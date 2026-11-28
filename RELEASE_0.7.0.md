# PixelBone v0.7.0 — UI Redesign

**Status:** installation package prepared, Lua syntax and mocked API tests passed. **Not launched in a real Aseprite instance** in this environment.

## Purpose and implementation

PixelBone is a Lua extension for Aseprite with a rest-pose skeleton, capsule skins, editable Paint Sheets, automatic nearest-bone pixel binding, FK/IK poses, a keyframe animation timeline, and layer export.

Version 0.7 implements a compact Bonebase-*inspired* workspace, using **only the project's original source and Aseprite's public scripting API**. No Bonebase source code or assets were used.

A single modeless `Dialog` contains a **single custom-drawn `Dialog:canvas` widget** with three persistent sections:

- **Left, ~33.5%:** tabs `Rig / Bone / Groups / Paint / Animation / Poses / More`, content scrolling separately from the workspace.
- **Right top, ~66.5%:** rest/pose character canvas, mouse-based tools and view navigation. Quick Art/Caps/Bones switches.
- **Right bottom:** an always-visible keyframe timeline with a scrollable list of bones and frame cells. It does not open a second window.

This is a floating Aseprite extension window, **not a docked editor panel**. Older Aseprite APIs do not provide a general-purpose docking/grid panel layout for Lua dialogs. PixelBone renders UI controls using the documented `GraphicsContext`; ordinary Aseprite mini-dialogs are used *only* to edit text, numeric fields, and colours safely.

## Compatibility and safety

- Loads/saves the **unchanged** `sprite.data.pixrig` JSON schema. No data migration.
- Preserves the existing modules `rig.lua`, `skin.lua`, `binding.lua`, `paint.lua`, `export.lua`, `json.lua`, `store.lua`, `view.lua` **without changes**.
- Existing Paint Sheet groups and original editable artwork layers are not replaced. `Generate new Paint Sheet` still creates a new uniquely named group.
- Original `PixRig` export-group semantics are unchanged.
- Includes the **entire unmodified old UI** as `pixrig/ui_classic.lua`, accessible via `File > Scripts > PixelBone Classic (0.6 UI)...`. Use it as a fallback if your old Aseprite build misbehaves.
- `templates.lua` only assembles 16 humanoid rest bones through the existing `Rig:addBone` API. It refuses to act on a non-empty rig.

## Main features to test

1. **Rig:** mirror, mirror axis, symmetrize, snap-to-pixel, autosave, one-click template (empty rig only).
2. **Bone:** select, create, edit, link, delete, radius, pose, move, pan, IK controllers and IK parameters.
3. **Groups:** switch/create/delete groups, colour, rename, skin assignment, outline.
4. **Paint:** preview of the editable Paint Sheet; `Open Paint Sheet` selects an artwork layer in the native Aseprite editor; `Refresh artwork` updates binding.
5. **Canvas:** independently switch artwork/capsules/bones; artwork is the default when an editable Paint Sheet exists; wheel zoom; pan and fit.
6. **Animation:** animation selection, frames, FPS, name, interpolation, angular snap.
7. **Timeline:** list of bones, current frame, click to select a frame/bone, double-click to create/remove a bone key, Play/Stop, +Key/-Key, copy/paste pose. Mouse wheel over time cells scrolls frames; over names scrolls bones.
8. **Poses:** transient pose slots in the current extension session; this does not change the saved rig format.
9. **More:** export skin/animation, save rig, render switches, undo/redo.

### Paint Sheet refresh

`Sprite.events:on('change', ...)` invalidates cached artwork. On the next repaint, `Binding.prepare` re-reads the existing art and the canvas redraws the bound character. The art is painted in **Aseprite itself** (Pencil, Eraser, Picker, History/Undo) because its editor already provides stable pixel editing. Pixel painting is **not** implemented inside the extension window, deliberately avoiding brittle undo/history and cel-editing workarounds.

## Installation

1. Keep a backup of your `.aseprite` project.
2. In Aseprite, open **Edit > Preferences > Extensions > Add Extension** and select `pixelbone-0.7.0.aseprite-extension`.
3. Restart Aseprite if prompted. Open a sprite; select **File > Scripts > PixelBone 0.7.0...**. Use **PixelBone Classic (0.6 UI)...** for troubleshooting.
4. Paint Sheets are edited on the **same Aseprite sprite**, on editable layers within `PixRig Paint Sheet...` groups. The UI is modeless: click the Aseprite editor to paint, then return to PixelBone.

This package uses extension name `pixelbone` rather than the original `pixrig`, so it does not silently replace the old installed extension. Stored project data remains under `sprite.data.pixrig` for backwards compatibility.

## Build from source

```sh
python3 build.py
```

This bundles the modules into `dist/main.lua` and creates `dist/pixelbone-0.7.0.aseprite-extension`. No `require()` filesystem loading is needed inside Aseprite.

## Automated verification performed

All of the following passed in a Lua 5.3-compatible `texlua` runner, **not inside Aseprite**:

```sh
texluac -p pixrig/*.lua entry.lua dist/main.lua
texlua tests/test_rig.lua
texlua tests/test_templates.lua
texlua tests/harness_workspace.lua
texlua tests/harness_classic.lua
texlua tests/harness_bundle.lua
SCREEN_W=1366 SCREEN_H=768 UI_SCALE=1 texlua tests/harness_sizes.lua
SCREEN_W=1920 SCREEN_H=1080 UI_SCALE=1 texlua tests/harness_sizes.lua
SCREEN_W=1366 SCREEN_H=768 UI_SCALE=2 texlua tests/harness_sizes.lua
SCREEN_W=1920 SCREEN_H=1080 UI_SCALE=2 texlua tests/harness_sizes.lua
```

`harness_workspace.lua` mocks Aseprite `Dialog`, `Canvas`, `GraphicsContext`, `Sprite`, `Image`, and events; it exercises drawing, tab switching, pose/rest switching, timeline key writes, Paint Sheet generation, real-time cache invalidation, layer selection, IK creation/deletion, and Undo. `harness_bundle.lua` repeats the workflow through the bundled `main.lua` and registered plugin command. `harness_classic.lua` verifies regression behavior of the unchanged old UI.

The layout-size test checks the initial canvas dimensions against window sizes for 1366×768 and 1920×1080 at 100%/200% UI scales. It is a **synthetic geometry check**, not a screenshot or actual UI result on those screens.

## Known limitations / manual tests still needed

- **Requires a live Aseprite smoke test**, particularly on the user's **1.3-rc4-dev** build. Headless test doubles cannot detect native editor crashes, rendering defects, unusual high-DPI behaviour, or focus issues.
- The panels are **not user-draggable/resizable** in v0.7; the dialog size is chosen at launch from the app window when available. A very small screen combined with high UI scaling leaves a short scene viewport, though both panels remain present.
- Only Aseprite-native painting is provided. A custom pixel editor in the Lua canvas is not justified without reliable cel history and input parity.
- `Poses` slots are in-memory only; persistent pose-library data would require a separately reviewed schema extension.
- The single humanoid template is conservative. Additional templates are not part of the v0.6 rig logic.
- Bone-name / FPS / colour editing opens short-lived native dialogs; there is no persistent second timeline window.
- Canvas-level keyboard shortcuts stay disabled because the user's 1.3-rc4-dev build previously experienced a native crash with the old implementation. Mouse controls work through the canvas event callbacks.
- The auto-refresh event callback and native layer-selection behaviour need to be tested during *actual* painting and Aseprite undo/redo; mocks verify only the intended code path.

## Aseprite compatibility decision

The requested Aseprite **1.3-rc4-dev** has already demonstrated support for the essential `Dialog:canvas`, mouse and `GraphicsContext` drawing calls in earlier PixelBone revisions. Therefore v0.7 does not require a version bump for its basic architecture. The current documented stable release, **Aseprite 1.3.18.6 (September 22, 2026)**, provides additional dialog/event improvements and is recommended for smoother future resizing work, but is **not enforced** as a minimum for this build.

Reference APIs:
- https://aseprite.org/api/dialog
- https://aseprite.org/api/graphicscontext
- https://aseprite.org/api/sprite
- https://aseprite.org/release-notes/

## Changed files

- `pixrig/ui.lua` — replaced the original multi-window interface with the owner-drawn two-panel workspace and integrated Timeline.
- `pixrig/ui_classic.lua` — new copy of the **unaltered** v0.6 UI for fallback.
- `pixrig/templates.lua` — new optional humanoid-rig helper.
- `entry.lua` — registers new-workspace and classic UI menu commands.
- `build.py` — bundles the added modules and new extension identity.
- `package.json` — extension metadata / version `0.7.0`.
- `SOURCE_README.txt`, `PROJECT.md`, `RELEASE_0.7.0.md` — documentation.
- `tests/harness_ui.lua`, `tests/harness_workspace.lua`, `tests/harness_classic.lua`, `tests/harness_bundle.lua`, `tests/harness_sizes.lua`, `tests/test_templates.lua` — test entrypoints and new regression scenarios.

**Unchanged:** `pixrig/rig.lua`, `pixrig/skin.lua`, `pixrig/paint.lua`, `pixrig/binding.lua`, `pixrig/export.lua`, `pixrig/json.lua`, `pixrig/store.lua`, `pixrig/view.lua`, and existing `tests/test_rig.lua`.
