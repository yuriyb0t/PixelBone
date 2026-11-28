PixelBone v0.8.2 -- editable Lua source and tests.

Purpose: standalone skeleton animation, separate editable Paint Sheets,
Assembly Pose, Bone Inspector and layered bone-locked artwork in one Aseprite
workspace. All code is original. No Bonebase source or assets are included.

Quick start:
  1. Create Rest bones and Paint Sheets.
  2. Use Assemble + Move / Rotate to arrange separated parts (NO timeline key).
  3. Use Animate to add normal FK / IK keys, starting at frame 1.
  4. Use Paint > New layer for selected bone... for separately editable hats,
     weapons or accessories; edits in Aseprite refresh the preview.

Build with: python3 build.py
Tests and known limits: RELEASE_0.8.1.md
Earlier notes: RELEASE_0.7.0.md (historical only)
The rig is stored in sprite.data.pixrig, with an optional assembly field since v0.8.
Existing user layers and Paint Sheets are not changed by the binder.
Classic UI was removed in v0.8.1 at the user's request. Previous releases remain available separately.
No actual Aseprite launch was performed during automated validation.
