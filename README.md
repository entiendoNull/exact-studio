# Exact Studio

A macOS screen recorder built with [Exact](https://github.com/expo/exact). It records, edits and exports polished screen videos.

- **Record** an area you drag out, a whole display, or one window.
- **Simulators and emulators are cropped to the device bezel.** An iOS Simulator or Android emulator window is captured on its own with its alpha channel, and the device's opaque shape is detected in the first frame. The title bar, toolbar and desktop never reach the video. If the detection is off, trim each edge in the editor.
- **Edit**: a gradient background, padding, rounded corners, a shadow, and an output shape (16:9, 9:16, 1:1, 4:3 or fit).
- **Auto-zoom**: the camera zooms in around clicks and follows the cursor while zoomed.
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
- `modules/apple/Compositor.swift`: the look and the zoom plan, rendered per frame. The preview and the export share it.
- `modules/apple/Studio.swift`: the module's ops, the menu bar item, the preview view, export.

Recordings are kept in `~/Movies/Exact Studio/Recordings/<id>/` as `capture.mov` (HEVC with alpha), `meta.json` and `cursor.json`.
