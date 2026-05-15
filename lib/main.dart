import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/backup_models.dart';
import 'src/backup_service.dart';
import 'src/attachment_format_support.dart';
import 'src/notebook_search_service.dart';
import 'src/search_models.dart';
import 'src/setup_models.dart';

const _nihBlue = Color(0xff005ea2);
const _nihBlueDark = Color(0xff162e51);
const _nihBlueLightest = Color(0xffe5faff);
const _nihGold = Color(0xffface00);
const _nihGoldLight = Color(0xfffff5c2);
const _nihCoolAccent = Color(0xff1dc2ae);
const _nihSurface = Color(0xfffbfcfd);
const _nihSuccess = Color(0xff0f6460);

void main() {
  runApp(const ElnlaApp());
}

class ElnlaApp extends StatelessWidget {
  const ElnlaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _nihBlue,
          brightness: Brightness.light,
        ).copyWith(
          primary: _nihBlue,
          onPrimary: Colors.white,
          primaryContainer: _nihBlueLightest,
          onPrimaryContainer: _nihBlueDark,
          secondary: _nihGold,
          onSecondary: const Color(0xff1c1d1f),
          secondaryContainer: _nihGoldLight,
          onSecondaryContainer: _nihBlueDark,
          tertiary: _nihCoolAccent,
          surface: _nihSurface,
        );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ELNLA',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        scaffoldBackgroundColor: _nihSurface,
        appBarTheme: const AppBarTheme(
          backgroundColor: _nihBlueDark,
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _nihBlue,
            foregroundColor: Colors.white,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: scheme.primary, width: 2),
          ),
        ),
      ),
      home: const ElnlaHome(),
    );
  }
}

class ElnlaHome extends StatefulWidget {
  const ElnlaHome({super.key});

  @override
  State<ElnlaHome> createState() => _ElnlaHomeState();
}

class _ElnlaHomeState extends State<ElnlaHome> {
  late final BackupService _service;
  Future<void>? _loader;
  List<NotebookSummary> _notebooks = const [];
  List<BackupRecord> _backups = const [];
  BackupRecord? _selectedBackup;
  RenderNotebook? _selectedNotebook;
  RenderNode? _selectedNode;
  BackupIntegrityCheck? _integrityCheck;
  LocalSetupStatus? _setupStatus;
  BackupSchedule _schedule = BackupSchedule.disabled();
  String _backupRootPath = '';
  Timer? _scheduleTimer;
  DateTime? _nextAutomaticBackup;
  String _status = 'Loading local LabArchives context...';
  final List<String> _log = <String>[];
  final _searchController = TextEditingController();
  NotebookSearchResult? _searchResult;
  bool _openAiSearchReady = false;
  bool _busy = false;
  bool _setupBusy = false;
  bool _restoreBusy = false;
  bool _searchBusy = false;
  bool _integrityBusy = false;

  @override
  void initState() {
    super.initState();
    _service = BackupService();
    _backupRootPath = _service.defaultBackupRootPath;
    _loader = _demoMode ? _loadDemo() : _refresh();
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_demoMode) {
      await _loadDemo();
      return;
    }
    try {
      final setupStatus = await _service.loadSetupStatus();
      final backupSettings = await _service.loadBackupSettings();
      final openAiSettings = await _service.loadOpenAiSearchSettings();
      final notebooks = setupStatus.hasNotebookIndex
          ? await _service.loadNotebookSummaries()
          : <NotebookSummary>[];
      final backups = await _service.loadBackups();
      setState(() {
        _setupStatus = setupStatus;
        _schedule = backupSettings.schedule;
        _backupRootPath = backupSettings.backupRootPath;
        _notebooks = notebooks;
        _backups = backups;
        _selectedBackup = backups.isEmpty ? null : backups.first;
        _openAiSearchReady = openAiSettings?.hasApiKey ?? false;
        _status = !setupStatus.isReady
            ? 'Setup needed: connect LabArchives credentials.'
            : notebooks.isEmpty
            ? 'No notebooks found. Run the local auth helper first.'
            : 'Ready: ${notebooks.length} notebook${notebooks.length == 1 ? '' : 's'} available.';
        _rescheduleAutomaticBackup();
      });
      if (_selectedBackup != null) {
        await _selectBackup(_selectedBackup!);
      }
    } catch (error) {
      setState(() {
        _status = 'Setup needed: $error';
        _openAiSearchReady = false;
        _setupStatus = const LocalSetupStatus(
          hasCredentials: false,
          hasUserAccess: false,
          hasNotebookIndex: false,
          notebookCount: 0,
        );
      });
    }
  }

  Future<void> _loadDemo() async {
    final notebook = _demoNotebook();
    final backup = BackupRecord(
      id: 'demo_20260514_090000Z',
      notebookName: notebook.name,
      createdAt: DateTime.utc(2026, 5, 14, 9),
      archivePath:
          'notebooks/demo_immunology_notebook/2026/05/14/demo_20260514_090000Z/notebook.7z',
      renderPath:
          'notebooks/demo_immunology_notebook/2026/05/14/demo_20260514_090000Z/render_notebook.json',
      pageCount: notebook.nodes.where((node) => node.isPage).length,
      contentVerification: const BackupContentVerification(
        archiveBytes: 212209,
        expectedOriginalAttachmentCount: 15,
        verifiedOriginalAttachmentCount: 15,
        expectedOriginalAttachmentBytes: 2591,
        verifiedOriginalAttachmentBytes: 2591,
        manifestPath:
            'notebooks/demo_immunology_notebook/2026/05/14/demo_20260514_090000Z/original_files_manifest.json',
        missingOriginals: [],
        sizeMismatches: [],
      ),
    );
    setState(() {
      _setupStatus = const LocalSetupStatus(
        hasCredentials: true,
        hasUserAccess: true,
        hasNotebookIndex: true,
        notebookCount: 1,
      );
      _schedule = const BackupSchedule(
        enabled: true,
        frequency: BackupFrequency.daily,
        minutesAfterMidnight: 7 * 60 + 30,
        weekday: DateTime.monday,
      );
      _backupRootPath = 'ELNLA_Backups';
      _notebooks = const [
        NotebookSummary(
          name: 'Demo Immunology Notebook',
          nbid: 'demo',
          isDefault: true,
        ),
      ];
      _backups = [backup];
      _selectedBackup = backup;
      _selectedNotebook = notebook;
      _selectedNode = _demoSearchMode
          ? notebook.nodes.firstWhere(
              (node) => node.title == 'Mixed file attachments',
              orElse: () => notebook.firstPage!,
            )
          : notebook.firstPage;
      _integrityCheck = BackupIntegrityCheck(
        backupId: 'demo_20260514_090000Z',
        checkedAt: DateTime.utc(2026, 5, 14, 9),
        hasManifest: false,
        hasLocalSeal: false,
        manifestPath: null,
        checkedFileCount: 0,
        checkedBytes: 0,
      );
      _openAiSearchReady = _demoSearchMode;
      if (_demoSearchMode) {
        _searchController.text =
            'Which backed-up records contain qPCR results and original payloads?';
        _searchResult = _demoOpenAiSearchResult();
      }
      _log
        ..clear()
        ..addAll([
          'Finished Demo Immunology Notebook',
          'Verifying full-size originals for Demo Immunology Notebook',
          'Indexing Demo Immunology Notebook',
          'Extracting Demo Immunology Notebook',
        ]);
      _status = 'Demo mode: full-size original backup verified.';
      _rescheduleAutomaticBackup();
    });
  }

  Future<void> _selectBackup(BackupRecord backup) async {
    setState(() {
      _integrityBusy = true;
      _integrityCheck = null;
    });
    final integrityCheck = await _service.verifyBackupIntegrity(backup);
    RenderNotebook? notebook;
    Object? loadError;
    try {
      notebook = await _service.loadRenderNotebook(backup);
    } catch (error) {
      loadError = error;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedBackup = backup;
      _selectedNotebook = notebook;
      _selectedNode = notebook?.firstPage;
      _integrityCheck = integrityCheck;
      _integrityBusy = false;
      if (loadError != null) {
        _status = 'Viewer could not load backup: $loadError';
      }
    });
    if (integrityCheck.needsWarning) {
      unawaited(_showIntegrityWarning(integrityCheck));
    }
  }

  Future<void> _showIntegrityWarning(BackupIntegrityCheck check) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          check.hasManifest ? Icons.warning_amber_outlined : Icons.gpp_bad,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(check.statusTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(check.summary),
                if (check.manifestPath != null) ...[
                  const SizedBox(height: 10),
                  SelectableText('Manifest: ${check.manifestPath}'),
                ],
                if (check.changedFiles.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Changed files:',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  for (final path in check.changedFiles.take(8))
                    SelectableText(path),
                ],
                if (check.missingFiles.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Missing files:',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  for (final path in check.missingFiles.take(8))
                    SelectableText(path),
                ],
                if (check.extraFiles.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Unexpected files:',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  for (final path in check.extraFiles.take(8))
                    SelectableText(path),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Review Backup'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectSearchHit(NotebookSearchHit hit) async {
    BackupRecord? backup;
    for (final candidate in _backups) {
      if (candidate.id == hit.chunk.backupId) {
        backup = candidate;
        break;
      }
    }
    if (backup == null) {
      return;
    }
    final integrityCheck = await _service.verifyBackupIntegrity(backup);
    final notebook = await _service.loadRenderNotebook(backup);
    RenderNode? node;
    for (final candidate in notebook.nodes) {
      if (candidate.id == hit.chunk.nodeId) {
        node = candidate;
        break;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedBackup = backup;
      _selectedNotebook = notebook;
      _selectedNode = node ?? notebook.firstPage;
      _integrityCheck = integrityCheck;
    });
    if (integrityCheck.needsWarning) {
      unawaited(_showIntegrityWarning(integrityCheck));
    }
  }

  Future<void> _runSearch() async {
    if (_searchBusy) {
      return;
    }
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _searchResult = const NotebookSearchResult(
          query: '',
          answer: 'Enter a notebook search question.',
          hits: [],
          usedOpenAi: false,
        );
      });
      return;
    }
    setState(() {
      _searchBusy = true;
      _status = 'Searching backed-up notebooks...';
    });
    try {
      final result = await NotebookSearchService(_service).search(query);
      if (!mounted) {
        return;
      }
      setState(() {
        _searchResult = result;
        _status = result.usedOpenAi
            ? 'Natural-language notebook search complete.'
            : 'Local fuzzy notebook search complete.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _searchResult = NotebookSearchResult(
          query: query,
          answer: 'Search failed: $error',
          hits: const [],
          usedOpenAi: false,
        );
        _status = 'Notebook search failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _searchBusy = false);
      }
    }
  }

  Future<void> _runBackup({bool automatic = false}) async {
    if (_busy || _setupBusy) {
      if (automatic && mounted) {
        setState(() {
          _status = 'Automatic backup postponed while another task is running.';
          _nextAutomaticBackup = DateTime.now().add(const Duration(minutes: 5));
          _scheduleTimer?.cancel();
          _scheduleTimer = Timer(
            _nextAutomaticBackup!.difference(DateTime.now()),
            () {
              unawaited(_runBackup(automatic: true));
            },
          );
        });
      }
      return;
    }
    setState(() {
      _busy = true;
      _log.clear();
      _status =
          '${automatic ? 'Automatic backup' : 'Backing up'} ${_notebooks.length} notebooks...';
    });
    try {
      final records = await _service.backupAllNotebooks(
        onProgress: (message) {
          if (mounted) {
            setState(() => _log.insert(0, message));
          }
        },
      );
      final backups = await _service.loadBackups();
      if (!mounted) {
        return;
      }
      setState(() {
        _backups = backups;
        _status =
            '${automatic ? 'Automatic backup complete' : 'Backup complete'}: ${records.length} notebook archive${records.length == 1 ? '' : 's'} created.';
      });
      if (records.isNotEmpty) {
        await _selectBackup(records.first);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Backup failed: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _rescheduleAutomaticBackup();
        });
      }
    }
  }

  Future<void> _downloadAttachment(RenderPart part) async {
    final backup = _selectedBackup;
    if (backup == null || _restoreBusy) {
      return;
    }
    final selectedFolder = await _chooseDirectoryPath(
      _backupRootPath.trim().isEmpty
          ? _service.defaultBackupRootPath
          : _backupRootPath,
      prompt: 'Choose attachment download folder',
    );
    if (selectedFolder == null || selectedFolder.trim().isEmpty) {
      return;
    }
    setState(() {
      _restoreBusy = true;
      _status = 'Restoring ${part.attachmentName ?? 'attachment'}...';
    });
    try {
      final restored = await _service.restoreAttachment(
        record: backup,
        part: part,
        destination: Directory(selectedFolder),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Attachment restored: ${restored.path}';
        _log.insert(0, 'Restored ${part.attachmentName ?? restored.path}');
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${restored.uri.pathSegments.last}')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _status = 'Attachment restore failed: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Attachment restore failed: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _restoreBusy = false);
      }
    }
  }

  Future<void> _connectWithBrowser(LabArchivesSetupInput input) async {
    setState(() {
      _setupBusy = true;
      _status = 'Waiting for LabArchives authorization...';
      _log.clear();
    });
    try {
      final snapshot = await _service.authorizeWithBrowser(
        input: input,
        onLoginUrl: (url) {
          Clipboard.setData(ClipboardData(text: url));
          if (mounted) {
            setState(() => _log.insert(0, 'Login URL copied.'));
          }
        },
        onProgress: (message) {
          if (mounted) {
            setState(() => _log.insert(0, message));
          }
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Connected: ${snapshot.notebooks.length} notebook${snapshot.notebooks.length == 1 ? '' : 's'} found.';
      });
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Setup failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _setupBusy = false);
      }
    }
  }

  Future<void> _connectWithAuthCode(LabArchivesSetupInput input) async {
    setState(() {
      _setupBusy = true;
      _status = 'Exchanging LabArchives auth code...';
      _log.clear();
    });
    try {
      final snapshot = await _service.authorizeWithAuthCode(input);
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Connected: ${snapshot.notebooks.length} notebook${snapshot.notebooks.length == 1 ? '' : 's'} found.';
      });
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Setup failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _setupBusy = false);
      }
    }
  }

  Future<void> _showScheduleDialog() async {
    final updated = await showDialog<BackupSettings>(
      context: context,
      builder: (context) => _ScheduleDialog(
        initial: BackupSettings(
          schedule: _schedule,
          backupRootPath: _backupRootPath,
        ),
      ),
    );
    if (updated == null) {
      return;
    }
    await _service.saveBackupSettings(updated);
    if (!mounted) {
      return;
    }
    setState(() {
      _schedule = updated.schedule;
      _backupRootPath = updated.backupRootPath;
      _status = updated.schedule.enabled
          ? 'Automatic backup scheduled.'
          : 'Automatic backup disabled.';
      _rescheduleAutomaticBackup();
    });
  }

  Future<void> _showSearchSettingsDialog() async {
    final current =
        await _service.loadOpenAiSearchSettings() ??
        const OpenAiSearchSettings(apiKey: '');
    if (!mounted) {
      return;
    }
    final updated = await showDialog<OpenAiSearchSettings>(
      context: context,
      builder: (context) => _SearchSettingsDialog(initial: current),
    );
    if (updated == null) {
      return;
    }
    await _service.saveOpenAiSearchSettings(updated);
    if (!mounted) {
      return;
    }
    setState(() {
      _openAiSearchReady = updated.hasApiKey;
      _status = updated.hasApiKey
          ? 'OpenAI notebook search key saved locally.'
          : 'OpenAI notebook search key removed.';
    });
  }

  void _rescheduleAutomaticBackup() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _nextAutomaticBackup = null;
    if (!_schedule.enabled || !(_setupStatus?.isReady ?? false)) {
      return;
    }
    final now = DateTime.now();
    final nextRun = _schedule.nextRunAfter(now);
    _nextAutomaticBackup = nextRun;
    _scheduleTimer = Timer(nextRun.difference(now), () {
      unawaited(_runBackup(automatic: true));
    });
  }

  String? get _scheduleDetail {
    if (_backupRootPath.trim().isEmpty) {
      return null;
    }
    if (!_schedule.enabled) {
      return 'Backup folder: $_backupRootPath';
    }
    final next = _nextAutomaticBackup;
    if (next == null) {
      return 'Automatic backup waiting for setup.';
    }
    return 'Next automatic backup: ${_formatDateTime(next)} · $_backupRootPath';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loader,
      builder: (context, snapshot) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('ELNLA'),
            centerTitle: false,
            actions: [
              IconButton(
                tooltip: 'LabArchives setup',
                onPressed: _busy || _setupBusy
                    ? null
                    : () {
                        setState(() {
                          _setupStatus = const LocalSetupStatus(
                            hasCredentials: false,
                            hasUserAccess: false,
                            hasNotebookIndex: false,
                            notebookCount: 0,
                          );
                          _status =
                              'Setup needed: connect LabArchives credentials.';
                        });
                      },
                icon: const Icon(Icons.manage_accounts_outlined),
              ),
              IconButton(
                tooltip: 'Automatic backup',
                onPressed: _busy || _setupBusy ? null : _showScheduleDialog,
                icon: const Icon(Icons.schedule_outlined),
              ),
              IconButton(
                tooltip: 'Notebook search settings',
                onPressed: _busy || _setupBusy || _searchBusy
                    ? null
                    : _showSearchSettingsDialog,
                icon: Icon(
                  _openAiSearchReady
                      ? Icons.manage_search
                      : Icons.manage_search_outlined,
                ),
              ),
              IconButton(
                tooltip: 'Refresh local backups',
                onPressed: _busy || _setupBusy
                    ? null
                    : () {
                        setState(() => _loader = _refresh());
                      },
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.icon(
                onPressed: _busy || _setupBusy || _notebooks.isEmpty
                    ? null
                    : () => _runBackup(),
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.archive_outlined),
                label: const Text('Backup All'),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: Column(
            children: [
              _StatusStrip(
                status: _status,
                detail: _scheduleDetail,
                busy:
                    _busy ||
                    _setupBusy ||
                    _restoreBusy ||
                    _searchBusy ||
                    _integrityBusy,
              ),
              if (_setupStatus?.isReady ?? false)
                _IntegrityBanner(check: _integrityCheck, busy: _integrityBusy),
              if (_setupStatus?.isReady ?? false)
                _SearchPanel(
                  controller: _searchController,
                  result: _searchResult,
                  busy: _searchBusy,
                  openAiReady: _openAiSearchReady,
                  onSearch: _runSearch,
                  onSettings: _showSearchSettingsDialog,
                  onSelectHit: _selectSearchHit,
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (!(_setupStatus?.isReady ?? false)) {
                      return _CredentialSetupPanel(
                        busy: _setupBusy,
                        initialBackupRootPath: _backupRootPath,
                        onConnectBrowser: _connectWithBrowser,
                        onConnectAuthCode: _connectWithAuthCode,
                      );
                    }
                    if (constraints.maxWidth < 840) {
                      return _NarrowLayout(
                        service: _service,
                        backups: _backups,
                        selectedBackup: _selectedBackup,
                        notebook: _selectedNotebook,
                        selectedNode: _selectedNode,
                        log: _log,
                        onSelectBackup: _selectBackup,
                        onSelectNode: (node) =>
                            setState(() => _selectedNode = node),
                        onDownloadAttachment: _downloadAttachment,
                      );
                    }
                    return _WideLayout(
                      service: _service,
                      backups: _backups,
                      selectedBackup: _selectedBackup,
                      notebook: _selectedNotebook,
                      selectedNode: _selectedNode,
                      log: _log,
                      onSelectBackup: _selectBackup,
                      onSelectNode: (node) =>
                          setState(() => _selectedNode = node),
                      onDownloadAttachment: _downloadAttachment,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

bool get _demoMode => Platform.environment['ELNLA_DEMO_MODE'] == '1';

bool get _demoSearchMode => Platform.environment['ELNLA_DEMO_SEARCH'] == '1';

NotebookSearchResult _demoOpenAiSearchResult() {
  const query =
      'Which backed-up records contain qPCR results and original payloads?';
  const backupCreatedAt = '2026-05-14T09:00:00.000Z';
  return NotebookSearchResult(
    query: query,
    answer:
        'The backed-up qPCR evidence is in Demo Immunology Notebook / Assays / qPCR run 001, which records the master-mix workflow, melt-curve review, and delayed IL6 amplification observation [1]. Original payload review is in Demo Immunology Notebook / Imaging and Attachments / Mixed file attachments, where the backup includes `qpcr_results.csv`, `amplicon.fasta`, `qc_report.pdf`, and `tiny_signal.png`; the run reports 15 of 15 original attachments verified [2].',
    hits: [
      NotebookSearchHit(
        chunk: NotebookSearchChunk(
          id: 'demo_20260514_090000Z:2:1',
          backupId: 'demo_20260514_090000Z',
          notebookName: 'Demo Immunology Notebook',
          backupCreatedAt: DateTime.parse(backupCreatedAt),
          nodeId: 2,
          pageTitle: 'qPCR run 001',
          path: 'Assays / qPCR run 001',
          text:
              'Protocol: prepare master mix on ice, load 96-well plate, and review melt curves. Observation: treated PBMC sample S002 shows delayed IL6 amplification.',
        ),
        score: 31.4,
        snippet:
            'Protocol: prepare master mix on ice, load 96-well plate, and review melt curves. Observation: treated PBMC sample S002 shows delayed IL6 amplification.',
      ),
      NotebookSearchHit(
        chunk: NotebookSearchChunk(
          id: 'demo_20260514_090000Z:4:1',
          backupId: 'demo_20260514_090000Z',
          notebookName: 'Demo Immunology Notebook',
          backupCreatedAt: DateTime.parse(backupCreatedAt),
          nodeId: 4,
          pageTitle: 'Mixed file attachments',
          path: 'Imaging and Attachments / Mixed file attachments',
          text:
              'Attachment qpcr_results.csv; text/csv; 77 bytes. Attachment amplicon.fasta. Attachment qc_report.pdf. Attachment tiny_signal.png.',
          attachments: [
            'Attachment qpcr_results.csv; text/csv; 77 bytes',
            'Attachment amplicon.fasta; application/octet-stream; 88 bytes',
            'Attachment qc_report.pdf; application/pdf; 602 bytes',
            'Attachment tiny_signal.png; image/png; 68 bytes',
          ],
        ),
        score: 28.2,
        snippet:
            'Attachment qpcr_results.csv; text/csv; 77 bytes. Attachment amplicon.fasta. Attachment qc_report.pdf. Attachment tiny_signal.png.',
      ),
    ],
    usedOpenAi: true,
  );
}

RenderNotebook _demoNotebook() {
  return RenderNotebook(
    name: 'Demo Immunology Notebook',
    createdAt: DateTime.utc(2026, 5, 14, 9),
    archivePath:
        'notebooks/demo_immunology_notebook/2026/05/14/demo_20260514_090000Z/notebook.7z',
    nodes: const [
      RenderNode(
        id: 1,
        parentId: 0,
        title: 'Assays',
        isPage: false,
        position: 1,
        parts: [],
      ),
      RenderNode(
        id: 2,
        parentId: 1,
        title: 'qPCR run 001',
        isPage: true,
        position: 1,
        parts: [
          RenderPart(
            id: 1,
            kindCode: 0,
            kindLabel: 'Heading',
            renderText: 'qPCR run 001',
            position: 1,
          ),
          RenderPart(
            id: 2,
            kindCode: 1,
            kindLabel: 'Rich text',
            renderText:
                'Protocol: prepare master mix on ice, load 96-well plate, and review melt curves.\n\nControl table: NTC pass; positive control pass.',
            position: 2,
          ),
          RenderPart(
            id: 3,
            kindCode: 5,
            kindLabel: 'Plain text',
            renderText:
                'Observation: treated PBMC sample S002 shows delayed IL6 amplification; repeat extraction if Ct remains above 30.',
            position: 3,
          ),
        ],
      ),
      RenderNode(
        id: 3,
        parentId: 0,
        title: 'Imaging and Attachments',
        isPage: false,
        position: 2,
        parts: [],
      ),
      RenderNode(
        id: 4,
        parentId: 3,
        title: 'Mixed file attachments',
        isPage: true,
        position: 1,
        parts: [
          RenderPart(
            id: 12,
            kindCode: 2,
            kindLabel: 'Attachment',
            renderText: 'qPCR results table',
            position: 1,
            attachmentName: 'qpcr_results.csv',
            attachmentContentType: 'text/csv',
            attachmentSize: 77,
          ),
          RenderPart(
            id: 14,
            kindCode: 2,
            kindLabel: 'Attachment',
            renderText: 'FASTA sequence',
            position: 2,
            attachmentName: 'amplicon.fasta',
            attachmentContentType: 'application/octet-stream',
            attachmentSize: 88,
          ),
          RenderPart(
            id: 25,
            kindCode: 2,
            kindLabel: 'Attachment',
            renderText: 'QC report PDF',
            position: 3,
            attachmentName: 'qc_report.pdf',
            attachmentContentType: 'application/pdf',
            attachmentSize: 602,
          ),
          RenderPart(
            id: 26,
            kindCode: 2,
            kindLabel: 'Attachment',
            renderText: 'Tiny PNG signal image',
            position: 4,
            attachmentName: 'tiny_signal.png',
            attachmentContentType: 'image/png',
            attachmentSize: 68,
          ),
        ],
      ),
    ],
  );
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.status,
    required this.detail,
    required this.busy,
  });

  final String status;
  final String? detail;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colors.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            busy ? Icons.sync : Icons.verified_user_outlined,
            size: 18,
            color: colors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (detail != null)
                  Text(
                    detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IntegrityBanner extends StatelessWidget {
  const _IntegrityBanner({required this.check, required this.busy});

  final BackupIntegrityCheck? check;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return _banner(
        context,
        icon: Icons.fact_check_outlined,
        title: 'Checking backup integrity...',
        detail: 'Verifying SHA-256 hashes before rendering this backup.',
        color: Theme.of(context).colorScheme.primary,
      );
    }
    final result = check;
    if (result == null) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final color = result.isVerified ? _nihSuccess : colors.error;
    return _banner(
      context,
      icon: result.isVerified
          ? Icons.verified_outlined
          : Icons.warning_amber_outlined,
      title: result.statusTitle,
      detail: result.summary,
      color: color,
      strong: result.needsWarning,
    );
  }

  Widget _banner(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String detail,
    required Color color,
    bool strong = false,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: strong ? 12 : 7),
      color: color.withValues(alpha: strong ? 0.16 : 0.08),
      child: Row(
        children: [
          Icon(icon, color: color, size: strong ? 24 : 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: (strong ? textTheme.titleSmall : textTheme.labelLarge)
                      ?.copyWith(color: color),
                ),
                Text(
                  detail,
                  maxLines: strong ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CredentialSetupPanel extends StatefulWidget {
  const _CredentialSetupPanel({
    required this.busy,
    required this.initialBackupRootPath,
    required this.onConnectBrowser,
    required this.onConnectAuthCode,
  });

  final bool busy;
  final String initialBackupRootPath;
  final ValueChanged<LabArchivesSetupInput> onConnectBrowser;
  final ValueChanged<LabArchivesSetupInput> onConnectAuthCode;

  @override
  State<_CredentialSetupPanel> createState() => _CredentialSetupPanelState();
}

class _CredentialSetupPanelState extends State<_CredentialSetupPanel> {
  final _email = TextEditingController();
  final _accessId = TextEditingController();
  final _accessKey = TextEditingController();
  final _authCode = TextEditingController();
  final _openAiKey = TextEditingController();
  final _openAiModel = TextEditingController(
    text: OpenAiSearchSettings.defaultModel,
  );
  late final TextEditingController _backupRoot;
  bool _showKey = false;
  bool _showOpenAiKey = false;

  @override
  void initState() {
    super.initState();
    _backupRoot = TextEditingController(text: widget.initialBackupRootPath);
  }

  @override
  void dispose() {
    _email.dispose();
    _accessId.dispose();
    _accessKey.dispose();
    _authCode.dispose();
    _openAiKey.dispose();
    _openAiModel.dispose();
    _backupRoot.dispose();
    super.dispose();
  }

  Future<void> _chooseBackupFolder() async {
    final selected = await _chooseDirectoryPath(_backupRoot.text);
    if (selected != null && mounted) {
      setState(() => _backupRoot.text = selected);
    }
  }

  LabArchivesSetupInput _input() {
    return LabArchivesSetupInput(
      email: _email.text,
      accessId: _accessId.text,
      accessKey: _accessKey.text,
      backupRootPath: _backupRoot.text,
      authCode: _authCode.text,
      openAiApiKey: _openAiKey.text,
      openAiModel: _openAiModel.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 620;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lock_person_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'LabArchives Setup',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _email,
                enabled: !widget.busy,
                autofillHints: const [AutofillHints.email],
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _accessId,
                enabled: !widget.busy,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Access ID',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _accessKey,
                enabled: !widget.busy,
                obscureText: !_showKey,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Access key',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    tooltip: _showKey ? 'Hide access key' : 'Show access key',
                    onPressed: widget.busy
                        ? null
                        : () => setState(() => _showKey = !_showKey),
                    icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _authCode,
                enabled: !widget.busy,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Auth code',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _backupRoot,
                enabled: !widget.busy,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Backup folder',
                  prefixIcon: const Icon(Icons.folder_outlined),
                  suffixIcon: IconButton(
                    tooltip: 'Choose backup folder',
                    onPressed: widget.busy ? null : _chooseBackupFolder,
                    icon: const Icon(Icons.drive_folder_upload_outlined),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _openAiKey,
                enabled: !widget.busy,
                obscureText: !_showOpenAiKey,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'OpenAI API key',
                  prefixIcon: const Icon(Icons.psychology_alt_outlined),
                  suffixIcon: IconButton(
                    tooltip: _showOpenAiKey
                        ? 'Hide OpenAI key'
                        : 'Show OpenAI key',
                    onPressed: widget.busy
                        ? null
                        : () =>
                              setState(() => _showOpenAiKey = !_showOpenAiKey),
                    icon: Icon(
                      _showOpenAiKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _openAiModel,
                enabled: !widget.busy,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'OpenAI model',
                  prefixIcon: Icon(Icons.auto_awesome_outlined),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: narrow ? WrapAlignment.center : WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: widget.busy
                        ? null
                        : () => widget.onConnectAuthCode(_input()),
                    icon: const Icon(Icons.password_outlined),
                    label: const Text('Use Auth Code'),
                  ),
                  FilledButton.icon(
                    onPressed: widget.busy
                        ? null
                        : () => widget.onConnectBrowser(_input()),
                    icon: widget.busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_outlined),
                    label: const Text('Connect'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScheduleDialog extends StatefulWidget {
  const _ScheduleDialog({required this.initial});

  final BackupSettings initial;

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late bool _enabled;
  late BackupFrequency _frequency;
  late int _minutesAfterMidnight;
  late int _weekday;
  late final TextEditingController _backupRoot;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initial.schedule.enabled;
    _frequency = widget.initial.schedule.frequency;
    _minutesAfterMidnight = widget.initial.schedule.minutesAfterMidnight;
    _weekday = widget.initial.schedule.weekday;
    _backupRoot = TextEditingController(text: widget.initial.backupRootPath);
  }

  @override
  void dispose() {
    _backupRoot.dispose();
    super.dispose();
  }

  Future<void> _chooseBackupFolder() async {
    final selected = await _chooseDirectoryPath(_backupRoot.text);
    if (selected != null && mounted) {
      setState(() => _backupRoot.text = selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedTime = TimeOfDay(
      hour: _minutesAfterMidnight ~/ 60,
      minute: _minutesAfterMidnight % 60,
    );
    return AlertDialog(
      title: const Text('Automatic Backup'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<BackupFrequency>(
              initialValue: _frequency,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Frequency',
                prefixIcon: Icon(Icons.repeat_outlined),
              ),
              items: BackupFrequency.values
                  .map(
                    (frequency) => DropdownMenuItem(
                      value: frequency,
                      child: Text(frequency.label),
                    ),
                  )
                  .toList(),
              onChanged: _enabled
                  ? (value) {
                      if (value != null) {
                        setState(() => _frequency = value);
                      }
                    }
                  : null,
            ),
            if (_frequency == BackupFrequency.weekly) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _weekday,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Day',
                  prefixIcon: Icon(Icons.calendar_month_outlined),
                ),
                items: List.generate(DateTime.sunday, (index) {
                  final weekday = index + 1;
                  return DropdownMenuItem(
                    value: weekday,
                    child: Text(_weekdayName(weekday)),
                  );
                }),
                onChanged: _enabled
                    ? (value) {
                        if (value != null) {
                          setState(() => _weekday = value);
                        }
                      }
                    : null,
              ),
            ],
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: Text(selectedTime.format(context)),
              trailing: const Icon(Icons.edit_outlined),
              enabled: _enabled,
              onTap: !_enabled
                  ? null
                  : () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: selectedTime,
                      );
                      if (picked != null) {
                        setState(() {
                          _minutesAfterMidnight =
                              picked.hour * 60 + picked.minute;
                        });
                      }
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _backupRoot,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Backup folder',
                prefixIcon: const Icon(Icons.folder_outlined),
                suffixIcon: IconButton(
                  tooltip: 'Choose backup folder',
                  onPressed: _chooseBackupFolder,
                  icon: const Icon(Icons.drive_folder_upload_outlined),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              BackupSettings(
                schedule: BackupSchedule(
                  enabled: _enabled,
                  frequency: _frequency,
                  minutesAfterMidnight: _minutesAfterMidnight,
                  weekday: _weekday,
                ),
                backupRootPath: _backupRoot.text.trim(),
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SearchSettingsDialog extends StatefulWidget {
  const _SearchSettingsDialog({required this.initial});

  final OpenAiSearchSettings initial;

  @override
  State<_SearchSettingsDialog> createState() => _SearchSettingsDialogState();
}

class _SearchSettingsDialogState extends State<_SearchSettingsDialog> {
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _apiKey = TextEditingController(text: widget.initial.apiKey);
    _model = TextEditingController(
      text: widget.initial.model.trim().isEmpty
          ? OpenAiSearchSettings.defaultModel
          : widget.initial.model,
    );
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Notebook Search'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _apiKey,
              obscureText: !_showKey,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'OpenAI API key',
                prefixIcon: const Icon(Icons.psychology_alt_outlined),
                suffixIcon: IconButton(
                  tooltip: _showKey ? 'Hide OpenAI key' : 'Show OpenAI key',
                  onPressed: () => setState(() => _showKey = !_showKey),
                  icon: Icon(
                    _showKey
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'OpenAI model',
                prefixIcon: Icon(Icons.auto_awesome_outlined),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Saved locally only. Matching notebook excerpts are sent to OpenAI when natural-language search runs.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(OpenAiSearchSettings(apiKey: '', model: _model.text.trim())),
          child: const Text('Remove Key'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            OpenAiSearchSettings(
              apiKey: _apiKey.text.trim(),
              model: _model.text.trim(),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SearchPanel extends StatelessWidget {
  const _SearchPanel({
    required this.controller,
    required this.result,
    required this.busy,
    required this.openAiReady,
    required this.onSearch,
    required this.onSettings,
    required this.onSelectHit,
  });

  final TextEditingController controller;
  final NotebookSearchResult? result;
  final bool busy;
  final bool openAiReady;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final ValueChanged<NotebookSearchHit> onSelectHit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final searchResult = result;
    final isFallback =
        searchResult != null &&
        !searchResult.usedOpenAi &&
        searchResult.warning != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: !busy,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => onSearch(),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: 'Ask across backed-up notebooks',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: openAiReady
                    ? 'Natural-language search is enabled'
                    : 'Add OpenAI key for natural-language search',
                child: IconButton(
                  onPressed: busy ? null : onSettings,
                  icon: Icon(
                    openAiReady
                        ? Icons.psychology_alt
                        : Icons.psychology_alt_outlined,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: busy ? null : onSearch,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.manage_search),
                label: const Text('Search'),
              ),
            ],
          ),
          if (searchResult != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  searchResult.usedOpenAi
                      ? Icons.auto_awesome
                      : isFallback
                      ? Icons.travel_explore
                      : Icons.manage_search_outlined,
                  size: 16,
                  color: colors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  searchResult.usedOpenAi
                      ? 'OpenAI answer'
                      : isFallback
                      ? 'Local fuzzy fallback'
                      : 'Local fuzzy results',
                  style: textTheme.labelMedium?.copyWith(color: colors.primary),
                ),
                if (searchResult.warning != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      searchResult.warning!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(color: colors.error),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(searchResult.answer),
            if (searchResult.hits.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: searchResult.hits
                    .take(6)
                    .map(
                      (hit) => ActionChip(
                        avatar: const Icon(Icons.article_outlined, size: 16),
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          child: Text(
                            hit.chunk.path,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        onPressed: () => onSelectHit(hit),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.service,
    required this.backups,
    required this.selectedBackup,
    required this.notebook,
    required this.selectedNode,
    required this.log,
    required this.onSelectBackup,
    required this.onSelectNode,
    required this.onDownloadAttachment,
  });

  final BackupService service;
  final List<BackupRecord> backups;
  final BackupRecord? selectedBackup;
  final RenderNotebook? notebook;
  final RenderNode? selectedNode;
  final List<String> log;
  final ValueChanged<BackupRecord> onSelectBackup;
  final ValueChanged<RenderNode> onSelectNode;
  final ValueChanged<RenderPart> onDownloadAttachment;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: _BackupList(
            backups: backups,
            selected: selectedBackup,
            onSelect: onSelectBackup,
            log: log,
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 330,
          child: _NotebookTree(
            notebook: notebook,
            selectedNode: selectedNode,
            onSelectNode: onSelectNode,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _EntryViewer(
            service: service,
            backup: selectedBackup,
            notebook: notebook,
            node: selectedNode,
            onDownloadAttachment: onDownloadAttachment,
          ),
        ),
      ],
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({
    required this.service,
    required this.backups,
    required this.selectedBackup,
    required this.notebook,
    required this.selectedNode,
    required this.log,
    required this.onSelectBackup,
    required this.onSelectNode,
    required this.onDownloadAttachment,
  });

  final BackupService service;
  final List<BackupRecord> backups;
  final BackupRecord? selectedBackup;
  final RenderNotebook? notebook;
  final RenderNode? selectedNode;
  final List<String> log;
  final ValueChanged<BackupRecord> onSelectBackup;
  final ValueChanged<RenderNode> onSelectNode;
  final ValueChanged<RenderPart> onDownloadAttachment;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Backups'),
              Tab(icon: Icon(Icons.account_tree_outlined), text: 'Pages'),
              Tab(icon: Icon(Icons.article_outlined), text: 'Viewer'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _BackupList(
                  backups: backups,
                  selected: selectedBackup,
                  onSelect: onSelectBackup,
                  log: log,
                ),
                _NotebookTree(
                  notebook: notebook,
                  selectedNode: selectedNode,
                  onSelectNode: onSelectNode,
                ),
                _EntryViewer(
                  service: service,
                  backup: selectedBackup,
                  notebook: notebook,
                  node: selectedNode,
                  onDownloadAttachment: onDownloadAttachment,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackupList extends StatelessWidget {
  const _BackupList({
    required this.backups,
    required this.selected,
    required this.onSelect,
    required this.log,
  });

  final List<BackupRecord> backups;
  final BackupRecord? selected;
  final ValueChanged<BackupRecord> onSelect;
  final List<String> log;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PaneHeader(icon: Icons.inventory_2_outlined, title: 'Backups'),
        Expanded(
          child: backups.isEmpty
              ? const _EmptyState(
                  icon: Icons.archive_outlined,
                  text:
                      'No local backups yet. Use Backup All to create JSON-viewable archives.',
                )
              : ListView.builder(
                  itemCount: backups.length,
                  itemBuilder: (context, index) {
                    final backup = backups[index];
                    final isSelected = selected?.id == backup.id;
                    return ListTile(
                      selected: isSelected,
                      leading: const Icon(Icons.folder_zip_outlined),
                      title: Text(
                        backup.notebookName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${backup.createdAtLabel} · ${backup.pageCount} pages · ${backup.contentVerification?.summary ?? 'legacy archive'}',
                      ),
                      onTap: () => onSelect(backup),
                    );
                  },
                ),
        ),
        if (log.isNotEmpty) ...[
          const Divider(height: 1),
          SizedBox(
            height: 130,
            child: ListView.builder(
              reverse: true,
              itemCount: log.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(
                  log[index],
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _NotebookTree extends StatelessWidget {
  const _NotebookTree({
    required this.notebook,
    required this.selectedNode,
    required this.onSelectNode,
  });

  final RenderNotebook? notebook;
  final RenderNode? selectedNode;
  final ValueChanged<RenderNode> onSelectNode;

  @override
  Widget build(BuildContext context) {
    final nb = notebook;
    if (nb == null) {
      return const _EmptyState(
        icon: Icons.account_tree_outlined,
        text: 'Select a backup to browse pages.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PaneHeader(icon: Icons.account_tree_outlined, title: nb.name),
        Expanded(
          child: ListView(
            children: nb.rootNodes
                .map(
                  (node) => _TreeNodeTile(
                    notebook: nb,
                    node: node,
                    selectedNode: selectedNode,
                    onSelectNode: onSelectNode,
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _TreeNodeTile extends StatelessWidget {
  const _TreeNodeTile({
    required this.notebook,
    required this.node,
    required this.selectedNode,
    required this.onSelectNode,
    this.depth = 0,
  });

  final RenderNotebook notebook;
  final RenderNode node;
  final RenderNode? selectedNode;
  final ValueChanged<RenderNode> onSelectNode;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final children = notebook.childrenOf(node.id);
    final selected = selectedNode?.id == node.id;
    final tile = ListTile(
      dense: true,
      selected: selected,
      contentPadding: EdgeInsets.only(left: 12 + depth * 18, right: 8),
      leading: Icon(
        node.isPage ? Icons.article_outlined : Icons.folder_outlined,
        size: 19,
      ),
      title: Text(node.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: node.isPage
          ? Text(
              '${node.parts.length} part${node.parts.length == 1 ? '' : 's'}',
            )
          : null,
      onTap: node.isPage ? () => onSelectNode(node) : null,
    );
    if (children.isEmpty) {
      return tile;
    }
    return ExpansionTile(
      initiallyExpanded: depth < 1,
      tilePadding: EdgeInsets.only(left: 12 + depth * 18, right: 8),
      leading: const Icon(Icons.folder_outlined, size: 19),
      title: Text(node.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      children: children
          .map(
            (child) => _TreeNodeTile(
              notebook: notebook,
              node: child,
              selectedNode: selectedNode,
              onSelectNode: onSelectNode,
              depth: depth + 1,
            ),
          )
          .toList(),
    );
  }
}

class _EntryViewer extends StatelessWidget {
  const _EntryViewer({
    required this.service,
    required this.backup,
    required this.notebook,
    required this.node,
    required this.onDownloadAttachment,
  });

  final BackupService service;
  final BackupRecord? backup;
  final RenderNotebook? notebook;
  final RenderNode? node;
  final ValueChanged<RenderPart> onDownloadAttachment;

  @override
  Widget build(BuildContext context) {
    final selected = node;
    if (notebook == null || selected == null) {
      return const _EmptyState(
        icon: Icons.article_outlined,
        text: 'Select a page to render its backed-up contents.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PaneHeader(
          icon: Icons.article_outlined,
          title: selected.title,
          trailing: Text('${selected.parts.length} parts'),
        ),
        Expanded(
          child: selected.parts.isEmpty
              ? const _EmptyState(
                  icon: Icons.notes_outlined,
                  text: 'This backed-up page has no rendered entry parts.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: selected.parts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) => _EntryPartView(
                    service: service,
                    backup: backup,
                    part: selected.parts[index],
                    onDownloadAttachment: onDownloadAttachment,
                  ),
                ),
        ),
      ],
    );
  }
}

class _EntryPartView extends StatelessWidget {
  const _EntryPartView({
    required this.service,
    required this.backup,
    required this.part,
    required this.onDownloadAttachment,
  });

  final BackupService service;
  final BackupRecord? backup;
  final RenderPart part;
  final ValueChanged<RenderPart> onDownloadAttachment;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (part.isAttachment) {
      final support = attachmentFormatSupport(part);
      return DecoratedBox(
        decoration: _partDecoration(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_attachmentIcon(support), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          part.attachmentName ?? 'Attachment',
                          style: textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          part.attachmentSummary,
                          style: textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    tooltip: 'Download original attachment',
                    onPressed: () => onDownloadAttachment(part),
                    icon: const Icon(Icons.download_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _AttachmentSupportBadge(support: support),
              if (part.renderText.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(part.renderText),
              ],
              _AttachmentPreview(
                service: service,
                backup: backup,
                part: part,
                support: support,
              ),
              if (part.comments.isNotEmpty) ...[
                const SizedBox(height: 10),
                _CommentList(comments: part.comments),
              ],
            ],
          ),
        ),
      );
    }

    final isHeading = part.kindLabel.toLowerCase().contains('heading');
    return DecoratedBox(
      decoration: _partDecoration(context),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isHeading ? Icons.title : Icons.notes_outlined, size: 18),
                const SizedBox(width: 8),
                Text(part.kindLabel, style: textTheme.labelMedium),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              part.renderText.isEmpty ? '(empty)' : part.renderText,
              style: isHeading ? textTheme.titleMedium : textTheme.bodyMedium,
            ),
            if (part.comments.isNotEmpty) ...[
              const SizedBox(height: 10),
              _CommentList(comments: part.comments),
            ],
          ],
        ),
      ),
    );
  }

  IconData _attachmentIcon(AttachmentFormatSupport support) {
    return switch (support.previewMode) {
      AttachmentPreviewMode.inlineImage => Icons.image_outlined,
      AttachmentPreviewMode.inlineText => Icons.description_outlined,
      AttachmentPreviewMode.jupyterSummary => Icons.data_object_outlined,
      AttachmentPreviewMode.externalViewer => Icons.open_in_new_outlined,
      AttachmentPreviewMode.downloadOnly => Icons.attach_file,
    };
  }

  BoxDecoration _partDecoration(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BoxDecoration(
      border: Border.all(color: colors.outlineVariant),
      borderRadius: BorderRadius.circular(8),
      color: colors.surface,
    );
  }
}

class _AttachmentSupportBadge extends StatelessWidget {
  const _AttachmentSupportBadge({required this.support});

  final AttachmentFormatSupport support;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: support.hasInlinePreview
            ? colors.primaryContainer.withValues(alpha: 0.42)
            : colors.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              support.family,
              style: textTheme.labelMedium?.copyWith(
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              support.elnlaSupport,
              style: textTheme.bodySmall?.copyWith(
                color: colors.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({
    required this.service,
    required this.backup,
    required this.part,
    required this.support,
  });

  final BackupService service;
  final BackupRecord? backup;
  final RenderPart part;
  final AttachmentFormatSupport support;

  @override
  Widget build(BuildContext context) {
    if (!support.hasInlinePreview) {
      return _AttachmentPreviewHint(support: support);
    }
    final record = backup;
    if (record == null) {
      return const _AttachmentPreviewMessage(
        message: 'Select a backup record to preview the original payload.',
      );
    }
    return FutureBuilder<File?>(
      future: service.resolveOriginalAttachmentFile(record: record, part: part),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(),
          );
        }
        if (file == null || !file.existsSync()) {
          return const _AttachmentPreviewMessage(
            message:
                'Original payload is not available for inline preview in this local backup.',
          );
        }
        return switch (support.previewMode) {
          AttachmentPreviewMode.inlineImage => _InlineImagePreview(file: file),
          AttachmentPreviewMode.inlineText => _InlineTextPreview(
            service: service,
            record: record,
            part: part,
          ),
          AttachmentPreviewMode.jupyterSummary => _InlineJupyterPreview(
            service: service,
            record: record,
            part: part,
          ),
          _ => _AttachmentPreviewHint(support: support),
        };
      },
    );
  }
}

class _InlineImagePreview extends StatelessWidget {
  const _InlineImagePreview({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      constraints: const BoxConstraints(maxHeight: 260),
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
        color: colors.surfaceContainerHighest.withValues(alpha: 0.32),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            const _AttachmentPreviewMessage(
              message: 'This image format could not be previewed inline.',
            ),
      ),
    );
  }
}

class _InlineTextPreview extends StatelessWidget {
  const _InlineTextPreview({
    required this.service,
    required this.record,
    required this.part,
  });

  final BackupService service;
  final BackupRecord record;
  final RenderPart part;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: service.loadAttachmentTextPreview(record: record, part: part),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(),
          );
        }
        final text = snapshot.data?.trim();
        if (text == null || text.isEmpty) {
          return const _AttachmentPreviewMessage(
            message: 'No safe text preview is available for this attachment.',
          );
        }
        return _AttachmentTextBox(text: text);
      },
    );
  }
}

class _InlineJupyterPreview extends StatelessWidget {
  const _InlineJupyterPreview({
    required this.service,
    required this.record,
    required this.part,
  });

  final BackupService service;
  final BackupRecord record;
  final RenderPart part;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: service.loadAttachmentTextPreview(record: record, part: part),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(),
          );
        }
        final summary = _jupyterSummary(snapshot.data);
        return _AttachmentTextBox(text: summary);
      },
    );
  }

  String _jupyterSummary(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return 'Jupyter notebook payload is empty or unavailable.';
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return 'Jupyter notebook payload could not be parsed locally. Restore the original .ipynb for inspection.';
    }
    if (decoded is! Map<String, Object?>) {
      return 'Jupyter notebook payload is not a recognized notebook object.';
    }
    final cells = (decoded['cells'] as List<Object?>? ?? const []);
    var markdownCells = 0;
    var codeCells = 0;
    String? title;
    for (final cell in cells.whereType<Map<String, Object?>>()) {
      final sourceText = _cellSourceText(cell['source']);
      final cellType = cell['cell_type'];
      if (cellType == 'markdown') {
        markdownCells += 1;
        title ??= _firstMarkdownHeading(sourceText);
      } else if (cellType == 'code') {
        codeCells += 1;
      }
    }
    final language = _notebookLanguage(decoded);
    final pieces = [
      'Jupyter notebook summary',
      'Language: $language',
      'Markdown cells: $markdownCells',
      'Code cells: $codeCells',
      if (title != null && title.isNotEmpty) 'First heading: $title',
    ];
    return pieces.join('\n');
  }

  String _cellSourceText(Object? source) {
    if (source is String) {
      return source;
    }
    if (source is List<Object?>) {
      return source.map((line) => line?.toString() ?? '').join();
    }
    return '';
  }

  String? _firstMarkdownHeading(String sourceText) {
    for (final line in const LineSplitter().convert(sourceText)) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) {
        final title = trimmed.replaceFirst(RegExp(r'^#+\s*'), '').trim();
        if (title.isNotEmpty) {
          return title;
        }
      }
    }
    return null;
  }

  String _notebookLanguage(Map<String, Object?> notebook) {
    final metadata = notebook['metadata'];
    if (metadata is Map<String, Object?>) {
      final languageInfo = metadata['language_info'];
      if (languageInfo is Map<String, Object?>) {
        final name = languageInfo['name'];
        if (name is String && name.trim().isNotEmpty) {
          return name;
        }
      }
      final kernelSpec = metadata['kernelspec'];
      if (kernelSpec is Map<String, Object?>) {
        final language = kernelSpec['language'];
        if (language is String && language.trim().isNotEmpty) {
          return language;
        }
      }
    }
    return 'unknown';
  }
}

class _AttachmentTextBox extends StatelessWidget {
  const _AttachmentTextBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
        color: colors.surfaceContainerHighest.withValues(alpha: 0.32),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

class _AttachmentPreviewHint extends StatelessWidget {
  const _AttachmentPreviewHint({required this.support});

  final AttachmentFormatSupport support;

  @override
  Widget build(BuildContext context) {
    final message = support.labArchivesDirectView
        ? '${support.labArchivesSupport} ${support.elnlaSupport}'
        : support.elnlaSupport;
    return _AttachmentPreviewMessage(message: message);
  }
}

class _AttachmentPreviewMessage extends StatelessWidget {
  const _AttachmentPreviewMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(message, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

class _CommentList extends StatelessWidget {
  const _CommentList({required this.comments});

  final List<RenderComment> comments;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
        color: colors.primaryContainer.withValues(alpha: 0.28),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.comment_outlined, size: 16, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  comments.length == 1 ? 'Comment' : 'Comments',
                  style: textTheme.labelMedium?.copyWith(color: colors.primary),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final comment in comments) ...[
              SelectableText(
                comment.text.isEmpty ? '(empty comment)' : comment.text,
                style: textTheme.bodySmall,
              ),
              if (comment.createdAt.isNotEmpty || comment.author != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    [
                      if (comment.author != null) comment.author!,
                      if (comment.createdAt.isNotEmpty) comment.createdAt,
                    ].join(' · '),
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              if (comment != comments.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: colors.surfaceContainer,
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: colors.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

Future<String?> _chooseDirectoryPath(
  String initialDirectory, {
  String prompt = 'Choose backup folder',
}) async {
  final initial = initialDirectory.trim();
  if (Platform.isMacOS) {
    final defaultClause = Directory(initial).existsSync()
        ? ' default location POSIX file "${_escapeAppleScript(initial)}"'
        : '';
    final script =
        'set chosenFolder to choose folder with prompt "${_escapeAppleScript(prompt)}"$defaultClause\n'
        'POSIX path of chosenFolder';
    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode == 0) {
      final selected = '${result.stdout}'.trim();
      return selected.isEmpty ? null : selected;
    }
  }
  if (Platform.isWindows) {
    const outputEncoding =
        '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8;';
    final initialPath = _escapePowerShellSingleQuoted(initial);
    final script = [
      outputEncoding,
      'Add-Type -AssemblyName System.Windows.Forms;',
      r'$dialog = New-Object System.Windows.Forms.FolderBrowserDialog;',
      "\$dialog.Description = '${_escapePowerShellSingleQuoted(prompt)}';",
      r'$dialog.ShowNewFolderButton = $true;',
      "\$initial = '$initialPath';",
      r'if ([System.IO.Directory]::Exists($initial)) { $dialog.SelectedPath = $initial; }',
      r'if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $dialog.SelectedPath; }',
    ].join(' ');
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ]);
    if (result.exitCode == 0) {
      final selected = '${result.stdout}'.trim();
      return selected.isEmpty ? null : selected;
    }
  }
  return null;
}

String _escapeAppleScript(String value) {
  return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

String _escapePowerShellSingleQuoted(String value) {
  return value.replaceAll("'", "''");
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${local.month}/${local.day}/${local.year} $hour:$minute $period';
}

String _weekdayName(int weekday) {
  switch (weekday) {
    case DateTime.monday:
      return 'Monday';
    case DateTime.tuesday:
      return 'Tuesday';
    case DateTime.wednesday:
      return 'Wednesday';
    case DateTime.thursday:
      return 'Thursday';
    case DateTime.friday:
      return 'Friday';
    case DateTime.saturday:
      return 'Saturday';
    case DateTime.sunday:
      return 'Sunday';
  }
  return 'Monday';
}
