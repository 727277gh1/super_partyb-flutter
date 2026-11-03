import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_ui/spb_ui.dart';

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

/// 「立即同步 + 本轮结果 + 回传改动」区块。
///
/// ## 为什么它是「区块」而不是一个独立页面
///
/// 它曾经是一个独立的「交付物同步」页（`SyncPage`），与「设置」页分开。那个
/// 划分带来两个真实问题（用户报障的原点）：
///
/// 1. **配置与执行分居两处**：目录 / 范围 / 过滤 / 自动同步在设置页，跑同步与
///    看结果在同步页。用户想「让它自动下载」必须跨两个页面拼出完整因果，
///    托盘里「同步设置…」与「设置…」两项更是让人分不清去哪。
/// 2. **同一个目录卡片被画两遍**（两边都能选目录），于是一边改的目录要到
///    另一边才生效，出现「在同步页选了目录，自动同步却没武装」的缝隙。
///
/// 现在它是设置页「交付物同步」标签里的一个区块，与目录 / 范围 / 过滤 /
/// 自动同步同屏。本组件**不含**目录选择——目录只由设置页那一处负责
/// （见 [localRoot]）。
///
/// ## 分层职责（与 [LoginPage] 一致）
///
/// 只负责渲染与交互；网络、磁盘、配置持久化全部由注入的回调承担，因此本组件
/// 可以在无文件系统、无网络、无平台插件的 widget test 里完整验证。
///
/// ## 同步是「单向」的，回传是「显式」的
///
/// **下行同步**（[runSync]，以及自动同步的四条通道）永远是 UFS → 本地单向，
/// 不会上传本地改动——反向自动同步会触发服务端 groupsync 的写入回路（emit
/// `agent.file.*` → 可能引发渲染推送/重跑，见
/// `docs/deliverable-upload-and-conflict.md` §4.1）。
///
/// 但用户确实可能改本地交付物（改完让 agent 接着做），所以这里另提供一条
/// **显式**的回传通道（[scanDirtyFiles] + [uploadChanges]）：先扫描出本地改动，
/// 用户**逐文件**勾选后才上传。两者不矛盾——一个是自动且只读，一个是手动且
/// 逐文件确认。
///
/// ⚠️ 回传成功后文案只说「**已回传**」，不说「已同步」：上传响应不含 etag，
/// 本地无法 `markSynced`，收口要等下一轮同步把新内容拉回来覆盖本地（见设计
/// 文档 §2.1③）。说「已同步」会让用户以为本地状态已对齐，而它还没。
class SyncRunSection extends StatefulWidget {
  const SyncRunSection({
    super.key,
    required this.runSync,
    required this.localRoot,
    this.hasUnsavedChanges = false,
    this.scanDirtyFiles,
    this.uploadChanges,
  });

  /// 执行一轮同步。
  final RunSyncAction runSync;

  /// 当前**生效**的同步目录（用于「未配目录」的前置拦截与提示）。
  ///
  /// 由调用方（设置页）传入——目录卡片也在那里，两处必须是同一个值。
  /// 真正发起同步时装配层自己从配置读根路径，本组件不碰存储。
  final String? localRoot;

  /// 设置页存在**未保存**的改动。
  ///
  /// ## 为什么要为它专门禁用「立即同步」
  ///
  /// 目录 / 范围 / 过滤都是草稿：用户改了目录还没点「保存」时，同步实际会用
  /// **旧**目录跑。让按钮在这种情况下可用，等于让用户做一次他以为配好了、
  /// 其实没配好的同步。禁用 + 说明比「让他踩坑」诚实。
  final bool hasUnsavedChanges;

  /// 扫描本地改动。null = 不展示「回传改动」入口。
  ///
  /// 与其余可选注入同一约定：**装配层没接就不显示**，而不是显示一个
  /// 点了没反应的按钮。
  final ScanDirtyFilesAction? scanDirtyFiles;

  /// 回传选中的本地改动。null = 不展示回传入口。
  ///
  /// 两个回调必须**成对**提供（只给一个的话区块会在扫描后无处可去，或在
  /// 上传时无列表可选），故 [_SyncRunSectionState] 以 [scanDirtyFiles] 是否为
  /// null 作为整个入口的开关。
  final UploadChangesAction? uploadChanges;

  @override
  State<SyncRunSection> createState() => _SyncRunSectionState();
}

class _SyncRunSectionState extends State<SyncRunSection> {
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

  bool get _busy => _syncing;

  /// 回传入口是否可用（两个回调必须成对提供，见 [SyncRunSection.uploadChanges]）。
  bool get _uploadEnabled =>
      widget.scanDirtyFiles != null && widget.uploadChanges != null;

  @override
  void didUpdateWidget(SyncRunSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 目录变了（保存了新目录）→ 上一轮结果描述的是旧目录，不再有意义。
    if (oldWidget.localRoot != widget.localRoot) {
      _report = null;
    }
  }

  /// 扫描本地改动（回传入口第一步）。
  ///
  /// ## 为什么扫描不需要目录也能发起
  ///
  /// 目录只是本地根路径的展示/配置，扫描回调的闭包里已持有真实根（装配层从
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
    if (_busy || widget.hasUnsavedChanges) return;

    final root = widget.localRoot;
    if (root == null || root.trim().isEmpty) {
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
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const ValueKey('sync-start-button'),
          // 有未保存改动时也禁用：见 [SyncRunSection.hasUnsavedChanges]。
          onPressed: (_busy || widget.hasUnsavedChanges) ? null : _handleSync,
          icon: _syncing
              ? const SizedBox(
                  width: SpbSpacing.lg,
                  height: SpbSpacing.lg,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download_outlined),
          label: Text(_syncing ? '同步中…' : '立即同步'),
        ),
        const SizedBox(height: SpbSpacing.xs),
        Text(
          // 两句话把两条通道说清：自动同步不回传（防「我改的怎么没了」），
          // 回传是显式动作（防用户以为必须手动同步才能让 agent 感知）。
          '手动与自动的同步都只从云端拉取到本地；本地改动要用「回传改动」显式交给 agent。',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (widget.hasUnsavedChanges) ...[
          const SizedBox(height: SpbSpacing.xs),
          Text(
            // 与按钮禁用配对：不说明原因，用户只会看到「按钮是灰的」。
            '上方设置有未保存的改动，先点右上角「保存」再同步（否则本轮仍用旧配置）。',
            key: const ValueKey('sync-unsaved-hint'),
            style: textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
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

/// 回传改动区块：扫描入口 + 脏文件勾选列表 + 提交按钮 + 结果卡片。
///
/// ## 为什么是一个「区块」而不是散在页面里
///
/// 回传有**两步**（扫描 → 勾选 → 提交），每步有自己的进行中状态；散写的话
/// 「扫描中按钮禁不禁用」「报告该不该显示」会散成六个条件分支。收进一个
/// widget 后，[SyncRunSection] 的 build 只多一个 `if (_uploadEnabled)`。
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

  /// 下行同步进行中时也禁用回传（同一个本地目录，避免并发读写混淆）。
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
