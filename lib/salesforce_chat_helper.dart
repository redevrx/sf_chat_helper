import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

class SalesforceChatHelper {
  final WebViewController webViewController;
  final String supportUrl;
  final String uatApexEndpoint;
  final String prodApexEndpoint;
  final VoidCallback? onVisibilityChanged;
  final ValueChanged<String>? onPageStarted;
  final ValueChanged<String>? onPageFinished;
  final bool enableDebugLog;
  final bool customRequest;

  static bool _isAppSessionFirstLoad = true;

  bool _isWebViewVisible = true;
  bool _isInjecting = false;

  static const String _keySessionId = 'sf_session_id';
  static const String _keyToken = 'sf_token';
  static const MethodChannel _channel = MethodChannel(
    'com.sf.mintel.chat.helper/session',
  );

  SalesforceChatHelper._({
    required this.webViewController,
    required this.supportUrl,
    required this.uatApexEndpoint,
    required this.prodApexEndpoint,
    required this.enableDebugLog,
    required this.customRequest,
    this.onVisibilityChanged,
    this.onPageStarted,
    this.onPageFinished,
  }) {
    _isWebViewVisible = true;
  }

  static SalesforceChatHelperBuilder builder() {
    return SalesforceChatHelperBuilder();
  }

  bool get isWebViewVisible => _isWebViewVisible;

  String get _currentApexEndpoint {
    if (supportUrl.contains('--uat.sandbox')) {
      return uatApexEndpoint;
    }
    return prodApexEndpoint;
  }

  void _log(String message, [Object? error, StackTrace? stackTrace]) {
    if (enableDebugLog) {
      developer.log(
        message,
        name: 'SalesforceChatHelper',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _initialize() {
    webViewController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Echo',
        onMessageReceived: (msg) {
          _log('[Echo] ${msg.message}');
        },
      )
      ..addJavaScriptChannel(
        'SalesforceSessionChannel',
        onMessageReceived: (msg) async {
          _log('[SalesforceSessionChannel] Message received: ${msg.message}');
          try {
            final data = jsonDecode(msg.message);
            if (data is Map) {
              final event = data['event'];
              if (event == 'session_active') {
                final sessionId = data['sessionId'];
                final token = data['token'];
                if (sessionId != null && token != null) {
                  await _saveSessionInfo(sessionId, token);
                }
              } else if (event == 'session_ended') {
                await _clearSessionInfo();
              }
            }
          } catch (e, stackTrace) {
            _log(
              '[SalesforceSessionChannel] Error parsing session message',
              e,
              stackTrace,
            );
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) async {
            await _injectWsInterceptor();
            onPageStarted?.call(url);
          },
          onPageFinished: (url) async {
            if (!_isWebViewVisible) {
              _isWebViewVisible = true;
              onVisibilityChanged?.call();
            }
            await _injectEndChat();
            onPageFinished?.call(url);
          },
        ),
      );
  }

  Future<void> _saveSessionInfo(String sessionId, String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keySessionId, sessionId);
      await prefs.setString(_keyToken, token);
      _log('[Echo] Saved session info to SharedPreferences: ID=$sessionId');

      await _channel.invokeMethod('saveSession', {
        'sessionId': sessionId,
        'token': token,
        'endpoint': _currentApexEndpoint,
      });
      _log('[Echo] Propagated session to native side');
    } catch (e, stackTrace) {
      _log('[Echo] Error saving session info', e, stackTrace);
    }
  }

  Future<void> _clearSessionInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keySessionId);
      await prefs.remove(_keyToken);
      _log('[Echo] Cleared session info from SharedPreferences');

      await _channel.invokeMethod('clearSession');
      _log('[Echo] Cleared session from native side');
    } catch (e, stackTrace) {
      _log('[Echo] Error clearing session info', e, stackTrace);
    }
  }

  Future<void> _deleteSessionOnServer(
    String endpoint,
    String conversationId,
    String token,
  ) async {
    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse(endpoint));
      request.headers.contentType = ContentType.json;
      final requestBody = jsonEncode({
        'conversationId': conversationId,
        'token': token,
        'activity': 'delete',
      });
      _log('[Echo] Sending delete request to $endpoint: $requestBody');
      request.write(requestBody);
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      _log(
        '[Echo] Server session delete response status: ${response.statusCode}, body: $responseBody',
      );
    } catch (e, stackTrace) {
      _log('[Echo] Error calling session delete endpoint', e, stackTrace);
    }
  }

  Future<void> loadInitialRequest([String? url]) async {
    if (_isAppSessionFirstLoad) {
      _isAppSessionFirstLoad = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        final sessionId = prefs.getString(_keySessionId);
        final token = prefs.getString(_keyToken);

        if (sessionId != null && token != null) {
          _log(
            '[Echo] Found active session from previous launch: $sessionId. Initiating clean up...',
          );
          await _deleteSessionOnServer(_currentApexEndpoint, sessionId, token);

          final cookieManager = WebViewCookieManager();
          await cookieManager.clearCookies();
          await webViewController.clearCache();
          await webViewController.clearLocalStorage();

          await _clearSessionInfo();
        }
      } catch (e, stackTrace) {
        _log('[Echo] Error clearing app session', e, stackTrace);
      }
    }

    final targetUrl = url ?? supportUrl;
    await webViewController.loadRequest(Uri.parse(targetUrl));
  }

  Future<void> handleAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      await _injectEndChat();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (!Platform.isIOS) {
        await _nativePausedEndChat();
      }
    }
  }

  Future<void> _injectWsInterceptor() async {
    try {
      await webViewController.runJavaScript('''
        (function() {
          if (window.__sfWsInterceptorInstalled) return;
          window.__sfWsInterceptorInstalled = true;
          var origWS = window.WebSocket;
          window.__sfWs = [];
          window.WebSocket = function(url, protocols) {
            var ws = new origWS(url, protocols);
            if (typeof url === 'string' && url.indexOf('scrt') >= 0) {
              window.__sfWs.push(ws);
            }
            return ws;
          };
        })();
      ''');
    } catch (e, stackTrace) {
      _log('[Echo] WS interceptor error', e, stackTrace);
    }
  }

  Future<void> _injectEndChat() async {
    if (_isInjecting) return;
    _isInjecting = true;
    try {
      final endpoint = _currentApexEndpoint;
      final showLogs = enableDebugLog;
      await webViewController.runJavaScript('''
(function() {
  function log(msg) {
    if ($showLogs) {
      console.log('[SF-Cleanup] ' + msg);
      if (window.Echo) {
        window.Echo.postMessage('[SF-Cleanup] ' + msg);
      }
    }
  }

  try {
    localStorage.setItem('web_chat_active', 'true');
  } catch (e) {
    log('Error setting web_chat_active: ' + e);
  }

  if (window.__sfSessionMonitorInstalled) return;
  window.__sfSessionMonitorInstalled = true;

  var sessionIv = null;
  var iv = null;
  var waitForMessaging = null;
  var pollHiddenIv = null;
  var sfEnded = false;
  var t = null;
  var lastSessionId = null;
  var lastToken = null;

  function cleanAllTimers() {
    log('Cleaning all intervals and listeners...');
    if (sessionIv) { clearInterval(sessionIv); sessionIv = null; }
    if (iv) { clearInterval(iv); iv = null; }
    if (waitForMessaging) { clearInterval(waitForMessaging); waitForMessaging = null; }
    if (pollHiddenIv) { clearInterval(pollHiddenIv); pollHiddenIv = null; }
    if (t) { clearTimeout(t); t = null; }
    try {
      document.removeEventListener('visibilitychange', onVisibilityChange);
    } catch(_) {}
  }

  sessionIv = setInterval(function() {
    try {
      var sessionId = localStorage.getItem("session_id");
      var token = localStorage.getItem("token");
      if (sessionId && token) {
        if (sessionId !== lastSessionId || token !== lastToken) {
          lastSessionId = sessionId;
          lastToken = token;
          if (window.SalesforceSessionChannel) {
            window.SalesforceSessionChannel.postMessage(JSON.stringify({
              event: 'session_active',
              sessionId: sessionId,
              token: token
            }));
          }
        }
      } else {
        if (lastSessionId !== null || lastToken !== null) {
          lastSessionId = null;
          lastToken = null;
          if (window.SalesforceSessionChannel) {
            window.SalesforceSessionChannel.postMessage(JSON.stringify({
              event: 'session_ended'
            }));
          }
        }
      }
    } catch (err) {
      log('Error in session monitor: ' + err);
    }
  }, 1000);

  iv = setInterval(function() {
    var b = window.embeddedservice_bootstrap;
    if (!b || !b.utilAPI || !b.utilAPI.endChat) return;
    clearInterval(iv);
    iv = null;
    window.__sfHandlersRegistered = true;

    function end(reason) {
      if (sfEnded) return;
      sfEnded = true;
      log('Ending chat. Reason: ' + reason);

      cleanAllTimers();

      const conversationId = localStorage.getItem("session_id");
      const token = localStorage.getItem("token");
      const endpoint = "$endpoint";
      
      localStorage.removeItem("setSystem");
      localStorage.setItem('countsetSystem', '0');

      if (conversationId && token) {
        try {
          navigator.sendBeacon(endpoint,
            JSON.stringify({
              conversationId: conversationId,
              token: token,
              activity: 'delete'
            })
          );
        } catch (error) {
          log("Delete conversation failed: " + error);
        }
      }

      try {
        if (b.utilAPI && b.utilAPI.endChat) b.utilAPI.endChat();
        if (window.__sfWs) {
          for (var i = 0; i < window.__sfWs.length; i++) {
            if (window.__sfWs[i].readyState === 1) window.__sfWs[i].close(1000, reason || 'end');
          }
        }
        localStorage.removeItem('web_chat_active');
      } catch(_) {}
    }
    window.__sfForceEndChat = end;

    waitForMessaging = setInterval(function() {
      if (b.messaging && b.messaging.on) {
        clearInterval(waitForMessaging);
        waitForMessaging = null;
        b.messaging.on("messagingSessionEnded", function() {
          localStorage.removeItem('web_chat_active');
          if (window.SalesforceSessionChannel) {
            window.SalesforceSessionChannel.postMessage(JSON.stringify({
              event: 'session_ended'
            }));
          }
          if (b.util && b.util.closeChat) b.util.closeChat();
        });
      }
    }, 300);
    setTimeout(function() { if (waitForMessaging) { clearInterval(waitForMessaging); waitForMessaging = null; } }, 15000);

    document.addEventListener('visibilitychange', onVisibilityChange);

    pollHiddenIv = setInterval(function() { 
      if (document.hidden) {
        end('poll-hidden'); 
      }
    }, 2000);
  }, 500);
  setTimeout(function() { if (iv) { clearInterval(iv); iv = null; } }, 30000);

  function onVisibilityChange() {
    if (document.hidden) { 
      if (!t) t = setTimeout(function(){ t=null; end('hidden-timeout'); }, 5000); 
    }
    else { 
      if (t) { clearTimeout(t); t = null; } 
    }
  }
})();
''');
    } catch (e, stackTrace) {
      _log('[Echo] injectEndChat error', e, stackTrace);
    } finally {
      _isInjecting = false;
    }
  }

  Future<void> _nativePausedEndChat() async {
    try {
      await webViewController.runJavaScript('''
        (function() {
          if (window.__sfForceEndChat) window.__sfForceEndChat('app-paused');
        })();
      ''');
    } catch (_) {}
  }

  Future<void> manualEndChat() async {
    await _clearSessionInfo();
    try {
      final r = await webViewController.runJavaScriptReturningResult('''
        (function() {
          localStorage.removeItem('web_chat_active');
          var b = window.embeddedservice_bootstrap;
          if (window.__sfForceEndChat) {
            window.__sfForceEndChat('manual');
            return 'ok-via-handler';
          }
          if (b && b.utilAPI && b.utilAPI.endChat) {
            b.utilAPI.endChat();
            return 'ok-direct';
          }
          return 'no-op';
        })();
      ''');
      _log('manual endChat: $r');
    } catch (e, stackTrace) {
      _log('manual endChat error', e, stackTrace);
    }
  }

  Future<void> closeAndClear() async {
    try {
      _log('Closing WebSockets and clearing WebView context...');
      await webViewController.runJavaScript('''
        (function() {
          try {
            // Close all intercepted Salesforce WebSockets
            if (window.__sfWs) {
              for (var i = 0; i < window.__sfWs.length; i++) {
                var ws = window.__sfWs[i];
                if (ws && (ws.readyState === 0 || ws.readyState === 1)) {
                  ws.close(1000, 'close-screen');
                }
              }
              window.__sfWs = [];
            }
          } catch (e) {
            console.error('Error closing WebSockets:', e);
          }
        })();
      ''');
      // Load about:blank to kill all running timers/intervals
      await webViewController.loadRequest(Uri.parse('about:blank'));
    } catch (e, stackTrace) {
      _log('Error during closeAndClear', e, stackTrace);
    }
  }
}

class SalesforceChatHelperBuilder {
  WebViewController? _webViewController;
  String? _supportUrl;
  String uatApexEndpoint =
      'https://bitkubexchange--uat.sandbox.my.salesforce-sites.com/publicapi/services/apexrest/update-session';
  String prodApexEndpoint =
      'https://bitkubexchange.my.salesforce-sites.com/publicapi/services/apexrest/update-session';
  VoidCallback? onVisibilityChanged;
  ValueChanged<String>? onPageStarted;
  ValueChanged<String>? onPageFinished;
  bool enableDebugLog = true;
  bool customRequest = false;

  SalesforceChatHelperBuilder();

  SalesforceChatHelperBuilder setWebViewController(
    WebViewController controller,
  ) {
    _webViewController = controller;
    return this;
  }

  SalesforceChatHelperBuilder setSupportUrl(String url) {
    _supportUrl = url;
    return this;
  }

  SalesforceChatHelperBuilder setUatApexEndpoint(String endpoint) {
    uatApexEndpoint = endpoint;
    return this;
  }

  SalesforceChatHelperBuilder setProdApexEndpoint(String endpoint) {
    prodApexEndpoint = endpoint;
    return this;
  }

  SalesforceChatHelperBuilder setOnVisibilityChanged(VoidCallback callback) {
    onVisibilityChanged = callback;
    return this;
  }

  SalesforceChatHelperBuilder setOnPageStarted(ValueChanged<String> callback) {
    onPageStarted = callback;
    return this;
  }

  SalesforceChatHelperBuilder setOnPageFinished(ValueChanged<String> callback) {
    onPageFinished = callback;
    return this;
  }

  SalesforceChatHelperBuilder setLoggingEnabled(bool enabled) {
    enableDebugLog = enabled;
    return this;
  }

  SalesforceChatHelperBuilder setCustomRequest(bool enabled) {
    customRequest = enabled;
    return this;
  }

  SalesforceChatHelper build() {
    final controller = _webViewController;
    final url = _supportUrl;
    if (controller == null) {
      throw StateError('webViewController must be configured on the builder');
    }
    if (url == null) {
      throw StateError('supportUrl must be configured on the builder');
    }

    final helper = SalesforceChatHelper._(
      webViewController: controller,
      supportUrl: url,
      uatApexEndpoint: uatApexEndpoint,
      prodApexEndpoint: prodApexEndpoint,
      enableDebugLog: enableDebugLog,
      onVisibilityChanged: onVisibilityChanged,
      onPageStarted: onPageStarted,
      onPageFinished: onPageFinished,
      customRequest: customRequest,
    );
    helper._initialize();

    if (!customRequest) {
      helper.loadInitialRequest();
    }

    return helper;
  }
}
