import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  // Note: these run on the Dart VM (non-web), so isWebPlatform is false and the
  // web exclusion branch can't be exercised here; it's covered by the const.
  group('MediaStreamResolver.isLiveSourceDirectPlayEligible', () {
    bool eligible({
      bool enableDirectPlay = true,
      bool isManagedLiveStream = true,
      String? path =
          'http://192.168.50.7:8096/LiveTv/LiveStreamFiles/abc/stream.ts',
    }) {
      return MediaStreamResolver.isLiveSourceDirectPlayEligible(
        enableDirectPlay: enableDirectPlay,
        isManagedLiveStream: isManagedLiveStream,
        path: path,
      );
    }

    test('eligible for a managed live http(s) path', () {
      // Server-served remux feed (Jellyfin LiveStreamFiles).
      expect(eligible(), isTrue);
      // Remote upstream URL.
      expect(eligible(path: 'https://provider.example/live/1'), isTrue);
    });

    test('not eligible when direct play is disabled', () {
      expect(eligible(enableDirectPlay: false), isFalse);
    });

    test('not eligible for non-live (no liveStreamId)', () {
      expect(eligible(isManagedLiveStream: false), isFalse);
    });

    test('not eligible when path is missing or not http(s)', () {
      expect(eligible(path: null), isFalse);
      expect(eligible(path: 'file:///tuner/0'), isFalse);
      expect(eligible(path: 'rtsp://provider/live'), isFalse);
      expect(eligible(path: ''), isFalse);
    });
  });
}
