import 'dart:async';

import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'todo_change.dart';

/// 一次「本对话待确认同步项」的快照。
class SyncTodoFeedState {
  const SyncTodoFeedState({
    this.items = const [],
    this.enabled = false,
    this.loading = false,
    this.error,
  });

  /// 服务端挂起项（**唯一**真源，别从 `todo.changed` 推导）。
  final List<WorkspaceSyncReview> items;

  /// 服务端 groupsync worker 是否在跑（`enabled: false` → 不展示入口）。
  ///
  /// 与「已启用但没有待确认项」必须区分：前者用户无从处理，后者应什么都不显示
  /// 但保持轮询。
  final bool enabled;

  /// 是否有一轮在途（首屏用；后续刷新不清空列表，故不置 true）。
  final bool loading;

  /// 最近一次失败的原因；成功一次即清空。
  ///
  /// 失败**不清空** [items]：一次网关抖动不该让「待办」凭空消失，那会让用户
  /// 以为文件已经被处理了。
  final String? error;
}

/// 「本对话待确认同步项」的取数 + 失效驱动（纯 Dart，可无头单测）。
///
/// ## 它解决什么
///
/// 对话页的待办面板与侧边栏徽标要**同一份**数据：面板只在被切到时才构建
/// （`ChatSidebar` 的惰性加载），而徽标要在用户还没打开面板时就是对的。故取数
/// 不能住在面板里——放在这里，页面订阅一次，面板与徽标都读同一份状态。
///
/// ## 三条失效来源
///
/// 1. 首次拉取（[start]）；
/// 2. 定时轮询 [pollInterval]（事件会丢，见下）；
/// 3. `todo.changed`（[todoChanges]）——**即时**失效，省掉最多 15 秒的等待。
///
/// 轮询**不删**：`todo.changed` 是 Transient（不落库、不回放），断线/切后台
/// 会丢，服务端也明确写了「断线丢失只是晚一轮」。事件只是加速，不是真源。
///
/// ## 单飞
///
/// 事件风暴（一次扫描连发 N 条 `op=created`）与轮询可能同时触发，[refresh]
/// 复用同一份在途 Future——否则一次扫描能打出 N 次 HTTP。
class SyncTodoFeed {
  SyncTodoFeed({
    required this.groupId,
    required this.fetch,
    this.todoChanges,
    this.pollInterval = const Duration(seconds: 15),
    this.idlePollInterval = const Duration(seconds: 60),
  });

  /// 本 feed 所属 group（用于过滤群级 `todo.changed`）。
  final String groupId;

  /// 取一次快照（真实实现是 `ChatApi.listWorkspaceSyncReviews(groupId)`）。
  final Future<WorkspaceSyncReviewsPage> Function() fetch;

  /// 待办失效通知流（可缺省：缺省时只靠轮询）。
  final Stream<TodoChange>? todoChanges;

  /// 轮询间隔。`Duration.zero` 表示不轮询（只在 [start] 与事件时拉）。
  final Duration pollInterval;

  /// groupsync **未启用**时的轮询间隔（降频，不是停）。
  ///
  /// ## 为什么降频而不是停
  ///
  /// `enabled: false` 来自服务端当次配置（worker 没跑），不是「本对话没有待办」。
  /// 停掉轮询会让「运维打开 groupsync」这个事件永远发现不了——用户得关掉重开
  /// 对话页；而按 15 秒继续打，等于给每个打开的对话页挂一条永久无效请求。
  /// 60 秒的粒度足够覆盖「配置变了」这种低频变化，代价可以忽略。
  ///
  /// `Duration.zero`（或 ≤ [pollInterval] 的更小值）表示不降频。
  final Duration idlePollInterval;

  final _controller = StreamController<SyncTodoFeedState>.broadcast();
  SyncTodoFeedState _state = const SyncTodoFeedState(loading: true);
  Timer? _timer;
  StreamSubscription<TodoChange>? _sub;
  Future<void>? _inFlight;
  bool _disposed = false;
  bool _running = false;

  /// 状态流：先给当前状态（首帧不闪），随后逐条推送。
  ///
  /// 先 `yield _state` 而不是只转发 broadcast 流：装配层把它包进
  /// `StreamProvider` 时，订阅发生在 `start()` 的首个事件**之前**，只转发会让
  /// 首帧拿到 `AsyncLoading` 而不是「加载中」的快照（徽标会晚一帧才出现）。
  /// 状态流：**订阅时先给当前状态**，随后逐条推送。
  ///
  /// ## 为什么不是 `yield _state; yield* _controller.stream`
  ///
  /// `async*` 生成器是惰性执行的：`listen()` 之后它的第一段代码要等一个微任务，
  /// 而首拉的响应可能在同一轮微任务里就 `_emit` 出去——那时生成器还没订阅到
  /// 广播流，事件被**静默丢掉**（broadcast 无监听者即丢弃）。实测现象：徽标与
  /// 面板卡在「加载中」直到下一次轮询。
  ///
  /// `Stream.multi` 的 onListen 回调是**同步**执行的：先补当前状态、再同步订阅
  /// 底层广播流，中间没有空档。
  Stream<SyncTodoFeedState> get changes {
    return Stream<SyncTodoFeedState>.multi((listener) {
      listener.add(_state);
      final sub = _controller.stream.listen(
        listener.add,
        onError: listener.addError,
        onDone: listener.close,
      );
      listener.onCancel = sub.cancel;
    });
  }

  /// 当前状态（同步初值，供首帧直接渲染）。
  SyncTodoFeedState get state => _state;

  /// 起轮询与事件订阅，并拉一次快照。**幂等**（重复调用不会叠加定时器/订阅）。
  ///
  /// 装配层会把本方法与 [stop] 挂在 Riverpod 的 `onResume` / `onCancel` 上
  /// （同 `NoticeCenter` 的做法）：页面卸载时最后一个监听者消失 → 立刻停表，
  /// 而不是等 autoDispose 在下一个微任务里回收。这一条很实在——widget 测试
  /// 在树销毁后**立即**检查「是否有未取消的 Timer」，晚一步就是一片红。
  Future<void> start() async {
    if (_disposed || _running) return;
    _running = true;
    _sub ??= todoChanges?.listen(_onTodoChange);
    // 先拉一次：`_arm` 要按**首拉**返回的 enabled 决定快/慢节奏，不能瞎猜。
    await refresh();
  }

  /// 暂停轮询与事件订阅（状态保留，[start] 可再次武装）。
  ///
  /// 为什么要真的退订事件流：另一个页面（设置页）也在订阅同一条
  /// `todo.changed`，这里留着订阅只会在空闲页面上反复触发无谓的 GET。
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// 通知到达：只有**本 group** 的变更才重拉（群级通知，别的对话变了与我无关）。
  void _onTodoChange(TodoChange change) {
    if (!change.matchesGroup(groupId)) return;
    unawaited(refresh());
  }

  /// 重拉一次（单飞）。
  Future<void> refresh() {
    return _inFlight ??= () async {
      try {
        final page = await fetch();
        if (_disposed) return;
        _emit(
          SyncTodoFeedState(
            items: page.items,
            enabled: page.enabled,
            loading: false,
          ),
        );
      } on Object catch (e) {
        if (_disposed) return;
        // 保留上次列表（见 [SyncTodoFeedState.error] 的说明）。
        _emit(
          SyncTodoFeedState(
            items: _state.items,
            enabled: _state.enabled,
            loading: false,
            error: e is SpbError ? e.message : '待办加载失败：$e',
          ),
        );
      } finally {
        _inFlight = null;
        // 每轮之后重排（而不是 `Timer.periodic`）：间隔取决于本轮返回的
        // `enabled`，周期定时器改不了自己的周期。
        _arm();
      }
    }();
  }

  /// 排下一轮轮询（一次性定时器，自续排）。
  ///
  /// 刻意不用 `Timer.periodic`：`enabled` 在一轮与一轮之间会变（运维开关
  /// groupsync、worker 崩溃后被拉起），而 `periodic` 的周期是构造时钉死的。
  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !_running) return;
    final interval = _state.enabled
        ? pollInterval
        // 降频只做「更慢」这一件事：调用方给了比 pollInterval 更小的
        // idlePollInterval 时按快的那条来（不做加速）。
        : (idlePollInterval > pollInterval ? idlePollInterval : pollInterval);
    if (interval <= Duration.zero) return;
    _timer = Timer(interval, () {
      _timer = null;
      unawaited(refresh());
    });
  }

  void _emit(SyncTodoFeedState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// 停轮询、退订、关流。调用后本实例不可复用。
  Future<void> dispose() async {
    _disposed = true;
    stop();
    await _controller.close();
  }
}
