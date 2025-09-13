// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:web/web.dart' as web;
import 'package:http/http.dart' as http;

import 'hls.dart';
import 'no_script_tag_exception.dart';

/// Helper class that provides HLS streaming support for VideoPlayer.
///
/// This class handles HLS.js integration, fallback logic, and custom headers
/// for authenticated HLS streams. It uses composition to extend the base
/// VideoPlayer functionality without modifying the original implementation.
class VideoPlayerHlsHelper {
  VideoPlayerHlsHelper({
    required web.HTMLVideoElement videoElement,
    required StreamController<VideoEvent> eventController,
  }) : _videoElement = videoElement,
       _eventController = eventController;

  final web.HTMLVideoElement _videoElement;
  final StreamController<VideoEvent> _eventController;

  Hls? _hls;
  String? _uri;
  Map<String, String>? _headers;
  bool? _hlsFallback;
  final List<StreamSubscription> _hlsEventSubscriptions = [];
  final List<HlsQualityLevel> _qualityLevels = [];

  /// Maps HLS.js error types to appropriate platform error codes.
  static const Map<String, String> _kHlsErrorTypeToCode = <String, String>{
    'networkError': 'MEDIA_ERR_NETWORK',
    'mediaError': 'MEDIA_ERR_DECODE',
    'muxError': 'MEDIA_ERR_DECODE',
    'keySystemError': 'MEDIA_ERR_ENCRYPTED',
    'otherError': 'HLS_OTHER_ERROR',
  };

  /// Checks if the given source should use HLS.js library.
  bool shouldUseHlsLibrary(String src, Map<String, String>? headers) {
    return isSupported() &&
        (src.contains('m3u8') || _testIfM3u8Sync(src)) &&
        !_canPlayHlsNatively();
  }

  /// Checks if the browser can play HLS streams natively (like Safari).
  bool _canPlayHlsNatively() {
    const List<String> hlsMimeTypes = [
      'application/vnd.apple.mpegurl',
      'application/x-mpegURL',
      'audio/mpegurl',
      'audio/x-mpegurl',
    ];

    try {
      return hlsMimeTypes.any(
        (type) => _videoElement.canPlayType(type).isNotEmpty,
      );
    } catch (e) {
      return false;
    }
  }

  /// Simple synchronous check for M3U8 content by looking at the URL.
  bool _testIfM3u8Sync(String src) {
    return src.contains('m3u8');
  }

  /// Checks if a URL is same-origin to prevent credential leakage.
  bool _isSameOrigin(String url) {
    try {
      final Uri uri = Uri.parse(url);
      final String currentOrigin = web.window.location.origin;
      final String urlOrigin =
          '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      return currentOrigin == urlOrigin;
    } catch (e) {
      return false; // Assume different origin if parsing fails
    }
  }

  /// Validates if a header is safe to set (prevents header injection attacks).
  bool _isHeaderSafe(String key, String value) {
    // Whitelist of safe headers for HLS authentication
    const List<String> safeHeaders = [
      'authorization',
      'x-auth-token',
      'x-api-key',
      'referer',
      'user-agent',
      'range',
    ];

    final String lowerKey = key.toLowerCase();

    // Check if header is in whitelist
    if (!safeHeaders.contains(lowerKey)) {
      return false;
    }

    // Basic validation to prevent injection
    if (value.contains('\n') || value.contains('\r')) {
      return false;
    }

    return true;
  }

  /// Efficiently detects HLS content using HEAD request to check content-type.
  Future<bool> detectHlsContentAsync(
    String uri,
    Map<String, String>? headers,
  ) async {
    try {
      // First, try efficient HEAD request to check content-type
      final http.Response headResponse = await http.head(
        Uri.parse(uri),
        headers: headers,
      );

      final String contentType = headResponse.headers['content-type'] ?? '';
      const List<String> hlsContentTypes = [
        'application/vnd.apple.mpegurl',
        'application/x-mpegURL',
        'audio/mpegurl',
        'audio/x-mpegurl',
      ];

      // Check content-type first (most efficient)
      if (hlsContentTypes.any((type) => contentType.contains(type))) {
        return true;
      }

      // Fallback to URL pattern if content-type is not helpful
      if (uri.contains('.m3u8')) {
        return true;
      }

      // Last resort: partial content check (only if needed)
      return await _testM3u8ByContent(uri, headers);
    } catch (e) {
      // If HEAD fails, fallback to URL pattern matching
      return uri.contains('.m3u8');
    }
  }

  /// Legacy method - kept for compatibility but improved with safer parsing.
  Future<bool> testIfM3u8Async() async {
    if (_uri == null) return false;
    return await _testM3u8ByContent(_uri!, _headers);
  }

  /// Safely tests M3U8 content by fetching a small portion.
  Future<bool> _testM3u8ByContent(
    String uri,
    Map<String, String>? headers,
  ) async {
    try {
      final Map<String, String> safeHeaders = Map<String, String>.of(
        headers ?? <String, String>{},
      );

      // Safely parse existing Range header or add a small range
      if (safeHeaders.containsKey('Range') ||
          safeHeaders.containsKey('range')) {
        final String? existingRange =
            safeHeaders['Range'] ?? safeHeaders['range'];
        if (existingRange != null && existingRange.contains('bytes=')) {
          // Parse existing range more safely
          final List<String> rangeParts = existingRange.split('bytes=');
          if (rangeParts.length > 1) {
            final List<String> range = rangeParts[1].split('-');
            if (range.length >= 2) {
              final int? start = int.tryParse(range[0]);
              final int? end = int.tryParse(range[1]);
              if (start != null && end != null) {
                final int newEnd = min(start + 1023, end);
                safeHeaders['Range'] = 'bytes=$start-$newEnd';
              }
            }
          }
        }
      } else {
        safeHeaders['Range'] = 'bytes=0-1023';
      }

      final http.Response response = await http.get(
        Uri.parse(uri),
        headers: safeHeaders,
      );
      return response.body.contains('#EXTM3U');
    } catch (e) {
      return false;
    }
  }

  /// Initializes HLS.js for the given video element with the specified URI and headers.
  Future<void> initializeHls({
    required String uri,
    Map<String, String>? headers,
  }) async {
    _uri = uri;
    _headers = headers ?? <String, String>{};

    try {
      _hls = Hls(
        HlsConfig(
          // Buffer management for smoother playback
          maxBufferLength: 30, // 30 seconds of buffering
          maxMaxBufferLength: 600, // Maximum 10 minutes buffer
          // Manifest loading configuration
          manifestLoadingTimeOut: 10000, // 10 seconds timeout
          manifestLoadingMaxRetry: 1, // Single retry for manifests
          // Fragment loading configuration
          fragLoadingTimeOut: 20000, // 20 seconds timeout for fragments
          fragLoadingMaxRetry: 3, // Up to 3 retries for fragments
          // Custom XHR setup for authentication
          xhrSetup:
              (web.XMLHttpRequest xhr, String url) {
                if (_headers?.isEmpty ?? true) {
                  return;
                }

                // Set credentials only for same-origin requests (security)
                if (_headers!.containsKey('useCookies') && _isSameOrigin(url)) {
                  xhr.withCredentials = true;
                }

                // Set safe headers only
                _headers!.forEach((String key, String value) {
                  if (key != 'useCookies' && _isHeaderSafe(key, value)) {
                    xhr.setRequestHeader(key, value);
                  }
                });
              }.toJS,
        ),
      );

      _hls!.attachMedia(_videoElement);

      // Setup HLS event listeners
      _hls!.on(
        HlsEvents.mediaAttached,
        ((String _, JSObject __) {
          _hls!.loadSource(uri);
        }.toJS),
      );

      // Listen for manifest parsed to populate quality levels
      _hls!.on(
        HlsEvents.manifestParsed,
        (String _, JSObject data) {
          try {
            if (_hls?.levels != null) {
              // Clear previous levels
              _qualityLevels.clear();

              final levels = _hls!.levels.toDart;
              for (int i = 0; i < levels.length; i++) {
                _qualityLevels.add(HlsQualityLevel.fromJsObject(levels[i], i));
              }

              debugPrint(
                'HLS: ${_qualityLevels.length} quality levels available',
              );
              for (final level in _qualityLevels) {
                debugPrint('  - $level');
              }
            }
          } catch (e) {
            debugPrint('Error parsing HLS manifest levels: $e');
          }
        }.toJS,
      );

      // Listen for quality level switches
      _hls!.on(
        HlsEvents.levelSwitched,
        (String _, JSObject data) {
          try {
            final currentLevel = _hls?.currentLevel ?? -1;
            debugPrint('HLS: Switched to quality level $currentLevel');
          } catch (e) {
            debugPrint('Error parsing level switch: $e');
          }
        }.toJS,
      );

      _hls!.on(
        HlsEvents.error,
        (String _, JSObject data) {
          try {
            final ErrorData errorData = ErrorData(data);
            if (errorData.fatal) {
              // Map HLS error types to appropriate error codes
              final String errorCode =
                  _kHlsErrorTypeToCode[errorData.type] ?? 'HLS_OTHER_ERROR';
              _eventController.addError(
                PlatformException(
                  code: errorCode,
                  message: 'HLS Error: ${errorData.type}',
                  details: errorData.details,
                ),
              );
            }
          } catch (e) {
            debugPrint('Error parsing hlsError: $e');
          }
        }.toJS,
      );

      // Listen for canPlay event when HLS is ready
      _hlsEventSubscriptions.add(
        _videoElement.onCanPlay.listen((dynamic _) {
          // HLS initialization complete, video can start playing
        }),
      );
    } catch (e) {
      throw NoScriptTagException();
    }
  }

  /// Handles fallback from native playback to HLS.js when native playback fails.
  Future<bool> handleNativePlaybackError({
    required int errorCode,
    required String? uri,
    Map<String, String>? headers,
  }) async {
    // If native playback fails with MEDIA_ERR_SRC_NOT_SUPPORTED and we haven't tried HLS yet
    if (_hls == null && _hlsFallback == null && errorCode == 4 && uri != null) {
      _hlsFallback = true;

      // Check if this could be an HLS stream that requires fallback
      if (shouldUseHlsLibrary(uri, headers)) {
        await initializeHls(uri: uri, headers: headers);
        return true; // Handled the error with HLS fallback
      }
    }
    return false; // Error not handled by HLS
  }

  /// Sets whether to force use of HLS.js library (for testing/debugging).
  void setHlsFallback(bool value) {
    _hlsFallback = value;
  }

  /// Returns whether HLS fallback is currently enabled.
  bool get isHlsFallbackEnabled => _hlsFallback == true;

  /// Returns whether HLS.js is currently active.
  bool get isHlsActive => _hls != null;

  /// Returns a list of available video quality levels.
  /// This is typically available after the 'hlsManifestParsed' event.
  List<HlsQualityLevel> getAvailableQualities() =>
      List.unmodifiable(_qualityLevels);

  /// Sets the desired video quality level by its index.
  /// Set to -1 to enable automatic quality switching.
  void setQualityLevel(int levelIndex) {
    if (_hls != null) {
      _hls!.currentLevel = levelIndex;
    }
  }

  /// Gets the current quality level index.
  /// Returns -1 if auto mode is enabled or HLS is not active.
  int getCurrentQualityLevel() {
    return _hls?.currentLevel ?? -1;
  }

  /// Enables automatic quality selection based on network speed.
  void enableAutoQuality() {
    setQualityLevel(-1); // -1 is the standard value for auto mode
  }

  /// Returns whether auto quality is currently enabled.
  bool get isAutoQualityEnabled => getCurrentQualityLevel() == -1;

  /// Disposes of HLS resources properly.
  void dispose() {
    _hls?.destroy(); // Use destroy() for complete cleanup
    _hls = null;
    for (final sub in _hlsEventSubscriptions) {
      sub.cancel();
    }
    _hlsEventSubscriptions.clear();
    _qualityLevels.clear();
    _uri = null;
    _headers = null;
    _hlsFallback = null;
  }
}
