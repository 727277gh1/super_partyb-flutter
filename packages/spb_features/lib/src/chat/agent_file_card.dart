import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// Agent 产出的文件卡（`agent.file.*` 事件归约而来）。
///
/// ## 交互对齐 webapp `ChatAgentFileCard`
///
/// - 图片本应自动内联缩略图，文档类只显示信息行（长文档内联会拖累滚动与流量）。
///   实际缩略图加载走 [onLoadThumbnail]（注入，返回字节）；未注入时退化为图标，
///   不硬依赖网络（本机无 DISPLAY 无法验证真图渲染，留给真机手测）。
/// - 下载走 [onDownload]（注入，app 层调 `UfsApi.download`）；**组件库不直接
///   依赖 `spb_api`**——保持卡片纯 UI、可无头单测（与 `ConfirmationCard`
///   注入 `onResolve` 同一约定）。
/// - deleted 时禁用下载与缩略图（UFS 已软删，点了会 404）。
///
/// ## 不做「加入上下文 / 移除」操作
///
/// webapp 有该操作（`onToggleContext`），但对应端点本轮未核实，留待后续。
class AgentFileCard extends StatefulWidget {
  const AgentFileCard({
    super.key,
    required this.file,
    this.onDownload,
    this.onLoadThumbnail,
  });

  final AgentFileItem file;

  /// 下载回调。null（或文件已删除、无 fileId）时下载按钮禁用。
  final Future<void> Function(AgentFileItem file)? onDownload;

  /// 缩略图加载回调（仅图片有意义）。返回字节则内联渲染，null/失败退化为图标。
  /// 不注入时一律退化（不发起网络请求），适合无头环境。
  final Future<List<int>> Function()? onLoadThumbnail;

  @override
  State<AgentFileCard> createState() => _AgentFileCardState();
}

class _AgentFileCardState extends State<AgentFileCard> {
  List<int>? _thumbnail;
  bool _loadingThumb = false;
  bool _downloading = false;
  /// narration 默认折叠（见 [_buildVoiceTile]）。
  bool _narrationExpanded = false;

  AgentFileItem get f => widget.file;

  @override
  void didUpdateWidget(AgentFileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 身份变了（同卡被更新到另一个文件）或缩略图回调变了：重置缓存。
    if (oldWidget.file.id != f.id ||
        oldWidget.onLoadThumbnail != widget.onLoadThumbnail) {
      _thumbnail = null;
      if (!_loadingThumb) _maybeLoadThumbnail();
    }
  }

  @override
  void initState() {
    super.initState();
    _maybeLoadThumbnail();
  }

  Future<void> _maybeLoadThumbnail() async {
    if (!f.isImage) return; // 只给图片加载缩略图
    final loader = widget.onLoadThumbnail;
    if (loader == null || f.isDeleted) return;
    setState(() => _loadingThumb = true);
    try {
      final bytes = await loader();
      if (!mounted) return;
      setState(() {
        _thumbnail = bytes;
        _loadingThumb = false;
      });
    } on Object catch (e) {
      // 缩略图失败不阻断卡片：退化为图标，让用户仍能下载。
      if (!mounted) return;
      setState(() => _loadingThumb = false);
      SpbLog.debug('加载 agent 文件缩略图失败', {'file': f.fileName, 'error': '$e'});
    }
  }

  Future<void> _handleDownload() async {
    if (_downloading) return; // 防重复点击
    final cb = widget.onDownload;
    if (cb == null) return;
    setState(() => _downloading = true);
    try {
      await cb(f);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // TTS 语音产物：渲染为语音条目而非普通文件卡。
    if (f.ttsKind != null) return _buildVoiceTile(context);

    final scheme = Theme.of(context).colorScheme;
    final canDownload =
        widget.onDownload != null && !f.isDeleted && !_downloading;

    return Card(
      margin: EdgeInsets.zero,
      child: Opacity(
        // deleted 置灰但保留（用户应看到「这个文件被删了」而非凭空消失）。
        opacity: f.isDeleted ? 0.5 : 1.0,
        child: Padding(
          padding: SpbSpacing.cardPadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _leading(scheme),
              const SizedBox(width: SpbSpacing.md),
              Expanded(child: _body(context)),
              if (!f.isDeleted) _downloadButton(canDownload),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leading(ColorScheme scheme) {
    if (_loadingThumb) {
      return SizedBox(
        width: SpbSpacing.xxxl,
        height: SpbSpacing.xxxl,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_thumbnail != null && _thumbnail!.isNotEmpty) {
      // 图片缩略图：用内存字节渲染。失败（如字节损坏）退化为图标，
      // 不让整卡崩——这正是加 try/catch 的目的。
      return ClipRRect(
        borderRadius: SpbRadius.cardAll,
        child: Image.memory(
          Uint8List.fromList(_thumbnail!),
          width: SpbSpacing.xxxl,
          height: SpbSpacing.xxxl,
          fit: BoxFit.cover,
          errorBuilder: (c, o, s) => _fileIcon(scheme),
        ),
      );
    }
    return _fileIcon(scheme);
  }

  Widget _fileIcon(ColorScheme scheme) => Icon(
    f.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
    size: SpbSpacing.xxxl,
    color: f.isDeleted ? scheme.outline : scheme.primary,
  );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          f.displayName.isEmpty ? f.fileName : f.displayName,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: SpbSpacing.xxs),
        Wrap(
          spacing: SpbSpacing.sm,
          runSpacing: SpbSpacing.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _lifecycleBadge(scheme),
            if (f.sizeBytes != null && f.sizeBytes! > 0)
              Text(
                _formatBytes(f.sizeBytes!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (f.mimeType != null && f.mimeType!.isNotEmpty)
              Text(
                f.mimeType!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ],
    );
  }

  Widget _lifecycleBadge(ColorScheme scheme) {
    // action 取阶段优先级（deleted > modified > created），与归约一致。
    final (IconData icon, Color bg, String label) = switch (f.action) {
      'deleted' => (
        Icons.delete_outline,
        scheme.errorContainer,
        '已删除',
      ),
      'modified' => (
        Icons.edit_outlined,
        scheme.tertiaryContainer,
        '已更新',
      ),
      _ => (Icons.add_circle_outline, scheme.secondaryContainer, '已生成'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: SpbSpacing.lg),
          const SizedBox(width: SpbSpacing.xxs),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }

  Widget _downloadButton(bool canDownload) => IconButton(
    key: const ValueKey('agent-file-download'),
    icon: _downloading
        ? const SizedBox(
            width: SpbSpacing.lg,
            height: SpbSpacing.lg,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.download_outlined),
    tooltip: f.isDeleted ? '文件已删除' : '下载',
    onPressed: canDownload ? _handleDownload : null,
  );

  /// TTS 语音条目（播放图标 + 种类标签 + 大小，可下载）。
  //
  // ## 为什么不做应用内播放
  //
  // 播放需新增音频依赖（`just_audio`/`audioplayers`）与移动端后台播放策略，
  // 本轮不在范围内（见 task nonGoals）。当前只提供「下载」——用户下载后用系统
  // 播放器听。播放图标在此仅作语义提示，不绑定播放动作。
  //
  // ## narration 默认折叠
  //
  // 思考填充语不是对用户的回复，一个 turn 可产出数十条，全部展开会淹没对话
  // （对齐 webapp「narration 不进语音回复列表」）。这里用一个可展开的紧凑行：
  // 默认只显示种类标签，点开后才显示大小与下载入口。reply/filesummary 默认展开。
  Widget _buildVoiceTile(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isNarration = f.ttsKind == TtsStreamKind.narration;
    final collapsed = isNarration && !_narrationExpanded;

    final (String kindLabel, IconData kindIcon) = switch (f.ttsKind) {
      TtsStreamKind.reply => ('回复语音', Icons.record_voice_over_outlined),
      TtsStreamKind.narration => ('思考填充语', Icons.psychology_outlined),
      TtsStreamKind.filesummary => ('文件播报', Icons.summarize_outlined),
      null => ('语音', Icons.graphic_eq_outlined),
    };

    Widget content = Row(
      children: [
        Icon(kindIcon, size: SpbSpacing.xxxl, color: scheme.primary),
        const SizedBox(width: SpbSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(kindLabel, style: theme.textTheme.titleSmall),
              if (!collapsed) ...[
                const SizedBox(height: SpbSpacing.xxs),
                Wrap(
                  spacing: SpbSpacing.sm,
                  runSpacing: SpbSpacing.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (f.sizeBytes != null && f.sizeBytes! > 0)
                      Text(
                        _formatBytes(f.sizeBytes!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (f.mimeType != null && f.mimeType!.isNotEmpty)
                      Text(
                        f.mimeType!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        // narration 折叠时不显示下载（点开后才出现），其余始终显示。
        if (!collapsed && !f.isDeleted) _downloadButton(_canDownload),
        if (isNarration)
          IconButton(
            key: const ValueKey('tts-narration-toggle'),
            icon: Icon(
              _narrationExpanded
                  ? Icons.expand_less
                  : Icons.expand_more,
            ),
            tooltip: _narrationExpanded ? '收起' : '展开',
            onPressed: f.isDeleted
                ? null
                : () => setState(
                      () => _narrationExpanded = !_narrationExpanded,
                    ),
          ),
      ],
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Opacity(
        opacity: f.isDeleted ? 0.5 : 1.0,
        child: Padding(padding: SpbSpacing.cardPadding, child: content),
      ),
    );
  }

  bool get _canDownload =>
      widget.onDownload != null && !f.isDeleted && !_downloading;

  /// 人类可读的字节大小。
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
