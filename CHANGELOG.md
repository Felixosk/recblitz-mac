# Changelog

## 2.1 (2026-10-05)

- The mode *Audio* is now *Audio only*
- *Mic* and *System* sound are two switches in all three modes, both on by
  default. *Audio only* can now record system sound, so an online call is
  transcribed with both sides and no video is kept
- If both switches are off, recording does not start (no silent files), the
  panel says why
- *Audio only* with system sound needs the screen recording permission and
  macOS 15; without it you get a banner instead of a quiet fallback to the
  microphone
- License changed to PolyForm Strict 1.0.0

## 2.0 (2026-09-26)

First public release.

- New look, matching the sister app MeetingBlitz: segment bars, the blue action
  pill, the latest recording as a list row with its actions, a result banner in
  the same ocean colours
- Settings split into four tabs: General, Transcript & notes, Screen recording,
  Google Drive
- Works without any setup: every recording becomes a Markdown note in
  `~/Documents/RecBlitz` (or any folder you choose)
- Google Drive is optional and off by default; sharing uses `rclone link`
- The latest recording survives a restart (title, Doc, video, note)
- Interface language follows the system on first run, banners are translated
- Config, logs and recordings live in `~/Library/Application Support/RecBlitz/`
- Universal binary (Apple Silicon and Intel), app icon, `--selftest`

## 1.x (July and August 2026, private)

- Voice notes with on-device transcription through Apple's SpeechAnalyzer
- Screen and region recording with microphone, optional system audio,
  countdown, pause, restart, discard and a floating control bar
- Webcam bubble that is recorded into the video
- Title and summary through the Claude command line
- Google Doc and Drive upload with upload progress and a share link on the clipboard
