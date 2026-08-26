abstract class PlaybackApi {
  Future<void> reportPlaybackStart(Map<String, dynamic> info);
  Future<void> reportPlaybackProgress(Map<String, dynamic> info);
  Future<void> reportPlaybackStopped(Map<String, dynamic> info);
  Future<void> closeLiveStream(String liveStreamId);

  Future<Map<String, dynamic>> getPlaybackInfo(
    String itemId, {
    Map<String, dynamic>? requestBody,
    String? userId,
    int? startTimeTicks,
  });

  String getStreamUrl(
    String itemId, {
    String? mediaSourceId,
    String? audioStreamIndex,
    String? subtitleStreamIndex,
    String? liveStreamId,
  });
}
