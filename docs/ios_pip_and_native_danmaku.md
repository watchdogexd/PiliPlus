# iOS PiP (mpv → AVSampleBufferDisplayLayer) + Native Danmaku

This documents the iOS Picture-in-Picture implementation added on `fix/ios-experiment`, and a
design for native danmaku. **None of this is compile-tested** (built on Linux); treat the native
Swift as a first cut to iterate on with Xcode + a real device. Tuning points are marked `TUNE:`.

## Why this shape

media_kit/mpv renders into a **Flutter texture** (a `CVPixelBuffer`), so there is no
`AVPlayerLayer` for iOS system PiP to grab. The only route for a custom (non-AVPlayer) engine is
`AVSampleBufferDisplayLayer` + `AVPictureInPictureControllerContentSource` (iOS 15+). This is the
same constraint Bilibili's own player (ijkplayer — FFmpeg + VideoToolbox, custom-rendered) faces,
so this mirrors how the official app must do it. We **keep mpv** for all decode/streaming/DASH —
no AVPlayer, no DASH proxy, no header hacks, no feature loss.

Per frame: the patched `VideoOutput` grabs the just-rendered `CVPixelBuffer` and posts it; the app
wraps it in a `CMSampleBuffer` and enqueues into the display layer; PiP transport (play/pause/seek)
is forwarded back to `PlPlayerController`.

## Files already changed in this repo

- `ios/Runner/SampleBufferPiPController.swift` — **new**. PiP controller, sample-buffer plumbing,
  `AVPictureInPictureSampleBufferPlaybackDelegate`, lifecycle delegate, the SBDL-backed view.
- `ios/Runner/AppDelegate.swift` — registers the `com.piliplus/ios_pip` MethodChannel, configures
  `AVAudioSession(.playback)`, owns the PiP controller.
- `lib/plugin/pl_player/utils/ios_pip.dart` — **new**. Dart bridge + transport callbacks.
- `lib/plugin/pl_player/controller.dart` — `_setupIosPip()` (attaches PiP to the texture once the
  `VideoController.id` is known), `_pushIosPipState()` (keeps the transport bar in sync, called
  from `updatePositionSecond`), and `enterPip()` now branches to iOS.
- `lib/pages/video/widgets/header_control.dart`, `lib/pages/live_room/widgets/header_control.dart`
  — PiP button now shows + works on iOS.

## The one external piece — patch your media_kit fork

The frame tap lives in `media_kit_video`, which you vendor via the git override
`github.com/My-Responsitories/media-kit @ version_1.2.5` (resolved into pub-cache). Apply this to
that fork and bump the ref (or use a local `path:` override while developing).

**File:** `media_kit_video/common/darwin/Classes/plugin/VideoOutput.swift`

1. Add a tiny tap registry (top-level in the file, iOS only):

```swift
#if os(iOS)
// Tracks which texture (if any) is currently feeding iOS PiP. App toggles this via notification.
final class MediaKitPiPTap {
  static let shared = MediaKitPiPTap()
  private var enabledTextureId: Int64 = -1
  private init() {
    NotificationCenter.default.addObserver(
      forName: Notification.Name("MediaKitPiPTapControl"), object: nil, queue: nil
    ) { [weak self] note in
      guard let self = self, let info = note.userInfo else { return }
      let enabled = (info["enabled"] as? Bool) ?? false
      let tid = (info["textureId"] as? NSNumber)?.int64Value ?? -1
      self.enabledTextureId = enabled ? tid : -1
    }
  }
  func isEnabled(_ id: Int64) -> Bool { id != -1 && id == enabledTextureId }
}
#endif
```

2. In `_updateCallback()`, right after `texture.render(size)` (before the
   `registry.textureFrameAvailable` block), forward the frame when the tap is on:

```swift
    texture.render(size)

    #if os(iOS)
    // PiP tap: hand the freshly rendered frame to the app only while PiP consumes this texture.
    if MediaKitPiPTap.shared.isEnabled(textureId),
       let pb = texture.copyPixelBuffer()?.takeRetainedValue() {
      NotificationCenter.default.post(
        name: Notification.Name("MediaKitPiPFrame"), object: nil,
        userInfo: ["textureId": NSNumber(value: textureId), "pixelBuffer": pb])
    }
    #endif

    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      that.registry.textureFrameAvailable(that.textureId)
    }
```

`copyPixelBuffer()` already exists on `TextureHW`/`TextureSW` (the `FlutterTexture` API). If the
compiler complains that `ResizableTextureProtocol` doesn't expose it, add
`func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?` to that protocol (both texture classes already
implement it).

> `TUNE:` the tap reads `textureContexts.current` from the worker thread while Flutter reads it on
> its raster thread. Triple-buffering makes this usually safe; if you see tearing in PiP, post the
> notification from inside the existing `DispatchQueue.main.sync` block instead.

## Build / wiring checklist (Xcode, on your Mac)

1. Add `SampleBufferPiPController.swift` to the **Runner** target (Xcode usually auto-adds files in
   `ios/Runner/`; confirm it's in *Build Phases → Compile Sources*).
2. `Info.plist` already has `UIBackgroundModes → audio` — that's the only key PiP needs here.
3. Deployment target is **14.0**; the PiP code is `@available(iOS 15.0, *)`-gated, so iOS 14 simply
   won't offer PiP. Bump to 15 if you'd rather not carry the guard.
4. Apply the fork patch and `flutter pub get` (or point the override at a local path).
5. Run on a **real device** (PiP and hardware decode don't work in the Simulator).

## Known gotchas to verify on-device (`TUNE:`)

- **Source layer visibility.** The SBDL view is inserted *behind* the Flutter view. PiP needs the
  layer in a window with content; occluded-but-present is usually fine, but if
  `isPictureInPicturePossible` stays false, give the SBDL a small visible region or bring it
  forward over the video area.
- **VOD scrubber.** `timeRangeForPlayback` reports `0..duration`; we call `invalidatePlaybackState`
  on each `updateState`. If the scrubber drifts, push position more often than 1 Hz while in PiP.
- **Auto-enter.** `canStartPictureInPictureAutomaticallyFromInline = true` makes iOS start PiP when
  the app backgrounds on the video page. The frame tap is enabled in `setup()`; if auto-enter
  misses the first frames, also enable the tap on `applicationWillResignActive`.
- **Background decode.** Commit `e36ec96` disables the video track in background to keep hwdec.
  That logic must **not** fire while PiP is active (PiP is "background" but needs frames). Gate the
  `setVideoTrack(VideoTrack.no())` path on "not currently in PiP".
- **Danmaku in PiP.** System PiP shows only the SBDL contents, so danmaku won't appear — matches the
  official app. To burn danmaku in, composite it onto the pixel buffer before enqueuing (extra GPU).

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
