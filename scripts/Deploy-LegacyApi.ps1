[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Status', 'Install', 'Restore')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$GamePath,

    [string]$OutputPath = (Join-Path $PSScriptRoot '..\OutputFinal'),

    [string]$BackupRoot = (Join-Path $PSScriptRoot '..\..\HollowKnight.DebugMod-backups'),

    [string]$LocalLowPath = (Join-Path $env:USERPROFILE 'AppData\LocalLow\Team Cherry\Hollow Knight')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedVanillaHash = 'B9884474B5662871C3AA1AF76D9C9E61FC3D930700738E45DB0ADF8FB3CBE728'
$gamePath = [System.IO.Path]::GetFullPath($GamePath)
$outputPath = [System.IO.Path]::GetFullPath($OutputPath)
$backupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
$localLowPath = [System.IO.Path]::GetFullPath($LocalLowPath)
$managedPath = Join-Path $gamePath 'hollow_knight_Data\Managed'
$outputManagedPath = Join-Path $outputPath 'hollow_knight_Data\Managed'
$gameAssembly = Join-Path $managedPath 'Assembly-CSharp.dll'
$outputAssembly = Join-Path $outputManagedPath 'Assembly-CSharp.dll'
$currentStatePath = Join-Path $backupRoot 'current-install.json'

function Get-SafeChildPath([string]$BasePath, [string]$RelativePath) {
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "拒绝绝对相对路径: $RelativePath"
    }
    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $child = [System.IO.Path]::GetFullPath((Join-Path $base $RelativePath))
    if (-not $child.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径超出允许目录: $RelativePath"
    }
    return $child
}

function Assert-GameClosed {
    if (Get-Process -Name 'hollow_knight' -ErrorAction SilentlyContinue) {
        throw 'Hollow Knight 正在运行，请关闭游戏后重试。'
    }
}

function Get-HashOrMissing([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'Missing' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到安装状态: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile([string]$Path, [object]$Value) {
    $json = $Value | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Assert-BackupIntegrity([string]$BackupPath) {
    $manifestPath = Join-Path $BackupPath 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "备份缺少 SHA-256 清单: $manifestPath"
    }

    $entries = @{}
    foreach ($line in @(Get-Content -LiteralPath $manifestPath)) {
        if ($line -notmatch '^(?<Hash>[0-9A-Fa-f]{64}) \*(?<Path>.+)$') {
            throw "备份 SHA-256 清单格式错误: $line"
        }
        $relativePath = [string]$Matches.Path
        if ($entries.ContainsKey($relativePath)) {
            throw "备份 SHA-256 清单含重复路径: $relativePath"
        }
        $file = Get-SafeChildPath $BackupPath $relativePath
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "备份清单文件不存在: $relativePath"
        }
        $actualHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($actualHash -ne $Matches.Hash) {
            throw "备份文件 SHA-256 不匹配: $relativePath"
        }
        $entries[$relativePath] = $actualHash
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $BackupPath -File -Recurse)) {
        if ($file.FullName -eq $manifestPath) { continue }
        $relativePath = $file.FullName.Substring($BackupPath.Length).TrimStart('\')
        if (-not $entries.ContainsKey($relativePath)) {
            throw "备份文件未记录于 SHA-256 清单: $relativePath"
        }
    }

    $assemblyPath = 'Managed\Assembly-CSharp.dll'
    if (-not $entries.ContainsKey($assemblyPath) -or $entries[$assemblyPath] -ne $expectedVanillaHash) {
        throw '备份 Assembly-CSharp.dll 不是指定原版。'
    }
}

function Show-Status {
    $gameHash = Get-HashOrMissing $gameAssembly
    $apiHash = Get-HashOrMissing $outputAssembly
    $isV37 = $false
    if ($gameHash -ne $expectedVanillaHash -and $gameHash -ne 'Missing') {
        try {
            $null = & (Join-Path $PSScriptRoot 'Verify-LegacyApi.ps1') -OutputPath $gamePath -AssemblyOnly
            $isV37 = $true
        }
        catch {}
    }
    $state = if ($gameHash -eq $expectedVanillaHash) {
        'Vanilla'
    }
    elseif ($gameHash -eq 'Missing') {
        'Missing'
    }
    elseif ($isV37) {
        'Modding API v37'
    }
    else {
        'Unknown'
    }

    Write-Output "State: $state"
    Write-Output "Assembly-CSharp.dll SHA-256: $gameHash"
    Write-Output "Vanilla SHA-256: $expectedVanillaHash"
    Write-Output "API SHA-256: $apiHash"
    Write-Output "Active backup: $(if (Test-Path -LiteralPath $currentStatePath) { $currentStatePath } else { 'None' })"
}

function Install-Api {
    Assert-GameClosed
    & (Join-Path $PSScriptRoot 'Verify-LegacyApi.ps1') -OutputPath $outputPath
    if (-not (Test-Path -LiteralPath $managedPath -PathType Container)) {
        throw "找不到游戏 Managed 目录: $managedPath"
    }

    $apiHash = Get-HashOrMissing $outputAssembly
    if (Test-Path -LiteralPath $currentStatePath -PathType Leaf) {
        $marker = Read-JsonFile $currentStatePath
        if ([System.IO.Path]::GetFullPath([string]$marker.GamePath) -ne $gamePath) {
            throw "当前备份属于其他游戏目录: $($marker.GamePath)"
        }
        if ((Get-HashOrMissing $gameAssembly) -ne $apiHash) {
            throw '已有安装状态，但游戏程序集与当前 API 不一致；请先 Restore。'
        }
    }
    else {
        $gameHash = Get-HashOrMissing $gameAssembly
        if ($gameHash -ne $expectedVanillaHash) {
            throw "安装前程序集不是指定原版。实际: $gameHash"
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $backupPath = Join-Path $backupRoot "1.2.2.1-$timestamp"
        $backupManagedPath = Join-Path $backupPath 'Managed'
        $backupLocalLowPath = Join-Path $backupPath 'LocalLow'
        New-Item -ItemType Directory -Path $backupManagedPath, $backupLocalLowPath -Force | Out-Null

        $preExistingFiles = [System.Collections.Generic.List[string]]::new()
        $newFiles = [System.Collections.Generic.List[string]]::new()
        $createdDirectories = [System.Collections.Generic.List[string]]::new()
        $outputFiles = @(Get-ChildItem -LiteralPath $outputManagedPath -File -Recurse)
        foreach ($source in $outputFiles) {
            $relativePath = $source.FullName.Substring($outputManagedPath.Length).TrimStart('\')
            $target = Get-SafeChildPath $managedPath $relativePath
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $preExistingFiles.Add($relativePath)
                $backupFile = Get-SafeChildPath $backupManagedPath $relativePath
                New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $target -Destination $backupFile
            }
            else {
                $newFiles.Add($relativePath)
            }
        }
        foreach ($sourceDirectory in @(Get-ChildItem -LiteralPath $outputManagedPath -Directory -Recurse)) {
            $relativePath = $sourceDirectory.FullName.Substring($outputManagedPath.Length).TrimStart('\')
            if (-not (Test-Path -LiteralPath (Get-SafeChildPath $managedPath $relativePath))) {
                $createdDirectories.Add($relativePath)
            }
        }

        $localLowExisted = Test-Path -LiteralPath $localLowPath -PathType Container
        if ($localLowExisted) {
            Get-ChildItem -LiteralPath $localLowPath -Force | Copy-Item -Destination $backupLocalLowPath -Recurse -Force
        }

        $state = [ordered]@{
            Version = 1
            GamePath = $gamePath
            BackupPath = $backupPath
            PreExistingFiles = @($preExistingFiles)
            NewFiles = @($newFiles)
            CreatedDirectories = @($createdDirectories)
            LocalLowExisted = $localLowExisted
        }
        Write-JsonFile (Join-Path $backupPath 'install-state.json') $state
        $manifestLines = foreach ($file in @(Get-ChildItem -LiteralPath $backupPath -File -Recurse)) {
            $relativePath = $file.FullName.Substring($backupPath.Length).TrimStart('\')
            '{0} *{1}' -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash, $relativePath
        }
        [System.IO.File]::WriteAllLines((Join-Path $backupPath 'SHA256SUMS.txt'), $manifestLines, [System.Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Write-JsonFile $currentStatePath ([ordered]@{ GamePath = $gamePath; BackupPath = $backupPath })
    }

    foreach ($sourceDirectory in @(Get-ChildItem -LiteralPath $outputManagedPath -Directory -Recurse)) {
        $relativePath = $sourceDirectory.FullName.Substring($outputManagedPath.Length).TrimStart('\')
        New-Item -ItemType Directory -Path (Get-SafeChildPath $managedPath $relativePath) -Force | Out-Null
    }
    foreach ($source in @(Get-ChildItem -LiteralPath $outputManagedPath -File -Recurse)) {
        $relativePath = $source.FullName.Substring($outputManagedPath.Length).TrimStart('\')
        $target = Get-SafeChildPath $managedPath $relativePath
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source.FullName -Destination $target -Force
    }

    if ((Get-HashOrMissing $gameAssembly) -ne $apiHash) {
        throw '安装后程序集哈希与构建产物不一致。'
    }
    Write-Output "Installed: Modding API v37 ($apiHash)"
}

function Restore-Vanilla {
    Assert-GameClosed
    $marker = Read-JsonFile $currentStatePath
    if ([System.IO.Path]::GetFullPath([string]$marker.GamePath) -ne $gamePath) {
        throw "当前备份属于其他游戏目录: $($marker.GamePath)"
    }
    $backupPath = [System.IO.Path]::GetFullPath([string]$marker.BackupPath)
    $backupPrefix = $backupRoot.TrimEnd('\') + '\'
    if (-not $backupPath.StartsWith($backupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "备份路径超出备份根目录: $backupPath"
    }
    Assert-BackupIntegrity $backupPath
    $state = Read-JsonFile (Join-Path $backupPath 'install-state.json')
    $backupManagedPath = Join-Path $backupPath 'Managed'

    foreach ($relativePath in @($state.PreExistingFiles)) {
        $source = Get-SafeChildPath $backupManagedPath ([string]$relativePath)
        $target = Get-SafeChildPath $managedPath ([string]$relativePath)
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    foreach ($relativePath in @($state.NewFiles)) {
        $target = Get-SafeChildPath $managedPath ([string]$relativePath)
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    $directories = @($state.CreatedDirectories) | Sort-Object { ([string]$_).Length } -Descending
    foreach ($relativePath in $directories) {
        $target = Get-SafeChildPath $managedPath ([string]$relativePath)
        if ((Test-Path -LiteralPath $target -PathType Container) -and -not (Get-ChildItem -LiteralPath $target -Force)) {
            Remove-Item -LiteralPath $target -Force
        }
    }

    $restoredHash = Get-HashOrMissing $gameAssembly
    if ($restoredHash -ne $expectedVanillaHash) {
        throw "Restore 后原版哈希不匹配。实际: $restoredHash"
    }
    Remove-Item -LiteralPath $currentStatePath -Force
    Write-Output "Restored: Vanilla ($restoredHash)"
}

switch ($Action) {
    'Status' { Show-Status }
    'Install' { Install-Api }
    'Restore' { Restore-Vanilla }
}
