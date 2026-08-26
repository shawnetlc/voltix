import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';

class EmbyPlaybackApi implements PlaybackApi {
  final Dio _dio;
  final String Function() _getBaseUrl;

  EmbyPlaybackApi(this._dio, this._getBaseUrl);

  @override
  Future<void> reportPlaybackStart(Map<String, dynamic> info) async {
    await _dio.post('/Sessions/Playing', data: info);
  }

  @override
  Future<void> reportPlaybackProgress(Map<String, dynamic> info) async {
    await _dio.post('/Sessions/Playing/Progress', data: info);
  }

  @override
  Future<void> reportPlaybackStopped(Map<String, dynamic> info) async {
    await _dio.post('/Sessions/Playing/Stopped', data: info);
  }

  @override
  Future<void> closeLiveStream(String liveStreamId) async {
    await _dio.post(
      '/LiveStreams/Close',
      queryParameters: {'LiveStreamId': liveStreamId},
    );
  }

  @override
  Future<Map<String, dynamic>> getPlaybackInfo(
    String itemId, {
    Map<String, dynamic>? requestBody,
    String? userId,
    int? startTimeTicks,
  }) async {
    final body = <String, dynamic>{
      'UserId': ?userId,
      ...?requestBody,
    };

    final audioStreamIndex = requestBody?['AudioStreamIndex'] ?? requestBody?['audioStreamIndex'];
    final subtitleStreamIndex = requestBody?['SubtitleStreamIndex'] ?? requestBody?['subtitleStreamIndex'];
    final mediaSourceId = requestBody?['MediaSourceId'] ?? requestBody?['mediaSourceId'];
    final maxStreamingBitrate = requestBody?['MaxStreamingBitrate'] ?? requestBody?['maxStreamingBitrate'];

    final response = await _dio.post(
      '/Items/$itemId/PlaybackInfo',
      data: body,
      queryParameters: {
        'userId': ?userId,
        'startTimeTicks': ?startTimeTicks,
        'audioStreamIndex': ?audioStreamIndex?.toString(),
        'subtitleStreamIndex': ?subtitleStreamIndex?.toString(),
        'mediaSourceId': ?mediaSourceId,
        'maxStreamingBitrate': ?maxStreamingBitrate?.toString(),
      },
    );
    return response.data as Map<String, dynamic>;
  }

  @override
  String getStreamUrl(
    String itemId, {
    String? mediaSourceId,
    String? audioStreamIndex,
    String? subtitleStreamIndex,
    String? liveStreamId,
  }) {
    final params = <String, String>{
      'MediaSourceId': ?mediaSourceId,
      'AudioStreamIndex': ?audioStreamIndex,
      'SubtitleStreamIndex': ?subtitleStreamIndex,
      'LiveStreamId': ?liveStreamId,
      'Static': 'true',
    };
    final uri = Uri.parse('${_getBaseUrl()}/Videos/$itemId/stream')
        .replace(queryParameters: params);
    return uri.toString();
  }
}
