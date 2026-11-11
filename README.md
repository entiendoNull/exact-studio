# Exact Studio

A macOS screen recorder built with [Exact](https://github.com/expo/exact). It records, edits and exports polished screen videos.

- **Record** an area you drag out, a whole display, or one window. A dragged area stays selected on the dimmed screen: move it, resize it from its handles, then press Record (or Return); Escape cancels.
- **Simulators and emulators are cropped to the device bezel.** An iOS Simulator or Android emulator window is captured on its own with its alpha channel, and the device's opaque shape is detected in the first frame. The title bar, toolbar and desktop never reach the video. If the detection is off, trim each edge in the editor.
- **Frame**: a gradient background, padding, rounded corners, a shadow, and an output shape (16:9, 9:16, 1:1, 4:3 or fit).
- **Timeline**: a filmstrip with cuts over it, and as many effect lanes as you need. The Add menu puts a zoom in, zoom out, slow down, speed up, spotlight, cursor highlight, blur, black and white, or cut at the playhead. Effects overlap on separate lanes, except two zooms, two speed changes, or two of the same effect. Drag a segment to move it (below the last lane for a new one) or its edges to resize; click it to change it in the inspector; split it at the playhead. Delete removes the selection, Space plays, the arrow keys step a frame (Shift: a second).
- **Zoom on clicks**: a new recording starts with a zoom around each group of clicks; the button regenerates them.
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
- `modules/apple/Studio.swift`: the module's ops, the menu bar item, the preview view, export.

Recordings are kept in `~/Movies/Exact Studio/Recordings/<id>/` as `capture.mov` (HEVC with alpha), `meta.json`, `cursor.json` and `edits.json`.
