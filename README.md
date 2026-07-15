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

These instructions build the Windows API for Hollow Knight `1.5.12620`.

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
pwsh -NoProfile -File '.\scripts\local-deploy.ps1' -Action Status
pwsh -NoProfile -File '.\scripts\local-deploy.ps1' -Action Install
pwsh -NoProfile -File '.\scripts\local-deploy.ps1' -Action Restore
```

Pass `-GamePath`, `-OutputPath`, `-BackupRoot`, or `-BackupPath` when the defaults do not apply.

License
=======
Distributed under the MIT [license](https://github.com/hk-modding/api/blob/master/LICENSE).
