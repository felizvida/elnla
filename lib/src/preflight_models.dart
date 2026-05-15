enum PreflightStatus {
  pass,
  warning,
  fail,
  info;

  bool get blocksBackup => this == PreflightStatus.fail;

  String get label {
    return switch (this) {
      PreflightStatus.pass => 'Ready',
      PreflightStatus.warning => 'Review',
      PreflightStatus.fail => 'Blocked',
      PreflightStatus.info => 'Info',
    };
  }
}

class PreflightCheck {
  const PreflightCheck({
    required this.id,
    required this.title,
    required this.detail,
    required this.status,
    this.nextAction,
  });

  final String id;
  final String title;
  final String detail;
  final PreflightStatus status;
  final String? nextAction;

  bool get blocksBackup => status.blocksBackup;
}

class BackupPreflightReport {
  const BackupPreflightReport({
    required this.generatedAt,
    required this.checks,
  });

  final DateTime generatedAt;
  final List<PreflightCheck> checks;

  Iterable<PreflightCheck> get blockingChecks =>
      checks.where((check) => check.blocksBackup);

  Iterable<PreflightCheck> get warningChecks =>
      checks.where((check) => check.status == PreflightStatus.warning);

  bool get canRunBackup => blockingChecks.isEmpty;

  String get summary {
    final blocking = blockingChecks.length;
    if (blocking > 0) {
      return '$blocking blocking check${blocking == 1 ? '' : 's'}';
    }
    final warnings = warningChecks.length;
    if (warnings > 0) {
      return 'Ready with $warnings warning${warnings == 1 ? '' : 's'}';
    }
    return 'Ready for backup';
  }
}
