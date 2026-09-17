import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One notification, as the viewer sees it in the inbox.
///
/// This is deliberately a copy of what arrived rather than a reference to it.
/// A push is a one-shot delivery: FCM does not keep it, the admin panel does
/// not keep it, and the Moonfin plugin does not keep it. If the app does not
/// write down what it was told, a notification the viewer swiped away or
/// missed while the TV was off is gone for good — which is the whole reason
/// this inbox exists.
class InboxNotification {
  /// Stable across restarts, so read/unread survives and a message redelivered
  /// by FCM does not appear twice.
  final String id;
  final String title;
  final String body;
  final String? imageUrl;

  /// An in-app route (`/item/123`, `/live-tv/iptv?channelName=…`) to open when
  /// the viewer taps through. Null for an informational message.
  final String? route;

  final DateTime receivedAt;
  final bool read;

  const InboxNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.receivedAt,
    this.imageUrl,
    this.route,
    this.read = false,
  });

  InboxNotification copyWith({bool? read}) => InboxNotification(
        id: id,
        title: title,
        body: body,
        imageUrl: imageUrl,
        route: route,
        receivedAt: receivedAt,
        read: read ?? this.read,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (route != null) 'route': route,
        'receivedAt': receivedAt.toIso8601String(),
        'read': read,
      };

  static InboxNotification? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final receivedAt = DateTime.tryParse('${json['receivedAt']}');
    if (id == null || id.isEmpty || receivedAt == null) return null;
    return InboxNotification(
      id: id,
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      imageUrl: _nonEmpty(json['imageUrl']),
      route: _nonEmpty(json['route']),
      receivedAt: receivedAt,
      read: json['read'] == true,
    );
  }

  static String? _nonEmpty(Object? value) {
    final s = value?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}

/// Every push this device has received, newest first.
///
/// ─── Why SharedPreferences and not a database ────────────────────────────
///
/// The cap below keeps this to a few dozen kilobytes of JSON, which is well
/// inside what SharedPreferences handles comfortably, and it is the one store
/// already reachable from the FCM *background* isolate without any setup. That
/// matters more than it sounds: a push that arrives while the app is closed is
/// handled in a separate isolate with none of the app's dependency injection
/// available, and if the inbox could not be written from there, every
/// notification the viewer did not happen to be watching for would be missing
/// from it.
///
/// Because that background isolate has its own memory, the in-memory list here
/// can be stale after the app is resumed. [refresh] re-reads from disk, and the
/// notifications screen calls it when it opens.
class NotificationInbox extends ChangeNotifier {
  NotificationInbox._();

  static final NotificationInbox instance = NotificationInbox._();

  static const _storageKey = 'voltix_notification_inbox_v1';

  /// Old notifications are dropped rather than kept forever. Two hundred is
  /// far more than anyone scrolls and small enough to read and write in one go.
  static const _maxItems = 200;

  List<InboxNotification> _items = const [];
  bool _loaded = false;

  /// Newest first.
  List<InboxNotification> get items => List.unmodifiable(_items);

  int get unreadCount => _items.where((n) => !n.read).length;

  bool get isLoaded => _loaded;

  /// Reads the stored list. Safe to call repeatedly.
  Future<void> refresh() async {
    _items = await _read();
    _loaded = true;
    notifyListeners();
  }

  Future<void> loadIfNeeded() async {
    if (_loaded) return;
    await refresh();
  }

  /// Records an arriving notification.
  ///
  /// Static, and reads-then-writes storage on every call, because this is also
  /// invoked from the FCM background isolate where [instance] is a different
  /// object than the one the UI is holding. Writing through storage is what
  /// keeps the two in step.
  static Future<void> record({
    required String id,
    required String title,
    required String body,
    String? imageUrl,
    String? route,
    DateTime? receivedAt,
  }) async {
    if (title.trim().isEmpty && body.trim().isEmpty) return;

    final existing = await _read();
    // FCM can deliver the same message twice (a retry, or onMessage followed by
    // onMessageOpenedApp for one notification). Matching on id keeps one entry,
    // and keeps its read state.
    if (existing.any((n) => n.id == id)) return;

    final updated = <InboxNotification>[
      InboxNotification(
        id: id,
        title: title.trim(),
        body: body.trim(),
        imageUrl: InboxNotification._nonEmpty(imageUrl),
        route: InboxNotification._nonEmpty(route),
        receivedAt: receivedAt ?? DateTime.now(),
      ),
      ...existing,
    ];
    await _write(updated);

    // Only meaningful in the UI isolate; harmless in the background one.
    instance._items = updated.take(_maxItems).toList(growable: false);
    instance._loaded = true;
    instance.notifyListeners();
  }

  Future<void> markRead(String id) async {
    await _mutate((list) => [
          for (final n in list) n.id == id ? n.copyWith(read: true) : n,
        ]);
  }

  Future<void> markAllRead() async {
    await _mutate((list) => [for (final n in list) n.copyWith(read: true)]);
  }

  Future<void> delete(String id) async {
    await _mutate((list) => [for (final n in list) if (n.id != id) n]);
  }

  Future<void> deleteAll() async {
    await _mutate((_) => const []);
  }

  /// Re-reads before applying, so an edit made here does not silently discard a
  /// notification the background isolate wrote in the meantime.
  Future<void> _mutate(
    List<InboxNotification> Function(List<InboxNotification>) change,
  ) async {
    final current = await _read();
    final updated = change(current);
    await _write(updated);
    _items = updated.take(_maxItems).toList(growable: false);
    _loaded = true;
    notifyListeners();
  }

  static Future<List<InboxNotification>> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The background isolate may have written since this instance last
      // loaded, and SharedPreferences caches its values per isolate.
      await prefs.reload();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final parsed = decoded
          .whereType<Map>()
          .map((m) => InboxNotification.fromJson(Map<String, dynamic>.from(m)))
          .whereType<InboxNotification>()
          .toList();
      parsed.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      return parsed;
    } catch (e) {
      debugPrint('NotificationInbox: could not read stored notifications: $e');
      return const [];
    }
  }

  static Future<void> _write(List<InboxNotification> items) async {
    try {
      final capped = items.take(_maxItems).toList(growable: false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode([for (final n in capped) n.toJson()]),
      );
    } catch (e) {
      debugPrint('NotificationInbox: could not save notifications: $e');
    }
  }
}
