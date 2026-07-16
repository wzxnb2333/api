[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\OutputFinal'),

    [switch]$AssemblyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managedPath = Join-Path $OutputPath 'hollow_knight_Data\Managed'
$assemblyPath = Join-Path $managedPath 'Assembly-CSharp.dll'
$xmlPath = Join-Path $managedPath 'Assembly-CSharp.xml'
$modsPath = Join-Path $managedPath 'Mods'

if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
    throw "缺少 v37 产物: $assemblyPath"
}
if (-not $AssemblyOnly) {
    if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
        throw "缺少 v37 产物: $xmlPath"
    }
    if (-not (Test-Path -LiteralPath $modsPath -PathType Container)) {
        throw "缺少 v37 产物: $modsPath"
    }
}

$cecilPath = Join-Path $PSScriptRoot '..\MonoMod\Mono.Cecil.dll'
[void][System.Reflection.Assembly]::LoadFrom($cecilPath)
$assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($assemblyPath)

try {
    if ($assembly.Name.Name -ne 'Assembly-CSharp' -or $assembly.Name.Version.ToString() -ne '0.0.0.0') {
        throw "产物程序集标识错误: $($assembly.Name.FullName)"
    }

    $types = $assembly.MainModule.Types
    $modHooks = $types | Where-Object FullName -EQ 'Modding.ModHooks'
    $togglableMod = $types | Where-Object FullName -EQ 'Modding.ITogglableMod'
    if ($null -eq $modHooks -or $null -eq $togglableMod -or -not $togglableMod.IsInterface) {
        throw '产物缺少 Modding.ModHooks 或 Modding.ITogglableMod。'
    }

    $versionField = $modHooks.Fields | Where-Object Name -EQ '_modVersion'
    if ($null -eq $versionField -or -not $versionField.HasConstant -or [int]$versionField.Constant -ne 37) {
        throw '产物元数据中的 Modding API 版本不是 37。'
    }

    $requiredEvents = @('BeforePlayerDeadHook', 'CursorHook', 'ColliderCreateHook')
    $eventNames = @($modHooks.Events | ForEach-Object Name)
    $missingEvents = @($requiredEvents | Where-Object { $_ -notin $eventNames })
    if ($missingEvents.Count -ne 0) {
        throw "产物缺少 ABI 事件: $($missingEvents -join ', ')"
    }
}
finally {
    $assembly.Dispose()
}

Write-Output "PASS: Modding API v37 产物及 ABI 验证通过: $assemblyPath"
