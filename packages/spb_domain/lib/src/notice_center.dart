import 'dart:async';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'confirmation_notification_inbox.dart';

/// 桌面与移动端共用的通知会话；页面只订阅快照，不能另开轮询或维护已读副本。
class NoticeCenter {
  NoticeCenter({
    required this.api,
    required this.inbox,
    required this.sessionVersion,
    required this.isFocused,
    this.interval = const Duration(seconds: 15),
  });

  final NoticesApi api;
  final ConfirmationNotificationInbox inbox;
  final Future<int?> Function() sessionVersion;
  final bool Function() isFocused;
  final Duration interval;
  final _changes = StreamController<NoticeSnapshot>.broadcast();
  NoticeSnapshot _snapshot = const NoticeSnapshot();
  Timer? _timer;
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
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
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
