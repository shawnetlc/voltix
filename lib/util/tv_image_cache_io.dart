import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'platform_detection.dart';

Future<void> configureAppleTvImageCache() async {
  if (!PlatformDetection.isAppleTV) return;
  try {
    final cacheDir = await getApplicationCacheDirectory();
    CachedNetworkImageProvider.defaultCacheManager = CacheManager(
      Config(
        DefaultCacheManager.key,
        repo: JsonCacheInfoRepository.withFile(
          File('${cacheDir.path}/${DefaultCacheManager.key}.json'),
        ),
      ),
    );
  } catch (_) {}
}
