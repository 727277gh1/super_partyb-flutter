import 'dart:async';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'confirmation_notification_inbox.dart';

/// 桌面与移动端共用的通知会话；页面只订阅快照，不能另开轮询或维护已读副本。
///
/// ## 两条触发路径，一个事实来源
///
/// - **事件加速**（[poke]）：SSE 收到轮次终态或确认卡变化（
///   `EventTypes.noticeAffecting`）时立刻拉一次，延迟从「等下一个 tick」降到
///   几百毫秒。它只当信号，不带数据。
/// - **周期兜底**（[interval]，默认 60 秒）：没有对应事件的通知
///   （`sandbox_suppressed` 等）、跨端已读的撤销、SSE 断线期间的变化都靠它对齐。
///
/// 兜底**不能删**：事件丢了没人知道，而「现在有几条未读」只有读表才能确定。
/// 周期从 15 秒放宽到 60 秒的前提正是事件加速存在——前台常见路径（自己这一轮
/// 跑完）已经在几百毫秒内弹出来了，剩下的是「别的端/别的服务写进来的」低频变化。
class NoticeCenter {
  NoticeCenter({
    required this.api,
    required this.inbox,
    required this.sessionVersion,
    required this.isFocused,
    this.interval = defaultInterval,
    this.pokeWindow = defaultPokeWindow,
  });

  /// 周期兜底的默认间隔（见类注释：事件加速之后 15 秒已无必要）。
  static const defaultInterval = Duration(seconds: 60);

  /// [poke] 的合并窗口：一串 `done`（多轮连跑）只换算成一次拉取。
  static const defaultPokeWindow = Duration(milliseconds: 400);

  final NoticesApi api;
  final ConfirmationNotificationInbox inbox;
  final Future<int?> Function() sessionVersion;
  final bool Function() isFocused;
  final Duration interval;

  /// 见 [defaultPokeWindow]。
  final Duration pokeWindow;
  final _changes = StreamController<NoticeSnapshot>.broadcast();
  NoticeSnapshot _snapshot = const NoticeSnapshot();
  Timer? _timer;
  Timer? _pokeTimer;
  Future<void>? _refreshing;
  bool _disposed = false;
  int? _version;

  NoticeSnapshot get snapshot => _snapshot;
  Stream<NoticeSnapshot> get changes => _changes.stream;

  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    // 停表时挂起的 poke 也要丢：它的语义是「顺手刷新一下」，页面已经不在时
    // 多打一次 HTTP 毫无意义（widget 测试还会因为残留 Timer 直接红）。
    _pokeTimer?.cancel();
    _pokeTimer = null;
  }

  /// 事件说「通知表可能变了」：合并短窗口内的多次信号，只拉一次。
  ///
  /// 为什么不直接 `refresh()`：一轮连跑会连续发出多条终态/确认事件，逐条拉取
  /// 会把「更即时」变成「更频繁」。合并窗口取几百毫秒——比一次往返长，
  /// 又远短于人类感知阈值。
  ///
  /// 未 [start] 时忽略：那表示没有任何界面在消费通知（页面已卸载），
  /// 拉回来的快照无人接收。
  void poke() {
    if (_disposed || _timer == null) return;
    _pokeTimer?.cancel();
    _pokeTimer = Timer(pokeWindow, () {
      _pokeTimer = null;
      if (_disposed) return;
      unawaited(refresh());
    });
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    // 并发调用共享同一次往返：poke 与周期 tick 撞在一起时只发一个请求。
    return _refreshing ??= _load().whenComplete(() => _refreshing = null);
  }

  Future<void> _load() async {
    try {
      final version = await sessionVersion();
      if (_disposed || version == null) return;
      _version ??= version;
      if (version != _version) return;
      // 必须包含已读项，且每轮读内容：数量不变也可能是同 ID 的新结果或别端已读。
      final page = await api.list(limit: 200);
      await inbox.store.exclusive(() async {
        if (_disposed || version != await sessionVersion()) return;
        if (_disposed) return;
        await inbox.handleNotices(page.notices, focused: isFocused());
        if (_disposed) return;
        _emit(NoticeSnapshot(notices: page.notices, unread: page.unread));
      });
    } catch (error) {
      if (_disposed) return;
      SpbLog.warn('通知中心刷新失败', {'error': error.toString()});
      _emit(
        NoticeSnapshot(
          notices: _snapshot.notices,
          unread: _snapshot.unread,
          error: '通知暂时无法加载，请重试',
        ),
      );
    }
  }

  /// 展示、聚焦、滑掉横幅均不算已读，只有用户主动确认才写服务端。
  Future<void> markRead({List<String> ids = const [], bool all = false}) async {
    await inbox.store.exclusive(() async {
      final version = await sessionVersion();
      if (_disposed || version == null || version != _version) return;
      if (_disposed) return;
      await api.markRead(ids: ids, all: all);
    });
    // 若写入期间已有 GET 在途，等旧快照完成后再获取已读真源。
    await _refreshing;
    await refresh();
  }

  void _emit(NoticeSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    _changes.add(value);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    unawaited(_changes.close());
  }
}

class NoticeSnapshot {
  const NoticeSnapshot({this.notices = const [], this.unread = 0, this.error});

  final List<Notice> notices;
  final int unread;
  final String? error;
}
