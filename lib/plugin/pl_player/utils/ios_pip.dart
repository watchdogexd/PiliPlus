import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart bridge to the native iOS sample-buffer Picture-in-Picture controller
/// (see ios/Runner/SampleBufferPiPController.swift).
///
/// media_kit/mpv renders into a Flutter texture, so there is no AVPlayerLayer for
/// system PiP. The native side wraps the texture's CVPixelBuffer into an
/// AVSampleBufferDisplayLayer and drives PiP via AVPictureInPictureControllerContentSource
/// (iOS 15+). This class wires the transport callbacks (play/pause/seek) back to the player.
class IosPip {
  IosPip._();
  static final IosPip instance = IosPip._();

  static const MethodChannel _channel = MethodChannel('com.piliplus/ios_pip');

  bool _supported = false;
  bool get isSupported => _supported;
  bool _inited = false;

  /// Wired to PlPlayerController.
  void Function(bool playing)? onSetPlaying;
  void Function(double seconds)? onSkip;
  VoidCallback? onPipWillStart;

  /// [foreground] is true when PiP stopped because the app returned to the
  /// foreground (don't tear down decode), false when the user closed the float
  /// while still backgrounded (safe to drop the video track to save power).
  void Function(bool foreground)? onPipDidStop;
  void Function(String message)? onPipError;

  /// Device locked (or iOS reclaimed the hardware decoder) while PiP was active.
  /// The PiP float isn't shown on the lock screen, so there's no point running
  /// (software) video decode — drop the video track and keep audio only.
  VoidCallback? onScreenLocked;

  /// Device unlocked while PiP is still active: restore the video track so mpv
  /// re-initialises decode and re-acquires VideoToolbox hardware decoding.
  VoidCallback? onScreenUnlocked;

  Future<bool> ensureSupported() async {
    if (!Platform.isIOS) return false;
    if (!_inited) {
      _channel.setMethodCallHandler(_handle);
      try {
        _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
        debugPrint('[PiP] isSupported channel returned: $_supported');
      } catch (e) {
        debugPrint('[PiP] isSupported channel ERROR (native channel not set up?): $e');
        _supported = false;
      }
      _inited = true;
    }
    return _supported;
  }

  /// Attach PiP to a media_kit texture. Call after the VideoController has an id.
  Future<void> setup({required int textureId, required bool isLive}) {
    return _invoke('setup', {'textureId': textureId, 'isLive': isLive});
  }

  /// Explicitly enter PiP now (PiP button). Auto-enter on background is handled natively.
  Future<void> start() => _invoke('start');

  Future<void> stop() => _invoke('stop');

  Future<void> dispose() => _invoke('dispose');

  /// Keep the native transport bar accurate.
  Future<void> updateState({
    required bool isPlaying,
    required double position,
    required double duration,
  }) {
    return _invoke('updateState', {
      'isPlaying': isPlaying,
      'position': position,
      'duration': duration,
    });
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (!_supported) {
      debugPrint('[PiP] skip "$method": PiP not supported / channel down');
      return;
    }
    try {
      await _channel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('[PiP] invoke "$method" ERROR: $e');
    }
  }

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'log':
        debugPrint('[PiP-native] ${call.arguments}');
      case 'setPlaying':
        onSetPlaying?.call(call.arguments as bool);
      case 'skip':
        onSkip?.call((call.arguments as num).toDouble());
      case 'pipWillStart':
        onPipWillStart?.call();
      case 'pipDidStop':
        final fg = (call.arguments as Map?)?['foreground'] as bool? ?? false;
        onPipDidStop?.call(fg);
      case 'screenLocked':
        onScreenLocked?.call();
      case 'screenUnlocked':
        onScreenUnlocked?.call();
      case 'pipError':
        onPipError?.call(call.arguments as String? ?? '');
    }
    return null;
  }
}
