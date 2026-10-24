import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'agent_file_preview.dart';

/// 用系统默认程序打开该文件（的本地副本）。返回是否成功发起。
///
/// 与 `group_deliverables_panel.dart` 的 `OpenLocalDeliverable` 同为
/// `Future<bool>` 形态，但入参是 [AgentFileItem] 而非路径：时间线卡片手里只有
/// 事件归约出来的条目，**不知道**本地路径（那由 app 层的落地目录决定）。
/// 让卡片持有路径就等于把「文件存在哪」这个装配层知识塞进组件库。
typedef OpenAgentFile = Future<bool> Function(AgentFileItem file);

/// 在系统文件管理器中定位该文件（的本地副本）。返回是否成功发起。
typedef RevealAgentFile = Future<bool> Function(AgentFileItem file);

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
/// - [onOpen] / [onReveal] 对**本地副本**操作，未注入时连菜单都不渲染
///   （移动端注入的是 `NoopDesktopCapabilities`，接上只会让用户点「打开」
///   得到「无法打开文件」）。
/// - [onPreview] 是**远端内容预览**（与上面两个动作不同：不落盘）。未注入时
///   预览按钮不渲染——「未注入预览能力时行为与现在完全一致」的保证。
///
/// ## 与 `GroupDeliverablesPanel` 的差异（**不要照抄**）
///
/// 面板的 `resolveLocalPath` 查的是**同步目录索引**（「这份交付物我本地有
/// 没有」），而时间线回答的是「这次对话产出了什么」。两者用途不同，故文件卡
/// **不**接 `resolveLocalPath`：时间线不掌握同步索引。
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
    this.onOpen,
    this.onReveal,
    this.onPreview,
  });

  final AgentFileItem file;

  /// 下载回调。null（或文件已删除、无 fileId）时下载按钮禁用。
  final Future<void> Function(AgentFileItem file)? onDownload;

  /// 缩略图加载回调（仅图片有意义）。返回字节则内联渲染，null/失败退化为图标。
  /// 不注入时一律退化（不发起网络请求），适合无头环境。
  ///
  /// 返回类型可空：`UfsApi.thumbnail` 用 null 表达「无缩略图可渲染」的两种
  /// **正常**结果（服务端未启用该能力返回 501、以及 304）。若这里收窄成
  /// `Future<List<int>>`，调用方就只能把 null 编造成空字节，而那会被
  /// `Image.memory` 当成损坏图片抛异常。
  final Future<List<int>?> Function()? onLoadThumbnail;

  /// 用系统默认程序打开本地副本。
  ///
  /// null 时**不渲染**菜单项（而非渲染一个点了没反应的项）——移动端就是这种
  /// 情形（`NoopDesktopCapabilities.openFile` 恒 false）。
  final OpenAgentFile? onOpen;

  /// 在系统文件管理器中定位本地副本。null 时不渲染菜单项（同 [onOpen]）。
  final RevealAgentFile? onReveal;

  /// 文件预览能力（文本 / 图片 / 外部跳转）。
  ///
  /// null 或 [AgentFilePreviewCallbacks.hasAny] 为假时**不渲染**预览按钮
  /// ——与 [onOpen] / [onReveal] 同一约定：不渲染一个点了没反应的入口。
  final AgentFilePreviewCallbacks? onPreview;

  @override
  State<AgentFileCard> createState() => _AgentFileCardState();
}

class _AgentFileCardState extends State<AgentFileCard> {
  List<int>? _thumbnail;
  bool _loadingThumb = false;
  bool _downloading = false;

  /// 打开/定位进行中（防重复点 + 菜单转圈）。
  bool _acting = false;

  /// narration 默认折叠（见 [_buildVoiceTile]）。
  bool _narrationExpanded = false;

  AgentFileItem get f => widget.file;

  @override
  void didUpdateWidget(AgentFileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文件身份变了（同卡被更新到另一个文件）：重置缓存并重拉。
    //
    // ## 为什么不用「回调 identity 变了」作判据
    //
    // 之前的判据是 `oldWidget.onLoadThumbnail != widget.onLoadThumbnail`。
    // 而调用方（`ConversationPage._buildItem` / `AgentFileBatchCard`）都是
    // 在 build 里现包一层闭包——**每次 build 都是新实例**。于是这个判据恒
    // 为真：推一条与文件无关的流式增量（甚至状态条刷新）都会清空缓存并重新
    // 请求缩略图（实测：1 条图片卡 + 3 条无关增量 → 4 次请求）。
    //
    // 回调换了但**文件没换**时无需重拉：新回调与旧回调的契约完全一致
    // （都是「拉这个文件的缩略图字节」），而缓存里的字节就是结果。
    //
    // 三个判据缺一不可：
    //   - `id` 是归约层的稳定身份（归一化相对路径），换文件时它一定变；
    //   - `ufsFileId` 是远端文件 id，同一路径被新版本覆盖时它会变；
    //   - `isDeleted` 翻转需要重新走一遍（删掉后不该继续展示旧缩略图）。
    if (oldWidget.file.id != f.id ||
        oldWidget.file.ufsFileId != f.ufsFileId ||
        oldWidget.file.isDeleted != f.isDeleted) {
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

  /// 能否对**远端文件**发起打开/定位。
  ///
  /// 判据与下载同源：已删除（UFS 已软删，点了会 404）或没有 fileId（无从定位
  /// 本地副本）都不可用。
  bool get _canActOnFile => !f.isDeleted && (f.ufsFileId ?? '').isNotEmpty;

  /// 是否至少有一个文件动作回调（决定行尾菜单是否渲染）。
  bool get _hasFileMenu => widget.onOpen != null || widget.onReveal != null;

  /// 能否预览**远端内容**。
  ///
  /// 判据与打开/定位同源（已删除 / 无 fileId 都不可用），但**不看**平台能力
  /// ——预览是应用内渲染（或跳浏览器），移动端也能做。
  bool get _canPreview =>
      (widget.onPreview?.hasAny ?? false) &&
      !f.isDeleted &&
      (f.ufsFileId ?? '').isNotEmpty;

  Future<void> _handleOpen() => _runAction(widget.onOpen, '无法打开文件', '打开');

  /// 打开预览对话框。
  ///
  /// 不包 `_runAction`：预览没有「返回 bool 表示是否发起成功」的语义——
  /// 失败都发生在对话框内部（取数失败 / 跳转失败），由它自己呈现。
  void _handlePreview() {
    showAgentFilePreview(
      context: context,
      file: f,
      onPreview: widget.onPreview,
    );
  }

  Future<void> _handleReveal() => _runAction(widget.onReveal, '无法定位文件', '定位');

  /// 打开/定位的公共外壳：防重复点、失败反馈、异常不冒泡。
  ///
  /// 回调返回 false = 「未能发起」（本地没有副本且拉不下来、平台能力不支持），
  /// 这正是 issue 要求的「不得静默无响应」——给一句用户能懂的反馈，
  /// 而不是让菜单项点下去什么都没发生。
  Future<void> _runAction(
    Future<bool> Function(AgentFileItem file)? cb,
    String failureMessage,
    String actionLabel,
  ) async {
    if (cb == null || _acting) return;
    setState(() => _acting = true);
    try {
      final ok = await cb(f);
      if (!mounted) return;
      if (!ok) _showMessage(failureMessage);
    } on Object catch (e) {
      // 动作失败不阻断卡片：文件仍可下载。
      if (!mounted) return;
      SpbLog.debug('$actionLabel agent 文件失败', {
        'file': f.fileName,
        'error': '$e',
      });
      _showMessage('$actionLabel失败：$e');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
              // 预览按钮放在下载左侧：它是最常用的动作（先看内容再决定要不要
              // 下载），且未注入能力时不渲染。
              if (widget.onPreview?.hasAny ?? false)
                IconButton(
                  key: const ValueKey('agent-file-preview'),
                  icon: const Icon(Icons.visibility_outlined),
                  tooltip: _canPreview ? '预览' : '文件已删除',
                  onPressed: _canPreview ? _handlePreview : null,
                ),
              if (!f.isDeleted) _downloadButton(canDownload),
              // 菜单在**未注入任何动作**时不渲染——这正是「未注入时行为与现在
              // 完全一致」的保证（只读时间线、移动端都是这种情形）。
              if (_hasFileMenu) _actionMenu(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leading(ColorScheme scheme) {
    if (_loadingThumb) {
      return const SizedBox(
        width: SpbSpacing.xxxl,
        height: SpbSpacing.xxxl,
        child: CircularProgressIndicator(strokeWidth: 2),
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
      'deleted' => (Icons.delete_outline, scheme.errorContainer, '已删除'),
      'modified' => (Icons.edit_outlined, scheme.tertiaryContainer, '已更新'),
      _ => (Icons.add_circle_outline, scheme.secondaryContainer, '已生成'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: SpbRadius.cardAll),
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

  /// 打开 / 定位的行尾菜单。
  ///
  /// 用菜单而非并排两个图标：卡片已有下载按钮，再加两个会把信息行挤没
  /// （与 `GroupDeliverablesPanel` 同一取舍）。
  ///
  /// 已删除/无 fileId 时**菜单项禁用而非隐藏**：让用户看到「这个动作存在但
  /// 现在不可用」，比动作凭空消失更容易理解。
  Widget _actionMenu() => PopupMenuButton<String>(
    key: const ValueKey('agent-file-menu'),
    enabled: !_acting,
    icon: _acting
        ? const SizedBox(
            width: SpbSpacing.lg,
            height: SpbSpacing.lg,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.more_vert),
    tooltip: '更多操作',
    onSelected: (v) {
      switch (v) {
        case 'open':
          _handleOpen();
        case 'reveal':
          _handleReveal();
      }
    },
    itemBuilder: (context) => [
      if (widget.onOpen != null)
        PopupMenuItem<String>(
          value: 'open',
          enabled: _canActOnFile,
          child: const Text('用默认程序打开'),
        ),
      if (widget.onReveal != null)
        PopupMenuItem<String>(
          value: 'reveal',
          enabled: _canActOnFile,
          child: const Text('在文件管理器中定位'),
        ),
    ],
  );

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
              _narrationExpanded ? Icons.expand_less : Icons.expand_more,
            ),
            tooltip: _narrationExpanded ? '收起' : '展开',
            onPressed: f.isDeleted
                ? null
                : () =>
                      setState(() => _narrationExpanded = !_narrationExpanded),
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
