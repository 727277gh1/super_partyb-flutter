import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 选择同步目录。返回 null 表示**用户取消**（不是错误）。
typedef PickSyncDirectory = Future<String?> Function();

/// 触发一轮同步。
///
/// 返回 [SyncReport]（含逐文件失败项）；**整轮**无法进行时抛 [SpbError]
/// （如未选目录、列表请求失败）。
///
/// ## 为什么「单文件失败」在返回值里，「整轮失败」才抛异常
///
/// 单文件失败是**预期内的常态**（网络抖动、权限、远端 404），且它不影响其余
/// 文件——报告里列出来让用户知道即可。整轮失败（拿不到清单）则意味着本次同步
/// 什么也没做，属于「操作没能完成」，走异常通道让页面显示错误横幅。
typedef RunSyncAction = Future<SyncReport> Function();

/// 交付物同步页。
///
/// ## 页面职责边界
///
/// - **只负责**渲染与回调：目录展示、进度、结果摘要、失败项、错误；
/// - **不负责**网络、磁盘、配置持久化——全部由 [pickDirectory] / [runSync]
///   注入。这样本页可以在无文件系统、无网络、无平台插件的 widget test 里
///   完整验证，也避免 `spb_features` 为一个页面引入平台依赖。
///
/// 这一分工与 [LoginPage] 一致（见 `src/auth/login_page.dart` 的说明）。
///
/// ## 为什么同步是「单向」的
///
/// UFS → 本地，不反向回传。反向回传会触发服务端 groupsync 的写入回路
/// （emit `agent.file.*` → 可能引发渲染推送/重跑）。故本页没有任何「上传」
/// 入口——不是漏了，是不该有。
class SyncPage extends StatefulWidget {
  const SyncPage({
    super.key,
    required this.pickDirectory,
    required this.runSync,
    this.initialLocalRoot,
    this.onLocalRootChanged,
    this.title = '交付物同步',
  });

  /// 弹出目录选择器。返回 null = 用户取消。
  final PickSyncDirectory pickDirectory;

  /// 执行一轮同步。
  final RunSyncAction runSync;

  /// 初始同步目录（从配置读入）。null = 尚未选过。
  final String? initialLocalRoot;

  /// 目录变更回调（供上层持久化）。
  ///
  /// ## 为什么变更要回调出去而不是页面自己存
  ///
  /// 「换目录必须重置同步状态」是一条**必须与目录写入同事务**的规则
  /// （否则会出现「目录已改、状态没清」→ 新目录同步显示成功却是空的）。
  /// 页面不持有存储，故只能把变更交出去，由装配层在同一事务里完成。
  final ValueChanged<String?>? onLocalRootChanged;

  final String title;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late String? _localRoot = widget.initialLocalRoot;

  /// 是否正在选择目录（防重复弹窗）。
  bool _picking = false;

  /// 是否正在同步。
  bool _syncing = false;

  /// 上一轮的结果。null = 尚未同步过。
  SyncReport? _report;

  /// 整轮失败的原因（优先于 [SyncReport] 展示）。
  String? _error;

  bool get _busy => _picking || _syncing;

  @override
  void didUpdateWidget(SyncPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部改了初始目录（如设置页保存后回读）→ 跟随，但不动本轮结果。
    if (oldWidget.initialLocalRoot != widget.initialLocalRoot) {
      _localRoot = widget.initialLocalRoot;
    }
  }

  Future<void> _handlePick() async {
    if (_busy) return;
    setState(() {
      _picking = true;
      _error = null;
    });

    String? picked;
    try {
      picked = await widget.pickDirectory();
    } catch (e) {
      SpbLog.warn('选择同步目录时异常', {'error': e.toString()});
      if (mounted) {
        setState(() {
          _picking = false;
          _error = '无法打开目录选择器：$e';
        });
      }
      return;
    }

    if (!mounted) return;
    // null = 用户取消：**不改变现有目录**，也不报错。
    // 若把取消当成「清空目录」，用户点一下取消就丢了配置。
    if (picked == null) {
      setState(() => _picking = false);
      return;
    }

    setState(() {
      _picking = false;
      _localRoot = picked;
      // 换目录后旧结果不再有意义（它描述的是旧目录）。
      _report = null;
    });
    widget.onLocalRootChanged?.call(picked);
  }

  Future<void> _handleSync() async {
    if (_busy) return;

    if (_localRoot == null || _localRoot!.isEmpty) {
      // 在发起前拦住：否则会拿到一个「未指定目录」的底层错误，
      // 而用户需要知道的是「先去选目录」。
      setState(() => _error = '请先选择同步目录');
      return;
    }

    setState(() {
      _syncing = true;
      _error = null;
      _report = null;
    });

    try {
      final report = await widget.runSync();
      if (!mounted) return;
      setState(() {
        _syncing = false;
        _report = report;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _syncing = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _syncing = false;
        _error = '同步失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: SpbSpacing.pagePadding,
        children: [
          _DirectoryCard(
            localRoot: _localRoot,
            busy: _busy,
            picking: _picking,
            onPick: _handlePick,
          ),
          const SizedBox(height: SpbSpacing.lg),
          FilledButton.icon(
            key: const ValueKey('sync-start-button'),
            onPressed: _busy ? null : _handleSync,
            icon: _syncing
                ? const SizedBox(
                    width: SpbSpacing.lg,
                    height: SpbSpacing.lg,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined),
            label: Text(_syncing ? '同步中…' : '立即同步'),
          ),
          const SizedBox(height: SpbSpacing.sm),
          Text(
            '单向同步：只把远端交付物拉到本地，不会上传本地改动。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: SpbSpacing.lg),
            _ErrorBanner(message: _error!),
          ],
          if (_report != null) ...[
            const SizedBox(height: SpbSpacing.lg),
            _ReportCard(report: _report!),
          ],
        ],
      ),
    );
  }
}

/// 同步目录卡片。
class _DirectoryCard extends StatelessWidget {
  const _DirectoryCard({
    required this.localRoot,
    required this.busy,
    required this.picking,
    required this.onPick,
  });

  final String? localRoot;
  final bool busy;
  final bool picking;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasRoot = localRoot != null && localRoot!.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Row(
          children: [
            Icon(
              hasRoot ? Icons.folder_outlined : Icons.folder_off_outlined,
              color: hasRoot ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: SpbSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('同步目录', style: textTheme.labelMedium),
                  const SizedBox(height: SpbSpacing.xxs),
                  Text(
                    // 未选目录时给出**行动指引**而非「未知」：
                    // 「未知」会让用户以为出错了，实际只是还没配。
                    hasRoot ? localRoot! : '尚未选择（点右侧按钮选择）',
                    key: const ValueKey('sync-local-root'),
                    style: textTheme.bodyMedium?.copyWith(
                      color: hasRoot ? null : scheme.onSurfaceVariant,
                    ),
                    // 路径可能很长（嵌套很深），必须省略而不是溢出。
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            TextButton(
              key: const ValueKey('sync-pick-directory'),
              onPressed: busy ? null : onPick,
              child: Text(picking ? '选择中…' : '选择目录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 同步结果卡片。
///
/// 展示「下载 N 个 / 跳过 M 个 / 失败 K 个」与逐条失败原因。
class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final SyncReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final failed = report.failed;

    return Card(
      key: const ValueKey('sync-report'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  failed.isEmpty
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_outlined,
                  color: failed.isEmpty ? scheme.tertiary : scheme.error,
                ),
                const SizedBox(width: SpbSpacing.sm),
                Text('同步完成', style: textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: SpbSpacing.md),
            Wrap(
              spacing: SpbSpacing.lg,
              runSpacing: SpbSpacing.sm,
              children: [
                _Stat(
                  key: const ValueKey('sync-stat-downloaded'),
                  label: '下载',
                  value: report.downloaded,
                ),
                if (report.notModified > 0)
                  _Stat(
                    key: const ValueKey('sync-stat-not-modified'),
                    label: '未变更',
                    value: report.notModified,
                  ),
                if (report.deleted > 0)
                  _Stat(
                    key: const ValueKey('sync-stat-deleted'),
                    label: '删除',
                    value: report.deleted,
                  ),
                _Stat(
                  key: const ValueKey('sync-stat-skipped'),
                  // 跳过数取各类之和：用户关心的是「有多少没同步」，
                  // 分类明细在下面单独列出。
                  label: '跳过',
                  value: report.skipped.values.fold(0, (a, b) => a + b),
                ),
                _Stat(
                  key: const ValueKey('sync-stat-failed'),
                  label: '失败',
                  value: failed.length,
                  danger: failed.isNotEmpty,
                ),
              ],
            ),
            if (report.skipped.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.md),
              Text('跳过明细', style: textTheme.labelMedium),
              const SizedBox(height: SpbSpacing.xxs),
              for (final entry in report.skipped.entries)
                Text(
                  '· ${entry.key.description}：${entry.value} 个',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
            if (failed.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.md),
              Text('失败项', style: textTheme.labelMedium),
              const SizedBox(height: SpbSpacing.xxs),
              // 逐条列出而非只给数量：用户需要知道**哪个文件**失败了
              // 才能判断要不要处理（如权限问题）。
              for (final f in failed)
                Padding(
                  key: ValueKey('sync-failure-${f.relPath}'),
                  padding: const EdgeInsets.only(top: SpbSpacing.xs),
                  child: Text(
                    '· ${f.relPath}：${f.reason}',
                    style: textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单个统计数字。
class _Stat extends StatelessWidget {
  const _Stat({
    super.key,
    required this.label,
    required this.value,
    this.danger = false,
  });

  final String label;
  final int value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = danger ? scheme.error : scheme.onSurface;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: textTheme.bodySmall?.copyWith(color: color)),
        const SizedBox(width: SpbSpacing.xs),
        Text('$value 个', style: textTheme.titleSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// 错误提示条。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('sync-error'),
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
