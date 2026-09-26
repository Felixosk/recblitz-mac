# RecBlitz, a guide for Claude Code

You are helping get RecBlitz running on this Mac, or extending it. This
directory is the complete source.

**Build it locally and do real diagnosis** (build, launch, read logs, render the
panel). Don't guess. Every trap below cost the author several attempts and is
written down for a reason.

## 1. What this is

A native macOS **menu bar app** (SwiftUI + AppKit, **SwiftPM, no Xcode project**).
It records a voice note or the screen, transcribes on the Mac and writes a
Markdown note, optionally a Google Doc plus a Drive upload.

**No dock icon, no main window.** Everything hangs off an `NSStatusItem` and
self-managed `NSPanel`s (panel, settings, banner, control bar, countdown,
webcam bubble). The app is never the active application, and a lot of SwiftUI's
convenience assumes it is. That explains most of the quirks below.

## 2. Layout

| Path | What |
|---|---|
| `Sources/RecBlitz/main.swift` | `AppDelegate`: status item, recording state machine, pipeline hand-off, CLI test modes |
| `Sources/RecBlitz/RecPanel.swift` | the dropdown panel window (material, placement, click-outside to close) |
| `Sources/RecBlitz/RecPanelView.swift` | the panel content |
| `Sources/RecBlitz/SettingsPanel.swift` | settings window and its four tabs |
| `Sources/RecBlitz/Chrome.swift` | shared UI pieces: segment bar, action pill, chips, row buttons |
| `Sources/RecBlitz/ConfigStore.swift` | `config.json`, shared with `pipeline.py` |
| `Sources/RecBlitz/Transcriber.swift` | Apple SpeechAnalyzer (macOS 26) |
| `Sources/RecBlitz/Recorder.swift` | microphone-only recording (AVCaptureSession, device choice) |
| `Sources/BlitzKit/` | screen recording engine: `ScreenRecorder`, `RegionPicker`, `CountdownOverlay`, `RecordingControlBar`, `WebcamBubble`, `AudioExtractor`, `AudioMixdown`, `PanelDock` |
| `pipeline.py` | title/summary (Claude CLI), Markdown note, Google Doc and video upload (rclone). Bundled into `Contents/Resources` |
| `design/make_icon.swift` | draws `AppIcon.icns` |
| `docs/` | README images, rendered from HTML around real app renders |

## 3. Build and run

```bash
./build.sh                    # universal binary, dist/RecBlitz.app, runs both self-tests
open dist/RecBlitz.app        # ALWAYS via open, never the binary directly
pkill -x RecBlitz && sleep 1 && open dist/RecBlitz.app   # restart while testing
```

Starting the binary directly from a shell breaks everything tied to the app's
identity: camera and microphone permission (TCC), excluding the app's own
windows from the screen recording, the single-instance behaviour. Use `open`.

If a new file in `Sources/BlitzKit` is "not in scope" or SwiftPM says
"command ... not registered", delete `.build` and build again.

## 4. Test modes (no menu bar icon, no side effects)

| Flag | Effect |
|---|---|
| `--selftest` | pure logic checks, `build.sh` fails on them |
| `--render-panel <png> [idle\|recording\|paused\|armed\|uploading\|empty\|settings=N] [--light] [--lang=en] [--demo-config] [--mode=screen]` | renders panel or settings through a real offscreen window, so AppKit controls draw properly. `--demo-config` ignores the real `config.json`: use it for any image that leaves the machine |
| `--transcribe <audio> [locale]` | transcribes a file |
| `--demo-banner`, `--demo-settings`, `--demo-webcam` | show one UI piece for inspection |
| `python3 pipeline.py --selftest` | pipeline logic without network |

**A test mode must never run the real pipeline.** An early `--demo-record`
went through the normal stop path and uploaded a test video to Drive, shared
it publicly and created a Doc. Test modes talk to the recorder directly.

## 5. Traps

**Liquid Glass in AppKit.** An `NSGlassEffectView` added as a *subview* covers
the view's own drawing, subviews always draw on top. Use SwiftUI's
`.glassEffect` as a background, or `glass.contentView = content`. White text
on glass is unreadable over light backgrounds, use `.primary`.

**`CALayer` does not resize with its view.** Set frames in `layout()`.

**Points vs pixels.** `SCDisplay.width/height` and `contentRect` are points. Using
them as pixel sizes records a Retina screen at half resolution. Multiply by
`filter.pointPixelScale`. `AVVideoProfileLevelKey` belongs inside
`AVVideoCompressionPropertiesKey`, at the top level AVAssetWriter throws.

**Microphone and screen in ONE `SCStream`** (`captureMicrophone`, macOS 15+).
Two separate recorders run on two clocks and drift apart audibly over minutes.

**Start the writer session at the first video frame**, not the first audio
buffer, or the video opens with a black block. Only write frames with
`SCFrameStatus.complete`. H.264 needs even dimensions.

**ScreenCaptureKit has no pause.** The writer drops samples while paused and
shifts every later timestamp back by the pause, video and both audio tracks by
the same amount.

**System audio means two audio tracks**, and most players (QuickTime, the Drive
preview) play only the first. `AudioMixdown` remixes with ffmpeg (`-ac 2`),
best effort.

**Audio extraction:** `AVAssetExportPresetPassthrough` fails with "Operation
Stopped" on a video. Use `AVAssetExportPresetAppleM4A`.

**The app excludes its own windows from the recording**, except the webcam
bubble (`includeWindowIDs`). Never recreate the bubble when recording starts:
that moves it back to its default place and changes the window ID that lets it
into the video.

**Hover on floating panels:** `NSTrackingArea` does not deliver reliable events
to a non-activating panel of a background app. Use a global `.mouseMoved`
monitor and test against `panel.frame`.

**Click outside closes the panel**, except clicks on RecBlitz's own floating
pieces. The global monitor gets no `event.window` (the event belongs to another
app), so check window frames under `NSEvent.mouseLocation` (`owns(_:)`).

**Resize after a layout change in the next run loop pass**, SwiftUI has not
laid out the new content before that.

**No `.menu` picker in a non-activating panel**, it hangs. Use segments or a
radio list.

**Long hint texts need `.fixedSize(horizontal: false, vertical: true)`**, or
they get cut off instead of wrapping. `build.sh` has a lint for it.

**rclone and Google Docs:** HTML becomes a Doc only with `copy` (a folder with
exactly one file) plus `--drive-import-formats html
--drive-allow-import-name-change`. `copyto` fails. The converted Doc shows up in
`lsjson` with an export extension (`.docx`), so match by prefix.

**rclone uploads but does not share.** Without `rclone link` (or the optional
`share_script_url`) recipients land on "request access".

**`AVCaptureAudioFileOutput.stop()` is asynchronous**, the file is only complete
in the delegate callback.

## 6. Signing

Without `signing.local` the build is signed ad-hoc and macOS forgets the
microphone, camera and screen permissions after every rebuild. See
`signing.local.example`.
