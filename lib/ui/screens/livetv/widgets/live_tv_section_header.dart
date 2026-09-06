import 'package:flutter/material.dart';

class LiveTvSectionHeader extends StatelessWidget {
  final String title;
  final Widget details;

  const LiveTvSectionHeader({
    super.key,
    required this.title,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w300,
                    color: Colors.white,
                  ),
                ),
              ),
              // Brand mark, top-right. Replaces the spacer that was only
              // here to keep the centred title balanced against the back
              // button -- the logo occupies that space instead.
              SizedBox(
                width: 48,
                child: Image.asset(
                  'assets/images/voltix_bolt.png',
                  width: 44,
                  height: 44,
                  fit: BoxFit.contain,
                  cacheWidth: 88,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          details,
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
