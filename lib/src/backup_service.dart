import 'dart:convert';
import 'dart:io';

import 'backup_models.dart';
import 'backup_parser.dart';
import 'labarchives_client.dart';

typedef ProgressCallback = void Function(String message);

class BackupService {
  BackupService({Directory? root}) : root = root ?? _findProjectRoot();

  final Directory root;

  Directory get credentialsDir =>
      Directory(_join(root.path, 'local_credentials'));

  Directory get backupDir => Directory(_join(root.path, 'backups'));

  File get _credentialFile =>
      File(_join(credentialsDir.path, 'labarchives.env'));

  File get _userFile =>
      File(_join(credentialsDir.path, 'labarchives_user.env'));

  File get _notebooksFile => File(_join(credentialsDir.path, 'notebooks.tsv'));

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
    if (!await backupDir.exists()) {
      return const [];
    }
    final records = <BackupRecord>[];
    await for (final entity in backupDir.list(
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
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records;
  }

  Future<RenderNotebook> loadRenderNotebook(BackupRecord record) async {
    final file = File(_absolute(record.renderPath));
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
    final sessionDir = Directory(_join(backupDir.path, session));
    await sessionDir.create(recursive: true);

    final records = <BackupRecord>[];
    for (final notebook in notebooks) {
      try {
        onProgress?.call('Downloading ${notebook.name}');
        final notebookDir = Directory(
          _join(sessionDir.path, _safeName(notebook.name)),
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
          archivePath: _relative(archive.path),
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
          archivePath: _relative(archive.path),
          renderPath: _relative(renderFile.path),
          pageCount: renderNotebook.nodes.where((node) => node.isPage).length,
        );
        final recordFile = File(_join(notebookDir.path, 'backup_record.json'));
        await recordFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(record.toJson()),
        );
        records.add(record);
        onProgress?.call('Finished ${notebook.name}');
      } catch (error) {
        onProgress?.call('Skipped ${notebook.name}: $error');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
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
    final normalizedRoot = root.absolute.path;
    final normalizedPath = File(path).absolute.path;
    if (normalizedPath.startsWith(normalizedRoot)) {
      final relative = normalizedPath.substring(normalizedRoot.length);
      return relative.startsWith(Platform.pathSeparator)
          ? relative.substring(1)
          : relative;
    }
    return path;
  }

  String _absolute(String path) {
    if (File(path).isAbsolute) {
      return path;
    }
    return _join(root.path, path);
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

String _join(String first, [String? second, String? third, String? fourth]) {
  final parts = <String>[first];
  for (final part in [second, third, fourth]) {
    if (part != null && part.isNotEmpty) {
      parts.add(part);
    }
  }
  return parts.join(Platform.pathSeparator);
}
