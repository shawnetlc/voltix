import 'native_game_player.dart';

/// The native libretro session on tvOS, where cores are bundled in the Runner
/// and loaded through the AppleTvGameChannel.
class AppleTvGamePlayer extends MethodChannelGamePlayer {
  AppleTvGamePlayer()
      : super('voltix/appletv_game_control', 'voltix/appletv_game_events');
}
