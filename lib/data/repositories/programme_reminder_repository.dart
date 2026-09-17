import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../../auth/store/voltix_session_store.dart';
import '../services/voltix_api_service.dart';

/// A reminder the viewer has set, as the server holds it.
class ProgrammeReminder {
  final int id;
  final String? channelNumber;
  final String channelName;
  final String programmeTitle;
  final String? imageUrl;
  final DateTime startsAt;
  final DateTime notifyAt;

  const ProgrammeReminder({
    required this.id,
    required this.channelName,
    required this.programmeTitle,
    required this.startsAt,
    required this.notifyAt,
    this.channelNumber,
    this.imageUrl,
  });

  static ProgrammeReminder? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as num?)?.toInt();
    final startsAt = DateTime.tryParse('${json['startsAt']}');
    final notifyAt = DateTime.tryParse('${json['notifyAt']}');
    if (id == null || startsAt == null || notifyAt == null) return null;
    return ProgrammeReminder(
      id: id,
      channelNumber: json['channelNumber']?.toString(),
      channelName: json['channelName']?.toString() ?? '',
      programmeTitle: json['programmeTitle']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString(),
      startsAt: startsAt,
      notifyAt: notifyAt,
    );
  }
}

/// Programme reminders, and resolving a DStv guide channel to a playable stream.
///
/// The two belong together because the TV Guide modal needs both: Play needs the
/// stream id, Remind me needs the reminder, and both are keyed off the same DStv
/// channel the viewer just tapped.
class ProgrammeReminderRepository {
  final VoltixApiService _api;
  final VoltixSessionStore _store;

  ProgrammeReminderRepository({VoltixApiService? api, VoltixSessionStore? store})
      : _api = api ?? GetIt.instance<VoltixApiService>(),
        _store = store ?? GetIt.instance<VoltixSessionStore>();

  String get _token => _store.sessionToken ?? '';

  bool get hasSession => _token.isNotEmpty;

  /// A DStv guide channel matched to the viewer's actual line-up.
  ///
  /// [channelName] is the PROVIDER's name for it, which is what the Live TV
  /// list is searchable by — not the DStv name the guide shows.
  ///
  /// Resolved channels already looked up this session.
  ///
  /// The modal asks for this every time a channel is opened, and a line-up does
  /// not change while someone is browsing the guide. Without it, scrolling the
  /// guide and opening five channels is five round trips for answers that were
  /// already known.
  static final Map<String, ResolvedChannel?> _resolveCache = {};

  /// Finds the IPTV stream for a DStv channel, or null when the viewer's
  /// line-up does not carry it.
  ///
  /// Null is an ordinary answer, not a failure: plenty of channels in the
  /// published DStv guide are not in any given package, and the modal says so
  /// rather than offering a Play button that cannot work.
  Future<ResolvedChannel?> resolveChannel({
    required String channelName,
    String? channelNumber,
  }) async {
    final key = channelNumber?.isNotEmpty == true
        ? 'n:$channelNumber'
        : 'name:${channelName.toLowerCase()}';
    if (_resolveCache.containsKey(key)) return _resolveCache[key];

    try {
      final data = await _api.restGet(
        '/api/iptv/dstv/resolve',
        query: {
          if (channelNumber != null && channelNumber.isNotEmpty)
            'number': channelNumber,
          'name': channelName,
        },
        sessionToken: _token,
        timeout: const Duration(seconds: 12),
      );
      final map = data is Map ? data : const {};
      final streamId = map['streamId']?.toString();
      if (streamId == null || streamId.isEmpty) {
        _resolveCache[key] = null;
        return null;
      }
      final resolved = ResolvedChannel(
        streamId: streamId,
        channelName: map['channelName']?.toString() ?? channelName,
      );
      _resolveCache[key] = resolved;
      return resolved;
    } on DioException catch (e) {
      // Only a 404 means "not in your line-up". Everything else — an expired
      // session, the route missing after a bad deploy, the provider's live
      // channel list coming back empty so nothing can possibly match, a
      // timeout — is a failure to *check*, and collapsing all of it into null
      // made the modal say "Not in your package" with total confidence about a
      // question it had never got an answer to. That hid a real upstream
      // outage behind a plausible message. A failure now surfaces as an
      // exception and is NOT cached, so reopening the channel tries again once
      // the cause is fixed.
      if (e.response?.statusCode == 404) {
        _resolveCache[key] = null;
        return null;
      }
      throw LineupCheckException(
        statusCode: e.response?.statusCode,
        detail: e.message ?? e.type.name,
      );
    } catch (e) {
      throw LineupCheckException(detail: e.toString());
    }
  }

  /// Asks the server to push a notification shortly before [startsAt].
  ///
  /// The programme's details travel with the request rather than an id, because
  /// the server stores them verbatim — the EPG will have moved on by the time
  /// the reminder fires.
  Future<ReminderResult> setReminder({
    required String channelName,
    String? channelNumber,
    /// The provider's name for the channel, from [resolveChannel]. This is what
    /// lets the notification tune the right channel when it is tapped.
    String? providerChannelName,
    String? streamId,
    String? actionUrl,
    required String programmeTitle,
    String? description,
    String? imageUrl,
    required DateTime startsAt,
    DateTime? endsAt,
  }) async {
    try {
      final deepLink = actionUrl ??
          (streamId != null && streamId.isNotEmpty
              ? '/live-tv/iptv?streamId=${Uri.encodeQueryComponent(streamId)}${providerChannelName != null && providerChannelName.isNotEmpty ? '&channelName=${Uri.encodeQueryComponent(providerChannelName)}' : ''}'
              : null);

      final data = await _api.restPost(
        '/api/iptv/reminders',
        sessionToken: _token,
        body: {
          'channelName': channelName,
          if (channelNumber != null && channelNumber.isNotEmpty)
            'channelNumber': channelNumber,
          if (providerChannelName != null && providerChannelName.isNotEmpty)
            'providerChannelName': providerChannelName,
          if (streamId != null && streamId.isNotEmpty) 'streamId': streamId,
          if (deepLink != null && deepLink.isNotEmpty) ...{
            'actionUrl': deepLink,
            'route': deepLink,
          },
          'programmeTitle': programmeTitle,
          if (description != null && description.isNotEmpty)
            'programmeDescription': description,
          if (imageUrl != null && imageUrl.isNotEmpty) 'imageUrl': imageUrl,
          // Sent as UTC. The guide's times are SAST wall-clock with no zone, so
          // converting here is the only place that knows which is which.
          'startsAt': startsAt.toUtc().toIso8601String(),
          if (endsAt != null) 'endsAt': endsAt.toUtc().toIso8601String(),
        },
      );
      final map = data is Map ? data : const {};
      return ReminderResult(
        ok: map['success'] == true,
        alreadySet: map['alreadySet'] == true,
        notifyAt: DateTime.tryParse('${map['notifyAt']}'),
      );
    } catch (e) {
      return ReminderResult(ok: false, error: e);
    }
  }

  Future<List<ProgrammeReminder>> listReminders() async {
    try {
      final data = await _api.restGet(
        '/api/iptv/reminders',
        sessionToken: _token,
        timeout: const Duration(seconds: 12),
      );
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      return items
          .whereType<Map<String, dynamic>>()
          .map(ProgrammeReminder.fromJson)
          .whereType<ProgrammeReminder>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<bool> cancelReminder(int id) async {
    try {
      await _api.restDelete('/api/iptv/reminders/$id', sessionToken: _token);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// A DStv channel matched to a stream in the viewer's own line-up.
class ResolvedChannel {
  final String streamId;

  /// The PROVIDER's name for the channel, which is what the Live TV list can be
  /// searched by — not the DStv name the guide displays.
  final String channelName;

  const ResolvedChannel({required this.streamId, required this.channelName});
}

/// The line-up could not be checked — as distinct from "checked, and the
/// channel is not in it", which is a plain null from [resolveChannel].
class LineupCheckException implements Exception {
  final int? statusCode;
  final String detail;

  const LineupCheckException({this.statusCode, required this.detail});

  @override
  String toString() =>
      'LineupCheckException(${statusCode ?? 'no status'}): $detail';
}

class ReminderResult {
  final bool ok;
  final bool alreadySet;
  final DateTime? notifyAt;
  final Object? error;

  const ReminderResult({
    required this.ok,
    this.alreadySet = false,
    this.notifyAt,
    this.error,
  });
}
