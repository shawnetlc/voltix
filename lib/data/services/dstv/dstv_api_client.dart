import 'package:dio/dio.dart';
import 'package:intl/intl.dart';

import '../../models/dstv/dstv_epg_models.dart';

/// Thin client for DStv's public (unauthenticated) TV Guide API. Same
/// endpoints DStv's own website uses to render https://www.dstv.com/tvguide.
///
/// GET /GetChannels?country=zaf&unit=dstv
///   -> the ~168 DStv channels: Number, Name, Tag, Logo, ChannelLogoDark,
///      ChannelDetail, ThumbnailImageUrl. Effectively static; safe to cache
///      for a day.
/// GET /GetProgrammes?d=YYYY-MM-DD&country=zaf&unit=dstv
///   -> the ~158 channels with that single calendar date's schedule, each as
///      Number/Tag/Name + a Programmes[] of StartTime/EndTime/Title. Times
///      are SAST (UTC+2) with no timezone suffix.
class DstvApiClient {
  static const _baseUrl = 'https://www.dstv.com/umbraco/api/TvGuide';
  static const _country = 'zaf';
  static const _unit = 'dstv';

  final Dio _dio;

  DstvApiClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));

  /// The full DStv channel list. Throws on failure -- callers decide how to
  /// degrade (the repository caches the last good result for this reason).
  Future<List<DstvChannel>> getChannels() async {
    final response = await _dio.get(
      '/GetChannels',
      queryParameters: {'country': _country, 'unit': _unit},
    );
    return _asJsonList(response.data)
        .whereType<Map<String, dynamic>>()
        .map(DstvChannel.fromJson)
        .toList();
  }

  /// One calendar date's full programme schedule, across every channel.
  Future<List<DstvChannelSchedule>> getProgrammes(DateTime date) async {
    final d = DateFormat('yyyy-MM-dd').format(date);
    final response = await _dio.get(
      '/GetProgrammes',
      queryParameters: {'d': d, 'country': _country, 'unit': _unit},
    );
    return _asJsonList(response.data)
        .whereType<Map<String, dynamic>>()
        .map(DstvChannelSchedule.fromJson)
        .toList();
  }

  /// The documented responses are bare JSON arrays, but this tolerates a
  /// wrapper object (e.g. `{"Channels": [...]}` / `{"data": [...]}`) in case
  /// DStv ever changes the envelope without changing the field names inside.
  List<dynamic> _asJsonList(dynamic data) {
    if (data is List) return data;
    if (data is Map) {
      for (final value in data.values) {
        if (value is List) return value;
      }
    }
    return const [];
  }

  void close() => _dio.close();
}
