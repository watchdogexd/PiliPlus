import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pipController: AnyObject?  // SampleBufferPiPController (iOS 15+)
  private static let pipChannelName = "com.piliplus/ios_pip"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo

    // Required for background audio + PiP. The app already declares UIBackgroundModes=audio.
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("AVAudioSession setup failed: \(error)")
    }

    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    setupPiPChannelIfNeeded()
    return didFinish
  }

  // With the implicit-engine AppDelegate, the FlutterViewController isn't the root yet at
  // didFinishLaunching. Retry once the app is active and the view hierarchy exists.
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    setupPiPChannelIfNeeded()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func setupPiPChannelIfNeeded() {
    guard #available(iOS 15.0, *) else { return }
    guard pipController == nil else { return }  // already set up

    guard let controller = findFlutterViewController() else {
      NSLog("[PiP] setup deferred: no FlutterViewController yet (root=\(String(describing: window?.rootViewController)))")
      return
    }

    let channel = FlutterMethodChannel(
      name: AppDelegate.pipChannelName, binaryMessenger: controller.binaryMessenger)
    let pip = SampleBufferPiPController(channel: channel, hostView: controller.view)
    pipController = pip
    channel.setMethodCallHandler { [weak pip] call, result in
      guard let pip = pip else { result(nil); return }
      pip.handle(call, result: result)
    }
    NSLog("[PiP] channel + controller set up")
  }

  // The root may be the FlutterViewController directly, or wrapped in a container.
  private func findFlutterViewController() -> FlutterViewController? {
    func search(_ vc: UIViewController?) -> FlutterViewController? {
      guard let vc = vc else { return nil }
      if let fvc = vc as? FlutterViewController { return fvc }
      if let presented = vc.presentedViewController, let f = search(presented) { return f }
      for child in vc.children {
        if let f = search(child) { return f }
      }
      return nil
    }
    if let fromWindow = search(window?.rootViewController) { return fromWindow }
    // Fallback: scan all connected scene windows.
    for scene in UIApplication.shared.connectedScenes {
      guard let ws = scene as? UIWindowScene else { continue }
      for w in ws.windows {
        if let f = search(w.rootViewController) { return f }
      }
    }
    return nil
  }
}
