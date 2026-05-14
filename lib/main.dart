import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/backup_models.dart';
import 'src/backup_service.dart';
import 'src/setup_models.dart';

void main() {
  runApp(const ElnlaApp());
}

class ElnlaApp extends StatelessWidget {
  const ElnlaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff1f7a6d),
      brightness: Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ELNLA',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
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
  LocalSetupStatus? _setupStatus;
  BackupSchedule _schedule = BackupSchedule.disabled();
  Timer? _scheduleTimer;
  DateTime? _nextAutomaticBackup;
  String _status = 'Loading local LabArchives context...';
  final List<String> _log = <String>[];
  bool _busy = false;
  bool _setupBusy = false;

  @override
  void initState() {
    super.initState();
    _service = BackupService();
    _loader = _refresh();
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final setupStatus = await _service.loadSetupStatus();
      final schedule = await _service.loadSchedule();
      final notebooks = setupStatus.hasNotebookIndex
          ? await _service.loadNotebookSummaries()
          : <NotebookSummary>[];
      final backups = await _service.loadBackups();
      setState(() {
        _setupStatus = setupStatus;
        _schedule = schedule;
        _notebooks = notebooks;
        _backups = backups;
        _selectedBackup = backups.isEmpty ? null : backups.first;
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
        _setupStatus = const LocalSetupStatus(
          hasCredentials: false,
          hasUserAccess: false,
          hasNotebookIndex: false,
          notebookCount: 0,
        );
      });
    }
  }

  Future<void> _selectBackup(BackupRecord backup) async {
    final notebook = await _service.loadRenderNotebook(backup);
    setState(() {
      _selectedBackup = backup;
      _selectedNotebook = notebook;
      _selectedNode = notebook.firstPage;
    });
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
    final updated = await showDialog<BackupSchedule>(
      context: context,
      builder: (context) => _ScheduleDialog(initial: _schedule),
    );
    if (updated == null) {
      return;
    }
    await _service.saveSchedule(updated);
    if (!mounted) {
      return;
    }
    setState(() {
      _schedule = updated;
      _status = updated.enabled
          ? 'Automatic backup scheduled.'
          : 'Automatic backup disabled.';
      _rescheduleAutomaticBackup();
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
    if (!_schedule.enabled) {
      return null;
    }
    final next = _nextAutomaticBackup;
    if (next == null) {
      return 'Automatic backup waiting for setup.';
    }
    return 'Next automatic backup: ${_formatDateTime(next)}';
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
                busy: _busy || _setupBusy,
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (!(_setupStatus?.isReady ?? false)) {
                      return _CredentialSetupPanel(
                        busy: _setupBusy,
                        onConnectBrowser: _connectWithBrowser,
                        onConnectAuthCode: _connectWithAuthCode,
                      );
                    }
                    if (constraints.maxWidth < 840) {
                      return _NarrowLayout(
                        backups: _backups,
                        selectedBackup: _selectedBackup,
                        notebook: _selectedNotebook,
                        selectedNode: _selectedNode,
                        log: _log,
                        onSelectBackup: _selectBackup,
                        onSelectNode: (node) =>
                            setState(() => _selectedNode = node),
                      );
                    }
                    return _WideLayout(
                      backups: _backups,
                      selectedBackup: _selectedBackup,
                      notebook: _selectedNotebook,
                      selectedNode: _selectedNode,
                      log: _log,
                      onSelectBackup: _selectBackup,
                      onSelectNode: (node) =>
                          setState(() => _selectedNode = node),
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

class _CredentialSetupPanel extends StatefulWidget {
  const _CredentialSetupPanel({
    required this.busy,
    required this.onConnectBrowser,
    required this.onConnectAuthCode,
  });

  final bool busy;
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
  bool _showKey = false;

  @override
  void dispose() {
    _email.dispose();
    _accessId.dispose();
    _accessKey.dispose();
    _authCode.dispose();
    super.dispose();
  }

  LabArchivesSetupInput _input() {
    return LabArchivesSetupInput(
      email: _email.text,
      accessId: _accessId.text,
      accessKey: _accessKey.text,
      authCode: _authCode.text,
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

  final BackupSchedule initial;

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late bool _enabled;
  late BackupFrequency _frequency;
  late int _minutesAfterMidnight;
  late int _weekday;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initial.enabled;
    _frequency = widget.initial.frequency;
    _minutesAfterMidnight = widget.initial.minutesAfterMidnight;
    _weekday = widget.initial.weekday;
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
              BackupSchedule(
                enabled: _enabled,
                frequency: _frequency,
                minutesAfterMidnight: _minutesAfterMidnight,
                weekday: _weekday,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.backups,
    required this.selectedBackup,
    required this.notebook,
    required this.selectedNode,
    required this.log,
    required this.onSelectBackup,
    required this.onSelectNode,
  });

  final List<BackupRecord> backups;
  final BackupRecord? selectedBackup;
  final RenderNotebook? notebook;
  final RenderNode? selectedNode;
  final List<String> log;
  final ValueChanged<BackupRecord> onSelectBackup;
  final ValueChanged<RenderNode> onSelectNode;

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
          child: _EntryViewer(notebook: notebook, node: selectedNode),
        ),
      ],
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({
    required this.backups,
    required this.selectedBackup,
    required this.notebook,
    required this.selectedNode,
    required this.log,
    required this.onSelectBackup,
    required this.onSelectNode,
  });

  final List<BackupRecord> backups;
  final BackupRecord? selectedBackup;
  final RenderNotebook? notebook;
  final RenderNode? selectedNode;
  final List<String> log;
  final ValueChanged<BackupRecord> onSelectBackup;
  final ValueChanged<RenderNode> onSelectNode;

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
                _EntryViewer(notebook: notebook, node: selectedNode),
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
                        '${backup.createdAtLabel} · ${backup.pageCount} pages',
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
  const _EntryViewer({required this.notebook, required this.node});

  final RenderNotebook? notebook;
  final RenderNode? node;

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
                  itemBuilder: (context, index) =>
                      _EntryPartView(part: selected.parts[index]),
                ),
        ),
      ],
    );
  }
}

class _EntryPartView extends StatelessWidget {
  const _EntryPartView({required this.part});

  final RenderPart part;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (part.isAttachment) {
      return DecoratedBox(
        decoration: _partDecoration(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.attach_file, size: 22),
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
                    Text(part.attachmentSummary, style: textTheme.bodySmall),
                    if (part.renderText.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectableText(part.renderText),
                    ],
                  ],
                ),
              ),
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
          ],
        ),
      ),
    );
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
