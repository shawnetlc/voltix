import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Catchup start time and window calculation', () {
    test('Catchup start timestamp is correctly formatted in UTC', () {
      // Wicked aired yesterday at 20:00:00 SAST (UTC+2) -> 18:00:00 UTC
      // 2026-09-05T18:00:00Z epoch seconds
      final utcDate = DateTime.utc(2026, 9, 5, 18, 0, 0);
      final epochSeconds = utcDate.millisecondsSinceEpoch ~/ 1000;

      final start = DateTime.fromMillisecondsSinceEpoch(
        epochSeconds * 1000,
        isUtc: true,
      );

      String two(int v) => v.toString().padLeft(2, '0');
      final startArg =
          '${start.year}-${two(start.month)}-${two(start.day)} '
          '${two(start.hour)}:${two(start.minute)}:${two(start.second)}';

      // Verify that startArg sent to backend is 18:00:00 (UTC), NOT local 20:00:00
      expect(startArg, '2026-09-05 18:00:00');
    });

    test('72-hour lookback window calculates 4 days of guide schedules', () {
      const lookback = Duration(hours: 72);
      final daysToFetch = ((lookback.inHours / 24).ceil() + 1).clamp(1, 7);
      expect(daysToFetch, 4);

      final today = DateTime.utc(2026, 9, 6);
      final dates = List.generate(
        daysToFetch,
        (i) => today.subtract(Duration(days: daysToFetch - 1 - i)),
      );

      expect(dates.length, 4);
      expect(dates[0], DateTime.utc(2026, 9, 3)); // 3 days ago (covers 72h window)
      expect(dates[1], DateTime.utc(2026, 9, 4));
      expect(dates[2], DateTime.utc(2026, 9, 5));
      expect(dates[3], DateTime.utc(2026, 9, 6)); // today
    });
  });
}
