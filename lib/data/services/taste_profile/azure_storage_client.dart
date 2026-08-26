import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Lightweight direct Azure Blob Storage client for managing JSON taste profiles.
class AzureStorageClient {
  final Dio _dio;
  String _connectionString = '';
  String _containerName = 'taste-profiles';
  String? _accountName;
  String? _accountKey;
  String? _sasToken;
  String? _customEndpoint;

  AzureStorageClient({Dio? dio}) : _dio = dio ?? Dio();

  String get containerName => _containerName;

  bool get isConfigured =>
      (_accountName != null && (_accountKey != null || _sasToken != null)) ||
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
      _accountKey = null;
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
          _accountKey = value;
        } else if (key == 'sharedaccesssignature' || key == 'sastoken') {
          _sasToken = value.startsWith('?') ? value.substring(1) : value;
        } else if (key == 'blobendpoint') {
          _customEndpoint = value.endsWith('/') ? value.substring(0, value.length - 1) : value;
        }
      }
    }
  }

  String _buildBlobUrl(String blobPath) {
    final cleanPath = blobPath.startsWith('/') ? blobPath.substring(1) : blobPath;
    final base = _customEndpoint ??
        (_accountName != null ? 'https://$_accountName.blob.core.windows.net' : 'https://api.voltix.media/blob');
    final url = '$base/$_containerName/$cleanPath';
    if (_sasToken != null && _sasToken!.isNotEmpty) {
      return '$url?$_sasToken';
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
