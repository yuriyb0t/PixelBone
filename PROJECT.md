# PixRig — Project Notes

**Version:** 0.3.0  
**Document date:** 2026-11-26  
**English** | [Русский](PROJECT.ru.md)

Technical project passport and development handoff notes. For the public overview and installation instructions, see [README.md](README.md).

## What it is

PixRig is an Aseprite extension written in Lua:

**2D skeleton (bones) → skin (capsule-based silhouette) → export into a sprite as layers and frames.**

## End goal

Import 3D animation from **GLB/glTF/BVH**, including a **Mixamo rig**, retarget it onto a 2D skeleton, and produce pixel animation.

Deferred feature: **smart bones**, similar to Moho. The artist draws extreme poses, and bone angles drive pixel deformation.

## Status at version 0.3.0

| Stage | Scope | Status |
| --- | --- | --- |
| 1 | Bone canvas: Create / Edit / Link / Delete, mirroring, Undo / Redo, storage in `sprite.data` | Working; verified |
| 2 | Joint radii, skin, color groups, outline, layer export into a `PixRig` group | Working; verified |
| 3 | Animation: Pose / Move tools, keyframes, linear / step interpolation, Timeline dialog, Play, Copy / Paste Pose, export of all frames plus an animation tag and frame durations | Written; not verified in Aseprite |
| 4 | Two-bone IK with a pole target, foot pinning | Planned |
| 5 | GLB / BVH import and Mixamo retargeting; layer ordering on turns, frame annotations | Planned |
| 6 | Onion skin, rig / pose libraries, skeleton templates, radius variation along bones, skin-group ordering | Planned |

**Verification scope:** stages 1–2 were checked manually in Aseprite. Stage 3 must not be treated as verified merely because its code exists or pure Lua tests pass.

## Environment and constraints

- Development checks were performed on **Windows**, using **Aseprite 1.3-rc4-dev**.
- A newer Aseprite version is available in a second environment, but this document does not establish that all features have been tested there.
- Development communication is in Russian; screenshots are used to report manual checks.
- Some patches have been prepared in an assistant environment without Aseprite or a Lua interpreter. Those patches were not executed there. The available execution evidence is the developer's manual checks and logic tests.
- Each code change needs verification in the target environment. Do not silently upgrade a feature's status from “written” to “verified.”

## Repository structure

| Path | Responsibility |
| --- | --- |
| `pixrig/rig.lua` | Model: bones, radii, groups, mirroring, animation, FK poses. Pure Lua; no Aseprite API |
| `pixrig/skin.lua` | Skin rasterization: capsules with radii, outline. Pure Lua |
| `pixrig/export.lua` | Sprite writing: `export` for one pose, `exportAnimation` for all frames |
| `pixrig/ui.lua` | Two dialogs: main dialog with canvas, tools, Rig / Skin sections; `PixRig Timeline` dialog |
| `pixrig/store.lua` | Persistence in `sprite.data`, key `pixrig`, using JSON |
| `pixrig/json.lua` | Minimal JSON implementation |
| `pixrig/view.lua` | Zoom and pan |
| `entry.lua` | Registers `File > PixRig...`; reports full errors through `app.alert` |
| `build.py` | Concatenates modules into `dist/main.lua`, packages `.aseprite-extension`; bundling only |
| `tests/test_rig.lua` | Pure Lua logic tests |
| `PROJECT.md` | This technical project passport |
| `PROJECT.ru.md` | Russian version of the technical project passport |
| `README.md` / `README.ru.md` | English / Russian project overview and installation instructions |

## Installation

See the full instructions in [README.md](README.md#installation).

### Ready-to-install package

1. Obtain `pixrig-<version>.aseprite-extension` from Releases, if provided, or build it from source.
2. Close PixRig dialogs.
3. Open **Edit → Preferences → Extensions** in Aseprite.
4. Uninstall any older PixRig version using **Uninstall**.
5. Use **Add Extension** to select the `.aseprite-extension` package.
6. Restart Aseprite.
7. Open an **RGB sprite**, then use **File → PixRig...**.

Do not manually place the package or unpacked sources in Aseprite's `extensions` folder. Do not extract or rename the package before installing it.

## Build and test

From the repository root:

```sh
python3 build.py
```

Windows Python Launcher alternative:

```powershell
py -3 build.py
```

Output:

```text
dist/main.lua
dist/pixrig-<version>.aseprite-extension
```

`build.py` only bundles and packages the extension. It does not install it or test Aseprite integration.

Logic tests, requiring **Lua 5.3/5.4** on PATH:

```sh
lua tests/test_rig.lua
```

The tests do not exercise the Aseprite API. UI, input, playback, sprite mutation, tags, frame creation, and export require manual verification in Aseprite.

## Data model in `sprite.data`

### Bone

| Field | Meaning |
| --- | --- |
| `id` | Bone identifier |
| `name` | Bone name |
| `parent` | Parent bone ID; `0` means root |
| `connected` | Connection to the parent |
| `ax`, `ay` | Head coordinates |
| `bx`, `by` | Tail coordinates |
| `ra`, `rb` | Head and tail radii |
| `group` | Skin group ID; `0` means auxiliary / no skin group |
| `mirrorOf` | ID of the bone this bone mirrors |

Coordinates are in sprite pixels. Pixel centers are at `n + 0.5`.

### Skin groups and outline

Groups are stored as:

```lua
{id, name, color}
```

New bones are assigned to the active group.

Outline mode: `none | pixel`, with a configurable outline color.

### Animation

Animation record:

```lua
{id, name, frames, fps, interp, keys}
```

Keyframes are indexed as:

```lua
keys["<boneId>"]["<frame>"] = {
  rot = 0, -- degrees around the bone's head
  dx = 0,
  dy = 0,
}
```

- JSON object keys are strings, including bone and frame indices.
- `rot` rotates the bone around its rest-pose head.
- `dx` and `dy` are translation offsets and apply only to the root.
- A pose is computed using **FK from the rest pose**: a bone rotates around its own rest head, then follows its parent's transform.
- `rig.rev` increases on every edit and invalidates the skin-preview cache.

## Aseprite 1.3-rc4-dev findings

These observations are important for compatibility and should not be discarded without retesting.

### Constraints and workarounds

- Extension-local `require()` does not resolve modules as expected. All modules are therefore bundled into one `main.lua`, with an internal replacement for `require`.
- `Dialog:tab` is unavailable in the checked build. The fallback is separated sections instead of tabs.
- A widget with a `label=` parameter occupies its own row. For compact layouts, labels are created separately with `dlg:label`.
- The console shows only the first line of an error. Full error text is captured with `xpcall` and displayed using `app.alert`.

### APIs / behavior verified in the checked environment

- `Dialog:canvas`, including mouse and wheel input.
- `GraphicsContext`.
- `dlg.bounds`.
- `sprite.data`.
- `sprite:newGroup`, `sprite:newLayer`, `sprite:newCel`.
- Layer-based export.

### Not yet verified

- `canvas.onkeydown` and canvas keyboard shortcuts.
- `Timer` for Play.
- `sprite:newEmptyFrame` and `sprite:newTag`.
- Full animation export.

## Design decisions

- Build an **extension**, not a standalone editor or an Aseprite fork. PhotoCraft and Pixelorama were rejected as unnecessarily heavy alternatives for this task.
- Use Bonebase as a reference for **capabilities**, not as code to inspect or copy.
- Defer the distinguishing smart-bone feature until feature parity is reached.
- Export rebuilds only the **PixRig** group. Its generated layers are locked; user layers outside it are left untouched.
- Skin and layer export require **RGB mode**.

## Continuing development / handoff

When continuing in a new chat or handing work to another contributor:

1. Provide the current `pixrig-<version>-src.zip` and this project passport, or the equivalent repository snapshot.
2. State exactly what has been verified in Aseprite, including the Aseprite build and any screenshots or error messages.
3. Do not inspect or copy Bonebase code; use the documented feature goals instead.
4. Ask the developer to check each new build in Aseprite and report results with screenshots where useful.
5. **Next step:** verify stage 3 end to end, then proceed to IK and GLB / BVH import.

### Stage 3 verification checklist

Use a disposable RGB sprite and record the actual result of each check:

- [ ] Pose and Move tools edit the intended bones / root offsets.
- [ ] Keyframes can be created and revisited without losing bone or frame indices.
- [ ] Linear and step interpolation produce the expected poses.
- [ ] Timeline opens and stays synchronized with edits.
- [ ] Play starts, advances frames, and stops correctly; check `Timer` behavior.
- [ ] Canvas keyboard shortcuts work; check `canvas.onkeydown`.
- [ ] Copy / Paste Pose preserves the intended pose.
- [ ] Full animation export creates the expected frames; check `sprite:newEmptyFrame`.
- [ ] The animation tag and frame durations are correct; check `sprite:newTag`.
- [ ] Exported layers match skin groups and colors; unrelated user layers remain unchanged.
- [ ] Undo / Redo and reopening the sprite preserve the expected rig data.
- [ ] Errors show the full diagnostic text through `app.alert`.

Only mark stage 3 as verified after the relevant checks pass in Aseprite.
