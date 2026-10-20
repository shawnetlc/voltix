import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:get_it/get_it.dart';

import '../../preference/user_preferences.dart';
import '../../util/device_performance_profile.dart';
import '../../util/platform_detection.dart';

/// Disk cache for posters and artwork.
///
/// The package default keeps only 200 files. A home screen alone shows more
/// posters than that, so artwork was being evicted and downloaded again on
/// every launch - the main reason posters "loaded slowly" after the first
/// visit.
///
/// This is a disk cache only - it never holds images in RAM (the in-memory
/// cache is set separately in main.dart, and is kept tiny on TV). TVs get a
/// smaller budget because entry-level boxes (Skyworth etc.) often have little
/// free storage: 1200 posters is roughly 50-90 MB; elsewhere 4000 (~150-300
/// MB). The oldest files are removed automatically past the limit.
class ArtworkCacheManager {
  static const _key = 'voltixArtworkCache';
  static final CacheManager instance = CacheManager(
    Config(
      _key,
      stalePeriod: Duration(days: _smallBudget ? 14 : 30),
      maxNrOfCacheObjects: _smallBudget ? 1200 : 4000,
    ),
  );

  /// Entry-level TVs keep the smaller budget; a TV set up as "Performance"
  /// in the setup wizard gets the full one.
  static bool get _smallBudget {
    if (!PlatformDetection.isTV) return false;
    try {
      if (GetIt.instance.isRegistered<UserPreferences>()) {
        return !DevicePerformanceProfile.isPerformance(
          GetIt.instance<UserPreferences>(),
        );
      }
    } catch (_) {}
    return true;
  }
}

/// A [CachedNetworkImage] whose decoded pixel width is bounded to the
/// rendered widget width times the device pixel ratio, optionally clamped
/// and/or scaled. This keeps the in-memory image cache from holding decodes
/// far larger than what is actually painted (a common source of jank and
/// large RAM usage on web).
class BoundedNetworkImage extends StatelessWidget {
  final String imageUrl;
  final BoxFit fit;
  final Alignment alignment;
  final Duration fadeInDuration;
  final Widget Function(BuildContext context, String url, Object error)?
      errorBuilder;
  final VoidCallback? onLoadFinished;

  /// Multiplier applied to the resolved width before clamping. Useful for
  /// blurred images where a low-resolution decode is acceptable.
  final double scale;

  /// Lower bound for the decoded width in physical pixels.
  final int minWidth;

  /// Upper bound for the decoded width in physical pixels.
  final int maxWidth;

  const BoundedNetworkImage({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fadeInDuration = Duration.zero,
    this.errorBuilder,
    this.onLoadFinished,
    this.scale = 1.0,
    this.minWidth = 64,
    this.maxWidth = 1024,
  });

  static int _cacheWidthFor(
    double layoutWidth,
    double devicePixelRatio, {
    double scale = 1.0,
    int minWidth = 64,
    int maxWidth = 1024,
  }) {
    return (layoutWidth * devicePixelRatio * scale)
        .round()
        .clamp(minWidth, maxWidth);
  }

  static Future<void> precache(
    BuildContext context,
    String imageUrl, {
    required double layoutWidth,
    double scale = 1.0,
    int minWidth = 64,
    int maxWidth = 1024,
  }) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheW = _cacheWidthFor(
      layoutWidth,
      dpr,
      scale: scale,
      minWidth: minWidth,
      maxWidth: maxWidth,
    );
    return precacheImage(
      ResizeImage.resizeIfNeeded(
        cacheW,
        null,
        CachedNetworkImageProvider(
          imageUrl,
          cacheManager: ArtworkCacheManager.instance,
        ),
      ),
      context,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheW = _cacheWidthFor(
          constraints.maxWidth,
          dpr,
          scale: scale,
          minWidth: minWidth,
          maxWidth: maxWidth,
        );
        return _image(cacheW, imageUrl);
      },
    );
  }

  Widget _image(int cacheW, String url) {
        return CachedNetworkImage(
          imageUrl: url,
          fit: fit,
          alignment: alignment,
          fadeInDuration: fadeInDuration,
          // The package default fades the (empty) placeholder out over a full
          // second before the poster shows, even when it came from disk.
          fadeOutDuration: Duration.zero,
          placeholderFadeInDuration: Duration.zero,
          cacheManager: ArtworkCacheManager.instance,
          // Decode at the painted size (cheap, done by the engine). The disk
          // copy is kept as the server sent it: the URL already asks the
          // server for the right size, and re-encoding a resized copy on the
          // device (maxWidthDiskCache) was slow on TV boxes and stored every
          // poster twice.
          memCacheWidth: cacheW,
          // A failed poster (busy server, dropped connection) retries a couple
          // of times before showing the fallback, instead of staying as title
          // text until the app restarts.
          errorWidget: (context, failedUrl, error) => _RetryThenFallback(
            url: imageUrl,
            // A different URL per attempt (Jellyfin ignores the extra
            // parameter) so the retry is a fresh download, not the cached
            // failure.
            retry: (attempt) => _image(
              cacheW,
              '$imageUrl${imageUrl.contains('?') ? '&' : '?'}r=$attempt',
            ),
            fallback: () => errorBuilder == null
                ? const SizedBox.shrink()
                : errorBuilder!(context, failedUrl, error),
          ),
        );
  }
}

class _RetryThenFallback extends StatefulWidget {
  final String url;
  final Widget Function(int attempt) retry;
  final Widget Function() fallback;

  const _RetryThenFallback({
    required this.url,
    required this.retry,
    required this.fallback,
  });

  @override
  State<_RetryThenFallback> createState() => _RetryThenFallbackState();
}

class _RetryThenFallbackState extends State<_RetryThenFallback> {
  static const _maxRetries = 2;
  static final Map<String, int> _attempts = {};
  bool _retrying = false;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    final n = _attempts[widget.url] ?? 0;
    if (n < _maxRetries) {
      _waiting = true;
      if (_attempts.length > 2000) _attempts.clear();
      Future<void>.delayed(Duration(seconds: 2 + n * 3), () {
        _attempts[widget.url] = n + 1;
        if (mounted) setState(() => _retrying = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_retrying) return widget.retry(_attempts[widget.url] ?? 1);
    // Blank while a retry is pending; the title fallback only when retries
    // are used up.
    return _waiting ? const SizedBox.expand() : widget.fallback();
  }
}
