# Exact Studio

A macOS screen recorder built with [Exact](https://github.com/expo/exact). It records, edits and exports polished screen videos.

- **Record** an area you drag out, a whole display, or one window. A dragged area stays selected on the dimmed screen: move it, resize it from its handles, then press Record (or Return); Escape cancels.
- **Simulators and emulators are cropped to the device bezel.** A Simulator (or Xcode 27's Device Hub) or Android emulator window is captured on its own. The device is found in the first frame: by transparency around it, or by its dark bezel on an opaque window, whose corner radius is measured so the frame is cut to it. For an area or window recording that shows a device, **Find a Device in the Picture** does the same. If the detection is off, trim each edge in the editor.
- **Frame**: 24 gradient backgrounds, a custom gradient (two colours from the system colour picker, linear at any angle or radial), or the recording itself blurred behind it; padding, rounded corners, a shadow, and an output shape (16:9, 9:16, 1:1, 4:3 or fit).
- **Placement and motion**: drag the video in the preview to place it (it snaps to the centre lines); scroll or pinch to resize. Presets put it centre, left, right, top, bottom, large or in a corner. A **move** on the Motion track animates it to a new place at a time, in one of eight styles (smooth, linear, spring, zoom through full screen, swipe, fade, spin, pop) at a chosen speed. **Motion** has ready-made patterns: side to side, zoom tour, entrance, bounce, slow push in.
- **3D**: the subject as a real 3D object (SceneKit) with the recording on its face, lit by a studio, its edge in polished metal, aluminum, glass or matte. A device's body is read from its silhouette: the block with its own corner radius, and each side button standing out from the edge. Tilt, turn and roll it, set its thickness, pick a pose (hero, lean left or right, lay back, tumble, face on), or ⌥-drag it in the preview. Face on looks exactly like the flat picture. Moves carry a 3D angle too, eased in their style (spin turns it a full circle), and Motion has 3D patterns: turntable, orbit, hero reveal, flip in, float.
- **Cursor**: new recordings leave the system cursor out and draw it from the recorded path, so it can be hidden, resized, smoothed, and squeezed on each click.
- **Text**: any number of texts on the lanes, each dragged into place, with size, tilt, colour, weight and a shape (pill, box, outline, soft shadow), an entrance (letters spring up, pop or drop, typewriter, pop, spin, slide, rise, blur, fade), an exit (fade, letters fall, pop away, sink, blur) and a loop while shown (wave, pulse, float, wiggle).
- **Whole-frame effects and temporary 3D**: blur and black and white cover the video or the whole frame (texts stay sharp); a 3D Turn segment turns the video to a pose, or a full orbit, and back, even with 3D off.
- **Timeline**: drag its top edge to make it (and the preview) taller or shorter; it scrolls when short.  the clip as a filmstrip, and effect lanes under it. **Split Clip** (or S) splits the clip at the playhead with a visible gap; select a part and remove it (it stays hatched, so it can be restored) or join it with a neighbour; a kept part can pass into the next across removed ones with a crossfade or a fade through the background. **Add** puts a zoom in, zoom out, slow down, speed up, spotlight, cursor highlight, blur, or black and white at the playhead. Effects overlap on separate lanes, except two zooms, two speed changes, or two of the same effect. **+ Add effect lane** adds a lane; an empty lane's × removes it. Drag an effect to move it (across lanes too) or its edges to resize. The inspector shows the selection's start and end as fields: type `1.25` or `0:01.25` and press Return. Delete removes the selection, Space plays, the arrow keys step a frame (Shift: a second).
- **Templates**: Clean Launch, Product Hero, Feature Tour and Social Teaser, each a ready-made set of texts, effects, zooms, moves and 3D laid out for the frame's shape (landscape, square or portrait) along the video as it plays. Undo Template puts the edit back.
- **Zoom on clicks**: a new recording starts with no zooms; the button adds one around each group of clicks.
- **Export** an MP4 to `~/Movies/Exact Studio/`.

## Run

```sh
bun exact.mjs mac --run
```

The app uses the Exact checkout at `../exact`. The first recording asks for Screen Recording permission in System Settings › Privacy & Security; reopen the app after you allow it. While recording, a **Stop** item sits in the menu bar.

## Layout

- `app.contract`: the view. `app.ts`: forwards each request to the native module.
- `modules/apple/Capture.swift`: source listing, the area picker, the ScreenCaptureKit recorder, cursor and click tracking.
- `modules/apple/Bezel.swift`: finds the device in a captured window.
- `modules/apple/Compositor.swift`: the look, zooms and effects rendered per frame, and the time map across cuts and speed. The preview and the export share it.
- `modules/apple/Editor.swift`: one open recording: its edits, its player, the selection.
- `modules/apple/Timeline.swift`: the timeline view.
- `modules/apple/Templates.swift`: the ready-made edits.
- `modules/apple/Scene3D.swift`: the 3D stage: the slab, its materials, lights and camera.
- `modules/apple/Studio.swift`: the module's ops, the menu bar item, the preview view, export.

Recordings are kept in `~/Movies/Exact Studio/Recordings/<id>/` as `capture.mov` (HEVC with alpha), `meta.json`, `cursor.json` and `edits.json`.
