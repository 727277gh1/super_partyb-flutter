import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'agent_file_card.dart';
import 'agent_file_preview.dart';

/// Agent 文件批量产出聚合卡（时间线内嵌）。
///
/// ## 它解决什么
///
/// 一次产出数十个候选（真实场景，见 webapp 注释）时，时间线会被几十张同构
/// 文件卡淹没，把对话正文挤出视野。本卡把这些折叠成**一张**摘要，点击展开后
/// 逐条渲染原始 [AgentFileCard]（可下载 / 打开 / 看缩略图）。
///
/// ## 折叠态不内联缩略图 / 预览
///
/// 与 webapp `ChatAgentFileBatchCard` 同一取舍：批量场景逐个加载预览会产生
/// N 倍并发请求（弱网拖垮首屏）。故折叠态只显示计数与类型分布；展开后才按需
/// 加载（展开项复用 [AgentFileCard]，其缩略图加载是懒的）。
///
/// ## 展开态是组件内 State，不进归约
///
/// 与 `#9` 超时兜底同一取向：**派生信号不改归约**。展开与否纯属这一帧的视图
/// 状态，写进 `ConversationItem` 会让「数据」与「怎么画」耦合。副作用是切换
/// 对话/重开页面后展开态复位——与 webapp 一致（`React.useState(false)`）。
class AgentFileBatchCard extends StatefulWidget {
  const AgentFileBatchCard({
    super.key,
    required this.batch,
    this.onDownload,
    this.onLoadThumbnail,
    this.onOpen,
    this.onReveal,
    this.onPreview,
  });

  final AgentFileBatchRow batch;

  /// 以下四个回调原样透传给展开后的每个 [AgentFileCard]。
  /// 语义与单卡完全一致（见 `AgentFileCard` 的文档）。
  ///
  /// [onLoadThumbnail] 收 `file` 而非无参：每个成员要绑自己的文件。
  /// 单卡的 `onLoadThumbnail` 是无参的（由调用方闭包捕获文件），但批量卡
  /// 一个实例服务 N 个成员，故这里保持「按文件」的形态、由本卡逐个绑定。
  final Future<void> Function(AgentFileItem file)? onDownload;
  final Future<List<int>?> Function(AgentFileItem file)? onLoadThumbnail;
  final OpenAgentFile? onOpen;
  final RevealAgentFile? onReveal;

  /// 预览能力，原样透传给展开后的每个 [AgentFileCard]。
  final AgentFilePreviewCallbacks? onPreview;

  @override
  State<AgentFileBatchCard> createState() => _AgentFileBatchCardState();
}

class _AgentFileBatchCardState extends State<AgentFileBatchCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final batch = widget.batch;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _summaryTile(theme, scheme, batch),
        // 展开项：复用单卡（懒加载缩略图），左侧竖线表达「从属于上面那张卡」。
        if (_expanded)
          Padding(
            key: const ValueKey('agent-file-batch-list'),
            padding: const EdgeInsets.only(
              top: SpbSpacing.xs,
              left: SpbSpacing.sm,
            ),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
              padding: const EdgeInsets.only(left: SpbSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final file in batch.files)
                    Padding(
                      // 与逐条渲染同一 key 语义：按归约层的稳定 id（归一化
                      // 相对路径），保证展开/收起时卡片状态不丢失。
                      key: ValueKey('batch-member-${file.id}'),
                      padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
                      child: AgentFileCard(
                        file: file,
                        onDownload: widget.onDownload,
                        // 与 `ConversationPage` 对单卡的绑定同一判据：无 ufsFileId
                        // 时传 null，避免拼出 `/files//thumbnails/256`。
                        onLoadThumbnail:
                            widget.onLoadThumbnail == null ||
                                (file.ufsFileId ?? '').isEmpty
                            ? null
                            : () => widget.onLoadThumbnail!(file),
                        onOpen: widget.onOpen,
                        onReveal: widget.onReveal,
                        onPreview: widget.onPreview,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 折叠态的摘要行（整行可点，展开/收起）。
  Widget _summaryTile(
    ThemeData theme,
    ColorScheme scheme,
    AgentFileBatchRow batch,
  ) {
    final deletedCount = batch.files.where((f) => f.isDeleted).length;

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: SpbRadius.cardAll,
      child: InkWell(
        key: const ValueKey('agent-file-batch-toggle'),
        borderRadius: SpbRadius.cardAll,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: SpbSpacing.cardPadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: SpbSpacing.lg,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: SpbSpacing.sm),
              // 文件夹图标：与文件卡的图片/文档图标形成「一个 vs 一批」的对比。
              Container(
                width: SpbSpacing.xxl,
                height: SpbSpacing.xxl,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.08),
                  borderRadius: SpbRadius.cardAll,
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Icon(
                  Icons.folder_open_outlined,
                  size: SpbSpacing.lg,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: SpbSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            // 标题动词由领域层按批内最新态算出（含删除判定），
                            // 这里只做文案拼接——动词口径三端一致，不该在 UI 重算。
                            '${batch.verb}了 ${batch.count} 个文件',
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: SpbSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: SpbSpacing.xs,
                            vertical: SpbSpacing.xxs,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: SpbRadius.cardAll,
                          ),
                          child: Text('批量', style: theme.textTheme.labelSmall),
                        ),
                      ],
                    ),
                    const SizedBox(height: SpbSpacing.xxs),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _categorySummary(batch.files),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 批内含已删除文件时明示数量：成员卡各自置灰展示删除态，
                        // 但折叠时用户看不到，需要一个数字提示。
                        if (deletedCount > 0) ...[
                          const SizedBox(width: SpbSpacing.sm),
                          Text(
                            '含 $deletedCount 个已删除',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 类型分布摘要（按数量降序，最多三类）。
  ///
  /// 与 webapp `categorize` 同一套分类口径（image / video / audio / doc /
  /// code / other），但只做**计数**，不做交互。
  static String _categorySummary(List<AgentFileItem> files) {
    final counts = <String, int>{};
    for (final f in files) {
      final c = _categoryOf(f);
      counts[c] = (counts[c] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        // 'other' 优先级最低：否则它会占满展示位（同 webapp）。
        if (a.key == 'other' && b.key != 'other') return 1;
        if (b.key == 'other' && a.key != 'other') return -1;
        return b.value.compareTo(a.value);
      });
    return entries
        .take(3)
        .map((e) => '${_categoryLabel(e.key)} ${e.value}')
        .join(' · ');
  }

  /// 按 MIME + 扩展名归类（与 webapp `categorize` 对齐）。
  static String _categoryOf(AgentFileItem f) {
    final mime = (f.mimeType ?? '').split(';').first.trim().toLowerCase();
    if (mime.startsWith('image/')) return 'image';
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) return 'audio';

    final dot = f.fileName.lastIndexOf('.');
    final ext = dot >= 0 ? f.fileName.substring(dot + 1).toLowerCase() : '';
    if (const {'md', 'markdown', 'pdf', 'doc', 'docx', 'txt'}.contains(ext) ||
        mime.contains('markdown') ||
        mime == 'application/pdf') {
      return 'doc';
    }
    if (const {
      'ts',
      'tsx',
      'js',
      'jsx',
      'json',
      'go',
      'py',
      'c',
      'cpp',
      'h',
      'hpp',
      'cc',
      'rs',
      'java',
      'rb',
      'php',
      'sh',
      'yaml',
      'yml',
      'toml',
      'html',
      'htm',
      'css',
      'scss',
      'wasm',
      'vue',
      'svelte',
    }.contains(ext)) {
      return 'code';
    }
    return 'other';
  }

  static String _categoryLabel(String category) => switch (category) {
    'image' => '图片',
    'video' => '视频',
    'audio' => '音频',
    'doc' => '文档',
    'code' => '代码',
    _ => '其它',
  };
}
