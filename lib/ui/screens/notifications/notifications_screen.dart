import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../data/services/notification_inbox.dart';
import '../../navigation/destinations.dart';

/// Everything this device has been sent, and what to do about it.
///
/// ─── Why an inbox at all ─────────────────────────────────────────────────
///
/// A push notification is a one-shot delivery. FCM does not keep it, the admin
/// Notification Centre does not keep a per-device copy, and on a television
/// there is no notification shade to fall back on — the banner shows for a few
/// seconds and that is the only chance anyone gets to read it. So an
/// announcement about a new film, or a reminder that a match is starting, was
/// simply lost if the viewer was out of the room. This screen is the record.
///
/// Read state, deletion and the deep link all operate on the stored copy, so
/// nothing here depends on the notification still existing anywhere else.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _inbox = NotificationInbox.instance;

  @override
  void initState() {
    super.initState();
    // Re-read rather than trusting what is in memory: pushes that arrived while
    // the app was closed were written by a different isolate.
    _inbox.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColorScheme.background,
      appBar: AppBar(
        title: const Text('Notifications'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.popOrHome(),
        ),
        actions: [
          AnimatedBuilder(
            animation: _inbox,
            builder: (context, _) {
              final items = _inbox.items;
              final hasUnread = _inbox.unreadCount > 0;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Mark all as read',
                    icon: const Icon(Icons.done_all_rounded),
                    onPressed: hasUnread ? _inbox.markAllRead : null,
                  ),
                  IconButton(
                    tooltip: 'Delete all',
                    icon: const Icon(Icons.delete_sweep_rounded),
                    onPressed: items.isEmpty ? null : _confirmDeleteAll,
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _inbox,
        builder: (context, _) {
          final items = _inbox.items;
          if (!_inbox.isLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) return const _EmptyInbox();

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final n = items[index];
              return _NotificationTile(
                notification: n,
                onTap: () => _open(n),
                onDelete: () => _inbox.delete(n.id),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _open(InboxNotification n) async {
    // Opening is what marks it read — not merely having it on screen, which
    // would clear the badge for messages the viewer only scrolled past.
    if (!n.read) await _inbox.markRead(n.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NotificationDetailSheet(
        notification: n,
        onDelete: () async {
          await _inbox.delete(n.id);
        },
      ),
    );
  }

  Future<void> _confirmDeleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete all notifications?'),
        content: const Text(
          'This clears the list on this device. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _inbox.deleteAll();
  }
}

// ── List tile ───────────────────────────────────────────────────────────────

class _NotificationTile extends StatelessWidget {
  final InboxNotification notification;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _NotificationTile({
    required this.notification,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final unread = !notification.read;
    final image = notification.imageUrl;

    return Dismissible(
      key: ValueKey(notification.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          // A literal rather than a scheme colour: the design package's
          // palette does not guarantee an `error` slot, and this is the one
          // place in the screen that needs a destructive red.
          color: const Color(0xFFEF4444).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_rounded, color: Color(0xFFEF4444)),
      ),
      child: Material(
        color: unread
            ? AppColorScheme.accent.withValues(alpha: 0.08)
            : AppColorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: unread
                    ? AppColorScheme.accent.withValues(alpha: 0.35)
                    : AppColorScheme.onSurface.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (image != null && image.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      image,
                      width: 84,
                      height: 47, // 16:9
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (unread) ...[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: AppColorScheme.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              notification.title.isEmpty
                                  ? 'Notification'
                                  : notification.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight:
                                    unread ? FontWeight.w700 : FontWeight.w600,
                                color: AppColorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (notification.body.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          notification.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color:
                                AppColorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        _relativeTime(notification.receivedAt),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                if (notification.route != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: AppColorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Detail sheet ────────────────────────────────────────────────────────────

class _NotificationDetailSheet extends StatelessWidget {
  final InboxNotification notification;
  final Future<void> Function() onDelete;

  const _NotificationDetailSheet({
    required this.notification,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final image = notification.imageUrl;
    final route = notification.route;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColorScheme.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColorScheme.onSurface.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (image != null && image.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    image,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              notification.title.isEmpty ? 'Notification' : notification.title,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: AppColorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              DateFormat('EEEE d MMMM, HH:mm').format(notification.receivedAt),
              style: TextStyle(
                fontSize: 12,
                color: AppColorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            if (notification.body.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                notification.body,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.5,
                  color: AppColorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ],
            const SizedBox(height: 24),
            if (route != null && route.trim().isNotEmpty)
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  // go rather than push: the notification's destination is a
                  // place in the app, not a step on top of the inbox.
                  GoRouter.of(context).go(route.trim());
                },
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open'),
              ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final navigator = Navigator.of(context);
                await onDelete();
                navigator.pop();
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ─────────────────────────────────────────────────────────────

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.notifications_none_rounded,
                size: 52,
                color: AppColorScheme.onSurface.withValues(alpha: 0.25),
              ),
              const SizedBox(height: 14),
              Text(
                'No notifications yet',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Announcements, request updates and programme reminders will '
                'appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: AppColorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      );
}

String _relativeTime(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) {
    return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
  }
  if (diff.inDays < 7) {
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }
  return DateFormat('d MMM yyyy').format(when);
}
