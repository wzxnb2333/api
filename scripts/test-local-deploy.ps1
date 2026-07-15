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

function Get-DeploymentLockPath {
    param([string]$GamePath)

    $normalized = [IO.Path]::GetFullPath($GamePath).TrimEnd('\').ToUpperInvariant()
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))
    $name = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Join-Path ([IO.Path]::GetTempPath()) "HollowKnight.ModdingAPI-locks\$name.lock"
}

function Try-NewJunction {
    param([string]$Path, [string]$Target)

    try {
        New-Item -ItemType Junction -Path $Path -Target $Target -Force -ErrorAction Stop | Out-Null
        $true
    }
    catch {
        [Console]::WriteLine("SKIP: reparse-point test unavailable: $($_.Exception.Message)")
        $false
    }
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
        Assert-True ($_.Exception.Message -like "*$ExpectedMessage*") "failure '$($_.Exception.Message)' should mention '$ExpectedMessage'"
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

    $extraGame = Join-Path $tempRoot 'extra-game'
    $extraOutput = Join-Path $tempRoot 'extra-output'
    $extraBackups = Join-Path $tempRoot 'extra-backups'
    New-FakeGame -Path $extraGame -VanillaPath $vanillaPath
    New-FakeOutput -Path $extraOutput
    Set-Content -LiteralPath (Join-Path $extraOutput 'unexpected.dll') -Value 'must not deploy' -NoNewline
    Assert-DeployFails -Arguments @{
        Action = 'Install'; GamePath = $extraGame; OutputPath = $extraOutput
        BackupRoot = $extraBackups; LegacyDebugModZip = $legacyZip
    } -ExpectedMessage 'unexpected'
    Assert-Equal (Get-Hash (Join-Path $vanillaPath 'Assembly-CSharp.dll')) (Get-Hash (Join-Path $extraGame 'hollow_knight_Data\Managed\Assembly-CSharp.dll')) 'extra output rejection must not modify the game'

    $lockGame = Join-Path $tempRoot 'lock-game'
    $lockOutput = Join-Path $tempRoot 'lock-output'
    $lockBackups = Join-Path $tempRoot 'lock-backups'
    New-FakeGame -Path $lockGame -VanillaPath $vanillaPath
    New-FakeOutput -Path $lockOutput
    $lockPath = Get-DeploymentLockPath $lockGame
    New-Item -ItemType Directory -Path (Split-Path $lockPath -Parent) -Force | Out-Null
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-DeployFails -Arguments @{
            Action = 'Install'; GamePath = $lockGame; OutputPath = $lockOutput
            BackupRoot = $lockBackups; LegacyDebugModZip = $legacyZip
        } -ExpectedMessage 'already running'
    }
    finally {
        $lockStream.Dispose()
    }

    $junctionTargetGame = Join-Path $tempRoot 'junction-target-game'
    $junctionTargetOutput = Join-Path $tempRoot 'junction-target-output'
    $junctionTargetBackups = Join-Path $tempRoot 'junction-target-backups'
    $junctionTargetOutside = Join-Path $tempRoot 'junction-target-outside'
    New-FakeGame -Path $junctionTargetGame -VanillaPath $vanillaPath
    New-FakeOutput -Path $junctionTargetOutput
    New-Item -ItemType Directory -Path $junctionTargetOutside -Force | Out-Null
    $modsJunction = Join-Path $junctionTargetGame 'hollow_knight_Data\Managed\Mods'
    if (Try-NewJunction -Path $modsJunction -Target $junctionTargetOutside) {
        try {
            Assert-DeployFails -Arguments @{
                Action = 'Install'; GamePath = $junctionTargetGame; OutputPath = $junctionTargetOutput
                BackupRoot = $junctionTargetBackups; LegacyDebugModZip = $legacyZip
            } -ExpectedMessage 'reparse point'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionTargetOutside 'DebugMod\DebugMod.dll'))) 'target junction rejection must not write through the junction'
        }
        finally {
            Remove-Item -LiteralPath $modsJunction -Force -ErrorAction SilentlyContinue
        }
    }

    $junctionBackupGame = Join-Path $tempRoot 'junction-backup-game'
    $junctionBackupOutput = Join-Path $tempRoot 'junction-backup-output'
    $junctionBackupRoot = Join-Path $tempRoot 'junction-backup-root'
    $junctionBackupOutside = Join-Path $tempRoot 'junction-backup-outside'
    New-FakeGame -Path $junctionBackupGame -VanillaPath $vanillaPath
    New-FakeOutput -Path $junctionBackupOutput
    New-Item -ItemType Directory -Path $junctionBackupOutside -Force | Out-Null
    if (Try-NewJunction -Path $junctionBackupRoot -Target $junctionBackupOutside) {
        try {
            Assert-DeployFails -Arguments @{
                Action = 'Install'; GamePath = $junctionBackupGame; OutputPath = $junctionBackupOutput
                BackupRoot = $junctionBackupRoot; LegacyDebugModZip = $legacyZip
            } -ExpectedMessage 'reparse point'
        }
        finally {
            Remove-Item -LiteralPath $junctionBackupRoot -Force -ErrorAction SilentlyContinue
        }
    }

    $originalAssemblyHash = Get-Hash (Join-Path $gamePath 'hollow_knight_Data\Managed\Assembly-CSharp.dll')
    $installOutput = Invoke-Deploy -Action Install -GamePath $gamePath -OutputPath $outputPath -BackupRoot $backupRoot -LegacyDebugModZip $legacyZip
    Assert-True ($installOutput -like '*Installed*') 'install should report Installed'

    $backupPath = Get-ChildItem -LiteralPath $backupRoot -Directory | Select-Object -First 1 -ExpandProperty FullName
    $manifestPath = Join-Path $backupPath 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal 'Installed' $manifest.Status 'manifest status after install'
    Assert-Equal 20 @($manifest.Files).Count 'manifest should contain the exact deployment allowlist'
    Assert-True (Test-Path -LiteralPath (Join-Path $backupPath 'LocalLow\user1.dat')) 'LocalLow snapshot should be backed up'
    Assert-Equal (Get-Hash (Join-Path $outputPath 'Assembly-CSharp.dll')) (Get-Hash (Join-Path $gamePath 'hollow_knight_Data\Managed\Assembly-CSharp.dll')) 'patched Assembly-CSharp should be installed'

    $modPath = Join-Path $gamePath 'hollow_knight_Data\Managed\Mods\DebugMod'
    Assert-True (Test-Path -LiteralPath (Join-Path $modPath 'DebugMod.dll')) 'legacy DLL should be installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $modPath 'DebugMod.pdb')) 'legacy PDB should be installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $modPath 'DebugMod.xml')) 'legacy XML should be installed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $modPath 'README.md'))) 'legacy README should not be installed'

    $bepInExVictim = Join-Path $gamePath 'BepInEx\config\victim.cfg'
    New-Item -ItemType Directory -Path (Split-Path $bepInExVictim -Parent) -Force | Out-Null
    Set-Content -LiteralPath $bepInExVictim -Value 'must survive' -NoNewline
    $maliciousBackup = Join-Path $tempRoot 'malicious-backup'
    Copy-Item -LiteralPath $backupPath -Destination $maliciousBackup -Recurse
    $maliciousManifestPath = Join-Path $maliciousBackup 'manifest.json'
    $maliciousManifest = Get-Content -LiteralPath $maliciousManifestPath -Raw | ConvertFrom-Json
    $maliciousManifest.Files[0].RelativePath = '..\..\BepInEx\config\victim.cfg'
    $maliciousManifest.Files[0].ExistedBefore = $false
    $maliciousManifest.Files[0].OriginalSha256 = $null
    $maliciousManifest.Files[0].InstalledSha256 = Get-Hash $bepInExVictim
    $maliciousManifest.Files[0].BackupRelativePath = $null
    $maliciousManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $maliciousManifestPath -Encoding utf8
    Assert-DeployFails -Arguments @{
        Action = 'Restore'; GamePath = $gamePath; OutputPath = $outputPath; BackupRoot = $backupRoot
        LegacyDebugModZip = $legacyZip; BackupPath = $maliciousBackup
    } -ExpectedMessage 'manifest'
    Assert-True (Test-Path -LiteralPath $bepInExVictim -PathType Leaf) 'forged manifest must not touch BepInEx'

    $badSchemaBackup = Join-Path $tempRoot 'bad-schema-backup'
    Copy-Item -LiteralPath $backupPath -Destination $badSchemaBackup -Recurse
    $badSchemaManifestPath = Join-Path $badSchemaBackup 'manifest.json'
    $badSchemaManifest = Get-Content -LiteralPath $badSchemaManifestPath -Raw | ConvertFrom-Json
    $badSchemaManifest.SchemaVersion = 2
    $badSchemaManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $badSchemaManifestPath -Encoding utf8
    Assert-DeployFails -Arguments @{
        Action = 'Restore'; GamePath = $gamePath; OutputPath = $outputPath; BackupRoot = $backupRoot
        LegacyDebugModZip = $legacyZip; BackupPath = $badSchemaBackup
    } -ExpectedMessage 'SchemaVersion'

    $teamCherryEntry = @($manifest.Files | Where-Object RelativePath -eq 'TeamCherry.Localization.dll')
    Assert-Equal 1 $teamCherryEntry.Count 'manifest should contain one TeamCherry.Localization entry'
    $teamCherryBackup = Join-Path $backupPath $teamCherryEntry[0].BackupRelativePath
    Add-Content -LiteralPath $teamCherryBackup -Value 'corrupt' -NoNewline
    $installedAssemblyHash = Get-Hash (Join-Path $gamePath 'hollow_knight_Data\Managed\Assembly-CSharp.dll')
    Assert-DeployFails -Arguments @{
        Action = 'Restore'; GamePath = $gamePath; OutputPath = $outputPath; BackupRoot = $backupRoot
        LegacyDebugModZip = $legacyZip; BackupPath = $backupPath
    } -ExpectedMessage 'corrupt'
    Assert-Equal $installedAssemblyHash (Get-Hash (Join-Path $gamePath 'hollow_knight_Data\Managed\Assembly-CSharp.dll')) 'restore preflight failure must not modify earlier files'
    Copy-Item -LiteralPath (Join-Path $vanillaPath 'TeamCherry.Localization.dll') -Destination $teamCherryBackup -Force

    $manifestLock = [IO.File]::Open($manifestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-DeployFails -Arguments @{
            Action = 'Restore'; GamePath = $gamePath; OutputPath = $outputPath; BackupRoot = $backupRoot
            LegacyDebugModZip = $legacyZip; BackupPath = $backupPath
        } -ExpectedMessage 'installed state was recovered'
    }
    finally {
        $manifestLock.Dispose()
    }
    foreach ($entry in @($manifest.Files)) {
        Assert-Equal $entry.InstalledSha256 (Get-Hash (Join-Path $gamePath "hollow_knight_Data\Managed\$($entry.RelativePath)")) "execution failure should roll back '$($entry.RelativePath)'"
    }

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

    $rollbackGame = Join-Path $tempRoot 'rollback-game'
    $rollbackOutput = Join-Path $tempRoot 'rollback-output'
    $rollbackBackups = Join-Path $tempRoot 'rollback-backups'
    New-FakeGame -Path $rollbackGame -VanillaPath $vanillaPath
    New-FakeOutput -Path $rollbackOutput
    $rollbackBlocker = Join-Path $rollbackGame 'hollow_knight_Data\Managed\Mods'
    Set-Content -LiteralPath $rollbackBlocker -Value 'blocks mod directory creation' -NoNewline
    $rollbackAssembly = Join-Path $rollbackGame 'hollow_knight_Data\Managed\Assembly-CSharp.dll'
    $rollbackOriginalHash = Get-Hash $rollbackAssembly

    Assert-DeployFails -Arguments @{
        Action = 'Install'; GamePath = $rollbackGame; OutputPath = $rollbackOutput
        BackupRoot = $rollbackBackups; LegacyDebugModZip = $legacyZip
    } -ExpectedMessage 'rolled back'
    Assert-Equal $rollbackOriginalHash (Get-Hash $rollbackAssembly) 'failed install should restore overwritten files'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackGame 'hollow_knight_Data\Managed\MMHOOK_PlayMaker.dll'))) 'failed install should delete newly added files'
    Assert-True (Test-Path -LiteralPath $rollbackBlocker -PathType Leaf) 'failed install must preserve an unrelated blocking file'

    'PASS: local deployment validation, locking, install, status, drift protection, restore, LocalLow preservation, and rollback'
}
finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $resolvedTempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($resolvedTempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTempRoot)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
