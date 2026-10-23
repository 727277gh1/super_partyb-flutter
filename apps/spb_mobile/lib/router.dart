import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import 'providers.dart';

/// 路由路径常量（集中定义，避免 `context.go` 与路由表两处字面量不一致）。
class SpbRoutes {
  const SpbRoutes._();

  static const conversations = '/';
  static const settings = '/settings';

  /// 无归属输入窗（带附件，走 `/me/quick-capture/enqueue`）。
  ///
  /// 见 `OverlayQuickCapturePage` 的类文档。
  ///
  /// ## 为什么没有「无附件的同步版」路由
  ///
  /// 本端曾并存一条 `/quick-capture`（走 `/me/quick-capture`，同步返回归属、
  /// 无附件）。它已被删除：**无任何导航调用点**（唯一的入口
  /// `onOpenQuickCapture` 指向本路由），而纯文本场景两者行为等价——保留功能
  /// 更弱的那个反而误导用户。桌面端已先做过同一删除（commit 1866b14）。
  static const overlay = '/overlay';

  /// 小程序工作台：工作列表。
  ///
  /// 挂在 shell **之外**（整屏页，无底部标签栏）。
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

  /// 跨 group 待确认收件箱（与 search 同挂在「对话」标签下）。
  static const confirmations = '/confirmations';

  /// 我的最近轮次。
  static const myTurns = '/my-turns';

  /// 习惯管理（规则列表 + 执行历史）。
  ///
  /// 与 [myTurns] 同挂在「对话」标签的导航栈下：它们都是**对话的衍生视图**
  /// （从对话里提取出的轮次/规则），从对话列表进入比从设置进入更符合心智。
  static const habits = '/habits';
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

    return resolveAuthRedirect(
      authenticated: auth.isAuthenticated,
      matchedLocation: state.matchedLocation,
      fromRaw: state.uri.queryParameters['from'],
      loginRoute: SpbRoutes.login,
      fallbackRoute: SpbRoutes.conversations,
    );
  };
}

/// 认证守卫的**纯决策函数**（不碰 `BuildContext` / Riverpod）。
///
/// 与桌面端同构，实现细节与理由见桌面 `router.dart` 的同名函数。摘要：
///
/// - 未认证 → 带上 `from` 去登录页；
/// - 已认证且停在登录页 → **先消费 `from`**（回跳必须由守卫统一决策，
///   否则登录成功瞬间就被 `refreshListenable` 重跑的守卫送走）；
/// - `from` 只接受站内路径（挡绝对 URL 与 `//host` 协议相对 URL），
///   并拒绝回跳到登录页自身（重定向环），非法值静默回落 [fallbackRoute]。
///
/// 抽成纯函数是为了能被精确断言：go_router 对匹配不到的路由会静默回落，
/// 导致「校验失效」与「校验生效」在 widget 测试里表现完全相同。
String? resolveAuthRedirect({
  required bool authenticated,
  required String matchedLocation,
  required String? fromRaw,
  required String loginRoute,
  required String fallbackRoute,
}) {
  final goingToLogin = matchedLocation == loginRoute;

  if (!authenticated) {
    if (goingToLogin) return null;
    return '$loginRoute?from=${Uri.encodeComponent(matchedLocation)}';
  }

  if (goingToLogin) return _safeFrom(fromRaw, loginRoute) ?? fallbackRoute;
  return null;
}

/// 校验 `from` 是否为可安全回跳的站内路径，非法返回 null。
String? _safeFrom(String? raw, String loginRoute) {
  // 空串其实已被下面的 `startsWith('/')` 拒绝（`''.startsWith('/') == false`），
  // 显式判一次是为了让「空值非法」这条规则在函数开头就可见，而不必读到
  // 第三行才推断出来。**这属于可读性冗余，不是独立防线**（实测：删掉
  // `raw.isEmpty` 后测试全绿）。
  if (raw == null || raw.isEmpty) return null;
  if (!raw.startsWith('/')) return null;
  if (raw.startsWith('//')) return null;
  if (raw == loginRoute) return null;
  return raw;
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
                GoRoute(
                  path: 'confirmations',
                  builder: (context, state) =>
                      const _PendingConfirmationsPage(),
                ),
                GoRoute(
                  path: 'my-turns',
                  builder: (context, state) => const _MyTurnsPage(),
                ),
                GoRoute(
                  path: 'habits',
                  builder: (context, state) => const _HabitsPage(),
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
    // 无归属输入窗在 shell **之外**：它是一个整屏的临时页面，不应带标签栏，
    // 也不应占据某个标签的导航栈。
    GoRoute(
      path: SpbRoutes.overlay,
      builder: (context, state) => const _OverlayQuickCapturePage(),
    ),
    // 小程序工作台同样在 shell **之外**：工作列表与详情都是整屏页（详情页
    // 底部有消息输入框，再叠一层标签栏会挤掉内容）。
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
      // 粘贴导入会话：IdP 未注册移动端 public client 时的唯一登录入口
      //（深链闭环依赖 `partyb://oidc/callback` 注册，见 docs/mobile-oidc-deeplink.md）。
      onImportSession: (raw) =>
          ref.read(authControllerProvider).importSession(raw),
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
        .watch(pendingConfirmationCountProvider)
        .maybeWhen(data: (n) => n, orElse: () => 0);
    return GroupListPage(
      api: api,
      // group 变更实时增量更新（新建/删除/归档/改名）。
      //
      // 列表页自己无法收到事件：它不持有 SSE 连接（连接由对话页 `start()`
      // 建立）。本 provider 用 `ensureConnected` 确保连接在，再转发变更流
      // ——详见 provider 文档。
      groupUpdates: ref.watch(groupUpdatesProvider),
      onOpenGroup: (group) => context.go(SpbRoutes.chat(group.id)),
      onGroupAction: ref.watch(groupActionProvider),
      onSearch: () => context.go(SpbRoutes.search),
      onOpenConfirmations: () => context.go(SpbRoutes.confirmations),
      pendingConfirmationCount: pendingCount,
      // 工作台（小程序 BFF）只有移动端接——它是为小程序/移动端做的投影层。
      onOpenWorks: () => context.push(SpbRoutes.works),
      // 习惯：两端都接（端点与页面都是共享的，见 `spb_features` 的 `HabitsPage`）。
      onOpenHabits: () => context.push(SpbRoutes.habits),
      // 全局设置：移动端**不接**。设置是底部标签栏的第二个 tab（`_AppShell`
      // 的 `NavigationBar`），在列表 AppBar 再放一个图标就是同一目标的第二个
      // 入口——而窄屏 AppBar 已有 5 个常驻图标（§6.16 的溢出教训）。
      // 该差异已登记在 `tools/check_wiring_parity.sh` 的 exempt["desktop"]
      // （`onOpenSettings` 是桌面端独有的接线）。
      // 对话列表缓存（issue #26 切片 A）。与桌面端同构，理由见桌面端 router 注释：
      // userId 必须走本地优先的 `cachedUserIdProvider`，否则断网时拿不到 userId、
      // 回落失效（而断网正是本功能要覆盖的场景）。
      cache: ref.watch(groupCacheStoreProvider),
      userId: ref.watch(cachedUserIdProvider).value,
      // 无归属快速输入入口（带附件）。
      //
      // ## 为什么移动端需要它
      //
      // 此前 `/overlay` 与 `/quick-capture` 两条路由都注册了、页面与测试也在，
      // 但**没有任何导航调用点**——用户碰不到（桌面端靠 Alt+Space 与托盘，
      // 移动端没有快捷键也没有托盘）。移动端只能从列表页进入，故用 FAB。
      //
      // 后来 `/quick-capture` 那条被彻底删除（无导航点且功能是它的子集），
      // 本 FAB 就是**唯一**入口。
      //
      // 用 `push` 而非 `go`：悬浮窗是临时页，`go` 会把它替换进列表所在的
      // 分支栈，返回时列表的滚动位置会丢。
      onOpenQuickCapture: () => context.push(SpbRoutes.overlay),
      // 不需要 userId：身份来自网关注入的 `X-User-ID`，请求体里没有 user_id。
      onCreateGroup: (title) => api.createGroup(title: title),
    );
  }
}

/// 跨 group 待确认收件箱（移动端，语义同桌面端 `_PendingConfirmationsPage`）。
class _PendingConfirmationsPage extends ConsumerStatefulWidget {
  const _PendingConfirmationsPage();

  @override
  ConsumerState<_PendingConfirmationsPage> createState() =>
      _PendingConfirmationsPageState();
}

class _PendingConfirmationsPageState
    extends ConsumerState<_PendingConfirmationsPage> {
  final _titles = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(chatApiProvider);
    return PendingConfirmationsPage(
      fetch: () async {
        final items = await api.listConfirmationsTyped(status: 'pending');
        await Future.wait(
          items.map((c) async {
            if (_titles.containsKey(c.groupId)) return;
            try {
              final g = await api.getGroup(c.groupId);
              _titles[c.groupId] = g.title;
            } on Object catch (e) {
              // 拉取失败不阻断列表渲染（卡片展示「未知对话」）。
              SpbLog.debug('待确认卡片预取对话标题失败', {
                'group_id': c.groupId,
                'error': e.toString(),
              });
            }
          }),
        );
        // 刷新计数角标。
        //
        // ## 为什么 invalidate 被依赖者而不是 count
        //
        // `pendingConfirmationCountProvider` 是
        // `await ref.watch(pendingConfirmationsProvider.future)` 的派生值。
        // 只 invalidate count 时它重建后读到的仍是被缓存的
        // `pendingConfirmationsProvider` 结果——角标不会变（本行原先正是
        // 这个失效调用）。invalidate 被依赖者，count 会因 watch 依赖自动重算。
        ref.invalidate(pendingConfirmationsProvider);
        return items;
      },
      groupTitleOf: (gid) => _titles[gid],
      onOpenGroup: (groupId, turnId) => context.go(SpbRoutes.chat(groupId)),
      onResolve: (c, action) async {
        await api.resolveConfirmation(c.groupId, c.id, action: action);
      },
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
    );
  }
}

/// 我的最近轮次（移动端，语义同桌面端 `_MyTurnsPage`）。
class _MyTurnsPage extends ConsumerWidget {
  const _MyTurnsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(chatApiProvider);
    return MyTurnsPage(
      // 透传页面上的筛选条件（days/source/status/groupId → 服务端 query）。
      fetch: ({days, status, source, groupId}) => api.listMyTurns(
        days: days,
        status: status,
        source: source,
        groupId: groupId,
      ),
      // 关键词搜索（issue #18）。与 fetch 分开注入：两个端点的参数集不相交，
      // 合并会让「搜索时也把筛选条件发下去」变成容易顺手写出的 bug，而服务端
      // 会静默忽略它们。
      search: (query) => api.searchMyTurns(query: query),
      // 点击一行 → 弹轮次详情（issue #19）。
      //
      // 不再只是 `context.go(chat(groupId))`：那样只能跳到对话列表，
      // 用户看不到「这一轮到底发生了什么」。turnId 现在会传进来，
      // 故可以直接拉详情。
      onOpenTurn: (groupId, turnId) =>
          _showTurnDetail(context, ref, groupId, turnId),
    );
  }

  /// 弹「轮次详情」底部弹层。
  ///
  /// ## 为什么用 `showModalBottomSheet`（与 AGENTS.md §6.10 的两端载体差异一致）
  ///
  /// 移动端小屏放不下桌面端那种常驻/大尺寸对话框，底部弹层是既有载体选择
  /// （`_openDeliverables` / `_openSettings` 等同款）。桌面端用 `showDialog`。
  ///
  /// ## 为什么只接 `onDownload`
  ///
  /// 移动端注入 `NoopDesktopCapabilities`，`openFile` / `revealPath` 恒 false。
  /// 接上会让用户点「打开」得到「无法打开文件」——比不展示该项更困惑（面板在
  /// 回调为 null 时不渲染对应菜单项）。与 `_openDeliverables` 的既有取舍一致。
  Future<void> _showTurnDetail(
    BuildContext context,
    WidgetRef ref,
    String groupId,
    String turnId,
  ) async {
    final loader = ref.read(loadTurnDetailProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.85,
        child: TurnDetailSheet(
          groupId: groupId,
          turnId: turnId,
          load: loader.call,
          // 不注入文件回调：下载 / 打开 / 预览的实现是 `_ChatPageState` 的
          // 私有方法（`_ensureAgentFileLocal` 等），从本页取不到；把它们提成
          // provider 属独立重构，不在本 issue 范围。未注入时 `AgentFileCard`
          // 只渲染文件信息、不渲染菜单项（其既有约定）。
        ),
      ),
    );
  }
}

/// 习惯管理页。
///
/// 与桌面端 `_HabitsPage` 逐字同构（除导航：移动端 `context.go` 到对话会在
/// 当前分支里推进，符合标签栏栈语义）。
class _HabitsPage extends ConsumerStatefulWidget {
  const _HabitsPage();

  @override
  ConsumerState<_HabitsPage> createState() => _HabitsPageState();
}

class _HabitsPageState extends ConsumerState<_HabitsPage> {
  /// groupId → title 缓存（`/api/habits/runs` 只给 id）。
  final _titles = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(habitApiProvider);
    return HabitsPage(
      loadHabits: () => api.listHabits(),
      loadRuns: (filter) async {
        // 服务端 `GET /api/habits/runs?days=&trigger_reason=` 直接筛选，
        // 且响应带 `daily_budget`（今日已用/上限）。
        final result = await api.listAllRunsWithBudget(
          days: filter.days,
          triggerReason: filter.reason?.wire,
        );
        final runs = result.items;
        // 预取涉及的 group 标题（缺失则静默）。
        await Future.wait(
          runs.map((r) async {
            final gid = r.deliveryGroupId ?? r.originGroupId;
            if (gid.isEmpty || _titles.containsKey(gid)) return;
            try {
              final g = await ref.read(chatApiProvider).getGroup(gid);
              _titles[gid] = g.title;
            } on Object catch (e) {
              // 标题查不到不该让整个列表失败（展示「未知对话」）。
              SpbLog.debug('运行记录预取对话标题失败', {
                'group_id': gid,
                'error': e.toString(),
              });
            }
          }),
        );
        return result;
      },
      groupTitleOf: (gid) => _titles[gid],
      onTrigger: (h) => api.triggerHabit(h.id),
      onPause: (h) => api.pauseHabit(h.id),
      onResume: (h) async => api.resumeHabit(h.id),
      onArchive: (h) => api.archiveHabit(h.id),
      onCreate: (draft) async {
        final r = await api.createHabit(
          topicKey: draft.topicKey,
          acceptanceLevel: draft.acceptanceLevel,
          triggerConfig: draft.triggerConfig,
        );
        return r.patternId;
      },
      onOpenTurn: (groupId, _) => context.go(SpbRoutes.chat(groupId)),
      // 编辑 + 按规则查记录：与桌面端逐字同构。
      onEdit: (h, patch) => api.patchHabit(
        h.id,
        topicKey: patch.topicKey,
        acceptanceLevel: patch.acceptanceLevel,
        triggerConfig: patch.triggerConfig,
        preferredAgentId: patch.preferredAgentId,
      ),
      loadHabitRuns: (patternId) => api.listHabitRuns(patternId),
      // 建议收件箱 + 洞察摘要：与桌面端逐字同构（同一套端点与同一页面）。
      loadSuggestions: (filter) => api.listSuggestions(filter: filter),
      resolveSuggestion: (s, action, {snooze}) => api
          .resolveSuggestion(
            s.id,
            action: action,
            snoozeUntil: snooze?.until(DateTime.now()),
          )
          .then((_) {}),
      unresolveSuggestion: api.unresolveSuggestion,
      loadInsights: (days) => api.habitInsights(days: days),
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
      // 移动端没有托盘/全局快捷键（触屏），恒不展示「桌面集成」区块——
      // 直接传常量，无需为这一个布尔去读平台能力接口。
      desktopInfo: DesktopIntegrationInfo.hidden,
      loadNotifications: ref.watch(loadNotificationSubscriptionsProvider),
      saveNotifications: ref.watch(saveNotificationSubscriptionsProvider),
      // 外观：选中即保存（不走 draft，见 SaveThemeMode 的说明）。
      loadThemeMode: ref.watch(loadThemeModeProvider),
      saveThemeMode: ref.watch(saveThemeModeProvider),
      // 个人偏好：昵称 / 头像 / 回复语言 / 默认 Agent。
      //
      // 昵称回落值取自 `/api/auth/me` 的 name（服务端已按
      // display_name → users.name → email 解析好），仅作输入框占位提示。
      // 用 `.value` 而非 `watch(future)`：本页不该因「我是谁」重新加载而重建
      // （会丢掉表单草稿）。
      loadPreferences: ref.watch(loadUserPreferencesProvider),
      savePreferences: ref.watch(saveUserPreferencesProvider),
      // 默认 Agent 下拉的候选项。
      //
      // 用 `.value ?? const []` 而非把 `AsyncValue` 喂进页面：本页是
      // ConsumerWidget，agent 列表晚到时只重建一次（下拉多出几项），
      // 而 `UserPreferencesCard` 的 State 一直存活，**用户已填的草稿不丢**。
      // 理由详见 `preferenceAgentOptionsProvider` 的文档。
      preferenceAgentOptions:
          ref.watch(preferenceAgentOptionsProvider).value ?? const [],
      preferenceFallbackDisplayName:
          ref.watch(currentUserProvider).value?.displayNameFallback ?? '',
      onOpenSync: () => context.go(SpbRoutes.sync),
      onOpenMyTurns: () => context.go(SpbRoutes.myTurns),
      // 退出登录：清凭证 → 回登录页。
      //
      // 显式跳转是「双保险」：`signOut()` 置为未登录后，路由守卫本身就会重定向
      // 到登录页（实测：删掉 `context.go` 后测试依然全绿）。保留它是为了把
      // 「登出后去哪」写在调用点，而不必跳去守卫确认。`context.mounted` 让它在
      // 页面已移除时安静跳过。理由详见桌面端同名注释。
      onSignOut: () async {
        await ref.read(authControllerProvider).signOut();
        if (context.mounted) context.go(SpbRoutes.login);
      },
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
      // 回传是显式逐文件动作（自动同步仍单向，见 SyncPage 文档）。
      scanDirtyFiles: ref.watch(scanDirtyFilesActionProvider),
      uploadChanges: ref.watch(uploadChangesActionProvider),
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

  /// 建议卡标注的「下一条消息由谁回答」（follow_up 的 agent_id）。
  ///
  /// 点击建议时设置，发送时经 [ConversationPage.onSend] 透传给控制器。
  /// null 表示未标注（服务端 routingMode=auto 照常走分类链）。
  String? _selectedAgentId;

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

  /// controller.activities 的订阅（与桌面端同取向）。
  ///
  /// 移动端此前只订阅 `items`（未订阅 gate 决策），活动指示是它接入的
  /// 第二条独立流。
  StreamSubscription<Map<String, TurnActivitySnapshot>>? _activitiesSub;

  /// controller.contextUsage 的订阅（与 activities 平行，见领域层说明）。
  StreamSubscription<ContextUsage?>? _contextUsageSub;

  /// 当前对话的权威 ChatGroup（设置弹层的目标文本与三个开关的真源）。
  ///
  /// 移动端没有侧边栏，故设置入口是 AppBar 的一个按钮 → 底部弹层。真源与桌面端
  /// 一致：`GET /chat/groups/:id`，写操作成功后用其响应覆盖。
  ChatGroup? _group;

  /// 设置写操作是否在途（面板用它禁用全部控件，防并发提交把 CAS 打成 409）。
  bool _settingsBusy = false;

  /// agent 切换是否在途。
  ///
  /// 切换会归档旧绑定 + 写新绑定，是**非幂等**的（并发切换会把绑定顺序打乱，
  /// 最后落库的未必是用户最后选的那个）。故在途时禁用入口。
  bool _switchingAgent = false;

  /// 已发过 group 拉取（防重复请求）。
  bool _loadingGroup = false;

  /// 最近一次归约出的执行中活动快照（按 turnId 索引）。
  ///
  /// 存 State 而非在 build 里读 `controller.activitiesSnapshot`：后者是同步
  /// getter，建立不了依赖，事件到达时不会触发重建。
  Map<String, TurnActivitySnapshot> _activities = const {};

  /// 最近一次归约出的上下文用量快照（同上）。
  ///
  /// 为 null 表示尚无可用用量数据（服务端未发射或载荷无法解析），
  /// 页面据此隐藏用量区。
  ContextUsage? _contextUsage;

  /// controller.executionStatus 的订阅（queue_state / retry_scheduled）。
  StreamSubscription<ExecutionStatus?>? _executionStatusSub;

  /// 最近一次归约出的等待/重试状态；null 表示当前无等待。
  ExecutionStatus? _executionStatus;

  /// controller.ttsStatus 的订阅（tts_started / tts_completed / tts_failed）。
  StreamSubscription<TtsStatus?>? _ttsStatusSub;

  /// controller.staleTurnIds 的订阅（超时兜底：长时间无进展的 turn）。
  ///
  /// 判据（「距最后一次事件」）与计时都在控制器里：它看得见 `turn_activity`
  /// 这类**不进 items** 的续期信号。本页只消费结果，不自建计时。
  StreamSubscription<Set<String>>? _staleTurnIdsSub;

  /// 最近一次超时集合（同上，存在 State 里才能触发重建）。
  Set<String> _staleTurnIds = const {};

  /// controller.goalUpdates 的订阅（goal_updated）。
  ///
  /// 事件携带与 `GET /goals/current` 同构的完整快照，故直接套进 _group
  /// 即可，无需再发一次 HTTP（见 GoalUpdate 类文档）。
  StreamSubscription<GoalUpdate>? _goalUpdatesSub;

  /// controller.groupUpdates 的订阅（本页只关心 metadata 变更）。
  ///
  /// ## 为什么对话页也要订阅（列表页已经在用了）
  ///
  /// `group_metadata_updated` 是 Goal Gate **后台**自动停用时的唯一通知：
  /// 服务端改了 `chat_groups.metadata`（`markGoalGateCompleted` 写
  /// `gate["enabled"] = false`），但没有任何 HTTP 响应回到客户端。
  /// 不消费它，设置面板会继续显示「自动实现目标：开」——事实性错误。
  ///
  /// 列表页虽也收到该事件，但 `GroupListPage._onGroupUpdate` 对
  /// `GroupUpdateOp.metadata` 是**刻意忽略**的（它只渲染标题与状态，
  /// metadata 的开关在对话页/设置面板编辑）。故本页必须自己订阅。
  StreamSubscription<GroupUpdate>? _groupUpdatesSub;

  /// 最近一次归约出的播报状态；null 表示本群未开语音/尚无事件。
  TtsStatus? _ttsStatus;

  /// controller.items 的订阅（交付物弹层的刷新令牌用）。
  ///
  /// ## 为什么要订阅（本页此前只订阅独立流）
  ///
  /// 交付物弹层的内容由 UFS 取数，与时间线无关；但 agent 新产出文件时
  /// **时间线不会自己刷新**——`agent.file.*` 事件只改变归约结果。若不监听
  /// `items`，用户必须手动点刷新才能看到刚产出的文件。
  StreamSubscription<List<ConversationItem>>? _itemsSub;

  /// 最近一次归约出的对话项（供交付物弹层的刷新令牌与后续待办弹层复用）。
  List<ConversationItem> _items = const [];

  /// 交付物弹层的刷新令牌：出现新的 agent 文件时自增。
  ///
  /// 面板按令牌值变化重拉，而不是比较取数闭包的函数身份（后者每次 build
  /// 都是新闭包，会变成每次 rebuild 都重拉）。见 `GroupDeliverablesPanel`
  /// 的「刷新模型」类文档。
  int _deliverablesReloadToken = 0;

  /// 「见过的文件 id」基线，用于判断新文件（与桌面端同取向）。
  final _seenFileItemIds = <String>{};

  /// 上次见过的确认卡身份集合：用于判定「待确认集合是否变了」。
  ///
  /// 元素形如 `'<confirmation_id>:<resolved>'`——把 `resolved` 也编进身份，
  /// 因为「一张卡被解决」同样是待确认集合的变化（角标要减 1）。
  ///
  /// ## 为什么是可空（null 表示「从未同步」）而不是空集合
  ///
  /// 用 `isEmpty` 判定首次同步有个错：**一个本来就没有确认卡的对话**，
  /// 首次同步后集合仍是空的，于是第二张卡真的到来时也会被当成「首次」而跳过
  /// 刷新。null 把「没同步过」与「同步过且为空」区分开。
  Set<String>? _seenConfirmationIds;

  /// 正在提交作答的确认卡行 id（与桌面端同名集合，两端共享 busy 语义）。
  ///
  /// ## 为什么按卡行 id 去重
  ///
  /// 同一张卡可能在两处可点（时间线内联渲染 + 待办弹层）。若只靠按钮自身
  /// 禁用，两处的 busy 状态互不相知，用户可以在弹层点一下、又回时间线再点
  /// 一下。集合按 `confirmationId`（**卡行 id，不是事件 id**，见
  /// `ConfirmationItem` 的类文档）去重。
  final _resolvingConfirmations = <String>{};

  /// 本对话时间线里已出现的 agent 文件数（去重后），供 AppBar 徽标。
  ///
  /// 与 `_seenFileItemIds` 不同：后者是「刷新令牌的基线」，切对话时会清空；
  /// 本值直接反映 `_items`，切对话后由 `_onItemsChanged` 重新填入。
  int get _agentFileCount => _items
      .whereType<AgentFileItem>()
      .where((f) => !f.isDeleted)
      .map((f) => f.ufsFileId ?? f.relativePath)
      .where((id) => id.isNotEmpty)
      .toSet()
      .length;

  /// 本对话待处理的确认卡数（供 AppBar 徽标）。
  ///
  /// 用 [ConfirmationItem.canResolve] 而非 `!resolved`：前者额外要求
  /// `confirmationId` 与 `groupId` 齐备。只统计能真正提交的卡——否则用户点开
  /// 弹层会看到一张按钮点不动、也没解释的卡（异常载荷的卡）。
  int get _pendingConfirmationCount =>
      _items.whereType<ConfirmationItem>().where((c) => c.canResolve).length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveUserAndFocus();
      _loadGroup();
    });
  }

  @override
  void dispose() {
    _itemsSub?.cancel();
    _activitiesSub?.cancel();
    _contextUsageSub?.cancel();
    _executionStatusSub?.cancel();
    _ttsStatusSub?.cancel();
    _staleTurnIdsSub?.cancel();
    _goalUpdatesSub?.cancel();
    _groupUpdatesSub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      // 先置空再拉：State 被 Flutter 复用，不置空会让新对话的设置弹层
      // 短暂显示上一个对话的目标与开关。
      _group = null;
      _resolveUserAndFocus();
      _loadGroup();
    }
  }

  /// 把本对话切到另一个 agent（含「同 Agent 开新会话」）。
  ///
  /// ## 为什么切换后要重拉 group **并**刷新时间线
  ///
  /// - 重拉 group：`activeSession.agentId` 变了，AppBar 的标签要跟着变；
  /// - 刷新时间线：服务端会归档旧 binding，新 binding 的 `session_id` 是
  ///   lazy 的（下一轮 turn 才回填）。虽然历史消息仍属于这个 group（时间线
  ///   不会少内容），但重拉能保证「下一轮回复来自新 agent」这一事实有最新
  ///   的服务端状态兜底，而不是靠本地推断。
  ///
  /// 失败弹 SnackBar：切换是用户主动发起且带确认的动作，失败必须告知——
  /// 静默失败会让用户以为切好了，接着发消息却发现回复还来自旧 agent。
  Future<GroupAgentSwitchResult> _switchAgent(
    String agentId, {
    required bool forceNewSession,
  }) async {
    if (_switchingAgent) {
      throw const ValidationError('切换正在进行中，请稍候');
    }
    setState(() => _switchingAgent = true);
    try {
      final result = await ref
          .read(agentsApiProvider)
          .switchGroupAgent(
            widget.groupId,
            agentId: agentId,
            forceNewSession: forceNewSession,
          );
      if (!mounted) return result;
      await _loadGroup();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(forceNewSession ? '已开始新会话' : '已切换 Agent')),
          );
      }
      return result;
    } on SpbError catch (e) {
      SpbLog.warn('切换 Agent 失败', {
        'groupId': widget.groupId,
        'agentId': agentId,
        'error': e.toString(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(_describeSwitchError(e))));
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _switchingAgent = false);
    }
  }

  /// 把切换失败翻成用户能看懂的一句话。
  ///
  /// `HttpError.message` 恒为 `"HTTP 400"`，服务端文案在 `body` 里
  /// （见 `AgentsApi._unwrap`），故必须从 body 提取。
  static String _describeSwitchError(SpbError e) {
    if (e is HttpError) {
      final body = e.body ?? '';
      // 404 = agent 已被删除（列表可能是在它删除前拉的）。
      if (e.isNotFound) return '这个 Agent 已不存在，请重新打开列表选择';
      if (body.contains('agentId')) return '切换失败：Agent 参数无效';
      if (e.statusCode == 401) return '登录已过期，请重新登录';
      return '切换失败（HTTP ${e.statusCode}）';
    }
    if (e is NetworkError) return '网络连接失败，请检查网络后重试';
    return e.message;
  }

  /// 拉取当前 group 的权威状态（设置弹层的初始值）。
  ///
  /// 失败只记日志、不阻断对话页：设置入口仍可点开，显示的是「未配置」形态。
  Future<void> _loadGroup() async {
    if (!mounted || _loadingGroup) return;
    _loadingGroup = true;
    try {
      final group = await ref.read(chatApiProvider).getGroup(widget.groupId);
      if (mounted) setState(() => _group = group);
    } on SpbError catch (e) {
      SpbLog.warn('读取对话设置失败', {
        'groupId': widget.groupId,
        'error': e.toString(),
      });
    } finally {
      _loadingGroup = false;
    }
  }

  /// 打开交付物底部弹层（按对话浏览本次产出）。
  ///
  /// ## 为什么用 `showModalBottomSheet` 而不是新路由
  ///
  /// 与 [_openSettings] / [_openGoalTasks] 同一理由：新路由会得到另一个
  /// `_ChatPage` 实例（State 不共享），刷新令牌与 `_group` 都不一致。
  /// 弹层共享同一份 State。
  ///
  /// ## 为什么只接下载，不接打开 / 定位
  ///
  /// 移动端注入的是 `NoopDesktopCapabilities`（见 providers.dart），
  /// `openFile` / `revealPath` 恒返回 false。若接上，用户点「打开」会得到
  /// 「无法打开文件」——比一开始就不展示该项更让人困惑。面板在 `onOpen` /
  /// `onReveal` 为 null 时不渲染对应菜单项，故这里只传 `onDownload`，退化为
  /// 「只读浏览 + 下载」（与 `_downloadAgentFile` 的既有取舍一致）。
  ///
  /// 同理不传 `resolveLocalPath`：它查的是**同步目录**索引，而本弹层回答的是
  /// 「这个对话产出了什么」（远端），两者用途不同。
  Future<void> _openDeliverables() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.8,
          child: GroupDeliverablesPanel(
            // groupId 变化时面板自行清空本地路径并重拉（见其类文档）。
            groupId: widget.groupId,
            // 弹层自带拖拽条，面板标题会与它重复；只保留工具条（刷新 + 计数）。
            title: '',
            loadFiles: () =>
                ref.read(groupDeliverablesProvider(widget.groupId).future),
            onDownload: (file) => ref.read(downloadDeliverableProvider)(file),
            // SSE 推送新文件时 bump（见 _onItemsChanged）。
            reloadToken: _deliverablesReloadToken,
          ),
        ),
      ),
    );
  }

  /// 打开待办底部弹层（跨轮次聚合未解决确认卡）。
  ///
  /// ## 它解决什么（与时间线内联卡的边界）
  ///
  /// 确认卡在时间线里已有内联渲染（`ConfirmationCard`）。本弹层不是替代，
  /// 而是**跨轮次的聚合视图**：时间线里确认卡夹在对话流中，用户在手机上
  /// 向上滚几屏后就看不到「还有一张卡在等我」。弹层把所有未处理的卡按轮次
  /// 集中呈现，最新轮次在最上。
  ///
  /// ## 为什么用 `showModalBottomSheet` 而不是新路由
  ///
  /// 与 [_openSettings] / [_openGoalTasks] 同一理由：新路由会得到另一个
  /// `_ChatPage` 实例（State 不共享），`_resolvingConfirmations` 的 busy 态
  /// 与时间线内联卡就不一致了。
  Future<void> _openTodos() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.8,
          child: GroupTodosPanel(
            // 按轮次聚合（纯函数在领域层，见 TurnGroup 类文档）。
            turns: groupItemsByTurn(_items),
            onResolveConfirmation: _resolveConfirmation,
            resolvingIds: _resolvingConfirmations,
            // 切 group 时清空折叠状态（旧对话的展开位置对新对话无意义）。
            reloadKey: widget.groupId,
            // 弹层自带拖拽条，不再重复面板标题。
            showHeader: false,
          ),
        ),
      ),
    );
  }

  /// 提交确认卡作答。
  ///
  /// ## 动作文案 → 服务端 action
  ///
  /// 真实路径：`POST /api/chat/groups/:group_id/confirmations/:id/resolve`。
  /// 服务端把 `action` 写进 `resolved_action`，`status` 固定为 `resolved`
  /// （受 CHECK 约束：pending|resolved|expired|cancelled）。故必须传**动作**
  /// 而非状态词，映射见 [_optionToAction]。
  ///
  /// ## 成功与失败都解锁
  ///
  /// 失败时应允许重试（不重抛、不弹错误打断阅读，与内联路径的既有行为
  /// 一致）。服务端 CAS 保证重复请求无数据错误。
  void _resolveConfirmation(
    String groupId,
    String confirmationId,
    String option,
  ) {
    if (_resolvingConfirmations.contains(confirmationId)) return;
    setState(() => _resolvingConfirmations.add(confirmationId));
    ref
        .read(chatApiProvider)
        .resolveConfirmation(
          groupId,
          confirmationId,
          action: _optionToAction(option),
        )
        .whenComplete(() {
          if (mounted) {
            setState(() => _resolvingConfirmations.remove(confirmationId));
          }
        })
        .catchError((Object e) {
          debugPrint('确认提交失败: $e');
        });
  }

  /// 打开设置底部弹层。
  ///
  /// ## 为什么用 `showModalBottomSheet` 而不是新路由
  ///
  /// 设置弹层需要读写 `_group` / `_settingsBusy` 这两个 State，而新路由会得到
  /// 另一个 `_ChatPage` 实例（State 不共享），写成功后回写的是那个实例的
  /// `_group`——关掉弹层回到对话页又变回旧值。用弹层共享同一份 State，
  /// 也让「保存中」的 busy 态自然覆盖整个面板。
  Future<void> _openSettings() async {
    final group = _group;
    if (group == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        // 弹层需要跟随外层 setState 重建（写成功后 _group 换了新对象），
        // 故用 StatefulBuilder + 每次 build 重新读 _group。
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.8,
            // 设置与「自动续跑」共用同一弹层（而不是新加第 7 个 AppBar 入口——
            // AppBar 已有 6 个，再加会挤压标题，见 AGENTS.md §6.10）。
            //
            // 两块各自可滚（都是 ListView），故用 Column + Expanded 给它们
            // 有界高度：弹层总高固定，两块按 3:2 分。
            child: Column(
              children: [
                Expanded(
                  flex: 3,
                  child: GroupSettingsPanel(
                    group: _group ?? group,
                    busy: _settingsBusy,
                    // 弹层自带拖拽条，不再重复面板标题。
                    showHeader: false,
                    onSaveGoal: (text) => _runSetting(
                      () => ref
                          .read(groupSettingsUseCaseProvider)
                          .saveGoal(widget.groupId, text),
                      onChanged: setSheetState,
                    ),
                    onToggleGoalGate: (enabled) => _runSetting(
                      () => ref
                          .read(groupSettingsUseCaseProvider)
                          .toggleGoalGate(widget.groupId, enabled),
                      onChanged: setSheetState,
                    ),
                    onSaveMaxAutoTurns: (turns) => _runSetting(
                      () => ref
                          .read(groupSettingsUseCaseProvider)
                          .saveMaxAutoTurns(widget.groupId, turns),
                      onChanged: setSheetState,
                    ),
                    onToggleFollowUpSuggest: (enabled) => _runSetting(
                      () => ref
                          .read(groupSettingsUseCaseProvider)
                          .toggleFollowUpSuggest(widget.groupId, enabled),
                      onChanged: setSheetState,
                    ),
                    onToggleHabitSuggest: (enabled) => _runSetting(
                      () => ref
                          .read(groupSettingsUseCaseProvider)
                          .toggleHabitSuggest(widget.groupId, enabled),
                      onChanged: setSheetState,
                    ),
                    onSaveTts:
                        ({
                          enabled,
                          narrateThinking,
                          narrationMode,
                          fileSummary,
                        }) => _runSetting(
                          () => ref
                              .read(groupSettingsUseCaseProvider)
                              .saveTts(
                                widget.groupId,
                                enabled: enabled,
                                narrateThinking: narrateThinking,
                                narrationMode: narrationMode,
                                fileSummary: fileSummary,
                              ),
                          onChanged: setSheetState,
                        ),
                  ),
                ),
                const Divider(height: 1),
                // 「自动续跑」section。
                //
                // ## 为什么放在设置弹层里而不是单独一个 AppBar 入口
                //
                // 它是**当前对话的配置类信息**（「它接下来还要自己跑几次、
                // 怎么叫停」），与设置同属「调整这个对话」的语境；且 AppBar
                // 已有 6 个入口，再加会挤压标题（AGENTS.md §6.10）。
                //
                // ## 为什么用同一份 State 而不开新路由
                //
                // 同 `_openSettings` 的理由：新路由会得到另一个 `_ChatPage`
                // 实例，`_settingsBusy` 不共享，两处写操作会互相覆盖。
                Expanded(
                  flex: 2,
                  child: AutoSchedulesPanel(
                    // 列表是独立端点，与 `_group` 快照不同源。用例内部会先取
                    // `activeSession.agentId`，再本地按 group 过滤（见其类文档）。
                    load: () => ref
                        .read(autoSchedulesUseCaseProvider)
                        .load(widget.groupId),
                    onStopAll: () async =>
                        (await ref
                                .read(autoSchedulesUseCaseProvider)
                                .stopAll(widget.groupId))
                            .items,
                    // 弹层自带拖拽条，且本 section 上方已有分割线，不重复标题。
                    showHeader: false,
                    // 切对话时重拉（Flutter 会复用面板 State）。
                    reloadToken: widget.groupId,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 执行一个设置写操作：成功后用返回的权威 group 覆盖本地。
  ///
  /// [onChanged] 是弹层自己的 setState（弹层不在本 State 的 build 子树里，
  /// 外层 setState 不会重建它）。
  Future<void> _runSetting(
    Future<ChatGroup> Function() action, {
    StateSetter? onChanged,
  }) async {
    if (_settingsBusy) return;
    setState(() => _settingsBusy = true);
    onChanged?.call(() {});
    try {
      final updated = await action();
      if (mounted) setState(() => _group = updated);
    } on GroupSettingsFailure catch (e) {
      _showSettingsError(e.message);
    } on SpbError catch (e) {
      // 纵深防御：[GroupSettingsUseCase] 已把 SpbError 翻成
      // [GroupSettingsFailure]，漏到这里说明翻译层自己出了问题。
      SpbLog.warn('设置失败（未经翻译）', {'error': e.toString()});
      _showSettingsError('设置失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
      onChanged?.call(() {});
    }
  }

  void _showSettingsError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ==================== 任务清单 ====================

  /// 当前 goal 快照（无 goal 或 `current_goal` 缺失时为空快照）。
  ///
  /// 与桌面端逐字同构：快照来自 `_group.currentGoal`（首次由
  /// `GET /chat/groups/:id` 填充，此后由 `goal_updated` SSE 覆盖），
  /// 不另发 HTTP。
  GoalSnapshot get _goalSnapshot =>
      GoalSnapshot.fromJson(_group?.currentGoal ?? const {});

  /// 当前 goal 的行 id（任务端点的路径参数）。无 goal 时为空串。
  String get _goalId => _goalSnapshot.goal?.id ?? '';

  /// 打开任务清单底部弹层。
  ///
  /// 同 [_openSettings]：用弹层而非新路由，共享同一份 State（`_group` /
  /// `_settingsBusy`），否则写成功后回写的是另一个 `_ChatPage` 实例。
  Future<void> _openGoalTasks() async {
    if (_group == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.8,
            child: GoalTasksPanel(
              snapshot: _goalSnapshot,
              // 移动端当前**不**消费 gate 决策（没有诊断 tab/面板）。
              // 传空列表而不是新接一条订阅：本任务只加任务清单，接诊断是
              // 另一个能力（桌面端已从 `controller.gateDecisions` 订阅）。
              // 面板在列表为空时整块不渲染，故这里不产生空壳。
              busy: _settingsBusy,
              // 弹层自带拖拽条，不再重复面板标题。
              showHeader: false,
              reloadToken: widget.groupId,
              onReload: () => _runGoalWrite(null, onChanged: setSheetState),
              onSetStatus: (taskId, status) => _runGoalWrite(
                () => ref
                    .read(goalApiProvider)
                    .setTaskStatus(_goalId, taskId, status),
                onChanged: setSheetState,
              ),
              onCreate: ({required title, description}) => _runGoalWrite(
                () => ref
                    .read(goalApiProvider)
                    .createTask(
                      _goalId,
                      title: title,
                      description: description,
                      // 与桌面端同一取舍：必须显式 manual，否则人工新增的任务会
                      // 在下次 LLM 展开时被当作可覆盖项删掉。
                      origin: GoalTaskOrigin.manual,
                    ),
                onChanged: setSheetState,
              ),
              // 编辑任务标题/描述。
              //
              // ⚠️ 服务端语义：`''` = 清除、`null` = 不改。面板已把输入框的
              // 当前值（含空串）显式传下来，故这里不能再转回 null。
              onUpdateTask: (taskId, {title, description}) => _runGoalWrite(
                () => ref
                    .read(goalApiProvider)
                    .updateTask(
                      _goalId,
                      taskId,
                      title: title,
                      description: description,
                    ),
                onChanged: setSheetState,
              ),
              onDelete: (taskId) => _runGoalWrite(
                () => ref.read(goalApiProvider).deleteTask(_goalId, taskId),
                onChanged: setSheetState,
              ),
              onReorder: (taskIds) => _runGoalWrite(
                () => ref.read(goalApiProvider).reorderTasks(_goalId, taskIds),
                onChanged: setSheetState,
              ),
              onResetForExpand: () => _runGoalWrite(
                () => ref.read(goalApiProvider).resetForExpand(_goalId),
                onChanged: setSheetState,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// AppBar 的操作按钮。
  ///
  /// ## 为什么按宽度分两套（issue #31）
  ///
  /// 移动端 AppBar 曾经塞了 7 个常驻元素（AgentSwitcher + 5 个 IconButton +
  /// 连接指示器），合计约 366dp，在常见手机宽度下**溢出**：360dp 达 66px、
  /// 390dp 36px、412dp 14px（实测，见 issue #31）。
  ///
  /// 溢出后右侧图标被黄黑条覆盖/裁切，用户点不到。且本机无 `DISPLAY`
  /// （AGENTS.md §9），此前的 widget test 用默认 800dp 窗口，掩盖了它。
  ///
  /// ## 分档依据：频率与是否需要一眼可见
  ///
  /// | 入口 | 窄屏 | 宽屏 | 理由 |
  /// |---|---|---|---|
  /// | AgentSwitcher | 常驻 | 常驻 | 「这段对话由谁回答」是全局属性，随时要切 |
  /// | 交付物 / 待办 | 常驻 | 常驻 | **带徽标**，回答「现在有什么在等我」，必须一眼可见 |
  /// | 对话设置 / 任务清单 / 目标历史 | 收进菜单 | 独立图标 | 低频弹层，多一步不痛 |
  /// | 对话内搜索 | 收进菜单 | 独立图标 | 同上（宽屏由页面的 `enableSearch` 摆出） |
  ///
  /// ## 阈值为什么是 `SpbBreakpoints.compact`（720dp）
  ///
  /// 而不是「刚好放得下」的实测值（440dp 左右）：后者是**内容相关的**
  /// ——AgentSwitcher 的宽度随 agent 名字变化（实测 94.3dp，上限 140dp+），
  /// 按「刚好」设阈值会在换个长名字的 agent 后又溢出。720dp 以下一律是
  /// 单栏窄屏，是这类取舍的天然分界。
  ///
  /// 副作用（**有意**）：既有 widget test 用默认 800dp 窗口，落在「宽屏」档，
  /// 故它们的交互路径完全不变（仍可直接 `find` 那些 `ValueKey`）。
  ///
  /// ## 溢出菜单为什么交给 `ConversationPage` 渲染
  ///
  /// 因为「在本对话中搜索」需要页面的 `ScrollController` 与 `_items`
  /// （命中后要滚回时间线），那是页面私有 State。故页面提供一个
  /// `overflowItems` 插槽，本端把三个低频入口与搜索开关一起交给它。
  List<Widget> _appBarActions() {
    final narrow = SpbBreakpoints.isCompact(MediaQuery.sizeOf(context).width);
    return [
      // Agent 切换：
      //
      // 放在 AppBar 而非底部弹层里：它是「这段对话由谁回答」的全局属性，
      // 用户在对话过程中随时可能要换，不该先开设置弹层再切。
      //
      // `_group` 未就绪时 `currentAgentId` 为 null，入口会显示「未绑定」——
      // 这与真实状态（尚未拉取）不符，但切换本身仍可用（服务端以 agentId
      // 为准），且比隐藏入口让用户以为「本端不支持切 agent」要好。
      AgentSwitcher(
        loadAgents: ref.watch(loadAgentsProvider),
        switchAgent: (agentId, {forceNewSession = false}) =>
            _switchAgent(agentId, forceNewSession: forceNewSession),
        currentAgentId: _group?.activeSession?.agentId,
        busy: _switchingAgent,
        // 极窄屏（< 360dp）只显示图标：名字最多占 140dp，配上三个常驻图标
        // 在 320dp 下仍会溢出 10px（issue #31）。名字在菜单的勾选项里可见，
        // 故省它不丢信息。
        compact: MediaQuery.sizeOf(context).width < 360,
      ),
      // 交付物入口（按对话浏览本次产出的文件）。
      //
      // ## 为什么与设置/任务分开
      //
      // 它是**只读浏览 + 下载**，而设置弹层是表单、任务弹层是可编辑列表。
      // 混在一起会让弹层变成多套交互的堆叠，且交付物的刷新（`agent.file.*`
      // 事件）会与表单草稿编辑互相干扰。
      //
      // ## 为什么徽标是「本对话已出现的 agent 文件数」而不是权威文件数
      //
      // 权威值要跑一轮 UFS 分页（生产实测单 group 可达数千条），而 AppBar
      // 在首帧就要渲染。徽标只回答「这个对话有没有产出」这个粗粒度问题，
      // 精确计数在弹层里（面板工具条）。取不到时（未就绪 / 事件未到）
      // 不显示徽标，不谎报 0。
      //
      // 与「任务清单」不同，本入口**不要求** `_group` 就绪：交付物取数只用
      // `widget.groupId`（URL 里已有），group 拉取失败不该连带屏蔽它。
      IconButton(
        key: const ValueKey('open-group-deliverables'),
        icon: Badge.count(
          count: _agentFileCount,
          isLabelVisible: _agentFileCount > 0,
          child: const Icon(Icons.folder_outlined),
        ),
        tooltip: '交付物',
        onPressed: _openDeliverables,
      ),
      // 待办入口（跨轮次聚合未解决确认卡）。
      //
      // ## 为什么与交付物分开
      //
      // 交付物回答「这个对话产出了什么」（只读浏览），待办回答「现在有什么
      // 在等我」（可作答）。两者数据源不同（UFS 远端 vs 时间线归约），且
      // 待办需要 busy 态与写端点，合成一个弹层会让两套交互堆叠。
      //
      // ## 徽标是「未解决确认卡数」
      //
      // 它就是弹层里列表的长度，可直接从归约结果算，无需额外请求。为 0 时
      // 不显示徽标（`isLabelVisible`）——显示一个恒为 0 的徽标会让用户以为
      // 功能坏了。
      //
      // 与交付物同理，**不要求** `_group` 就绪：确认卡来自时间线归约，
      // 与 group 快照无关。
      IconButton(
        key: const ValueKey('open-group-todos'),
        icon: Badge.count(
          count: _pendingConfirmationCount,
          isLabelVisible: _pendingConfirmationCount > 0,
          child: const Icon(Icons.pending_actions_outlined),
        ),
        tooltip: '待办',
        onPressed: _openTodos,
      ),
      // 宽屏：低频入口直接摆出来（与既有行为一致，测试路径不变）。
      if (!narrow) ...[
        IconButton(
          key: const ValueKey('open-group-settings'),
          icon: const Icon(Icons.tune),
          tooltip: '对话设置',
          onPressed: _group == null ? null : _openSettings,
        ),
        IconButton(
          key: const ValueKey('open-goal-tasks'),
          icon: const Icon(Icons.checklist_outlined),
          tooltip: '任务清单',
          onPressed: _group == null ? null : _openGoalTasks,
        ),
        IconButton(
          key: const ValueKey('open-goal-history'),
          icon: const Icon(Icons.history),
          tooltip: '目标历史',
          onPressed: _group == null ? null : _openGoalHistory,
        ),
      ],
    ];
  }

  /// 窄屏溢出菜单的条目（宽屏返回 null）。
  ///
  /// 宽屏的「对话设置 / 任务清单 / 目标历史」由 [_appBarActions] 摆成独立
  /// 图标，故这里不重复给条目；「对话内搜索」则由页面的独立图标提供
  /// （`enableSearch`，见 build）。
  List<ConversationOverflowItem>? _overflowItems() {
    final narrow = SpbBreakpoints.isCompact(MediaQuery.sizeOf(context).width);
    if (!narrow) return null;
    final groupReady = _group != null;
    return [
      ConversationOverflowItem(
        key: const ValueKey('menu-group-settings'),
        icon: Icons.tune,
        label: '对话设置',
        onTap: groupReady ? _openSettings : null,
      ),
      ConversationOverflowItem(
        key: const ValueKey('menu-goal-tasks'),
        icon: Icons.checklist_outlined,
        label: '任务清单',
        onTap: groupReady ? _openGoalTasks : null,
      ),
      ConversationOverflowItem(
        key: const ValueKey('menu-goal-history'),
        icon: Icons.history,
        label: '目标历史',
        onTap: groupReady ? _openGoalHistory : null,
      ),
    ];
  }

  /// 打开目标版本历史底部弹层。
  ///
  /// 同 [_openGoalTasks]：用弹层而非新路由，共享同一份 State（`_group` /
  /// `_settingsBusy`），否则写成功后回写的是另一个 `_ChatPage` 实例。
  Future<void> _openGoalHistory() async {
    if (_group == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.8,
            child: GoalHistoryPanel(
              // 历史列表是独立端点，与 `_group.currentGoal` 快照不同源。
              load: () => ref.read(goalApiProvider).listGoals(widget.groupId),
              currentGoalId: _goalId.isEmpty ? null : _goalId,
              busy: _settingsBusy,
              // 弹层自带拖拽条，不再重复面板标题。
              showHeader: false,
              reloadToken: widget.groupId,
              // ⚠️ requireGoal: false —— 切回必须允许「当前无目标」：那正是它
              // 存在的场景（用户清除了目标后，历史面板是唯一恢复入口）。
              // 若也拦 `_goalId` 为空，就形成「有历史但回不去」的死局。
              onSwitch: (goalId) => _runGoalWrite(
                () => ref
                    .read(goalApiProvider)
                    .switchGoal(widget.groupId, goalId),
                requireGoal: false,
                onChanged: setSheetState,
              ),
              onSetStatus: (goalId, status) => _runGoalWrite(
                () =>
                    ref.read(goalApiProvider).updateGoalStatus(goalId, status),
                requireGoal: false,
                onChanged: setSheetState,
              ),
              // 新建目标（issue #17）。`requireGoal: false`：正是**没有**当前
              // 目标时才最需要它。
              //
              // `tasksSource: manual` 必须显式传：它决定重新展开时能否覆盖
              // 任务清单，`manual` = 人工创建，LLM 展开不会覆盖。
              onCreate: (goalText) => _runGoalWrite(
                () => ref
                    .read(goalApiProvider)
                    .createGoal(
                      widget.groupId,
                      goalText: goalText,
                      tasksSource: GoalTasksSource.manual,
                    ),
                requireGoal: false,
                onChanged: setSheetState,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 执行一个任务写操作（`action` 为 null 时只重拉）。
  ///
  /// 与桌面端 `_runGoalWrite` 同一取舍：写端点响应形状各异（`{task,progress}`
  /// / `{items}` / `{deleted}` / 被删保留清单），逐个写本地归一化会与
  /// `goal_updated` 事件路径产生两套真相，故统一 write → re-read。
  Future<void> _runGoalWrite(
    Future<void> Function()? action, {
    bool requireGoal = true,
    StateSetter? onChanged,
  }) async {
    if (_settingsBusy) return;
    if (requireGoal && _goalId.isEmpty) {
      _showSettingsError('当前对话没有目标，无法操作任务');
      return;
    }
    setState(() => _settingsBusy = true);
    onChanged?.call(() {});
    try {
      if (action != null) await action();
      await _loadGroup();
    } on SpbError catch (e) {
      SpbLog.warn('任务操作失败', {
        'groupId': widget.groupId,
        'goalId': _goalId,
        'error': e.toString(),
      });
      _showSettingsError(_describeGoalError(e));
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
      onChanged?.call(() {});
    }
  }

  /// 把任务写操作的错误翻成用户能看懂的一句话（与桌面端同一取舍）。
  String _describeGoalError(SpbError e) {
    if (e is HttpError) {
      return switch (e.statusCode) {
        404 => '任务或目标不存在（可能已被删除），已刷新列表',
        409 => '任务编号已存在，请换一个标题后重试',
        400 => '请求被拒绝：${e.message}',
        _ => '操作失败（HTTP ${e.statusCode}），请稍后重试',
      };
    }
    if (e is AuthError) return '登录已失效，请重新登录';
    return '操作失败，请稍后重试';
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
    // 交付物刷新令牌的基线：切对话时清空「见过的文件 id」，否则上一个对话里
    // 见过的文件会把新对话的文件当成「旧文件」而不触发刷新。
    _seenFileItemIds.clear();
    // 同理重置确认卡基线（见该字段文档：null = 从未同步）。
    _seenConfirmationIds = null;
    if (_itemsSub == null) {
      // 只订阅一次（controller 是 user 级单例，切 group 复用同一实例）。
      // 立即同步一次当前快照，避免错过订阅前已存在的文件。
      _itemsSub = controller.items.listen(_onItemsChanged);
      _onItemsChanged(controller.snapshot);
    }
    if (_activitiesSub == null) {
      // 执行中活动快照走独立流（见领域层 TurnActivitySnapshot 类文档）。
      // 先订阅再同步一次快照，避免错过订阅前已到达的事件。
      _activitiesSub = controller.activities.listen(_onActivitiesChanged);
      _onActivitiesChanged(controller.activitiesSnapshot);
    }
    if (_contextUsageSub == null) {
      // 上下文用量走独立流（见领域层 ContextUsage 类文档）。与 activities 同取向：
      // 先订阅再同步一次快照，避免错过订阅前已到达的事件。
      _contextUsageSub = controller.contextUsage.listen(_onContextUsageChanged);
      _onContextUsageChanged(controller.contextUsageSnapshot);
    }
    if (_executionStatusSub == null) {
      // 等待/重试状态走独立流（见 ExecutionStatus 类文档）。
      _executionStatusSub = controller.executionStatus.listen(
        _onExecutionStatusChanged,
      );
      _onExecutionStatusChanged(controller.executionStatusSnapshot);
    }
    if (_ttsStatusSub == null) {
      // 语音播报状态走独立流（见 TtsStatus 类文档）。
      _ttsStatusSub = controller.ttsStatus.listen(_onTtsStatusChanged);
      _onTtsStatusChanged(controller.ttsStatusSnapshot);
      if (_staleTurnIdsSub == null) {
        // 超时兜底集合走独立流（见 ChatStreamController.staleTurnIds）。
        // 与 activities 同取向：先订阅再同步一次快照。
        _staleTurnIdsSub = controller.staleTurnIds.listen(
          _onStaleTurnIdsChanged,
        );
        _onStaleTurnIdsChanged(controller.staleTurnIdsSnapshot);
      }
    }
    // 目标变更通知走独立流（见 GoalUpdate 类文档）。
    //
    // ⚠️ 该事件在服务端漏设 Transient（见 GoalUpdate 的类文档），
    // 控制器已按事件类型把它挡在游标推进之外——此处只消费快照。
    _goalUpdatesSub ??= controller.goalUpdates.listen(_onGoalUpdated);
    // group 变更通知走独立流。本页只处理 metadata 分支（见 _onGroupMetadataChanged）。
    _groupUpdatesSub ??= controller.groupUpdates.listen(
      _onGroupMetadataChanged,
    );
    if (_connectedUserId == userId || controller.isConnected) {
      // 同一 userId 内切 group：复用已有连接（不调 connect，游标保留）。
      await controller.switchGroup(widget.groupId);
      _connectedUserId = userId;
    } else {
      // 首次聚焦：建立 SSE 连接。
      await controller.start(groupId: widget.groupId);
      _connectedUserId = userId;
    }
  }

  /// 监听 controller.staleTurnIds：驱动对话页的超时兜底提示。
  ///
  /// 集合通常只有 0 或 1 个元素（同一 group 的 turn 串行执行）。
  void _onStaleTurnIdsChanged(Set<String> ids) {
    if (!mounted) return;
    setState(() => _staleTurnIds = ids);
  }

  /// 监听 controller.activities：驱动对话页的空窗期进度指示。
  void _onActivitiesChanged(Map<String, TurnActivitySnapshot> activities) {
    if (!mounted) return;
    setState(() => _activities = activities);
  }

  /// 监听 controller.contextUsage：驱动对话页顶部的用量读数。
  ///
  /// 快照可为 null（尚无数据），直接存下即可——页面按 `hasData` 决定是否渲染。
  void _onContextUsageChanged(ContextUsage? usage) {
    if (!mounted) return;
    setState(() => _contextUsage = usage);
  }

  /// 监听 controller.items：出现新的 agent 文件时 bump 交付物刷新令牌。
  ///
  /// ## 为什么只 bump 令牌，不直接调 provider
  ///
  /// 弹层可能未打开（`groupDeliverablesProvider` 是 autoDispose，无人监听时
  /// 本就不该取数）。bump 令牌是无副作用的；打开弹层后首帧会拉到最新。
  void _onItemsChanged(List<ConversationItem> items) {
    final ids = <String>{};
    for (final item in items) {
      if (item is AgentFileItem && !item.isDeleted) {
        final id = item.ufsFileId;
        if (id != null && id.isNotEmpty) ids.add(id);
      }
    }
    // 首次建立基线：不 bump（避免刚打开页面就多拉一次——首帧本就要拉）。
    final isFirstSync = _seenFileItemIds.isEmpty;
    final hasNew = ids.difference(_seenFileItemIds).isNotEmpty;
    _seenFileItemIds
      ..clear()
      ..addAll(ids);

    // 新确认卡到达时发 OS 通知（issue #21）。理由同桌面端：副作用、与
    // setState 无关，且页面已卸载时**更需要**通知。
    unawaited(ref.read(confirmationNotifierProvider).handleItems(items));

    if (!mounted) return;
    setState(() {
      _items = items;
      if (!isFirstSync && hasNew) _deliverablesReloadToken++;
    });

    // ## 为什么要刷新待确认角标
    //
    // 确认卡事件（`confirmation_required` / `confirmation_resolved`）会进入
    // 归约结果，但对话列表页的角标读的是另一个 provider
    //（`pendingConfirmationCountProvider`）。不刷新的话，用户要等下次进入
    // 列表页或打开待确认页才能看到角标变化。
    //
    // ## 为什么 invalidate 被依赖者而不是 count
    //
    // count provider 是 `await ref.watch(pendingConfirmationsProvider.future)`
    // 的**派生值**。只 invalidate count 时，它重建后读到的仍是被缓存的
    // `pendingConfirmationsProvider` 结果——角标纹丝不动（本文件 :399 处那个
    // 失效调用就是这个根因）。刷新被依赖者则两条都生效：前者重拉，后者因
    // watch 依赖被自动重算。
    //
    // 首次建基线不刷新：对话列表页本就在拉，再刷一次是重复请求。
    final confIds = <String>{
      for (final item in items)
        if (item is ConfirmationItem) '${item.confirmationId}:${item.resolved}',
    };
    final baseline = _seenConfirmationIds;
    _seenConfirmationIds = confIds;
    if (baseline != null && !_setEquals(baseline, confIds)) {
      ref.invalidate(pendingConfirmationsProvider);
    }
  }

  /// 集合内容相等（`Set` 的 `==` 是**引用**相等，不能用）。
  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// 监听 controller.executionStatus：驱动对话页的等待/重试提示。
  void _onExecutionStatusChanged(ExecutionStatus? status) {
    if (!mounted) return;
    setState(() => _executionStatus = status);
  }

  /// 监听 controller.ttsStatus：驱动对话页的播报状态条。
  void _onTtsStatusChanged(TtsStatus? status) {
    if (!mounted) return;
    setState(() => _ttsStatus = status);
  }

  /// 监听 controller.goalUpdates：实时刷新本对话的目标快照。
  ///
  /// ## 为什么直接套快照而不重新拉 group
  ///
  /// 事件 payload 的 goal/tasks/progress 由与 `GET /goals/current` 完全
  /// 相同的 DTO 函数生成（Go `goalToDTO`/`taskToDTO`/`progressFromTasks`），
  /// 是服务端刻意的防漂移设计。重发 HTTP 只为拿已在手里的数据是白费一次
  /// 往返，且会打断设置面板里的草稿编辑。
  ///
  /// ## 三条守卫
  ///
  /// 1. **只处理本对话的变更**：SSE 是 user 级订阅，会收到别的 group 的
  ///    goal 变更（agent 可能在别处改任务）；套错会把本页目标改掉。
  /// 2. **_group 未就绪时忽略**：初始 `_loadGroup` 会拿到最新状态，此处
  ///    无事可做（也不能拿 null 去拼快照）。
  /// 3. **快照为 null 时忽略**：goal 字段缺失的异常载荷不得清空现有目标
  ///    （否则面板上的目标会凭空消失）。
  /// 监听 controller.groupUpdates：把 Goal Gate 自动停用的 metadata 套进 _group。
  ///
  /// ## 只处理 metadata 分支
  ///
  /// 本页不渲染 group 的标题/状态（那是列表页的事），`created`/`deleted`/
  /// `title` 等 op 对设置面板无影响，处理它们只会白费一次 setState。
  ///
  /// ## 三条守卫
  ///
  /// 1. **只处理本对话**：SSE 是 user 级订阅，会收到别的 group 的变更
  ///    （`groupUpdates` 刻意不过滤 group）。套错会把本页开关改掉。
  /// 2. **_group 未就绪时忽略**：初始 `_loadGroup` 会拿到最新 metadata。
  /// 3. **metadata 为 null 时忽略**：不得用空 map 覆盖现有值
  ///    （否则面板会显示假的「全部关闭」）。
  ///
  /// ## 为什么整体替换而不深合并
  ///
  /// payload 的 metadata 是**完整**的 `chat_groups.metadata`（Go
  /// `updateGroupMetadata` 返回整个 map）。服务端的删除语义是「把键移除」
  /// （关闭 tts 时整块删 `metadata.tts`），深合并会让「已关」的开关
  /// 继续显示为开。
  void _onGroupMetadataChanged(GroupUpdate update) {
    if (!mounted) return;
    final group = _group;
    if (group == null) return;
    // 判定逻辑在 GroupUpdate.applyTo（两端共用，见其文档）：
    // op 非 metadata / groupId 不匹配 / metadata 缺失时返回**原对象**，
    // 据此跳过无意义的 setState。
    final next = update.applyTo(group);
    if (identical(next, group)) return;
    setState(() => _group = next);
  }

  void _onGoalUpdated(GoalUpdate update) {
    if (!mounted) return;
    if (update.groupId != widget.groupId) return;
    final group = _group;
    if (group == null) return;
    final snapshot = update.snapshot;
    if (snapshot == null) return;
    setState(() => _group = group.withCurrentGoal(snapshot));
  }

  /// AppBar 标题：进入对话后显示**对话名**（[ChatGroup.title]）。
  ///
  /// 与桌面端逐字同构（见 `apps/spb_desktop/lib/router.dart` 的同名 getter）。
  /// 未就绪时退回「对话」：空标题会让 AppBar 只剩图标，且宽度变化会拖动
  /// 右侧 5 个常驻图标（窄屏本已紧张，见 issue #31）。
  String get _appBarTitle {
    final title = _group?.title.trim() ?? '';
    return title.isEmpty ? '对话' : title;
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
      title: _appBarTitle,
      // 对话内搜索（搜已加载的时间线，含 agent 回复）。
      //
      // ## 为什么按宽度给（issue #33）
      //
      // 窄屏：不摆图标，改由溢出菜单收纳（见下方 [_overflowItems]）。AppBar
      // 在窄屏本就溢出（issue #31），直接加图标会让溢出量从 66px 涨到 114px。
      //
      // 宽屏：摆独立图标。此前恒为 `false`，而 [_overflowItems] 在宽屏又返回
      // `null` —— 两个入口同时消失，搜索在 ≥720dp（平板/折叠屏展开/横屏手机）
      // **彻底不可达**。宽屏 AppBar 有 720dp 余量，多一个 48dp 图标不会溢出。
      enableSearch: !SpbBreakpoints.isCompact(MediaQuery.sizeOf(context).width),
      // 对话设置入口（目标 + 三个 CAS 开关）。
      //
      // 移动端没有侧边栏，故走 AppBar 按钮 → 底部弹层；桌面端同一份
      // [GroupSettingsPanel] 挂在侧边栏「设置」tab 上（见 desktop router）。
      //
      // 权威 group 未就绪时**禁用而非隐藏**：AppBar 宽度恒定，不会因加载完成
      // 而拖动其余图标（与停止按钮同一取舍）。
      //
      // ## 窄屏（issue #31）：低频率入口收进溢出菜单
      //
      // 7 个常驻元素合计约 366dp，在 ≤412dp 宽度下溢出（360dp 达 66px）。
      // 故窄屏把「对话设置 / 任务清单 / 目标历史」收进一个 PopupMenuButton
      // （净省 2 个图标的宽度 = 96dp），保留带徽标的交付物/待办与 AgentSwitcher
      // ——它们回答「现在有什么在等我」，需要一眼可见。
      //
      // 用 `SpbBreakpoints.isCompact`（< 720dp）作阈值而不是「刚好放得下」的
      // 实测值：720 以上是桌面端宽屏，也是既有测试窗口（默认 800dp）所在区间
      // ——后者让全部既有用例的交互路径**不变**（它们直接 find 那些 ValueKey）。
      actions: _appBarActions(),
      // 窄屏（issue #31）：三个低频入口收进溢出菜单。
      //
      // 宽屏返回 null，此时页面不渲染溢出菜单（入口以独立图标摆出，与既有
      // 行为一致，既有测试路径不变）。
      overflowItems: _overflowItems(),
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
      // 「立即发送」：把服务端缓冲区里 pending 的消息立即合并成 turn。
      // 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      onFlush: ref.read(flushMessagesProvider(widget.groupId)),
      onFlushWithStrategy: ref.read(flushWithStrategyProvider(widget.groupId)),
      // 执行中活动指示（turn_activity）：长 turn 的静默期给用户可见进展。
      // 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      activities: controller.activities,
      activitiesSnapshot: _activities,
      // 上下文用量（context_update）：贴时间线顶部的诊断读数。
      // 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      contextUsage: controller.contextUsage,
      contextUsageSnapshot: _contextUsage,
      // 等待/重试提示（queue_state / retry_scheduled）：与活动指示共用槽位。
      // 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      executionStatus: controller.executionStatus,
      executionStatusSnapshot: _executionStatus,
      // 语音播报状态（tts_*）：只做状态展示，不引入播放（AGENTS.md §11）。
      // 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      ttsStatus: controller.ttsStatus,
      ttsStatusSnapshot: _ttsStatus,
      // 超时兜底（长时间无进展）：停掉流式光标 + 提示条，但**不禁用**取消。
      // 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      staleTurnIds: controller.staleTurnIds,
      staleTurnIdsSnapshot: _staleTurnIds,
      // 离线写队列（issue #30）：断网时用户发的消息进「待发送」条而不是
      // 时间线——入队时还没有 turnId，而归约器按 turnId 去重，无 turnId 的
      // 本地项会在服务端 `user_message` 到达后渲染成两个气泡。
      //
      // 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
      outboxEntries: ref.watch(outboxQueueProvider).entries,
      outboxSnapshot: ref.watch(outboxQueueProvider).snapshot,
      onCancelOutbox: (id) => ref.read(outboxQueueProvider).cancel(id),
      onRetryOutbox: (id) => ref.read(outboxQueueProvider).retryNow(id),
      onRemoveOutbox: (id) => ref.read(outboxQueueProvider).remove(id),
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
      onReconnect: () =>
          ref.read(chatStreamControllerProvider(userId)).reconnect(),
      onDownloadAgentFile: (file) => _downloadAgentFile(file, userId),
      // 图片类交付物在时间线内联显示缩略图（与桌面端同源，走 `UfsApi.thumbnail`）。
      onLoadThumbnailAgentFile: (file) => _loadAgentFileThumbnail(file),
      // 文件预览（text / image / external 三类）。
      //
      // 与桌面端的**关键差异**：移动端能接 `openExternal`，但不能接
      // #6 的 `onOpenAgentFile` / `onRevealAgentFile`。两者不是同一件事：
      // - 打开/定位需要「本地副本 + 系统文件管理器」→ 移动端无此能力
      //   （`NoopDesktopCapabilities` 恒 false）；
      // - 预览是**应用内渲染**（text/image），external 走 `url_launcher`
      //   跳系统浏览器——两者都不需要桌面能力。
      //
      // 故「移动端完全不做文件能力」是错的：预览恰恰是移动端最该有的（屏幕
      // 小、下载后更不方便找）。
      onPreviewAgentFile: AgentFilePreviewCallbacks(
        loadBytes: _loadAgentFileBytes,
        openExternal: _openAgentFileExternal,
        // map spec 的地点行：跳高德。移动端本就是「跳出去打开」的语义，
        // 故这里与 `openExternal` 用同一个 `url_launcher` 入口。
        openMapMarker: _openMapMarker,
      ),
      // ⚠️ **有意不装配**打开/定位回调（issue #6）：
      //
      // 本端注入的是 `NoopDesktopCapabilities`（见 `providers.dart`），
      // `openFile` / `revealPath` 恒返回 false。接上会让用户点「打开」得到
      // 「无法打开文件」——比菜单项根本不出现更困惑（回调为 null 时
      // `AgentFileCard` 不渲染对应项）。
      //
      // 要真正支持需引入 `open_filex` / `share_plus` + Android FileProvider
      // 配置 + 真机验证（本机无 `/dev/kvm`，模拟器不可用），见 AGENTS.md §6.9.1。
      // 当前退化为「只读浏览 + 下载」。
      // 打开 Markdown 回复里的链接。失败只记日志（点不开不该打断阅读）。
      //
      // 用 `unawaited` 而非 `await`：回调签名是 void（发起即返回），
      // 且失败已在内部消化。
      onOpenLink: (url, _) {
        unawaited(
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
              .then((ok) {
                if (!ok) SpbLog.warn('打开链接返回 false', {'url': url});
              })
              .catchError((Object e) {
                SpbLog.warn('打开链接失败', {'url': url, 'error': '$e'});
              }),
        );
      },
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
      // 归属反馈：POST /chat/feedback/:token/resolve（可视化渠道直接解决，
      // 不经消息通道；一次性 CAS）。与桌面端 _resolveFeedback 同语义。
      //
      // ⚠️ **不吞异常**：回执没有「服务端稍后用事件收敛」的回路，失败就是失败，
      // 必须交给页面提示（页面在失败时保留可点，不把卡片变成只读）。此前这里
      // `.catchError(debugPrint)`，叠加请求体键名错误，就成了「点了没反应」。
      onResolveFeedback: (token, correct) =>
          api.resolveFeedback(token, correct: correct),
      // 习惯建议：接受/忽略/稍后。与桌面端逐字同构——端点是习惯域的
      // `/api/chat/habit-suggestions/:id/resolve`，**不走发消息通道**。
      //
      // 结果的权威呈现是 `habit_suggestion_resolved` 事件（服务端广播后归约器
      // 把卡片换成结果行），故这里不乐观更新本地状态。
      onAcceptHabit: (s) => ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.accept,
          )
          .catchError((Object e) {
            debugPrint('接受习惯建议失败: $e');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
      onEditAndAcceptHabit: (s, patch) => ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.editAndAccept,
            // patch 的字段集由服务端下发的 editable_fields 决定（见
            // HabitSuggestionEditor），这里原样透传，不做二次筛选。
            patternPatch: patch,
          )
          .catchError((Object e) {
            debugPrint('编辑并接受习惯建议失败: $e');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
      onDismissHabit: (s) => ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.dismiss,
          )
          .catchError((Object e) {
            debugPrint('忽略习惯建议失败: $e');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
      onSnoozeHabit: (s, option) => ref
          .read(habitApiProvider)
          .resolveSuggestion(
            s.suggestionId,
            action: HabitSuggestionAction.snooze,
            // `until` 返回 UTC RFC3339 无毫秒（服务端解析失败会静默回退冷却
            // 时长，不报错——格式错了用户只能发现「时间不对」）。
            snoozeUntil: option.until(DateTime.now()),
          )
          .catchError((Object e) {
            debugPrint('延后习惯建议失败: $e');
            return const HabitSuggestionResolveResult(resolved: false);
          }),
      // 建议卡选中的 agent 随消息透传；未选中时为 null（与默认路径等价）。
      // 之所以自建 onSend 而非用默认 controller.send：默认路径没有地方带 agentId。
      onSend: (text) => controller.send(input: text, agentId: _selectedAgentId),
      // 失败 turn 的重发：锁定原 group + 原 agent，`manual` 路由跳过归属判定。
      // 不传 requestId → 服务端新建 turn（沿用旧 id 会幂等命中那个已失败的 turn）。
      onRetryTurn: (text, agentId) => controller
          .send(
            input: text,
            groupId: widget.groupId,
            agentId: agentId ?? _selectedAgentId,
            routingMode: 'manual',
          )
          .then((_) => null),
      // spec 卡动作：copy_text 已由页面内部回填输入框（_draft 通道），
      // 这里只处理 send_next_input（直接发送）。
      onSpecAction: (action) {
        if (action.type == SpecUiActionType.sendNextInput &&
            action.nextInput.isNotEmpty) {
          unawaited(
            controller
                .send(input: action.nextInput, agentId: _selectedAgentId)
                .then((_) => null)
                .catchError((Object e) {
                  debugPrint('spec 动作发送失败: $e');
                  return null;
                }),
          );
        }
      },
      onSelectAgent: (agentId) => setState(() => _selectedAgentId = agentId),
    );
  }

  /// 下载 agent 文件产物到本地（复用桌面端的语义，详见桌面 router）。
  ///
  /// 布局同样是 `downloads/agent/{groupId}/<group 内相对路径>`——不同对话的
  /// 同名交付物不会互相覆盖。
  Future<void> _downloadAgentFile(AgentFileItem file, String userId) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return;
    final ufs = ref.read(ufsApiProvider);
    final res = await ufs.download(fileId);
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) return;
    final dir = await getApplicationSupportDirectory();
    final root = Directory(p.join(dir.path, 'downloads', 'agent'));
    final rel = agentFileDownloadRelPath(file, widget.groupId);
    final target = Directory(p.join(root.path, p.dirname(rel)));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    await File(p.join(root.path, rel)).writeAsBytes(res.bytes!, flush: true);
  }

  /// 拉取 agent 文件缩略图（仅图片类）。详见桌面端同名方法。
  Future<List<int>?> _loadAgentFileThumbnail(AgentFileItem file) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return null;
    return ref.read(ufsApiProvider).thumbnail(fileId);
  }

  /// 取文件**原始字节**供预览。与桌面端同名方法同源（不落盘、用原图非缩略图）。
  Future<List<int>?> _loadAgentFileBytes(AgentFileItem file) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return null;
    final res = await ref.read(ufsApiProvider).download(fileId);
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) return null;
    return res.bytes;
  }

  /// 在高德地图打开一个地点（map spec 的地点行，issue #12）。
  ///
  /// URL 拼接留在装配层（页面不掌握高德 URI 形状）；与
  /// `_openAgentFileExternal` 共用 `url_launcher`，只是目标域名不同。
  Future<bool> _openMapMarker(MapMarker marker) async {
    final url = Uri.parse(amapMarkerUrl(marker));
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      SpbLog.warn('打开高德地图失败', {'error': '$e'});
      return false;
    }
  }

  /// 在系统浏览器中打开 UFS 预览页（external 类）。
  ///
  /// 与桌面端的差异：移动端用 `url_launcher` 而非 `openInBrowser`
  /// （后者在 `spb_platform` 里只实现桌面三平台）。这与 `onOpenLink` 的
  /// 做法一致。
  ///
  /// URL 拼接同样留在装配层（页面不掌握 UFS 基地址与预览页路由）。
  Future<bool> _openAgentFileExternal(AgentFileItem file) async {
    final fileId = file.ufsFileId;
    if (fileId == null || fileId.isEmpty || file.isDeleted) return false;
    final url = Uri.parse(
      '${SpbEndpoints.current.ufsBaseUrl}/preview.html'
      '?file_id=${Uri.encodeQueryComponent(fileId)}',
    );
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      SpbLog.warn('打开 UFS 预览页失败', {'error': '$e'});
      return false;
    }
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
      onCreateWork: () async {
        final workId = await ref.read(createMiniappWorkProvider)();
        // `push` 的 Future 在**目标路由 pop 时**才完成，不是导航完成时——
        // 等它会把本回调挂到用户返回为止。故显式 unawaited。
        if (context.mounted) unawaited(context.push(SpbRoutes.work(workId)));
        return workId;
      },
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
      onUploadFile: ref.watch(uploadMiniappFileProvider(workId)),
    );
  }
}

/// 带附件的无归属输入窗。
///
/// ## 移动端为何也接入它
///
/// 移动端**没有**拖拽，但有系统文件选择器（`pickFilesForOverlay()` 走
/// `file_selector`，Android/iOS 均已实现），故「带附件提交」在手机上同样
/// 成立——而且手机上「拍照/选图再问」比桌面端更常见。
///
/// ## 为什么注入 `NoopDragDropCapability`
///
/// 不伪造拖拽能力：`desktop_drop` 在 Android/iOS 上不支持拖入，假装支持会
/// 让用户看到一个永远不触发的拖拽提示。空实现下页面**只少一个拖拽区**，
/// 「添加文件」按钮与附件列表完全照常（见 `OverlayQuickCapturePage` 的
/// `_pickFiles`）。
///
/// ## 为什么提交成功后不导航
///
/// enqueue 是异步投递（worker 消费后才建 turn），本页拿不到 groupId。
/// 与桌面端一致：结果由对话列表订阅 SSE 呈现。导航到「对话」列表让用户
/// 能立刻看到新对话出现。
class _OverlayQuickCapturePage extends ConsumerWidget {
  const _OverlayQuickCapturePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useCase = ref.watch(quickCaptureEnqueueUseCaseProvider);

    return OverlayQuickCapturePage(
      submit: ({required input, required attachments, onUploadProgress}) =>
          useCase.submit(
            input: input,
            attachments: attachments,
            onUploadProgress: onUploadProgress,
          ),
      dragDrop: ref.watch(dragDropCapabilityProvider),
      onClose: () {
        if (context.mounted) context.go(SpbRoutes.conversations);
      },
    );
  }
}
