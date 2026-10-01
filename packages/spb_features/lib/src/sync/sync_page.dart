import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_ui/spb_ui.dart';

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

/// 扫描本地改动（脏检测）。
///
/// 返回 [LocalDirtyScanResult]（逐文件明细 + 跳过/读取失败统计）；整轮无法进行
/// 时抛 [SpbError]。
///
/// ## 为什么扫描与回传是**两个**回调而不是一个
///
/// 设计文档 §6 要求「上传前**逐文件可见**，不搞一键全传黑箱」。把扫描与上传
/// 合成一个「回传」回调，UI 就只能在拿到最终报告后才能展示文件列表——那时
/// 覆盖已经发生了。拆成两步后，列表先渲染、用户逐条勾选、再触发上传。
///
/// 与 [RunSyncAction] 同一分工：单文件问题在返回值里，整轮问题抛异常。
typedef ScanDirtyFilesAction = Future<LocalDirtyScanResult> Function();

/// 回传**选中的**本地改动。
///
/// 参数是本地相对路径集合（与状态表键完全一致）；返回 [UploadReport]
/// （每文件终态：已回传 / 冲突已物化 / 走快速捕获 / 已跳过 / 失败原因）。
///
/// 参数是集合而不是「全部」：这个签名本身就在阻止「一键全传」——调用方
/// 无法表达「我不管哪些文件，全传」这个意图。
typedef UploadChangesAction = Future<UploadReport> Function(Set<String> only);

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
/// ## 同步是「单向」的，回传是「显式」的
///
/// **自动同步**（[runSync]）永远是 UFS → 本地单向，不会上传本地改动——反向
/// 自动同步会触发服务端 groupsync 的写入回路（emit `agent.file.*` → 可能引发
/// 渲染推送/重跑，见 `docs/deliverable-upload-and-conflict.md` §4.1）。
///
/// 但用户确实可能改本地交付物（改完让 agent 接着做），所以本页另提供一条
/// **显式**的回传通道（[scanDirtyFiles] + [uploadChanges]）：先扫描出本地
/// 改动，用户**逐文件**勾选后才上传。两者不矛盾——一个是自动且只读，一个是
/// 手动且逐文件确认。
///
/// ⚠️ 回传成功后文案只说「**已回传**」，不说「已同步」：上传响应不含 etag，
/// 本地无法 `markSynced`，收口要等下一轮同步把新内容拉回来覆盖本地（见设计
/// 文档 §2.1③）。说「已同步」会让用户以为本地状态已对齐，而它还没。
class SyncPage extends StatefulWidget {
  const SyncPage({
    super.key,
    required this.pickDirectory,
    required this.runSync,
    this.scanDirtyFiles,
    this.uploadChanges,
    this.initialLocalRoot,
    this.onLocalRootChanged,
    this.onOpenDirectory,
    this.title = '交付物同步',
  });

  /// 弹出目录选择器。返回 null = 用户取消。
  final PickSyncDirectory pickDirectory;

  /// 执行一轮同步。
  final RunSyncAction runSync;

  /// 扫描本地改动。null = 不展示「回传改动」入口。
  ///
  /// 与 [onOpenDirectory] 同一约定：**装配层没接就不显示**，而不是显示一个
  /// 点了没反应的按钮。
  final ScanDirtyFilesAction? scanDirtyFiles;

  /// 回传选中的本地改动。null = 不展示回传入口。
  ///
  /// 两个回调必须**成对**提供（只给一个的话页面会在扫描后无处可去，或在
  /// 上传时无列表可选），故 [_SyncPageState] 以 [scanDirtyFiles] 是否为 null
  /// 作为整个入口的开关。
  final UploadChangesAction? uploadChanges;

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

  /// 在文件管理器中打开当前同步目录（桌面端）。null = 不展示该入口
  /// （移动端无目录概念）。
  final Future<bool> Function(String path)? onOpenDirectory;

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

  /// 本地改动扫描结果。null = 尚未扫描。
  LocalDirtyScanResult? _dirtyScan;

  /// 是否正在扫描本地改动。
  bool _scanning = false;

  /// 是否正在回传。
  bool _uploading = false;

  /// 用户勾选的待回传文件（本地相对路径）。
  Set<String> _selected = {};

  /// 上一轮回传的结果。null = 尚未回传过。
  UploadReport? _uploadReport;

  bool get _busy => _picking || _syncing;

  /// 回传入口是否可用（两个回调必须成对提供，见 [SyncPage.uploadChanges]）。
  bool get _uploadEnabled =>
      widget.scanDirtyFiles != null && widget.uploadChanges != null;

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

  /// 在系统文件管理器中打开当前同步目录。失败时用 SnackBar 提示
  /// （不静默失败——用户点了没反应会以为应用卡住）。
  Future<void> _handleOpenDirectory() async {
    final path = _localRoot;
    final cb = widget.onOpenDirectory;
    if (path == null || path.isEmpty || cb == null) return;
    final ok = await cb(path);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开目录，请检查路径是否存在')));
    }
  }

  /// 扫描本地改动（回传入口第一步）。
  ///
  /// ## 为什么扫描不需要选目录也能发起
  ///
  /// 目录只是本地根路径的展示/配置，扫描回调闭包里已持有真实根（装配层从
  /// 配置读）。这里只在**未配回调**时拦（按钮本就不会出现）。
  Future<void> _handleScanDirty() async {
    if (_busy || _scanning || _uploading) return;
    final scan = widget.scanDirtyFiles;
    if (scan == null) return;

    setState(() {
      _scanning = true;
      _error = null;
    });

    try {
      final result = await scan();
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _dirtyScan = result;
        // 新扫描覆盖旧的勾选与报告：报告描述的是上一轮的提交。
        _selected = {for (final d in result.dirty) d.relPath};
        _uploadReport = null;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = '扫描本地改动失败：$e';
      });
    }
  }

  /// 回传选中的文件（第二步）。
  Future<void> _handleUpload() async {
    if (_busy || _uploading) return;
    final upload = widget.uploadChanges;
    if (upload == null || _selected.isEmpty) return;

    setState(() {
      _uploading = true;
      _error = null;
    });

    try {
      final report = await upload(Set.of(_selected));
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _uploadReport = report;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = '回传失败：$e';
      });
    }
  }

  void _toggleSelected(String relPath, bool value) {
    setState(() {
      if (value) {
        _selected.add(relPath);
      } else {
        _selected.remove(relPath);
      }
    });
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
          if (widget.onOpenDirectory != null &&
              _localRoot != null &&
              _localRoot!.isNotEmpty) ...[
            const SizedBox(height: SpbSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('sync-open-directory'),
                onPressed: _handleOpenDirectory,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开目录'),
              ),
            ),
          ],
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
            // 两句话把两条通道说清：自动同步不回传（防「我改的怎么没了」），
            // 回传是显式动作（防用户以为必须手动同步才能让 agent 感知）。
            '自动同步不会上传本地改动；可用「回传改动」把选中的修改显式交给 agent。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: SpbSpacing.lg),
            ErrorBanner(key: const ValueKey('sync-error'), message: _error!),
          ],
          if (_report != null) ...[
            const SizedBox(height: SpbSpacing.lg),
            _ReportCard(report: _report!),
          ],
          if (_uploadEnabled) ...[
            const SizedBox(height: SpbSpacing.lg),
            _UploadSection(
              scan: _dirtyScan,
              scanning: _scanning,
              uploading: _uploading,
              selected: _selected,
              report: _uploadReport,
              onScan: _handleScanDirty,
              onUpload: _handleUpload,
              onToggle: _toggleSelected,
              disabled: _busy,
            ),
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

/// 回传改动区块：扫描入口 + 脏文件勾选列表 + 提交按钮 + 结果卡片。
///
/// ## 为什么是一个「区块」而不是散在页面里
///
/// 回传有**两步**（扫描 → 勾选 → 提交），每步有自己的进行中状态；散写的话
/// 「扫描中按钮禁不禁用」「报告该不该显示」会散成六个条件分支。收进一个
/// widget 后，[SyncPage] 的 build 只多一个 `if (_uploadEnabled)`。
class _UploadSection extends StatelessWidget {
  const _UploadSection({
    required this.scan,
    required this.scanning,
    required this.uploading,
    required this.selected,
    required this.report,
    required this.onScan,
    required this.onUpload,
    required this.onToggle,
    required this.disabled,
  });

  final LocalDirtyScanResult? scan;
  final bool scanning;
  final bool uploading;
  final Set<String> selected;
  final UploadReport? report;
  final VoidCallback onScan;
  final VoidCallback onUpload;
  final void Function(String relPath, bool value) onToggle;

  /// 下行同步/选目录进行中时也禁用回传（同一个本地目录，避免并发读写混淆）。
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: const ValueKey('upload-section'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.upload_outlined),
                const SizedBox(width: SpbSpacing.sm),
                Expanded(child: Text('回传改动', style: textTheme.titleSmall)),
                TextButton.icon(
                  key: const ValueKey('upload-scan-button'),
                  onPressed: disabled || scanning || uploading ? null : onScan,
                  icon: scanning
                      ? const SizedBox(
                          width: SpbSpacing.md,
                          height: SpbSpacing.md,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search_outlined),
                  label: Text(scanning ? '扫描中…' : '扫描改动'),
                ),
              ],
            ),
            const SizedBox(height: SpbSpacing.xxs),
            Text(
              // 先讲清语义再给入口：用户需要知道「扫描」只读不改任何东西。
              '扫描会把本地内容与上次同步的记录逐文件比对，只有真正改过的文件会出现在下面。',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (scan == null)
              const SizedBox.shrink()
            else if (scan!.isEmpty) ...[
              const SizedBox(height: SpbSpacing.md),
              // 空态必须显式：不说的话用户不知道扫描做完没有。
              Text(
                scan!.summarize(),
                key: const ValueKey('upload-empty'),
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ] else ...[
              const SizedBox(height: SpbSpacing.md),
              Text(
                // 摘要行给出「改动 N 个」与无法检测/读取失败的口径，
                // 与下面的逐文件列表互补。
                scan!.summarize(),
                key: const ValueKey('upload-scan-summary'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: SpbSpacing.xs),
              // 逐文件勾选：设计文档 §6「上传前逐文件可见，不搞一键全传黑箱」。
              for (final d in scan!.dirty)
                CheckboxListTile(
                  key: ValueKey('upload-file-${d.relPath}'),
                  value: selected.contains(d.relPath),
                  onChanged: uploading
                      ? null
                      : (v) => onToggle(d.relPath, v ?? false),
                  // dense + 控件内边距：脏文件可能几十个，默认密度太占屏。
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    d.relPath,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  subtitle: Text('${d.localSize} 字节'),
                ),
              const SizedBox(height: SpbSpacing.xs),
              FilledButton.icon(
                key: const ValueKey('upload-submit-button'),
                onPressed: disabled || uploading || selected.isEmpty
                    ? null
                    : onUpload,
                icon: uploading
                    ? const SizedBox(
                        width: SpbSpacing.md,
                        height: SpbSpacing.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(
                  uploading
                      ? '回传中…'
                      : selected.isEmpty
                      ? '回传改动'
                      : '回传选中的 ${selected.length} 个改动',
                ),
              ),
            ],
            if (report != null) ...[
              const SizedBox(height: SpbSpacing.md),
              _UploadResultCard(report: report!),
            ],
          ],
        ),
      ),
    );
  }
}

/// 回传结果卡片。
///
/// ## 为什么文案说「已回传」不说「已同步」
///
/// 上传响应不含 etag，本地无法 `markSynced`；本地要等下一轮同步拉回新内容
/// 才对齐。说「已同步」会让用户以为本地状态已对齐，而它还没。
/// （设计文档 §2.1③。）
class _UploadResultCard extends StatelessWidget {
  const _UploadResultCard({required this.report});

  final UploadReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final failed = report.byOutcome(UploadOutcome.failed);
    // 已上传但没能通知 agent 的条目：agent 还不知道这些文件改了，
    // 用户需要手动在对话里说一声（或重跑回传）。
    final notNotified = report.notifiedFailed;

    return Card(
      key: const ValueKey('upload-report'),
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
                Expanded(child: Text('回传完成', style: textTheme.titleSmall)),
              ],
            ),
            const SizedBox(height: SpbSpacing.md),
            Text(
              report.summarize(),
              key: const ValueKey('upload-report-summary'),
              style: textTheme.bodyMedium,
            ),
            // 逐文件终态：设计文档 §6「413 / 400 等服务端拒绝按『此文件无法
            // 回传 + 原因』呈现，不算同步失败」——失败只属于单个文件。
            for (final item in report.items)
              Padding(
                key: ValueKey('upload-result-${item.relPath}'),
                padding: const EdgeInsets.only(top: SpbSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('· ${item.relPath}：', style: textTheme.bodySmall),
                    const SizedBox(width: SpbSpacing.xxs),
                    Expanded(
                      child: Text(
                        // 成功条目带冲突副本路径（用户可能要去比对两份）；
                        // 失败/跳过条目带原因。
                        item.conflictPath != null
                            ? '${item.outcome.description}（副本：${item.conflictPath}）'
                            : item.reason ?? item.outcome.description,
                        style: textTheme.bodySmall?.copyWith(
                          color: item.outcome == UploadOutcome.failed
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (notNotified.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.md),
              Text(
                // 通知失败不回滚上传：文件已在 workspace 里，但 agent 不知道。
                // 如实告诉用户这个差异，而不是假装一切完成。
                '注意：${notNotified.length} 个文件已上传但未能通知 agent，'
                '请在对话中告知或稍后重试。',
                key: const ValueKey('upload-notify-warning'),
                style: textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
