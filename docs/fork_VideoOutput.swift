// Patched copy of media_kit_video's
//   common/darwin/Classes/plugin/VideoOutput.swift
// (fork: github.com/My-Responsitories/media-kit @ version_1.2.5)
//
// Adds the iOS PiP frame tap + hwdec-current probe. Copy this over the pub-cache file:
//   F=$(ls ~/.pub-cache/git/media-kit-*/media_kit_video/common/darwin/Classes/plugin/VideoOutput.swift | head -1)
//   cp docs/fork_VideoOutput.swift "$F"
// Transfer via git (this file) instead of pasting, so newlines stay intact.

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

#if os(iOS)
import QuartzCore

final class MediaKitPiPTap {
  static let shared = MediaKitPiPTap()
  private var enabledTextureId: Int64 = -1
  // Full rate (every frame) only while the PiP window is actually on screen. Otherwise we
  // just keep the AVSampleBufferDisplayLayer "warm" at a trickle so iOS auto-PiP stays
  // possible the instant the app backgrounds — at a fraction of the per-frame cost.
  private var fullRate = false
  private var lastPost: CFTimeInterval = 0
  private let trickleInterval: CFTimeInterval = 0.5  // ~2 fps while warming
  private init() {
    NotificationCenter.default.addObserver(
      forName: Notification.Name("MediaKitPiPTapControl"), object: nil, queue: nil
    ) { [weak self] note in
      guard let self = self, let info = note.userInfo else { return }
      let enabled = (info["enabled"] as? Bool) ?? false
      let tid = (info["textureId"] as? NSNumber)?.int64Value ?? -1
      self.enabledTextureId = enabled ? tid : -1
      self.fullRate = (info["fullRate"] as? Bool) ?? false
    }
  }
  func isEnabled(_ id: Int64) -> Bool { id != -1 && id == enabledTextureId }
  // Gate the expensive copyPixelBuffer + post: every frame during PiP, ~2 fps while warming.
  func shouldPost(_ id: Int64) -> Bool {
    guard isEnabled(id) else { return false }
    if fullRate { return true }
    let now = CACurrentMediaTime()
    if now - lastPost >= trickleInterval {
      lastPost = now
      return true
    }
    return false
  }
}
#endif

public class VideoOutput: NSObject {
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false
  private var lastHwdecProbe: CFTimeInterval = 0

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    worker.cancel()
    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog("VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)")

    if VideoOutput.isSimulator {
      NSLog("VideoOutput: warning: hardware rendering is disabled in the iOS simulator")
    }

    if enableHardwareAcceleration {
      texture = SafeResizableTexture(
        TextureHW(
          handle: handle,
          updateCallback: { [weak self]() in
            guard let that = self else { return }
            that.updateCallback()
          }
        )
      )
    } else {
      texture = SafeResizableTexture(
        TextureSW(
          handle: handle,
          updateCallback: { [weak self]() in
            guard let that = self else { return }
            that.updateCallback()
          }
        )
      )
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else { return }
      that.registerTextureId()
    }
  }

  private func registerTextureId() {
    textureId = registry.register(texture)
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      registry_.unregisterTexture(textureId_)
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    if currentSize != size {
      currentSize = size
      texture.resize(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        that.textureUpdateCallback(that.textureId, size)
      }
    }

    if disposed {
      return
    }

    texture.render(size)

    #if os(iOS)
    if MediaKitPiPTap.shared.isEnabled(textureId) {
      // Probe hwdec-current every ~2s (not once) so a background VideoToolbox -> software
      // fallback shows up in the logs as the cause of any stutter.
      let nowProbe = CACurrentMediaTime()
      if nowProbe - lastHwdecProbe >= 2.0 {
        lastHwdecProbe = nowProbe
        var hwdec = "unknown"
        if let c = mpv_get_property_string(handle, "hwdec-current") {
          hwdec = String(cString: c)
          mpv_free(c)
        }
        NotificationCenter.default.post(
          name: Notification.Name("MediaKitPiPHwdec"), object: nil,
          userInfo: ["value": hwdec])
      }
      if MediaKitPiPTap.shared.shouldPost(textureId),
        let pb = texture.copyPixelBuffer()?.takeRetainedValue() {
        NotificationCenter.default.post(
          name: Notification.Name("MediaKitPiPFrame"), object: nil,
          userInfo: ["textureId": NSNumber(value: textureId), "pixelBuffer": pb])
      }
    } else {
      lastHwdecProbe = 0
    }
    #endif

    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

  private var videoSize: CGSize {
    if width != nil && height != nil {
      return CGSize(width: Double(width!), height: Double(height!))
    }
    let params = MPVHelpers.getVideoOutParams(handle)
    return CGSize(
      width: Double(width ?? (params.rotate == 0 || params.rotate == 180 ? params.dw : params.dh)),
      height: Double(height ?? (params.rotate == 0 || params.rotate == 180 ? params.dh : params.dw))
    )
  }
}
