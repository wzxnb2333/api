[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'OutputFinal')
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$cecilPath = Join-Path $OutputPath 'Mono.Cecil.dll'
$hooksPath = Join-Path $OutputPath 'MMHOOK_Assembly-CSharp.dll'
$gamePath = Join-Path $OutputPath 'Assembly-CSharp.dll'
foreach ($path in @($cecilPath, $hooksPath, $gamePath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "missing test input '$path'"
}

Add-Type -Path $cecilPath
$resolver = [Mono.Cecil.DefaultAssemblyResolver]::new()
$resolver.AddSearchDirectory([IO.Path]::GetFullPath($OutputPath))
$readerParameters = [Mono.Cecil.ReaderParameters]::new()
$readerParameters.AssemblyResolver = $resolver
$hooks = [Mono.Cecil.ModuleDefinition]::ReadModule([IO.Path]::GetFullPath($hooksPath), $readerParameters)
$game = [Mono.Cecil.ModuleDefinition]::ReadModule([IO.Path]::GetFullPath($gamePath), $readerParameters)
try {
    $hookType = @($hooks.Types | Where-Object { $_.FullName -eq 'On.HeroController' })
    Assert-True ($hookType.Count -eq 1) 'On.HeroController should exist exactly once'

    $hookDelegate = @($hookType[0].NestedTypes | Where-Object { $_.Name -eq 'hook_Invulnerable' })
    Assert-True ($hookDelegate.Count -eq 1) 'unsuffixed hook_Invulnerable should exist exactly once'
    $invoke = @($hookDelegate[0].Methods | Where-Object { $_.Name -eq 'Invoke' })
    Assert-True ($invoke.Count -eq 1) 'hook_Invulnerable should expose exactly one Invoke method'
    Assert-True ($invoke[0].ReturnType.FullName -eq 'System.Collections.IEnumerator') 'hook_Invulnerable should return IEnumerator'

    $actualParameters = @($invoke[0].Parameters | ForEach-Object { "$($_.Name):$($_.ParameterType.FullName)" })
    $expectedParameters = @(
        'orig:On.HeroController/orig_Invulnerable'
        'self:HeroController'
        'duration:System.Single'
    )
    Assert-True (($actualParameters -join '|') -eq ($expectedParameters -join '|')) `
        "hook_Invulnerable should preserve legacy ABI '$($expectedParameters -join ', ')'; found '$($actualParameters -join ', ')'"

    $origDelegate = @($hookType[0].NestedTypes | Where-Object { $_.Name -eq 'orig_Invulnerable' })
    Assert-True ($origDelegate.Count -eq 1) 'unsuffixed orig_Invulnerable should exist exactly once'
    $origInvoke = @($origDelegate[0].Methods | Where-Object { $_.Name -eq 'Invoke' })
    Assert-True ($origInvoke.Count -eq 1) 'orig_Invulnerable should expose exactly one Invoke method'
    $actualOrigParameters = @($origInvoke[0].Parameters | ForEach-Object { "$($_.Name):$($_.ParameterType.FullName)" })
    $expectedOrigParameters = @('self:HeroController', 'duration:System.Single')
    Assert-True ($origInvoke[0].ReturnType.FullName -eq 'System.Collections.IEnumerator') 'orig_Invulnerable should return IEnumerator'
    Assert-True (($actualOrigParameters -join '|') -eq ($expectedOrigParameters -join '|')) `
        "orig_Invulnerable should preserve legacy ABI '$($expectedOrigParameters -join ', ')'; found '$($actualOrigParameters -join ', ')'"

    $suffixedMembers = @($hookType[0].NestedTypes.Name) + @($hookType[0].Methods.Name) + @($hookType[0].Events.Name) |
        Where-Object { $_ -match '^(?:orig_|hook_|add_|remove_)?Invulnerable_[0-9]+$' }
    Assert-True ($suffixedMembers.Count -eq 0) `
        "Invulnerable hook should not expose HookGen overload suffixes; found '$($suffixedMembers -join ', ')'"

    $event = @($hookType[0].Events | Where-Object { $_.Name -eq 'Invulnerable' })
    Assert-True ($event.Count -eq 1) 'unsuffixed Invulnerable event should exist exactly once'
    Assert-True ($event[0].EventType.FullName -eq $hookDelegate[0].FullName) 'Invulnerable event should use hook_Invulnerable'
    Assert-True ($null -ne $event[0].AddMethod -and $event[0].AddMethod.Name -eq 'add_Invulnerable') `
        'Invulnerable event should expose add_Invulnerable'

    $targetTokens = @($event[0].AddMethod.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldtoken -and $_.Operand -is [Mono.Cecil.MethodReference]
    })
    Assert-True ($targetTokens.Count -eq 1) 'add_Invulnerable should contain one method target token'

    $target = $targetTokens[0].Operand.Resolve()
    Assert-True ($null -ne $target) 'add_Invulnerable target should resolve'
    Assert-True ($target.DeclaringType.FullName -eq 'HeroController' -and $target.Name -eq 'Invulnerable') `
        'add_Invulnerable should target HeroController.Invulnerable'
    Assert-True ($target.Parameters.Count -eq 1 -and $target.Parameters[0].ParameterType.FullName -eq 'System.Single') `
        'add_Invulnerable should target the legacy-compatible Invulnerable(float) method'

    $heroType = @($game.Types | Where-Object { $_.FullName -eq 'HeroController' })
    Assert-True ($heroType.Count -eq 1) 'patched Assembly-CSharp should define HeroController exactly once'
    $invulnerableMethods = @($heroType[0].Methods | Where-Object { $_.Name -in @('Invulnerable', 'InvulnerableCore') })
    $gameTarget = @($invulnerableMethods | Where-Object {
        $_.Name -eq 'Invulnerable' -and $_.Parameters.Count -eq 1 -and $_.Parameters[0].ParameterType.FullName -eq 'System.Single'
    })
    Assert-True ($gameTarget.Count -eq 1) 'patched Assembly-CSharp should define exactly one Invulnerable(float) compatibility target'
    $coreTarget = @($invulnerableMethods | Where-Object { $_.Name -eq 'InvulnerableCore' -and $_.Parameters.Count -eq 0 })
    Assert-True ($coreTarget.Count -eq 1) 'patched Assembly-CSharp should define exactly one InvulnerableCore() method'
    Assert-True ($invulnerableMethods.Count -eq 2) 'patched Assembly-CSharp should only define Invulnerable(float) and InvulnerableCore()'
    Assert-True ($gameTarget[0].ReturnType.FullName -eq 'System.Collections.IEnumerator' -and
        $coreTarget[0].ReturnType.FullName -eq 'System.Collections.IEnumerator') `
        'Invulnerable(float) and InvulnerableCore() should return IEnumerator'
    Assert-True ($target.FullName -eq $gameTarget[0].FullName) 'add_Invulnerable should resolve to patched Assembly-CSharp compatibility target'

    $durationField = @($heroType[0].Fields | Where-Object { $_.Name -eq 'invulnerableDuration' -and $_.FieldType.FullName -eq 'System.Single' })
    Assert-True ($durationField.Count -eq 1) 'HeroController should expose one float invulnerableDuration field'
    $wrapperInstructions = @($gameTarget[0].Body.Instructions)
    $durationStores = @($wrapperInstructions | Where-Object {
        $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Stfld -and $_.Operand -is [Mono.Cecil.FieldReference] -and
        $_.Operand.Name -eq 'invulnerableDuration'
    })
    $coreCalls = @($wrapperInstructions | Where-Object {
        $_.OpCode.Code -in @([Mono.Cecil.Cil.Code]::Call, [Mono.Cecil.Cil.Code]::Callvirt) -and
        $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'InvulnerableCore'
    })
    Assert-True ($durationStores.Count -eq 1) 'Invulnerable(float) should store invulnerableDuration exactly once'
    Assert-True ($coreCalls.Count -eq 1) 'Invulnerable(float) should call InvulnerableCore() exactly once'
    $durationStoreIndex = [array]::IndexOf($wrapperInstructions, $durationStores[0])
    $coreCallIndex = [array]::IndexOf($wrapperInstructions, $coreCalls[0])
    Assert-True ($durationStoreIndex -lt $coreCallIndex) 'Invulnerable(float) should store invulnerableDuration before calling InvulnerableCore()'
    $wrapperDurationLoad = $wrapperInstructions[$durationStoreIndex - 1]
    $wrapperLoadsDuration = $wrapperDurationLoad.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldarg_1 -or
        ($wrapperDurationLoad.OpCode.Code -in @([Mono.Cecil.Cil.Code]::Ldarg, [Mono.Cecil.Cil.Code]::Ldarg_S) -and
            $wrapperDurationLoad.Operand -eq $gameTarget[0].Parameters[0])
    Assert-True ($wrapperLoadsDuration) 'Invulnerable(float) should store its duration argument in invulnerableDuration'

    $startTarget = @($heroType[0].Methods | Where-Object {
        $_.Name -eq 'StartInvulnerable' -and $_.Parameters.Count -eq 1 -and $_.Parameters[0].ParameterType.FullName -eq 'System.Single'
    })
    Assert-True ($startTarget.Count -eq 1) 'HeroController should define exactly one StartInvulnerable(float) method'
    Assert-True ($startTarget[0].Body.MaxStackSize -ge 4) 'StartInvulnerable(float) should reserve a stack size of at least four'
    $startInstructions = @($startTarget[0].Body.Instructions)
    $wrapperCalls = @($startInstructions | Where-Object {
        $_.OpCode.Code -in @([Mono.Cecil.Cil.Code]::Call, [Mono.Cecil.Cil.Code]::Callvirt) -and
        $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'Invulnerable' -and
        $_.Operand.Parameters.Count -eq 1 -and $_.Operand.Parameters[0].ParameterType.FullName -eq 'System.Single'
    })
    Assert-True ($wrapperCalls.Count -eq 1) 'StartInvulnerable(float) should call Invulnerable(float) exactly once'
    $wrapperCallIndex = [array]::IndexOf($startInstructions, $wrapperCalls[0])
    $startDurationLoad = $startInstructions[$wrapperCallIndex - 1]
    $startLoadsDuration = $startDurationLoad.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldarg_1 -or
        ($startDurationLoad.OpCode.Code -in @([Mono.Cecil.Cil.Code]::Ldarg, [Mono.Cecil.Cil.Code]::Ldarg_S) -and
            $startDurationLoad.Operand -eq $startTarget[0].Parameters[0])
    Assert-True ($startLoadsDuration) 'StartInvulnerable(float) should load duration immediately before calling Invulnerable(float)'
}
finally {
    $game.Dispose()
    $hooks.Dispose()
    $resolver.Dispose()
}

'PASS: legacy Invulnerable(float) hook ABI preserved'
