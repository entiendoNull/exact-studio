#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$here/.exact/test/model"
app="$here/modules/apple"
sources=("$here/test/model/main.swift" "$app/Compositor.swift" "$app/Scene3D.swift" "$app/Bezel.swift" "$app/Templates.swift"
         "$app/Images.swift" "$app/Splits.swift" "$app/Sounds.swift" "$app/Control.swift" "$app/Editor.swift" "$app/Capture.swift" "$app/MotionPaths.swift"
         "$app/TimelineMenus.swift")
stale=0
[ -x "$bin" ] || stale=1
for s in "${sources[@]}"; do [ "$s" -nt "$bin" ] && stale=1; done
if [ "$stale" = 1 ]; then
  mkdir -p "$(dirname "$bin")"
  echo "building the model tests…" >&2
  swiftc -Onone -suppress-warnings -o "$bin" "${sources[@]}" >&2
fi
exec "$bin" "$@"
