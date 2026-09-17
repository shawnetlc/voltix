import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';
import 'package:playback_jellyfin/playback_jellyfin.dart';
import 'package:server_core/server_core.dart';

class _FakePlaybackApi implements PlaybackApi {
  Map<String, dynamic> playbackInfoResponse = {};

  @override
  Future<Map<String, dynamic>> getPlaybackInfo(
    String itemId, {
    Map<String, dynamic>? requestBody,
    String? userId,
    int? startTimeTicks,
  }) async {
    return playbackInfoResponse;
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
      'Static': 'true',
    };
    final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');
    return 'http://test-server:8096/Videos/$itemId/stream?$query';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMediaServerClient implements MediaServerClient {
  @override
  String baseUrl = 'http://test-server:8096/';

  @override
  String? accessToken = 'test_token_123';

  @override
  String? userId = 'user_abc';

  @override
  DeviceInfo deviceInfo = const DeviceInfo(
    id: 'device_1',
    name: 'TestDevice',
    appName: 'Voltix',
    appVersion: '2.5.0',
  );

  final _FakePlaybackApi fakePlaybackApi = _FakePlaybackApi();

  @override
  PlaybackApi get playbackApi => fakePlaybackApi;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('JellyfinMediaStreamResolver', () {
    late _FakeMediaServerClient client;
    late JellyfinMediaStreamResolver resolver;

    setUp(() {
      client = _FakeMediaServerClient();
      resolver = JellyfinMediaStreamResolver(client);
    });

    test('resolves direct play when enableDirectPlay is true', () async {
      client.fakePlaybackApi.playbackInfoResponse = {
        'MediaSources': [
          {
            'Id': 'src_1',
            'SupportsDirectPlay': true,
            'SupportsDirectStream': true,
            'SupportsTranscoding': true,
            'DirectStreamUrl': '/Videos/item1/stream.mkv',
            'TranscodingUrl': '/Videos/item1/master.m3u8',
            'MediaStreams': [
              {'Type': 'Video', 'Codec': 'h264'},
              {'Type': 'Audio', 'Codec': 'aac'},
            ],
          }
        ],
        'PlaySessionId': 'session_1',
      };

      final result = await resolver.resolve(
        {'Id': 'item1'},
        enableDirectPlay: true,
      );

      expect(result.playMethod, StreamPlayMethod.directPlay);
      expect(result.streamUrl, contains('/Videos/item1/stream'));
      expect(result.streamUrl, contains('api_key=test_token_123'));
      expect(result.requestHeaders['X-Emby-Token'], 'test_token_123');
    });

    test('falls back to directStream when enableDirectPlay is false', () async {
      client.fakePlaybackApi.playbackInfoResponse = {
        'MediaSources': [
          {
            'Id': 'src_1',
            'SupportsDirectPlay': true,
            'SupportsDirectStream': true,
            'SupportsTranscoding': true,
            'DirectStreamUrl': '/Videos/item1/stream.mkv',
            'TranscodingUrl': '/Videos/item1/master.m3u8',
            'MediaStreams': [
              {'Type': 'Video', 'Codec': 'h264'},
              {'Type': 'Audio', 'Codec': 'aac'},
            ],
          }
        ],
        'PlaySessionId': 'session_1',
      };

      final result = await resolver.resolve(
        {'Id': 'item1'},
        enableDirectPlay: false,
      );

      expect(result.playMethod, StreamPlayMethod.directStream);
      expect(result.streamUrl, startsWith('http://test-server:8096/Videos/item1/stream.mkv'));
      expect(result.streamUrl, isNot(contains('//Videos')));
      expect(result.streamUrl, contains('api_key=test_token_123'));
    });

    test('falls back to transcode when directPlay and directStream are unsupported', () async {
      client.fakePlaybackApi.playbackInfoResponse = {
        'MediaSources': [
          {
            'Id': 'src_1',
            'SupportsDirectPlay': true,
            'SupportsDirectStream': false,
            'SupportsTranscoding': true,
            'TranscodingUrl': '/Videos/item1/master.m3u8',
            'MediaStreams': [
              {'Type': 'Video', 'Codec': 'hevc'},
              {'Type': 'Audio', 'Codec': 'truehd'},
            ],
          }
        ],
        'PlaySessionId': 'session_2',
      };

      final result = await resolver.resolve(
        {'Id': 'item1'},
        enableDirectPlay: false,
      );

      expect(result.playMethod, StreamPlayMethod.transcode);
      expect(result.streamUrl, startsWith('http://test-server:8096/Videos/item1/master.m3u8'));
      expect(result.streamUrl, isNot(contains('//Videos')));
      expect(result.streamUrl, contains('api_key=test_token_123'));
    });
  });
}
