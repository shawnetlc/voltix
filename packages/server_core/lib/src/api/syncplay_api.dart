import '../models/syncplay_models.dart';

class UtcTimeResponse {
  final int requestReceptionTimeMs;
  final int responseTransmissionTimeMs;

  const UtcTimeResponse({
    required this.requestReceptionTimeMs,
    required this.responseTransmissionTimeMs,
  });

  factory UtcTimeResponse.fromJson(Map<String, dynamic> json) =>
      UtcTimeResponse(
        requestReceptionTimeMs:
            SyncPlayUtils.parseISOToMs(json['RequestReceptionTime'] as String?),
        responseTransmissionTimeMs: SyncPlayUtils.parseISOToMs(
            json['ResponseTransmissionTime'] as String?),
      );
}

abstract class SyncPlayApi {
  Future<void> createGroup(String groupName, {String? password});
  Future<void> joinGroup(String groupId, {String? password});
  Future<void> leaveGroup();
  Future<SyncPlayGroupInfo> getGroup(String groupId);
  Future<List<SyncPlayGroupInfo>> getGroups();

  Future<void> sendUnpause();
  Future<void> sendPause();
  Future<void> sendSeek(int positionTicks);
  Future<void> sendStop();
  Future<void> sendBuffering({
    required bool isPlaying,
    required String playlistItemId,
    required int positionTicks,
  });
  Future<void> sendReady({
    required bool isPlaying,
    required String playlistItemId,
    required int positionTicks,
  });
  Future<void> sendPing(int ping);

  Future<void> setNewQueue({
    required List<String> itemIds,
    required int startIndex,
    required int startPositionTicks,
  });
  Future<void> setPlaylistItem(String playlistItemId);
  Future<void> removeFromPlaylist(
    List<String> playlistItemIds, {
    bool clearPlaylist = false,
    bool clearPlayingItem = false,
  });
  Future<void> movePlaylistItem({
    required String playlistItemId,
    required int newIndex,
  });
  Future<void> queue({
    required List<String> itemIds,
    SyncPlayQueueMode mode = SyncPlayQueueMode.queue,
  });
  Future<void> nextItem(String playlistItemId);
  Future<void> previousItem(String playlistItemId);
  Future<void> setRepeatMode(SyncPlayRepeatMode mode);
  Future<void> setShuffleMode(SyncPlayShuffleMode mode);
  Future<void> setIgnoreWait(bool ignore);

  Future<UtcTimeResponse> getUtcTime();
}
