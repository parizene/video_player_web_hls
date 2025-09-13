@JS()
library hls.js;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('Hls.isSupported')
external bool isSupported();

@JS()
@staticInterop
class Hls {
  external factory Hls(HlsConfig config);
}

extension HlsExtension on Hls {
  external void stopLoad();

  external void destroy();

  external void loadSource(String videoSrc);

  external void attachMedia(web.HTMLVideoElement video);

  external void on(String event, JSFunction callback);

  external HlsConfig config;

  // Quality control properties
  external JSArray get levels;
  external set currentLevel(int level);
  external int get currentLevel;
}

@JS()
@anonymous
@staticInterop
class HlsConfig {
  external factory HlsConfig({
    JSFunction? xhrSetup,
    int? maxBufferLength,
    int? maxMaxBufferLength,
    int? manifestLoadingTimeOut,
    int? manifestLoadingMaxRetry,
    int? fragLoadingTimeOut,
    int? fragLoadingMaxRetry,
  });
}

extension HlsConfigExtension on HlsConfig {
  external JSFunction? get xhrSetup;
  external int? get maxBufferLength;
  external int? get maxMaxBufferLength;
  external int? get manifestLoadingTimeOut;
  external int? get manifestLoadingMaxRetry;
  external int? get fragLoadingTimeOut;
  external int? get fragLoadingMaxRetry;
}

/// HLS.js event constants to avoid magic strings.
class HlsEvents {
  static const String manifestParsed = 'hlsManifestParsed';
  static const String error = 'hlsError';
  static const String levelSwitched = 'hlsLevelSwitched';
  static const String mediaAttached = 'hlsMediaAttached';
  static const String levelLoaded = 'hlsLevelLoaded';
  static const String fragLoadingProgress = 'hlsFragLoadingProgress';
}

/// Represents a video quality level from HLS.js.
class HlsQualityLevel {
  final int bitrate;
  final int height;
  final int width;
  final String name;
  final int levelIndex;

  HlsQualityLevel({
    required this.bitrate,
    required this.height,
    required this.width,
    required this.name,
    required this.levelIndex,
  });

  /// Creates a quality level from HLS.js level object.
  factory HlsQualityLevel.fromJsObject(dynamic level, int index) {
    final int height = (level.height as num?)?.toInt() ?? 0;
    final int width = (level.width as num?)?.toInt() ?? 0;
    final int bitrate = (level.bitrate as num?)?.toInt() ?? 0;

    String name = '${height}p'; // Default name
    if (level.name != null) {
      name = level.name as String;
    } else if (height > 0) {
      name = '${height}p';
    } else if (bitrate > 0) {
      name = '${(bitrate / 1000).round()}k';
    }

    return HlsQualityLevel(
      bitrate: bitrate,
      height: height,
      width: width,
      name: name,
      levelIndex: index,
    );
  }

  @override
  String toString() =>
      'HlsQualityLevel($name, ${width}x$height, ${bitrate}bps)';
}

class ErrorData {
  late final String type;
  late final String details;
  late final bool fatal;

  ErrorData(dynamic errorData) {
    type = errorData.type as String;
    details = errorData.details as String;
    fatal = errorData.fatal as bool;
  }
}
