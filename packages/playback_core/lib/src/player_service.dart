import 'stream_resolution_result.dart';

abstract class PlayerService {
  Future<void> onPlaybackStart(
    dynamic mediaItem,
    StreamResolutionResult resolution, {
    int? positionTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  });

  Future<void> onPlaybackProgress(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position, {
    bool isPaused = false,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  });

  Future<void> onPlaybackStop(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position,
  );

  /// Closes an opened server-side live stream session by id. Used to release the
  /// server's upstream connection when the client is playing the live source
  /// directly (so only one upstream connection remains). Default: no-op.
  Future<void> closeLiveStream(String liveStreamId) async {}

  /// Asks the server to tear down any server-side transcoding session associated
  /// with [resolution]. Safe to call after direct-play streams. Default: no-op.
  Future<void> stopTranscoding(StreamResolutionResult resolution) async {}

  void dispose();
}
