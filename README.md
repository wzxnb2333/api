Hollow Knight Modding API
=========================
![build](https://github.com/hk-modding/api/actions/workflows/build.yaml/badge.svg)
![docs](https://github.com/hk-modding/api/actions/workflows/docs.yaml/badge.svg)
![GitHub all releases](https://img.shields.io/github/downloads/hk-modding/api/total)

A Hollow Knight Modding API/loader. Uses [MonoMod](https://github.com/MonoMod/MonoMod).

If you're a mod developer, there are [examples](https://github.com/hk-modding/api/tree/master/Examples) in the repo.

Documentation can be found [here](https://hk-modding.github.io/api/).

Build
=======

**If you want to use the API, for making mods or using them, please use a release or the installer.**

These instructions build the Windows x64 API for Hollow Knight `1.5.12620` and Unity `6000.0.61f1`. Linux and macOS project structure is retained, but those platforms are not verified by this branch.

1. Clone the repository.
2. Copy the contents of the game's `hollow_knight_Data\Managed` directory into a `Vanilla` directory at the repository root.
3. Restore and build the API:

```powershell
dotnet restore
dotnet build Assembly-CSharp --runtime win-x64 -p:Configuration=Release
```

The complete package is written to `OutputFinal`. A normal build does not modify the game installation.

To inspect, install, or restore a local game explicitly, use the deployment script:

```powershell
$gamePath = '<Hollow Knight install path>'
$legacyDebugModZip = '<DebugMod-Legacy-1.5.78.zip path>'
pwsh -NoProfile -File '.\scripts\local-deploy.ps1' -Action Status -GamePath $gamePath
pwsh -NoProfile -File '.\scripts\local-deploy.ps1' -Action Install -GamePath $gamePath -LegacyDebugModZip $legacyDebugModZip
pwsh -NoProfile -File '.\scripts\local-deploy.ps1' -Action Restore -GamePath $gamePath
```

Close the game before installing or restoring. Install copies `OutputFinal` and the Legacy DebugMod into `hollow_knight_Data\Managed`, while preserving the replaced files and a LocalLow snapshot under the backup root. Restore returns the Managed directory to its pre-install state but deliberately leaves later LocalLow progress unchanged.

Set `HK_GAME_PATH` instead of passing `-GamePath` on every command. Pass `-OutputPath`, `-BackupRoot`, `-BackupPath`, or `-LegacyDebugModZip` when their defaults do not apply. The Legacy DebugMod ZIP is not part of this repository and must be supplied for an independent clone.

When testing beside an existing BepInEx installation, first run `Status` and require `DoorstopDisableSupported : True`. This means `doorstop_config.ini` permits the process-local disable switch. Then disable Doorstop only for the test process:

```powershell
try {
    $env:DOORSTOP_DISABLE = '1'
    & (Join-Path $gamePath 'hollow_knight.exe')
}
finally {
    Remove-Item Env:DOORSTOP_DISABLE -ErrorAction SilentlyContinue
}
```

License
=======
Distributed under the MIT [license](https://github.com/hk-modding/api/blob/master/LICENSE).
