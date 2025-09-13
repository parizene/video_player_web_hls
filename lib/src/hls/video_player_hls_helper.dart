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

  /// Error code value to error name Map for HLS-specific errors.
  static const Map<int, String> _kHlsErrorValueToErrorName = <int, String>{
    2: 'MEDIA_ERR_NETWORK',
    5: 'HLS_MANIFEST_LOAD_ERROR',
  };

  /// Checks if the given source should use HLS.js library.
  bool shouldUseHlsLibrary(String src, Map<String, String>? headers) {
    return isSupported() &&
        (src.contains('m3u8') || _testIfM3u8Sync(src)) &&
        !_canPlayHlsNatively();
  }

  /// Checks if the browser can play HLS streams natively (like Safari).
  bool _canPlayHlsNatively() {
    try {
      final String canPlayType =
          _videoElement.canPlayType('application/vnd.apple.mpegurl');
      return canPlayType != '';
    } catch (e) {
      return false;
    }
  }

  /// Simple synchronous check for M3U8 content by looking at the URL.
  bool _testIfM3u8Sync(String src) {
    return src.contains('m3u8');
  }

  /// Asynchronously tests if the content is an M3U8 playlist by fetching headers.
  Future<bool> testIfM3u8Async() async {
    if (_uri == null) return false;
    try {
      final Map<String, String> headers = Map<String, String>.of(_headers ?? <String, String>{});
      if (headers.containsKey('Range') || headers.containsKey('range')) {
        final List<int> range = (headers['Range'] ?? headers['range'])!
            .split('bytes')[1]
            .split('-')
            .map((String e) => int.parse(e))
            .toList();
        range[1] = min(range[0] + 1023, range[1]);
        headers['Range'] = 'bytes=${range[0]}-${range[1]}';
      } else {
        headers['Range'] = 'bytes=0-1023';
      }
      final http.Response response =
          await http.get(Uri.parse(_uri!), headers: headers);
      final String body = response.body;
      return body.contains('#EXTM3U');
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
          xhrSetup: (web.XMLHttpRequest xhr, String _) {
            if (_headers?.isEmpty ?? true) {
              return;
            }

            if (_headers!.containsKey('useCookies')) {
              xhr.withCredentials = true;
            }
            _headers!.forEach((String key, String value) {
              if (key != 'useCookies') {
                xhr.setRequestHeader(key, value);
              }
            });
          }.toJS,
        ),
      );

      _hls!.attachMedia(_videoElement);

      // Setup HLS event listeners
      _hls!.on(
          'hlsMediaAttached',
          ((String _, JSObject __) {
            _hls!.loadSource(uri);
          }.toJS));

      _hls!.on(
          'hlsError',
          (String _, JSObject data) {
            try {
              final ErrorData errorData = ErrorData(data);
              if (errorData.fatal) {
                _eventController.addError(PlatformException(
                  code: _kHlsErrorValueToErrorName[2]!,
                  message: errorData.type,
                  details: errorData.details,
                ));
              }
            } catch (e) {
              debugPrint('Error parsing hlsError: $e');
            }
          }.toJS);

      // Listen for canPlay event when HLS is ready
      _hlsEventSubscriptions.add(_videoElement.onCanPlay.listen((dynamic _) {
        // HLS initialization complete, video can start playing
      }));

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

  /// Disposes of HLS resources.
  void dispose() {
    _hls?.stopLoad();
    _hls = null;
    for (final sub in _hlsEventSubscriptions) {
      sub.cancel();
    }
    _hlsEventSubscriptions.clear();
    _uri = null;
    _headers = null;
    _hlsFallback = null;
  }
}