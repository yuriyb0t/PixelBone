# PixRig

**English** | [Русский](README.ru.md)

A 2D skeletal animation extension for [Aseprite](https://www.aseprite.org/), written in Lua.

PixRig lets you build a 2D skeleton, generate a capsule-based skin silhouette, and export poses or animations into an Aseprite sprite as separate layers.

> **Early development — v0.3.0**
>
> Skeleton editing, skin generation, and single-pose layer export have been tested in Aseprite. Animation editing and animation export are implemented but **not yet verified in Aseprite**. IK and 3D animation import are planned.

## Goals

The current focus is a practical 2D rigging and pixel-animation workflow inside Aseprite.

The longer-term goal is to import 3D animation from **GLB/glTF or BVH**, retarget a **Mixamo rig** onto a 2D skeleton, and turn the result into pixel animation.

A deferred feature is **smart bones**, inspired by Moho: the artist draws extreme poses, and bone angles drive pixel deformation.

## Current status

| Stage | Feature | Status |
| --- | --- | --- |
| 1 | Bone canvas: Create / Edit / Link / Delete, mirroring, Undo / Redo, persistence in `sprite.data` | Working; verified in Aseprite |
| 2 | Joint radii, skin, color groups, pixel outline, layer export into a `PixRig` group | Working; verified in Aseprite |
| 3 | Pose / Move tools, keyframes, linear / step interpolation, Timeline dialog, Play, Copy / Paste Pose, all-frame export with an animation tag and frame durations | Implemented; not yet verified in Aseprite |
| 4 | Two-bone IK with a pole target, foot pinning | Planned |
| 5 | GLB / BVH import and Mixamo retargeting, including layer ordering on turns and frame annotations | Planned |
| 6 | Onion skin, rig / pose libraries, skeleton templates, radius variation along bones, skin-group ordering | Planned |

See [PROJECT.md](PROJECT.md) for the technical project notes, data model, and compatibility details.

## Installation

### Requirements and compatibility

- A Windows installation of Aseprite with Lua extension support.
- The verified development target is **Aseprite 1.3-rc4-dev**. Other builds may behave differently; the animation features still need testing.
- Use an **RGB sprite** for skin and layer export.
- Lua and Python are **not required to install a packaged extension**. They are only needed for the optional tests and source build described below.

### Install the packaged extension

1. Obtain `pixrig-<version>.aseprite-extension`, either from the repository's **Releases** page, if a package is provided, or by building it from source as described below.
2. Close any open PixRig dialogs.
3. In Aseprite, open **Edit → Preferences → Extensions**.
4. If an older PixRig version is installed, select it and click **Uninstall** first.
5. Click **Add Extension**, select the `.aseprite-extension` file, and confirm.
6. **Restart Aseprite** to finish installation and load the new version.
7. Open an RGB sprite and launch **File → PixRig...**.

**Important:**

- Select the packaged `.aseprite-extension` file through **Add Extension**. You do not need to extract it or rename it to `.zip`.
- Do **not** copy the package or the unpacked source files directly into Aseprite's `extensions` folder.
- Uninstall the previous version before installing the new one, then restart Aseprite.

### Updating

Repeat the installation steps: uninstall the existing PixRig entry under **Preferences → Extensions**, add the new package, and restart Aseprite.

### Uninstalling

Open **Edit → Preferences → Extensions**, select PixRig, click **Uninstall**, and restart Aseprite.

Removing the extension does not remove layers or cels that have already been exported into a sprite.

## Build from source

Run these commands from the repository root:

```sh
python3 build.py
```

If your Windows Python installation uses the Python launcher instead:

```powershell
py -3 build.py
```

The build script combines the Lua modules into `dist/main.lua` and creates:

```text
dist/pixrig-<version>.aseprite-extension
```

Install that package using the steps above. The build script is a **bundler only**: it does not install the extension into Aseprite or validate its runtime behavior.

## Run the logic tests

The pure Lua model tests require **Lua 5.3 or 5.4** available as `lua` on your PATH.

From the repository root:

```sh
lua tests/test_rig.lua
```

These tests cover logic outside the Aseprite API. Passing them does **not** verify dialogs, canvas input, timers, sprite modifications, or animation export. Those features must be checked manually in Aseprite.

## Project structure

```text
pixrig/
  rig.lua       Skeleton model, radii, groups, mirroring, animation, FK poses
  skin.lua      Skin rasterization: capsules, joint radii, outline
  export.lua    Sprite output: single pose and full animation
  ui.lua        Main dialog and PixRig Timeline dialog
  store.lua     Persistence in sprite.data
  json.lua      Minimal JSON implementation
  view.lua      Canvas zoom and pan
entry.lua       File > PixRig... command and full error reporting
build.py        Single-file bundler and extension packager
tests/
  test_rig.lua  Pure Lua logic tests
PROJECT.md      Technical project notes in English
PROJECT.ru.md   Technical project notes in Russian
```

The model, skin rasterization, JSON, storage, and view modules are kept separate from direct Aseprite rendering and export operations. `rig.lua` and `skin.lua` are pure Lua and do not use the Aseprite API.

## How it works

- Bones and rig settings are stored as JSON in the sprite's `sprite.data`, under the `pixrig` key.
- The skin is generated from capsules with configurable joint radii.
- Skin groups have their own colors and become separate exported layers.
- Poses use forward kinematics relative to the rest pose.
- Export rebuilds only the dedicated **PixRig** layer group. Other user layers are not modified; layers inside the generated group are locked.

## Documentation

- [Technical project notes](PROJECT.md)
- [Технический паспорт проекта](PROJECT.ru.md)
- [README на русском](README.ru.md)

## Development approach

PixRig is an Aseprite extension rather than a standalone editor or an Aseprite fork. Bonebase is a reference for desired capabilities, not a source of code to copy. The initial goal is feature parity; smart-bone deformation comes later.
