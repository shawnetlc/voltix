import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:playback_core/playback_core.dart';

import '../../../auth/repositories/user_repository.dart';
import '../../../auth/repositories/session_repository.dart';
import '../../../auth/models/user.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../../../data/services/voltix_api_service.dart';
import '../../../data/models/aggregated_item.dart';
import '../../navigation/destinations.dart';
import '../../../util/platform_detection.dart';

/// Xtream Codes IPTV screen — loads the Voltix web IPTV player in a WebView.
/// The web player handles auth, categories, channel browsing, and HLS playback.
///
/// D-pad key events are intercepted by a [Focus] widget and forwarded as
/// synthetic JS KeyboardEvents into the WebView so that the spatial navigation
/// library (@noriginmedia/norigin-spatial-navigation) can handle them.
class XtreamIptvScreen extends StatefulWidget {
  const XtreamIptvScreen({super.key});

  @override
  State<XtreamIptvScreen> createState() => _XtreamIptvScreenState();
}

class _XtreamIptvScreenState extends State<XtreamIptvScreen>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  late final FocusNode _focusNode;
  bool _isLoading = true;
  bool _hasError = false;

  Timer? _repeatTimer;
  LogicalKeyboardKey? _repeatingKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
    _initWebView();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clear WebView disk cache on exit to prevent unbounded growth
    // from poster images and web assets.
    // Note: Do NOT call clearLocalStorage() here — it would wipe the user's
    // session token and saved preferences stored in localStorage.
    try {
      _controller.clearCache();
      debugPrint('[IPTV WebView] Cleared disk cache on dispose');
    } catch (e) {
      debugPrint('[IPTV WebView] Error clearing cache on dispose: $e');
    }
    _focusNode.removeListener(_onFocusChange);
    _stopRepeatTimer();
    _focusNode.dispose();
    super.dispose();
  }

  // ─── Memory pressure handler ──────────────────────────────────────────────
  // Flutter equivalent of Android's onTrimMemory(TRIM_MEMORY_MODERATE).
  // Clears WebView cache and Flutter image cache when the OS signals low memory.
  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    debugPrint('[IPTV WebView] Memory pressure detected — clearing caches');
    try {
      _controller.clearCache();
    } catch (e) {
      debugPrint('[IPTV WebView] Error clearing WebView cache: $e');
    }
    // Also evict the Flutter image cache to free decoded bitmap memory
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      _stopRepeatTimer();
    }
  }

  void _startRepeatTimer(String jsKey, int keyCode) {
    _repeatTimer?.cancel();
    // Initial delay: 350ms, then repeat every 80ms
    _repeatTimer = Timer(const Duration(milliseconds: 350), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 80), (timer) {
        _controller.runJavaScript('window.__dispatchFlutterKey("$jsKey", $keyCode, "keydown");');
      });
    });
  }

  void _stopRepeatTimer() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _repeatingKey = null;
  }

  void _showSearchDialog(String initialQuery) {
    _focusNode.unfocus();
    final textController = TextEditingController(text: initialQuery);
    final textFieldFocusNode = FocusNode(debugLabel: 'SearchTextField');
    final cancelBtnFocusNode = FocusNode(debugLabel: 'SearchCancel');
    final searchBtnFocusNode = FocusNode(debugLabel: 'SearchSubmit');

    // D-pad navigation for the text field: ArrowDown → Search button
    textFieldFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        searchBtnFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // D-pad for Cancel button: ArrowUp → TextField, ArrowRight → Search
    cancelBtnFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        textFieldFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        searchBtnFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // D-pad for Search button: ArrowUp → TextField, ArrowLeft → Cancel
    searchBtnFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        textFieldFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        cancelBtnFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        Future.delayed(const Duration(milliseconds: 250), () {
          if (textFieldFocusNode.canRequestFocus) {
            textFieldFocusNode.requestFocus();
            if (PlatformDetection.isTV) {
              // On TV, also try to show the system keyboard
              SystemChannels.textInput.invokeMethod('TextInput.show');
            }
          }
        });

        return Focus(
          onKeyEvent: (node, event) {
            // Intercept back key to dismiss the dialog
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.goBack ||
                 event.logicalKey == LogicalKeyboardKey.escape)) {
              Navigator.of(dialogContext).pop();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: AlertDialog(
            backgroundColor: const Color(0xFF0F141C),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF1E90FF), width: 2),
            ),
            title: const Text(
              'Search IPTV',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            content: SizedBox(
              width: 400,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: TextField(
                  controller: textController,
                  focusNode: textFieldFocusNode,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Enter search term...',
                    hintStyle: const TextStyle(color: Colors.grey),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                    ),
                    focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1E90FF)),
                    ),
                  ),
                  onSubmitted: (value) {
                    final escaped = value.replaceAll('"', '\\"').replaceAll('\n', ' ');
                    _controller.runJavaScript(
                      'if (window.onSearchFromFlutter) { window.onSearchFromFlutter("$escaped"); }'
                    );
                    Navigator.of(dialogContext).pop();
                  },
                ),
              ),
            ),
            actions: [
              TextButton(
                focusNode: cancelBtnFocusNode,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey,
                ).copyWith(
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.focused)) {
                      return Colors.white;
                    }
                    return Colors.grey;
                  }),
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.focused)) {
                      return Colors.white.withValues(alpha: 0.1);
                    }
                    return null;
                  }),
                  side: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.focused)) {
                      return const BorderSide(color: Color(0xFF1E90FF), width: 2);
                    }
                    return null;
                  }),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontSize: 16),
                ),
              ),
              ElevatedButton(
                focusNode: searchBtnFocusNode,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E90FF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ).copyWith(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.focused)) {
                      return Colors.white;
                    }
                    return const Color(0xFF1E90FF);
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.focused)) {
                      return Colors.black;
                    }
                    return Colors.white;
                  }),
                  side: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.focused)) {
                      return const BorderSide(color: Color(0xFF1E90FF), width: 2);
                    }
                    return null;
                  }),
                ),
                onPressed: () {
                  final escaped = textController.text.replaceAll('"', '\\"').replaceAll('\n', ' ');
                  _controller.runJavaScript(
                    'if (window.onSearchFromFlutter) { window.onSearchFromFlutter("$escaped"); }'
                  );
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Search', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
    ).then((_) {
      textController.dispose();
      textFieldFocusNode.dispose();
      cancelBtnFocusNode.dispose();
      searchBtnFocusNode.dispose();
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  void _playNativeStream(String dataStr) {
    try {
      final data = jsonDecode(dataStr) as Map<String, dynamic>;
      final url = data['url'] as String;
      final title = data['title'] as String? ?? 'Voltix IPTV';
      final isLive = data['isLive'] as bool? ?? false;

      final manager = GetIt.instance<PlaybackManager>();
      final itemId = 'iptv_${DateTime.now().millisecondsSinceEpoch}';
      final rawData = {
        'Id': itemId,
        'url': url,
        'Name': title,
        'isLive': isLive,
        'Type': 'Video',
      };
      final item = AggregatedItem(
        id: itemId,
        serverId: 'iptv',
        rawData: rawData,
      );

      unawaited(() async {
        if (!mounted) return;

        // Push the player screen immediately so the Video surface/widget is mounted
        final routeFuture = context.push(Destinations.videoPlayer);

        try {
          await manager.playItems([item]);
          await routeFuture;
        } catch (e) {
          debugPrint('[IPTV Flutter Channel] Playback failed: $e');
          if (mounted) {
            final route = ModalRoute.of(context);
            if (route != null && !route.isCurrent) {
              Navigator.of(context).pop();
            }
          }
        }
      }());
    } catch (e) {
      debugPrint('[IPTV Flutter Channel] Error parsing play_native message: $e');
    }
  }

  void _handleSessionExpired({String? reason}) async {
    try {
      final voltixStore = GetIt.instance<VoltixSessionStore>();
      await voltixStore.clear();

      final sessionRepo = GetIt.instance<SessionRepository>();
      await sessionRepo.destroyCurrentSession();
    } catch (e) {
      debugPrint('[IPTV WebView] Error clearing session: $e');
    }

    if (mounted) {
      String msg = 'Session expired. Please log in again.';
      if (reason == 'subscription_inactive') {
        msg = 'Access Suspended: Subscription expired. Please renew your plan.';
      } else if (reason == 'suspended') {
        msg = 'Access Suspended: Account suspended.';
      } else if (reason == 'invalid_session') {
        msg = 'Access Suspended: Session invalidated.';
      } else if (reason != null && reason.isNotEmpty) {
        msg = 'Access Suspended: $reason';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
      context.go(Destinations.voltixLogin);
    }
  }

  void _initWebView() {
    // Use the Voltix API base URL for the IPTV player
    final voltixApi = GetIt.instance<VoltixApiService>();
    final voltixStore = GetIt.instance<VoltixSessionStore>();
    String iptvUrl = '${voltixApi.baseUrl}/iptv';

    // Use the Voltix session token for proxy authentication
    final token = voltixStore.sessionToken;
    if (token != null && token.isNotEmpty) {
      final uri = Uri.parse(iptvUrl);
      final newQueryParams = Map<String, dynamic>.from(uri.queryParameters);
      newQueryParams['token'] = token;
      iptvUrl = uri.replace(queryParameters: newQueryParams).toString();
    } else {
      // Fallback to Jellyfin access token if no Voltix session
      final userRepo = GetIt.instance<UserRepository>();
      final currentUser = userRepo.currentUser;
      if (currentUser is PrivateUser) {
        final jfToken = currentUser.accessToken;
        if (jfToken.isNotEmpty) {
          final uri = Uri.parse(iptvUrl);
          final newQueryParams = Map<String, dynamic>.from(uri.queryParameters);
          newQueryParams['token'] = jfToken;
          iptvUrl = uri.replace(queryParameters: newQueryParams).toString();
        }
      }
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF07090E))
      ..addJavaScriptChannel(
        'FlutterIPTVChannel',
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint('[IPTV Flutter Channel] Received message: ${message.message}');
          if (message.message.startsWith('open_search:')) {
            final query = message.message.substring('open_search:'.length);
            _showSearchDialog(query);
          } else if (message.message == 'focus_input') {
            _focusNode.unfocus();
          } else if (message.message == 'blur_input') {
            _focusNode.requestFocus();
          } else if (message.message.startsWith('play_native:')) {
            final dataStr = message.message.substring('play_native:'.length);
            _playNativeStream(dataStr);
          } else if (message.message == 'auth_error' ||
              message.message.startsWith('auth_error:') ||
              message.message == 'request_native_login' ||
              message.message.startsWith('force_logout:')) {
            String? reason;
            if (message.message.startsWith('force_logout:')) {
              reason = message.message.substring('force_logout:'.length);
            } else if (message.message.startsWith('auth_error:')) {
              reason = message.message.substring('auth_error:'.length);
            }
            _handleSessionExpired(reason: reason);
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final url = request.url.toLowerCase();
            if (url.contains('/login') || url.contains('/auth') || url.contains('/select-server') || url.contains('/logged-out')) {
              _handleSessionExpired();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
            // Inject viewport settings and zoom/overscan adjustments to prevent screen clipping on TV
            final isTV = PlatformDetection.isTV;
            final js = '''
              (function() {
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                  meta = document.createElement('meta');
                  meta.name = 'viewport';
                  document.getElementsByTagName('head')[0].appendChild(meta);
                }
                meta.setAttribute('content', 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no');
                
                if ($isTV) {
                  document.body.style.zoom = '95%';
                  document.body.style.padding = '0 16px';
                  document.body.style.boxSizing = 'border-box';
                }
              })();
            ''';
            _controller.runJavaScript(js);
            // Inject auto-fullscreen script for video playback
            _controller.runJavaScript(_autoFullscreenScript);
            // Inject optimized D-pad key dispatcher
            _controller.runJavaScript(_performanceScript);
            // Inject localStorage cache cleanup — evict expired series cache
            // entries and cap at 50 most-recent (LRU eviction)
            _controller.runJavaScript(_cacheCleanupScript);
          },
          onWebResourceError: (error) {
            // Only show the error screen for main frame failures.
            // Sub-resource errors (CSS, JS, images, fonts) are common
            // and should not block the entire IPTV experience.
            if (error.isForMainFrame ?? false) {
              debugPrint('[IPTV WebView] Main frame error: '
                  '${error.errorCode} ${error.description}');
              if (mounted) {
                setState(() {
                  _isLoading = false;
                  _hasError = true;
                });
              }
            } else {
              debugPrint('[IPTV WebView] Sub-resource error: '
                  '${error.errorCode} ${error.description} '
                  '(url: ${error.url})');
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(iptvUrl));

    if (_controller.platform is AndroidWebViewController) {
      final androidController = _controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
      androidController.setMixedContentMode(MixedContentMode.alwaysAllow);
    }
    debugPrint('[IPTV WebView] Loading URL: $iptvUrl');
  }

  // ─── Auto-fullscreen script ─────────────────────────────────────────────────
  // Injected into the WebView to auto-fullscreen the video player container
  // when a stream starts playing. Uses MutationObserver to detect video elements.
  static const String _autoFullscreenScript = '''
    (function() {
      if (window.__voltixAutoFS) return;
      window.__voltixAutoFS = true;

      function tryFullscreen(video) {
        // Find the VideoPlayerModal container (fixed inset-0 z-[100])
        var container = video.closest('.fixed');
        if (!container) container = video.parentElement;
        while (container && container !== document.body) {
          if (container.classList.contains('fixed') ||
              getComputedStyle(container).position === 'fixed') {
            break;
          }
          container = container.parentElement;
        }
        var target = container || document.documentElement;
        if (!document.fullscreenElement) {
          target.requestFullscreen().catch(function() {
            // Fullscreen may be blocked without user gesture, ignore
          });
        }
      }

      // Watch for video elements being added and starting playback
      var observer = new MutationObserver(function(mutations) {
        mutations.forEach(function(m) {
          m.addedNodes.forEach(function(node) {
            if (node.nodeType !== 1) return;
            var videos = node.tagName === 'VIDEO' ? [node] :
                         node.querySelectorAll ? node.querySelectorAll('video') : [];
            for (var i = 0; i < videos.length; i++) {
              videos[i].addEventListener('play', function() {
                tryFullscreen(this);
              }, { once: true });
            }
          });
        });
      });
      observer.observe(document.body, { childList: true, subtree: true });

      // Also handle existing videos
      document.querySelectorAll('video').forEach(function(v) {
        v.addEventListener('play', function() {
          tryFullscreen(this);
        }, { once: true });
      });
    })();
  ''';

  // ─── Optimized key dispatcher script ─────────────────────────────────────────
  static const String _performanceScript = '''
    (function() {
      if (window.__dispatchFlutterKey) return;
      window.__dispatchFlutterKey = function(key, keyCode, type) {
        var event = new KeyboardEvent(type, {
          key: key,
          code: key,
          keyCode: keyCode,
          which: keyCode,
          bubbles: true,
          cancelable: true
        });
        window.dispatchEvent(event);
        if (type === 'keydown' && key === 'Enter') {
          var el = document.querySelector(':focus');
          if (el) el.click();
          setTimeout(function() {
            var upEvent = new KeyboardEvent('keyup', {
              key: 'Enter',
              code: 'Enter',
              keyCode: 13,
              bubbles: true,
              cancelable: true
            });
            window.dispatchEvent(upEvent);
          }, 50);
        }
      };
    })();
  ''';

  // ─── localStorage cache cleanup script ───────────────────────────────────────
  // Evicts expired series cache entries (>24h) and caps at 50 most-recent (LRU).
  // Prevents localStorage from growing unbounded with series info JSON data.
  static const String _cacheCleanupScript = '''
    (function() {
      if (window.__voltix_cache_cleaned) return;
      window.__voltix_cache_cleaned = true;
      try {
        var prefix = 'voltix_series_info_v3_';
        var maxEntries = 50;
        var maxAgeMs = 24 * 60 * 60 * 1000;
        var now = Date.now();
        var entries = [];
        var removed = 0;
        for (var i = localStorage.length - 1; i >= 0; i--) {
          var key = localStorage.key(i);
          if (key && key.indexOf(prefix) === 0) {
            try {
              var val = JSON.parse(localStorage.getItem(key));
              if (!val || !val.timestamp || (now - val.timestamp > maxAgeMs)) {
                localStorage.removeItem(key);
                removed++;
              } else {
                entries.push({ key: key, ts: val.timestamp });
              }
            } catch(e) {
              localStorage.removeItem(key);
              removed++;
            }
          }
        }
        if (entries.length > maxEntries) {
          entries.sort(function(a, b) { return b.ts - a.ts; });
          for (var j = maxEntries; j < entries.length; j++) {
            localStorage.removeItem(entries[j].key);
            removed++;
          }
        }
        if (removed > 0) {
          console.log('[Voltix] Cleaned ' + removed + ' expired/excess cache entries');
        }
      } catch(e) {
        console.warn('[Voltix] Cache cleanup failed:', e);
      }
    })();
  ''';

  // ─── D-pad → WebView JS forwarding ─────────────────────────────────────────
  // Maps Flutter logical keys to JS key names for synthetic KeyboardEvent dispatch.
  // This mirrors the approach used in voltix-iptv's MainActivity.onKeyDown().

  static final Map<LogicalKeyboardKey, String> _dpadKeyMap = {
    LogicalKeyboardKey.arrowUp: 'ArrowUp',
    LogicalKeyboardKey.arrowDown: 'ArrowDown',
    LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
    LogicalKeyboardKey.arrowRight: 'ArrowRight',
  };

  static final Set<LogicalKeyboardKey> _selectKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  static final Set<LogicalKeyboardKey> _backKeys = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.goBack,
    LogicalKeyboardKey.browserBack,
    LogicalKeyboardKey.gameButtonB,
  };

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_focusNode.hasFocus || (ModalRoute.of(context)?.isCurrent == false)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    // ── Arrow keys → dispatch ArrowUp/Down/Left/Right to the web layer ──
    final jsKey = _dpadKeyMap[key];
    if (jsKey != null) {
      if (event is KeyDownEvent) {
        final keyCodes = { 'ArrowLeft': 37, 'ArrowUp': 38, 'ArrowRight': 39, 'ArrowDown': 40 };
        final kc = keyCodes[jsKey] ?? 0;
        _repeatingKey = key;
        _controller.runJavaScript('window.__dispatchFlutterKey("$jsKey", $kc, "keydown");');
        _startRepeatTimer(jsKey, kc);
      } else if (event is KeyRepeatEvent) {
        // Ignored; repeats are handled by custom _repeatTimer.
      } else if (event is KeyUpEvent) {
        if (_repeatingKey == key) {
          _stopRepeatTimer();
        }
        final keyCodes = { 'ArrowLeft': 37, 'ArrowUp': 38, 'ArrowRight': 39, 'ArrowDown': 40 };
        final kc = keyCodes[jsKey] ?? 0;
        _controller.runJavaScript('window.__dispatchFlutterKey("$jsKey", $kc, "keyup");');
      }
      return KeyEventResult.handled;
    }

    // ── Select/Enter → dispatch Enter + click on focused element ──
    if (_selectKeys.contains(key)) {
      if (event is KeyDownEvent) {
        _controller.runJavaScript('window.__dispatchFlutterKey("Enter", 13, "keydown");');
      }
      return KeyEventResult.handled;
    }

    // ── Back → exit fullscreen / close player / pop Flutter route ──
    if (_backKeys.contains(key)) {
      if (event is KeyDownEvent) {
        _handleBackNavigation();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _handleBackNavigation() {
    _controller.runJavaScriptReturningResult('''
      (function() {
        // 1. If video player modal is open, exit fullscreen and close the player
        var videoModal = document.querySelector('.fixed video');
        if (videoModal) {
          if (document.fullscreenElement) {
            document.exitFullscreen().catch(function() {});
          }
          var closeBtn = document.querySelector('button[aria-label="Go Back"]') || 
                         document.querySelector('button[aria-label="Back"]') ||
                         document.querySelector('.fixed button svg[class*="lucide-x"]')?.closest('button') ||
                         document.querySelector('.fixed button');
          if (closeBtn) {
            closeBtn.click();
            return 'closed_player';
          }
        }
        // 2. Otherwise, check for any other open modal/dialog and close it
        var fixedOverlays = document.querySelectorAll('.fixed');
        for (var i = fixedOverlays.length - 1; i >= 0; i--) {
          var overlay = fixedOverlays[i];
          if (overlay.tagName === 'HEADER') continue;
          var zIndex = parseInt(window.getComputedStyle(overlay).zIndex) || 0;
          if (zIndex < 100) continue;
          var closeBtn = overlay.querySelector('button svg[class*="lucide-x"]')?.closest('button') ||
                         overlay.querySelector('button[aria-label*="close"]') ||
                         overlay.querySelector('button[class*="hover:bg-white/10"]') ||
                         overlay.querySelector('button[class*="hover:bg-white/20"]');
          if (closeBtn) {
            closeBtn.click();
            return 'closed_modal';
          }
        }
        return 'none';
      })();
    ''').then((result) {
      final handled = result.toString().replaceAll('"', '');
      if (handled == 'none' && mounted) {
        // Nothing in the web layer to close — pop the Flutter route
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackNavigation();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF07090E),
        appBar: null,
        body: _hasError
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: Colors.red[400]),
                    const SizedBox(height: 16),
                    const Text(
                      'Failed to load IPTV',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Check your connection and try again',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _hasError = false;
                          _isLoading = true;
                        });
                        _controller.reload();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColorScheme.accent,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ],
                ),
              )
            : Focus(
                focusNode: _focusNode,
                autofocus: true,
                descendantsAreFocusable: false,
                onKeyEvent: _onKeyEvent,
                child: Stack(
                  children: [
                    WebViewWidget(controller: _controller),
                    if (_isLoading)
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: AppColorScheme.accent),
                            const SizedBox(height: 16),
                            Text(
                              'Loading IPTV...',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
