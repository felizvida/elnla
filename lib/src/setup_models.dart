class LocalSetupStatus {
  const LocalSetupStatus({
    required this.hasCredentials,
    required this.hasUserAccess,
    required this.hasNotebookIndex,
    required this.notebookCount,
  });

  final bool hasCredentials;
  final bool hasUserAccess;
  final bool hasNotebookIndex;
  final int notebookCount;

  bool get isReady => hasCredentials && hasUserAccess && hasNotebookIndex;
}

class LabArchivesSetupInput {
  const LabArchivesSetupInput({
    required this.email,
    required this.accessId,
    required this.accessKey,
    this.authCode,
  });

  final String email;
  final String accessId;
  final String accessKey;
  final String? authCode;
}

class UserAccessSnapshot {
  const UserAccessSnapshot({
    required this.uid,
    required this.notebooks,
    required this.rawXml,
  });

  final String uid;
  final List<NotebookAccess> notebooks;
  final String rawXml;
}

class NotebookAccess {
  const NotebookAccess({
    required this.name,
    required this.nbid,
    required this.isDefault,
  });

  final String name;
  final String nbid;
  final bool isDefault;
}

enum BackupFrequency {
  daily,
  weekly;

  String get label {
    switch (this) {
      case BackupFrequency.daily:
        return 'Daily';
      case BackupFrequency.weekly:
        return 'Weekly';
    }
  }
}

class BackupSchedule {
  const BackupSchedule({
    required this.enabled,
    required this.frequency,
    required this.minutesAfterMidnight,
    required this.weekday,
  });

  factory BackupSchedule.disabled() {
    return const BackupSchedule(
      enabled: false,
      frequency: BackupFrequency.daily,
      minutesAfterMidnight: 2 * 60,
      weekday: DateTime.monday,
    );
  }

  factory BackupSchedule.fromJson(Map<String, Object?> json) {
    final frequencyName = json['frequency'] as String?;
    return BackupSchedule(
      enabled: json['enabled'] == true,
      frequency: BackupFrequency.values.firstWhere(
        (value) => value.name == frequencyName,
        orElse: () => BackupFrequency.daily,
      ),
      minutesAfterMidnight: _intInRange(
        json['minutesAfterMidnight'],
        min: 0,
        max: 1439,
        fallback: 2 * 60,
      ),
      weekday: _intInRange(
        json['weekday'],
        min: DateTime.monday,
        max: DateTime.sunday,
        fallback: DateTime.monday,
      ),
    );
  }

  final bool enabled;
  final BackupFrequency frequency;
  final int minutesAfterMidnight;
  final int weekday;

  Map<String, Object?> toJson() {
    return {
      'enabled': enabled,
      'frequency': frequency.name,
      'minutesAfterMidnight': minutesAfterMidnight,
      'weekday': weekday,
    };
  }

  BackupSchedule copyWith({
    bool? enabled,
    BackupFrequency? frequency,
    int? minutesAfterMidnight,
    int? weekday,
  }) {
    return BackupSchedule(
      enabled: enabled ?? this.enabled,
      frequency: frequency ?? this.frequency,
      minutesAfterMidnight: minutesAfterMidnight ?? this.minutesAfterMidnight,
      weekday: weekday ?? this.weekday,
    );
  }

  DateTime nextRunAfter(DateTime now) {
    var candidate = DateTime(
      now.year,
      now.month,
      now.day,
      minutesAfterMidnight ~/ 60,
      minutesAfterMidnight % 60,
    );
    if (frequency == BackupFrequency.weekly) {
      final daysUntil = (weekday - candidate.weekday) % 7;
      candidate = candidate.add(Duration(days: daysUntil));
    }
    if (!candidate.isAfter(now)) {
      candidate = candidate.add(
        frequency == BackupFrequency.daily
            ? const Duration(days: 1)
            : const Duration(days: 7),
      );
    }
    return candidate;
  }
}

int _intInRange(
  Object? value, {
  required int min,
  required int max,
  required int fallback,
}) {
  if (value is int && value >= min && value <= max) {
    return value;
  }
  if (value is num) {
    final rounded = value.round();
    if (rounded >= min && rounded <= max) {
      return rounded;
    }
  }
  return fallback;
}
