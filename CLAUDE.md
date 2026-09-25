# CLAUDE.md

Coding rules, Swift/SwiftUI conventions and git workflow live in AGENTS.md — follow them:

@AGENTS.md

This file covers what AGENTS.md doesn't: how to build this fork, what it adds on top of upstream
[jsattler/BetterCapture](https://github.com/jsattler/BetterCapture), where that code lives, and what's next.

## What this fork is

BetterCapture is a sandboxed macOS menu bar screen recorder (ScreenCaptureKit + AVAssetWriter).
This fork is working towards a free Screen Studio / CleanShot X alternative: record input telemetry
now, build an editor (auto-zoom, smooth cursor, backgrounds) on top of it later.

Architecture of the original app: `docs/architecture/OVERVIEW.md`, `docs/architecture/OUTPUT.md`,
`docs/concepts/VIDEO.md`, `docs/concepts/AUDIO.md`.

## Build, run, test

The project is signed with upstream's team (`DMX24B5FC3`), which you won't have. Build with your
own Apple Development certificate — don't commit signing changes:

```sh
# Find your team ID: the OU= field
security find-identity -v -p codesigning
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject

TEAM=<YOUR_TEAM_ID>
xcodebuild -scheme BetterCapture -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/bc-build/dd \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=$TEAM \
  CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" build -quiet \
  && { pkill -x BetterCapture; open /tmp/bc-build/dd/Build/Products/Debug/BetterCapture.app; }
```

- Tests: same command with `test` instead of `build -quiet` (Swift Testing, 189 tests).
- Lint: `swiftlint lint --quiet <files>` — new code must be clean. Pre-existing warnings:
  `AssetWriter.swift` (file_length, type_body_length, 2× function_body_length) and
  `RecorderViewModel.swift` (file_length, type_body_length). Don't make them worse; SwiftLint skips
  extensions for type_body_length, so new logic goes in same-file extensions or new types.
- Keep build output outside the repo (`/tmp/bc-build`). If the build fails with "There is no
  XCFramework found", `rm -rf /tmp/bc-build` and rebuild (moved DerivedData breaks SPM paths).
- **Don't use ad-hoc signing (`CODE_SIGN_IDENTITY="-"`)**: the code hash changes every build, so
  macOS forgets the Screen Recording permission and prompts forever. If a permission gets stuck:
  `tccutil reset ScreenCapture com.sattlerjoshua.BetterCapture`, then relaunch.
- New `.swift` files need no pbxproj edit (file-system synchronized groups).
- App target defaults to MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Swift 6
  language mode. Types used off the main actor must be marked `nonisolated`: Swift 6 checks
  isolation at runtime too, so main-actor code called from a capture queue crashes instead of racing.
  ScreenCaptureKit isn't Sendable-annotated; files that pass its types across actors use
  `@preconcurrency import ScreenCaptureKit`.
- Test suites that touch main-actor app types (most models) are marked `@MainActor`.

## Features added in this fork

Branches are stacked: `feat/input-telemetry` → `feat/cursor-sprites` → `feat/pause-resume`.

### F1 — Input telemetry sidecar (`feat/input-telemetry`)

Optional setting **Settings → Video → Advanced → Record Input Telemetry** (off by default). Writes
`<video>.telemetry.json` next to each recording with cursor positions, clicks, scrolls and
keystrokes (key code + modifiers only, never characters), all on the video timeline.

| File | Role |
|---|---|
| `Model/InputTelemetry.swift` | Codable file format, pure conversion helpers (`videoTime`, `rebased`, `videoPixel`, `topLeft`, `modifierNames`) |
| `Service/InputTelemetryRecorder.swift` | Cursor polling (≤60 Hz), global mouse/scroll monitor, listen-only key `CGEventTap`, writes the sidecar |
| `Service/CaptureGeometryTracker.swift` | Per-frame `SCStreamFrameInfo` geometry on the capture queue, stored only on change |
| `Service/AssetWriter.swift` | `sessionStartTime` (host time of file time 0) |
| `ViewModel/RecorderViewModel.swift` | Starts telemetry after the last `try` in `startRecording`, writes the sidecar in `stopRecording` while the output folder's security scope is held |

Key facts:
- **Time:** events are stored as host-clock seconds while recording (`NSEvent.timestamp`,
  `CMClockGetHostTimeClock`, SCStream PTS all share it) and rebased at stop by `sessionStartTime`.
- **Position:** locations are global CG points, top-left origin. Map to video pixels with
  `InputTelemetry.videoPixel(for:geometry:)` using the `geometry` entry in effect at that time.
  Verified against real frames for display and window captures.
- **Window shadows:** with "Show Window Shadows" on, SCK draws window + shadow scaled into the frame.
  SCK reports only the shadow's total size, so the top/bottom split uses the measured
  `InputTelemetry.shadowTopFraction = 0.35` (macOS 27). Re-measure if Apple changes shadows.
- **Keystrokes** need Input Monitoring (requested when the toggle is turned on; effective after
  relaunch). Without it `keystrokesAvailable` is false and `keys` is empty.

### F2 — Cursor sprites (`feat/cursor-sprites`)

When telemetry is on, each distinct system cursor image (arrow, I-beam, hand, resize…) is stored once
in the JSON (largest bitmap as base64 PNG, size + hotspot in points), plus a track of when the
cursor changed shape. Standard cursors also get a `kind` (`CursorKind`). Lets the editor redraw the
cursor, so with telemetry on the cursor is **left out of the video** unless
**Settings → Video → Advanced → Keep System Cursor in Video** is on (off by default); "Show Cursor"
is disabled meanwhile. `capture.cursorInVideo` records which applied.

| File | Role |
|---|---|
| `Service/CursorShapeTracker.swift` | Pure dedup by fingerprint (size + hotspot + smallest bitmap's pixels); PNG encoded and kind looked up only for new shapes |
| `Service/StandardCursors.swift` | Fingerprints of the running OS's 44 standard `NSCursor`s; another app's arrow is byte-identical to `NSCursor.arrow`, so exact match classifies |
| `Service/InputTelemetryRecorder.swift` | `sampleCursorShape(at:)` reads `NSCursor.currentSystem` at ≤15 Hz |
| `Model/SettingsStore.swift` | `keepSystemCursorInVideo`, `leavesCursorToEditor`, `capturesCursor` (used for `SCStreamConfiguration.showsCursor`) in the `// MARK: - Cursor Capture` extension |

Arrow and I-beam bitmaps go up to 10× (280×400 px); other standard cursors only 2×, so the captured
PNG is as sharp as anything `NSCursor` offers at edit time.

Risk: `NSCursor.currentSystem` is marked "to be deprecated" with no public replacement. If it starts
returning nil, sprites are simply empty; nothing else breaks.

### F4 — Pause / resume (`feat/pause-resume`, upstream issue #174)

Menu bar **Pause/Resume** button, global shortcut **Pause/Resume Recording** (no default), and
`bettercapture://pause`. The SCStream keeps running while paused (instant resume, macOS recording
indicator stays on); every sample is dropped and the paused time is cut from the file.

| File | Role |
|---|---|
| `Service/RecordingPauses.swift` | Pure struct: per sample, drop (`nil`) or return paused time to subtract |
| `Service/AssetWriter.swift` | `timelineOffset(of:duration:)` rebases every track, the CFR grid and head silence padding by `sessionAnchor + pausedTime`; `pause`/`resume`/`pauseIntervals` in the `// MARK: - Pausing` extension; last frame captured while paused is shown from the resume point |
| `ViewModel/RecorderViewModel.swift` | `isPaused` flag (state stays `.recording`), `togglePause()` extension, timer excludes paused time |
| `Model/InputTelemetry.swift` | `rebased(anchor:duration:pauses:)` drops events inside pauses and shifts later ones |

Audio buffers straddling a pause edge are dropped whole (gap ≤ ~21 ms per edge, marked `ponytail:`).

### Telemetry JSON (version 3)

```
version, keystrokesAvailable,
capture:       { kind: display|window|area, videoSize: [w,h], cursorInVideo }  // missing → true
geometry:      [{ time, screenRect, contentRect, boundingRect?, contentScale, scaleFactor }]
cursor:        [{ time, location: [x,y] }]            // only when changed
clicks:        [{ time, location, button, isDown, clickCount }]
scrolls:       [{ time, location, delta: [dx,dy] }]
keys:          [{ time, keyCode, modifiers: [..], isRepeat }]
cursorSprites: [{ id, kind?, size, hotspot, png: base64 }]
cursorShapes:  [{ time, sprite }]
```
CG geometry types encode as arrays (`CGRect` → `[[x,y],[w,h]]`). Bump `version` on incompatible changes.

## Sandbox findings (measured, keep the app sandboxed)

- `NSEvent.mouseLocation` polling and global mouse/scroll monitors work without any permission.
- Global `NSEvent` **key** monitors never fire in the sandbox (need Accessibility) — don't use them.
- Listen-only `CGEvent.tapCreate(.cgSessionEventTap, …, .listenOnly)` works once Input Monitoring is
  granted; no entitlement or Info.plist key needed.
- `NSCursor.currentSystem` works in the sandbox.

## Roadmap status

| Item | Status |
|---|---|
| F1 input telemetry | Done |
| F2 cursor sprites | Done, incl. editor spec Phase 0 (hidden cursor, `cursorInVideo`, `kind`); a real recording still has to confirm kinds for I-beam/hand |
| F3 `.bettercapture` project bundle | **Not needed for editor v1**, which uses a `<name>.edit.json` sidecar (spec 0003, open question 2). Revisit when opening recordings from outside the output folder |
| F4 pause / resume | Done; audio sync across a pause still needs a real-recording check (see below) |
| F5 countdown | Next candidate |
| F6 audio robustness (mic hot-swap #208, gain #209, level meters #153) | Todo |
| F7 remember last selection (#172) | Todo |
| F8 Swift 6 language mode | Done (`chore/swift-6-mode`); needs one real recording to rule out runtime isolation crashes |
| S1+ editor (preview, timeline, auto-zoom, cursor smoothing, backgrounds, export) | Todo, consumes the telemetry JSON |

Reference repos for later work: `syi0808/screenize` and `imbhargav5/open-recorder` are Apache-2.0
(portable with attribution). `lzhgus/Capso` (BSL, bans screen-capture use) and
`lihaoyun6/QuickRecorder` (AGPL) are **ideas only — never copy code**.

## Known open items

- **F4 audio check:** record the Terminal window with system audio + mic on, running
  `while true; do date +%T.%N; afplay /System/Library/Sounds/Tink.aiff; done`; once without pausing
  and once with two pauses. Each audio track should match video length and ticks should line up
  with the clock across cuts. The one test so far had only silent system audio, which ended 1.5 s
  before the video.
- Not yet verified on real recordings: area capture mapping, a window moved/resized mid-recording.
- `RecorderViewModel` is over SwiftLint's type size limit (pre-existing); split it before adding more.

## Verifying against real recordings

Frame-level checks beat eyeballing. With `ffmpeg`/`ffprobe` (Homebrew):
- Stream lengths: `ffprobe -v error -show_entries stream=codec_type,duration,nb_frames -of compact <file>`
- Frame at a time: `ffmpeg -ss <t> -i <file> -frames:v 1 out.png`, crop around
  `InputTelemetry.videoPixel(...)` to check the cursor tip lands on the prediction.
