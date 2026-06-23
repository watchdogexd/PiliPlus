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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register the PiP channel on the same registry as every other plugin. This binds it to
    // the engine's messenger directly, with no dependency on window.rootViewController timing.
    setupPiP(registry: engineBridge.pluginRegistry)
  }

  private func setupPiP(registry: FlutterPluginRegistry) {
    guard #available(iOS 15.0, *) else { return }
    guard let registrar = registry.registrar(forPlugin: "PiliPlusPiP") else {
      NSLog("[PiP] no registrar available")
      return
    }
    let channel = FlutterMethodChannel(
      name: AppDelegate.pipChannelName, binaryMessenger: registrar.messenger())
    let pip = SampleBufferPiPController(channel: channel)
    pipController = pip
    channel.setMethodCallHandler { [weak pip] call, result in
      guard let pip = pip else { result(nil); return }
      pip.handle(call, result: result)
    }
    NSLog("[PiP] channel registered via plugin registrar")
  }
}
