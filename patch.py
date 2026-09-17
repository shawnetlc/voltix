import re

with open('lib/data/services/azure_blob_storage_service.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Update _buildWatchRegistryBlobUrl
content = re.sub(
    r"String _buildWatchRegistryBlobUrl\(String username, String\? overrideSasToken\) {[\s\S]*?final blobName = 'watch-history/\$\{username\.toLowerCase\(\)\.trim\(\)\}_watch_history\.json';",
    "String _buildWatchRegistryBlobUrl(String username, String? overrideSasToken, {int? profileId}) {\n    final cleanUser = username.toLowerCase().trim();\n    final blobName = profileId != null \n        ? 'watch-history/_profile_watch_history.json' \n        : 'watch-history/_watch_history.json';",
    content
)

# Update uploadWatchRegistryBlob
content = re.sub(
    r"Future<bool> uploadWatchRegistryBlob\({\n\s*required String username,\n\s*required Map<String, dynamic> registryData,\n\s*String\? sasToken,\n\s*}\) async {\n\s*final cleanUser = username\.toLowerCase\(\)\.trim\(\);\n\s*if \(cleanUser\.isEmpty\) return false;\n\s*final blobName = 'watch-history/\$\{cleanUser\}_watch_history\.json';",
    "Future<bool> uploadWatchRegistryBlob({\n    required String username,\n    required Map<String, dynamic> registryData,\n    String? sasToken,\n    int? profileId,\n  }) async {\n    final cleanUser = username.toLowerCase().trim();\n    if (cleanUser.isEmpty) return false;\n    final blobName = profileId != null\n        ? 'watch-history/_profile_watch_history.json'\n        : 'watch-history/_watch_history.json';",
    content
)

# Update _buildWatchRegistryBlobUrl call in uploadWatchRegistryBlob
content = re.sub(
    r"final url = _buildWatchRegistryBlobUrl\(cleanUser, sasToken\);",
    "final url = _buildWatchRegistryBlobUrl(cleanUser, sasToken, profileId: profileId);",
    content
)

# Update downloadWatchRegistryBlob
content = re.sub(
    r"Future<Map<String, dynamic>\?> downloadWatchRegistryBlob\({\n\s*required String username,\n\s*String\? sasToken,\n\s*}\) async {\n\s*final cleanUser = username\.toLowerCase\(\)\.trim\(\);\n\s*if \(cleanUser\.isEmpty\) return null;\n\s*final blobName = 'watch-history/\$\{cleanUser\}_watch_history\.json';",
    "Future<Map<String, dynamic>?> downloadWatchRegistryBlob({\n    required String username,\n    String? sasToken,\n    int? profileId,\n  }) async {\n    final cleanUser = username.toLowerCase().trim();\n    if (cleanUser.isEmpty) return null;\n    final blobName = profileId != null\n        ? 'watch-history/_profile_watch_history.json'\n        : 'watch-history/_watch_history.json';",
    content
)

# Also add the favorites registry methods
favorites_methods = \"\"\"
  // ═══════════════════════════════════════════════════════════════════
  // ── Favorites Registry Blob (favorites/<username>_profile<profileId>_favorites.json)
  // ═══════════════════════════════════════════════════════════════════

  String _buildFavoritesRegistryBlobUrl(String username, int profileId, String? overrideSasToken) {
    final cleanUser = username.toLowerCase().trim();
    final blobName = 'favorites/_profile_favorites.json';
    final token = (overrideSasToken != null && overrideSasToken.isNotEmpty)
        ? overrideSasToken
        : envSasToken;
    final tokenQuery = token.isNotEmpty
        ? (token.startsWith('?') ? token : '?\')
        : '';
    return '\/\/\\';
  }

  Future<bool> uploadFavoritesRegistryBlob({
    required String username,
    required int profileId,
    required Map<String, dynamic> registryData,
    String? sasToken,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return false;
    final blobName = 'favorites/_profile_favorites.json';

    final payloadJson = jsonEncode(registryData);
    _logger.i('[AzureBlob] Uploading favorites registry for @\ profile \');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        headers: {'Content-Type': 'application/json'},
      ));
      final proxyUrl = '\/api/voltix/azure-sync';
      final response = await syncDio.post(
        proxyUrl,
        data: {
          'username': cleanUser,
          'blobName': blobName,
          'settings': registryData,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      final body = response.data;
      final reportedSuccess = body is Map ? body['success'] != false : true;
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          reportedSuccess) {
        _logger.i('[AzureBlob] Favorites registry upload succeeded for @\');
        return true;
      }
    } catch (e) {
      _logger.w('[AzureBlob] Proxy favorites registry upload failed (\), trying direct...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildFavoritesRegistryBlobUrl(cleanUser, profileId, sasToken);
      final response = await _dio.put(
        url,
        data: payloadJson,
        options: Options(
          headers: {
            'x-ms-blob-type': 'BlockBlob',
            'Content-Type': 'application/json; charset=utf-8',
          },
        ),
      );
      return response.statusCode == 201 || response.statusCode == 200;
    } catch (e) {
      _logger.e('[AzureBlob] All favorites registry upload attempts failed', error: e);
      return false;
    }
  }

  Future<Map<String, dynamic>?> downloadFavoritesRegistryBlob({
    required String username,
    required int profileId,
    String? sasToken,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return null;
    final blobName = 'favorites/_profile_favorites.json';

    _logger.i('[AzureBlob] Downloading favorites registry for @\ profile \');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final proxyUrl = '\/api/voltix/azure-sync';
      final response = await syncDio.get(
        proxyUrl,
        queryParameters: {'username': cleanUser, 'blobName': blobName},
      );
      final data = response.data;
      if (data is Map) {
        if (data['settings'] is Map) {
          return Map<String, dynamic>.from(data['settings'] as Map);
        }
        return Map<String, dynamic>.from(data);
      }
    } catch (e) {
      _logger.w('[AzureBlob] Proxy favorites registry download failed (\), trying direct...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildFavoritesRegistryBlobUrl(cleanUser, profileId, sasToken);
      final response = await _dio.get(url);
      if (response.statusCode == 200) {
        final decoded = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
    return null;
  }
}
\"\"\"

content = content.replace('}\n', '}\n' + favorites_methods)
content = content.replace(favorites_methods + favorites_methods, favorites_methods)

with open('lib/data/services/azure_blob_storage_service.dart', 'w', encoding='utf-8') as f:
    f.write(content)
