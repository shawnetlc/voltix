import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../data/services/app_update_service.dart';
import '../../l10n/app_localizations.dart';
import '../../util/app_distribution.dart';
import '../../util/platform_detection.dart';

const _installChannel = MethodChannel('com.voltix.app/update');
final _kAccent = AppColorScheme.accent;

/// Checks for an update and shows the dialog or an appropriate snackbar.
/// Returns true if an update was found and the dialog was shown.
Future<void> checkAndShowUpdateResult(BuildContext context) async {
  final result =
      await GetIt.instance<AppUpdateService>().checkForUpdateNowDetailed();
  if (!context.mounted) return;

  final update = result.update;
  if (update != null) {
    await showAppUpdateDialog(context, update);
    return;
  }

  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final message = switch (result.status) {
    DesktopUpdateCheckStatus.upToDate => l10n.youAreUpToDate,
    DesktopUpdateCheckStatus.checkFailed => l10n.couldNotCheckForUpdates,
    DesktopUpdateCheckStatus.noMatchingAsset => l10n.noCompatibleUpdate,
    DesktopUpdateCheckStatus.unsupportedPlatform => l10n.updateChecksNotSupported,
    DesktopUpdateCheckStatus.disabledByPreference => l10n.updateNotificationsDisabled,
    DesktopUpdateCheckStatus.rateLimited => l10n.pleaseWaitBeforeChecking,
    DesktopUpdateCheckStatus.alreadyNotified => l10n.latestUpdateAlreadyShown,
    DesktopUpdateCheckStatus.updateAvailable => l10n.updateAvailable,
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
  );
}

Future<void> showAppUpdateDialog(
  BuildContext context,
  DesktopUpdateInfo update, {
  bool forcedByServer = false,
}) async {
  final isForced = update.forceUpdate || forcedByServer;
  
  bool showStoreListing = false;
  bool showApkDownload = false;

  if (PlatformDetection.isAndroid) {
    // A store-managed build never offers an APK download, whatever the
    // installer reports — the store owns updates for those installs.
    if (AppDistribution.isManagedStoreBuild) {
      showStoreListing = true;
    } else {
      String installer = '';
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        installer = packageInfo.installerStore?.toLowerCase().trim() ?? '';
      } catch (_) {
        // Leave installer empty and fall through to the build-channel decision.
      }

      if (installer == 'com.android.vending') {
        showStoreListing = true;
      } else if (installer.isEmpty) {
        // `installerStore` needs API 30+ and is commonly null on TV boxes and
        // older devices. Treating "unknown" as sideloaded is what offered an
        // APK download to users who had installed from Play, so defer to the
        // build channel instead of assuming.
        showStoreListing = !AppDistribution.allowsApkSelfUpdate;
        showApkDownload = AppDistribution.allowsApkSelfUpdate;
      } else {
        // A known non-Play installer (adb, a file manager, another store).
        showApkDownload = AppDistribution.allowsApkSelfUpdate;
      }
    }
  } else {
    showStoreListing = false;
    showApkDownload = false;
  }

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: !isForced,
    builder: (dialogContext) => _ForceUpdateModal(
      update: update,
      isForced: isForced,
      showApkDownload: showApkDownload,
      showStoreListing: showStoreListing,
    ),
  );
}

class _ForceUpdateModal extends StatefulWidget {
  final DesktopUpdateInfo update;
  final bool isForced;
  final bool showApkDownload;
  final bool showStoreListing;

  const _ForceUpdateModal({
    required this.update,
    required this.isForced,
    required this.showApkDownload,
    required this.showStoreListing,
  });

  @override
  State<_ForceUpdateModal> createState() => _ForceUpdateModalState();
}

class _ForceUpdateModalState extends State<_ForceUpdateModal> {
  final _storeFocus = FocusNode(debugLabel: 'UpdateStoreListing');
  final _apkDownloadFocus = FocusNode(debugLabel: 'UpdateApkDownload');
  final _laterFocus = FocusNode(debugLabel: 'UpdateLater');
  // Release notes need their own focus + controller: on TV the notes panel was
  // unreachable, so D-pad Up/Down only cycled the buttons and long notes could
  // never be scrolled.
  final _notesFocus = FocusNode(debugLabel: 'UpdateReleaseNotes');
  final _notesScrollController = ScrollController();

  /// Scrolls the release notes by [delta] logical pixels, clamped to range.
  void _scrollNotes(double delta) {
    if (!_notesScrollController.hasClients) return;
    final position = _notesScrollController.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _notesScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  /// Focuses the release-notes panel if it's present, so Up from the topmost
  /// button reaches the notes instead of dead-ending.
  bool _focusNotesIfPresent() {
    if (!_notesFocus.canRequestFocus) return false;
    _notesFocus.requestFocus();
    return true;
  }

  KeyEventResult _handleNotesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      // At the bottom, hand focus on to the action buttons.
      if (_notesScrollController.hasClients &&
          _notesScrollController.position.pixels >=
              _notesScrollController.position.maxScrollExtent - 1) {
        return KeyEventResult.ignored;
      }
      _scrollNotes(120);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_notesScrollController.hasClients &&
          _notesScrollController.position.pixels <=
              _notesScrollController.position.minScrollExtent + 1) {
        return KeyEventResult.ignored;
      }
      _scrollNotes(-120);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _scrollNotes(320);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _scrollNotes(-320);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
  bool _isDownloading = false;
  double _downloadProgress = -1;

  @override
  void initState() {
    super.initState();
    _setupDpadNavigation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // Focus on the first available action button
        if (widget.showStoreListing) {
          _storeFocus.requestFocus();
        } else if (widget.showApkDownload) {
          _apkDownloadFocus.requestFocus();
        } else if (!widget.isForced) {
          _laterFocus.requestFocus();
        }
      }
    });
  }

  void _setupDpadNavigation() {
    _storeFocus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (widget.showApkDownload) {
          _apkDownloadFocus.requestFocus();
        } else if (!widget.isForced) {
          _laterFocus.requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        // Topmost button — go up into the release notes so they can scroll.
        if (_focusNotesIfPresent()) return KeyEventResult.handled;
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    _apkDownloadFocus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (widget.showStoreListing) {
          _storeFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (_focusNotesIfPresent()) return KeyEventResult.handled;
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown && !widget.isForced) {
        _laterFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    _laterFocus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (widget.showApkDownload) {
          _apkDownloadFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (widget.showStoreListing) {
          _storeFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (_focusNotesIfPresent()) return KeyEventResult.handled;
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _storeFocus.dispose();
    _apkDownloadFocus.dispose();
    _laterFocus.dispose();
    _notesFocus.dispose();
    _notesScrollController.dispose();
    super.dispose();
  }

  /// AppGallery listing id, e.g. C123456789.
  ///
  /// Supplied at build time because it only exists once the app has been created
  /// in AppGallery Connect. Without it the https fallback cannot address the
  /// listing, so only the appmarket:// scheme is attempted - which is fine on a
  /// Huawei device, since AppGallery is guaranteed to be installed there.
  static const String _appGalleryAppId =
      String.fromEnvironment('APPGALLERY_APP_ID');

  /// Opens this app's listing in whichever store owns updates for this build.
  void _openStoreListing() async {
    String pkgName = 'cc.voltix.streaming';
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.packageName.trim().isNotEmpty) {
        pkgName = info.packageName.trim();
      }
    } catch (_) {}

    final String schemeUrl;
    final String? fallbackUrl;
    if (AppDistribution.isAppGalleryBuild) {
      schemeUrl = 'appmarket://details?id=$pkgName';
      fallbackUrl = _appGalleryAppId.trim().isEmpty
          ? null
          : 'https://appgallery.huawei.com/app/$_appGalleryAppId';
    } else {
      schemeUrl = 'market://details?id=$pkgName';
      fallbackUrl = 'https://play.google.com/store/apps/details?id=$pkgName';
    }

    try {
      final launched = await launchUrl(
        Uri.parse(schemeUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && fallbackUrl != null) {
        await launchUrl(Uri.parse(fallbackUrl), mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (fallbackUrl != null) {
        await launchUrl(Uri.parse(fallbackUrl), mode: LaunchMode.externalApplication)
            .catchError((_) => false);
      }
    }
  }

  Future<void> _downloadApk() async {
    // Belt-and-braces: the button is already hidden on store-managed builds,
    // but a self-install must never be reachable there under any code path.
    if (!AppDistribution.allowsApkSelfUpdate) {
      _openStoreListing();
      return;
    }
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
    });

    final downloadStream = GetIt.instance<AppUpdateService>().downloadUpdate(widget.update);
    String? errorMessage;
    String? donePath;

    await for (final event in downloadStream) {
      if (event is DownloadProgressEvent) {
        if (mounted) setState(() => _downloadProgress = event.fraction);
      } else if (event is DownloadDoneEvent) {
        donePath = event.filePath;
        break;
      } else if (event is DownloadFailedEvent) {
        errorMessage = event.error;
        break;
      }
    }

    if (!mounted) return;

    if (errorMessage != null) {
      setState(() {
        _isDownloading = false;
        _downloadProgress = -1;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Download failed. Please try again.'), duration: Duration(seconds: 4)),
      );
      return;
    }

    if (donePath != null) {
      if (AppDistribution.allowsApkSelfUpdate) {
        await _installApkAndroid(donePath, context);
      } else {
        await _openFileDesktop(donePath, context);
      }
    }

    if (mounted) {
      setState(() {
        _isDownloading = false;
        _downloadProgress = -1;
      });
    }
  }

  /// Strips the <!-- force_update --> marker and basic HTML comments from the
  /// release notes body so the user sees clean text.
  String _cleanReleaseNotes(String raw) {
    return raw
        .replaceAll('<!-- force_update -->', '')
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final releaseNotes = _cleanReleaseNotes(widget.update.releaseNotesBody);

    return PopScope(
      canPop: !widget.isForced,
      child: Focus(
        onKeyEvent: (node, event) {
          // Block back button for forced updates
          if (widget.isForced &&
              event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.goBack ||
               event.logicalKey == LogicalKeyboardKey.escape)) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0F1923), Color(0xFF0A1017)],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _kAccent.withValues(alpha: 0.3), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: _kAccent.withValues(alpha: 0.15),
                  blurRadius: 40,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Header ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 0),
                  child: Column(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [_kAccent, _kAccent.withValues(alpha: 0.6)],
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.system_update_rounded, size: 28, color: Colors.black),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.isForced ? 'Update Required' : 'Update Available',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: _kAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _kAccent.withValues(alpha: 0.25)),
                        ),
                        child: Text(
                          'v${widget.update.version}',
                          style: TextStyle(
                            color: _kAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Release Notes ──
                if (releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Flexible(
                    child: Focus(
                      focusNode: _notesFocus,
                      onKeyEvent: _handleNotesKey,
                      child: Builder(builder: (context) {
                        final notesFocused = Focus.of(context).hasFocus;
                        return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 28),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: notesFocused
                              ? _kAccent.withValues(alpha: 0.8)
                              : Colors.white.withValues(alpha: 0.06),
                          width: notesFocused ? 2 : 1,
                        ),
                      ),
                      child: SingleChildScrollView(
                        controller: _notesScrollController,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.article_outlined, size: 16, color: _kAccent.withValues(alpha: 0.7)),
                                const SizedBox(width: 8),
                                Text(
                                  'What\'s New',
                                  style: TextStyle(
                                    color: _kAccent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              releaseNotes,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.75),
                                fontSize: 13,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                        );
                      }),
                    ),
                  ),
                ],

                // ── Action Buttons ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
                  child: Column(
                    children: [
                      // Store button - Play or AppGallery, per build channel.
                      if (widget.showStoreListing)
                        _UpdateActionButton(
                          focusNode: _storeFocus,
                          icon: Icons.storefront_rounded,
                          label: AppDistribution.isAppGalleryBuild
                              ? 'Update via AppGallery'
                              : 'Update via Play Store',
                          isPrimary: true,
                          onPressed: _openStoreListing,
                        ),

                      // APK Download button
                      if (widget.showApkDownload) ...[
                        if (widget.showStoreListing) const SizedBox(height: 10),
                        _isDownloading
                            ? _DownloadProgressRow(progress: _downloadProgress)
                            : _UpdateActionButton(
                                focusNode: _apkDownloadFocus,
                                icon: Icons.download_rounded,
                                label: 'Download APK',
                                isPrimary: !widget.showStoreListing,
                                onPressed: _downloadApk,
                              ),
                      ],

                      // Later / Dismiss button (only for non-forced)
                      if (!widget.isForced) ...[
                        const SizedBox(height: 10),
                        _UpdateActionButton(
                          focusNode: _laterFocus,
                          icon: Icons.schedule_rounded,
                          label: 'Remind Me Later',
                          isPrimary: false,
                          isSubtle: true,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ],
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

class _UpdateActionButton extends StatelessWidget {
  final FocusNode focusNode;
  final IconData icon;
  final String label;
  final bool isPrimary;
  final bool isSubtle;
  final VoidCallback onPressed;

  const _UpdateActionButton({
    required this.focusNode,
    required this.icon,
    required this.label,
    required this.isPrimary,
    this.isSubtle = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: isSubtle
          ? TextButton.icon(
              focusNode: focusNode,
              onPressed: onPressed,
              icon: Icon(icon, size: 18),
              label: Text(label, style: const TextStyle(fontSize: 14)),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white54,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ).copyWith(
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) return Colors.white;
                  return Colors.white54;
                }),
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) return Colors.white.withValues(alpha: 0.1);
                  return null;
                }),
                side: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return BorderSide(color: _kAccent, width: 2);
                  }
                  return null;
                }),
              ),
            )
          : ElevatedButton.icon(
              focusNode: focusNode,
              onPressed: onPressed,
              icon: Icon(icon, size: 20),
              label: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: isPrimary ? _kAccent : Colors.white.withValues(alpha: 0.08),
                foregroundColor: isPrimary ? Colors.black : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ).copyWith(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return isPrimary ? Colors.white : _kAccent;
                  }
                  return isPrimary ? _kAccent : Colors.white.withValues(alpha: 0.08);
                }),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) return Colors.black;
                  return isPrimary ? Colors.black : Colors.white;
                }),
                side: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return BorderSide(color: _kAccent, width: 2);
                  }
                  return null;
                }),
              ),
            ),
    );
  }
}

class _DownloadProgressRow extends StatelessWidget {
  final double progress;
  const _DownloadProgressRow({required this.progress});

  @override
  Widget build(BuildContext context) {
    final percent = progress >= 0 ? '${(progress * 100).toInt()}%' : '…';
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kAccent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              value: progress >= 0 ? progress : null,
              strokeWidth: 2.5,
              color: _kAccent,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Downloading update… $percent',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadProgressDialog extends StatefulWidget {
  final ValueNotifier<double> progressNotifier;
  final String label;
  final Future<void> onCompleted;
  final VoidCallback onCancel;

  const _DownloadProgressDialog({
    required this.progressNotifier,
    required this.label,
    required this.onCompleted,
    required this.onCancel,
  });

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.onCompleted.then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Text(widget.label),
          const SizedBox(height: 20),
          ValueListenableBuilder<double>(
            valueListenable: widget.progressNotifier,
            builder: (_, fraction, _) {
              return LinearProgressIndicator(
                value: fraction < 0 ? null : fraction.clamp(0.0, 1.0),
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}

// ─── APK install / file-open helpers ──────────────────────────────────────────

Future<void> _installApkAndroid(String path, BuildContext context) async {
  try {
    final canInstall = await _installChannel
        .invokeMethod<bool>('canInstallPackages') ?? false;
    if (!canInstall) {
      await _installChannel.invokeMethod<void>('requestInstallPermission');
      return;
    }
    await _installChannel.invokeMethod<void>('installApk', {'path': path});
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to install update.'),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }
}

Future<void> _openFileDesktop(String path, BuildContext context) async {
  try {
    if (PlatformDetection.isMacOS) {
      await Process.run('open', [path]);
    } else if (PlatformDetection.isWindows) {
      await Process.run('explorer', [path]);
    } else {
      await launchUrl(
        Uri.file(path),
        mode: LaunchMode.externalApplication,
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to open update file.'),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }
}
