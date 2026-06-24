import AVKit
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import QuartzCore
import UIKit

// iOS Picture-in-Picture for a libmpv/media_kit-backed player.
//
// media_kit renders mpv frames into a Flutter texture (a CVPixelBuffer), so there is
// no AVPlayerLayer for the system to pull into PiP. The only route for a custom
// (non-AVPlayer) engine is AVSampleBufferDisplayLayer + an
// AVPictureInPictureControllerContentSource (iOS 15+). Frames arrive from the patched
// VideoOutput in the media_kit fork via NotificationCenter.
//
// Diagnostics are routed through the channel ("log") so they appear in `flutter run`.
@available(iOS 15.0, *)
final class SampleBufferPiPController: NSObject {
  static let frameNotification = Notification.Name("MediaKitPiPFrame")
  static let frameTextureIdKey = "textureId"
  static let framePixelBufferKey = "pixelBuffer"
  static let tapControlNotification = Notification.Name("MediaKitPiPTapControl")
  static let tapEnabledKey = "enabled"
  static let tapTextureIdKey = "textureId"
  static let tapFullRateKey = "fullRate"
  static let hwdecNotification = Notification.Name("MediaKitPiPHwdec")  // fork -> app, diagnostic

  private let channel: FlutterMethodChannel
  private var viewAttached = false

  private let sampleBufferView = SampleBufferDisplayView()
  private var pipController: AVPictureInPictureController?

  private var activeTextureId: Int64 = -1
  private var formatDescription: CMVideoFormatDescription?
  private var lastPixelBufferWidth: Int = 0
  private var lastPixelBufferHeight: Int = 0

  private var frameCount = 0
  private var frameMismatchLogged = false
  private var timebase: CMTimebase?

  // Frame-pacing diagnostics: detect stalls/drops in the PiP layer.
  private var paceWindowStart: CFTimeInterval = 0
  private var paceFrames = 0
  private var enqueueSkips = 0
  private var lastEnqueueTime: CFTimeInterval = 0
  private var paceMaxGap: CFTimeInterval = 0  // worst frame-to-frame gap this window (judder)

  // Set once we've dropped to audio-only because the screen locked / hardware decode was
  // reclaimed during PiP; cleared when the screen unlocks or we return to the app.
  private var lockedAudioOnly = false
  // Whether we've seen hardware decode this PiP session. A hardware->software transition means
  // the OS reclaimed the decoder (screen lock); a stream that was software from the start (user
  // disabled HA) must NOT be mistaken for that.
  private var sawHardware = false

  private var isPlaying = false
  private var isLive = false
  private var positionSeconds: Double = 0
  private var durationSeconds: Double = 0

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()

    NotificationCenter.default.addObserver(
      self, selector: #selector(onFrame(_:)), name: Self.frameNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onHwdec(_:)), name: Self.hwdecNotification, object: nil)
    // Device lock / unlock (fires when the user has a passcode). While locked the PiP float is
    // not shown, so we drop video decode to audio-only and restore it (re-acquiring hardware
    // decode) on unlock.
    NotificationCenter.default.addObserver(
      self, selector: #selector(onProtectedDataUnavailable),
      name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onProtectedDataAvailable),
      name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

    log("init; PiP supported=\(AVPictureInPictureController.isPictureInPictureSupported())")
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  private func log(_ s: String) {
    let stamped = String(format: "%.3f %@", CACurrentMediaTime(), s)
    NSLog("[PiP] \(stamped)")
    DispatchQueue.main.async { self.channel.invokeMethod("log", arguments: stamped) }
  }

  @objc private func onWillResignActive() {
    // Only arm the tap when a video is actually set up. After dispose (left the player)
    // activeTextureId is -1; arming here would feed/keep the layer warm for nothing.
    if pipController != nil, activeTextureId != -1 {
      log("willResignActive -> enable tap")
      setTap(enabled: true)
    }
  }

  @objc private func onDidBecomeActive() {
    // Back in the app (screen on): the resume lifecycle handler restores the video track.
    lockedAudioOnly = false
    // Returning to the app should dismiss the float (the inline player takes over again).
    if pipController?.isPictureInPictureActive == true {
      log("didBecomeActive while PiP active -> stop PiP")
      pipController?.stopPictureInPicture()
    } else if pipController != nil {
      // Keep the layer warm (trickle) so a later background still auto-PiPs.
      setTap(enabled: true, fullRate: false)
    }
  }

  // mpv's hwdec-current, read by the fork while the PiP tap is on.
  // "videotoolbox" = hardware decode; "no"/sw = the OS reclaimed hardware (it does this when
  // the device locks). Losing hardware mid-PiP is our most reliable "screen locked" signal:
  // drop to audio-only so we don't keep burning CPU on software decode for a hidden window.
  @objc private func onHwdec(_ note: Notification) {
    let value = (note.userInfo?["value"] as? String) ?? "?"
    log("hwdec-current at PiP tap: \(value)")
    if value.hasPrefix("videotoolbox") {
      sawHardware = true
    } else if sawHardware, value != "?", pipController?.isPictureInPictureActive == true {
      enterAudioOnly(reason: "hwdec lost (\(value))")
    }
  }

  // Lock / unlock (passcode users). protectedDataUnavailable is a proactive lock signal that
  // beats the hwdec-loss one above; whichever fires first wins (enterAudioOnly is idempotent).
  @objc private func onProtectedDataUnavailable() {
    if pipController?.isPictureInPictureActive == true {
      enterAudioOnly(reason: "device locked")
    }
  }

  @objc private func onProtectedDataAvailable() {
    guard lockedAudioOnly, pipController?.isPictureInPictureActive == true else { return }
    lockedAudioOnly = false
    log("unlocked -> restore video, full rate")
    channel.invokeMethod("screenUnlocked", arguments: nil)
    setTap(enabled: true, fullRate: true)
  }

  private func enterAudioOnly(reason: String) {
    guard !lockedAudioOnly else { return }
    lockedAudioOnly = true
    log("\(reason) during PiP -> audio only (drop video, tap off)")
    setTap(enabled: false)  // the float is hidden while locked; stop feeding frames
    channel.invokeMethod("screenLocked", arguments: nil)
  }

  // MARK: - MethodChannel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "setup":
      let args = call.arguments as? [String: Any]
      let textureId = (args?["textureId"] as? NSNumber)?.int64Value ?? -1
      isLive = (args?["isLive"] as? Bool) ?? false
      setup(textureId: textureId)
      result(nil)
    case "start":
      start()
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "dispose":
      dispose()
      result(nil)
    case "updateState":
      let args = call.arguments as? [String: Any]
      isPlaying = (args?["isPlaying"] as? Bool) ?? isPlaying
      positionSeconds = (args?["position"] as? NSNumber)?.doubleValue ?? positionSeconds
      durationSeconds = (args?["duration"] as? NSNumber)?.doubleValue ?? durationSeconds
      syncTimebase()
      pipController?.invalidatePlaybackState()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  private func setup(textureId: Int64) {
    attachViewIfNeeded()
    setupTimebaseIfNeeded()
    activeTextureId = textureId
    formatDescription = nil
    frameCount = 0
    frameMismatchLogged = false
    paceWindowStart = 0
    paceFrames = 0
    enqueueSkips = 0
    lastEnqueueTime = 0
    lockedAudioOnly = false
    sawHardware = false

    // New stream: clear any frames from the previous one.
    sampleBufferView.displayLayer.flushAndRemoveImage()

    // Create the controller ONCE; it's bound to the persistent display layer. Recreating it
    // on every texture switch deallocated the in-flight controller -> EXC_BAD_ACCESS.
    if pipController == nil {
      let content = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: sampleBufferView.displayLayer, playbackDelegate: self)
      let controller = AVPictureInPictureController(contentSource: content)
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      controller.delegate = self
      pipController = controller
    }
    // Re-arm auto-PiP for this video (dispose() turns it off so backgrounding from a
    // video-less screen can't auto-start PiP against an empty layer -> black float).
    pipController?.canStartPictureInPictureAutomaticallyFromInline = true
    // Seed the layer NOW with one synthetic frame so isPictureInPicturePossible is true
    // immediately. The decoder's first real frame can take seconds (network load); without a
    // primer, backgrounding during that window can't auto-PiP because the layer is empty.
    enqueuePrimerFrame()
    // Warm the layer (trickle) so native auto-PiP stays possible the instant we background.
    setTap(enabled: true, fullRate: false)
    log("setup textureId=\(textureId) isLive=\(isLive)")
  }

  private func setupTimebaseIfNeeded() {
    guard timebase == nil else { return }
    var tb: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
    guard let tb = tb else { return }
    timebase = tb
    sampleBufferView.displayLayer.controlTimebase = tb
    CMTimebaseSetTime(tb, time: .zero)
    CMTimebaseSetRate(tb, rate: 0.0)
  }

  private func syncTimebase() {
    guard let tb = timebase else { return }
    CMTimebaseSetTime(tb, time: CMTime(seconds: positionSeconds, preferredTimescale: 600))
    CMTimebaseSetRate(tb, rate: isPlaying ? 1.0 : 0.0)
  }

  private func start() {
    guard let controller = pipController else {
      log("start: NO controller (setup not run yet)")
      return
    }
    setTap(enabled: true)
    log("start requested; possible=\(controller.isPictureInPicturePossible) frames=\(frameCount)")
    attemptStart(controller, retries: 25)  // ~2.5s
  }

  private func attemptStart(_ controller: AVPictureInPictureController, retries: Int) {
    if controller.isPictureInPictureActive { return }
    // Require at least one enqueued frame; starting with an empty layer fails with
    // PGPegasusErrorDomain -1003.
    if controller.isPictureInPicturePossible && frameCount > 0 {
      log("possible + frames=\(frameCount) -> startPictureInPicture")
      controller.startPictureInPicture()
      return
    }
    if retries <= 0 {
      log("gave up: possible=\(controller.isPictureInPicturePossible) frames=\(frameCount) layerStatus=\(sampleBufferView.displayLayer.status.rawValue)")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.attemptStart(controller, retries: retries - 1)
    }
  }

  private func stop() { pipController?.stopPictureInPicture() }

  private func dispose() {
    setTap(enabled: false)
    // Turn OFF auto-PiP: with no video, backgrounding must not auto-start PiP against the
    // (flushed/primer-only) layer and show a black float. setup() re-arms it for the next video.
    pipController?.canStartPictureInPictureAutomaticallyFromInline = false
    // Dismiss the float if it's up. Keep the controller (it's created once and bound to the
    // persistent layer); the next video reuses it. Nil-ing it here can abort the dismissal.
    if pipController?.isPictureInPictureActive == true {
      pipController?.stopPictureInPicture()
    }
    activeTextureId = -1
    frameCount = 0
    formatDescription = nil
    sampleBufferView.displayLayer.flushAndRemoveImage()
    log("dispose: tap off, auto-PiP off, PiP stopped")
  }

  // The display layer must live in the on-screen view hierarchy for PiP to be possible.
  // The FlutterViewController exists by the time a video is playing (when setup runs).
  private func attachViewIfNeeded() {
    guard !viewAttached else { return }
    guard let host = Self.findFlutterView() else {
      log("attachView: no Flutter view found yet")
      return
    }
    // Keep the source view effectively invisible (1x1). A subview renders ON TOP of the
    // FlutterView, so a full-size layer would double the video and leave a stuck frame when
    // PiP stops. PiP pulls full-resolution frames from the layer's buffer queue regardless of
    // the on-screen view size.
    sampleBufferView.translatesAutoresizingMaskIntoConstraints = true
    sampleBufferView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    sampleBufferView.isUserInteractionEnabled = false
    host.insertSubview(sampleBufferView, at: 0)
    viewAttached = true
    log("attachView: attached 1x1 display layer to Flutter view")
  }

  private static func findFlutterView() -> UIView? {
    func search(_ vc: UIViewController?) -> FlutterViewController? {
      guard let vc = vc else { return nil }
      if let f = vc as? FlutterViewController { return f }
      if let p = vc.presentedViewController, let f = search(p) { return f }
      for c in vc.children { if let f = search(c) { return f } }
      return nil
    }
    for scene in UIApplication.shared.connectedScenes {
      guard let ws = scene as? UIWindowScene else { continue }
      for w in ws.windows {
        if let f = search(w.rootViewController) { return f.view }
      }
    }
    return nil
  }

  // enabled:false stops the tap entirely. enabled:true with fullRate:false keeps the layer
  // "warm" at ~2 fps (cheap) so iOS auto-PiP is possible the instant we background; fullRate:true
  // feeds every frame, used only while the PiP window is on screen.
  private func setTap(enabled: Bool, fullRate: Bool = false) {
    NotificationCenter.default.post(
      name: Self.tapControlNotification, object: nil,
      userInfo: [
        Self.tapEnabledKey: enabled,
        Self.tapTextureIdKey: NSNumber(value: activeTextureId),
        Self.tapFullRateKey: fullRate,
      ])
  }

  // MARK: - Frame ingestion

  @objc private func onFrame(_ note: Notification) {
    guard let info = note.userInfo,
          let tid = (info[Self.frameTextureIdKey] as? NSNumber)?.int64Value,
          let pbObj = info[Self.framePixelBufferKey],
          CFGetTypeID(pbObj as CFTypeRef) == CVPixelBufferGetTypeID()
    else { return }
    if tid != activeTextureId {
      if !frameMismatchLogged {
        log("frame for texture \(tid) but active=\(activeTextureId); ignoring")
        frameMismatchLogged = true
      }
      return
    }
    let pixelBuffer = pbObj as! CVPixelBuffer
    frameCount += 1
    if frameCount == 1 {
      log("first frame texture=\(tid) \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
    }
    enqueue(pixelBuffer)
  }

  // A single black frame to make the display layer non-empty (PiP-eligible) before the decoder
  // produces anything. Replaced by the first real frame; frameCount stays 0 so the manual-start
  // path still waits for real video (no black flash on the PiP button).
  private func enqueuePrimerFrame() {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    guard CVPixelBufferCreate(
            kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let buffer = pb
    else { return }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    enqueue(buffer)
    log("primer frame enqueued (PiP eligible before first decode)")
  }

  private func enqueue(_ pixelBuffer: CVPixelBuffer) {
    let layer = sampleBufferView.displayLayer
    if layer.status == .failed {
      log("layer failed (\(String(describing: layer.error))) -> flush")
      layer.flush()
    }

    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    if formatDescription == nil || w != lastPixelBufferWidth || h != lastPixelBufferHeight {
      formatDescription = nil
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
      lastPixelBufferWidth = w
      lastPixelBufferHeight = h
    }
    guard let fd = formatDescription else { return }

    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    let err = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: fd,
      sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    guard err == noErr, let sb = sampleBuffer else { return }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
      as? [NSMutableDictionary], let dict = attachments.first {
      dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
    }

    if layer.isReadyForMoreMediaData {
      layer.enqueue(sb)
    } else {
      enqueueSkips += 1  // layer back-pressure: a dropped frame
    }
    logPacing(layer: layer)
  }

  // Logs effective fps, dropped frames, and any long gap so playback stalls are visible.
  private func logPacing(layer: AVSampleBufferDisplayLayer) {
    let now = CACurrentMediaTime()
    let fullRate = timebase != nil && CMTimebaseGetRate(timebase!) > 0
    if lastEnqueueTime != 0 {
      let gap = now - lastEnqueueTime
      if gap > paceMaxGap { paceMaxGap = gap }
      // Only meaningful at full rate (PiP active); the 2 fps warm trickle has ~0.5s gaps.
      if gap > 0.4 && fullRate {
        log(String(format: "frame GAP %.3fs status=%d skips=%d", gap, layer.status.rawValue, enqueueSkips))
      }
    }
    lastEnqueueTime = now
    if paceWindowStart == 0 { paceWindowStart = now }
    paceFrames += 1
    let elapsed = now - paceWindowStart
    if elapsed >= 2.0 {
      let fps = Double(paceFrames) / elapsed
      // maxgap reveals frame-to-frame judder that the fps average hides: at a smooth 30fps it
      // should be ~0.033s. A maxgap far above 1/fps while fps looks fine == visible stutter.
      log(String(format: "pace %.1ffps maxgap=%.3fs skips=%d ready=%@ status=%d err=%@",
                 fps, paceMaxGap, enqueueSkips,
                 layer.isReadyForMoreMediaData ? "Y" : "N",
                 layer.status.rawValue,
                 layer.error == nil ? "-" : "\(layer.error!)"))
      paceWindowStart = now
      paceFrames = 0
      enqueueSkips = 0
      paceMaxGap = 0
    }
  }
}

// MARK: - Transport delegate

@available(iOS 15.0, *)
extension SampleBufferPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ c: AVPictureInPictureController, setPlaying playing: Bool
  ) {
    isPlaying = playing  // optimistic so the play/pause icon tracks immediately
    if let tb = timebase { CMTimebaseSetRate(tb, rate: playing ? 1.0 : 0.0) }
    channel.invokeMethod("setPlaying", arguments: playing)
    c.invalidatePlaybackState()
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ c: AVPictureInPictureController
  ) -> CMTimeRange {
    if isLive { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    let start = CMTime(seconds: 0, preferredTimescale: 600)
    let dur = CMTime(seconds: max(durationSeconds, 0.001), preferredTimescale: 600)
    return CMTimeRange(start: start, duration: dur)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
    return !isPlaying
  }

  func pictureInPictureController(
    _ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    log("skipByInterval \(skipInterval.seconds)")
    channel.invokeMethod("skip", arguments: skipInterval.seconds)
    completionHandler()
  }
}

// MARK: - PiP window lifecycle

@available(iOS 15.0, *)
extension SampleBufferPiPController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
    log("WILL start -> full rate")
    // Switch to full rate BEFORE the window animates in, so the float opens already at
    // 30fps instead of showing a brief stretch of the ~2fps warm trickle.
    setTap(enabled: true, fullRate: true)
    channel.invokeMethod("pipWillStart", arguments: nil)
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
    log("DID start")
    setTap(enabled: true, fullRate: true)  // idempotent; ensure full rate
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
    // applicationState is authoritative for *why* PiP stopped, with no race against
    // Flutter's lifecycle channel: .active => the app is returning to foreground; otherwise
    // the user closed the float while still backgrounded.
    let foreground = UIApplication.shared.applicationState == .active
    log("DID stop (foreground=\(foreground))")
    channel.invokeMethod("pipDidStop", arguments: ["foreground": foreground])
    if foreground {
      // Returning to the app: keep the layer warm (trickle) so the next PiP starts instantly.
      setTap(enabled: true, fullRate: false)
    } else {
      // Float dismissed while backgrounded: nothing to show, stop the tap entirely.
      setTap(enabled: false)
    }
  }

  // Required for a clean dismissal back to the app.
  func pictureInPictureController(
    _ c: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  func pictureInPictureController(
    _ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
  ) {
    log("FAILED to start: \(error.localizedDescription)")
    channel.invokeMethod("pipError", arguments: error.localizedDescription)
  }
}

@available(iOS 15.0, *)
final class SampleBufferDisplayView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

  override init(frame: CGRect) {
    super.init(frame: frame)
    displayLayer.videoGravity = .resizeAspect
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
