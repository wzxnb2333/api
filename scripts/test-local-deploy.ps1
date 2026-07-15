[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

function Get-Hash {
    param([string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Invoke-Deploy {
    param(
        [string]$Action,
        [string]$GamePath,
        [string]$OutputPath,
        [string]$BackupRoot,
        [string]$LegacyDebugModZip,
        [string]$BackupPath
    )

    $arguments = @{
        Action = $Action
        GamePath = $GamePath
        OutputPath = $OutputPath
        BackupRoot = $BackupRoot
        LegacyDebugModZip = $LegacyDebugModZip
    }
    if ($BackupPath) {
        $arguments.BackupPath = $BackupPath
    }

    (& $script:DeployScript @arguments | Out-String).Trim()
}

function Assert-DeployFails {
    param([hashtable]$Arguments, [string]$ExpectedMessage)

    try {
        & $script:DeployScript @Arguments | Out-Null
    }
    catch {
        Assert-True ($_.Exception.Message -like "*$ExpectedMessage*") "failure should mention '$ExpectedMessage'"
        return
    }

    throw "Assertion failed: deployment should fail with '$ExpectedMessage'."
}

function New-FakeGame {
    param([string]$Path, [string]$VanillaPath)

    $managed = Join-Path $Path 'hollow_knight_Data\Managed'
    New-Item -ItemType Directory -Path $managed -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'hollow_knight.exe') -Value 'fake executable' -NoNewline
    Set-Content -LiteralPath (Join-Path $Path 'hollow_knight_Data\globalgamemanagers') -Value "6000.0.61f1`01.5.12620" -NoNewline
    Copy-Item -LiteralPath (Join-Path $VanillaPath 'Assembly-CSharp.dll') -Destination $managed
    Copy-Item -LiteralPath (Join-Path $VanillaPath 'TeamCherry.Localization.dll') -Destination $managed
}

function New-FakeOutput {
    param([string]$Path, [switch]$BreakLegacyDirectory)

    $required = @(
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

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    foreach ($name in $required) {
        Set-Content -LiteralPath (Join-Path $Path $name) -Value "patched:$name" -NoNewline
    }
    if ($BreakLegacyDirectory) {
        Set-Content -LiteralPath (Join-Path $Path 'Mods') -Value 'blocks mod directory creation' -NoNewline
    }
}

function New-FakeLegacyZip {
    param([string]$Path, [string]$StagingPath)

    New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $StagingPath 'DebugMod.dll') -Value 'legacy dll' -NoNewline
    Set-Content -LiteralPath (Join-Path $StagingPath 'DebugMod.pdb') -Value 'legacy pdb' -NoNewline
    Set-Content -LiteralPath (Join-Path $StagingPath 'DebugMod.xml') -Value 'legacy xml' -NoNewline
    Set-Content -LiteralPath (Join-Path $StagingPath 'README.md') -Value 'not deployed' -NoNewline
    Compress-Archive -Path (Join-Path $StagingPath '*') -DestinationPath $Path
}

$script:DeployScript = Join-Path $PSScriptRoot 'local-deploy.ps1'
Assert-True (Test-Path -LiteralPath $script:DeployScript -PathType Leaf) 'local-deploy.ps1 must exist'

$repoRoot = Split-Path $PSScriptRoot -Parent
$vanillaPath = Join-Path $repoRoot 'Vanilla'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("hk-modding-api-deploy-test-{0}" -f [guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA

try {
    $gamePath = Join-Path $tempRoot 'game'
    $outputPath = Join-Path $tempRoot 'output'
    $backupRoot = Join-Path $tempRoot 'backups'
    $legacyZip = Join-Path $tempRoot 'DebugMod-Legacy-1.5.78.zip'
    $localAppData = Join-Path $tempRoot 'AppData\Local'
    $localLow = Join-Path $tempRoot 'AppData\LocalLow\Team Cherry\Hollow Knight'

    New-Item -ItemType Directory -Path $localAppData,$localLow -Force | Out-Null
    $env:LOCALAPPDATA = $localAppData
    Set-Content -LiteralPath (Join-Path $localLow 'user1.dat') -Value 'save before install' -NoNewline

    New-FakeGame -Path $gamePath -VanillaPath $vanillaPath
    New-FakeOutput -Path $outputPath
    New-FakeLegacyZip -Path $legacyZip -StagingPath (Join-Path $tempRoot 'legacy')

    $originalAssemblyHash = Get-Hash (Join-Path $gamePath 'hollow_knight_Data\Managed\Assembly-CSharp.dll')
    $installOutput = Invoke-Deploy -Action Install -GamePath $gamePath -OutputPath $outputPath -BackupRoot $backupRoot -LegacyDebugModZip $legacyZip
    Assert-True ($installOutput -like '*Installed*') 'install should report Installed'

    $backupPath = Get-ChildItem -LiteralPath $backupRoot -Directory | Select-Object -First 1 -ExpandProperty FullName
    $manifestPath = Join-Path $backupPath 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal 'Installed' $manifest.Status 'manifest status after install'
    Assert-True (Test-Path -LiteralPath (Join-Path $backupPath 'LocalLow\user1.dat')) 'LocalLow snapshot should be backed up'
    Assert-Equal (Get-Hash (Join-Path $outputPath 'Assembly-CSharp.dll')) (Get-Hash (Join-Path $gamePath 'hollow_knight_Data\Managed\Assembly-CSharp.dll')) 'patched Assembly-CSharp should be installed'

    $modPath = Join-Path $gamePath 'hollow_knight_Data\Managed\Mods\DebugMod'
    Assert-True (Test-Path -LiteralPath (Join-Path $modPath 'DebugMod.dll')) 'legacy DLL should be installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $modPath 'DebugMod.pdb')) 'legacy PDB should be installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $modPath 'DebugMod.xml')) 'legacy XML should be installed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $modPath 'README.md'))) 'legacy README should not be installed'

    $status = Invoke-Deploy -Action Status -GamePath $gamePath -OutputPath $outputPath -BackupRoot $backupRoot -LegacyDebugModZip $legacyZip
    Assert-True ($status -like '*Installed*') 'status should report Installed'

    $hookPath = Join-Path $gamePath 'hollow_knight_Data\Managed\MMHOOK_PlayMaker.dll'
    Remove-Item -LiteralPath $hookPath
    $status = Invoke-Deploy -Action Status -GamePath $gamePath -OutputPath $outputPath -BackupRoot $backupRoot -LegacyDebugModZip $legacyZip
    Assert-True ($status -like '*Partial*') 'status should report Partial when a deployed file is missing'
    Copy-Item -LiteralPath (Join-Path $outputPath 'MMHOOK_PlayMaker.dll') -Destination $hookPath

    $assemblyPath = Join-Path $gamePath 'hollow_knight_Data\Managed\Assembly-CSharp.dll'
    Add-Content -LiteralPath $assemblyPath -Value 'drift' -NoNewline
    $status = Invoke-Deploy -Action Status -GamePath $gamePath -OutputPath $outputPath -BackupRoot $backupRoot -LegacyDebugModZip $legacyZip
    Assert-True ($status -like '*Drifted*') 'status should report Drifted when a deployed file changed'
    Assert-DeployFails -Arguments @{
        Action = 'Restore'; GamePath = $gamePath; OutputPath = $outputPath; BackupRoot = $backupRoot
        LegacyDebugModZip = $legacyZip; BackupPath = $backupPath
    } -ExpectedMessage 'drift'

    Copy-Item -LiteralPath (Join-Path $outputPath 'Assembly-CSharp.dll') -Destination $assemblyPath -Force
    Set-Content -LiteralPath (Join-Path $localLow 'user1.dat') -Value 'save after install' -NoNewline
    $restoreOutput = Invoke-Deploy -Action Restore -GamePath $gamePath -OutputPath $outputPath -BackupRoot $backupRoot -LegacyDebugModZip $legacyZip -BackupPath $backupPath
    Assert-True ($restoreOutput -like '*Restored*') 'restore should report Restored'
    Assert-Equal $originalAssemblyHash (Get-Hash $assemblyPath) 'restore should recover vanilla Assembly-CSharp'
    Assert-True (-not (Test-Path -LiteralPath $hookPath)) 'restore should delete newly added API files'
    Assert-True (-not (Test-Path -LiteralPath $modPath)) 'restore should remove empty legacy mod directory'
    Assert-Equal 'save after install' (Get-Content -LiteralPath (Join-Path $localLow 'user1.dat') -Raw) 'restore must not overwrite LocalLow'

    $outsidePath = Join-Path $tempRoot 'outside.txt'
    Set-Content -LiteralPath $outsidePath -Value 'must survive' -NoNewline
    $maliciousBackup = Join-Path $tempRoot 'malicious-backup'
    New-Item -ItemType Directory -Path $maliciousBackup -Force | Out-Null
    [pscustomobject]@{
        SchemaVersion = 1
        Status = 'Installed'
        GamePath = $gamePath
        Files = @([pscustomobject]@{
            RelativePath = '..\outside.txt'
            ExistedBefore = $false
            OriginalSha256 = $null
            InstalledSha256 = Get-Hash $outsidePath
            BackupRelativePath = $null
        })
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $maliciousBackup 'manifest.json') -Encoding utf8
    Assert-DeployFails -Arguments @{
        Action = 'Restore'; GamePath = $gamePath; OutputPath = $outputPath; BackupRoot = $backupRoot
        LegacyDebugModZip = $legacyZip; BackupPath = $maliciousBackup
    } -ExpectedMessage 'outside game path'
    Assert-True (Test-Path -LiteralPath $outsidePath -PathType Leaf) 'restore must not touch paths outside the game'

    $rollbackGame = Join-Path $tempRoot 'rollback-game'
    $rollbackOutput = Join-Path $tempRoot 'rollback-output'
    $rollbackBackups = Join-Path $tempRoot 'rollback-backups'
    New-FakeGame -Path $rollbackGame -VanillaPath $vanillaPath
    New-FakeOutput -Path $rollbackOutput -BreakLegacyDirectory
    $rollbackAssembly = Join-Path $rollbackGame 'hollow_knight_Data\Managed\Assembly-CSharp.dll'
    $rollbackOriginalHash = Get-Hash $rollbackAssembly

    Assert-DeployFails -Arguments @{
        Action = 'Install'; GamePath = $rollbackGame; OutputPath = $rollbackOutput
        BackupRoot = $rollbackBackups; LegacyDebugModZip = $legacyZip
    } -ExpectedMessage 'rolled back'
    Assert-Equal $rollbackOriginalHash (Get-Hash $rollbackAssembly) 'failed install should restore overwritten files'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackGame 'hollow_knight_Data\Managed\MMHOOK_PlayMaker.dll'))) 'failed install should delete newly added files'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackGame 'hollow_knight_Data\Managed\Mods'))) 'failed install should remove blocking output file'

    'PASS: local deployment install, status, drift protection, restore, LocalLow preservation, and rollback'
}
finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $resolvedTempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($resolvedTempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTempRoot)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
