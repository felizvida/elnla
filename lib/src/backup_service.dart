import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'backup_models.dart';
import 'backup_parser.dart';
import 'labarchives_client.dart';
import 'preflight_models.dart';
import 'readable_notebook_exporter.dart';
import 'search_models.dart';
import 'secure_secret_store.dart';
import 'setup_models.dart';

typedef ProgressCallback = void Function(String message);

class _BackupFailure {
  const _BackupFailure({
    required this.category,
    required this.message,
    required this.nextAction,
  });

  final BackupFailureCategory category;
  final String message;
  final String nextAction;
}

class BackupService {
  BackupService({Directory? root, SecureSecretStore? secretStore})
    : root = root ?? _findProjectRoot(),
      _secretStore =
          secretStore ??
          (root == null && MacOSKeychainSecretStore.isSupported
              ? const MacOSKeychainSecretStore()
              : const DisabledSecretStore());

  final Directory root;
  final SecureSecretStore _secretStore;

  Directory get credentialsDir =>
      Directory(_join(root.path, 'local_credentials'));

  Directory get backupDir => Directory(_join(root.path, 'backups'));

  String get defaultBackupRootPath => backupDir.path;

  File get _credentialFile =>
      File(_join(credentialsDir.path, 'labarchives.env'));

  File get _userFile =>
      File(_join(credentialsDir.path, 'labarchives_user.env'));

  File get _notebooksFile => File(_join(credentialsDir.path, 'notebooks.tsv'));

  File get _settingsFile =>
      File(_join(credentialsDir.path, 'benchvault_settings.json'));

  File get _openAiSearchFile => File(_join(credentialsDir.path, 'openai.env'));

  File get _integrityLedgerFile =>
      File(_join(credentialsDir.path, 'integrity_ledger.jsonl'));

  File get _backupLockFile => File(_join(credentialsDir.path, 'backup.lock'));

  Future<LocalSetupStatus> loadSetupStatus() async {
    var notebookCount = 0;
    if (await _notebooksFile.exists()) {
      final lines = await _notebooksFile.readAsLines();
      notebookCount = lines.length > 1 ? lines.length - 1 : 0;
    }
    final hasSecureCredentials = await _hasSecureLabArchivesCredentials();
    final hasFileCredentials = await _hasLabArchivesCredentialFileSecrets();
    return LocalSetupStatus(
      hasCredentials: hasSecureCredentials || hasFileCredentials,
      hasUserAccess: await _userFile.exists(),
      hasNotebookIndex: await _notebooksFile.exists(),
      notebookCount: notebookCount,
    );
  }

  Future<BackupSettings> loadBackupSettings() async {
    if (!await _settingsFile.exists()) {
      return BackupSettings.defaults(defaultBackupRootPath);
    }
    try {
      final json =
          jsonDecode(await _settingsFile.readAsString())
              as Map<String, Object?>;
      return BackupSettings.fromJson(
        json,
        defaultBackupRootPath: defaultBackupRootPath,
      );
    } catch (_) {
      return BackupSettings.defaults(defaultBackupRootPath);
    }
  }

  Future<BackupSchedule> loadSchedule() async {
    return (await loadBackupSettings()).schedule;
  }

  Future<void> saveSchedule(BackupSchedule schedule) async {
    final settings = (await loadBackupSettings()).copyWith(schedule: schedule);
    await saveBackupSettings(settings);
  }

  Future<void> saveBackupSettings(BackupSettings settings) async {
    final backupRootPath = settings.backupRootPath.trim().isEmpty
        ? defaultBackupRootPath
        : settings.backupRootPath.trim();
    final cleanSettings = settings.copyWith(backupRootPath: backupRootPath);
    await credentialsDir.create(recursive: true);
    await _settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(cleanSettings.toJson()),
    );
    await _setOwnerOnlyPermissions(_settingsFile);
  }

  Future<OpenAiSearchSettings?> loadOpenAiSearchSettings() async {
    if (_secretStore.isAvailable) {
      final apiKey = await _readSecret(
        service: BenchVaultSecretServices.openAi,
        account: BenchVaultSecretAccounts.openAiApiKey,
      );
      if (apiKey != null && apiKey.trim().isNotEmpty) {
        final model = await _openAiModelFromFile();
        return OpenAiSearchSettings(apiKey: apiKey, model: model);
      }
    }
    if (!await _openAiSearchFile.exists()) {
      return null;
    }
    final values = await _loadEnv(_openAiSearchFile);
    final apiKey = values['OPENAI_API_KEY'] ?? '';
    final model = values['OPENAI_MODEL'] ?? OpenAiSearchSettings.defaultModel;
    if (apiKey.trim().isEmpty) {
      return null;
    }
    if (_secretStore.isAvailable) {
      await _writeSecret(
        service: BenchVaultSecretServices.openAi,
        account: BenchVaultSecretAccounts.openAiApiKey,
        value: apiKey,
      );
      await _writeOpenAiMetadata(model);
    }
    return OpenAiSearchSettings(apiKey: apiKey, model: model);
  }

  Future<BackupPreflightReport> runPreflight() async {
    final checks = <PreflightCheck>[];
    final setupStatus = await loadSetupStatus();
    final settings = await loadBackupSettings();
    final openAiSettings = await loadOpenAiSearchSettings();

    checks.add(_setupPreflight(setupStatus));
    checks.add(_notebookIndexPreflight(setupStatus));
    checks.add(await _backupFolderPreflight(settings.backupRootPath));
    checks.add(await _diskSpacePreflight(settings.backupRootPath));
    checks.add(await _archiveExtractorPreflight());
    checks.add(_readOnlyContractPreflight());
    checks.add(_openAiPreflight(openAiSettings));
    checks.add(_schedulePreflight(settings.schedule));

    return BackupPreflightReport(
      generatedAt: DateTime.now().toUtc(),
      checks: checks,
    );
  }

  PreflightCheck _setupPreflight(LocalSetupStatus setupStatus) {
    if (setupStatus.hasCredentials && setupStatus.hasUserAccess) {
      return PreflightCheck(
        id: 'credentials',
        title: 'LabArchives authorization',
        detail:
            'Credentials are present in ${_credentialStorageLabel()}; UID is present in local setup metadata.',
        status: PreflightStatus.pass,
      );
    }
    return const PreflightCheck(
      id: 'credentials',
      title: 'LabArchives authorization',
      detail: 'Credentials or UID are missing.',
      status: PreflightStatus.fail,
      nextAction: 'Connect LabArchives credentials from setup.',
    );
  }

  PreflightCheck _notebookIndexPreflight(LocalSetupStatus setupStatus) {
    if (!setupStatus.hasNotebookIndex) {
      return const PreflightCheck(
        id: 'notebook_index',
        title: 'Notebook list',
        detail: 'The local notebook list has not been created yet.',
        status: PreflightStatus.fail,
        nextAction: 'Complete LabArchives setup to capture notebook metadata.',
      );
    }
    if (setupStatus.notebookCount == 0) {
      return const PreflightCheck(
        id: 'notebook_index',
        title: 'Notebook list',
        detail: 'The local notebook list exists but contains no notebooks.',
        status: PreflightStatus.warning,
        nextAction:
            'Reconnect setup after confirming the account owns backup-eligible notebooks.',
      );
    }
    return PreflightCheck(
      id: 'notebook_index',
      title: 'Notebook list',
      detail:
          '${setupStatus.notebookCount} notebook${setupStatus.notebookCount == 1 ? '' : 's'} available for backup attempts.',
      status: PreflightStatus.pass,
    );
  }

  Future<PreflightCheck> _backupFolderPreflight(String backupRootPath) async {
    final cleanPath = backupRootPath.trim();
    if (cleanPath.isEmpty) {
      return const PreflightCheck(
        id: 'backup_folder',
        title: 'Backup folder',
        detail: 'No backup folder is configured.',
        status: PreflightStatus.fail,
        nextAction: 'Choose a protected local backup folder.',
      );
    }
    final directory = Directory(cleanPath);
    try {
      await directory.create(recursive: true);
      final probe = File(_join(directory.path, '.benchvault_preflight.tmp'));
      await probe.writeAsString('benchvault preflight\n');
      await probe.delete();
      return PreflightCheck(
        id: 'backup_folder',
        title: 'Backup folder',
        detail: 'Writable: ${_relative(cleanPath)}',
        status: PreflightStatus.pass,
      );
    } catch (error) {
      return PreflightCheck(
        id: 'backup_folder',
        title: 'Backup folder',
        detail: 'The configured backup folder is not writable: $error',
        status: PreflightStatus.fail,
        nextAction: 'Choose a folder that this Mac account can write to.',
      );
    }
  }

  Future<PreflightCheck> _diskSpacePreflight(String backupRootPath) async {
    final cleanPath = backupRootPath.trim();
    if (cleanPath.isEmpty) {
      return const PreflightCheck(
        id: 'disk_space',
        title: 'Backup storage',
        detail: 'Disk space cannot be checked until a backup folder is set.',
        status: PreflightStatus.warning,
      );
    }
    if (Platform.isWindows) {
      return const PreflightCheck(
        id: 'disk_space',
        title: 'Backup storage',
        detail:
            'Disk-space preflight is not implemented on Windows in this build.',
        status: PreflightStatus.info,
      );
    }
    try {
      final result = await Process.run('df', ['-Pk', cleanPath]);
      if (result.exitCode != 0) {
        return PreflightCheck(
          id: 'disk_space',
          title: 'Backup storage',
          detail: 'Could not measure free space: ${result.stderr}',
          status: PreflightStatus.warning,
        );
      }
      final lines = result.stdout.toString().trim().split('\n');
      if (lines.length < 2) {
        throw StateError('Unexpected df output.');
      }
      final columns = lines.last.trim().split(RegExp(r'\s+'));
      if (columns.length < 4) {
        throw StateError('Unexpected df columns.');
      }
      final availableKilobytes = int.parse(columns[3]);
      final availableBytes = availableKilobytes * 1024;
      final availableGiB = availableBytes / (1024 * 1024 * 1024);
      final detail =
          '${availableGiB.toStringAsFixed(1)} GiB available near the backup folder.';
      if (availableGiB < 1) {
        return PreflightCheck(
          id: 'disk_space',
          title: 'Backup storage',
          detail: detail,
          status: PreflightStatus.fail,
          nextAction: 'Free space or choose another backup folder.',
        );
      }
      if (availableGiB < 10) {
        return PreflightCheck(
          id: 'disk_space',
          title: 'Backup storage',
          detail: detail,
          status: PreflightStatus.warning,
          nextAction:
              'Large notebooks may need more space; consider a roomier backup volume.',
        );
      }
      return PreflightCheck(
        id: 'disk_space',
        title: 'Backup storage',
        detail: detail,
        status: PreflightStatus.pass,
      );
    } catch (error) {
      return PreflightCheck(
        id: 'disk_space',
        title: 'Backup storage',
        detail: 'Disk-space check could not run: $error',
        status: PreflightStatus.warning,
      );
    }
  }

  Future<PreflightCheck> _archiveExtractorPreflight() async {
    final command = await _findArchiveExtractor();
    final sqliteCommand = await _findCommand('sqlite3');
    if (command != null) {
      return PreflightCheck(
        id: 'archive_extractor',
        title: 'Archive extraction',
        detail:
            'Archive extractor available: $command. SQLite backup compatibility: ${sqliteCommand ?? 'not available'}.',
        status: PreflightStatus.pass,
      );
    }
    return const PreflightCheck(
      id: 'archive_extractor',
      title: 'Archive extraction',
      detail:
          'No supported extractor was found. BenchVault needs bsdtar, tar, or 7z to unpack LabArchives .7z backups.',
      status: PreflightStatus.fail,
      nextAction: 'Install or bundle a supported archive extractor.',
    );
  }

  Future<String?> _findArchiveExtractor() async {
    for (final command in const ['bsdtar', 'tar', '7z']) {
      final found = await _findCommand(command);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  Future<String?> _findCommand(String command) async {
    try {
      final result = Platform.isWindows
          ? await Process.run('where', [command])
          : await Process.run('which', [command]);
      if (result.exitCode == 0) {
        return command;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  PreflightCheck _readOnlyContractPreflight() {
    try {
      LabArchivesClient.assertReadOnlyElnOperation(
        apiClass: 'users',
        method: 'user_access_info',
        paramKeys: const ['login_or_email', 'password'],
      );
      LabArchivesClient.assertReadOnlyElnOperation(
        apiClass: 'notebooks',
        method: 'notebook_backup',
        paramKeys: const ['uid', 'nbid', 'json'],
      );
      final refusedWrite = !LabArchivesClient.isReadOnlyElnOperation(
        'entries',
        'add_entry',
      );
      if (!refusedWrite) {
        throw StateError('Mutable endpoint unexpectedly allowlisted.');
      }
      return const PreflightCheck(
        id: 'read_only_contract',
        title: 'Read-only LabArchives contract',
        detail:
            'Production access is limited to login, user-access lookup, and notebook backup download.',
        status: PreflightStatus.pass,
      );
    } catch (error) {
      return PreflightCheck(
        id: 'read_only_contract',
        title: 'Read-only LabArchives contract',
        detail: 'Read-only guard failed: $error',
        status: PreflightStatus.fail,
        nextAction: 'Stop and review the LabArchives client allowlist.',
      );
    }
  }

  PreflightCheck _openAiPreflight(OpenAiSearchSettings? settings) {
    if (settings?.hasApiKey ?? false) {
      return PreflightCheck(
        id: 'openai_search',
        title: 'Notebook search',
        detail: 'OpenAI search is configured with model ${settings!.model}.',
        status: PreflightStatus.pass,
      );
    }
    return const PreflightCheck(
      id: 'openai_search',
      title: 'Notebook search',
      detail:
          'OpenAI search is not configured. Local fuzzy search remains available.',
      status: PreflightStatus.info,
    );
  }

  PreflightCheck _schedulePreflight(BackupSchedule schedule) {
    if (schedule.enabled) {
      final next = schedule.nextRunAfter(DateTime.now());
      return PreflightCheck(
        id: 'automatic_backup',
        title: 'Automatic backup',
        detail: 'Enabled. Next run: ${next.toLocal()}.',
        status: PreflightStatus.pass,
      );
    }
    return const PreflightCheck(
      id: 'automatic_backup',
      title: 'Automatic backup',
      detail: 'Not enabled. Manual backup is available.',
      status: PreflightStatus.info,
    );
  }

  Future<void> saveOpenAiSearchSettings(OpenAiSearchSettings settings) async {
    final apiKey = settings.apiKey.trim();
    if (apiKey.isEmpty) {
      await _deleteSecret(
        service: BenchVaultSecretServices.openAi,
        account: BenchVaultSecretAccounts.openAiApiKey,
      );
      if (await _openAiSearchFile.exists()) {
        await _openAiSearchFile.delete();
      }
      return;
    }
    final model = settings.model.trim().isEmpty
        ? OpenAiSearchSettings.defaultModel
        : settings.model.trim();
    if (_secretStore.isAvailable) {
      await _writeSecret(
        service: BenchVaultSecretServices.openAi,
        account: BenchVaultSecretAccounts.openAiApiKey,
        value: apiKey,
      );
      await _writeOpenAiMetadata(model);
      return;
    }
    await credentialsDir.create(recursive: true);
    await _openAiSearchFile.writeAsString(
      ['OPENAI_API_KEY=$apiKey', 'OPENAI_MODEL=$model', ''].join('\n'),
    );
    await _setOwnerOnlyPermissions(_openAiSearchFile);
  }

  Future<UserAccessSnapshot> authorizeWithAuthCode(
    LabArchivesSetupInput input,
  ) async {
    final authCode = input.authCode?.trim();
    if (authCode == null || authCode.isEmpty) {
      throw StateError('Enter the LabArchives auth code.');
    }
    final cleanInput = _validatedSetupInput(input);
    final client = LabArchivesClient(
      accessId: cleanInput.accessId,
      accessKey: cleanInput.accessKey,
    );
    final xml = await client.fetchUserAccessInfoXml(
      email: cleanInput.email,
      authCode: authCode,
    );
    final snapshot = _parseUserAccessInfo(xml);
    await _persistSetup(cleanInput, snapshot);
    return snapshot;
  }

  Future<UserAccessSnapshot> authorizeWithBrowser({
    required LabArchivesSetupInput input,
    ProgressCallback? onProgress,
    void Function(String url)? onLoginUrl,
  }) async {
    final cleanInput = _validatedSetupInput(input);
    final client = LabArchivesClient(
      accessId: cleanInput.accessId,
      accessKey: cleanInput.accessKey,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri =
        'http://${server.address.host}:${server.port}/labarchives_callback';
    final loginUrl = client
        .buildUserLoginUri(redirectUri: redirectUri)
        .toString();
    onLoginUrl?.call(loginUrl);
    final opened = await _openExternalUrl(loginUrl);
    onProgress?.call(
      opened
          ? 'Opened LabArchives authorization in the browser.'
          : 'Login URL copied. Paste it into a browser to continue.',
    );

    try {
      final callback = await _waitForAuthCallback(server).timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw TimeoutException('LabArchives authorization timed out.');
        },
      );
      final error = callback['error'];
      if (error != null && error.isNotEmpty) {
        throw StateError('LabArchives authorization returned an error.');
      }
      final authCode = callback['auth_code'];
      if (authCode == null || authCode.isEmpty) {
        throw StateError('LabArchives did not return an auth code.');
      }
      final email = callback['email']?.isNotEmpty == true
          ? callback['email']!
          : cleanInput.email;
      final xml = await client.fetchUserAccessInfoXml(
        email: email,
        authCode: authCode,
      );
      final snapshot = _parseUserAccessInfo(xml);
      await _persistSetup(
        LabArchivesSetupInput(
          email: email,
          accessId: cleanInput.accessId,
          accessKey: cleanInput.accessKey,
          backupRootPath: cleanInput.backupRootPath,
          openAiApiKey: cleanInput.openAiApiKey,
          openAiModel: cleanInput.openAiModel,
        ),
        snapshot,
      );
      return snapshot;
    } finally {
      await server.close(force: true);
    }
  }

  Future<List<NotebookSummary>> loadNotebookSummaries() async {
    if (!await _notebooksFile.exists()) {
      throw StateError(
        'Missing ${_relative(_notebooksFile.path)}. Run scripts/labarchives_auth_flow.py first.',
      );
    }
    final lines = await _notebooksFile.readAsLines();
    if (lines.length <= 1) {
      return const [];
    }
    final notebooks = <NotebookSummary>[];
    for (final line in lines.skip(1)) {
      final columns = line.split('\t');
      if (columns.length < 2) {
        continue;
      }
      notebooks.add(
        NotebookSummary(
          name: columns[0],
          nbid: columns[1],
          isDefault: columns.length > 2 && columns[2].toLowerCase() == 'true',
        ),
      );
    }
    return notebooks;
  }

  Future<List<BackupRecord>> loadBackups() async {
    final records = <BackupRecord>[];
    for (final directory in await _backupSearchDirs()) {
      if (!await directory.exists()) {
        continue;
      }
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('backup_record.json')) {
          continue;
        }
        try {
          final json =
              jsonDecode(await entity.readAsString()) as Map<String, Object?>;
          records.add(BackupRecord.fromJson(json));
        } catch (_) {
          continue;
        }
      }
    }
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records;
  }

  Future<BackupRunManifest?> loadLatestBackupRun() async {
    final runs = <BackupRunManifest>[];
    for (final backupRoot in await _backupSearchDirs()) {
      final runsDir = Directory(_join(backupRoot.path, 'runs'));
      if (!await runsDir.exists()) {
        continue;
      }
      await for (final entity in runsDir.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.json')) {
          continue;
        }
        try {
          final json =
              jsonDecode(await entity.readAsString()) as Map<String, Object?>;
          runs.add(BackupRunManifest.fromJson(json));
        } catch (_) {
          continue;
        }
      }
    }
    if (runs.isEmpty) {
      return null;
    }
    runs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return runs.first;
  }

  Future<RenderNotebook> loadRenderNotebook(BackupRecord record) async {
    final file = await _resolveBackupFile(record.renderPath);
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return RenderNotebook.fromJson(json);
  }

  Future<BackupRecord> sealBackupIntegrity(BackupRecord record) async {
    final renderFile = await _resolveBackupFile(record.renderPath);
    final backupRoot = await _backupRootForFile(renderFile);
    final runDir = renderFile.parent;
    final manifestFile = File(_join(runDir.path, 'integrity_manifest.json'));
    final manifestPath = _relativeTo(backupRoot.path, manifestFile.path);
    final sealedRecord = record.copyWith(integrityManifestPath: manifestPath);
    final recordFile = File(_join(runDir.path, 'backup_record.json'));
    await recordFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(sealedRecord.toJson()),
    );

    final manifest = await _buildIntegrityManifest(
      record: sealedRecord,
      runDir: runDir,
      backupRootPath: backupRoot.path,
      manifestPath: manifestPath,
    );
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
    final manifestSha256 = await _sha256File(manifestFile);
    await _appendIntegrityLedger(
      record: sealedRecord,
      manifestPath: manifestPath,
      manifestSha256: manifestSha256,
      manifestBytes: await manifestFile.length(),
    );
    return sealedRecord;
  }

  Future<BackupIntegrityCheck> verifyBackupIntegrity(
    BackupRecord record,
  ) async {
    final manifestPath = record.integrityManifestPath;
    if (manifestPath == null || manifestPath.trim().isEmpty) {
      return BackupIntegrityCheck(
        backupId: record.id,
        checkedAt: DateTime.now().toUtc(),
        hasManifest: false,
        hasLocalSeal: false,
        manifestPath: null,
        checkedFileCount: 0,
        checkedBytes: 0,
      );
    }

    final manifestFile = await _resolveBackupFile(manifestPath);
    if (!await manifestFile.exists()) {
      return BackupIntegrityCheck(
        backupId: record.id,
        checkedAt: DateTime.now().toUtc(),
        hasManifest: false,
        hasLocalSeal: false,
        manifestPath: manifestPath,
        checkedFileCount: 0,
        checkedBytes: 0,
      );
    }

    try {
      final manifestSha256 = await _sha256File(manifestFile);
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
      final entries = (manifest['files'] as List<Object?>? ?? const [])
          .cast<Map<String, Object?>>();
      final expectedPaths = <String>{};
      final missingFiles = <String>[];
      final changedFiles = <String>[];
      var checkedBytes = 0;
      for (final entry in entries) {
        final path = entry['path'] as String? ?? '';
        if (path.isEmpty) {
          continue;
        }
        expectedPaths.add(path);
        final file = await _resolveBackupFile(path);
        if (!await file.exists()) {
          missingFiles.add(path);
          continue;
        }
        final expectedSize = entry['bytes'] as int? ?? -1;
        final actualSize = await file.length();
        checkedBytes += actualSize;
        final expectedSha256 = entry['sha256'] as String? ?? '';
        final actualSha256 = await _sha256File(file);
        if (expectedSize != actualSize || expectedSha256 != actualSha256) {
          changedFiles.add(path);
        }
      }

      final renderFile = await _resolveBackupFile(record.renderPath);
      final backupRoot = await _backupRootForFile(renderFile);
      final currentPaths = await _currentProtectedPaths(
        runDir: renderFile.parent,
        backupRootPath: backupRoot.path,
      );
      final extraFiles =
          currentPaths.where((path) => !expectedPaths.contains(path)).toList()
            ..sort();

      final ledgerEntry = await _findIntegrityLedgerEntry(
        backupId: record.id,
        manifestPath: manifestPath,
      );
      final sealedManifestSha256 = ledgerEntry?['manifestSha256'] as String?;
      return BackupIntegrityCheck(
        backupId: record.id,
        checkedAt: DateTime.now().toUtc(),
        hasManifest: true,
        hasLocalSeal: ledgerEntry != null,
        manifestPath: manifestPath,
        manifestSha256: manifestSha256,
        sealedManifestSha256: sealedManifestSha256,
        checkedFileCount: entries.length,
        checkedBytes: checkedBytes,
        missingFiles: missingFiles,
        changedFiles: changedFiles,
        extraFiles: extraFiles,
      );
    } catch (error) {
      return BackupIntegrityCheck(
        backupId: record.id,
        checkedAt: DateTime.now().toUtc(),
        hasManifest: true,
        hasLocalSeal: false,
        manifestPath: manifestPath,
        checkedFileCount: 0,
        checkedBytes: 0,
        error: error.toString(),
      );
    }
  }

  Future<BackupAuditExport> exportAuditSummary(BackupRecord record) async {
    final check = await verifyBackupIntegrity(record);
    final renderFile = await _resolveBackupFile(record.renderPath);
    final runDir = renderFile.parent;
    final backupRoot = await _backupRootForFile(renderFile);
    final auditDir = Directory(_join(runDir.path, 'audit'));
    await auditDir.create(recursive: true);

    final generatedAt = DateTime.now().toUtc();
    final jsonFile = File(_join(auditDir.path, 'backup_audit_summary.json'));
    final markdownFile = File(_join(auditDir.path, 'backup_audit_summary.md'));
    final csvFile = File(_join(auditDir.path, 'integrity_files.csv'));
    final hashAnchorFile = File(
      _join(auditDir.path, 'external_hash_anchor.txt'),
    );
    final jsonPath = _relativeTo(backupRoot.path, jsonFile.path);
    final markdownPath = _relativeTo(backupRoot.path, markdownFile.path);
    final csvPath = _relativeTo(backupRoot.path, csvFile.path);
    final hashAnchorPath = _relativeTo(backupRoot.path, hashAnchorFile.path);
    final manifestEntries = await _integrityManifestEntries(record);

    final summary = <String, Object?>{
      'version': 1,
      'kind': 'benchvault.backup.audit',
      'generatedAt': generatedAt.toIso8601String(),
      'note':
          'BenchVault audit summaries are local tamper-evidence aids. They do not replace institutional records policy, chain-of-custody review, or legal certification.',
      'backup': record.toJson(),
      'integrityCheck': check.toJson(),
      'exports': {
        'markdownPath': markdownPath,
        'jsonPath': jsonPath,
        'csvPath': csvPath,
        'hashAnchorPath': hashAnchorPath,
      },
      'integrityFiles': manifestEntries,
    };
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
    );
    await markdownFile.writeAsString(
      _auditMarkdown(
        record: record,
        check: check,
        generatedAt: generatedAt,
        jsonPath: jsonPath,
        csvPath: csvPath,
        hashAnchorPath: hashAnchorPath,
        manifestEntries: manifestEntries,
      ),
    );
    await csvFile.writeAsString(_auditCsv(manifestEntries));
    await hashAnchorFile.writeAsString(
      _externalHashAnchor(
        record: record,
        check: check,
        generatedAt: generatedAt,
      ),
    );

    return BackupAuditExport(
      generatedAt: generatedAt,
      markdownPath: markdownPath,
      jsonPath: jsonPath,
      csvPath: csvPath,
      hashAnchorPath: hashAnchorPath,
      integrityCheck: check,
    );
  }

  Future<List<Map<String, Object?>>> _integrityManifestEntries(
    BackupRecord record,
  ) async {
    final manifestPath = record.integrityManifestPath;
    if (manifestPath == null || manifestPath.trim().isEmpty) {
      return const [];
    }
    final manifestFile = await _resolveBackupFile(manifestPath);
    if (!await manifestFile.exists()) {
      return const [];
    }
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
    return (manifest['files'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .toList();
  }

  String _auditMarkdown({
    required BackupRecord record,
    required BackupIntegrityCheck check,
    required DateTime generatedAt,
    required String jsonPath,
    required String csvPath,
    required String hashAnchorPath,
    required List<Map<String, Object?>> manifestEntries,
  }) {
    final buffer = StringBuffer()
      ..writeln('# BenchVault Backup Audit Summary')
      ..writeln()
      ..writeln('- Notebook: `${record.notebookName}`')
      ..writeln('- Backup ID: `${record.id}`')
      ..writeln('- Backup created: `${record.createdAt.toIso8601String()}`')
      ..writeln('- Audit generated: `${generatedAt.toIso8601String()}`')
      ..writeln('- Integrity status: `${check.statusTitle}`')
      ..writeln('- Integrity summary: ${check.summary}')
      ..writeln('- Faithful archive: `${record.archivePath}`')
      ..writeln('- Viewer JSON: `${record.renderPath}`');
    if (record.readablePath != null) {
      buffer.writeln('- Readable copy: `${record.readablePath}`');
    }
    if (record.searchIndexPath != null) {
      buffer.writeln('- Search index: `${record.searchIndexPath}`');
    }
    if (record.integrityManifestPath != null) {
      buffer.writeln('- Integrity manifest: `${record.integrityManifestPath}`');
    }
    buffer
      ..writeln('- Machine-readable JSON: `$jsonPath`')
      ..writeln('- Integrity file CSV: `$csvPath`')
      ..writeln('- External hash anchor: `$hashAnchorPath`')
      ..writeln()
      ..writeln('## Original Attachment Verification');
    final verification = record.contentVerification;
    if (verification == null) {
      buffer.writeln(
        'This backup record does not include original attachment verification metadata.',
      );
    } else {
      buffer
        ..writeln('- Summary: `${verification.summary}`')
        ..writeln('- Complete: `${verification.isComplete}`')
        ..writeln(
          '- Expected originals: `${verification.expectedOriginalAttachmentCount}`',
        )
        ..writeln(
          '- Verified originals: `${verification.verifiedOriginalAttachmentCount}`',
        )
        ..writeln(
          '- Expected original bytes: `${verification.expectedOriginalAttachmentBytes}`',
        )
        ..writeln(
          '- Verified original bytes: `${verification.verifiedOriginalAttachmentBytes}`',
        );
    }
    buffer
      ..writeln()
      ..writeln('## Integrity Check')
      ..writeln()
      ..writeln('- Manifest present: `${check.hasManifest}`')
      ..writeln('- Local seal present: `${check.hasLocalSeal}`')
      ..writeln('- Manifest matches local seal: `${check.manifestMatchesSeal}`')
      ..writeln('- Checked files: `${check.checkedFileCount}`')
      ..writeln('- Checked bytes: `${check.checkedBytes}`');
    if (check.manifestSha256 != null) {
      buffer.writeln('- Manifest SHA-256: `${check.manifestSha256}`');
    }
    if (check.sealedManifestSha256 != null) {
      buffer.writeln(
        '- Sealed manifest SHA-256: `${check.sealedManifestSha256}`',
      );
    }
    _auditPathSection(buffer, 'Changed files', check.changedFiles);
    _auditPathSection(buffer, 'Missing files', check.missingFiles);
    _auditPathSection(buffer, 'Unexpected files', check.extraFiles);
    buffer
      ..writeln()
      ..writeln('## Protected Files')
      ..writeln()
      ..writeln(
        'Protected files listed in the CSV are the files hashed by the integrity manifest at backup time.',
      )
      ..writeln()
      ..writeln('## Important Limit')
      ..writeln()
      ..writeln(
        'This audit summary is local tamper-evidence, not true immutability or legal certification by itself.',
      );
    return buffer.toString();
  }

  void _auditPathSection(
    StringBuffer buffer,
    String title,
    List<String> paths,
  ) {
    buffer
      ..writeln()
      ..writeln('### $title')
      ..writeln();
    if (paths.isEmpty) {
      buffer.writeln('None.');
      return;
    }
    for (final path in paths) {
      buffer.writeln('- `$path`');
    }
  }

  String _auditCsv(List<Map<String, Object?>> entries) {
    final buffer = StringBuffer()..writeln('path,bytes,sha256,modifiedAt');
    for (final entry in entries) {
      buffer.writeln(
        [
          entry['path'] ?? '',
          entry['bytes'] ?? '',
          entry['sha256'] ?? '',
          entry['modifiedAt'] ?? '',
        ].map((value) => _csv(value.toString())).join(','),
      );
    }
    return buffer.toString();
  }

  String _externalHashAnchor({
    required BackupRecord record,
    required BackupIntegrityCheck check,
    required DateTime generatedAt,
  }) {
    final buffer = StringBuffer()
      ..writeln('BenchVault external hash anchor')
      ..writeln('Generated at: ${generatedAt.toIso8601String()}')
      ..writeln('Notebook: ${record.notebookName}')
      ..writeln('Backup ID: ${record.id}')
      ..writeln('Backup created: ${record.createdAt.toIso8601String()}')
      ..writeln('Integrity status: ${check.statusTitle}')
      ..writeln('Integrity manifest: ${check.manifestPath ?? 'missing'}')
      ..writeln('Manifest SHA-256: ${check.manifestSha256 ?? 'unavailable'}')
      ..writeln(
        'Sealed manifest SHA-256: ${check.sealedManifestSha256 ?? 'unavailable'}',
      )
      ..writeln()
      ..writeln(
        'Store this text or just the manifest SHA-256 in an institutional records system, WORM storage, or another append-only location to strengthen later originality review.',
      );
    return buffer.toString();
  }

  Future<BackupRecord> ensureReadableCopy(BackupRecord record) async {
    final existingMarkdown = record.readablePath == null
        ? null
        : await _resolveBackupFile(record.readablePath!);
    final existingIndex = record.searchIndexPath == null
        ? null
        : await _resolveBackupFile(record.searchIndexPath!);
    if (existingMarkdown != null &&
        existingIndex != null &&
        await existingMarkdown.exists() &&
        await existingIndex.exists()) {
      return record;
    }

    final renderFile = await _resolveBackupFile(record.renderPath);
    final notebook = await loadRenderNotebook(record);
    final backupRoot = await _backupRootForFile(renderFile);
    final artifacts = await ReadableNotebookExporter().write(
      record: record,
      notebook: notebook,
      runDir: renderFile.parent,
      backupRootPath: backupRoot.path,
    );
    final updated = record.copyWith(
      readablePath: artifacts.markdownPath,
      searchIndexPath: artifacts.searchIndexPath,
    );
    final recordFile = File(
      _join(renderFile.parent.path, 'backup_record.json'),
    );
    if (await recordFile.exists()) {
      await recordFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(updated.toJson()),
      );
    }
    return updated;
  }

  Future<List<NotebookSearchChunk>> loadSearchChunks(
    BackupRecord record,
  ) async {
    final readableRecord = await ensureReadableCopy(record);
    final indexPath = readableRecord.searchIndexPath;
    if (indexPath == null || indexPath.isEmpty) {
      return const [];
    }
    final file = await _resolveBackupFile(indexPath);
    if (!await file.exists()) {
      return const [];
    }
    final chunks = <NotebookSearchChunk>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) {
        continue;
      }
      final json = jsonDecode(line) as Map<String, Object?>;
      chunks.add(NotebookSearchChunk.fromJson(json));
    }
    return chunks;
  }

  Future<List<NotebookSearchChunk>> loadAllSearchChunks() async {
    final records = await loadBackups();
    final chunks = <NotebookSearchChunk>[];
    for (final record in records) {
      try {
        chunks.addAll(await loadSearchChunks(record));
      } catch (_) {
        continue;
      }
    }
    return chunks;
  }

  Future<File> restoreAttachment({
    required BackupRecord record,
    required RenderPart part,
    required Directory destination,
  }) async {
    if (!part.isAttachment) {
      throw StateError('Selected entry part is not an attachment.');
    }
    final source = await _resolveOriginalAttachment(record, part);
    if (source == null || !await source.exists()) {
      throw StateError(
        'Original attachment file is not available in this local backup.',
      );
    }
    await destination.create(recursive: true);
    final fileName = _safeAttachmentFileName(
      part.attachmentName ?? source.uri.pathSegments.last,
    );
    final output = await _uniqueDestinationFile(destination, fileName);
    final restored = await source.copy(output.path);
    final expectedSize = part.attachmentSize;
    if (expectedSize != null && await restored.length() != expectedSize) {
      await restored.delete();
      throw StateError(
        'Restored attachment size did not match the backup metadata.',
      );
    }
    return restored;
  }

  Future<File?> resolveOriginalAttachmentFile({
    required BackupRecord record,
    required RenderPart part,
  }) {
    return _resolveOriginalAttachment(record, part);
  }

  Future<File?> resolveAttachmentThumbnailFile({
    required BackupRecord record,
    required RenderPart part,
  }) async {
    final thumbnailPath = part.attachmentThumbnailPath;
    if (thumbnailPath == null || thumbnailPath.trim().isEmpty) {
      return null;
    }
    final file = await _resolveBackupFile(thumbnailPath);
    return await file.exists() ? file : null;
  }

  Future<String?> loadAttachmentTextPreview({
    required BackupRecord record,
    required RenderPart part,
    int maxBytes = 65536,
  }) async {
    final source = await _resolveOriginalAttachment(record, part);
    if (source == null || !await source.exists()) {
      return null;
    }
    final length = await source.length();
    final previewEnd = length < maxBytes ? length : maxBytes;
    final bytes = <int>[];
    await for (final chunk in source.openRead(0, previewEnd)) {
      bytes.addAll(chunk);
    }
    if (bytes.contains(0)) {
      return null;
    }
    final decoded = utf8.decode(bytes, allowMalformed: true);
    return length > maxBytes ? '$decoded\n\n[Preview truncated]' : decoded;
  }

  Future<List<BackupRecord>> backupAllNotebooks({
    ProgressCallback? onProgress,
  }) async {
    await credentialsDir.create(recursive: true);
    final lock = await _backupLockFile.open(mode: FileMode.write);
    var locked = false;
    try {
      onProgress?.call('Waiting for exclusive BenchVault backup lock...');
      await lock.lock();
      locked = true;
      onProgress?.call('Backup lock acquired.');
      return await _backupAllNotebooksUnlocked(onProgress: onProgress);
    } finally {
      if (locked) {
        await lock.unlock();
      }
      await lock.close();
    }
  }

  Future<List<BackupRecord>> _backupAllNotebooksUnlocked({
    ProgressCallback? onProgress,
  }) async {
    final notebooks = await loadNotebookSummaries();
    final client = await _client();
    final parser = BackupParser();
    final session = _timestamp();
    final backupRoot = await _configuredBackupDir();
    final now = DateTime.now().toUtc();
    final year = now.year.toString().padLeft(4, '0');
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final runDir = Directory(_join(backupRoot.path, 'runs', year, month, day));
    await runDir.create(recursive: true);

    final records = <BackupRecord>[];
    final outcomes = <BackupNotebookOutcome>[];
    final runLog = <String>[];
    void emit(String message) {
      runLog.add(message);
      onProgress?.call(message);
    }

    for (var index = 0; index < notebooks.length; index++) {
      final notebook = notebooks[index];
      final queueIndex = index + 1;
      final startedAt = DateTime.now().toUtc();
      Directory? notebookDir;
      try {
        emit('Queued $queueIndex/${notebooks.length}: ${notebook.name}');
        emit('Downloading ${notebook.name}');
        notebookDir = Directory(
          _join(
            backupRoot.path,
            'notebooks',
            _safeName(notebook.name),
            year,
            month,
            day,
            session,
          ),
        );
        await notebookDir.create(recursive: true);
        final archive = File(_join(notebookDir.path, 'notebook.7z'));
        await client.downloadNotebookBackup(
          notebook: notebook,
          destination: archive,
        );

        emit('Extracting ${notebook.name}');
        final extracted = Directory(_join(notebookDir.path, 'extracted'));
        await _extractArchive(archive, extracted);

        emit('Indexing ${notebook.name}');
        final renderNotebook = await parser.parseExtractedBackup(
          extractedDir: extracted,
          archivePath: _relativeTo(backupRoot.path, archive.path),
          backupRootPath: backupRoot.path,
        );
        emit('Verifying full-size originals for ${notebook.name}');
        final originalsManifest = File(
          _join(notebookDir.path, 'original_files_manifest.json'),
        );
        final contentVerification = await parser.verifyOriginalContents(
          extractedDir: extracted,
          archive: archive,
          manifestFile: originalsManifest,
          manifestPath: _relativeTo(backupRoot.path, originalsManifest.path),
        );
        if (!contentVerification.isComplete) {
          throw StateError(
            'Original attachment verification failed for ${notebook.name}: ${_verificationFailureSummary(contentVerification)}',
          );
        }
        final renderFile = File(
          _join(notebookDir.path, 'render_notebook.json'),
        );
        await renderFile.writeAsString(renderNotebook.toPrettyJson());

        var record = BackupRecord(
          id: '${session}_${_safeName(notebook.name)}',
          notebookName: renderNotebook.name == 'Untitled notebook'
              ? notebook.name
              : renderNotebook.name,
          createdAt: DateTime.now().toUtc(),
          archivePath: _relativeTo(backupRoot.path, archive.path),
          renderPath: _relativeTo(backupRoot.path, renderFile.path),
          pageCount: renderNotebook.nodes.where((node) => node.isPage).length,
          contentVerification: contentVerification,
        );
        emit('Writing readable search copy for ${notebook.name}');
        final readable = await ReadableNotebookExporter().write(
          record: record,
          notebook: renderNotebook,
          runDir: notebookDir,
          backupRootPath: backupRoot.path,
        );
        record = record.copyWith(
          readablePath: readable.markdownPath,
          searchIndexPath: readable.searchIndexPath,
        );
        emit('Sealing integrity manifest for ${notebook.name}');
        record = await sealBackupIntegrity(record);
        records.add(record);
        outcomes.add(
          BackupNotebookOutcome(
            notebookName: record.notebookName,
            status: BackupOutcomeStatus.success,
            category: BackupFailureCategory.none,
            message: 'Backed up successfully.',
            backupRecordId: record.id,
            queueIndex: queueIndex,
            totalQueueCount: notebooks.length,
            startedAt: startedAt,
            completedAt: DateTime.now().toUtc(),
            pageCount: record.pageCount,
            archiveBytes: contentVerification.archiveBytes,
            verifiedOriginalAttachmentCount:
                contentVerification.verifiedOriginalAttachmentCount,
            expectedOriginalAttachmentCount:
                contentVerification.expectedOriginalAttachmentCount,
          ),
        );
        emit('Finished ${notebook.name}');
      } catch (error) {
        if (notebookDir != null && await notebookDir.exists()) {
          await notebookDir.delete(recursive: true);
        }
        final failure = _classifyBackupError(error);
        outcomes.add(
          BackupNotebookOutcome(
            notebookName: notebook.name,
            status: BackupOutcomeStatus.skipped,
            category: failure.category,
            message: failure.message,
            nextAction: failure.nextAction,
            queueIndex: queueIndex,
            totalQueueCount: notebooks.length,
            startedAt: startedAt,
            completedAt: DateTime.now().toUtc(),
          ),
        );
        emit('Skipped ${notebook.name}: ${failure.message}');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await _writeRunManifest(
      runDir: runDir,
      session: session,
      records: records,
      createdAt: now,
      completedAt: DateTime.now().toUtc(),
      totalNotebookCount: notebooks.length,
      outcomes: outcomes,
      log: runLog,
    );
    if (records.isEmpty && notebooks.isNotEmpty) {
      throw StateError(
        'No notebooks could be backed up with the current user rights. At NIH/NICHD, full-size notebook backup is owner-only, and lab notebook owners are lab chiefs/PIs.',
      );
    }
    return records;
  }

  _BackupFailure _classifyBackupError(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (message.contains('code 4547') ||
        lower.contains('does not have rights')) {
      return const _BackupFailure(
        category: BackupFailureCategory.notOwner,
        message: 'Full-size backup is owner-only for this notebook.',
        nextAction:
            'At NIH/NICHD, ask the lab chief or PI owner to run the backup.',
      );
    }
    if (lower.contains('authorization failed') ||
        lower.contains('missing local credentials') ||
        lower.contains('missing labarchives uid') ||
        lower.contains('auth')) {
      return _BackupFailure(
        category: BackupFailureCategory.authorization,
        message: _oneLine(message),
        nextAction: 'Reconnect LabArchives credentials and try again.',
      );
    }
    if (lower.contains('could not extract') ||
        lower.contains('bsdtar') ||
        lower.contains('7z')) {
      return _BackupFailure(
        category: BackupFailureCategory.extraction,
        message: _oneLine(message),
        nextAction: 'Install or bundle a supported archive extractor.',
      );
    }
    if (lower.contains('original attachment verification failed')) {
      return _BackupFailure(
        category: BackupFailureCategory.verification,
        message: _oneLine(message),
        nextAction:
            'Keep the failed context in the log, then retry or review whether LabArchives omitted originals.',
      );
    }
    if (lower.contains('permission denied') ||
        lower.contains('no space') ||
        lower.contains('disk') ||
        lower.contains('not writable')) {
      return _BackupFailure(
        category: BackupFailureCategory.storage,
        message: _oneLine(message),
        nextAction: 'Choose a writable backup folder with enough free space.',
      );
    }
    if (lower.contains('socket') ||
        lower.contains('network') ||
        lower.contains('timed out') ||
        lower.contains('connection')) {
      return _BackupFailure(
        category: BackupFailureCategory.network,
        message: _oneLine(message),
        nextAction: 'Check the network connection and try again.',
      );
    }
    return _BackupFailure(
      category: BackupFailureCategory.unknown,
      message: _oneLine(message),
      nextAction: 'Review the local run log and retry when ready.',
    );
  }

  String _verificationFailureSummary(BackupContentVerification verification) {
    final pieces = <String>[
      '${verification.verifiedOriginalAttachmentCount}/${verification.expectedOriginalAttachmentCount} originals',
      '${verification.verifiedOriginalAttachmentBytes}/${verification.expectedOriginalAttachmentBytes} bytes',
    ];
    if (verification.missingOriginals.isNotEmpty) {
      pieces.add('missing ${verification.missingOriginals.take(5).join(', ')}');
    }
    if (verification.sizeMismatches.isNotEmpty) {
      pieces.add(
        'mismatched ${verification.sizeMismatches.take(5).join(', ')}',
      );
    }
    return pieces.join('; ');
  }

  Future<Map<String, Object?>> _buildIntegrityManifest({
    required BackupRecord record,
    required Directory runDir,
    required String backupRootPath,
    required String manifestPath,
  }) async {
    final files = <Map<String, Object?>>[];
    final currentPaths = await _currentProtectedPaths(
      runDir: runDir,
      backupRootPath: backupRootPath,
    );
    for (final path in currentPaths) {
      final file = await _resolveBackupFile(path);
      final stat = await file.stat();
      files.add({
        'path': path,
        'bytes': stat.size,
        'sha256': await _sha256File(file),
        'modifiedAt': stat.modified.toUtc().toIso8601String(),
      });
    }
    final totalBytes = files.fold<int>(
      0,
      (sum, file) => sum + (file['bytes'] as int? ?? 0),
    );
    return {
      'version': 1,
      'kind': 'benchvault.backup.integrity',
      'algorithm': 'sha256',
      'backupId': record.id,
      'notebookName': record.notebookName,
      'backupCreatedAt': record.createdAt.toIso8601String(),
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'manifestPath': manifestPath,
      'fileCount': files.length,
      'totalBytes': totalBytes,
      'note':
          'Tamper-evident SHA-256 seal for this local backup. It detects later byte changes to protected files, but it is not a legal certification by itself.',
      'files': files,
    };
  }

  Future<List<String>> _currentProtectedPaths({
    required Directory runDir,
    required String backupRootPath,
  }) async {
    final paths = <String>[];
    if (!await runDir.exists()) {
      return paths;
    }
    await for (final entity in runDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (name == 'integrity_manifest.json') {
        continue;
      }
      if (entity.path.split(Platform.pathSeparator).contains('audit')) {
        continue;
      }
      paths.add(_relativeTo(backupRootPath, entity.path));
    }
    paths.sort();
    return paths;
  }

  Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _appendIntegrityLedger({
    required BackupRecord record,
    required String manifestPath,
    required String manifestSha256,
    required int manifestBytes,
  }) async {
    await credentialsDir.create(recursive: true);
    String? previousEntryHash;
    if (await _integrityLedgerFile.exists()) {
      final lines = await _integrityLedgerFile.readAsLines();
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) {
          continue;
        }
        final entry = jsonDecode(line) as Map<String, Object?>;
        previousEntryHash = entry['entryHash'] as String?;
        break;
      }
    }
    final entry = <String, Object?>{
      'version': 1,
      'kind': 'benchvault.integrity.ledger',
      'backupId': record.id,
      'notebookName': record.notebookName,
      'backupCreatedAt': record.createdAt.toIso8601String(),
      'sealedAt': DateTime.now().toUtc().toIso8601String(),
      'manifestPath': manifestPath,
      'manifestSha256': manifestSha256,
      'manifestBytes': manifestBytes,
      'previousEntryHash': previousEntryHash,
    };
    entry['entryHash'] = _ledgerEntryHash(entry);
    await _integrityLedgerFile.writeAsString(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
    );
    await _setOwnerOnlyPermissions(_integrityLedgerFile);
  }

  Future<Map<String, Object?>?> _findIntegrityLedgerEntry({
    required String backupId,
    required String manifestPath,
  }) async {
    if (!await _integrityLedgerFile.exists()) {
      return null;
    }
    Map<String, Object?>? found;
    for (final line in await _integrityLedgerFile.readAsLines()) {
      if (line.trim().isEmpty) {
        continue;
      }
      final entry = jsonDecode(line) as Map<String, Object?>;
      if (entry['backupId'] == backupId &&
          entry['manifestPath'] == manifestPath) {
        found = entry;
      }
    }
    if (found == null) {
      return null;
    }
    final expectedHash = found['entryHash'];
    if (expectedHash is String && expectedHash == _ledgerEntryHash(found)) {
      return found;
    }
    return null;
  }

  String _ledgerEntryHash(Map<String, Object?> entry) {
    final canonical = Map<String, Object?>.from(entry)..remove('entryHash');
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  Future<LabArchivesClient> _client() async {
    final creds = await _loadLabArchivesCredentials();
    final user = await _loadEnv(_userFile);
    final accessId = creds['LABARCHIVES_GOV_LOGIN_ID'];
    final accessKey = creds['LABARCHIVES_GOV_ACCESS_KEY'];
    final uid = user['LABARCHIVES_GOV_UID'];
    if (accessId == null || accessKey == null || uid == null) {
      throw StateError(
        'Missing local credentials or UID. Run the local auth helper first.',
      );
    }
    return LabArchivesClient(
      accessId: accessId,
      accessKey: accessKey,
      uid: uid,
    );
  }

  Future<Map<String, String>> _loadLabArchivesCredentials() async {
    if (_secretStore.isAvailable) {
      final accessId = await _readSecret(
        service: BenchVaultSecretServices.labArchives,
        account: BenchVaultSecretAccounts.labArchivesAccessId,
      );
      final accessKey = await _readSecret(
        service: BenchVaultSecretServices.labArchives,
        account: BenchVaultSecretAccounts.labArchivesAccessKey,
      );
      if (accessId != null &&
          accessId.trim().isNotEmpty &&
          accessKey != null &&
          accessKey.trim().isNotEmpty) {
        return {
          'LABARCHIVES_GOV_LOGIN_ID': accessId,
          'LABARCHIVES_GOV_ACCESS_KEY': accessKey,
        };
      }
    }

    final creds = await _loadEnv(_credentialFile);
    final accessId = creds['LABARCHIVES_GOV_LOGIN_ID'];
    final accessKey = creds['LABARCHIVES_GOV_ACCESS_KEY'];
    if (_secretStore.isAvailable &&
        accessId != null &&
        accessId.isNotEmpty &&
        accessKey != null &&
        accessKey.isNotEmpty) {
      await _writeLabArchivesSecrets(accessId: accessId, accessKey: accessKey);
      await _writeLabArchivesCredentialMetadata(
        email: creds['LABARCHIVES_GOV_EMAIL'],
      );
    }
    return creds;
  }

  Future<bool> _hasSecureLabArchivesCredentials() async {
    if (!_secretStore.isAvailable) {
      return false;
    }
    final accessId = await _readSecret(
      service: BenchVaultSecretServices.labArchives,
      account: BenchVaultSecretAccounts.labArchivesAccessId,
    );
    final accessKey = await _readSecret(
      service: BenchVaultSecretServices.labArchives,
      account: BenchVaultSecretAccounts.labArchivesAccessKey,
    );
    return accessId != null &&
        accessId.trim().isNotEmpty &&
        accessKey != null &&
        accessKey.trim().isNotEmpty;
  }

  Future<bool> _hasLabArchivesCredentialFileSecrets() async {
    if (!await _credentialFile.exists()) {
      return false;
    }
    try {
      final values = await _loadEnv(_credentialFile);
      return (values['LABARCHIVES_GOV_LOGIN_ID'] ?? '').isNotEmpty &&
          (values['LABARCHIVES_GOV_ACCESS_KEY'] ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _readSecret({
    required String service,
    required String account,
  }) async {
    try {
      return await _secretStore.read(service: service, account: account);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSecret({
    required String service,
    required String account,
    required String value,
  }) async {
    await _secretStore.write(service: service, account: account, value: value);
  }

  Future<void> _deleteSecret({
    required String service,
    required String account,
  }) async {
    try {
      await _secretStore.delete(service: service, account: account);
    } catch (_) {
      return;
    }
  }

  Future<void> _writeLabArchivesSecrets({
    required String accessId,
    required String accessKey,
  }) async {
    await _writeSecret(
      service: BenchVaultSecretServices.labArchives,
      account: BenchVaultSecretAccounts.labArchivesAccessId,
      value: accessId,
    );
    await _writeSecret(
      service: BenchVaultSecretServices.labArchives,
      account: BenchVaultSecretAccounts.labArchivesAccessKey,
      value: accessKey,
    );
  }

  Future<void> _writeLabArchivesCredentialMetadata({String? email}) async {
    await credentialsDir.create(recursive: true);
    await _credentialFile.writeAsString(
      [
        'LABARCHIVES_GOV_CREDENTIAL_STORAGE=${_secretStore.storageLabel}',
        if (email != null && email.trim().isNotEmpty)
          'LABARCHIVES_GOV_EMAIL=${email.trim()}',
        '',
      ].join('\n'),
    );
    await _setOwnerOnlyPermissions(_credentialFile);
  }

  Future<String> _openAiModelFromFile() async {
    if (!await _openAiSearchFile.exists()) {
      return OpenAiSearchSettings.defaultModel;
    }
    try {
      final values = await _loadEnv(_openAiSearchFile);
      final model = values['OPENAI_MODEL'] ?? OpenAiSearchSettings.defaultModel;
      return model.trim().isEmpty ? OpenAiSearchSettings.defaultModel : model;
    } catch (_) {
      return OpenAiSearchSettings.defaultModel;
    }
  }

  Future<void> _writeOpenAiMetadata(String model) async {
    await credentialsDir.create(recursive: true);
    await _openAiSearchFile.writeAsString(
      [
        'OPENAI_KEY_STORAGE=${_secretStore.storageLabel}',
        'OPENAI_MODEL=$model',
        '',
      ].join('\n'),
    );
    await _setOwnerOnlyPermissions(_openAiSearchFile);
  }

  String _credentialStorageLabel() {
    return _secretStore.isAvailable
        ? _secretStore.storageLabel
        : 'local-only setup files';
  }

  Future<Map<String, String>> _loadEnv(File file) async {
    if (!await file.exists()) {
      throw StateError('Missing ${_relative(file.path)}.');
    }
    final values = <String, String>{};
    for (final rawLine in await file.readAsLines()) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || !line.contains('=')) {
        continue;
      }
      final index = line.indexOf('=');
      values[line.substring(0, index).trim()] = line
          .substring(index + 1)
          .trim();
    }
    return values;
  }

  LabArchivesSetupInput _validatedSetupInput(LabArchivesSetupInput input) {
    final email = input.email.trim();
    final accessId = input.accessId.trim();
    final accessKey = input.accessKey.trim();
    final backupRootPath = input.backupRootPath.trim();
    if (email.isEmpty || accessId.isEmpty || accessKey.isEmpty) {
      throw StateError('Enter email, access ID, and access key.');
    }
    if (backupRootPath.isEmpty) {
      throw StateError('Choose a backup folder.');
    }
    return LabArchivesSetupInput(
      email: email,
      accessId: accessId,
      accessKey: accessKey,
      backupRootPath: backupRootPath,
      authCode: input.authCode?.trim(),
      openAiApiKey: input.openAiApiKey?.trim(),
      openAiModel: input.openAiModel?.trim(),
    );
  }

  Future<Map<String, String>> _waitForAuthCallback(HttpServer server) async {
    await for (final request in server) {
      final uri = request.uri;
      if (uri.path != '/labarchives_callback') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not found');
        await request.response.close();
        continue;
      }
      request.response.headers.contentType = ContentType.text;
      request.response.write(
        'LabArchives authorization captured. You can return to BenchVault.',
      );
      await request.response.close();
      return uri.queryParameters;
    }
    throw StateError('Authorization callback closed before completion.');
  }

  Future<bool> _openExternalUrl(String url) async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('open', [url]);
        return result.exitCode == 0;
      }
      if (Platform.isWindows) {
        final result = await Process.run('rundll32', [
          'url.dll,FileProtocolHandler',
          url,
        ]);
        return result.exitCode == 0;
      }
      if (Platform.isLinux) {
        final result = await Process.run('xdg-open', [url]);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<void> _persistSetup(
    LabArchivesSetupInput input,
    UserAccessSnapshot snapshot,
  ) async {
    await credentialsDir.create(recursive: true);
    if (_secretStore.isAvailable) {
      await _writeLabArchivesSecrets(
        accessId: input.accessId,
        accessKey: input.accessKey,
      );
      await _writeLabArchivesCredentialMetadata(email: input.email);
    } else {
      await _credentialFile.writeAsString(
        [
          'LABARCHIVES_GOV_LOGIN_ID=${input.accessId}',
          'LABARCHIVES_GOV_ACCESS_KEY=${input.accessKey}',
          'LABARCHIVES_GOV_EMAIL=${input.email}',
          '',
        ].join('\n'),
      );
      await _setOwnerOnlyPermissions(_credentialFile);
    }

    await _userFile.writeAsString(
      [
        'LABARCHIVES_GOV_UID=${snapshot.uid}',
        'LABARCHIVES_GOV_EMAIL=${input.email}',
        '',
      ].join('\n'),
    );
    await _setOwnerOnlyPermissions(_userFile);

    final accessInfoFile = File(
      _join(credentialsDir.path, 'user_access_info.xml'),
    );
    await accessInfoFile.writeAsString(snapshot.rawXml);
    await _setOwnerOnlyPermissions(accessInfoFile);

    final notebookRows = <String>['name\tnbid\tis_default'];
    for (final notebook in snapshot.notebooks) {
      notebookRows.add(
        '${_tsv(notebook.name)}\t${_tsv(notebook.nbid)}\t${notebook.isDefault}',
      );
    }
    await _notebooksFile.writeAsString('${notebookRows.join('\n')}\n');
    await _setOwnerOnlyPermissions(_notebooksFile);

    final currentSettings = await loadBackupSettings();
    await saveBackupSettings(
      currentSettings.copyWith(backupRootPath: input.backupRootPath),
    );
    final openAiApiKey = input.openAiApiKey?.trim() ?? '';
    if (openAiApiKey.isNotEmpty) {
      await saveOpenAiSearchSettings(
        OpenAiSearchSettings(
          apiKey: openAiApiKey,
          model: input.openAiModel?.trim().isNotEmpty == true
              ? input.openAiModel!.trim()
              : OpenAiSearchSettings.defaultModel,
        ),
      );
    }
  }

  Future<Directory> _configuredBackupDir() async {
    final settings = await loadBackupSettings();
    return Directory(settings.backupRootPath).absolute;
  }

  Future<List<Directory>> _backupSearchDirs() async {
    final configured = await _configuredBackupDir();
    final legacy = backupDir.absolute;
    if (configured.path == legacy.path) {
      return [configured];
    }
    return [configured, legacy];
  }

  Future<Directory> _backupRootForFile(File file) async {
    final normalizedPath = file.absolute.path;
    for (final directory in await _backupSearchDirs()) {
      final normalizedRoot = directory.absolute.path;
      if (normalizedPath.startsWith(normalizedRoot)) {
        return directory.absolute;
      }
    }
    return root.absolute;
  }

  Future<File> _resolveBackupFile(String path) async {
    final file = File(path);
    if (file.isAbsolute) {
      return file;
    }
    final rootFile = File(_join(root.path, path));
    if (await rootFile.exists()) {
      return rootFile;
    }
    for (final directory in await _backupSearchDirs()) {
      final candidate = File(_join(directory.path, path));
      if (await candidate.exists()) {
        return candidate;
      }
    }
    return rootFile;
  }

  Future<File?> _resolveOriginalAttachment(
    BackupRecord record,
    RenderPart part,
  ) async {
    final originalPath = part.attachmentOriginalPath;
    if (originalPath != null && originalPath.trim().isNotEmpty) {
      final file = await _resolveBackupFile(originalPath);
      if (await file.exists()) {
        return file;
      }
    }

    final attachmentName = part.attachmentName;
    if (attachmentName == null || attachmentName.trim().isEmpty) {
      return null;
    }
    final renderFile = await _resolveBackupFile(record.renderPath);
    final runDir = renderFile.parent;
    final direct = File(
      _join(
        runDir.path,
        'extracted',
        'notebook',
        'attachments',
        part.id.toString(),
        '1',
        'original',
        attachmentName,
      ),
    );
    if (await direct.exists()) {
      return direct;
    }

    final partRoot = Directory(
      _join(
        runDir.path,
        'extracted',
        'notebook',
        'attachments',
        part.id.toString(),
      ),
    );
    if (!await partRoot.exists()) {
      return null;
    }
    await for (final entity in partRoot.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final segments = entity.path.split(Platform.pathSeparator);
      if (segments.contains('original') && segments.last == attachmentName) {
        return entity;
      }
    }
    return null;
  }

  Future<void> _writeRunManifest({
    required Directory runDir,
    required String session,
    required List<BackupRecord> records,
    required DateTime createdAt,
    required DateTime completedAt,
    required int totalNotebookCount,
    required List<BackupNotebookOutcome> outcomes,
    required List<String> log,
  }) async {
    final manifest = File(_join(runDir.path, '$session.json'));
    final run = BackupRunManifest(
      id: session,
      createdAt: createdAt,
      completedAt: completedAt,
      totalNotebookCount: totalNotebookCount,
      outcomes: outcomes,
      records: records,
      log: log,
    );
    await manifest.writeAsString(
      const JsonEncoder.withIndent('  ').convert(run.toJson()),
    );
  }

  UserAccessSnapshot _parseUserAccessInfo(String xml) {
    final uid = _xmlText(xml, 'id');
    if (uid == null || uid.isEmpty) {
      throw StateError(
        'LabArchives user access response did not include a UID.',
      );
    }
    final notebooksSection =
        RegExp(
          r'<notebooks(?:\s[^>]*)?>(.*?)</notebooks>',
          dotAll: true,
          caseSensitive: false,
        ).firstMatch(xml)?.group(1) ??
        '';
    final notebooks = <NotebookAccess>[];
    final notebookMatches = RegExp(
      r'<notebook(?:\s[^>]*)?>(.*?)</notebook>',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(notebooksSection);
    for (final match in notebookMatches) {
      final block = match.group(1) ?? '';
      final nbid = _xmlText(block, 'id');
      if (nbid == null || nbid.isEmpty) {
        continue;
      }
      final name =
          _xmlText(block, 'name') ??
          _xmlText(block, 'notebook-name') ??
          'Notebook $nbid';
      final isDefaultText =
          (_xmlText(block, 'is-default') ?? _xmlText(block, 'is_default') ?? '')
              .toLowerCase();
      notebooks.add(
        NotebookAccess(
          name: name,
          nbid: nbid,
          isDefault: isDefaultText == 'true' || isDefaultText == '1',
        ),
      );
    }
    return UserAccessSnapshot(uid: uid, notebooks: notebooks, rawXml: xml);
  }

  String? _xmlText(String xml, String tag) {
    final match = RegExp(
      '<$tag(?:\\s[^>]*)?>(.*?)</$tag>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(xml);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return _decodeXml(value.replaceAll(RegExp(r'<[^>]+>'), '').trim());
  }

  String _decodeXml(String value) {
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  String _tsv(String value) {
    return value.replaceAll('\t', ' ').replaceAll(RegExp(r'[\r\n]+'), ' ');
  }

  Future<void> _setOwnerOnlyPermissions(File file) async {
    if (Platform.isWindows) {
      return;
    }
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {
      return;
    }
  }

  Future<void> _extractArchive(File archive, Directory destination) async {
    if (await destination.exists()) {
      await destination.delete(recursive: true);
    }
    await destination.create(recursive: true);
    final attempts = <List<String>>[
      ['bsdtar', '-xf', archive.path, '-C', destination.path],
      ['tar', '-xf', archive.path, '-C', destination.path],
      ['7z', 'x', '-y', '-o${destination.path}', archive.path],
    ];
    final errors = <String>[];
    for (final command in attempts) {
      try {
        final result = await Process.run(
          command.first,
          command.skip(1).toList(),
        );
        if (result.exitCode == 0) {
          return;
        }
        errors.add('${command.first}: ${result.stderr}');
      } catch (error) {
        errors.add('${command.first}: $error');
      }
    }
    throw StateError(
      'Could not extract ${archive.path}. ${errors.join(' | ')}',
    );
  }

  String _relative(String path) {
    return _relativeTo(root.absolute.path, path);
  }

  String _relativeTo(String base, String path) {
    final normalizedBase = Directory(base).absolute.path;
    final normalizedRoot = root.absolute.path;
    final normalizedPath = File(path).absolute.path;
    if (normalizedPath.startsWith(normalizedBase)) {
      final relative = normalizedPath.substring(normalizedBase.length);
      return relative.startsWith(Platform.pathSeparator)
          ? relative.substring(1)
          : relative;
    }
    if (normalizedPath.startsWith(normalizedRoot)) {
      final relative = normalizedPath.substring(normalizedRoot.length);
      return relative.startsWith(Platform.pathSeparator)
          ? relative.substring(1)
          : relative;
    }
    return path;
  }

  String _timestamp() {
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}Z';
  }

  String _safeName(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'notebook' : cleaned;
  }

  String _safeAttachmentFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/\x00-\x1F]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    return cleaned.isEmpty ? 'attachment' : cleaned;
  }

  Future<File> _uniqueDestinationFile(
    Directory destination,
    String fileName,
  ) async {
    final dot = fileName.lastIndexOf('.');
    final hasExtension = dot > 0 && dot < fileName.length - 1;
    final stem = hasExtension ? fileName.substring(0, dot) : fileName;
    final extension = hasExtension ? fileName.substring(dot) : '';
    for (var index = 0; index < 10000; index++) {
      final candidateName = index == 0
          ? fileName
          : '$stem (${index.toString()})$extension';
      final candidate = File(_join(destination.path, candidateName));
      if (!await candidate.exists()) {
        return candidate;
      }
    }
    throw StateError('Could not choose a unique restored attachment name.');
  }
}

Directory _findProjectRoot() {
  final configuredRoot = Platform.environment['BENCHVAULT_PROJECT_ROOT'];
  if (configuredRoot != null && configuredRoot.trim().isNotEmpty) {
    return Directory(configuredRoot).absolute;
  }

  var current = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File(_join(current.path, 'pubspec.yaml')).existsSync() &&
        File(
          _join(
            current.path,
            'docs',
            'developer',
            'labarchives_gov_api_reference.md',
          ),
        ).existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    if (Platform.isMacOS) {
      return Directory(
        _join(home, 'Library', 'Application Support', 'BenchVault'),
      ).absolute;
    }
    return Directory(_join(home, '.benchvault')).absolute;
  }
  return Directory.current.absolute;
}

String _join(
  String first, [
  String? second,
  String? third,
  String? fourth,
  String? fifth,
  String? sixth,
  String? seventh,
  String? eighth,
]) {
  final parts = <String>[first];
  for (final part in [second, third, fourth, fifth, sixth, seventh, eighth]) {
    if (part != null && part.isNotEmpty) {
      parts.add(part);
    }
  }
  return parts.join(Platform.pathSeparator);
}

String _oneLine(String value) {
  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _csv(String value) {
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}
