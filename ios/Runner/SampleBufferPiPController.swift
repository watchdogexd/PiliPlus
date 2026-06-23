import AVKit
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import UIKit

// iOS Picture-in-Picture for a libmpv/media_kit-backed player.
//
// media_kit renders mpv frames into a Flutter texture (a CVPixelBuffer), so there is
// no AVPlayerLayer for the system to pull into PiP. The only route for a custom
// (non-AVPlayer) engine is AVSampleBufferDisplayLayer + an
// AVPictureInPictureControllerContentSource (iOS 15+). This is the same approach a
// custom FFmpeg player (e.g. Bilibili's ijkplayer lineage) must use.
//
// Frames arrive from the patched VideoOutput in the media_kit fork via NotificationCenter
// (decoupled — Runner does not import the plugin). We wrap each CVPixelBuffer into a
// CMSampleBuffer and enqueue it into the display layer. Transport controls (play/pause/
// seek) are forwarded to Dart over a MethodChannel and applied to PlPlayerController.
//
// NOTE: untested on-device; treat as a first implementation to iterate on. Known tuning
// points are flagged with `// TUNE:`.
@available(iOS 15.0, *)
final class SampleBufferPiPController: NSObject {
  // Notification contract shared with the media_kit fork patch (see guide).
  static let frameNotification = Notification.Name("MediaKitPiPFrame")        // fork -> app (per frame)
  static let frameTextureIdKey = "textureId"
  static let framePixelBufferKey = "pixelBuffer"
  static let tapControlNotification = Notification.Name("MediaKitPiPTapControl") // app -> fork (enable/disable)
  static let tapEnabledKey = "enabled"
  static let tapTextureIdKey = "textureId"

  private let channel: FlutterMethodChannel
  private weak var hostView: UIView?

  private let sampleBufferView = SampleBufferDisplayView()
  private var pipController: AVPictureInPictureController?

  private var activeTextureId: Int64 = -1
  private var formatDescription: CMVideoFormatDescription?
  private var lastPixelBufferWidth: Int = 0
  private var lastPixelBufferHeight: Int = 0

  // State pushed from Dart so the PiP transport bar is accurate.
  private var isPlaying: Bool = false
  private var isLive: Bool = false
  private var positionSeconds: Double = 0
  private var durationSeconds: Double = 0

  init(channel: FlutterMethodChannel, hostView: UIView) {
    self.channel = channel
    self.hostView = hostView
    super.init()

    // Insert the sample-buffer layer behind the Flutter view. The Flutter video texture
    // is drawn on top during normal playback; this layer only becomes visible inside PiP.
    sampleBufferView.translatesAutoresizingMaskIntoConstraints = false
    sampleBufferView.isUserInteractionEnabled = false
    hostView.insertSubview(sampleBufferView, at: 0)
    NSLayoutConstraint.activate([
      sampleBufferView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
      sampleBufferView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
      sampleBufferView.topAnchor.constraint(equalTo: hostView.topAnchor),
      sampleBufferView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
    ])

    NotificationCenter.default.addObserver(
      self, selector: #selector(onFrame(_:)),
      name: Self.frameNotification, object: nil)

    // Feed frames only around backgrounding / PiP, never during normal foreground
    // playback. willResignActive fires before the app backgrounds, so auto-enter PiP
    // (canStartPictureInPictureAutomaticallyFromInline) has frames ready in time.
    NotificationCenter.default.addObserver(
      self, selector: #selector(onWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func onWillResignActive() {
    // Only if PiP has been set up for the current video.
    if pipController != nil { setTap(enabled: true) }
  }

  @objc private func onDidBecomeActive() {
    // Back in foreground and not in PiP -> stop feeding to save power.
    if pipController?.isPictureInPictureActive != true { setTap(enabled: false) }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Public API (called from AppDelegate's MethodChannel handler)

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
      if let c = pipController { c.invalidatePlaybackState() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  private func setup(textureId: Int64) {
    activeTextureId = textureId
    formatDescription = nil

    let content = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: sampleBufferView.displayLayer,
      playbackDelegate: self)
    let controller = AVPictureInPictureController(contentSource: content)
    // Let iOS auto-enter PiP when the app backgrounds while the video page is up.
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.delegate = self
    pipController = controller
    // Tap stays off during foreground playback; enabled on background / explicit start.
  }

  // Explicit "enter PiP now" (the PiP button). Auto-enter on background is handled by
  // canStartPictureInPictureAutomaticallyFromInline.
  private func start() {
    guard let controller = pipController else { return }
    setTap(enabled: true)
    // Give the layer a couple of frames before asking the system to start.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if controller.isPictureInPicturePossible {
        controller.startPictureInPicture()
      }
    }
  }

  private func stop() {
    pipController?.stopPictureInPicture()
  }

  private func dispose() {
    setTap(enabled: false)
    pipController?.stopPictureInPicture()
    pipController = nil
    activeTextureId = -1
    sampleBufferView.displayLayer.flushAndRemoveImage()
  }

  private func setTap(enabled: Bool) {
    NotificationCenter.default.post(
      name: Self.tapControlNotification, object: nil,
      userInfo: [Self.tapEnabledKey: enabled, Self.tapTextureIdKey: NSNumber(value: activeTextureId)])
  }

  // MARK: - Frame ingestion

  @objc private func onFrame(_ note: Notification) {
    guard let info = note.userInfo,
          let tid = (info[Self.frameTextureIdKey] as? NSNumber)?.int64Value,
          tid == activeTextureId,
          let pbObj = info[Self.framePixelBufferKey],
          CFGetTypeID(pbObj as CFTypeRef) == CVPixelBufferGetTypeID()
    else { return }
    let pixelBuffer = pbObj as! CVPixelBuffer
    enqueue(pixelBuffer)
  }

  private func enqueue(_ pixelBuffer: CVPixelBuffer) {
    let layer = sampleBufferView.displayLayer

    if layer.status == .failed {
      layer.flush()
    }

    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    if formatDescription == nil || w != lastPixelBufferWidth || h != lastPixelBufferHeight {
      formatDescription = nil
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription)
      lastPixelBufferWidth = w
      lastPixelBufferHeight = h
    }
    guard let fd = formatDescription else { return }

    // DisplayImmediately avoids depending on a precise timeline clock for the PiP preview.
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    let err = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    guard err == noErr, let sb = sampleBuffer else { return }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
      as? [NSMutableDictionary], let dict = attachments.first {
      dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
    }

    if layer.isReadyForMoreMediaData {
      layer.enqueue(sb)
    }
  }
}

// MARK: - Transport delegate (PiP play/pause/seek bar -> Dart -> PlPlayerController)

@available(iOS 15.0, *)
extension SampleBufferPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
  ) {
    channel.invokeMethod("setPlaying", arguments: playing)
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    if isLive {
      // A live stream: report a "now" range so the scrubber hides.
      return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    let start = CMTime(seconds: 0, preferredTimescale: 600)
    let dur = CMTime(seconds: max(durationSeconds, 0.001), preferredTimescale: 600)
    _ = positionSeconds // position is reflected via invalidatePlaybackState + isPlaybackPaused
    return CMTimeRange(start: start, duration: dur)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    return !isPlaying
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
  ) {
    channel.invokeMethod("skip", arguments: skipInterval.seconds)
    completionHandler()
  }
}

// MARK: - PiP window lifecycle (tell Dart so it can hide controls / keep playing)

@available(iOS 15.0, *)
extension SampleBufferPiPController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("pipWillStart", arguments: nil)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("pipDidStop", arguments: nil)
    // Stop feeding frames when not in PiP to save power. Re-enabled on next start/setup.
    setTap(enabled: false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    channel.invokeMethod("pipError", arguments: error.localizedDescription)
  }
}

// A UIView whose backing layer is an AVSampleBufferDisplayLayer.
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
