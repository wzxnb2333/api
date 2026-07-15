[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'OutputFinal'),
    [switch]$VerifyIdempotence
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Invoke-PrePatcher {
    param([string]$Executable, [string]$TargetPath, [string]$SourcePath)

    if ($IsWindows) {
        & $Executable --mmhook $TargetPath $SourcePath
        return
    }

    $mono = Get-Command mono -CommandType Application -ErrorAction SilentlyContinue
    if (-not $mono) {
        throw 'mono is required to run PrePatcher.exe on non-Windows platforms.'
    }

    & $mono.Source $Executable --mmhook $TargetPath $SourcePath
}

function Get-ForwarderCount {
    param([string]$TargetPath, [string]$SourcePath)

    $target = [Mono.Cecil.ModuleDefinition]::ReadModule($TargetPath)
    $source = [Mono.Cecil.ModuleDefinition]::ReadModule($SourcePath)
    try {
        $sourceTypes = @($source.Types | Where-Object {
            $sourceType = $_
            $sourceType.IsPublic -and -not $sourceType.IsNested -and
            ($sourceType.Namespace -eq 'On' -or $sourceType.Namespace -like 'On.*' -or
                $sourceType.Namespace -eq 'IL' -or $sourceType.Namespace -like 'IL.*') -and
            -not ($target.Types | Where-Object { $_.Namespace -eq $sourceType.Namespace -and $_.Name -eq $sourceType.Name })
        })
        Assert-True ($sourceTypes.Count -gt 0) "$(Split-Path $SourcePath -Leaf) should expose public top-level On/IL types"

        $sourceAssemblyName = $source.Assembly.Name.Name
        $forwarders = @($target.ExportedTypes | Where-Object {
            ($_.Attributes -band [Mono.Cecil.TypeAttributes]::Forwarder) -ne 0 -and
            $_.Scope -is [Mono.Cecil.AssemblyNameReference] -and
            $_.Scope.Name -eq $sourceAssemblyName
        })

        foreach ($type in $sourceTypes) {
            $matches = @($forwarders | Where-Object { $_.Namespace -eq $type.Namespace -and $_.Name -eq $type.Name })
            Assert-True ($matches.Count -eq 1) "MMHOOK_Assembly-CSharp.dll should forward $($type.FullName) exactly once to $sourceAssemblyName"
        }
        $sourceTypes.Count
    }
    finally {
        $source.Dispose()
        $target.Dispose()
    }
}

$cecilPath = Join-Path $OutputPath 'Mono.Cecil.dll'
$targetPath = Join-Path $OutputPath 'MMHOOK_Assembly-CSharp.dll'
$sourceNames = @('MMHOOK_TeamCherry.TK2D.dll', 'MMHOOK_TeamCherry.Cinematics.dll')
foreach ($path in @($cecilPath, $targetPath) + @($sourceNames | ForEach-Object { Join-Path $OutputPath $_ })) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "missing test input '$path'"
}

Add-Type -Path $cecilPath
$counts = [ordered]@{}
foreach ($sourceName in $sourceNames) {
    $counts[$sourceName] = Get-ForwarderCount -TargetPath $targetPath -SourcePath (Join-Path $OutputPath $sourceName)
}

if ($VerifyIdempotence) {
    $prePatcher = [IO.Path]::Combine((Split-Path $PSScriptRoot -Parent), 'PrePatcher', 'Output', 'PrePatcher.exe')
    Assert-True (Test-Path -LiteralPath $prePatcher -PathType Leaf) "missing PrePatcher '$prePatcher'"
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("hk-mmhook-forwarder-test-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        Copy-Item -LiteralPath $targetPath,$cecilPath -Destination $tempRoot
        foreach ($sourceName in $sourceNames) {
            Copy-Item -LiteralPath (Join-Path $OutputPath $sourceName) -Destination $tempRoot
        }

        $copyTarget = Join-Path $tempRoot 'MMHOOK_Assembly-CSharp.dll'
        foreach ($sourceName in $sourceNames) {
            Invoke-PrePatcher -Executable $prePatcher -TargetPath $copyTarget -SourcePath (Join-Path $tempRoot $sourceName)
            Assert-True ($LASTEXITCODE -eq 0) "first idempotence pass should succeed for $sourceName"
        }
        $firstHash = (Get-FileHash -LiteralPath $copyTarget -Algorithm SHA256).Hash
        foreach ($sourceName in $sourceNames) {
            Invoke-PrePatcher -Executable $prePatcher -TargetPath $copyTarget -SourcePath (Join-Path $tempRoot $sourceName)
            Assert-True ($LASTEXITCODE -eq 0) "second idempotence pass should succeed for $sourceName"
        }
        $secondHash = (Get-FileHash -LiteralPath $copyTarget -Algorithm SHA256).Hash
        Assert-True ($firstHash -eq $secondHash) 'second forwarder pass should not rewrite the target'
    }
    finally {
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}

$summary = $counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
"PASS: MMHOOK forwarders present ($($summary -join ', '))"
