import 'dart:async' show scheduleMicrotask, unawaited;
import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';
import 'package:spb_ui/spb_ui.dart';

import 'map_spec_card.dart';
import 'spec_ui_card.dart';

/// 预览图的解码上限基准：**逻辑宽度上限 1024dp**（与全局基准
/// [kImageDecodeCeilingLogicalWidth] 同一个值，此处保留专属名字是因为调用点
/// 的语义是「预览大图」，与缩略图/头像/Markdown 图片各自不同）。
///
/// 最终解码宽 = `1024 × devicePixelRatio`（`imageDecodeCeilingFor`）。
/// 取 1024 而不是实际视口宽：预览页在窄屏手机上不足 1024，但解码
/// 宽只影响内存不影响显示（`BoxFit.contain` 自己缩）；而桌面端全屏预览
/// 可能接近这个量级。1024×2（常见 DPR）≈ 2048 物理像素，是「高清阅读
/// 与内存占用」的折衷点（docs/memory-audit.md G4b 的 2048px 上限）。
/// 放大看细节时超过此宽的部分会被插值放大（见 `_imageBody` 内注释）。
const double kImagePreviewDecodeCeilingLogicalWidth =
    kImageDecodeCeilingLogicalWidth;

/// 内联预览的单文件上限；更大的文件交给外部预览/系统程序，避免整份载入内存。
const int kMaxInlinePreviewBytes = 32 * 1024 * 1024;

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
    this.loadThumbnail,
    this.openExternal,
    this.openMapMarker,
  });

  /// 取原始字节（text 解码 / image 渲染共用）。
  final LoadAgentFileBytes? loadBytes;

  /// 取**小图**（256px 缩略图），只给图片分支做「先出形、后出清晰」的占位。
  ///
  /// ## 为什么是可选的
  ///
  /// 缩略图是**增强**：取不到（非图片、服务端未开缩略图、网络抖动）时页面
  /// 退回「转圈直到原图到位」的旧行为，不报错、不影响 [loadBytes] 的结果。
  /// 故它不计入 [hasAny]——只配了它不能让预览入口出现（那样点开必然空白）。
  ///
  /// ## 为什么不复用 `loadBytes`
  ///
  /// 原图可能几十 MB，用户点开的头一两秒**什么都看不到**；而 UFS 的
  /// `thumbnails/{size}` 是服务端同步补生成的小图（`internal/service/thumbnail.go`），
  /// 通常几百毫秒内就回来。两者是两次独立请求，不能合并。
  final LoadAgentFileBytes? loadThumbnail;

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
  /// 注意 [openMapMarker] **不计入**：它只在已经打开的预览页里用得上，
  /// 不能单独让「预览」按钮出现（否则只配了它时点预览会得到空对话框）。
  bool get hasAny => loadBytes != null || openExternal != null;
}

/// 打开文件预览**页面**（按类型渲染文本 / 图片 / 外部跳转）。
///
/// ## 入口
///
/// 由 [AgentFileCard] 的预览按钮调用；未注入 [AgentFilePreviewCallbacks] 时
/// 按钮不渲染，故**只读时间线**用法完全不受影响。
///
/// ## 为什么是独立页面而不是对话框（2026-11）
///
/// 对话框也是一层 `ModalRoute`，返回键同样能 pop 它，但有三处实际代价：
///
/// 1. **返回键心智模型**：用户对「关掉这块内容」的默认动作是系统返回 / 左上角
///    返回。对话框没有返回箭头，只能点 ✕ 或遮罩——用户无法从界面确认「返回一次
///    只关预览、对话还在」，实际用起来就会退到列表甚至退出对话去找退路。
/// 2. **尺寸上限**：对话框曾固定 `maxWidth: 900 / maxHeight: 720`，长文本、
///    大 spec、DataTable 全在小窗里内滚。
/// 3. **对照与沉浸**：modal 遮罩把聊天压暗，既读不痛快也没法顺手看一眼上下文。
///
/// 页面在 **root Navigator** 上压一层 `MaterialPageRoute`：系统返回键、AppBar
/// 返回箭头、右上角关闭三者都走**同一个** `_AgentFilePreviewPageState._dismiss`，
/// 且**只弹这一层**——对话路由原样留在下面，不会因为关闭预览把对话一起退掉。
///
/// ## 为什么「只弹一层」不能只靠 `Navigator.pop`（2026-11 真机回归）
///
/// 预览在 root Navigator，宿主（对话页 / 轮次详情弹层）在**分支 Navigator**
/// （移动端 `StatefulShellRoute.indexedStack`）。系统返回在 go_router 里不是
/// 直接找 root，而是先试「当前分支 navigator」
/// （`GoRouterDelegate._findCurrentNavigators`），只靠「shell 之上压了 pageless
/// route 就 break」这条**实现细节**兜住。判据一旦不成立（go_router 升级、路由
/// 结构变化、宿主自己也是嵌套 navigator），一次返回会先弹掉宿主再弹预览——用户
/// 看到的就是「预览完按返回，退回了对话列表，对话也没了」。
///
/// 故本文件把这条判据从「哪个 navigator 先被选中」换成「谁在栈顶」：
/// 1. 三个出口都经 `_AgentFilePreviewPageState._dismiss`，它先验
///    `ModalRoute.isCurrent`（不在栈顶就什么都不做，退场动画期间的重复点不会
///    误弹下层）；
/// 2. 宿主用 [AgentFilePreviewHostGuard] 声明「预览开着时我拒绝被弹掉」，被拒绝
///    的那次返回转给**预览自己**关自己（见 [_previewDismissers] 的说明）。
///
/// ## 类型判定在打开时就定了
///
/// [resolvePreviewKind] 是纯函数，不依赖网络。故页面能**立刻**决定布局
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
  List<AgentFileItem> siblings = const [],
}) {
  if (onPreview == null || !onPreview.hasAny) return Future<void>.value();
  // 压在 root Navigator 上：不塞进任何分支的导航栈（移动端的
  // `StatefulShellRoute` tab 栈），跨端行为一致（桌面没有返回键，但 AppBar 的
  // 返回 / 关闭同源）。
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _AgentFilePreviewPage(
        file: file,
        onPreview: onPreview,
        siblings: siblings,
      ),
      settings: const RouteSettings(name: 'agent-file-preview'),
    ),
  );
}

/// 当前打开的预览页的「关掉自己」回调（LIFO：最后一项 = 用户此刻看到的那层）。
///
/// ## 为什么需要登记表（2026-11 真机回归：预览返回退到列表）
///
/// 见 [showAgentFilePreview] 的「为什么『只弹一层』不能只靠 `Navigator.pop`」。
/// 一句话：系统返回在 go_router 里可能先落到**宿主**（分支 navigator 的栈顶），
/// 宿主拒绝被弹掉之后，得有人替它把预览关掉——那就是这里登记的回调。
///
/// 用栈而不是单个回调：预览页理论上可以叠层（宿主在预览页里再开一层），栈语义
/// 天然正确，也不需要额外的计数变量。
final List<VoidCallback> _previewDismissers = <VoidCallback>[];

/// 打开的预览层数。宿主守卫监听它重建 `PopScope.canPop`。
final ValueNotifier<int> _previewDepth = ValueNotifier<int>(0);

void _registerPreviewDismisser(VoidCallback dismiss) {
  _previewDismissers.add(dismiss);
  _syncPreviewDepth();
}

void _unregisterPreviewDismisser(VoidCallback dismiss) {
  if (!_previewDismissers.remove(dismiss)) return;
  _syncPreviewDepth();
}

/// 把层数变化推给宿主守卫（[AgentFilePreviewHostGuard]）。
///
/// ## 为什么推到微任务而不是同步赋值
///
/// 两处调用点都在框架不允许标脏的时刻：注册在预览页的 `initState`（push 的首帧，
/// 正在 build），注销在 `dispose`（路由拆卸，树已锁）。同步通知会让宿主的
/// `ValueListenableBuilder` 被要求在 build 期间重建，直接抛断言。
///
/// 微任务足够早：返回请求来自独立的平台消息回合（或用户点击），永远晚于它，
/// 故不存在「预览已开、`canPop` 还是旧值」的窗口。
void _syncPreviewDepth() {
  final depth = _previewDismissers.length;
  if (_previewDepth.value == depth) return;
  scheduleMicrotask(() => _previewDepth.value = depth);
}

/// 关掉栈顶的预览页（由 [AgentFilePreviewHostGuard] 在「返回落到宿主」时调用）。
///
/// 没有预览页时**什么都不做**：守卫只在层数 > 0 时才接管返回，故这条路径
/// 不会把「本来就没有预览」的正常返回吃掉。
void _dismissTopPreview() {
  if (_previewDismissers.isEmpty) return;
  _previewDismissers.last();
}

/// 预览页的**宿主守卫**：预览开着时，宿主拒绝自己被弹掉，并把这次返回转给预览。
///
/// 用法：包住「可能打开预览页」的页面根节点（对话页、轮次详情面板）。
/// 没有预览页时它完全透明（`canPop: true`，与不加本 widget 等价）。
///
/// ## 为什么把防线放在宿主而不是预览页
///
/// `PopScope` 只对它自己所在的 `ModalRoute` 生效。返回请求若被 go_router 派给
/// 分支 navigator，被问到的是**宿主**的 route（预览在 root navigator，压根不在
/// 那条栈上），预览页上的任何拦截都收不到这次请求。故只能在宿主上声明
/// 「现在不能弹我」——然后由预览自己关自己（`_dismissTopPreview`）。
class AgentFilePreviewHostGuard extends StatelessWidget {
  const AgentFilePreviewHostGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _previewDepth,
      builder: (context, depth, child) => PopScope(
        // 只在有预览页时才拦：其余时刻与未包守卫完全一致（不改变既有返回语义）。
        canPop: depth == 0,
        onPopInvokedWithResult: (didPop, _) {
          // didPop 为真 = 没有预览页，这次返回已按原语义弹掉了宿主自身。
          if (didPop) return;
          _dismissTopPreview();
        },
        child: child!,
      ),
      child: child,
    );
  }
}

class _AgentFilePreviewPage extends StatefulWidget {
  const _AgentFilePreviewPage({
    required this.file,
    required this.onPreview,
    required this.siblings,
  });

  final AgentFileItem file;
  final AgentFilePreviewCallbacks onPreview;
  final List<AgentFileItem> siblings;

  @override
  State<_AgentFilePreviewPage> createState() => _AgentFilePreviewPageState();
}

class _AgentFilePreviewPageState extends State<_AgentFilePreviewPage> {
  /// text / image 的取数结果；external 恒为 null（不需要取数）。
  Future<_PreviewPayload>? _loading;

  /// 图片的**占位小图**（256px 缩略图，已解码前的原始字节）。null = 还没有。
  ///
  /// 与 [_loading] 并行发起：小图先回来就先把形状铺上，原图到位后由
  /// [_imageBody] 整块替换（两段式，见 [_imagePlaceholder]）。
  Uint8List? _thumbBytes;

  /// external 跳转进行中（防重复点）。
  bool _openingExternal = false;

  late AgentFileItem f = widget.file;

  void _selectFile(AgentFileItem file) {
    if (f.id == file.id || _openingExternal) return;
    setState(() {
      f = file;
      _thumbBytes = null;
      _loading = null;
      _startLoading();
    });
  }

  /// 类型判定（纯函数，同步可得）。
  FilePreviewKind get _kind {
    final kind = resolvePreviewKind(
      mimeType: f.mimeType,
      fileName: f.fileName,
      relativePath: f.relativePath,
    );
    if (kind != FilePreviewKind.external &&
        (f.sizeBytes ?? 0) > kMaxInlinePreviewBytes) {
      return FilePreviewKind.external;
    }
    return kind;
  }

  @override
  void initState() {
    super.initState();
    _registerPreviewDismisser(_dismisser);
    _startLoading();
  }

  @override
  void dispose() {
    _unregisterPreviewDismisser(_dismisser);
    super.dispose();
  }

  /// 登记给宿主守卫的回调。
  ///
  /// 存成字段而不是每次 `_dismiss` 擦一个新闭包：注册与注销必须是**同一个**
  /// 对象，否则从栈里删不掉（层数永远回不到 0，宿主的返回会永久失效）。
  late final VoidCallback _dismisser = _dismiss;

  /// 关掉**本页这一层**（三个出口共用）。
  ///
  /// 判据是「自己还在栈顶」（`ModalRoute.isCurrent`）：
  /// - 退场动画期间的重复点、以及“已经被弹掉但还没 dispose”的窗口期，
  ///   都不会把下面的宿主一起退掉；
  /// - 预览之上又压了别的东西时，不会误弹那一层。
  void _dismiss() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    Navigator.of(context).pop();
  }

  /// 发起取数。external 分支不取数（直接给跳转入口）。
  void _startLoading() {
    final file = f;
    final kind = _kind;
    if (kind == FilePreviewKind.external) return;

    // 图片：小图与原图**并行**发起（串行只会把总耗时变成两者之和）。
    // 取不到就退化为「转圈到原图到位」，见 [_imagePlaceholder]。
    final thumbLoader = widget.onPreview.loadThumbnail;
    if (kind == FilePreviewKind.image && thumbLoader != null) {
      // 不 await：小图只是占位，绝不能让它的成败拖住或影响原图这条主链。
      thumbLoader(file).then(
        (bytes) {
          if (!mounted ||
              !identical(f, file) ||
              bytes == null ||
              bytes.isEmpty) {
            return;
          }
          setState(() => _thumbBytes = Uint8List.fromList(bytes));
        },
        onError: (Object e) {
          SpbLog.debug('预览占位小图取不到', {'file': file.fileName, 'error': '$e'});
        },
      );
    }

    final loader = widget.onPreview.loadBytes;
    if (loader == null) {
      _loading = Future<_PreviewPayload>.error(
        const _PreviewUnavailable('未注入预览取数能力'),
      );
      return;
    }

    _loading = Future<_PreviewPayload>(() async {
      final bytes = await loader(file);
      if (bytes == null ||
          (bytes.isEmpty &&
              !(kind == FilePreviewKind.text && file.sizeBytes == 0))) {
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
                mimeType: file.mimeType,
                fileName: file.relativePath.isEmpty
                    ? file.fileName
                    : file.relativePath,
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

    return Scaffold(
      key: const ValueKey('agent-file-preview-page'),
      // 三个出口同源：系统返回键 / 这个返回箭头 / 右上角 ✕ 都只弹这一层——
      // 对话路由原样留在下面。两个按钮都走 [_dismiss]（而不是默认的
      // `maybePop`）：它先验 `ModalRoute.isCurrent`，重复点、退场期间、以及
      // 「上面又压了别的路由」这三种情况一律丢弃，不会把下层宿主退掉。
      appBar: AppBar(
        leading: BackButton(
          key: const ValueKey('agent-file-preview-back'),
          onPressed: _dismiss,
        ),
        titleSpacing: 0,
        title: _header(theme, scheme, kind),
        actions: [
          IconButton(
            key: const ValueKey('agent-file-preview-close'),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: _dismiss,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final preview = Center(
            child: ConstrainedBox(
              // 宽屏（桌面最大化窗口）不把内容拉成一行 2000px：保持可读行宽；
              // 窄屏时该上限自然不生效。
              constraints: const BoxConstraints(maxWidth: 980),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: KeyedSubtree(
                        key: ValueKey(f.id),
                        child: _body(kind),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          if (!SpbTheme.isDesktopTheme(theme) ||
              constraints.maxWidth < SpbBreakpoints.medium ||
              widget.siblings.length < 2) {
            return preview;
          }
          return Row(
            children: [
              SizedBox(
                width: SpbBreakpoints.medium / 4,
                child: SpbVerticalListFocus(
                  child: ListView.builder(
                    key: const ValueKey('preview-file-switcher'),
                    itemCount: widget.siblings.length,
                    itemBuilder: (context, index) {
                      final file = widget.siblings[index];
                      return SpbVerticalListFocus.item(
                        context,
                        index: index,
                        builder: (focusNode) => ListTile(
                          focusNode: focusNode,
                          selected: file.id == f.id,
                          title: Text(
                            file.relativePath.isEmpty
                                ? file.fileName
                                : file.relativePath,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: _openingExternal
                              ? null
                              : () => _selectFile(file),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: preview),
            ],
          );
        },
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
                  style: SpbType.cardTitle(theme.textTheme),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: SpbSpacing.xxs),
                Text(
                  kindLabel,
                  style: SpbType.listMeta(theme.textTheme)
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
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
          // 图片有占位小图就先把形状铺上（用户点开的头一两秒不再是空白转圈），
          // 原图到位后由下面的 `_ImagePayload` 分支整块替换。
          final placeholder = _imagePlaceholder();
          if (placeholder != null) return placeholder;
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

  /// spec：复用 `SpecUiCard`（只读展示——预览页无动作通道，不传 `onAction`）。
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
                    // 等宽 + CJK 兜底由 SpbType.mono 一并给出（§6.81）。
                    style: SpbType.mono(theme.textTheme),
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
  /// 预览页**没有** `onLinkTap` 注入通道（与 `_specBody` 不传 `onAction`
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

  /// 图片占位：先渲染 256px 缩略图，底部一条进度条表示「原图还在路上」。
  ///
  /// ## 为什么值得多一条请求
  ///
  /// 原图动辄几十 MB（手机截图、录屏帧），点击后的头一两秒是纯空白转圈；
  /// 缩略图由服务端同步补生成、通常几百毫秒内回来，用户立刻能看到「打开
  /// 的是哪张图」，也让慢网络下的等待有参照物。
  ///
  /// ## 为什么失败一律静默
  ///
  /// 小图是**增强**：没注入能力、非图片、服务端未开缩略图、请求失败——都返回
  /// null 让调用方退回转圈。把占位失败做成错误提示只会让「本该能看原图」的
  /// 文件变成一条报错。
  ///
  /// 缩略图**不**设 `cacheWidth`：它本身就是 256px（服务端白名单 64/128/256/512），
  /// 再限宽没有收益，还会在窄屏上糊掉。
  Widget? _imagePlaceholder() {
    final bytes = _thumbBytes;
    if (bytes == null) return null;
    return Padding(
      padding: const EdgeInsets.all(SpbSpacing.lg),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Image.memory(
                bytes,
                key: const ValueKey('agent-file-preview-image-thumb'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                // 小图解码失败就当作没有占位（别让一条坏缩略图顶掉原图）。
                errorBuilder: (c, o, s) => const SizedBox.shrink(),
              ),
            ),
          ),
          const SizedBox(height: SpbSpacing.sm),
          const LinearProgressIndicator(
            key: ValueKey('agent-file-preview-image-loading'),
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
          // 解码上限（docs/memory-audit.md G4b）：不传时按原图分辨率解码，
          // 一张 4000×3000 的截图 ≈ 48MB 位图。上限取「屏幕逻辑宽 × 设备
          // 像素比」——预览图不会宽过窗口。
          //
          // ## 折衷（诚实记录）
          //
          // InteractiveViewer 放大（maxScale 8）时，超过解码宽度的部分
          // 会被插值放大——放大到 8× 后清晰度略低于原图。取屏幕宽而非
          // 原图意味着「全屏阅读清晰、极限放大略糊」；比「多张 48MB 位图
          // 驻留 imageCache」可控（全局上限见 spb_platform
          // configureImageCache）。若将来需要高倍放大仍清晰，得改成
          // 分级重解码（按当前 scale 重建 cacheWidth），那是独立的复杂度。
          cacheWidth: imageDecodeCeilingFor(
            displayLogicalWidth: kImagePreviewDecodeCeilingLogicalWidth,
            view: View.of(context),
          ),
          gaplessPlayback: true,
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
