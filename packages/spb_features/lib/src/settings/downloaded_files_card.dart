import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

typedef LoadDownloadedFiles = Future<DownloadedFileInventory> Function();
typedef DeleteDownloadedFiles = Future<DownloadedFileCleanupResult> Function(
  Iterable<DownloadedFileKey> files,
);

/// 当前账号的应用下载副本统计与用户主动清理入口。
class DownloadedFilesCard extends StatefulWidget {
  const DownloadedFilesCard({
    required this.loadFiles,
    required this.deleteFiles,
    super.key,
  });

  final LoadDownloadedFiles loadFiles;
  final DeleteDownloadedFiles deleteFiles;

  @override
  State<DownloadedFilesCard> createState() => _DownloadedFilesCardState();
}

class _DownloadedFilesCardState extends State<DownloadedFilesCard> {
  DownloadedFileInventory? _inventory;
  Object? _error;
  bool _loading = true;
  bool _deleting = false;

  @override
  void didUpdateWidget(DownloadedFilesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loadFiles != widget.loadFiles ||
        oldWidget.deleteFiles != widget.deleteFiles) {
      // 账号归属一变，旧清单不能短暂配上新账号的删除回调。
      _inventory = null;
      _error = null;
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reload(showLoading: false);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final inventory = await widget.loadFiles();
      if (!mounted) return;
      setState(() {
        _inventory = inventory;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Map<String, List<DownloadedFileRecord>> get _byGroup {
    final result = <String, List<DownloadedFileRecord>>{};
    for (final file in _inventory?.files ?? const <DownloadedFileRecord>[]) {
      result.putIfAbsent(file.groupId, () => []).add(file);
    }
    return result;
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text('$detail\n\n只删除本机下载副本，不会删除云端文件或同步目录内容。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;

  Future<DownloadedFileCleanupResult?> _delete(
    Iterable<DownloadedFileRecord> records,
    String title,
  ) async {
    final files = records.toList(growable: false);
    if (files.isEmpty || _deleting) return null;
    final bytes = files.fold(0, (sum, file) => sum + file.sizeBytes);
    if (!await _confirm(
      title,
      '将删除 ${files.length} 个文件，释放 ${humanBytes(bytes)}。',
    )) {
      return null;
    }

    setState(() => _deleting = true);
    try {
      final result = await widget.deleteFiles(files.map((file) => file.key));
      final inventory = await widget.loadFiles();
      if (!mounted) return result;
      setState(() {
        _inventory = inventory;
        _deleting = false;
      });
      final message = result.hasFailures
          ? '已删除 ${result.deletedFiles} 个文件，${result.failures.length} 项失败'
          : '已删除 ${result.deletedFiles} 个文件，释放 ${humanBytes(result.deletedBytes)}';
      if (result.hasFailures) {
        final screen = MediaQuery.sizeOf(context);
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(message),
            content: SizedBox(
              width: math.min(520.0, screen.width - 64),
              height: math.min(360.0, screen.height * 0.5),
              child: ListView(
                children: [
                  for (final failure in result.failures.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(failure.key),
                      subtitle: Text(failure.value),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
      return result;
    } on Object catch (error) {
      if (!mounted) return null;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('清理下载副本失败：$error')));
      return null;
    }
  }

  Future<void> _showGroup(String groupId) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final records = _byGroup[groupId] ?? const <DownloadedFileRecord>[];
          final bytes = records.fold(0, (sum, file) => sum + file.sizeBytes);
          final screen = MediaQuery.sizeOf(context);
          return AlertDialog(
            title: Text('对话下载副本 · ${records.length} 个文件'),
            content: SizedBox(
              width: math.min(560.0, screen.width - 64),
              height: math.min(420.0, screen.height * 0.55),
              child: records.isEmpty
                  ? const Center(child: Text('此对话没有下载副本'))
                  : ListView.builder(
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final file = records[index];
                        return ListTile(
                          key: ValueKey(
                            'downloaded-file-${file.groupId}-${file.relativePath}',
                          ),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.insert_drive_file_outlined),
                          title: Text(
                            file.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${file.relativePath} · ${humanBytes(file.sizeBytes)}'
                            '${file.isIndexed ? '' : ' · 索引缺失'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '删除此下载副本',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _deleting
                                ? null
                                : () async {
                                    await _delete([file], '删除此下载副本？');
                                    if (mounted) setDialogState(() {});
                                  },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('关闭'),
              ),
              FilledButton.tonal(
                onPressed: records.isEmpty || _deleting
                    ? null
                    : () async {
                        final result = await _delete(records, '清理这个对话的下载副本？');
                        if (result != null && dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        } else if (mounted) {
                          setDialogState(() {});
                        }
                      },
                child: Text('清理此对话 · ${humanBytes(bytes)}'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showGroups() async {
    final groups = _byGroup;
    final screen = MediaQuery.sizeOf(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('按对话管理下载副本'),
        content: SizedBox(
          width: math.min(480.0, screen.width - 64),
          height: math.min(420.0, screen.height * 0.55),
          child: groups.isEmpty
              ? const Center(child: Text('没有下载副本'))
              : ListView.builder(
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups.entries.elementAt(index);
                    final bytes = group.value.fold(
                      0,
                      (sum, file) => sum + file.sizeBytes,
                    );
                    return ListTile(
                      key: ValueKey('downloaded-group-${group.key}'),
                      title: Text('对话 ${group.key}'),
                      subtitle: Text(
                        '${group.value.length} 个文件 · ${humanBytes(bytes)}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showGroup(group.key),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inventory = _inventory;
    return Card(
      key: const ValueKey('settings-downloaded-files'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_loading)
              const LinearProgressIndicator()
            else if (_error != null)
              Row(
                children: [
                  const Expanded(child: Text('读取下载副本统计失败')),
                  TextButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              )
            else if (inventory == null || inventory.totalFiles == 0)
              Text('当前账号没有下载副本', style: Theme.of(context).textTheme.bodyMedium)
            else ...[
              Wrap(
                spacing: SpbSpacing.lg,
                runSpacing: SpbSpacing.sm,
                children: [
                  Text('${inventory.totalFiles} 个文件'),
                  Text('${inventory.groupIds.length} 个对话'),
                  Text(humanBytes(inventory.totalBytes)),
                  if (inventory.files.any((file) => !file.isIndexed))
                    const Text('含索引缺失文件'),
                ],
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                '仅管理当前账号的应用下载副本，与上方同步目录分开。清理后需要联网重新下载。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: SpbSpacing.md),
            Wrap(
              spacing: SpbSpacing.sm,
              runSpacing: SpbSpacing.sm,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('settings-manage-downloaded-files'),
                  onPressed: _loading || _error != null || _deleting
                      ? null
                      : _showGroups,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('按对话管理'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('settings-clear-downloaded-files'),
                  onPressed:
                      inventory == null ||
                          inventory.totalFiles == 0 ||
                          _loading ||
                          _deleting
                      ? null
                      : () => _delete(inventory.files, '清理当前账号全部下载副本？'),
                  icon: _deleting
                      ? const SizedBox(
                          width: SpbSpacing.lg,
                          height: SpbSpacing.lg,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_sweep_outlined),
                  label: Text(_deleting ? '清理中…' : '清理全部'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
