import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backup_models.dart';
import 'backup_parser.dart';
import 'labarchives_client.dart';
import 'setup_models.dart';

typedef ProgressCallback = void Function(String message);

class BackupService {
  BackupService({Directory? root}) : root = root ?? _findProjectRoot();

  final Directory root;

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
      File(_join(credentialsDir.path, 'elnla_settings.json'));

  Future<LocalSetupStatus> loadSetupStatus() async {
    var notebookCount = 0;
    if (await _notebooksFile.exists()) {
      final lines = await _notebooksFile.readAsLines();
      notebookCount = lines.length > 1 ? lines.length - 1 : 0;
    }
    return LocalSetupStatus(
      hasCredentials: await _credentialFile.exists(),
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

  Future<RenderNotebook> loadRenderNotebook(BackupRecord record) async {
    final file = await _resolveBackupFile(record.renderPath);
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return RenderNotebook.fromJson(json);
  }

  Future<List<BackupRecord>> backupAllNotebooks({
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
    for (final notebook in notebooks) {
      Directory? notebookDir;
      try {
        onProgress?.call('Downloading ${notebook.name}');
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

        onProgress?.call('Extracting ${notebook.name}');
        final extracted = Directory(_join(notebookDir.path, 'extracted'));
        await _extractArchive(archive, extracted);

        onProgress?.call('Indexing ${notebook.name}');
        final renderNotebook = await parser.parseExtractedBackup(
          extractedDir: extracted,
          archivePath: _relativeTo(backupRoot.path, archive.path),
        );
        final renderFile = File(
          _join(notebookDir.path, 'render_notebook.json'),
        );
        await renderFile.writeAsString(renderNotebook.toPrettyJson());

        final record = BackupRecord(
          id: '${session}_${_safeName(notebook.name)}',
          notebookName: renderNotebook.name == 'Untitled notebook'
              ? notebook.name
              : renderNotebook.name,
          createdAt: DateTime.now().toUtc(),
          archivePath: _relativeTo(backupRoot.path, archive.path),
          renderPath: _relativeTo(backupRoot.path, renderFile.path),
          pageCount: renderNotebook.nodes.where((node) => node.isPage).length,
        );
        final recordFile = File(_join(notebookDir.path, 'backup_record.json'));
        await recordFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(record.toJson()),
        );
        records.add(record);
        onProgress?.call('Finished ${notebook.name}');
      } catch (error) {
        if (notebookDir != null && await notebookDir.exists()) {
          await notebookDir.delete(recursive: true);
        }
        onProgress?.call('Skipped ${notebook.name}: $error');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await _writeRunManifest(
      runDir: runDir,
      session: session,
      records: records,
      createdAt: now,
    );
    if (records.isEmpty && notebooks.isNotEmpty) {
      throw StateError(
        'No notebooks could be backed up with the current user rights.',
      );
    }
    return records;
  }

  Future<LabArchivesClient> _client() async {
    final creds = await _loadEnv(_credentialFile);
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
        'LabArchives authorization captured. You can return to ELNLA.',
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
    await _credentialFile.writeAsString(
      [
        'LABARCHIVES_GOV_LOGIN_ID=${input.accessId}',
        'LABARCHIVES_GOV_ACCESS_KEY=${input.accessKey}',
        'LABARCHIVES_GOV_EMAIL=${input.email}',
        '',
      ].join('\n'),
    );
    await _setOwnerOnlyPermissions(_credentialFile);

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

  Future<void> _writeRunManifest({
    required Directory runDir,
    required String session,
    required List<BackupRecord> records,
    required DateTime createdAt,
  }) async {
    final manifest = File(_join(runDir.path, '$session.json'));
    await manifest.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'id': session,
        'createdAt': createdAt.toIso8601String(),
        'notebookCount': records.length,
        'records': records.map((record) => record.toJson()).toList(),
      }),
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
}

Directory _findProjectRoot() {
  final configuredRoot = Platform.environment['ELNLA_PROJECT_ROOT'];
  if (configuredRoot != null && configuredRoot.trim().isNotEmpty) {
    return Directory(configuredRoot).absolute;
  }

  var current = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File(_join(current.path, 'pubspec.yaml')).existsSync() &&
        File(
          _join(current.path, 'labarchives_gov_api_reference.md'),
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
        _join(home, 'Library', 'Application Support', 'ELNLA'),
      ).absolute;
    }
    return Directory(_join(home, '.elnla')).absolute;
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
