import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

class OfflineImage extends StatelessWidget {
  final String? localPath;
  final String? networkUrl;
  final double? width;
  final double? height;
  final BoxFit fit;

  const OfflineImage({
    super.key,
    this.localPath,
    this.networkUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    if (localPath != null && File(localPath!).existsSync()) {
      return Image.file(
        File(localPath!),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }

    if (networkUrl != null && networkUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: networkUrl!,
        width: width,
        height: height,
        fit: fit,
        errorWidget: (_, _, _) => _placeholder(),
      );
    }

    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      width: width,
      height: height,
      color: AppColorScheme.onSurface.withValues(alpha: 0.05),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: AppColorScheme.onSurface.withValues(alpha: 0.24),
          size: 40,
        ),
      ),
    );
  }
}
