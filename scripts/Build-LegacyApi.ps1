[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManagedPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedVanillaHash = 'B9884474B5662871C3AA1AF76D9C9E61FC3D930700738E45DB0ADF8FB3CBE728'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managedPath = [System.IO.Path]::GetFullPath($ManagedPath)
$vanillaPath = Join-Path $repoRoot 'Vanilla'
$binPath = Join-Path $repoRoot 'Assembly-CSharp\bin\Debug'
$outputPath = Join-Path $repoRoot 'OutputFinal'

function Assert-WorkspacePath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repoRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝修改工作区外路径: $fullPath"
    }
}

foreach ($path in @($vanillaPath, $binPath, $outputPath)) {
    Assert-WorkspacePath $path
}

$vanillaAssembly = Join-Path $managedPath 'Assembly-CSharp.dll'
if (-not (Test-Path -LiteralPath $vanillaAssembly)) {
    throw "找不到原版程序集: $vanillaAssembly"
}
$vanillaHash = (Get-FileHash -LiteralPath $vanillaAssembly -Algorithm SHA256).Hash
if ($vanillaHash -ne $expectedVanillaHash) {
    throw "原版 Assembly-CSharp.dll 哈希不匹配。实际: $vanillaHash"
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw '找不到 Visual Studio Installer 的 vswhere.exe。'
}
$visualStudioPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
$msbuild = Join-Path $visualStudioPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "找不到 MSBuild: $msbuild"
}

foreach ($path in @($vanillaPath, $binPath, $outputPath)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $vanillaPath | Out-Null
Get-ChildItem -LiteralPath $managedPath -File | Copy-Item -Destination $vanillaPath

$solution = Join-Path $repoRoot 'HollowKnight.Modding.API.sln'
$buildArguments = @(
    $solution,
    '/t:Rebuild',
    '/p:Configuration=Debug',
    '/p:Platform=Any CPU',
    '/p:PreBuildEvent=',
    '/p:PostBuildEvent=',
    '/v:minimal',
    '/nologo'
)
& $msbuild @buildArguments
if ($LASTEXITCODE -ne 0) {
    throw "MSBuild 失败，退出码: $LASTEXITCODE"
}

$patchAssembly = Join-Path $binPath 'Assembly-CSharp.mm.dll'
if (-not (Test-Path -LiteralPath $patchAssembly)) {
    throw "MSBuild 未生成补丁程序集: $patchAssembly"
}
Move-Item -LiteralPath $patchAssembly -Destination (Join-Path $binPath 'Assembly-CSharp.dll.mm.dll')
$patchPdb = Join-Path $binPath 'Assembly-CSharp.mm.pdb'
if (Test-Path -LiteralPath $patchPdb) {
    Move-Item -LiteralPath $patchPdb -Destination (Join-Path $binPath 'Assembly-CSharp.dll.mm.pdb')
}
Get-ChildItem -LiteralPath $vanillaPath -File | Copy-Item -Destination $binPath
Get-ChildItem -LiteralPath (Join-Path $repoRoot 'MonoMod') -File | Copy-Item -Destination $binPath

Push-Location $binPath
try {
    & (Join-Path $binPath 'MonoMod.exe') 'Assembly-CSharp.dll'
    if ($LASTEXITCODE -ne 0) {
        throw "MonoMod 失败，退出码: $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$outputManaged = Join-Path $outputPath 'hollow_knight_Data\Managed'
New-Item -ItemType Directory -Path (Join-Path $outputManaged 'Mods') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $binPath 'MONOMODDED_Assembly-CSharp.dll') -Destination (Join-Path $outputManaged 'Assembly-CSharp.dll')

$sourceXml = Join-Path $binPath 'Assembly-CSharp.mm.xml'
$outputXml = Join-Path $outputManaged 'Assembly-CSharp.xml'
$xml = [System.IO.File]::ReadAllText($sourceXml).Replace('Assembly-CSharp.mm', 'Assembly-CSharp')
[System.IO.File]::WriteAllText($outputXml, $xml, [System.Text.UTF8Encoding]::new($false))

& (Join-Path $PSScriptRoot 'Verify-LegacyApi.ps1') -OutputPath $outputPath
