import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import 'providers.dart';

/// 路由路径常量（集中定义，避免 `context.go` 与路由表两处字面量不一致）。
class SpbRoutes {
  const SpbRoutes._();

  static const conversations = '/';
  static const settings = '/settings';
  static const quickCapture = '/quick-capture';

  /// 小程序工作台：工作列表。
  ///
  /// 挂在 shell **之外**（整屏页，无底部标签栏），沿用 [quickCapture] 的先例。
  static const works = '/miniapp/works';

  /// 工作详情。
  ///
  /// `work.id` **就是 group id**（服务端没有独立的 works 表），故路径参数
  /// 与对话共用同一个 id 空间。
  static String work(String workId) => '/miniapp/works/$workId';

  /// 交付物同步页（移动端同步到应用沙箱目录）。
  static const sync = '/settings/sync';

  /// 登录页。
  ///
  /// 路由守卫（`redirect`）与路由表必须用**同一个**字面量，否则守卫会把用户
  /// 重定向到一个不存在的路径，go_router 抛「no routes for location」。
  static const login = '/login';

  static String chat(String groupId) => '/chat/$groupId';

  /// 搜索页（搜消息正文，不是对话标题）。
  ///
  /// 挂在「对话」标签的导航栈下（与 [chat] 同级），故从搜索结果跳到对话后
  /// 按返回键回到搜索结果，再返回回到列表——符合移动端的栈语义。
  static const search = '/search';
}

/// 移动端路由表。
///
/// ## 为什么这里用 `StatefulShellRoute.indexedStack`
///
/// 移动端是**底部标签栏**（对话 / 设置），每个标签有**独立的导航栈**：
/// 在「对话」标签里进入某个对话后切到「设置」再切回来，应回到那个对话而非列表。
/// 这正是 shell route 的用途（见 `docs/flutter-component-research.md` §1.2）。
///
/// 桌面端**不用**它：那边是「列表 + 内容」两栏布局，侧边栏只是布局而非导航栈。
///
/// 用 `indexedStack` 而非 `pageBuilder` 版本：它保留各分支的 widget 状态
/// （滚动位置、输入框内容），符合标签栏的预期行为。
GoRouter createMobileRouter({Listenable? refreshListenable}) {
  return GoRouter(
    initialLocation: SpbRoutes.conversations,
    routes: buildMobileRoutes(),
    redirect: buildAuthRedirect(),
    refreshListenable: refreshListenable,
  );
}

/// 未认证重定向守卫。
///
/// 与桌面端同构（说明见桌面 `router.dart`）：
///
/// - 守卫放在路由层 → 「未认证」只有一个判定点，新增页面不会漏判；
/// - [AuthStatus.unknown] 时**不重定向**（读凭证是异步的，否则已登录用户
///   会看到登录页闪一下），由 `refreshListenable` 在判定完成后重跑；
/// - 未认证时带上 `from` 参数记住原目标，登录后可回跳。
GoRouterRedirect buildAuthRedirect({AuthState Function()? authState}) {
  return (context, state) {
    final auth = authState?.call() ?? _authStateFromContext(context);
    if (auth == null || auth.status == AuthStatus.unknown) return null;

    final goingToLogin = state.matchedLocation == SpbRoutes.login;

    if (auth.isUnauthenticated) {
      if (goingToLogin) return null;
      return '${SpbRoutes.login}?from=${Uri.encodeComponent(state.matchedLocation)}';
    }

    if (goingToLogin) return SpbRoutes.conversations;
    return null;
  };
}

/// 从 `BuildContext` 读认证状态。
///
/// 用 `listen: false` 是必要的——守卫不在 build 阶段，依赖订阅会抛异常。
AuthState? _authStateFromContext(BuildContext context) {
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    return container.read(authStateProvider);
  } catch (_) {
    // 没有 ProviderScope（如单测直接构造 GoRouter）→ 视为未接入认证。
    return null;
  }
}

/// 移动端路由表（不含 `GoRouter` 实例）。
///
/// 独立导出供测试构造自己的 `GoRouter`（测试需指定 `initialLocation`
/// 并在 pumpWidget 前拿到实例以主动导航）。
List<RouteBase> buildMobileRoutes() {
  return [
    // 登录页在 shell **之外**：它是整屏页面，不应带底部标签栏，
    // 也不应占据某个标签的导航栈（登录成功后不该能「返回」到登录页）。
    GoRoute(
      path: SpbRoutes.login,
      builder: (context, state) => const _LoginPage(),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: SpbRoutes.conversations,
              builder: (context, state) => const _ConversationsTab(),
              routes: [
                GoRoute(
                  path: 'chat/:groupId',
                  builder: (context, state) =>
                      _ChatPage(groupId: state.pathParameters['groupId'] ?? ''),
                ),
                GoRoute(
                  path: 'search',
                  builder: (context, state) => const _SearchPage(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: SpbRoutes.settings,
              builder: (context, state) => const _SettingsTab(),
              routes: [
                GoRoute(
                  path: 'sync',
                  builder: (context, state) => const _SyncPage(),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    // 悬浮输入窗在 shell **之外**：它是一个整屏的临时页面，不应带标签栏，
    // 也不应占据某个标签的导航栈。
    GoRoute(
      path: SpbRoutes.quickCapture,
      builder: (context, state) => const _QuickCapturePage(),
    ),
    // 小程序工作台同样在 shell **之外**：工作列表与详情都是整屏页（详情页
    // 底部有消息输入框，再叠一层标签栏会挤掉内容）。沿用 [SpbRoutes.quickCapture]
    // 已确立的先例。
    //
    // 两条路由**不会互相抢匹配**：`/miniapp/works` 是 2 段，`/miniapp/works/:workId`
    // 是 3 段，段数不同（实测：即使把 `:workId` 那条写在前面，`/miniapp/works`
    // 仍匹配到列表页）。故这里不依赖声明顺序——但有回归用例守着，
    // 以防将来有人把它改成嵌套子路由而引入歧义。
    GoRoute(
      path: SpbRoutes.works,
      builder: (context, state) => const _WorksPage(),
    ),
    GoRoute(
      path: '/miniapp/works/:workId',
      builder: (context, state) =>
          _WorkDetailPage(workId: state.pathParameters['workId'] ?? ''),
    ),
  ];
}

/// 登录页（接线到认证用例）。
class _LoginPage extends ConsumerWidget {
  const _LoginPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LoginPage(
      state: ref.watch(authStateProvider),
      onSignIn: () => ref.read(authControllerProvider).signIn(),
    );
  }
}

/// 底部标签栏外壳。
class _AppShell extends StatelessWidget {
  const _AppShell({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        // goBranch 会切到对应分支并恢复它的导航栈。
        onDestinationSelected: navigationShell.goBranch,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

/// 「对话」标签：对话列表。
///
/// 管理动作（改名/归档/删除）交给 `groupActionProvider`（异常 → 用户可读提示
/// 的翻译在那里）。长按条目打开菜单。
///
/// 新建对话直接调 `api.createGroup`：它只有「拿到 ChatGroup 或抛错」一种结果，
/// 没有 `groupActionProvider` 那种多结果语义需要归一化。导航复用 `onOpenGroup`
/// （见桌面端同一处的说明）。
class _ConversationsTab extends ConsumerWidget {
  const _ConversationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(chatApiProvider);
    final pendingCount = ref
        .maybeWhen(data: (n) => n, orElse: () => 0);
    return GroupListPage(
      api: api,
      onOpenGroup: (group) => context.go(SpbRoutes.chat(group.id)),
      onGroupAction: ref.watch(groupActionProvider),
      onSearch: () => context.go(SpbRoutes.search),
      // 工作台（小程序 BFF）只有移动端接——它是为小程序/移动端做的投影层。
      onOpenWorks: () => context.push(SpbRoutes.works),
      // 不需要 userId：身份来自网关注入的 `X-User-ID`，请求体里没有 user_id。
      onCreateGroup: (title) => api.createGroup(title: title),
      groupTitleOf: (gid) => _titles[gid],
      onOpenGroup: (groupId, turnId) => context.go(SpbRoutes.chat(groupId)),
    );
  }
}

/// 搜索页（接线到注入的搜索实现）。
///
/// 点击命中项 `push` 而不是 `go`：搜索页要留在栈里，从对话返回时能回到
/// 搜索结果继续看下一条。用 `go` 会替换整个栈，返回直接跳回对话列表，
/// 用户得重新搜一次。
class _SearchPage extends ConsumerWidget {
  const _SearchPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SearchPage(
      search: ref.watch(searchChatProvider),
      onOpenHit: (hit) => context.push(SpbRoutes.chat(hit.groupId)),
      onOpenTurn: (groupId) => context.go(SpbRoutes.chat(groupId)),
    );
  }
}

/// 「设置」标签（接线到注入的设置读写与平台能力）。
///
/// ## 与桌面端的差异
///
/// 移动端注入 [NoopDesktopCapabilities]（`isSupported == false`），故设置页
/// **不展示**托盘/全局快捷键区块——展示一堆点了没反应的开关比不展示更糟。
///
/// 目录也不可选（应用沙箱由系统分配），但**仍展示**：用户需要知道文件落在
/// 哪里才能去文件管理器里找。
class _SettingsTab extends ConsumerWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPage(
      loadSettings: ref.watch(loadSyncSettingsProvider),
      saveSettings: ref.watch(saveSyncSettingsProvider),
      loadGroups: ref.watch(loadSyncGroupsProvider),
      scanGroups: ref.watch(scanLocalGroupsProvider),
      executePrune: ref.watch(executePruneProvider),
      pickDirectory: ref.watch(pickDirectoryProvider),
      capabilities: ref.watch(desktopCapabilitiesProvider),
      onOpenSync: () => context.go(SpbRoutes.sync),
    );
  }
}

/// 交付物同步页（接线到同步用例）。
///
/// ## 与桌面端的差异：没有目录选择器
///
/// 移动端目录由系统分配（应用沙箱），用户不选路径。`pickDirectoryProvider`
/// 恒返回 null（「用户取消」），故点「选择目录」不会有任何副作用——
/// 这比隐藏按钮更简单，也让两端共用同一个页面组件。
class _SyncPage extends ConsumerWidget {
  const _SyncPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localRoot = ref.watch(syncLocalRootProvider).value;

    return SyncPage(
      initialLocalRoot: localRoot,
      pickDirectory: ref.watch(pickDirectoryProvider),
      runSync: ref.watch(runSyncActionProvider),
      onLocalRootChanged: (root) {
        // 移动端目录不可改，保存是空操作（见 provider 说明）。
        ref.read(saveLocalRootActionProvider)(root).catchError((Object e) {
          SpbLog.warn('保存同步目录失败', {'error': e.toString()});
          return false;
        });
      },
    );
  }
}

/// 对话时间线。
class _ChatPage extends ConsumerStatefulWidget {
  const _ChatPage({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<_ChatPage> {
  /// 已解析的 userId。为 null 表示 `GET /api/auth/me` 尚未返回。
  ///
  /// ## 为什么必须显式持有它（issue #2）
  ///
  /// 控制器 provider 是 `family`，构造它需要**真实的** userId。若在 userId 未就绪
  /// 时就构造，会得到连 `/users//chat/stream` 的控制器，且后续 provider 重建出
  /// 正确实例时，旧实例的 `start()` 已经跑过——新实例永远不被 start。
  /// 故 build 在 userId 就绪前只渲染加载态。
  String? _userId;

  /// 是否正在解析 userId（防重复请求）。
  bool _resolvingUser = false;

  /// 已聚焦的 `userId:groupId`。去重键必须含 userId：只用 groupId 时，
  /// userId 从「未就绪」变为「已就绪」不会改变键，于是新 userId 的控制器
  /// 永不被 start（issue #2 的时序）。
  String? _focused;

  /// 已建立 SSE 连接的 userId。
  ///
  /// ## 为什么需要它（切 group 不重连）
  ///
  /// SSE 是 **user 级订阅**：同一 userId 下换 group 只需换聚焦目标，连接本身
  /// 应复用。而 `SseClient.connect()` 会把 `_lastEventId` 置 null（游标清零），
  /// 于是「切对话就重连」会**丢掉续接能力**——断线重连时无法带 cursor 回放，
  /// 只能整段重拉。
  ///
  /// 故：首次聚焦该 userId 用 `start()`（建连），此后用 `switchGroup()`
  /// （只清缓冲 + 重新回填，不重连）。
  String? _connectedUserId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveUserAndFocus());
  }

  @override
  void didUpdateWidget(_ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) _resolveUserAndFocus();
  }

  /// 先解析 userId，再聚焦到当前 group。
  Future<void> _resolveUserAndFocus() async {
    if (!mounted || _resolvingUser) return;
    _resolvingUser = true;
    try {
      // 必须先 await 到真实 id：`currentUserIdProvider` 首次读取必然 pending，
      // 直接读 `.value` 只会拿到 null（issue #2 的根因）。
      final userId = await ref.read(currentUserIdProvider.future);
      if (!mounted) return;
      setState(() => _userId = userId);
      await _focus(userId);
    } on SpbError catch (e) {
      SpbLog.warn('解析当前用户失败，对话页停留在加载态', {'error': e.toString()});
    } finally {
      _resolvingUser = false;
    }
  }

  /// 聚焦到当前 group。
  ///
  /// 用 `_focused` 去重：`start`/`switchGroup` 会清空缓冲并重新回填 timeline，
  /// 若每次 rebuild 都调用会导致列表反复闪烁。
  Future<void> _focus(String userId) async {
    final key = '$userId:${widget.groupId}';
    if (!mounted || _focused == key) return;
    _focused = key;

    final controller = ref.read(chatStreamControllerProvider(userId));
    if (_connectedUserId == userId) {
      // 同一 userId 内切 group：复用已有连接（不调 connect，游标保留）。
      await controller.switchGroup(widget.groupId);
    } else {
      // 首次聚焦：建立 SSE 连接。
      await controller.start(groupId: widget.groupId);
      _connectedUserId = userId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = _userId;
    // userId 未就绪：不构造控制器（`family` 需要非空 id），显示加载态。
    if (userId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('对话')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final controller = ref.watch(chatStreamControllerProvider(userId));
    final api = ref.watch(chatApiProvider);

    return ConversationPage(
      controller: controller,
      title: '对话',
      // 待处理收件箱消息（可撤销）。
      //
      // 撤销需要 userId，而页面不该知道 userId 从哪来——故在这里闭包捕获
      // （本 State 已经解析出了真实 userId，见 _resolveUserAndFocus）。
      loadPending: () => api.pendingMessages(userId, groupId: widget.groupId),
      undoPending: (messageId) => api.undoMessage(userId, messageId),
      // 切换 group 时重新加载：Flutter 会复用本页 State，
      // 不靠这个键就会一直显示上一个 group 的待处理消息。
      pendingReloadKey: widget.groupId,
      // 停止生成：`POST /chat/turns/:turn_id/cancel`。
      // 路径里没有 user_id，身份来自网关注入的 `X-User-ID`。
      onCancelTurn: (turnId) => api.cancelTurn(turnId),
      // 向上翻页：加载更早历史。
      //
      // 直接委托给控制器：游标（缓冲区最小 globalSeq）与去重都是**领域状态**，
      // 页面与 router 都不应该知道它。返回值 `hasMore` 由页面用来决定是否
      // 继续触发（false = 已到最早）。
      onLoadOlder: controller.loadOlder,
      // 当前对话的身份：换了 group 要重置「已到最早」的翻页标记。
      //
      // 控制器实例在切 group 时**不变**（`switchGroup` 复用同一条 SSE），
      // 且 `_ChatPage` 未带 key、State 被复用，故页面无法自行察觉切换，
      // 必须显式告知。
      historyKey: widget.groupId,
      // 手动重连：断线/重连失败时用户不必干等退避计时器。
      //
      // family 的键必须是 **userId**（provider 的键就是它，SSE 是 user 级订阅，
      // 一个 userId 一条连接）。传 groupId 会命中另一个 family 条目，创建出一个
      // **多余的、无人监听的控制器**。
      //
      // 注：写错键**不会**导致「点了没反应」——`sseClientProvider` 是跨对话共享的
      // 单例（见其文档），`reconnect()` 最终只是 `_sse.resume()`，而那个共享 client
      // 上确实有 `_path`。故错误键只是白建一个对象，不会坏功能。仍然写对，是因为
      // 「聚焦哪个 group、游标停在哪」都归控制器所有，重建一个空控制器来表达动作
      // 是错的意思表达；且一旦将来控制器不再是无状态转发（例如加了本地重试计数），
      // 这种「靠共享单例兜住」的写法就会真的出错。
      //
      // 用 `ref.read` 而非 `ref.watch`：这是**动作**不是数据依赖，用 watch 会在
      // 每次连接状态变化时重建本 widget。
      onResolveConfirmation: (groupId, confirmationId, option) {
        // 真实路径：POST /api/chat/groups/:group_id/confirmations/:id/resolve
        // （挂载点 ext_routes.go:39）。服务端 `misc.go:resolve` 绑定
        // `{action, comment}`，把 action 写进 `resolved_action`，status 固定
        // `resolved`（受 CHECK 约束：pending|resolved|expired|cancelled）。
        // 故必须传**动作**而非状态词。
        api
            .resolveConfirmation(
              groupId,
              confirmationId,
              action: _optionToAction(option),
            )
            .catchError((Object e) => debugPrint('确认提交失败: $e'));
      },
    );
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return;
    final ufs = ref.read(ufsApiProvider);
    final res = await ufs.download(fileId);
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) return;
    final dir = await getApplicationSupportDirectory();
    final target = Directory(p.join(dir.path, 'downloads', 'agent'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final safeName = p.basename(file.fileName.isEmpty ? 'agent-file' : file.fileName);
    await File(p.join(target.path, safeName))
        .writeAsBytes(res.bytes!, flush: true);
  }

  static String _optionToAction(String option) => switch (option) {
    '继续' => 'approve',
    '取消' => 'reject',
    _ => option,
  };
}

/// 悬浮输入窗页面。
/// 工作列表页（小程序工作台）。
///
/// 点条目进入详情——workId 就是 group id。
class _WorksPage extends ConsumerWidget {
  const _WorksPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WorksPage(
      loadWorks: ref.watch(loadMiniappWorksProvider),
      onOpenWork: (work) => context.push(SpbRoutes.work(work.id)),
      // 新建后直接进详情：新工作的标题是占位符「新会话」，列表里一堆同名条目
      // 看不出哪个是自己刚建的；进详情才能看到状态与进度。
      //
      // ## 为什么在这里导航，而不是在 WorksPage 内部
      //
      // 导航目标是装配层的事（与 `onOpenWork` 同一约定）。且本页拿到的是
      // `workId` 而非完整的 `MiniappWork`，页面内部造不出来。
    );
  }
}

/// 工作详情页。
///
/// ## 为什么用 `family(workId)` 而不是在页面内部取
///
/// 六个注入点全部依赖 workId，若在页面内部从路由读，页面就得知道路由——那是
/// app 装配层的事。用 family 把它变成构造参数，页面保持纯注入（可测）。
///
/// 用 `context.push` 而非 `go`：详情是从列表**深入**的一层，返回应回到列表
/// 并保留滚动位置。
class _WorkDetailPage extends ConsumerWidget {
  const _WorkDetailPage({required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WorkDetailPage(
      loadDetail: ref.watch(loadMiniappWorkDetailProvider(workId)),
      loadEvents: ref.watch(loadMiniappWorkEventsProvider(workId)),
      loadArtifacts: ref.watch(loadMiniappArtifactsProvider(workId)),
      downloadArtifact: ref.watch(downloadMiniappArtifactProvider(workId)),
      saveArtifact: ref.watch(saveMiniappArtifactProvider),
      sendMessage: ref.watch(sendMiniappMessageProvider(workId)),
      complete: ref.watch(completeMiniappWorkProvider(workId)),
      stop: ref.watch(stopMiniappWorkProvider(workId)),
      resolveConfirmation: ref.watch(resolveMiniappConfirmationProvider),
    );
  }
}

class _QuickCapturePage extends ConsumerWidget {
  const _QuickCapturePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useCase = ref.watch(quickCaptureUseCaseProvider);

    return QuickCapturePage(
      submit: (input) => useCase.submit(input: input),
      onQueued: (outcome) {
        // 提交成功后导航到服务端判定的对话。不回显（不传 echoInto）：
        // 本页没有可见的对话，回显由目标对话页的 timeline 回填完成。
        if (context.mounted) context.go(SpbRoutes.chat(outcome.groupId));
      },
      onCancel: () {
        if (context.mounted) context.go(SpbRoutes.conversations);
      },
    );
  }
}
