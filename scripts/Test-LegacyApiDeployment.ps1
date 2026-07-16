[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VanillaManagedPath,

    [string]$OutputPath = (Join-Path $PSScriptRoot '..\OutputFinal')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$deployScript = Join-Path $PSScriptRoot 'Deploy-LegacyApi.ps1'
$verifyScript = Join-Path $PSScriptRoot 'Verify-LegacyApi.ps1'
if (-not (Test-Path -LiteralPath $deployScript)) {
    throw "缺少部署脚本: $deployScript"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "hk-api-deploy-$([guid]::NewGuid().ToString('N'))"
$gamePath = Join-Path $tempRoot 'game'
$managedPath = Join-Path $gamePath 'hollow_knight_Data\Managed'
$backupRoot = Join-Path $tempRoot 'backups'
$localLowPath = Join-Path $tempRoot 'LocalLow\Team Cherry\Hollow Knight'
$originalAssembly = Join-Path $VanillaManagedPath 'Assembly-CSharp.dll'

try {
    New-Item -ItemType Directory -Path $managedPath, $localLowPath -Force | Out-Null
    Copy-Item -LiteralPath $originalAssembly -Destination $managedPath
    Set-Content -LiteralPath (Join-Path $localLowPath 'user1.dat') -Value 'before-install' -NoNewline

    $invalidManagedPath = Join-Path $tempRoot 'invalid-output\hollow_knight_Data\Managed'
    New-Item -ItemType Directory -Path $invalidManagedPath -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $OutputPath 'hollow_knight_Data\Managed\Assembly-CSharp.dll') -Destination $invalidManagedPath
    Copy-Item -LiteralPath (Join-Path $OutputPath 'hollow_knight_Data\Managed\Assembly-CSharp.xml') -Destination $invalidManagedPath
    Set-Content -LiteralPath (Join-Path $invalidManagedPath 'Mods') -Value 'not-a-directory'
    $verificationFailed = $false
    try { & $verifyScript -OutputPath (Join-Path $tempRoot 'invalid-output') }
    catch { $verificationFailed = $true }
    if (-not $verificationFailed) { throw 'Verify 未拒绝文件类型的 Mods。' }
    Remove-Item -LiteralPath (Join-Path $invalidManagedPath 'Mods') -Force
    New-Item -ItemType Directory -Path (Join-Path $invalidManagedPath 'Mods') | Out-Null
    foreach ($leafName in @('Assembly-CSharp.xml', 'Assembly-CSharp.dll')) {
        $leafPath = Join-Path $invalidManagedPath $leafName
        Remove-Item -LiteralPath $leafPath -Force
        New-Item -ItemType Directory -Path $leafPath | Out-Null
        $verificationFailed = $false
        try { & $verifyScript -OutputPath (Join-Path $tempRoot 'invalid-output') }
        catch { $verificationFailed = $true }
        if (-not $verificationFailed) { throw "Verify 未拒绝目录类型的 $leafName。" }
        Remove-Item -LiteralPath $leafPath -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $OutputPath "hollow_knight_Data\Managed\$leafName") -Destination $leafPath
    }

    $status = & $deployScript -Action Status -GamePath $gamePath -OutputPath $OutputPath -BackupRoot $backupRoot -LocalLowPath $localLowPath | Out-String
    if ($status -notmatch 'Vanilla') { throw "安装前状态错误: $status" }

    & $deployScript -Action Install -GamePath $gamePath -OutputPath $OutputPath -BackupRoot $backupRoot -LocalLowPath $localLowPath
    $installedHash = (Get-FileHash -LiteralPath (Join-Path $managedPath 'Assembly-CSharp.dll') -Algorithm SHA256).Hash
    $outputHash = (Get-FileHash -LiteralPath (Join-Path $OutputPath 'hollow_knight_Data\Managed\Assembly-CSharp.dll') -Algorithm SHA256).Hash
    if ($installedHash -ne $outputHash) { throw 'Install 未写入 API 程序集。' }

    $backupDirectory = @(Get-ChildItem -LiteralPath $backupRoot -Directory)
    if ($backupDirectory.Count -ne 1) { throw 'Install 未创建唯一时间戳备份。' }
    foreach ($relativePath in @('Managed\Assembly-CSharp.dll', 'LocalLow\user1.dat', 'SHA256SUMS.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $backupDirectory[0].FullName $relativePath))) {
            throw "备份缺少: $relativePath"
        }
    }

    Set-Content -LiteralPath (Join-Path $localLowPath 'user1.dat') -Value 'after-install' -NoNewline
    $status = & $deployScript -Action Status -GamePath $gamePath -OutputPath $OutputPath -BackupRoot $backupRoot -LocalLowPath $localLowPath | Out-String
    if ($status -notmatch 'Modding API v37') { throw "安装后状态错误: $status" }

    $nonV37ManagedPath = Join-Path $tempRoot 'non-v37-output\hollow_knight_Data\Managed'
    New-Item -ItemType Directory -Path (Join-Path $nonV37ManagedPath 'Mods') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\MonoMod\Mono.Cecil.dll') -Destination (Join-Path $managedPath 'Assembly-CSharp.dll') -Force
    Copy-Item -LiteralPath (Join-Path $managedPath 'Assembly-CSharp.dll') -Destination (Join-Path $nonV37ManagedPath 'Assembly-CSharp.dll')
    Copy-Item -LiteralPath (Join-Path $managedPath 'Assembly-CSharp.xml') -Destination (Join-Path $nonV37ManagedPath 'Assembly-CSharp.xml')
    $status = & $deployScript -Action Status -GamePath $gamePath -OutputPath (Join-Path $tempRoot 'non-v37-output') -BackupRoot $backupRoot -LocalLowPath $localLowPath | Out-String
    if ($status -notmatch 'State: Unknown') { throw "非 v37 程序集状态错误: $status" }
    Copy-Item -LiteralPath (Join-Path $OutputPath 'hollow_knight_Data\Managed\Assembly-CSharp.dll') -Destination (Join-Path $managedPath 'Assembly-CSharp.dll') -Force

    Remove-Item -LiteralPath (Join-Path $managedPath 'Assembly-CSharp.xml') -Force
    Remove-Item -LiteralPath (Join-Path $managedPath 'Mods') -Recurse -Force
    $status = & $deployScript -Action Status -GamePath $gamePath -OutputPath (Join-Path $tempRoot 'missing-output') -BackupRoot $backupRoot -LocalLowPath $localLowPath | Out-String
    if ($status -notmatch 'Modding API v37') { throw "Status 依赖构建输出哈希而非已安装程序集元数据: $status" }
    Copy-Item -LiteralPath (Join-Path $OutputPath 'hollow_knight_Data\Managed\Assembly-CSharp.xml') -Destination $managedPath
    New-Item -ItemType Directory -Path (Join-Path $managedPath 'Mods') | Out-Null

    $backupAssembly = Join-Path $backupDirectory[0].FullName 'Managed\Assembly-CSharp.dll'
    Set-Content -LiteralPath $backupAssembly -Value 'corrupted-backup' -NoNewline
    $restoreFailed = $false
    try {
        & $deployScript -Action Restore -GamePath $gamePath -OutputPath $OutputPath -BackupRoot $backupRoot -LocalLowPath $localLowPath
    }
    catch {
        $restoreFailed = $true
    }
    if (-not $restoreFailed) { throw 'Restore 未拒绝损坏备份。' }
    if ((Get-FileHash -LiteralPath (Join-Path $managedPath 'Assembly-CSharp.dll') -Algorithm SHA256).Hash -ne $installedHash) {
        throw 'Restore 校验失败后修改了游戏程序集。'
    }
    Copy-Item -LiteralPath $originalAssembly -Destination $backupAssembly -Force

    & $deployScript -Action Restore -GamePath $gamePath -OutputPath $OutputPath -BackupRoot $backupRoot -LocalLowPath $localLowPath
    $restoredHash = (Get-FileHash -LiteralPath (Join-Path $managedPath 'Assembly-CSharp.dll') -Algorithm SHA256).Hash
    $originalHash = (Get-FileHash -LiteralPath $originalAssembly -Algorithm SHA256).Hash
    if ($restoredHash -ne $originalHash) { throw 'Restore 未恢复原版程序集。' }
    foreach ($relativePath in @('Assembly-CSharp.xml', 'Mods')) {
        if (Test-Path -LiteralPath (Join-Path $managedPath $relativePath)) {
            throw "Restore 未删除此次新增项: $relativePath"
        }
    }
    if ((Get-Content -LiteralPath (Join-Path $localLowPath 'user1.dat') -Raw) -ne 'after-install') {
        throw 'Restore 覆盖了安装后 LocalLow 数据。'
    }
    if (Test-Path -LiteralPath (Join-Path $backupRoot 'current-install.json')) {
        throw 'Restore 未清理当前安装状态。'
    }

    $status = & $deployScript -Action Status -GamePath $gamePath -OutputPath $OutputPath -BackupRoot $backupRoot -LocalLowPath $localLowPath | Out-String
    if ($status -notmatch 'Vanilla') { throw "恢复后状态错误: $status" }
    Write-Output 'PASS: Status/Install/Restore 沙箱验证通过。'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
