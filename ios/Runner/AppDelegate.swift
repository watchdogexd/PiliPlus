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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func setupPiPChannelIfNeeded() {
    guard #available(iOS 15.0, *),
          let controller = window?.rootViewController as? FlutterViewController
    else { return }

    let channel = FlutterMethodChannel(
      name: AppDelegate.pipChannelName, binaryMessenger: controller.binaryMessenger)
    let pip = SampleBufferPiPController(channel: channel, hostView: controller.view)
    pipController = pip
    channel.setMethodCallHandler { [weak pip] call, result in
      guard let pip = pip else { result(nil); return }
      pip.handle(call, result: result)
    }
  }
}
