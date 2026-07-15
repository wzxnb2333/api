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
    $GamePath = 'D:\Program Files\steam\steamapps\common\Hollow Knight'
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

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
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
        throw "$Description resolves outside game path: '$RelativePath'."
    }
    $candidate
}

function Write-Manifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Path)

    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
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
    foreach ($name in $requiredOutputFiles) {
        $path = Join-Path $OutputPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            throw "OutputFinal is incomplete; missing or empty '$name'."
        }
    }

    @(Get-ChildItem -LiteralPath $OutputPath -File -Recurse | Sort-Object FullName)
}

function Expand-LegacyFiles {
    param([Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path -LiteralPath $LegacyDebugModZip -PathType Leaf)) {
        throw "Legacy DebugMod ZIP not found: '$LegacyDebugModZip'."
    }

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
    [pscustomobject]@{
        Path = $manifestPath
        Directory = Split-Path $manifestPath -Parent
        Data = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
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
        $destination = Resolve-SafeChildPath -BasePath $Manifest.GamePath -RelativePath $entry.RelativePath -Description 'Manifest destination'
        if ($entry.ExistedBefore) {
            $backupFile = Resolve-SafeChildPath -BasePath $ManifestDirectory -RelativePath $entry.BackupRelativePath -Description 'Backup file'
            if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf) -or (Get-Sha256 $backupFile) -ne $entry.OriginalSha256) {
                throw "Backup file is missing or corrupt: '$($entry.RelativePath)'."
            }
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $backupFile -Destination $destination -Force
        }
        elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
    }

    foreach ($entry in @($Manifest.Files) | Sort-Object { $_.RelativePath.Length } -Descending) {
        if (-not $entry.ExistedBefore) {
            $destination = Resolve-SafeChildPath -BasePath $Manifest.GamePath -RelativePath $entry.RelativePath -Description 'Manifest destination'
            Remove-EmptyParents -Path $destination -StopPath $ManagedPath
        }
    }
}

function Assert-InstalledFilesUnchanged {
    param([Parameter(Mandatory)]$Manifest)

    foreach ($entry in @($Manifest.Files)) {
        $destination = Resolve-SafeChildPath -BasePath $Manifest.GamePath -RelativePath $entry.RelativePath -Description 'Manifest destination'
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-Sha256 $destination) -ne $entry.InstalledSha256) {
            throw "Installed file drift detected: '$($entry.RelativePath)'. Restore refused."
        }
    }
}

function Install-Api {
    Assert-GameClosed
    $managed = Assert-GameLayout $GamePath
    Assert-VanillaGameFiles $managed
    if (Get-LatestInstalledManifest -Root $BackupRoot -ForGamePath $GamePath) {
        throw 'An Installed backup already exists for this game. Restore it before reinstalling.'
    }

    $outputFiles = Get-OutputFiles
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backupDirectory = Join-Path $BackupRoot ("1.5.12620-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
        if (Test-Path -LiteralPath $source.Destination -PathType Container) {
            throw "A deployment file is blocked by a directory: '$($source.Destination)'."
        }
        $relativeGame = Get-RelativePath $GamePath $source.Destination
        $existed = Test-Path -LiteralPath $source.Destination -PathType Leaf
        $backupRelative = if ($existed) { Join-Path 'GameFiles' $relativeGame } else { $null }
        $originalHash = if ($existed) { Get-Sha256 $source.Destination } else { $null }
        if ($existed) {
            $backupFile = Join-Path $backupDirectory $backupRelative
            New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source.Destination -Destination $backupFile
            if ((Get-Sha256 $backupFile) -ne $originalHash) {
                throw "Game file backup verification failed: '$relativeGame'."
            }
        }
        $fileRecords.Add([pscustomobject]@{
            RelativePath = $relativeGame
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

    try {
        foreach ($source in $sources) {
            New-Item -ItemType Directory -Path (Split-Path $source.Destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source.Source -Destination $source.Destination -Force
        }
        Assert-InstalledFilesUnchanged $manifest
        $manifest.Status = 'Installed'
        $manifest.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-Manifest -Manifest $manifest -Path $manifestPath
        Remove-Item -LiteralPath (Join-Path $backupDirectory 'Staging') -Recurse -Force
        "Installed: $backupDirectory"
    }
    catch {
        $installError = $_.Exception.Message
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
    if ($record.Data.Status -ne 'Installed') {
        throw "Backup status must be Installed, got '$($record.Data.Status)'."
    }
    if ([IO.Path]::GetFullPath([string]$record.Data.GamePath).TrimEnd('\') -ine [IO.Path]::GetFullPath($GamePath).TrimEnd('\')) {
        throw 'Backup belongs to a different game path.'
    }

    Assert-InstalledFilesUnchanged $record.Data
    Restore-ManifestFiles -Manifest $record.Data -ManifestDirectory $record.Directory -ManagedPath $managed
    foreach ($entry in @($record.Data.Files)) {
        $destination = Resolve-SafeChildPath -BasePath $record.Data.GamePath -RelativePath $entry.RelativePath -Description 'Manifest destination'
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
    "Restored: $($record.Directory). LocalLow snapshot was not restored."
}

function Get-DeploymentStatus {
    $managed = Assert-GameLayout $GamePath
    $record = Get-LatestInstalledManifest -Root $BackupRoot -ForGamePath $GamePath
    $state = 'Vanilla'
    $detail = 'Managed files match Vanilla; no active Installed manifest.'

    if ($record) {
        $missing = 0
        $drifted = 0
        foreach ($entry in @($record.Data.Files)) {
            $destination = Resolve-SafeChildPath -BasePath $record.Data.GamePath -RelativePath $entry.RelativePath -Description 'Manifest destination'
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
    'Install' { Install-Api }
    'Restore' { Restore-Api }
    'Status' { Get-DeploymentStatus }
}
