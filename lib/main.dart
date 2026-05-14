import 'dart:async';

import 'package:flutter/material.dart';

import 'src/backup_models.dart';
import 'src/backup_service.dart';

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
  String _status = 'Loading local LabArchives context...';
  final List<String> _log = <String>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service = BackupService();
    _loader = _refresh();
  }

  Future<void> _refresh() async {
    try {
      final notebooks = await _service.loadNotebookSummaries();
      final backups = await _service.loadBackups();
      setState(() {
        _notebooks = notebooks;
        _backups = backups;
        _selectedBackup = backups.isEmpty ? null : backups.first;
        _status = notebooks.isEmpty
            ? 'No notebooks found. Run the local auth helper first.'
            : 'Ready: ${notebooks.length} notebook${notebooks.length == 1 ? '' : 's'} available.';
      });
      if (_selectedBackup != null) {
        await _selectBackup(_selectedBackup!);
      }
    } catch (error) {
      setState(() {
        _status = 'Setup needed: $error';
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

  Future<void> _runBackup() async {
    setState(() {
      _busy = true;
      _log.clear();
      _status = 'Backing up ${_notebooks.length} notebooks...';
    });
    try {
      final records = await _service.backupAllNotebooks(
        onProgress: (message) {
          setState(() => _log.insert(0, message));
        },
      );
      final backups = await _service.loadBackups();
      setState(() {
        _backups = backups;
        _status =
            'Backup complete: ${records.length} notebook archive${records.length == 1 ? '' : 's'} created.';
      });
      if (records.isNotEmpty) {
        await _selectBackup(records.first);
      }
    } catch (error) {
      setState(() {
        _status = 'Backup failed: $error';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
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
                tooltip: 'Refresh local backups',
                onPressed: _busy
                    ? null
                    : () {
                        setState(() => _loader = _refresh());
                      },
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.icon(
                onPressed: _busy || _notebooks.isEmpty ? null : _runBackup,
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
              _StatusStrip(status: _status, busy: _busy),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
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
  const _StatusStrip({required this.status, required this.busy});

  final String status;
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
            child: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
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
