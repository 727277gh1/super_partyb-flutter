import 'dart:async' show unawaited;
import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'map_spec_card.dart';
import 'spec_ui_card.dart';

/// 取文件**原始字节**（预览用）。null 表示取不到（无 id / 已删除 / 下载失败）。
///
/// 与 [AgentFileCard.onLoadThumbnail] 的分工：
/// - 缩略图用于**列表内联**（一张卡一个 256px 小图），要走廉价的缩略图端点；
/// - 预览是**用户主动点开**的单文件，走原图字节（缩略图放大到全屏会糊）。
///
/// 故这里不复用缩略图回调——两者取数策略不同，混用会让「预览」显示 256px 的图。
typedef LoadAgentFileBytes = Future<List<int>?> Function(AgentFileItem file);

/// 在系统浏览器中打开该文件的 **UFS 预览页**（external 类的唯一出路）。
///
/// 入参是 [AgentFileItem] 而非 URL：**URL 拼接留在 app 装配层**。页面不掌握
/// UFS 基地址与预览页路由形状（`/preview.html?file_id=…`），让它拼等于把
/// 「服务部署在哪」这个装配层知识塞进组件库——与 [OpenAgentFile] 收 file
/// 而非路径同一理由。
///
/// 返回 false = 未能发起（浏览器打不开、无 id），调用方据此给反馈。
typedef OpenAgentFileExternal = Future<bool> Function(AgentFileItem file);

/// 在高德地图打开一个地点（map spec 的地点行点击）。
///
/// 与 [OpenAgentFileExternal] 分开：后者拼的是**本服务**的 UFS 预览页 URL，
/// 前者拼的是**第三方** `uri.amap.com` 链接（见 `amapMarkerUrl`）。两者目标
/// 域名、失败语义都不同，合一个会让装配层必须再判一次类型。
typedef OpenMapMarker = Future<bool> Function(MapMarker marker);

/// 文件预览所需的两个 IO 能力。**打包成一个对象**，避免 `AgentFileCard` /
/// `AgentFileBatchCard` / `ConversationPage` 各加两个可选参数（4 处 × 2 参数
/// 的透传链）。
///
/// ## 为什么两个回调都是可空的
///
/// 两者覆盖的 kind 不同：
/// - [loadBytes] 服务 `text` / `image`；
/// - [openExternal] 服务 `external`。
///
/// 移动端可以只接前者（浏览器跳转在移动端要走 `url_launcher`，见
/// `apps/spb_mobile/lib/router.dart` 的说明）。缺失的能力对应的分支会退化为
/// 「无法内联预览」提示，而不是崩溃或静默无响应。
///
/// ## 未注入时行为与现在完全一致
///
/// `onPreview` 为 null 时卡片**不渲染**预览按钮（与 #6 的打开/定位菜单项
/// 同一约定：不渲染一个点了没反应的入口）。
class AgentFilePreviewCallbacks {
  const AgentFilePreviewCallbacks({
    this.loadBytes,
    this.openExternal,
    this.openMapMarker,
  });

  /// 取原始字节（text 解码 / image 渲染共用）。
  final LoadAgentFileBytes? loadBytes;

  /// 打开 UFS 预览页（external 类）。
  final OpenAgentFileExternal? openExternal;

  /// 在高德地图打开一个地点（map spec 的地点行）。
  ///
  /// ## 为什么单独一个回调而不是复用 [openExternal]
  ///
  /// [openExternal] 的签名收的是 `AgentFileItem`（它要拼 UFS 预览页 URL），
  /// 而这里要打开的是一个 `MapMarker` 的第三方链接——调用方拿不到、也不该
  /// 拿到「当前预览的是哪个文件」这个信息。
  ///
  /// ## 未注入时的降级
  ///
  /// 地点行**不可点**（不渲染成一个点了没反应的入口）。地图与地点列表
  /// 照常显示——「看到」不依赖「能跳出去」。
  final OpenMapMarker? openMapMarker;

  /// 是否至少有一个可用能力（决定预览入口是否渲染）。
  ///
  /// 注意 [openMapMarker] **不计入**：它只在已经打开的预览对话框里用得上，
  /// 不能单独让「预览」按钮出现（否则只配了它时点预览会得到空对话框）。
  bool get hasAny => loadBytes != null || openExternal != null;
}

/// 打开文件预览对话框（按类型渲染文本 / 图片 / 外部跳转）。
///
/// ## 入口
///
/// 由 [AgentFileCard] 的预览按钮调用；未注入 [AgentFilePreviewCallbacks] 时
/// 按钮不渲染，故**只读时间线**用法完全不受影响。
///
/// ## 类型判定在打开时就定了
///
/// [resolvePreviewKind] 是纯函数，不依赖网络。故对话框能**立刻**决定布局
/// （图片占位尺寸、文本等宽字体、external 直接给跳转按钮），而不是先拉一次
/// 字节再猜。取数只在 text / image 两条分支上发生。
///
/// ## 不认识的类型不报错
///
/// 退化为 external（跳 UFS 预览页）——那是 webapp 的取舍，也是本 issue 的
/// 验收项。报错等于「这个文件你永远看不到内容」。
Future<void> showAgentFilePreview({
  required BuildContext context,
  required AgentFileItem file,
  AgentFilePreviewCallbacks? onPreview,
}) {
  if (onPreview == null || !onPreview.hasAny) return Future<void>.value();
  return showDialog<void>(
    context: context,
    builder: (_) => _AgentFilePreviewDialog(file: file, onPreview: onPreview),
  );
}

class _AgentFilePreviewDialog extends StatefulWidget {
  const _AgentFilePreviewDialog({required this.file, required this.onPreview});

  final AgentFileItem file;
  final AgentFilePreviewCallbacks onPreview;

  @override
  State<_AgentFilePreviewDialog> createState() =>
      _AgentFilePreviewDialogState();
}

class _AgentFilePreviewDialogState extends State<_AgentFilePreviewDialog> {
  /// text / image 的取数结果；external 恒为 null（不需要取数）。
  Future<_PreviewPayload>? _loading;

  /// external 跳转进行中（防重复点）。
  bool _openingExternal = false;

  AgentFileItem get f => widget.file;

  /// 类型判定（纯函数，同步可得）。
  FilePreviewKind get _kind => resolvePreviewKind(
    mimeType: f.mimeType,
    fileName: f.fileName,
    relativePath: f.relativePath,
  );

  @override
  void initState() {
    super.initState();
    _startLoading();
  }

  /// 发起取数。external 分支不取数（直接给跳转入口）。
  void _startLoading() {
    final kind = _kind;
    if (kind == FilePreviewKind.external) return;

    final loader = widget.onPreview.loadBytes;
    if (loader == null) {
      _loading = Future<_PreviewPayload>.error(
        const _PreviewUnavailable('未注入预览取数能力'),
      );
      return;
    }

    _loading = Future<_PreviewPayload>(() async {
      final bytes = await loader(f);
      if (bytes == null || bytes.isEmpty) {
        throw const _PreviewUnavailable('未能取到文件内容');
      }
      switch (kind) {
        case FilePreviewKind.image:
          return _ImagePayload(Uint8List.fromList(bytes));
        case FilePreviewKind.text:
          // `allowMalformed: true`：文本白名单也可能被服务端报错 mime 而
          // 实际是二进制（如 .log 里混了控制字节）。不加这个参数，
          // `utf8.decode` 会抛 FormatException，用户看到的是「加载失败」
          // 而不是「文件里有乱码」——后者信息量大得多。
          //
          // 解码后交给内容层判定（issue #14）：命中 spec schema 则渲染结构化
          // 卡片，否则照旧展示原文。**解析失败必落原文**——`resolveTextPreview`
          // 只在 `elements[root]` 确实存在时才返回 spec（空对话框比原文更差）。
          return switch (resolveTextPreview(
            utf8.decode(bytes, allowMalformed: true),
          )) {
            MapTextPreview(:final schema) => _MapPayload(schema),
            SpecTextPreview(:final doc) => _SpecPayload(doc),
            PlainTextPreview(:final text) => _TextPayload(
              text,
              // 渲染器选择在**取数时**定一次（而非每帧判定）：文件名/mime 不变，
              // 重复判定只是浪费。
              isMarkdown: isMarkdownTextPreview(
                mimeType: f.mimeType,
                fileName: f.relativePath.isEmpty ? f.fileName : f.relativePath,
              ),
            ),
          };
        case FilePreviewKind.external:
          throw const _PreviewUnavailable('此类型不可内联预览');
      }
    });
  }

  Future<void> _openExternal() async {
    if (_openingExternal) return;
    final cb = widget.onPreview.openExternal;
    if (cb == null) return;
    setState(() => _openingExternal = true);
    try {
      final ok = await cb(f);
      if (!mounted) return;
      if (!ok) _showMessage('无法打开预览页');
    } on Object catch (e) {
      if (!mounted) return;
      SpbLog.debug('打开 UFS 预览页失败', {'file': f.fileName, 'error': '$e'});
      _showMessage('打开预览页失败：$e');
    } finally {
      if (mounted) setState(() => _openingExternal = false);
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final kind = _kind;

    return Dialog(
      key: const ValueKey('agent-file-preview-dialog'),
      insetPadding: const EdgeInsets.all(SpbSpacing.xxl),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        // 上限而非固定尺寸：小图/短文本时对话框贴着内容，长文本时到顶后内滚。
        constraints: const BoxConstraints(
          maxWidth: 900,
          maxHeight: 720,
          minWidth: 320,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(theme, scheme, kind),
            const Divider(height: 1),
            Flexible(child: _body(kind)),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, ColorScheme scheme, FilePreviewKind kind) {
    final (String kindLabel, IconData kindIcon) = switch (kind) {
      FilePreviewKind.text => ('文本', Icons.description_outlined),
      FilePreviewKind.image => ('图片', Icons.image_outlined),
      FilePreviewKind.external => ('外部预览', Icons.open_in_new_outlined),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.lg,
        SpbSpacing.md,
        SpbSpacing.sm,
        SpbSpacing.md,
      ),
      child: Row(
        children: [
          Icon(kindIcon, size: SpbSpacing.xl, color: scheme.primary),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  f.displayName.isEmpty ? f.fileName : f.displayName,
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: SpbSpacing.xxs),
                Text(
                  kindLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('agent-file-preview-close'),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _body(FilePreviewKind kind) {
    if (kind == FilePreviewKind.external) return _externalBody();
    return FutureBuilder<_PreviewPayload>(
      future: _loading,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(SpbSpacing.xxxl),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return _errorBody(
            snap.error is _PreviewUnavailable
                ? (snap.error! as _PreviewUnavailable).message
                : '加载失败：${snap.error}',
          );
        }
        final payload = snap.data;
        return switch (payload) {
          _TextPayload(:final text, :final isMarkdown) => _textBody(
            text,
            isMarkdown: isMarkdown,
          ),
          _SpecPayload(:final doc) => _specBody(doc),
          _MapPayload(:final schema) => _mapBody(schema),
          _ImagePayload(:final bytes) => _imageBody(bytes),
          null => _errorBody('加载失败'),
        };
      },
    );
  }

  /// spec：复用 `SpecUiCard`（只读展示——预览对话框无动作通道，不传 `onAction`）。
  ///
  /// 包一层滚动容器：spec 文档可能比对话框高（服务端产出的 card 列表）。
  /// `SpecUiCard` 在 root 悬空时渲染 `SizedBox.shrink()`，但 `resolveTextPreview`
  /// 已保证走到这里时 `root` 非空（否则会落到 [_textBody]）。
  Widget _specBody(SpecUiDocument doc) => SingleChildScrollView(
    key: const ValueKey('agent-file-preview-spec'),
    padding: const EdgeInsets.all(SpbSpacing.lg),
    child: SpecUiCard(doc: doc),
  );

  /// map spec：轨迹图 + 路线/地点列表（issue #12 的 `map` 项）。
  ///
  /// 与 [_specBody] 同样包滚动容器：地点列表可能比对话框高。
  ///
  /// 地点行只在注入了 [AgentFilePreviewCallbacks.openMapMarker] 时可点——
  /// 未注入时 `MapSpecCard` 渲染成纯展示（不画一个点了没反应的入口）。
  Widget _mapBody(MapSchema schema) => SingleChildScrollView(
    key: const ValueKey('agent-file-preview-map'),
    padding: const EdgeInsets.all(SpbSpacing.lg),
    child: MapSpecCard(
      schema: schema,
      onOpenMarker: widget.onPreview.openMapMarker == null
          ? null
          : (marker) => unawaited(_openMapMarker(marker)),
    ),
  );

  /// 在高德地图打开地点。失败只提示（不弹异常）。
  Future<void> _openMapMarker(MapMarker marker) async {
    final cb = widget.onPreview.openMapMarker;
    if (cb == null) return;
    try {
      final ok = await cb(marker);
      if (!mounted || ok) return;
      _showMessage('无法打开地图');
    } on Object catch (e) {
      if (!mounted) return;
      SpbLog.debug('打开高德地图失败', {'marker': marker.displayTitle, 'error': '$e'});
      _showMessage('打开地图失败：$e');
    }
  }

  /// 文本：Markdown 用 [GptMarkdown]，其余等宽、可选中、可滚动。
  ///
  /// 截断提示**常驻**在内容上方（两种渲染方式都有）。
  Widget _textBody(TextPreview preview, {required bool isMarkdown}) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (preview.truncated) _truncatedBanner(preview),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(SpbSpacing.lg),
            child: isMarkdown
                ? _markdownBody(preview, theme)
                : SelectableText(
                    key: const ValueKey('agent-file-preview-text'),
                    preview.content,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      // 与另两处 monospace 调用点共用同一条链（含 CJK 兜底）。
                      fontFamilyFallback: SpbFonts.monoFallback,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// Markdown 正文。
  ///
  /// ## 为什么不用 `isStreaming` / `animation`
  ///
  /// 预览是**一次性取完**的静态内容，没有 token 流。开着 reveal 动画会让用户
  /// 打开对话框后先看到半截、再逐字补全——那是「正在生成」的错误暗示。
  /// `GptMarkdownAnimation.none` + `isStreaming: false` 直接渲染全文。
  ///
  /// ## 为什么包 `SelectionArea`
  ///
  /// `GptMarkdown` 内部用 `RichText`，默认不可选中；纯文本分支的
  /// `SelectableText` 可选中。不包会让「Markdown 能选、txt 不能选」——
  /// 同一对话框两种行为。
  ///
  /// ## 链接不可点
  ///
  /// 预览对话框**没有** `onLinkTap` 注入通道（与 `_specBody` 不传 `onAction`
  /// 同一约定：预览是只读展示，不引入动作）。故不传 `onLinkTap`——
  /// `GptMarkdown` 在它为 null 时只渲染样式、不响应点击，与
  /// `AssistantMessageBubble` 的可点行为刻意区分。
  Widget _markdownBody(TextPreview preview, ThemeData theme) {
    return SelectionArea(
      child: GptMarkdown(
        key: const ValueKey('agent-file-preview-markdown'),
        preview.content,
        animation: GptMarkdownAnimation.none,
        style: theme.textTheme.bodyMedium,
      ),
    );
  }

  /// 截断提示条：不静默截断是本 issue 的验收项。它必须**可见**——
  /// 只在日志里记一笔等于没提示（用户看不到日志）。
  ///
  /// ## 为什么 Markdown 分支更需要它
  ///
  /// 渲染成 Markdown 后，页面看起来「很完整」（有标题、有排版），比等宽纯文本
  /// 更容易让人以为「这就是全部」。故提示不能因为换了渲染器就省掉。
  Widget _truncatedBanner(TextPreview preview) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      key: const ValueKey('agent-file-preview-truncated'),
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.lg,
        vertical: SpbSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.content_cut_outlined,
            size: SpbSpacing.lg,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Text(
              // 说清「截了多少」而不只是「截了」：只报已截断，
              // 用户无法判断是漏了一行还是漏了 10 万行。
              '内容过大，仅显示前 ${preview.content.length} 字符'
              '（共 ${preview.originalLength} 字符，'
              '省略 ${preview.omittedLength} 字符）。'
              '完整内容请下载查看。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageBody(Uint8List bytes) => Padding(
    padding: const EdgeInsets.all(SpbSpacing.lg),
    child: InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: Image.memory(
          bytes,
          key: const ValueKey('agent-file-preview-image'),
          fit: BoxFit.contain,
          // 字节损坏/非图片时退化为提示，不让整个对话框抛异常。
          errorBuilder: (c, o, s) => _errorBody('图片无法解码（可能不是有效的图片数据）'),
        ),
      ),
    ),
  );

  /// external：说清「为什么看不到内容」并给出唯一的出路（跳 UFS 预览页）。
  Widget _externalBody() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canOpen = widget.onPreview.openExternal != null;

    return Padding(
      key: const ValueKey('agent-file-preview-external'),
      padding: const EdgeInsets.all(SpbSpacing.xxxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: SpbSpacing.xxxl * 2,
            color: scheme.outline,
          ),
          const SizedBox(height: SpbSpacing.lg),
          Text(
            f.mimeType?.isNotEmpty == true
                ? '此类型（${f.mimeType}）无法在应用内预览'
                : '此类型无法在应用内预览',
            style: theme.textTheme.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SpbSpacing.xs),
          Text(
            canOpen ? '可在 UFS 预览页中查看。' : '当前环境未提供外部预览入口，可改用「下载」后查看。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (canOpen) ...[
            const SizedBox(height: SpbSpacing.xl),
            FilledButton.icon(
              key: const ValueKey('agent-file-preview-open-external'),
              onPressed: _openingExternal ? null : _openExternal,
              icon: _openingExternal
                  ? const SizedBox(
                      width: SpbSpacing.lg,
                      height: SpbSpacing.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_new_outlined),
              label: const Text('在 UFS 预览页打开'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _errorBody(String message) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const ValueKey('agent-file-preview-error'),
      padding: const EdgeInsets.all(SpbSpacing.xxxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: SpbSpacing.xxxl, color: scheme.error),
          const SizedBox(height: SpbSpacing.md),
          Text(
            message,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SpbSpacing.xs),
          Text(
            '可改用「下载」后查看。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 取数结果（仅 text / image 需要；external 不取数）。
sealed class _PreviewPayload {
  const _PreviewPayload();
}

class _TextPayload extends _PreviewPayload {
  const _TextPayload(this.text, {required this.isMarkdown});
  final TextPreview text;

  /// 用 Markdown 渲染器还是等宽纯文本（取数时按 mime/扩展名判定一次）。
  final bool isMarkdown;
}

/// spec 结构化内容（`resolveTextPreview` 命中 `{root, elements}` 时）。
class _SpecPayload extends _PreviewPayload {
  const _SpecPayload(this.doc);
  final SpecUiDocument doc;
}

class _MapPayload extends _PreviewPayload {
  const _MapPayload(this.schema);
  final MapSchema schema;
}

class _ImagePayload extends _PreviewPayload {
  const _ImagePayload(this.bytes);
  final Uint8List bytes;
}

/// 「取不到内容」这一类**预期内**的失败（与真异常区分开，文案不同）。
class _PreviewUnavailable implements Exception {
  const _PreviewUnavailable(this.message);
  final String message;
}
