part of '../settings_side_panel.dart';

class _AboutCategoryScreen extends StatelessWidget {
  const _AboutCategoryScreen();

  @override
  Widget build(BuildContext context) {
    final appVersion = GetIt.instance<DeviceInfo>().appVersion;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: buildSettingsAppBar(context, Text(l10n.aboutTitle)),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          Center(
            child: Image.asset('assets/images/logo_and_text.png', height: 72),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              l10n.versionValue(appVersion),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 16),
          const Divider(),
          _SectionHeader(l10n.settingsAppInfo),
          _TvSettingsListTile(
            autofocus: true,
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.version),
            subtitle: Text(appVersion),
            trailing: const SizedBox.shrink(),
            onTap: () {},
          ),
          if (AppDistribution.supportsInAppUpdates)
            const _CheckForUpdatesTile(),
          _TvSettingsListTile(
            leading: const Icon(Icons.troubleshoot),
            title: const Text('Diagnostics & Logging'),
            subtitle: const Text(
              'Capture media, login and network logs and send them to the '
              'server as a report',
            ),
            onTap: () =>
                context.pushSettingsScreen(const DiagnosticsSettingsScreen()),
          ),
          _SectionHeader(l10n.settingsLegal),
          _TvSettingsListTile(
            leading: const Icon(Icons.description),
            title: Text(l10n.settingsLicenses),
            subtitle: Text(l10n.settingsOpenSourceLicenseNotices),
            onTap: () => context.pushSettingsScreen(const _LicensesScreen()),
          ),
        ],
      ),
    );
  }
}

class _CheckForUpdatesTile extends StatefulWidget {
  const _CheckForUpdatesTile();

  @override
  State<_CheckForUpdatesTile> createState() => _CheckForUpdatesTileState();
}

class _CheckForUpdatesTileState extends State<_CheckForUpdatesTile> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    await checkAndShowUpdateResult(context);
    if (!mounted) return;
    setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _TvSettingsListTile(
      leading: _checking
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.system_update_alt),
      title: Text(l10n.settingsCheckForUpdates),
      subtitle: Text(l10n.settingsCheckForUpdatesSubtitle),
      onTap: _checking ? null : _check,
    );
  }
}
