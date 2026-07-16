Hollow Knight Modding API
=========================

This is a simple modding API used mainly for compatibility between mods. It does little on its own, but is required for several mods to run.

Release Compatibility
=====================

* Hollow Knight: 1.5.12620.0
* Modding API: v78
* Verified platform: Windows x64 only
* Status: Experimental. Existing mods may still require updates for the Unity 6 game build.

发布兼容性
==========

* Hollow Knight：1.5.12620.0
* Modding API：v78
* 已验证平台：仅 Windows x64
* 状态：实验性。部分现有 Mod 仍可能需要更新后才能兼容 Unity 6 游戏版本。

How To Install
==============

Navigate to the managed assembly folder inside your Hollow Knight installation.

    Steam: C:\Program Files (x86)\Steam\steamapps\common\Hollow Knight\hollow_knight_Data\Managed\
    GoG: <Hollow Knight install folder>\hollow_knight_Data\Managed\

Copy all 17 files from this zip directly into the `Managed` folder. When prompted to overwrite files, say yes.

You may also use [Scarab](https://github.com/fifty-six/Scarab/releases/latest).

安装方法
========

打开 Hollow Knight 游戏安装目录下的 `hollow_knight_Data\Managed` 目录，将压缩包内 17 个文件直接复制到该目录。出现覆盖提示时选择确认。

本版本仅在 Windows x64 上完成验证。安装前请备份存档和现有 Mod 配置。

How To Uninstall
================

Steam: Right Click on Hollow Knight -> Properties -> Local Files -> Verify Integrity of Game Files
GoG: Options -> Manage Installation -> Verify / Repair

卸载方法
========

Steam：右键 Hollow Knight -> 属性 -> 已安装文件 -> 验证游戏文件的完整性

GoG：选项 -> 管理安装 -> 验证 / 修复

Experimental Compatibility Notes
================================

This build targets Hollow Knight 1.5.12620.0. Compatibility with other game versions, operating systems, and every existing mod is not guaranteed.

实验性兼容说明
==============

本构建仅面向 Hollow Knight 1.5.12620.0，不保证兼容其他游戏版本、操作系统或全部现有 Mod。
