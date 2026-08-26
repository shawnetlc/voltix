import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:server_core/server_core.dart';

import '../../../navigation/destinations.dart';
import '../providers/admin_user_providers.dart';
import 'admin_user_delete_dialog.dart';
import '../../../../l10n/app_localizations.dart';

class AdminUsersScreen extends ConsumerStatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  ConsumerState<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends ConsumerState<AdminUsersScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  Future<void> _toggleUserDisabled(ServerUser user) async {
    final l10n = AppLocalizations.of(context);
    final currentPolicy = user.policy ?? const UserPolicy();
    final willDisable = !currentPolicy.isDisabled;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(willDisable ? l10n.adminDisableUser : l10n.adminEnableUser),
        content: Text(
          willDisable
              ? l10n.adminDisableUserConfirm(user.name ?? '')
              : l10n.adminEnableUserConfirm(user.name ?? ''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(willDisable ? l10n.disable : l10n.enable),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    try {
      final updatedPolicy = currentPolicy.toJson()
        ..['IsDisabled'] = willDisable;
      await GetIt.instance<MediaServerClient>()
          .adminUsersApi
          .updateUserPolicy(user.id, updatedPolicy);

      ref.invalidate(adminUsersListProvider);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            willDisable
                ? l10n.adminUserDisabled(user.name ?? '')
                : l10n.adminUserEnabled(user.name ?? ''),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.adminUserPolicyUpdateFailed(e.toString()))),
      );
    }
  }

  Future<void> _exportUsers(List<ServerUser> users) async {
    final client = GetIt.instance<MediaServerClient>();
    final serverName = client.baseUrl;

    final userList = users.map((u) {
      final p = u.policy;
      return {
        'id': u.id,
        'name': u.name ?? '',
        'isAdmin': p?.isAdministrator ?? false,
        'isDisabled': p?.isDisabled ?? false,
        'enableRemoteAccess': p?.enableRemoteAccess ?? false,
        'enableContentDownloading': p?.enableContentDownloading ?? false,
        'enableLiveTvAccess': p?.enableLiveTvAccess ?? false,
        'hasPassword': u.hasPassword,
        'server': serverName,
      };
    }).toList();

    final jsonString = const JsonEncoder.withIndent('  ').convert(userList);

    final csvBuffer = StringBuffer();
    csvBuffer.writeln('ID,Username,IsAdmin,IsDisabled,RemoteAccess,DownloadAccess,LiveTvAccess,HasPassword,Server');
    for (final u in userList) {
      csvBuffer.writeln(
        '"${u['id']}","${u['name']}",${u['isAdmin']},${u['isDisabled']},${u['enableRemoteAccess']},${u['enableContentDownloading']},${u['enableLiveTvAccess']},${u['hasPassword']},"${u['server']}"',
      );
    }
    final csvString = csvBuffer.toString();

    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.file_download_outlined),
            SizedBox(width: 8),
            Text('Export Users List'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Export ${users.length} users from server ($serverName).\n\nThis export is generated 100% locally on your device and produces zero logs on the server.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy JSON'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: jsonString));
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                    }
                    messenger.showSnackBar(
                      const SnackBar(content: Text('✓ User details copied to clipboard (JSON format)')),
                    );
                  },
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.table_chart_outlined, size: 18),
                  label: const Text('Copy CSV'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: csvString));
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                    }
                    messenger.showSnackBar(
                      const SnackBar(content: Text('✓ User details copied to clipboard (CSV format)')),
                    );
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Save JSON File'),
                  onPressed: () async {
                    try {
                      final fileName = 'users_export_${DateTime.now().millisecondsSinceEpoch}.json';
                      final path = await FilePicker.saveFile(
                        dialogTitle: 'Save Users Export JSON',
                        fileName: fileName,
                      );
                      if (path != null) {
                        await File(path).writeAsString(jsonString);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                        }
                        messenger.showSnackBar(
                          SnackBar(content: Text('✓ Saved users export to $path')),
                        );
                      }
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Could not save file: $e')),
                      );
                    }
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final usersAsync = ref.watch(adminUsersListProvider);
    final client = GetIt.instance<MediaServerClient>();

    return usersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) {
        final errStr = e.toString();
        final isForbidden = errStr.contains('403');
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isForbidden ? Icons.lock_outline_rounded : Icons.error_outline_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  isForbidden ? '403 Forbidden on Server' : l10n.adminUsersLoadFailed,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  isForbidden
                      ? 'The server (${client.baseUrl}) rejected the /Users request. This server node may restrict user management or act as a shared media node.'
                      : errStr,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => ref.invalidate(adminUsersListProvider),
                  child: Text(l10n.retry),
                ),
              ],
            ),
          ),
        );
      },
      data: (users) {
        final theme = Theme.of(context);
        final bottomSafe = MediaQuery.of(context).padding.bottom;
        final listBottomPadding = bottomSafe + 108;
        final fabBottom = bottomSafe + 16;
        final filtered = users.where((user) {
          if (_searchQuery.isEmpty) {
            return true;
          }
          final query = _searchQuery.toLowerCase();
          return (user.name ?? '').toLowerCase().contains(query);
        }).toList();

        return Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.dns_outlined, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            client.baseUrl.isNotEmpty ? client.baseUrl : 'Active Server',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: 'Refresh Users',
                      child: IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: () => ref.invalidate(adminUsersListProvider),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Export Users List (Untraceable)',
                      child: IconButton.filledTonal(
                        icon: const Icon(Icons.file_download_outlined),
                        onPressed: () => _exportUsers(users),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _searchQuery = value.trim()),
                  decoration: InputDecoration(
                    hintText: l10n.adminSearchUsers,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            icon: const Icon(Icons.clear),
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
            ? Center(
                child: Text(
                  users.isEmpty
                      ? l10n.adminNoUsersFound
                      : l10n.adminNoUsersMatchSearch,
                ),
              )
            : ListView.builder(
              padding: EdgeInsets.fromLTRB(8, 8, 8, listBottomPadding),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final user = filtered[index];
                  final policy = user.policy;
                  final isAdmin = policy?.isAdministrator ?? false;
                  final isDisabled = policy?.isDisabled ?? false;
                  final hasRemoteAccess = policy?.enableRemoteAccess ?? false;
                  final isHidden = policy?.isHidden ?? false;
                    final displayName = (user.name ?? l10n.unknown).trim();
                  final initials = displayName.isEmpty
                      ? '?'
                      : displayName.characters.first.toUpperCase();

                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => context.push(Destinations.adminUser(user.id)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 21,
                                  backgroundImage: user.primaryImageTag != null
                                      ? NetworkImage(client.imageApi.getUserImageUrl(user.id))
                                      : null,
                                  child: user.primaryImageTag == null
                                      ? Text(
                                          initials,
                                          style: const TextStyle(fontWeight: FontWeight.bold),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        displayName,
                                        style: theme.textTheme.titleMedium?.copyWith(
                                          decoration: isDisabled
                                              ? TextDecoration.lineThrough
                                              : null,
                                          color: isDisabled
                                              ? theme.disabledColor
                                              : null,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        user.hasPassword
                                            ? l10n.passwordSet
                                            : l10n.noPasswordConfigured,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.adminEditUser,
                                  onPressed: () => context.push(Destinations.adminUser(user.id)),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                if (isAdmin) _statusChip(context, l10n.admin, Icons.shield),
                                if (isDisabled)
                                  _statusChip(
                                    context,
                                    l10n.disabled,
                                    Icons.block,
                                    tint: theme.colorScheme.error,
                                  ),
                                _statusChip(
                                  context,
                                  hasRemoteAccess
                                      ? l10n.remoteAccess
                                      : l10n.localOnly,
                                  hasRemoteAccess ? Icons.cloud_done : Icons.cloud_off,
                                ),
                                if (isHidden)
                                  _statusChip(
                                    context,
                                    l10n.hidden,
                                    Icons.visibility_off,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => context.push(Destinations.adminUser(user.id)),
                                  icon: const Icon(Icons.manage_accounts_outlined, size: 18),
                                  label: Text(l10n.manage),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _toggleUserDisabled(user),
                                  icon: Icon(
                                    isDisabled
                                        ? Icons.check_circle_outline
                                        : Icons.block,
                                    size: 18,
                                  ),
                                  label: Text(isDisabled ? l10n.enable : l10n.disable),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: theme.colorScheme.error,
                                  ),
                                  onPressed: () => showAdminUserDeleteDialog(
                                    context,
                                    user: user,
                                    onDeleted: () =>
                                        ref.invalidate(adminUsersListProvider),
                                  ),
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  label: Text(l10n.delete),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: fabBottom,
            child: FloatingActionButton.extended(
              onPressed: () => context.push(Destinations.adminUsersAdd),
              icon: const Icon(Icons.person_add),
              label: Text(l10n.adminAddUser),
            ),
          ),
        ],
      );
      },
    );
  }

  Widget _statusChip(
    BuildContext context,
    String label,
    IconData icon, {
    Color? tint,
  }) {
    final theme = Theme.of(context);
    final base = tint ?? theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: base.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: base),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: base,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
