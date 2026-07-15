[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Restore', 'Status')]
    [string]$Action,
    [string]$GamePath,
    [string]$OutputPath,
    [string]$BackupRoot,
    [string]$LegacyDebugModZip,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $repoRoot -Parent

if (-not $GamePath) {
    $GamePath = $env:HK_GAME_PATH
}
if (-not $GamePath) {
    throw 'Pass -GamePath or set HK_GAME_PATH.'
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'OutputFinal'
}
if (-not $BackupRoot) {
    $BackupRoot = Join-Path $workspaceRoot 'HollowKnight.ModdingAPI-backups'
}
if (-not $LegacyDebugModZip) {
    $LegacyDebugModZip = Join-Path $workspaceRoot 'HollowKnight.DebugMod-legacy-1.5.78\Source\DebugMod-Legacy-1.5.78.zip'
}

$requiredOutputFiles = @(
    'Assembly-CSharp.dll',
    'Assembly-CSharp.xml',
    'TeamCherry.Localization.dll',
    'TeamCherry.Localization.xml',
    'MMHOOK_Assembly-CSharp.dll',
    'MMHOOK_PlayMaker.dll',
    'MMHOOK_TeamCherry.BuildBot.dll',
    'MMHOOK_TeamCherry.Cinematics.dll',
    'MMHOOK_TeamCherry.Localization.dll',
    'MMHOOK_TeamCherry.NestedFadeGroup.dll',
    'MMHOOK_TeamCherry.SharedUtils.dll',
    'MMHOOK_TeamCherry.TK2D.dll',
    'Mono.Cecil.dll',
    'MonoMod.RuntimeDetour.dll',
    'MonoMod.Utils.dll',
    'unityscenerepacker.dll',
    'README.md'
)
$legacyFiles = @('DebugMod.dll', 'DebugMod.pdb', 'DebugMod.xml')
$requiredManifestFiles = @(
    $requiredOutputFiles
    $legacyFiles | ForEach-Object { "Mods\DebugMod\$_" }
)

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-DeploymentLockPath {
    $normalized = [IO.Path]::GetFullPath($GamePath).TrimEnd('\').ToUpperInvariant()
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))
    $name = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Join-Path ([IO.Path]::GetTempPath()) "HollowKnight.ModdingAPI-locks\$name.lock"
}

function Invoke-WithDeploymentLock {
    param([Parameter(Mandatory)][scriptblock]$Operation)

    $lockPath = Get-DeploymentLockPath
    New-Item -ItemType Directory -Path (Split-Path $lockPath -Parent) -Force | Out-Null
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        throw "Another deployment operation is already running for '$GamePath'."
    }
    try {
        & $Operation
    }
    finally {
        $lock.Dispose()
    }
}

function Get-RelativePath {
    param([Parameter(Mandatory)][string]$BasePath, [Parameter(Mandatory)][string]$Path)

    [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($BasePath), [IO.Path]::GetFullPath($Path))
}

function Resolve-SafeChildPath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Description
    )

    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
    if (-not $candidate.StartsWith("$base\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description resolves outside its allowed root: '$RelativePath'."
    }
    $candidate
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Description contains a reparse point: '$current'."
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if (-not $parent -or $parent.FullName -eq $current) {
            break
        }
        $current = $parent.FullName
    }
}

function Write-Manifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Path)

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Manifest | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Assert-GameClosed {
    if (Get-Process -Name 'hollow_knight' -ErrorAction SilentlyContinue) {
        throw 'hollow_knight is running. Close the game before installing or restoring.'
    }
}

function Get-ManagedPath {
    param([Parameter(Mandatory)][string]$Root)

    Join-Path $Root 'hollow_knight_Data\Managed'
}

function Assert-GameLayout {
    param([Parameter(Mandatory)][string]$Root)

    $managed = Get-ManagedPath $Root
    $globalManagers = Join-Path $Root 'hollow_knight_Data\globalgamemanagers'
    Assert-NoReparsePoint -Path $Root -Description 'Game path'
    Assert-NoReparsePoint -Path $managed -Description 'Managed path'
    foreach ($path in @((Join-Path $Root 'hollow_knight.exe'), $managed, $globalManagers)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Invalid game path; missing '$path'."
        }
    }

    $identity = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($globalManagers))
    if (-not $identity.Contains('1.5.12620') -or -not $identity.Contains('6000.0.61f1')) {
        throw 'Game must be Hollow Knight 1.5.12620 on Unity 6000.0.61f1.'
    }

    $managed
}

function Assert-VanillaGameFiles {
    param([Parameter(Mandatory)][string]$ManagedPath)

    $vanillaPath = Join-Path $repoRoot 'Vanilla'
    foreach ($name in @('Assembly-CSharp.dll', 'TeamCherry.Localization.dll')) {
        $gameFile = Join-Path $ManagedPath $name
        $vanillaFile = Join-Path $vanillaPath $name
        if (-not (Test-Path -LiteralPath $gameFile -PathType Leaf) -or -not (Test-Path -LiteralPath $vanillaFile -PathType Leaf)) {
            throw "Cannot validate vanilla '$name'."
        }
        if ((Get-Sha256 $gameFile) -ne (Get-Sha256 $vanillaFile)) {
            throw "Managed '$name' does not match Vanilla. Restore the original game before installing."
        }
    }
}

function Get-OutputFiles {
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        throw "OutputFinal not found: '$OutputPath'."
    }
    Assert-NoReparsePoint -Path $OutputPath -Description 'OutputFinal path'

    $items = @(Get-ChildItem -LiteralPath $OutputPath -Force)
    $actualNames = @($items | Where-Object { -not $_.PSIsContainer } | Select-Object -ExpandProperty Name)
    $unexpected = @($items | Where-Object { $_.PSIsContainer -or $_.Name -notin $requiredOutputFiles })
    $missing = @($requiredOutputFiles | Where-Object { $_ -notin $actualNames })
    if ($unexpected -or $missing -or $actualNames.Count -ne $requiredOutputFiles.Count) {
        $unexpectedNames = @($unexpected | Select-Object -ExpandProperty Name)
        throw "OutputFinal must contain exactly the required 17 files. Missing: '$($missing -join ', ')'. Unexpected: '$($unexpectedNames -join ', ')'."
    }

    foreach ($name in $requiredOutputFiles) {
        $path = Join-Path $OutputPath $name
        Assert-NoReparsePoint -Path $path -Description "OutputFinal '$name'"
        if ((Get-Item -LiteralPath $path).Length -eq 0) {
            throw "OutputFinal contains an empty '$name'."
        }
        Get-Item -LiteralPath $path
    }
}

function Expand-LegacyFiles {
    param([Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path -LiteralPath $LegacyDebugModZip -PathType Leaf)) {
        throw "Legacy DebugMod ZIP not found: '$LegacyDebugModZip'."
    }
    Assert-NoReparsePoint -Path $Destination -Description 'Legacy staging path'

    Add-Type -AssemblyName System.IO.Compression
    $archive = [IO.Compression.ZipFile]::OpenRead($LegacyDebugModZip)
    try {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        foreach ($name in $legacyFiles) {
            $matches = @($archive.Entries | Where-Object { $_.FullName -ceq $name -and $_.Length -gt 0 })
            if ($matches.Count -ne 1) {
                throw "Legacy DebugMod ZIP must contain one non-empty '$name' at its root."
            }
            $target = Join-Path $Destination $name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($matches[0], $target, $true)
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-LocalLowPath {
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    Join-Path (Split-Path $localAppData -Parent) 'LocalLow\Team Cherry\Hollow Knight'
}

function Copy-LocalLowSnapshot {
    param([Parameter(Mandatory)][string]$Destination)

    $source = Get-LocalLowPath
    Assert-NoReparsePoint -Path $Destination -Description 'LocalLow backup path'
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $records = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        return @($records)
    }
    if (Get-ChildItem -LiteralPath $source -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
        throw "LocalLow contains a reparse point and cannot be backed up safely: '$source'."
    }

    foreach ($child in Get-ChildItem -LiteralPath $source -Force) {
        Copy-Item -LiteralPath $child.FullName -Destination $Destination -Recurse -Force
    }
    foreach ($file in Get-ChildItem -LiteralPath $source -File -Force -Recurse) {
        $relative = Get-RelativePath $source $file.FullName
        $copied = Join-Path $Destination $relative
        $hash = Get-Sha256 $file.FullName
        if ((Get-Sha256 $copied) -ne $hash) {
            throw "LocalLow backup verification failed: '$relative'."
        }
        $records.Add([pscustomobject]@{ RelativePath = $relative; Sha256 = $hash })
    }
    @($records)
}

function Get-Manifest {
    param([Parameter(Mandatory)][string]$Path)

    $manifestPath = if (Test-Path -LiteralPath $Path -PathType Container) { Join-Path $Path 'manifest.json' } else { $Path }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Backup manifest not found: '$manifestPath'."
    }
    Assert-NoReparsePoint -Path $manifestPath -Description 'Backup manifest'
    [pscustomobject]@{
        Path = $manifestPath
        Directory = Split-Path $manifestPath -Parent
        Data = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
}

function Assert-ManifestProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)

    if (-not $Object.PSObject.Properties[$Name]) {
        throw "Invalid manifest: missing '$Name'."
    }
}

function Assert-Sha256Value {
    param($Value, [Parameter(Mandatory)][string]$Description)

    if ($Value -isnot [string] -or $Value -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Invalid manifest: $Description must be a SHA-256 hash."
    }
}

function Test-TimestampValue {
    param($Value)

    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) {
        return $true
    }
    if ($Value -isnot [string]) {
        return $false
    }
    $parsed = [DateTimeOffset]::MinValue
    [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
}

function Assert-Manifest {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ExpectedGamePath,
        [Parameter(Mandatory)][string]$ManifestDirectory,
        [string]$ExpectedStatus = 'Installed'
    )

    foreach ($name in @(
        'SchemaVersion', 'Status', 'CreatedAt', 'GamePath', 'OutputPath', 'LocalLowPath',
        'LocalLowExistedBefore', 'Files', 'LocalLowFiles', 'CompletedAt', 'Error'
    )) {
        Assert-ManifestProperty -Object $Manifest -Name $name
    }
    if ($Manifest.SchemaVersion -isnot [long] -and $Manifest.SchemaVersion -isnot [int]) {
        throw 'Invalid manifest: SchemaVersion must be an integer.'
    }
    if ([int]$Manifest.SchemaVersion -ne 1) {
        throw "Invalid manifest: unsupported SchemaVersion '$($Manifest.SchemaVersion)'."
    }
    if ($Manifest.Status -ne $ExpectedStatus) {
        throw "Invalid manifest: status must be $ExpectedStatus, got '$($Manifest.Status)'."
    }
    if (-not (Test-TimestampValue $Manifest.CreatedAt)) {
        throw 'Invalid manifest: CreatedAt must be a timestamp.'
    }
    if ($Manifest.GamePath -isnot [string] -or -not $Manifest.GamePath) {
        throw 'Invalid manifest: GamePath must be a non-empty string.'
    }
    if ([IO.Path]::GetFullPath($Manifest.GamePath).TrimEnd('\') -ine [IO.Path]::GetFullPath($ExpectedGamePath).TrimEnd('\')) {
        throw 'Invalid manifest: backup belongs to a different game path.'
    }
    if ($Manifest.LocalLowExistedBefore -isnot [bool]) {
        throw 'Invalid manifest: LocalLowExistedBefore must be a Boolean.'
    }
    if ($Manifest.OutputPath -isnot [string] -or -not $Manifest.OutputPath) {
        throw 'Invalid manifest: OutputPath must be a non-empty string.'
    }
    if ($Manifest.LocalLowPath -isnot [string] -or -not $Manifest.LocalLowPath) {
        throw 'Invalid manifest: LocalLowPath must be a non-empty string.'
    }
    if ($ExpectedStatus -eq 'Installed') {
        if (-not (Test-TimestampValue $Manifest.CompletedAt)) {
            throw 'Invalid manifest: CompletedAt must be a timestamp.'
        }
        if ($null -ne $Manifest.Error) {
            throw 'Invalid manifest: an Installed backup cannot contain an error.'
        }
    }
    elseif ($null -ne $Manifest.CompletedAt -or $null -ne $Manifest.Error) {
        throw 'Invalid manifest: a Preparing backup cannot be completed or contain an error.'
    }
    Assert-NoReparsePoint -Path $ManifestDirectory -Description 'Backup manifest path'

    $files = @($Manifest.Files)
    if ($files.Count -ne $requiredManifestFiles.Count) {
        throw "Invalid manifest: expected exactly $($requiredManifestFiles.Count) deployment files."
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $requiredManifestFiles | ForEach-Object { [void]$expected.Add($_) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $files) {
        foreach ($name in @('RelativePath', 'ExistedBefore', 'OriginalSha256', 'InstalledSha256', 'BackupRelativePath')) {
            Assert-ManifestProperty -Object $entry -Name $name
        }
        if ($entry.RelativePath -isnot [string] -or -not $expected.Contains($entry.RelativePath) -or -not $seen.Add($entry.RelativePath)) {
            throw "Invalid manifest: unexpected or duplicate deployment path '$($entry.RelativePath)'."
        }
        if ($entry.ExistedBefore -isnot [bool]) {
            throw "Invalid manifest: ExistedBefore must be a Boolean for '$($entry.RelativePath)'."
        }
        Assert-Sha256Value -Value $entry.InstalledSha256 -Description "InstalledSha256 for '$($entry.RelativePath)'"
        if ($entry.ExistedBefore) {
            Assert-Sha256Value -Value $entry.OriginalSha256 -Description "OriginalSha256 for '$($entry.RelativePath)'"
            $expectedBackup = Join-Path 'GameFiles' $entry.RelativePath
            if ($entry.BackupRelativePath -isnot [string] -or $entry.BackupRelativePath -cne $expectedBackup) {
                throw "Invalid manifest: BackupRelativePath is invalid for '$($entry.RelativePath)'."
            }
        }
        elseif ($null -ne $entry.OriginalSha256 -or $null -ne $entry.BackupRelativePath) {
            throw "Invalid manifest: new file '$($entry.RelativePath)' cannot have original backup metadata."
        }
    }
    if ($seen.Count -ne $expected.Count) {
        throw 'Invalid manifest: deployment file allowlist is incomplete.'
    }

    $localLowPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Manifest.LocalLowFiles)) {
        foreach ($name in @('RelativePath', 'Sha256')) {
            Assert-ManifestProperty -Object $entry -Name $name
        }
        if ($entry.RelativePath -isnot [string] -or -not $entry.RelativePath -or -not $localLowPaths.Add($entry.RelativePath)) {
            throw 'Invalid manifest: LocalLow RelativePath must be non-empty and unique.'
        }
        $localLowFile = Resolve-SafeChildPath -BasePath $Manifest.LocalLowPath -RelativePath $entry.RelativePath -Description 'LocalLow manifest file'
        if ((Get-RelativePath $Manifest.LocalLowPath $localLowFile) -cne $entry.RelativePath) {
            throw "Invalid manifest: LocalLow path is not canonical: '$($entry.RelativePath)'."
        }
        Assert-Sha256Value -Value $entry.Sha256 -Description "LocalLow SHA-256 for '$($entry.RelativePath)'"
    }
}

function Get-LatestInstalledManifest {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ForGamePath)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }
    $normalizedGamePath = [IO.Path]::GetFullPath($ForGamePath).TrimEnd('\')
    foreach ($directory in Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name -Descending) {
        $path = Join-Path $directory.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        try {
            Assert-NoReparsePoint -Path $path -Description 'Backup manifest'
            $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($data.Status -eq 'Installed' -and [IO.Path]::GetFullPath([string]$data.GamePath).TrimEnd('\') -ieq $normalizedGamePath) {
                return [pscustomobject]@{ Path = $path; Directory = $directory.FullName; Data = $data }
            }
        }
        catch {
            continue
        }
    }
    $null
}

function Remove-EmptyParents {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$StopPath)

    $stop = [IO.Path]::GetFullPath($StopPath).TrimEnd('\')
    $directory = Split-Path $Path -Parent
    while ($directory -and [IO.Path]::GetFullPath($directory).TrimEnd('\') -ine $stop) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            $directory = Split-Path $directory -Parent
            continue
        }
        if (Get-ChildItem -LiteralPath $directory -Force | Select-Object -First 1) {
            break
        }
        Remove-Item -LiteralPath $directory
        $directory = Split-Path $directory -Parent
    }
}

function Restore-ManifestFiles {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ManifestDirectory,
        [Parameter(Mandatory)][string]$ManagedPath
    )

    foreach ($entry in @($Manifest.Files)) {
        $destination = Resolve-SafeChildPath -BasePath $ManagedPath -RelativePath $entry.RelativePath -Description 'Manifest destination'
        Assert-NoReparsePoint -Path $destination -Description 'Manifest destination'
        if ($entry.ExistedBefore) {
            $backupFile = Resolve-SafeChildPath -BasePath $ManifestDirectory -RelativePath $entry.BackupRelativePath -Description 'Backup file'
            Assert-NoReparsePoint -Path $backupFile -Description 'Backup file'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $backupFile -Destination $destination -Force
        }
        elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
    }

    foreach ($entry in @($Manifest.Files) | Sort-Object { $_.RelativePath.Length } -Descending) {
        if (-not $entry.ExistedBefore) {
            $destination = Resolve-SafeChildPath -BasePath $ManagedPath -RelativePath $entry.RelativePath -Description 'Manifest destination'
            Remove-EmptyParents -Path $destination -StopPath $ManagedPath
        }
    }
}

function Assert-InstalledFilesUnchanged {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$ManagedPath)

    foreach ($entry in @($Manifest.Files)) {
        $destination = Resolve-SafeChildPath -BasePath $ManagedPath -RelativePath $entry.RelativePath -Description 'Manifest destination'
        Assert-NoReparsePoint -Path $destination -Description 'Manifest destination'
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-Sha256 $destination) -ne $entry.InstalledSha256) {
            throw "Installed file drift detected: '$($entry.RelativePath)'. Restore refused."
        }
    }
}

function Assert-RestorePreflight {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ManifestDirectory,
        [Parameter(Mandatory)][string]$ManagedPath
    )

    Assert-InstalledFilesUnchanged -Manifest $Manifest -ManagedPath $ManagedPath
    foreach ($entry in @($Manifest.Files | Where-Object ExistedBefore)) {
        $backupFile = Resolve-SafeChildPath -BasePath $ManifestDirectory -RelativePath $entry.BackupRelativePath -Description 'Backup file'
        Assert-NoReparsePoint -Path $backupFile -Description 'Backup file'
        if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf) -or (Get-Sha256 $backupFile) -ne $entry.OriginalSha256) {
            throw "Backup file is missing or corrupt: '$($entry.RelativePath)'."
        }
    }
}

function New-RestoreRollbackSnapshot {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ManagedPath,
        [Parameter(Mandatory)][string]$ManifestDirectory
    )

    $directory = Join-Path $ManifestDirectory (".restore-rollback-{0}" -f [guid]::NewGuid().ToString('N'))
    Assert-NoReparsePoint -Path $directory -Description 'Restore rollback path'
    try {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        foreach ($entry in @($Manifest.Files)) {
            $source = Resolve-SafeChildPath -BasePath $ManagedPath -RelativePath $entry.RelativePath -Description 'Installed file'
            $destination = Resolve-SafeChildPath -BasePath $directory -RelativePath $entry.RelativePath -Description 'Restore rollback file'
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination
            if ((Get-Sha256 $destination) -ne $entry.InstalledSha256) {
                throw "Restore rollback snapshot verification failed: '$($entry.RelativePath)'."
            }
        }
        $directory
    }
    catch {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        throw
    }
}

function Restore-InstalledSnapshot {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ManagedPath,
        [Parameter(Mandatory)][string]$SnapshotDirectory
    )

    foreach ($entry in @($Manifest.Files)) {
        $source = Resolve-SafeChildPath -BasePath $SnapshotDirectory -RelativePath $entry.RelativePath -Description 'Restore rollback file'
        $destination = Resolve-SafeChildPath -BasePath $ManagedPath -RelativePath $entry.RelativePath -Description 'Installed file'
        Assert-NoReparsePoint -Path $source -Description 'Restore rollback file'
        Assert-NoReparsePoint -Path $destination -Description 'Installed file'
        if ((Test-Path -LiteralPath $destination -PathType Leaf) -and (Get-Sha256 $destination) -eq $entry.InstalledSha256) {
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    Assert-InstalledFilesUnchanged -Manifest $Manifest -ManagedPath $ManagedPath
}

function Install-Api {
    Assert-GameClosed
    $managed = Assert-GameLayout $GamePath
    Assert-VanillaGameFiles $managed
    if (Get-LatestInstalledManifest -Root $BackupRoot -ForGamePath $GamePath) {
        throw 'An Installed backup already exists for this game. Restore it before reinstalling.'
    }

    $outputFiles = Get-OutputFiles
    Assert-NoReparsePoint -Path $BackupRoot -Description 'Backup root'
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backupDirectory = Join-Path $BackupRoot ("1.5.12620-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Assert-NoReparsePoint -Path $backupDirectory -Description 'Backup directory'
    $gameBackupDirectory = Join-Path $backupDirectory 'GameFiles'
    $legacyStaging = Join-Path $backupDirectory 'Staging\DebugMod'
    New-Item -ItemType Directory -Path $gameBackupDirectory -Force | Out-Null
    Expand-LegacyFiles -Destination $legacyStaging

    $sources = [Collections.Generic.List[object]]::new()
    foreach ($file in $outputFiles) {
        $relativeOutput = Get-RelativePath $OutputPath $file.FullName
        $sources.Add([pscustomobject]@{
            Source = $file.FullName
            Destination = Join-Path $managed $relativeOutput
        })
    }
    foreach ($name in $legacyFiles) {
        $sources.Add([pscustomobject]@{
            Source = Join-Path $legacyStaging $name
            Destination = Join-Path $managed "Mods\DebugMod\$name"
        })
    }

    $duplicate = $sources | Group-Object { [IO.Path]::GetFullPath($_.Destination).ToLowerInvariant() } | Where-Object Count -gt 1
    if ($duplicate) {
        throw 'OutputFinal and Legacy DebugMod contain duplicate deployment destinations.'
    }

    $fileRecords = [Collections.Generic.List[object]]::new()
    foreach ($source in $sources) {
        Assert-NoReparsePoint -Path $source.Destination -Description 'Deployment destination'
        if (Test-Path -LiteralPath $source.Destination -PathType Container) {
            throw "A deployment file is blocked by a directory: '$($source.Destination)'."
        }
        $relativeManaged = Get-RelativePath $managed $source.Destination
        if ($relativeManaged -notin $requiredManifestFiles) {
            throw "Deployment destination is not allowed: '$relativeManaged'."
        }
        $existed = Test-Path -LiteralPath $source.Destination -PathType Leaf
        $backupRelative = if ($existed) { Join-Path 'GameFiles' $relativeManaged } else { $null }
        $originalHash = if ($existed) { Get-Sha256 $source.Destination } else { $null }
        if ($existed) {
            $backupFile = Join-Path $backupDirectory $backupRelative
            Assert-NoReparsePoint -Path $backupFile -Description 'Game file backup'
            New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source.Destination -Destination $backupFile
            if ((Get-Sha256 $backupFile) -ne $originalHash) {
                throw "Game file backup verification failed: '$relativeManaged'."
            }
        }
        $fileRecords.Add([pscustomobject]@{
            RelativePath = $relativeManaged
            ExistedBefore = $existed
            OriginalSha256 = $originalHash
            InstalledSha256 = Get-Sha256 $source.Source
            BackupRelativePath = $backupRelative
        })
    }

    $manifest = [pscustomobject]@{
        SchemaVersion = 1
        Status = 'Preparing'
        CreatedAt = (Get-Date).ToUniversalTime().ToString('o')
        GamePath = [IO.Path]::GetFullPath($GamePath)
        OutputPath = [IO.Path]::GetFullPath($OutputPath)
        LocalLowPath = Get-LocalLowPath
        LocalLowExistedBefore = Test-Path -LiteralPath (Get-LocalLowPath) -PathType Container
        Files = @($fileRecords)
        LocalLowFiles = @(Copy-LocalLowSnapshot -Destination (Join-Path $backupDirectory 'LocalLow'))
        CompletedAt = $null
        Error = $null
    }
    $manifestPath = Join-Path $backupDirectory 'manifest.json'
    Write-Manifest -Manifest $manifest -Path $manifestPath
    Assert-Manifest -Manifest $manifest -ExpectedGamePath $GamePath -ManifestDirectory $backupDirectory -ExpectedStatus 'Preparing'

    $gameMutationStarted = $false
    try {
        Assert-GameClosed
        foreach ($source in $sources) {
            Assert-NoReparsePoint -Path $source.Destination -Description 'Deployment destination'
            $gameMutationStarted = $true
            New-Item -ItemType Directory -Path (Split-Path $source.Destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source.Source -Destination $source.Destination -Force
        }
        Assert-InstalledFilesUnchanged -Manifest $manifest -ManagedPath $managed
        $manifest.Status = 'Installed'
        $manifest.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-Manifest -Manifest $manifest -Path $manifestPath
        Remove-Item -LiteralPath (Join-Path $backupDirectory 'Staging') -Recurse -Force
        "Installed: $backupDirectory"
    }
    catch {
        $installError = $_.Exception.Message
        if (-not $gameMutationStarted) {
            $manifest.Status = 'InstallAborted'
            $manifest.Error = $installError
            $manifest.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Write-Manifest -Manifest $manifest -Path $manifestPath
            throw "Install failed before game modification: $installError"
        }
        try {
            Restore-ManifestFiles -Manifest $manifest -ManifestDirectory $backupDirectory -ManagedPath $managed
            $manifest.Status = 'InstallFailedRolledBack'
            $manifest.Error = $installError
            $manifest.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Write-Manifest -Manifest $manifest -Path $manifestPath
            throw "Install failed and was rolled back: $installError"
        }
        catch {
            if ($_.Exception.Message -like 'Install failed and was rolled back:*') {
                throw
            }
            $manifest.Status = 'InstallFailedRollbackFailed'
            $manifest.Error = "$installError | Rollback: $($_.Exception.Message)"
            $manifest.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Write-Manifest -Manifest $manifest -Path $manifestPath
            throw "Install failed and rollback also failed: $($manifest.Error)"
        }
    }
}

function Restore-Api {
    Assert-GameClosed
    $managed = Assert-GameLayout $GamePath
    $record = if ($BackupPath) { Get-Manifest $BackupPath } else { Get-LatestInstalledManifest -Root $BackupRoot -ForGamePath $GamePath }
    if (-not $record) {
        throw 'No Installed backup manifest found.'
    }
    Assert-Manifest -Manifest $record.Data -ExpectedGamePath $GamePath -ManifestDirectory $record.Directory
    Assert-RestorePreflight -Manifest $record.Data -ManifestDirectory $record.Directory -ManagedPath $managed
    $rollbackDirectory = New-RestoreRollbackSnapshot -Manifest $record.Data -ManagedPath $managed -ManifestDirectory $record.Directory

    try {
        Assert-GameClosed
    }
    catch {
        Remove-Item -LiteralPath $rollbackDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    try {
        Restore-ManifestFiles -Manifest $record.Data -ManifestDirectory $record.Directory -ManagedPath $managed
        foreach ($entry in @($record.Data.Files)) {
            $destination = Resolve-SafeChildPath -BasePath $managed -RelativePath $entry.RelativePath -Description 'Manifest destination'
            if ($entry.ExistedBefore) {
                if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-Sha256 $destination) -ne $entry.OriginalSha256) {
                    throw "Restore verification failed: '$($entry.RelativePath)'."
                }
            }
            elseif (Test-Path -LiteralPath $destination) {
                throw "Restore verification failed to remove '$($entry.RelativePath)'."
            }
        }
        $record.Data.Status = 'Restored'
        $record.Data.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-Manifest -Manifest $record.Data -Path $record.Path
    }
    catch {
        $restoreError = $_.Exception.Message
        try {
            $record.Data.Status = 'Installed'
            Restore-InstalledSnapshot -Manifest $record.Data -ManagedPath $managed -SnapshotDirectory $rollbackDirectory
            Remove-Item -LiteralPath $rollbackDirectory -Recurse -Force -ErrorAction SilentlyContinue
            throw "Restore failed; installed state was recovered: $restoreError"
        }
        catch {
            if ($_.Exception.Message -like 'Restore failed; installed state was recovered:*') {
                throw
            }
            throw "Restore failed and installed-state rollback also failed: $restoreError | Rollback: $($_.Exception.Message)"
        }
    }

    Remove-Item -LiteralPath $rollbackDirectory -Recurse -Force -ErrorAction SilentlyContinue
    "Restored: $($record.Directory). LocalLow snapshot was not restored."
}

function Get-DeploymentStatus {
    $managed = Assert-GameLayout $GamePath
    $record = Get-LatestInstalledManifest -Root $BackupRoot -ForGamePath $GamePath
    $state = 'Vanilla'
    $detail = 'Managed files match Vanilla; no active Installed manifest.'

    if ($record) {
        Assert-Manifest -Manifest $record.Data -ExpectedGamePath $GamePath -ManifestDirectory $record.Directory
        $missing = 0
        $drifted = 0
        foreach ($entry in @($record.Data.Files)) {
            $destination = Resolve-SafeChildPath -BasePath $managed -RelativePath $entry.RelativePath -Description 'Manifest destination'
            Assert-NoReparsePoint -Path $destination -Description 'Manifest destination'
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                $missing++
            }
            elseif ((Get-Sha256 $destination) -ne $entry.InstalledSha256) {
                $drifted++
            }
        }
        if ($drifted -gt 0) {
            $state = 'Drifted'
            $detail = "$drifted deployed file(s) changed."
        }
        elseif ($missing -gt 0) {
            $state = 'Partial'
            $detail = "$missing deployed file(s) missing."
        }
        else {
            $state = 'Installed'
            $detail = 'All deployed files match the active backup manifest.'
        }
    }
    else {
        try {
            Assert-VanillaGameFiles $managed
        }
        catch {
            $apiMarkers = @($requiredOutputFiles | Where-Object { Test-Path -LiteralPath (Join-Path $managed $_) -PathType Leaf })
            $state = if ($apiMarkers.Count -gt 0) { 'Partial' } else { 'Drifted' }
            $detail = $_.Exception.Message
        }
    }

    $doorstopConfig = Join-Path $GamePath 'doorstop_config.ini'
    $doorstopDisableSupported = $false
    if (Test-Path -LiteralPath $doorstopConfig -PathType Leaf) {
        $doorstopText = Get-Content -LiteralPath $doorstopConfig -Raw
        $doorstopDisableSupported = $doorstopText -match '(?im)^\s*ignore_disable_switch\s*=\s*false\s*$'
    }

    [pscustomobject]@{
        State = $state
        Detail = $detail
        GamePath = [IO.Path]::GetFullPath($GamePath)
        OutputReady = $(try { [void](Get-OutputFiles); $true } catch { $false })
        BackupPath = if ($record) { $record.Directory } else { $null }
        DoorstopDisableSupported = $doorstopDisableSupported
    }
}

switch ($Action) {
    'Install' { Invoke-WithDeploymentLock { Install-Api } }
    'Restore' { Invoke-WithDeploymentLock { Restore-Api } }
    'Status' { Get-DeploymentStatus }
}
