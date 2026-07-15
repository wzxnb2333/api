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
$gamePath = Join-Path $OutputPath 'Assembly-CSharp.dll'
foreach ($path in @($cecilPath, $gamePath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "missing test input '$path'"
}

Add-Type -Path $cecilPath
$game = [Mono.Cecil.ModuleDefinition]::ReadModule([IO.Path]::GetFullPath($gamePath))
try {
    $gameManager = @($game.Types | Where-Object { $_.FullName -eq 'GameManager' })
    Assert-True ($gameManager.Count -eq 1) 'GameManager should exist exactly once'

    $levelActivated = @($gameManager[0].Methods | Where-Object {
        $_.Name -eq 'LevelActivated' -and $_.ReturnType.FullName -eq 'System.Void' -and
        $_.Parameters.Count -eq 2 -and
        $_.Parameters[0].ParameterType.FullName -eq 'UnityEngine.SceneManagement.Scene' -and
        $_.Parameters[1].ParameterType.FullName -eq 'UnityEngine.SceneManagement.Scene'
    })
    Assert-True ($levelActivated.Count -eq 1) 'GameManager.LevelActivated(Scene, Scene) should exist exactly once'

    $instructions = @($levelActivated[0].Body.Instructions)
    $quitStringIndex = -1
    for ($index = 0; $index -lt $instructions.Count; $index++) {
        if ($instructions[$index].OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldstr -and
            $instructions[$index].Operand -eq 'Quit_To_Menu') {
            $quitStringIndex = $index
            break
        }
    }
    Assert-True ($quitStringIndex -ge 2) 'LevelActivated should guard sceneTo.name == "Quit_To_Menu" before running the original implementation'

    $sceneNameCall = $instructions[$quitStringIndex - 1]
    $sceneToLoad = $instructions[$quitStringIndex - 2]
    Assert-True ($sceneNameCall.Operand -is [Mono.Cecil.MethodReference] -and
        $sceneNameCall.Operand.DeclaringType.FullName -eq 'UnityEngine.SceneManagement.Scene' -and
        $sceneNameCall.Operand.Name -eq 'get_name') 'Quit_To_Menu guard should read Scene.name'
    Assert-True ($sceneToLoad.OpCode.Code -in @([Mono.Cecil.Cil.Code]::Ldarga, [Mono.Cecil.Cil.Code]::Ldarga_S) -and
        $sceneToLoad.Operand -is [Mono.Cecil.ParameterDefinition] -and
        $sceneToLoad.Operand.Index -eq 1) 'Quit_To_Menu guard should inspect the sceneTo parameter'

    $comparison = $instructions[$quitStringIndex + 1]
    $normalBranch = $instructions[$quitStringIndex + 2]
    Assert-True ($comparison.Operand -is [Mono.Cecil.MethodReference] -and
        $comparison.Operand.DeclaringType.FullName -eq 'System.String' -and
        $comparison.Operand.Name -eq 'op_Equality') 'Quit_To_Menu guard should compare Scene.name by value'
    Assert-True ($normalBranch.OpCode.Code -in @([Mono.Cecil.Cil.Code]::Brfalse, [Mono.Cecil.Cil.Code]::Brfalse_S) -and
        $normalBranch.Operand -is [Mono.Cecil.Cil.Instruction]) 'non-menu scenes should branch to the original implementation'

    $normalTargetIndex = [Array]::IndexOf($instructions, $normalBranch.Operand)
    Assert-True ($normalTargetIndex -gt ($quitStringIndex + 2)) 'Quit_To_Menu guard should branch forward for normal scenes'
    $earlyReturns = @($instructions[($quitStringIndex + 3)..($normalTargetIndex - 1)] | Where-Object {
        $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ret
    })
    Assert-True ($earlyReturns.Count -eq 1) 'Quit_To_Menu should return before running the original LevelActivated implementation'

    $origCallIndex = -1
    for ($index = $normalTargetIndex; $index -lt $instructions.Count; $index++) {
        $operand = $instructions[$index].Operand
        if ($operand -is [Mono.Cecil.MethodReference] -and
            $operand.DeclaringType.FullName -eq 'GameManager' -and
            $operand.Name -eq 'orig_LevelActivated' -and
            $operand.Parameters.Count -eq 2) {
            $origCallIndex = $index
            break
        }
    }
    Assert-True ($origCallIndex -ge $normalTargetIndex) 'normal scenes should call orig_LevelActivated(Scene, Scene)'
    $normalPathReturns = @($instructions[$normalTargetIndex..($origCallIndex - 1)] | Where-Object {
        $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ret
    })
    Assert-True ($normalPathReturns.Count -eq 0) 'normal scene path should reach orig_LevelActivated without returning early'
}
finally {
    $game.Dispose()
}

'PASS: Quit_To_Menu skips GameManager.LevelActivated while normal scenes run the original implementation'
