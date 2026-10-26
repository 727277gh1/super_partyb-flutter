import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'group_management.dart';

/// 新建对话时使用的**默认占位标题**。
///
/// 建对话不需要用户输入标题（见 [GroupListPage.onCreateGroup] 的说明），
/// 故这里给一个固定占位，用户在对话设置里可随时改名。
///
/// 选「新对话」而非服务端的「新对话组」：后者是 `createGroup` 的**服务端**
/// 兜底文案，而这里是我们主动发的值——两端（本页与 webapp）展示的都是用户
/// 主动看到的那个词，保持一致即可。
const String defaultGroupTitle = '新对话';

/// 对话列表页（offset 分页）。
///
/// ## 分页约定：offset 而非游标
///
/// `GET /chat/groups` 用 `?limit=&offset=`（与 timeline 的
/// `before_global_seq` 游标**不同**——两套约定并存是既有事实，见 AGENTS.md §5.7）。
///
/// 用 offset 分页时「加载更多」必须**去重**：offset 分页在列表变动时会产生
/// 重复项（服务端在两次请求之间新增/删除对话会移动窗口）。故 [_loadMore] 按
/// [ChatGroup.id] 去重，否则 Flutter 的列表会出现重复 Key 崩溃。
///
/// ## 滚动触发加载
///
/// 不用「加载更多」按钮：桌面端滚到底是自然动作，加按钮反而多一步。
/// 用 [ScrollController] 监听接近底部时预加载（提前一屏），避免用户看到白屏等待。
class GroupListPage extends StatefulWidget {
  const GroupListPage({
    super.key,
    required this.api,
    this.onOpenGroup,
    this.onGroupAction,
    this.onSearch,
    this.onOpenWorks,
    this.onOpenHabits,
    this.onOpenQuickCapture,
    this.onOpenSettings,
    this.onCreateGroup,
    this.pendingConfirmationCount = 0,
    this.onOpenConfirmations,
    this.groupUpdates,
    this.cache,
    this.userId,
    this.onSaveSnapshot,
    this.onOpenSnapshotSite,
    this.pageSize = 30,
  });

  final ChatApi api;

  /// group 变更通知流（`group_updated`，Transient）。
  ///
  /// ## 为什么列表页需要它
  ///
  /// 列表原来只在挂载时拉一次、下拉时刷新，于是**别人建的对话不会出现**。
  /// 服务端已把建组/改名/归档/删除都广播成 `group_updated`，但那些入口大多
  /// 不经过本页：chatpipeline 静默建组、habit 建独立组、miniapp 建 work、
  /// 以及另一端（另一台设备）的任意操作。
  ///
  /// 为 null 时不订阅——保持本页在未注入时是**纯拉取列表**（同
  /// [onOpenGroup] 等可选参数的取向），也让页面单测不必造一条假流。
  final Stream<GroupUpdate>? groupUpdates;

  /// 点击某个对话时的回调。
  final void Function(ChatGroup group)? onOpenGroup;

  /// 新建对话：入参是标题，返回值是服务端创建的**权威** [ChatGroup]。
  ///
  /// 标题由本页给**默认占位**（[defaultGroupTitle]），用户不需要输入——点
  /// 「新建对话」即建即进，之后再在对话设置里改名。这是 webapp 的既有取向
  /// （`use-workbench-state.ts` 的 `createGroup(title?)` 也是可选的）。
  ///
  /// ## 为什么页面不自己调 `ChatApi.createGroup`
  ///
  /// 与 [onGroupAction] 同一理由：页面只收集意图，请求与错误翻译归调用方。
  /// 页面拿返回值做两件事——插到列表最前、交给 [onOpenGroup] 导航进该对话。
  ///
  /// 为 null 时**不展示**新建入口：入口存在但点了没反应，比没有入口更糟。
  final Future<ChatGroup> Function(String title)? onCreateGroup;

  /// 执行管理动作（改名/归档/取消归档/删除）。
  ///
  /// ## 为什么页面不自己调 `ChatApi`
  ///
  /// 本页只做**渲染与交互**（见 `chat.dart` 的分层说明）。动作的执行、错误
  /// 翻译、以及「删除后要不要跳走」这类决策都属于调用方。页面只负责：收集
  /// 用户意图（菜单 + 对话框）→ 交给回调 → 按返回的权威结果更新本地列表。
  ///
  /// 返回 [GroupActionRejected] 表示服务端明确拒绝（页面提示原因）；
  /// 抛出异常表示网络/解析失败（页面同样提示）。
  ///
  /// 为 null 时**不展示任何管理入口**（保持「只读列表」用法，如首页预览）。
  final Future<GroupActionResult> Function(ChatGroup group, GroupAction action)?
  onGroupAction;

  /// 打开搜索页。
  ///
  /// 为 null 时**不展示**搜索按钮——入口存在但点了没反应比没有入口更糟。
  /// 页面不做路由，由调用方决定跳转方式（同 [onOpenGroup]）。
  final VoidCallback? onSearch;

  /// 打开工作台（小程序 BFF 的工作列表）。
  ///
  /// 为 null 时**不展示**入口。**两端均已接线**（`apps/spb_desktop/lib/router.dart`
  /// 与 `apps/spb_mobile/lib/router.dart` 都传了 `onOpenWorks`）。
  final VoidCallback? onOpenWorks;

  /// 打开习惯管理页。
  ///
  /// 与 [onOpenWorks] 同为可选入口（不注入则不显示）：移动端与桌面端都支持
  /// 习惯，但测试与只读用法不需要它。
  final VoidCallback? onOpenHabits;

  /// 打开**无归属**快速输入入口（悬浮窗）。
  ///
  /// ## 为什么挂在列表页而不是移动端的标签栏外壳上
  ///
  /// 「没有对话 UI 的入口」在列表页是最自然的落点（没有聚焦的对话可发）。
  /// 若挂到 `_AppShell`，它会同时出现在「设置」标签上——在设置页弹一个
  /// 「发消息」按钮语义不成立。
  ///
  /// ## 为什么指向带附件的那条链路
  ///
  /// 目标路由是 `/overlay`（`POST /me/quick-capture/enqueue`）而非
  /// `/quick-capture`（同步、**无附件**）：附件只能在 enqueue 那条链路上落地
  /// （见 AGENTS.md §6.7）。纯文本场景两者等价，故不必再暴露一个功能更弱的入口。
  ///
  /// 为 null 时不展示（保持「只读列表」用法，与其余可选入口一致）。
  final VoidCallback? onOpenQuickCapture;

  /// 打开**全局设置页**（同步目录 / 范围 / 过滤 / 外观 / 个人偏好 / 诊断导出）。
  ///
  /// ## 为什么要在这里给入口
  ///
  /// 桌面端此前**没有任何** UI 入口能到 `/settings`：托盘只有「同步设置…」
  /// （直达 `/settings/sync`），列表 AppBar 只有新建/待确认/搜索/工作台/习惯。
  /// 于是同步目录、范围、媒体开关、本地清理、外观、个人偏好、导出诊断日志
  /// 这些配置**在界面上不可达**——只有深链能进（`WindowRole.settings` 的映射
  /// 存在，但生产代码里没有调用方）。
  ///
  /// ## 为什么挂在列表 AppBar 而不是托盘
  ///
  /// 「设置」是用户**主动找**的东西，位置应当符合平台惯例：桌面端各应用都把
  /// 它放在主界面标题栏（托盘菜单是辅助入口，不是主入口）。故托盘也补了一项
  /// 作为兜底，但主入口在这里。
  ///
  /// 为 null 时不展示（保持「只读列表」用法，与其余可选入口一致）。
  final VoidCallback? onOpenSettings;

  /// 跨 group 的待确认数量（角标）。> 0 时显示角标。
  final int pendingConfirmationCount;

  /// 打开待确认收件箱页。
  ///
  /// 为 null 时不展示入口（但 [pendingConfirmationCount] 仍可驱动角标）。
  final VoidCallback? onOpenConfirmations;

  /// 对话列表缓存（issue #26 切片 A）。
  ///
  /// ## 为什么是可选参数（而不是必需）
  ///
  /// 与 [groupUpdates] 等可选参数同一取向：为 null 时页面**既不写缓存也不回落**
  /// ——保持「纯拉取列表」的用法，也让页面单测不必造一个库。
  ///
  /// ## 为什么还需要 [userId]
  ///
  /// 缓存按用户隔离（见 `CachedGroups.userId` 的说明：换账号必须不串号）。
  /// 页面不解析身份（那是 `currentUserIdProvider` 的职责），故由调用方传入。
  /// 两者**同时**有效才启用缓存——只给 cache 不给 userId 时无法定位行，故同样
  /// 视为未启用（静默降级，不报错）。
  final GroupCacheStore? cache;

  /// 当前用户 id（缓存的行归属）。见 [cache]。
  final String? userId;

  /// 在系统浏览器中打开快照站点（staging / production）。
  ///
  /// ## 为什么是回调而不是页面拼 URL
  ///
  /// URL 拼接留在装配层：页面不掌握「服务部署在哪」这个知识（同
  /// `AgentFilePreviewCallbacks.openExternal` 的取向）。且 `access_url` 可能
  /// 是**相对路径**（后端未配置 `ARCHIVE_SNAPSHOT_SITE_BASE_URL` 时），
  /// 需要按当前 origin 补全——那是 app 层的端点知识。
  ///
  /// 返回 false = 未能发起（浏览器打不开、无 URL），页面据此给反馈。
  final Future<bool> Function(ArchiveSnapshot snapshot)? onOpenSnapshotSite;

  /// 保存快照下载的字节（文件名 + 内容）。
  ///
  /// ## 为什么是回调而不是页面自己写文件
  ///
  /// 落盘方式按平台不同（桌面端 `File.writeAsBytes`、移动端走分享面板或
  /// 系统文件选择器），且页面（`spb_features`）不依赖 `dart:io`——与
  /// `AgentFilePreviewCallbacks` 同一取向：IO 能力由装配层注入。
  ///
  /// ## 未注入时的降级
  ///
  /// 提示「已下载但未配置保存入口」，**不静默丢弃**——否则用户会以为点击
  /// 没生效，反复点。
  final Future<void> Function(String fileName, List<int> bytes)? onSaveSnapshot;

  final int pageSize;

  @override
  State<GroupListPage> createState() => _GroupListPageState();
}

class _GroupListPageState extends State<GroupListPage> {
  final _scrollController = ScrollController();
  final _groups = <ChatGroup>[];

  /// 已见过的 id，用于 offset 分页去重（见类文档）。
  final _seenIds = <String>{};

  bool _loading = false;
  bool _hasMore = true;
  SpbError? _error;

  /// 当前展示的内容来自**缓存**（而非网络）。
  ///
  /// ## 为什么需要它（而不是用 `_error != null` 判断）
  ///
  /// 回落成功时**不能**设 [_error]：那会让 [_buildBody] 渲染整页错误、盖掉刚拿到
  /// 的缓存内容。故「离线」与「出错」是两个独立状态，本字段只表示前者。
  bool _fromCache = false;

  /// 缓存写入时刻（陈旧提示用）。仅当 [_fromCache] 为 true 时有意义。
  DateTime? _cacheFetchedAt;

  /// 正在创建对话（避免重复提交）。
  ///
  /// 与 [_busyGroupId] 同理：创建是一次往返请求，期间再点一次 `+` 会建出两个
  /// 对话，而用户只会看到一个（第二个被导航覆盖）。这里把按钮禁用掉。
  bool _creating = false;

  /// 正在执行管理动作的 group id。
  ///
  /// ## 为什么需要它
  ///
  /// 改名/删除是**往返请求**。期间若用户再次点菜单，会发出第二个请求——
  /// 对删除尤其危险（第二次会得到 404 并提示「失败」，而实际第一次已成功，
  /// 用户会以为没删掉）。这里把对应条目的菜单禁用掉。
  String? _busyGroupId;

  /// [GroupListPage.groupUpdates] 的订阅。
  StreamSubscription<GroupUpdate>? _groupUpdatesSub;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _subscribeGroupUpdates();
    _loadMore();
  }

  @override
  void didUpdateWidget(GroupListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupUpdates != widget.groupUpdates) {
      unawaited(_groupUpdatesSub?.cancel());
      _groupUpdatesSub = null;
      _subscribeGroupUpdates();
    }
  }

  @override
  void dispose() {
    _groupUpdatesSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _subscribeGroupUpdates() {
    final stream = widget.groupUpdates;
    if (stream == null) return;
    _groupUpdatesSub = stream.listen(_onGroupUpdate);
  }

  /// 按 op 把一条变更反映到本地列表。
  ///
  /// ## 为什么是增量而不是「收到就整体重拉」
  ///
  /// group 变更频率极低，两种做法代价都可忽略；但增量不会打断用户的滚动位置
  /// 与已加载的多页数据（重拉只会回到第一页）。
  ///
  /// ## 与 webapp 的差异（有意）
  ///
  /// webapp 维护「活跃 / 已归档」两个分区，故 `archived` 是「转移分区」。
  /// 本页是**单一列表 + 已归档角标**（见 [_GroupTile]），故 `archived`/`active`
  /// 只改状态标记，条目留在原位。
  void _onGroupUpdate(GroupUpdate update) {
    if (!mounted) return;
    switch (update.op) {
      case GroupUpdateOp.created:
        // created 的快照刻意最小化（只有 id/title/status，没有时间戳与
        // active_session），插进列表会缺字段，故读回权威行。
        unawaited(_insertCreated(update));
      case GroupUpdateOp.deleted:
        var removed = false;
        setState(() {
          final index = _groups.indexWhere((g) => g.id == update.groupId);
          if (index >= 0) {
            _groups.removeAt(index);
            removed = true;
          }
          // 同时放开去重集合：否则该 id 之后若被服务端重新返回（如撤销删除后
          // 重建同名 id），会因「已见过」被静默丢弃，表现为列表少一项。
          // 与 [_handleAction] 的删除分支保持同一套判据。
          _seenIds.remove(update.groupId);
        });
        // 只在真的移除了一行时写缓存（issue #28）。未加载过的 group 不在
        // `_groups` 里，也就不在缓存里（缓存是 `_groups` 的整表投影），
        // 写一次是纯粹的无效写入。
        if (removed) unawaited(_saveCache());
      case GroupUpdateOp.archived:
        _patchLoaded(update, status: 'archived');
      case GroupUpdateOp.active:
        _patchLoaded(update, status: 'active');
      case GroupUpdateOp.title:
        _patchLoaded(update, title: update.title);
      case GroupUpdateOp.metadata:
        // 本页只渲染标题与状态（metadata 的开关在设置页/对话页编辑）。
        // 刻意不处理：重拉一次只为更新看不见的字段是白费一次往返。
        //
        // ⚠️ 这里的忽略**不影响**对话页的开关刷新：
        // `group_metadata_updated`（Goal Gate 自动停用）也归一为
        // [GroupUpdateOp.metadata]，但对话页自己订阅了 `controller.groupUpdates`
        // 并单独处理该分支（见 `_onGroupMetadataChanged`）。两个订阅者各取所需，
        // 互不依赖——本页看不到 metadata 是**设计如此**，不是缺口。
        break;
      case GroupUpdateOp.unknown:
        // 服务端新增了本客户端不认识的 op，无从增量应用。
        // 整体重拉是唯一安全兜底（见 [GroupUpdateOp.needsRefetch]）。
        unawaited(_refresh());
    }
  }

  /// 就地把已加载条目的字段改掉；条目不在当前已加载页里则忽略。
  ///
  /// 忽略是安全的：下次 [_loadMore] / 下拉刷新拉到的本就是最新行。
  /// 刻意**不**为「不在列表里」的 group 插一条——改名/归档不是「新出现」
  /// 的语义，凭空插入会让用户看到一个从未加载过的条目。
  void _patchLoaded(GroupUpdate update, {String? title, String? status}) {
    final index = _groups.indexWhere((g) => g.id == update.groupId);
    if (index < 0) return;
    setState(() {
      _groups[index] = _copyGroup(
        _groups[index],
        title: title,
        status: status,
        // 服务端在 PATCH/归档时也会推新 updated_at，用事件时间做近似
        // （快照里的 updated_at 没有进 GroupUpdate——见该类文档）。
        updatedAt: update.at,
      );
    });
    // 把变更镜像进缓存（issue #28）：否则「改名后断网重启」会看到旧标题。
    unawaited(_saveCache());
  }

  /// 处理 `op=created`：读回权威行后插到列表最前。
  ///
  /// 读回失败（网络抖动）时退化为用快照里的 title/status 造一条占位项——
  /// 「新建了但列表里没有」比「标题暂时不全」更糟。
  Future<void> _insertCreated(GroupUpdate update) async {
    if (_seenIds.contains(update.groupId)) return;

    ChatGroup? group;
    try {
      group = await widget.api.getGroup(update.groupId);
    } on SpbError catch (e) {
      SpbLog.warn('拉取新建的 group 失败，改用事件快照占位', {
        'groupId': update.groupId,
        'error': e.toString(),
      });
    }
    if (!mounted) return;

    final resolved = group ?? _placeholderFrom(update);
    if (resolved == null) return;
    setState(() {
      // 服务端按 updated_at 倒序，刚建的必然在最前（与 [_createGroup] 一致）。
      if (_seenIds.add(resolved.id)) _groups.insert(0, resolved);
    });
    // 把变更镜像进缓存（issue #28）：A 端建的对话，B 端断网重启后也要看得见。
    unawaited(_saveCache());
  }

  /// 用事件快照造一条占位 [ChatGroup]；连标题都没有时返回 null。
  ///
  /// 无标题的条目在列表里就是一个空白行，用户无法辨认——不如不插。
  static ChatGroup? _placeholderFrom(GroupUpdate update) {
    final title = update.title;
    if (title == null) return null;
    final at = update.at ?? DateTime.now();
    return ChatGroup(
      id: update.groupId,
      userId: '',
      title: title,
      status: update.status ?? 'active',
      createdAt: at,
      updatedAt: at,
    );
  }

  /// 复制一个 [ChatGroup] 并覆盖若干字段。
  ///
  /// [ChatGroup] 没有 `copyWith`，而它字段不多——在此就地展开比给模型层加一个
  /// 只有本页用的 API 更收敛（加在模型层会诱导其他页面各自拼装字段）。
  static ChatGroup _copyGroup(
    ChatGroup g, {
    String? title,
    String? status,
    DateTime? updatedAt,
  }) => ChatGroup(
    id: g.id,
    userId: g.userId,
    title: title ?? g.title,
    status: status ?? g.status,
    createdAt: g.createdAt,
    updatedAt: updatedAt ?? g.updatedAt,
    goal: g.goal,
    metadata: g.metadata,
    activeSession: g.activeSession,
    currentGoal: g.currentGoal,
  );

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 提前一屏触发：用户滚到底时数据已经在路上了。
    if (position.pixels >=
        position.maxScrollExtent - position.viewportDimension) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final page = await widget.api.listGroups(
        limit: widget.pageSize,
        offset: _groups.length,
      );
      if (!mounted) return;
      setState(() {
        // 去重后追加：offset 分页在列表变动时会重复返回同一项。
        for (final g in page) {
          if (_seenIds.add(g.id)) _groups.add(g);
        }
        // 返回数量不足一页即认为到底。
        //
        // 不用「返回空列表」判断：服务端可能因去重后恰好全被过滤而返回空，
        // 但后面还有数据——用「原始返回条数 < pageSize」更准确。
        _hasMore = page.length >= widget.pageSize;
        _loading = false;
        // 网络成功了，之前的「离线数据」提示必须消失（否则提示条永久残留）。
        _fromCache = false;
        _cacheFetchedAt = null;
      });
      unawaited(_saveCache());
    } on SpbError catch (e) {
      if (!mounted) return;

      // ── 首次加载失败时回落缓存（issue #26 切片 A）──────────────
      //
      // ## 为什么只在 `_groups.isEmpty` 时回落
      //
      // 已有数据时回落会**覆盖用户刚看到的内容**：典型场景是「加载更多」失败，
      // 回落会把整页缓存塞进来、丢掉当前滚动位置与已加载的后续页。
      //
      // ## 为什么回落成功时不设 _error
      //
      // 设了会让 _buildBody 渲染整页错误页，盖掉刚拿到的缓存内容——等于白回落。
      // 改为置 _fromCache，由 UI 渲染「离线数据」提示条（见 _CacheNotice）。
      if (_groups.isEmpty) {
        final cached = await _loadCache();
        if (!mounted) return;
        if (cached.isNotEmpty) {
          setState(() {
            _groups
              ..clear()
              ..addAll(cached);
            _seenIds
              ..clear()
              ..addAll(cached.map((g) => g.id));
            // 缓存里只有已拉过的部分，不能再自动加载更多（无游标可用，
            // 而且网络本来就是失败的）。
            _hasMore = false;
            _fromCache = true;
            _loading = false;
          });
          return;
        }
      }

      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 读缓存；未启用或为空时返回空列表（失败静默，见 `GroupCacheStore`）。
  Future<List<ChatGroup>> _loadCache() async {
    final cache = widget.cache;
    final userId = widget.userId;
    if (cache == null || userId == null || userId.isEmpty) return const [];
    final groups = await cache.load(userId);
    final at = await cache.lastFetchedAt(userId);
    if (mounted) _cacheFetchedAt = at;
    return groups;
  }

  /// 把当前列表写入缓存（**整表替换**语义，见 `GroupCacheStore.save`）。
  ///
  /// ## 为什么传整个 `_groups` 而不是刚拉到的那一页
  ///
  /// `save` 是整表替换（先删后插）。只传新页会把前面几页删掉——用户下次
  /// 断网就只能看到最后一页。故必须传累积后的完整列表。
  ///
  /// 缓存写失败不影响主流程（实现层已静默，见 `DriftGroupCacheStore.save`）。
  ///
  /// ## 为什么**不**跳过空列表（issue #28）
  ///
  /// 曾经这里有一道 `if (_groups.isEmpty) return;`，它是错的：
  ///
  /// 1. **删掉最后一个对话后缓存不更新**——用户下次断网重启，那个已删除的
  ///    对话仍在列表里（点进去 404）；
  /// 2. 与契约矛盾——`GroupCacheStore.save` 明确写「[groups] 为空时等价于清空
  ///    该用户缓存（合法：服务端确实一个对话都没有）」。
  ///
  /// 空列表是**合法状态**，不是「还没加载完」。真正的「还没加载完」由调用点
  /// 控制：本方法只在**网络成功**或**本地列表已变更**之后被调用，不会在加载
  /// 途中被调用（见 [_loadMore] / [_refresh]）。
  Future<void> _saveCache() async {
    final cache = widget.cache;
    final userId = widget.userId;
    if (cache == null || userId == null || userId.isEmpty) return;
    await cache.save(userId, List.of(_groups));
  }

  Future<void> _refresh() async {
    setState(() {
      _groups.clear();
      _seenIds.clear();
      _hasMore = true;
      _error = null;
      _fromCache = false;
      _cacheFetchedAt = null;
    });
    await _loadMore();
  }

  /// 用默认占位标题创建对话，成功后进入该对话。
  ///
  /// ## 为什么不弹「输入标题」对话框
  ///
  /// 建对话的**真实意图**是「开一个干净上下文继续聊」，不是「先起个名字」。
  /// 逼用户先想名字会让最常见的动作多一步，而名字随后还能在对话设置里改
  /// （`_RenameDialog`）。webapp 的 `createGroup(title?)` 也是这个取向。
  ///
  /// 标题用 [defaultGroupTitle]（`新对话`）：服务端在标题为空时会兜底成
  /// 「新对话组」，显式传同一个词能让两端列表里的占位一致。
  Future<void> _createGroup() async {
    final handler = widget.onCreateGroup;
    if (handler == null || _creating) return;

    setState(() => _creating = true);
    ChatGroup? created;
    try {
      created = await handler(defaultGroupTitle);
    } on SpbError catch (e) {
      // 网络/解析失败只提示、不崩溃（与 [_handleAction] 的容错策略一致）。
      //
      // 展示的是 `SpbError.message` 原文，**未经 app 层翻译**——与
      // [_handleAction] 不同：那条路径的错误文案由调用方通过
      // `GroupActionRejected(_describeGroupActionError(e))` 预先整理成人话，
      // 而本回调的签名（返回 [ChatGroup] / 抛错）没有承载文案的位置。
      // 对新建而言实际会出现的失败是网络中断与服务端 5xx，`message` 已足以定位；
      // 若将来需要与服务端错误体对齐文案，应统一两个 app 各自私有的
      // `_describeGroupActionError`，而不是在这里再分叉一份。
      if (mounted) _showMessage('创建失败：${e.message}', isError: true);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
    if (!mounted || created == null) return;

    // 插到列表最前：服务端按 updated_at 倒序，刚创建的必然在最前。
    // 经 _seenIds 登记，与 offset 分页去重保持同一套判据。
    setState(() {
      if (_seenIds.add(created!.id)) _groups.insert(0, created);
    });
    // 把变更镜像进缓存（issue #28）：新建后立刻断网重启，新对话必须还在。
    unawaited(_saveCache());

    // 导航交给调用方（页面不碰路由）。
    widget.onOpenGroup?.call(created);
  }

  /// 收集意图并交给调用方，然后按权威结果更新本地列表。
  Future<void> _handleAction(ChatGroup group, GroupAction action) async {
    final handler = widget.onGroupAction;
    if (handler == null || _busyGroupId != null) return;

    setState(() => _busyGroupId = group.id);
    GroupActionResult result;
    try {
      result = await handler(group, action);
    } on SpbError catch (e) {
      // 网络/解析失败：不是业务拒绝，但页面同样只提示、不崩溃。
      result = GroupActionRejected(e.message);
    } finally {
      if (mounted) setState(() => _busyGroupId = null);
    }
    if (!mounted) return;

    switch (result) {
      case GroupActionApplied(group: final updated):
        setState(() {
          final index = _groups.indexWhere((g) => g.id == group.id);
          if (index < 0) return;
          if (updated == null) {
            // 删除成功：从列表移除，并把 id 从去重集合里放开——
            // 否则若同名 id 之后又被服务端返回（理论上不该发生），会因
            // 「已见过」而被静默丢弃，表现为列表少一项。
            _groups.removeAt(index);
            _seenIds.remove(group.id);
          } else {
            // 改名/归档：换成服务端返回的权威对象，而不是本地拼一个。
            // 本地拼会漏掉服务端同时更新的 `updated_at` 等字段，表现为
            // 「列表时间没变，下拉刷新后才跳」。
            _groups[index] = updated;
          }
        });
        // 把变更镜像进缓存（issue #28）：改名/删除后断网重启必须看到新状态。
        unawaited(_saveCache());
      case SnapshotDownloaded(:final bytes, :final suggestedFileName):
        // 落盘是装配层的事（桌面端写文件系统、移动端走分享/保存），
        // 页面只把「拿到了这些字节」交出去。未注入时降级为提示——
        // 不静默丢弃，否则用户会以为点击没生效。
        final save = widget.onSaveSnapshot;
        if (save == null) {
          _showMessage('已下载 ${bytes.length} 字节，但未配置保存入口');
        } else {
          try {
            await save(suggestedFileName, bytes);
            _showMessage('已保存 $suggestedFileName');
          } on Object catch (e) {
            _showMessage('保存失败：$e', isError: true);
          }
        }
      case SnapshotSiteActionApplied(:final result):
        // pending / none 是 202 语义（动作已接受、结果稍后可见），不是失败。
        // 只有 ready 才说「成功」；其余提示「已提交，稍后刷新」。
        if (result.isReady) {
          _showMessage('站点已就绪');
        } else if (result.isPending) {
          _showMessage('站点正在渲染，稍后刷新查看');
        } else {
          _showMessage('站点已重置，稍后会自动重建');
        }
        // 站点状态由服务端异步推进，本地不猜转换——直接刷新列表。
        unawaited(_refreshAfterSiteAction());
      case GroupActionRejected(:final message):
        _showMessage(message, isError: true);
    }
  }

  /// 站点动作后刷新列表（状态从 pending → ready 是异步的）。
  ///
  /// 不在这里直接调 `api.listGroups`：页面已有 [_refresh] 承担「清空去重集合
  /// 并重拉首页」的职责，重复实现会让两处的缓存/分页逻辑漂移。
  ///
  /// ## 为什么用 [_refresh] 而不是只替换单个条目
  ///
  /// 站点状态是服务端 worker 异步推进的，`redeploy` 返回 pending 时列表里的
  /// `site.status` 仍是旧值；本地拼一个 pending 会在下一轮 worker 失败时
  /// 永远显示「渲染中」。重拉首页拿到的是服务端权威值。
  Future<void> _refreshAfterSiteAction() async {
    if (!mounted) return;
    await _refresh();
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? scheme.errorContainer : null,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('对话'),
        actions: [
          if (widget.onCreateGroup != null)
            IconButton(
              key: const ValueKey('group-list-create'),
              icon: const Icon(Icons.add),
              tooltip: '新建对话',
              // 创建往返期间禁用：否则连点会建出两个对话。
              onPressed: _creating ? null : _createGroup,
            ),
          if (widget.onOpenConfirmations != null)
            IconButton(
              key: const ValueKey('group-list-confirmations'),
              icon: Badge(
                isLabelVisible: widget.pendingConfirmationCount > 0,
                label: Text('${widget.pendingConfirmationCount}'),
                child: const Icon(Icons.pending_actions),
              ),
              tooltip: '待确认',
              onPressed: widget.onOpenConfirmations,
            ),
          if (widget.onSearch != null)
            IconButton(
              key: const ValueKey('group-list-search'),
              icon: const Icon(Icons.search),
              tooltip: '搜索消息',
              onPressed: widget.onSearch,
            ),
          if (widget.onOpenWorks != null)
            IconButton(
              key: const ValueKey('group-list-works'),
              icon: const Icon(Icons.work_outline),
              tooltip: '工作台',
              onPressed: widget.onOpenWorks,
            ),
          if (widget.onOpenHabits != null)
            IconButton(
              key: const ValueKey('group-list-habits'),
              icon: const Icon(Icons.repeat),
              tooltip: '习惯',
              onPressed: widget.onOpenHabits,
            ),
          // 全局设置放**最后**：它是低频入口，而前面几项都与「对话」这个
          // 当前任务直接相关。顺序也贴合平台惯例（设置在最右）。
          if (widget.onOpenSettings != null)
            IconButton(
              key: const ValueKey('group-list-settings'),
              icon: const Icon(Icons.settings_outlined),
              tooltip: '设置',
              onPressed: widget.onOpenSettings,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Column(
          children: [
            // 离线缓存提示条（issue #26 切片 A）。
            //
            // 放在列表**上方**而不是列表里：它描述的是「整个列表的来源」，
            // 不是某一条的属性；放在 itemBuilder 里会被滚动带出屏幕（用户
            // 滚到中间就看不见「这是缓存」了）。
            if (_fromCache)
              _CacheNotice(fetchedAt: _cacheFetchedAt, onRetry: _refresh),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      // 无归属快速输入入口（悬浮窗）。未注入时不展示——入口存在但点了没反应
      // 比没有入口更糟（同 [onOpenWorks] 的取向）。
      floatingActionButton: widget.onOpenQuickCapture == null
          ? null
          : FloatingActionButton(
              key: const ValueKey('group-list-quick-capture'),
              tooltip: '快速记录',
              onPressed: widget.onOpenQuickCapture,
              child: const Icon(Icons.bolt),
            ),
    );
  }

  Widget _buildBody() {
    // 首次加载：居中转圈。
    if (_groups.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // 首次加载失败：整页错误 + 重试。
    if (_groups.isEmpty && _error != null) {
      return ErrorState(message: _error!.message, onRetry: _loadMore);
    }

    if (_groups.isEmpty) {
      // 用 ListView 而非 Center：让 RefreshIndicator 在空列表上仍可下拉。
      //
      // ## 为什么空态要能下拉刷新
      //
      // 空列表的常见成因是「刚建完对话但列表还没刷出来」或「另一台设备上建的」。
      // 不能下拉的话用户只能杀进程重开。
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
          const EmptyState(message: '还没有对话', icon: Icons.chat_bubble_outline),
        ],
      );
    }

    return ScrollConfiguration(
      // 桌面端鼠标拖拽（同 conversation_page.dart）。
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: ListView.separated(
        controller: _scrollController,
        // RefreshIndicator 需要列表始终可滚动才能下拉（内容不足一屏时）。
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _groups.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == _groups.length) return _buildFooter();
          final group = _groups[index];
          return _GroupTile(
            key: ValueKey(group.id),
            group: group,
            onTap: widget.onOpenGroup == null
                ? null
                : () => widget.onOpenGroup!(group),
            // 动作进行中时禁用菜单，避免重复提交（见 _busyGroupId）。
            onAction: widget.onGroupAction == null || _busyGroupId != null
                ? null
                : (action) => _handleAction(group, action),
            onOpenSnapshotSite: widget.onOpenSnapshotSite,
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    if (_error != null) {
      // 加载更多失败：底部内联重试，不清空已有列表（用户仍能用已有数据）。
      return Padding(
        padding: SpbSpacing.pagePadding,
        child: Column(
          children: [
            Text(
              _error!.message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: SpbSpacing.sm),
            OutlinedButton(onPressed: _loadMore, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(SpbSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: SpbSpacing.pagePadding,
        child: Center(
          child: Text('没有更多了', style: Theme.of(context).textTheme.labelSmall),
        ),
      );
    }
    return const SizedBox(height: SpbSpacing.xxl);
  }
}

/// 离线缓存提示条（issue #26 切片 A）。
///
/// ## 为什么需要它（而不是直接展示缓存当无事发生）
///
/// 缓存可能是几小时前的快照：别人新建的对话不在里面、已删除的可能还在。
/// 用户不知道这一点时会以为「对话消失了」。提示条明确告知「这是离线数据」，
/// 并提供重试入口。
///
/// ## 为什么用 `MaterialBanner` 风格的内联条而不是 `SnackBar`
///
/// SnackBar 会**自动消失**（几秒后），而「当前看到的是缓存」是一个**持续成立**
/// 的事实，不是一次性通知。用内联条才能让它在整个离线期间可见。
///
/// ## 为什么不用 `ErrorBanner`
///
/// [ErrorBanner] 的语义是「出错了」（错误色）。而这里既不是错误也不是失败——
/// 数据是**有效**的，只是旧。用 `surfaceContainerHighest` + `onSurfaceVariant`
/// 传达「提示」而非「警告」，与真正的错误态区分开。
class _CacheNotice extends StatelessWidget {
  const _CacheNotice({required this.fetchedAt, this.onRetry});

  /// 缓存写入时刻；null 时退化为不带时间的文案。
  final DateTime? fetchedAt;

  final VoidCallback? onRetry;

  /// 把「多久之前」格式化成中文。
  ///
  /// 只做到「天」粒度：更细的分钟数对「这份缓存多旧」这个判断没有帮助，
  /// 反而会让文案频繁变化（每次 rebuild 都不一样）。
  String _ageText() {
    final at = fetchedAt;
    if (at == null) return '';
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final age = _ageText();
    return Material(
      key: const ValueKey('group-list-cache-notice'),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                // 文案不写「已中断」「加载失败」：网络错误不代表中断，只是
                // 这次没拉到。也不写「正在重试」——页面不会自动重试。
                age.isEmpty ? '离线数据' : '离线数据 · $age',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 单个对话条目。
///
/// ## 管理入口的触发方式：长按 + 右键
///
/// - **长按**：移动端唯一可行的方式（没有右键）；
/// - **右键**：桌面端自然的方式（`GestureDetector.onSecondaryTapDown`）。
///
/// 两者都打开同一个菜单。**不用**滑动（`Dismissible`）直接删：删除不可恢复，
/// 滑动太容易误触，且无法承载「改名/归档」这类同级动作。
class _GroupTile extends StatelessWidget {
  const _GroupTile({
    super.key,
    required this.group,
    this.onTap,
    this.onAction,
    this.onOpenSnapshotSite,
  });

  final ChatGroup group;
  final VoidCallback? onTap;

  /// 为 null 表示不提供管理入口（只读用法）。
  final void Function(GroupAction action)? onAction;

  /// 打开快照站点（浏览器）。为 null 时不渲染该入口。
  ///
  /// ## 为什么不用 GroupAction 通道
  ///
  /// 打开站点是**纯客户端动作**（拼 URL + 交给浏览器），不调服务端、不改状态。
  /// 塞进 `GroupAction` 会让 domain 层（`group_management.dart`）出现一个
  /// 打不通端点的分支，且 `GroupManagementUseCase.execute` 的 switch 必须为它
  /// 写一个「什么都不做」的 case——那是把装配层职责漏进领域层。
  final void Function(ArchiveSnapshot snapshot)? onOpenSnapshotSite;

  /// 当前 group 的快照（仅归档行有值，见 [ChatGroup.archiveSnapshot]）。
  ArchiveSnapshot? get _snapshot =>
      group.isArchived ? group.archiveSnapshot : null;

  /// 打开菜单并把用户选择交给 [onAction]。
  Future<void> _openMenu(BuildContext context, Offset position) async {
    final action = await showMenu<GroupAction>(
      context: context,
      // 右键时菜单出现在指针处；长按时出现在条目中心。
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          key: ValueKey('group-action-rename'),
          value: RenameGroup(''),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('重命名'),
          ),
        ),
        if (group.isArchived)
          const PopupMenuItem(
            key: ValueKey('group-action-unarchive'),
            value: UnarchiveGroup(),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.unarchive_outlined),
              title: Text('取消归档'),
            ),
          )
        else
          const PopupMenuItem(
            key: ValueKey('group-action-archive'),
            value: ArchiveGroup(),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.archive_outlined),
              title: Text('归档'),
            ),
          ),
        // 结项快照动作：只在「已归档且快照可用」时出现。
        //
        // ## 为什么拆成下载 / 重部署 / 发布三项而不是一个「结项记录」子菜单
        //
        // 三项的触发条件与风险都不同：下载要求 ready；重部署在 pending/failed
        // 时才有意义；发布是不可逆对外动作。子菜单会多一层点击，而这三项本身
        // 频率很低——直接列出更清楚。
        if (_snapshot != null) ...[
          const PopupMenuDivider(),
          if (_snapshot!.isReady && _snapshot!.downloadAvailable) ...[
            if (_snapshot!.links?.markdown != null)
              PopupMenuItem(
                key: const ValueKey('group-action-download-md'),
                value: DownloadSnapshot(_snapshot!.id, 'markdown'),
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.description_outlined),
                  title: Text('下载结项记录（Markdown）'),
                ),
              ),
            if (_snapshot!.links?.html != null)
              PopupMenuItem(
                key: const ValueKey('group-action-download-html'),
                value: DownloadSnapshot(_snapshot!.id, 'html'),
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.html_outlined),
                  title: Text('下载结项记录（HTML）'),
                ),
              ),
          ],
          // 重部署：pending 卡住 / failed / 站点被 UFS 重启重置时可用。
          // 不限制条件——ready 时重部署也是合法操作（改了站点源想重编译）。
          PopupMenuItem(
            key: const ValueKey('group-action-redeploy-site'),
            value: RedeploySnapshotSite(_snapshot!.id),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.refresh),
              title: Text('重新部署站点'),
            ),
          ),
          // 发布：只在 **staging** 且 ready 时出现。
          //
          // ## 判定依据：URL 里有没有 `/_staging/`
          //
          // group DTO 的 `site` 子对象**不含 environment**（Go
          // `archive_snapshot_dto.go` 只给 status/slug/access_url），故只能从
          // access_url 推断：staging 是 `{base}/_staging/ufs_sites/{slug}/`，
          // production 是 `{base}/ufs_sites/{slug}/`（见设计文档 §13）。
          //
          // 不用「不含 /ufs_sites/」判断——两者都含。也不要靠 `environment`
          // 字段：它不存在，读出来永远是 null，会让发布项永远显示。
          if (_snapshot!.site.isReady &&
              (_snapshot!.site.accessUrl?.contains('/_staging/') ?? false))
            PopupMenuItem(
              key: const ValueKey('group-action-publish-site'),
              value: PublishSnapshotSite(_snapshot!.id),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.publish_outlined),
                title: Text('公开发布站点'),
              ),
            ),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(
          key: ValueKey('group-action-delete'),
          value: DeleteGroup(),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline),
            title: Text('删除'),
          ),
        ),
      ],
    );
    if (action == null || !context.mounted) return;

    // 「重命名」的菜单项带的是空标题（菜单在打开前还不知道用户要输入什么），
    // 真正的新标题在这里收集。
    if (action is RenameGroup) {
      final title = await _promptRename(context);
      if (title == null) return;
      onAction?.call(RenameGroup(title));
      return;
    }

    // 删除不可恢复，必须确认。
    if (action is DeleteGroup) {
      final confirmed = await _confirmDelete(context);
      if (confirmed != true) return;
    }

    onAction?.call(action);
  }

  /// 收集新标题；返回 null 表示取消、输入为空、或标题未改动。
  Future<String?> _promptRename(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initialTitle: group.title),
    );
    final trimmed = result?.trim();
    // 空标题服务端会拒绝（且「改成空」几乎不可能是用户意图），本地直接拦掉。
    if (trimmed == null || trimmed.isEmpty) return null;
    // 没改动就别发请求（省一次往返，也避免把列表里的 updated_at 白白推新）。
    if (trimmed == group.title) return null;
    return trimmed;
  }

  /// 删除确认；返回 null 表示用户取消。
  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('group-delete-dialog'),
        title: const Text('删除对话'),
        content: Text('「${group.title}」将被永久删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('group-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final tile = ListTile(
      onTap: onTap,
      title: Text(group.title, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          if (group.isArchived) ...[
            // 归档状态必须可见：否则用户会奇怪为什么这个对话不更新。
            Icon(
              Icons.archive_outlined,
              size: SpbSpacing.md,
              color: scheme.outline,
            ),
            const SizedBox(width: SpbSpacing.xs),
            Text('已归档', style: textTheme.labelSmall),
            const SizedBox(width: SpbSpacing.sm),
          ],
          Text(
            _relativeTime(group.updatedAt),
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          // 结项快照状态徽标：只在归档行且有快照时出现。
          //
          // ## 为什么在 subtitle 而不是 trailing
          //
          // trailing 已被 chevron 占用，塞第二个图标会让整行显得拥挤；而
          // 「有没有结项记录」属于元信息，与「多久没动过」同一层级。
          //
          // ## 为什么 pending/failed 也要显示
          //
          // 用户点了归档后最想知道的是「结项记录好了没」。只显示 ready 会让
          // 生成中的状态看起来像「没做」。
          if (_snapshot != null) ...[
            const SizedBox(width: SpbSpacing.sm),
            _SnapshotBadge(
              snapshot: _snapshot!,
              // 站点可打开时徽标变成可点入口（常显，不依赖 hover——
              // 触屏没有 hover）。站点不可用时保持纯展示。
              onOpenSite:
                  _snapshot!.site.isOpenable && onOpenSnapshotSite != null
                  ? () => onOpenSnapshotSite!(_snapshot!)
                  : null,
            ),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
    );

    if (onAction == null) return tile;

    // 用 GestureDetector 包一层而不是 ListTile.onLongPress：
    // 需要同时拿到右键的**指针位置**（菜单要出现在鼠标处），而
    // ListTile 的 onLongPress 不带位置参数。
    //
    // ## 为什么包 Semantics（issue #24）
    //
    // 重命名/归档/删除这三个动作**只能**从长按或右键菜单到达，键盘用户
    // 与屏幕阅读器用户没有任何入口。Flutter 不会从「包了一个
    // GestureDetector」推断出「这里有自定义动作」——必须显式声明
    // `customSemanticsActions`。
    //
    // 用 `Semantics` 而非 `onLongPress` 参数：后者会挂上真正的长按手势，
    // 与上面只挂 onLongPressStart 的意图冲突。这里只补语义动作（屏幕阅读器
    // 的「长按」手势会触发它），手势层仍归 GestureDetector。
    return Semantics(
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        const CustomSemanticsAction(label: '对话操作（重命名/归档/删除）'): () {
          // 无指针位置：菜单出现在屏幕中心（`showMenu` 在 position 为
          // 零尺寸矩形时的行为）。屏幕阅读器用户看不到菜单贴在哪里。
          _openMenu(context, Offset.zero);
        },
      },
      child: GestureDetector(
        onLongPressStart: (details) =>
            _openMenu(context, details.globalPosition),
        onSecondaryTapDown: (details) =>
            _openMenu(context, details.globalPosition),
        // 让 ListTile 自己处理点击：GestureDetector 的 opaque 会吃掉手势，
        // 故只挂长按/右键，不设 onTap。
        child: tile,
      ),
    );
  }

  /// 相对时间（「3 分钟前」）。
  ///
  /// 不用绝对时间戳：对话列表里用户关心的是「多久没动过」，
  /// 而精确到秒的时间需要用户自己做减法。
  static String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

/// 结项快照的状态徽标（只读，不可点）。
///
/// ## 为什么是徽标而不是按钮
///
/// 列表行已经有一个点击目标（打开对话）和一个菜单入口（长按/右键）。再塞
/// 一个可点元素会让「点哪里发生什么」变得难以预测——尤其桌面端行高有限。
/// 动作统一收进菜单（见 `_GroupTile._openMenu`），徽标只表达状态。
///
/// ## 六种状态的映射
///
/// | 快照 | 站点 | 徽标 |
/// |------|------|------|
/// | pending | — | 结项记录生成中 |
/// | failed | — | 结项记录生成失败 |
/// | ready | ready | 结项记录 |
/// | ready | pending | 结项记录（站点渲染中） |
/// | ready | failed/none | 结项记录（站点不可用） |
///
/// 与 webapp 的 `ArchiveSnapshotEntry` 同一套判定，但那边是**按钮**（有
/// 下载/重部署动作），这边只显示状态——动作在菜单里。
class _SnapshotBadge extends StatelessWidget {
  const _SnapshotBadge({required this.snapshot, this.onOpenSite});

  final ArchiveSnapshot snapshot;

  /// 打开站点。null = 站点不可用或未注入，此时徽标是纯展示。
  ///
  /// ## 为什么入口挂在徽标上而不是 trailing 的图标按钮
  ///
  /// trailing 的 chevron 语义是「进入对话」。再放一个图标按钮会与它并列，
  /// 用户无法从图标区分「哪个是进对话、哪个是开站点」。徽标本身写的是
  /// 「结项记录」，点它开结项站点是自然的映射。
  ///
  /// ## 为什么不用 hover 才显示的按钮
  ///
  /// 触屏没有 hover，那样移动端永远看不到入口。
  final VoidCallback? onOpenSite;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (icon, label, color) = switch (snapshot) {
      ArchiveSnapshot(isPending: true) => (
        Icons.hourglass_empty,
        '结项记录生成中',
        scheme.onSurfaceVariant,
      ),
      ArchiveSnapshot(isFailed: true) => (
        Icons.error_outline,
        '结项记录生成失败',
        scheme.error,
      ),
      // ready：站点状态只影响「能不能在线看」，不影响「有没有结项记录」。
      // 站点 ready 用强调色，其余用中性色——避免「站点失败」被误读成
      // 「结项失败」。
      ArchiveSnapshot(isReady: true) when snapshot.site.isReady => (
        Icons.menu_book_outlined,
        '结项记录',
        scheme.primary,
      ),
      ArchiveSnapshot(isReady: true) => (
        Icons.menu_book_outlined,
        '结项记录',
        scheme.onSurfaceVariant,
      ),
      // 兜底：服务端将来新增 status 时不让徽标消失（静默丢信息比显示
      // 一个笼统标签更糟）。
      _ => (Icons.help_outline, '结项记录', scheme.onSurfaceVariant),
    };

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: SpbSpacing.md, color: color),
        const SizedBox(width: SpbSpacing.xs),
        Text(label, style: textTheme.labelSmall?.copyWith(color: color)),
        if (onOpenSite != null) ...[
          const SizedBox(width: SpbSpacing.xs),
          // 用 `open_in_new` 而不是 chevron：明确「会跳出去」。
          Icon(Icons.open_in_new, size: SpbSpacing.md, color: color),
        ],
      ],
    );

    if (onOpenSite == null) return row;

    // 可点时有最小触摸区域（`InkWell` 默认只在内容范围内响应，徽标本身
    // 只有十几像素高，直接点很难命中）。
    return Semantics(
      button: true,
      label: '打开结项站点',
      child: InkWell(
        onTap: onOpenSite,
        borderRadius: BorderRadius.circular(SpbSpacing.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: row,
        ),
      ),
    );
  }
}

/// 重命名对话框。
///
/// ## 为什么是 StatefulWidget 而不是在 `_promptRename` 里建 controller
///
/// 对话框关闭时有一个**退场动画**（约 150ms），期间 `TextField` 仍在树上、
/// 仍会读 controller。若在 `await showDialog(...)` 返回后立刻 `dispose()`，
/// 动画帧里就会抛「A TextEditingController was used after being disposed」。
///
/// 交给 StatefulWidget 后，Flutter 会在对话框**真正从树上移除后**才调用
/// [State.dispose]——时序天然正确，不必手写延迟。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('group-rename-dialog'),
      title: const Text('重命名对话'),
      content: TextField(
        key: const ValueKey('group-rename-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '标题'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('group-rename-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
