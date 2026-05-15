import 'package:benchvault/src/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('daily schedule picks the next local wall-clock time', () {
    const schedule = BackupSchedule(
      enabled: true,
      frequency: BackupFrequency.daily,
      minutesAfterMidnight: 9 * 60 + 30,
      weekday: DateTime.monday,
    );

    expect(
      schedule.nextRunAfter(DateTime(2026, 5, 14, 9, 29)),
      DateTime(2026, 5, 14, 9, 30),
    );
    expect(
      schedule.nextRunAfter(DateTime(2026, 5, 14, 9, 30)),
      DateTime(2026, 5, 15, 9, 30),
    );
  });

  test('weekly schedule preserves the selected weekday', () {
    const schedule = BackupSchedule(
      enabled: true,
      frequency: BackupFrequency.weekly,
      minutesAfterMidnight: 2 * 60,
      weekday: DateTime.friday,
    );

    expect(
      schedule.nextRunAfter(DateTime(2026, 5, 14, 10)),
      DateTime(2026, 5, 15, 2),
    );
    expect(
      schedule.nextRunAfter(DateTime(2026, 5, 15, 3)),
      DateTime(2026, 5, 22, 2),
    );
  });
}
