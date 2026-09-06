import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Lightweight direct Azure Blob Storage client for managing JSON taste
/// profiles.
///
/// Authenticates with a SAS token only. Shared Key signing is deliberately not
/// implemented: it would require the storage account key on the device, and
/// that key grants full read/write/delete over every container in the account
/// -- which for Voltix means every user's taste profile, settings and watch
/// history. A SAS can be scoped to one container, given only the permissions
/// it needs, expired on a date, and revoked server-side without shipping a new
/// build. An account key can do none of those things.
///
/// The token is supplied at build time:
///
///   --dart-define=AZURE_BLOB_SAS_TOKEN=sv=2024-...&sp=racw&sr=c&sig=...
///   --dart-define=AZURE_BLOB_ACCOUNT_NAME=voltixstorage   (optional)
///
/// Generate it against the `voltix-taste-profiles` container with Read / Add /
/// Create / Write, an expiry you are willing to re-issue on, and nothing else.
/// No Delete, no List, and no account-level scope.
///
/// Without a token this client reports itself unconfigured and the sync
/// services fall through to the Voltix proxy, which is the preferred path
/// anyway because there the credential never leaves the server.
class AzureStorageClient {
  final Dio _dio;
  String _connectionString = '';
  String _containerName = 'voltix-taste-profiles';
  String? _accountName;
  String? _sasToken;
  String? _customEndpoint;

  /// Build-time SAS, used unless a runtime one is supplied.
  static const _envSasToken = String.fromEnvironment('AZURE_BLOB_SAS_TOKEN');
  static const _envAccountName =
      String.fromEnvironment('AZURE_BLOB_ACCOUNT_NAME');
  static const _defaultAccountName = 'voltixstorage';

  AzureStorageClient({Dio? dio}) : _dio = dio ?? Dio();

  String get containerName => _containerName;

  /// The runtime token if one was supplied, otherwise the build-time one.
  String? get _effectiveSasToken {
    if (_sasToken != null && _sasToken!.isNotEmpty) return _sasToken;
    if (_envSasToken.isNotEmpty) {
      return _envSasToken.startsWith('?')
          ? _envSasToken.substring(1)
          : _envSasToken;
    }
    return null;
  }

  String? get _effectiveAccountName {
    if (_accountName != null && _accountName!.isNotEmpty) return _accountName;
    if (_envAccountName.isNotEmpty) return _envAccountName;
    return _defaultAccountName;
  }

  /// Configured means "can actually authenticate a request".
  ///
  /// This used to count a parsed AccountKey as configuration, which made the
  /// client claim it was ready and then send unsigned requests that Azure
  /// answered with 403 -- there is no code here that signs with an account
  /// key. A SAS token, or a custom endpoint that carries its own, is the only
  /// thing that works.
  bool get isConfigured =>
      (_effectiveAccountName != null && _effectiveSasToken != null) ||
      _customEndpoint != null;

  void setContainerName(String name) {
    if (name.trim().isNotEmpty) {
      _containerName = name.trim();
    }
  }

  void setConnectionString(String connStr) {
    _connectionString = connStr.trim();
    _parseConnectionString(_connectionString);
  }

  void _parseConnectionString(String conn) {
    if (conn.isEmpty) {
      _accountName = null;
      _sasToken = null;
      _customEndpoint = null;
      return;
    }

    if (conn.startsWith('http://') || conn.startsWith('https://')) {
      final uri = Uri.tryParse(conn);
      if (uri != null) {
        _customEndpoint = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
        if (uri.query.isNotEmpty) {
          _sasToken = uri.query;
        }
        return;
      }
    }

    final parts = conn.split(';');
    for (final part in parts) {
      final kv = part.split('=');
      if (kv.length >= 2) {
        final key = kv[0].trim().toLowerCase();
        final value = kv.sublist(1).join('=').trim();
        if (key == 'accountname') {
          _accountName = value;
        } else if (key == 'accountkey') {
          // Deliberately discarded. Nothing here can sign with it, and keeping
          // it on the device is the exposure this client is written to avoid.
          debugPrint(
            '[AzureStorageClient] AccountKey in connection string ignored; '
            'supply a scoped SAS token instead.',
          );
        } else if (key == 'sharedaccesssignature' || key == 'sastoken') {
          _sasToken = value.startsWith('?') ? value.substring(1) : value;
        } else if (key == 'blobendpoint') {
          _customEndpoint = value.endsWith('/') ? value.substring(0, value.length - 1) : value;
        }
      }
    }
  }

  String _buildBlobUrl(String blobPath) {
    final cleanPath =
        blobPath.startsWith('/') ? blobPath.substring(1) : blobPath;
    final account = _effectiveAccountName;
    final base = _customEndpoint ??
        (account != null
            ? 'https://$account.blob.core.windows.net'
            : 'https://api.voltix.media/blob');
    final url = '$base/$_containerName/$cleanPath';
    final sas = _effectiveSasToken;
    if (sas != null && sas.isNotEmpty) {
      return '$url?$sas';
    }
    return url;
  }

  /// Puts JSON string as a Block Blob into the container.
  Future<bool> putBlockBlobJson({
    required String blobPath,
    required Map<String, dynamic> jsonData,
  }) async {
    try {
      final url = _buildBlobUrl(blobPath);
      final jsonString = jsonEncode(jsonData);

      final response = await _dio.put<dynamic>(
        url,
        data: jsonString,
        options: Options(
          headers: {
            'x-ms-blob-type': 'BlockBlob',
            'Content-Type': 'application/json; charset=utf-8',
            'x-ms-version': '2020-04-08',
          },
        ),
      );

      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      debugPrint('[AzureStorageClient] putBlockBlobJson failed: $e');
      return false;
    }
  }

  /// Fetches Block Blob JSON content from container.
  Future<Map<String, dynamic>?> getBlockBlobJson({
    required String blobPath,
  }) async {
    try {
      final url = _buildBlobUrl(blobPath);
      final response = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: {
            'x-ms-version': '2020-04-08',
          },
          responseType: ResponseType.json,
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        } else if (response.data is String) {
          final decoded = jsonDecode(response.data as String);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('[AzureStorageClient] getBlockBlobJson error for $blobPath: $e');
      return null;
    }
  }

  /// Deletes a Block Blob from the container.
  Future<bool> deleteBlockBlob({
    required String blobPath,
  }) async {
    try {
      final url = _buildBlobUrl(blobPath);
      final response = await _dio.delete<dynamic>(
        url,
        options: Options(
          headers: {
            'x-ms-version': '2020-04-08',
          },
        ),
      );
      return response.statusCode == 200 ||
          response.statusCode == 202 ||
          response.statusCode == 204;
    } catch (e) {
      debugPrint('[AzureStorageClient] deleteBlockBlob error: $e');
      return false;
    }
  }
}
