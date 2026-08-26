import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:playback_core/playback_core.dart';
import 'package:playback_emby/playback_emby.dart';
import 'package:playback_jellyfin/playback_jellyfin.dart';
import 'package:server_core/server_core.dart';

import '../../../playback/device_profile_builder.dart';
import '../../../preference/preference_constants.dart';
import '../../../util/platform_detection.dart';
import '../../models/aggregated_item.dart';
import '../media_server_client_factory.dart';
import 'cast_provider.dart';
import 'cast_target.dart';
import 'cast_transport_controls.dart';
import 'native_cast_channel.dart';

class GoogleCastProvider implements CastProvider, CastTransportControls {
  final NativeCastChannel _native;
  final MediaServerClientFactory _clientFactory;

  static final Logger _logger = Logger();

  const GoogleCastProvider(this._native, this._clientFactory);

  MediaStreamResolver _resolverForClient(MediaServerClient client) {
    return switch (client.serverType) {
      ServerType.jellyfin => JellyfinPlugin(client).createStreamResolver(),
      ServerType.emby => EmbyPlugin(client).createStreamResolver(),
    };
  }

  /// Profile describing what a Chromecast receiver can actually decode.
  ///
  /// The Default Media Receiver handles AAC/MP3/Opus/Vorbis and stereo FLAC. It
  /// cannot decode DTS or TrueHD at all, and (E)AC-3 only survives as
  /// passthrough on hardware and AVR setups we cannot detect from here. Library
  /// files routinely carry exactly those codecs, which is why casting produced
  /// picture with no sound: without a profile the server reported the source as
  /// direct-playable, the original file went straight to the receiver, the video
  /// track decoded and the audio track was silently dropped.
  ///
  /// forceStereo collapses the allowed audio codecs to aac/mp2/mp3 and adds a
  /// max-2-channel constraint, so the server transcodes to AAC stereo.
  static Map<String, dynamic> _castDeviceProfile() =>
      DeviceProfileBuilder.build(
        maxBitrateMbps: 15,
        audioOutputMode: AudioOutputMode.forceStereo,
        audioFallbackCodec: AudioFallbackCodec.aac,
        maxAudioChannels: 2,
        supportsAvc: true,
      );

  Future<String> _streamUrlForItem(
    MediaServerClient client,
    AggregatedItem item, {
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    if (item.serverId == 'iptv') {
      return item.rawData['url'] as String? ?? '';
    }
    final resolution = await _resolverForClient(client).resolve(
      item,
      deviceProfile: _castDeviceProfile(),
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      mediaSourceId: mediaSourceId,
      // Direct play must be off, not just profiled. With a profile but direct
      // play allowed, an MKV whose audio the receiver cannot decode still gets
      // handed over untouched, because mkv is in the profile's direct-play
      // container list. Forcing the transcode yields an HLS URL with AAC audio,
      // which is also what makes the native layer label the content type
      // correctly.
      enableDirectPlay: false,
      enableDirectStream: false,
    );
    return resolution.streamUrl;
  }

  @override
  Set<CastTargetKind> get supportedKinds => {CastTargetKind.googleCast};

  @override
  Set<CastTargetKind> get controllableKinds => {CastTargetKind.googleCast};

  /// Cached GMS availability. Null until the first check.
  ///
  /// Static because the provider is const-constructed: a per-instance field
  /// would be re-evaluated on every discovery pass. Play services cannot appear
  /// or vanish during a session, so one check per process is right.
  static bool? _castAvailable;

  @override
  Future<List<CastTarget>> discoverTargets(AggregatedItem item) async {
    if (!PlatformDetection.isAndroid && !PlatformDetection.isIOS) {
      return const [];
    }

    // Google Cast is part of Google Play services. Huawei devices shipped since
    // 2019 have no GMS, so discovery there can only ever fail - returning no
    // targets keeps the Cast option out of the UI entirely rather than showing
    // a button that errors when tapped. DLNA is unaffected: it is a local
    // SSDP/UPnP implementation with no Google dependency.
    _castAvailable ??= await _native.isGoogleCastAvailable();
    if (_castAvailable != true) {
      return const [];
    }

    try {
      return await _native.discoverGoogleCastTargets();
    } catch (e, st) {
      _logger.w('Google Cast discovery failed', error: e, stackTrace: st);
      return const [];
    }
  }

  @override
  Future<void> playToTarget(
    CastTarget target, {
    required AggregatedItem item,
    List<AggregatedItem>? queueItems,
    int? startPositionTicks,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    final client =
        _clientFactory.getClientIfExists(item.serverId) ?? GetIt.instance<MediaServerClient>();
    final streamUrl = await _streamUrlForItem(
      client,
      item,
      mediaSourceId: mediaSourceId,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
    );
    final effectiveQueueItems =
        (queueItems == null || queueItems.isEmpty)
            ? <AggregatedItem>[item]
            : queueItems;
    final queuePayload = <Map<String, dynamic>>[];
    for (final entry in effectiveQueueItems) {
      final entryStreamUrl =
          entry.id == item.id ? streamUrl : await _streamUrlForItem(client, entry);
      queuePayload.add(
        <String, dynamic>{
          'streamUrl': entryStreamUrl,
          'title': entry.name,
          if (entry.overview?.isNotEmpty == true) 'subtitle': entry.overview,
        },
      );
    }

    await _native.startGoogleCastSession(
      targetId: target.id,
      streamUrl: streamUrl,
      title: item.name,
      subtitle: item.overview,
      queueItems: queuePayload.length > 1 ? queuePayload : null,
      startPositionTicks: startPositionTicks,
    );
  }

  @override
  Future<void> pause(CastTargetKind kind) async {
    if (kind != CastTargetKind.googleCast) {
      throw UnsupportedError('Unsupported cast kind for GoogleCastProvider.');
    }
    await _native.pauseGoogleCast();
  }

  @override
  Future<void> play(CastTargetKind kind) async {
    if (kind != CastTargetKind.googleCast) {
      throw UnsupportedError('Unsupported cast kind for GoogleCastProvider.');
    }
    await _native.playGoogleCast();
  }

  @override
  Future<void> seek(CastTargetKind kind, {required int positionTicks}) async {
    if (kind != CastTargetKind.googleCast) {
      throw UnsupportedError('Unsupported cast kind for GoogleCastProvider.');
    }
    await _native.seekGoogleCast(positionTicks: positionTicks);
  }

  @override
  Future<void> stop(CastTargetKind kind) async {
    if (kind != CastTargetKind.googleCast) {
      throw UnsupportedError('Unsupported cast kind for GoogleCastProvider.');
    }
    await _native.stopGoogleCastSession();
  }

  @override
  Future<double?> getVolume(CastTargetKind kind) async {
    if (kind != CastTargetKind.googleCast) {
      throw UnsupportedError('Unsupported cast kind for GoogleCastProvider.');
    }
    return _native.getGoogleCastVolume();
  }

  @override
  Future<void> setVolume(CastTargetKind kind, {required double volume}) async {
    if (kind != CastTargetKind.googleCast) {
      throw UnsupportedError('Unsupported cast kind for GoogleCastProvider.');
    }
    await _native.setGoogleCastVolume(volume: volume);
  }
}
