# iOS PiP (mpv → AVSampleBufferDisplayLayer) + Native Danmaku

This documents the iOS Picture-in-Picture implementation on `test/ios-pip` (verified on a real
device, iOS 15+), and a design for native danmaku (not yet built). The PiP section reflects the
**shipped** behavior, including the non-obvious gotchas found while debugging on-device.

## Why this shape

media_kit/mpv renders into a **Flutter texture** (a `CVPixelBuffer`), so there is no
`AVPlayerLayer` for iOS system PiP to grab. The only route for a custom (non-AVPlayer) engine is
`AVSampleBufferDisplayLayer` (SBDL) + `AVPictureInPictureControllerContentSource` (iOS 15+). This is
the same constraint Bilibili's own player (ijkplayer — FFmpeg + VideoToolbox, custom-rendered)
faces. We **keep mpv** for all decode/streaming/DASH — no AVPlayer, no DASH proxy, no feature loss.

Per frame (only while PiP is active or about to be): the patched `VideoOutput` grabs the
just-rendered `CVPixelBuffer` and posts it via `NotificationCenter`; the app wraps it in a
`CMSampleBuffer` and enqueues it into the SBDL; PiP transport (play/pause/seek) is forwarded back to
`PlPlayerController`.

## Files in this repo

- `ios/Runner/SampleBufferPiPController.swift` — PiP controller, sample-buffer plumbing,
  `AVPictureInPictureSampleBufferPlaybackDelegate`, lifecycle delegate, the SBDL-backed view,
  primer pump, lock/unlock handling, and a dev `PerfMonitor` (CPU/mem/thermal).
- `ios/Runner/AppDelegate.swift` — registers the `com.piliplus/ios_pip` MethodChannel, configures
  `AVAudioSession(.playback)`, owns the PiP controller.
- `lib/plugin/pl_player/utils/ios_pip.dart` — Dart bridge + transport / lock callbacks.
- `lib/plugin/pl_player/controller.dart` — `_setupIosPip()` (gated on the `autoPiP` setting),
  `_pushIosPipState()` (transport sync; also pushed on every play/pause flip), lock/unlock track
  handling, and the resume-reload guard.
- `lib/pages/setting/models/play_settings.dart` — the **后台画中画 (`autoPiP`)** toggle now shows on
  iOS too (was Android-only) and controls iOS PiP.
- `docs/fork_VideoOutput.swift` — the media_kit fork patch (see below).

## Settings toggle (shared with Android)

iOS PiP reuses the existing Android **后台画中画 / `SettingBoxKey.autoPiP`** preference (default
**off**). When off, `_setupIosPip()` is skipped entirely — no native controller, no warm pump, no
frame tap, zero cost. The flag is read once at player creation, so toggling it takes effect on the
next playback (same as Android). There is intentionally **no separate iOS-only PiP setting**.

## The one external piece — patch your media_kit fork

The frame tap lives in `media_kit_video`, vendored via the git override
`github.com/My-Responsitories/media-kit @ version_1.2.5` (resolved into pub-cache). The full
patched file is committed at **`docs/fork_VideoOutput.swift`**; copy it over the pub-cache copy
**on the Mac that builds** (not the Linux dev box — that pub-cache is unrelated to the iOS build):

```bash
F=$(ls ~/.pub-cache/git/media-kit-*/media_kit_video/common/darwin/Classes/plugin/VideoOutput.swift | head -1)
cp docs/fork_VideoOutput.swift "$F"
```

The patch adds `MediaKitPiPTap` (a notification-driven tap registry with a warm-burst + ~2fps
trickle gate) and, in `_updateCallback`, an iOS-only block that — when the tap is enabled — probes
`hwdec-current` (~2s) and posts the rendered `CVPixelBuffer`. **Transfer it via git, never by paste**
(newlines must stay intact). Re-copy only when this file changes; pure Runner/Dart changes don't
need it.

## Build / wiring checklist (Xcode, on your Mac)

1. `SampleBufferPiPController.swift` must be in the **Runner** target's *Compile Sources*. New
   standalone `.swift` files are **not** auto-added — that's why `PerfMonitor` lives inside
   `SampleBufferPiPController.swift` rather than its own file (a separate file failed to compile
   with "Cannot find PerfMonitor in scope").
2. `Info.plist` already has `UIBackgroundModes → audio` — the only key PiP needs.
3. PiP code is `@available(iOS 15.0, *)`-gated; iOS 14 simply won't offer PiP.
4. Run on a **real device** (PiP + hardware decode don't work in the Simulator).

## How it actually works (confirmed on-device)

These are the load-bearing details — each was a real bug before it was understood.

- **Eligibility = primer + warm pump.** `isPictureInPicturePossible` must be true *at the instant
  the app backgrounds* for auto-PiP to fire. The fork **does not post frames while the app is in
  the foreground** (Flutter's compositor owns the texture's `CVPixelBuffer`, so `copyPixelBuffer()`
  only yields a frame once the app resigns active). So the SBDL would otherwise sit empty/with one
  stale frame and lose eligibility. Fix: `enqueuePrimerFrame()` seeds a black 320×180 frame at
  setup, and `startWarmPump()` re-enqueues one **~1/s while inline** to keep eligibility *latched*.
  The pump pauses during PiP (real frames take over) and stops on dispose.

- **Auto-PiP needs the video to look PLAYING — via the timebase rate.** iOS will not auto-start PiP
  for a video it considers paused, and for an SBDL it reads "paused vs playing" from the layer's
  `controlTimebase` **rate**. Our native `isPlaying` could be stale (`updateState` only fired on
  position ticks). So at `willResignActive` we **force the timebase to rate=1 *iff* `isPlaying`**.
  `isPlaying` is now pushed to native **on every play/pause flip** (the `stream.playing` listener),
  not just on position ticks, so a real pause reads false promptly. Net effect:
  - playing → background → rate=1 → auto-PiP fires (reliable);
  - genuinely paused → background → rate stays 0 → **no** auto-PiP (otherwise PiP would start on the
    black primer = a black landscape window, since a paused mpv emits no frames).

- **Frame tap is gated; foreground is silent and cheap.** Tap is warm (~2fps trickle) while inline,
  full rate only while PiP is on screen (`willStart`→full, `pipDidStop`/`didBecomeActive`→trickle).
  Cost inline is ~2 IOSurface retains/sec (~0% CPU). High-frequency diagnostics (pace, hwdec probe,
  frame-gap) are gated behind `verboseLog` (false) in the Swift controller.

- **Return from PiP — no decoder rebuild.** The resume lifecycle handler only calls
  `setVideoTrack(auto)` if the track was actually dropped; re-selecting an already-active track
  forces mpv to rebuild the whole decode chain (a visible hitch). Guarded in `_onAppLifecycleState`.

- **Lock screen → audio only, hwdec recovers on unlock.** When the device locks, iOS reclaims
  VideoToolbox from in-process apps → mpv would fall back to multi-second software decode for a
  window that isn't even shown on the lock screen. Detected two ways (`protectedDataWillBecomeUnavailable`
  and a hardware→software `hwdec-current` transition); we drop the video track (`setVideoTrack(no)`,
  audio continues) and tap off. On unlock we restore the track to re-acquire VideoToolbox (~4s
  decode-chain rebuild — the unavoidable cost of not running software decode while locked).

- **No black float when there's no video.** `dispose()` sets
  `canStartPictureInPictureAutomaticallyFromInline = false` (and `setup()` re-arms it) so
  backgrounding from a video-less screen can't auto-start PiP against the empty/primer layer.

- **`-11847 "Operation Interrupted"` recovery.** A lock/interruption can fail the SBDL; on a failed
  status we `flush()` **and reset the format description** so the next frame rebuilds cleanly
  (reusing a pre-interruption format description can re-fail the layer).

- **Vertical videos fill width.** The video `Obx` in `view.dart` is wrapped in `Positioned.fill`;
  without it the default `StackFit.loose` let `FittedBox` shrink the layer.

- **Source layer geometry.** The SBDL view is a 1×1 view inserted *behind* the Flutter view (z=0).
  A full-size layer doubled the video / left a stuck frame; PiP pulls full-resolution frames from
  the layer's buffer queue regardless of on-screen size, so 1×1 is fine.

- **Danmaku in PiP.** System PiP shows only SBDL contents, so danmaku doesn't appear (matches the
  official app). `pipNoDanmaku` is therefore Android-only. Burning danmaku in would mean
  compositing onto the pixel buffer before enqueuing (extra GPU) — see the design below.

## Debug toggles

- **Swift** `verboseLog` (in `SampleBufferPiPController`) — set `true` for per-2s pace / hwdec /
  frame-gap diagnostics. Off by default; low-frequency lifecycle/error logs stay on.
- **Dart** `PlPlayerController._perfMonitor` — set `true` to log `[Perf] cpu/mem/thermal` every 2s
  while playing (iOS has no public GPU-utilisation API; use Xcode's GPU gauge / Instruments).

---

# Native danmaku (design)

## Goal

Kill root-cause #2 from the heat analysis: the `canvas_danmaku` `Ticker` repaints a Flutter
`CustomPaint` **every display frame**, pinning Flutter's UI+raster threads to 120 Hz on ProMotion
while the video plays. Moving danmaku into **Core Animation** lets the system render server animate
it, so Flutter's scene goes static and idles down.

## Why it removes the 120 Hz cost

A `CABasicAnimation` on a layer's `position` is interpolated and composited by the render server
(`backboardd`) — a separate process. Once you hand off the animation, **your app's main thread and
the Flutter engine do nothing per frame**. Compositing pre-rasterized layers at 120 Hz is the cheap
work the display does anyway; it is not Flutter rebuilding + re-rasterizing a scene. With video on
an `AVPlayerLayer`/SBDL *and* danmaku on CALayers, Flutter has no animation left → it can drop to
~1 Hz. That's the native-player power profile.

## Architecture

- A Flutter **`UiKitView`** (iOS PlatformView) hosting a `DanmakuContainerView` (plain `UIView`),
  placed in the player `Stack` above the video, replacing the `canvas_danmaku` widget *on iOS only*
  (keep `canvas_danmaku` for Android, or port this with `SurfaceView` + `Choreographer` later).
- A `MethodChannel` (e.g. `com.piliplus/native_danmaku`) bridging `DanmakuController` ⇄ the view.

### Per-danmaku layers

- **Scroll**: one `CALayer` whose `contents` is a pre-rasterized `CGImage` of the (stroked) text.
  Add a `CABasicAnimation` on `position.x` from just off the right edge to fully off the left, with
  `duration = (screenWidth + textWidth) / speed`. Remove the layer in the animation's completion.
- **Top/bottom (static)**: `CALayer` centered horizontally; a timer removes it after the dwell.
- **Lane allocation**: reuse `canvas_danmaku`'s logic — track, per lane, when the tail of the last
  danmaku clears the right edge; place a new one in the first free lane.

### Text rasterization (once, then cached)

Render each string to a `CGImage` once using Core Text / `NSAttributedString` with stroke
(`NSStrokeWidth`/`NSStrokeColor`) + fill, then `layer.contents = cgImage`. This mirrors
`canvas_danmaku`'s `toImageSync` caching — layout cost is paid once, not per frame. Cache by
(text, fontSize, color, strokeWidth).

### Pause / resume — no ticking

Freeze/thaw *all* animations with the standard CALayer technique (matches video pause without any
per-frame work):

```swift
func pause(_ layer: CALayer) {
  let t = layer.convertTime(CACurrentMediaTime(), from: nil)
  layer.speed = 0
  layer.timeOffset = t
}
func resume(_ layer: CALayer) {
  let paused = layer.timeOffset
  layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
  let since = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
  layer.beginTime = since
}
```

Apply to the container layer to pause every danmaku at once. Wire to the player status listener
exactly like `lib/pages/danmaku/view.dart` does today (`status.isPlaying ? resume : pause`).

### Channel surface

`addScroll(text,color,fontSize,strokeWidth,speed)`, `addStatic(...)`, `pause()`, `resume()`,
`clear()` (on seek), `setOpacity(double)`, `setSpeed(double)`, `setArea/limit(...)`. The existing
`videoPositionListen` in `lib/pages/danmaku/view.dart` already coalesces to 100 ms and calls
`addDanmaku` — point those calls at the channel on iOS.

## Scroll animation sketch

```swift
func addScroll(image: CGImage, size: CGSize, lane: Int, speed: CGFloat) {
  let layer = CALayer()
  layer.contents = image
  layer.frame = CGRect(x: bounds.width, y: CGFloat(lane) * laneHeight, width: size.width, height: size.height)
  containerView.layer.addSublayer(layer)

  let distance = bounds.width + size.width
  let anim = CABasicAnimation(keyPath: "position.x")
  anim.fromValue = bounds.width + size.width / 2
  anim.toValue = -size.width / 2
  anim.duration = CFTimeInterval(distance / speed)
  anim.timingFunction = CAMediaTimingFunction(name: .linear)
  anim.isRemovedOnCompletion = true
  anim.delegate = removalDelegate(for: layer)   // remove layer on finish
  layer.add(anim, forKey: "scroll")
}
```

## Trade-offs

- **Win**: per-frame danmaku motion leaves Flutter's render loop entirely → Flutter idles, ProMotion
  steps down, big battery/heat reduction during playback. This is the structural fix.
- **Cost**: a real iOS-specific engine (text, lanes, lifecycle) to build and maintain; Android keeps
  `canvas_danmaku` (or needs its own port). PlatformView overlay compositing has some cost, but the
  danmaku *motion* itself becomes free, which is the dominant term.
- **Cheaper alternative**: if a full native engine is too much, just **throttle the `canvas_danmaku`
  Ticker** to ~30–60 fps in your fork (`bggRGjQaUbCoE/canvas_danmaku`) — skip ticks below a frame
  interval. Doesn't eliminate Flutter work but cuts it 2–4× with a few lines and no rewrite. Good
  first step to measure the delta before committing to native.
