import 'package:flutter/material.dart';
import 'package:server_core/server_core.dart';

/// A thin banner shown at the top of the app whenever a media server is
/// currently refusing the app (circuit breaker open after a 403). It reacts to
/// [ServerAvailability], which the Jellyfin client updates. When no server is
/// blocked it renders nothing and takes no space.
class ServerUnavailableBanner extends StatelessWidget {
  const ServerUnavailableBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final availability = ServerAvailability.instance;
    return StreamBuilder<bool>(
      stream: availability.changes,
      initialData: availability.anyUnavailable,
      builder: (context, snapshot) {
        final unavailable = snapshot.data ?? false;
        if (!unavailable) return const SizedBox.shrink();
        return Material(
          type: MaterialType.transparency,
          child: SafeArea(
            bottom: false,
            child: Container(
              width: double.infinity,
              color: const Color(0xFF7A1F1F),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off, size: 18, color: Colors.white),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'This server is temporarily unavailable. Retrying shortly…',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
