import 'package:server_core/server_core.dart';

/// JPEG/WebP quality requested for posters, backdrops, thumbs and banners.
/// The server default is 90; 80 is visually identical at card sizes and makes
/// each image roughly a quarter smaller, so rows fill in faster.
const _kArtworkQuality = '80';

/// Artwork is requested as WebP: ~25-35% smaller than JPEG at the same
/// quality, decoded natively on Android / Android TV and in browsers.
// WebP was tried and removed: servers whose image encoder lacks WebP
// answer with an error, and every poster fell back to its title text.
// ignore: unused_element
const _kArtworkFormat = 'Webp';

/// Requested sizes are rounded UP to a few standard steps. Jellyfin keeps a
/// cache of resized images keyed by the exact size asked for, so arbitrary
/// widths (213, 227, 241 ... per screen and device) meant it resized almost
/// every poster from scratch; standard steps let it serve cached copies to
/// every device.
const _kSizeSteps = <int>[120, 180, 240, 320, 400, 480, 640, 800, 960, 1280, 1920];

String _bucket(int px) {
  if (px <= 0) return px.toString();
  for (final step in _kSizeSteps) {
    if (px <= step) return step.toString();
  }
  return px.toString();
}

class JellyfinImageApi implements ImageApi {
  final String _baseUrl;

  JellyfinImageApi(this._baseUrl);

  String _buildQuery(Map<String, String> params) {
    if (params.isEmpty) return '';
    return '?${params.entries.map((e) => '${e.key}=${e.value}').join('&')}';
  }

  @override
  String getPrimaryImageUrl(
    String itemId, {
    int? maxWidth,
    int? maxHeight,
    String? tag,
  }) {
    final query = _buildQuery({
      if (maxWidth != null) 'maxWidth': _bucket(maxWidth),
      'quality': _kArtworkQuality,
      if (maxHeight != null) 'maxHeight': _bucket(maxHeight),
      'tag': ?tag,
    });
    return '$_baseUrl/Items/$itemId/Images/Primary$query';
  }

  @override
  String getBackdropImageUrl(
    String itemId, {
    int? maxWidth,
    int? index,
    String? tag,
  }) {
    final idx = index ?? 0;
    final query = _buildQuery({
      if (maxWidth != null) 'maxWidth': _bucket(maxWidth),
      'quality': _kArtworkQuality,
      'tag': ?tag,
    });
    return '$_baseUrl/Items/$itemId/Images/Backdrop/$idx$query';
  }

  @override
  String getLogoImageUrl(
    String itemId, {
    int? maxWidth,
    String? tag,
  }) {
    final query = _buildQuery({
      if (maxWidth != null) 'maxWidth': _bucket(maxWidth),
      'tag': ?tag,
    });
    return '$_baseUrl/Items/$itemId/Images/Logo$query';
  }

  @override
  String getBannerImageUrl(
    String itemId, {
    int? maxWidth,
    String? tag,
  }) {
    final query = _buildQuery({
      if (maxWidth != null) 'maxWidth': _bucket(maxWidth),
      'quality': _kArtworkQuality,
      'tag': ?tag,
    });
    return '$_baseUrl/Items/$itemId/Images/Banner$query';
  }

  @override
  String getThumbImageUrl(
    String itemId, {
    int? maxWidth,
    String? tag,
  }) {
    final query = _buildQuery({
      if (maxWidth != null) 'maxWidth': _bucket(maxWidth),
      'quality': _kArtworkQuality,
      'tag': ?tag,
    });
    return '$_baseUrl/Items/$itemId/Images/Thumb$query';
  }

  @override
  String getChapterImageUrl(
    String itemId, {
    required int index,
    int? maxWidth,
    String? tag,
  }) {
    final query = _buildQuery({
      if (maxWidth != null) 'maxWidth': _bucket(maxWidth),
      'tag': ?tag,
    });
    return '$_baseUrl/Items/$itemId/Images/Chapter/$index$query';
  }

  @override
  String getUserImageUrl(String userId, {String? tag}) {
    final query = _buildQuery({
      'tag': ?tag,
    });
    return '$_baseUrl/Users/$userId/Images/Primary$query';
  }

  @override
  String getTrickplayTileImageUrl(
    String itemId, {
    required int width,
    required int index,
    String? mediaSourceId,
  }) {
    final query = _buildQuery({
      'mediaSourceId': ?mediaSourceId,
    });
    return '$_baseUrl/Videos/$itemId/Trickplay/$width/$index.jpg$query';
  }
}
