import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';

import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 后台挂起后回到前台的对账（issue #88 方案 C 的客户端部分）。
///
/// ## 测的是什么
///
/// 移动端切后台一阵后，系统会冻结进程：SSE 断掉、待确认列表停在旧快照。
/// 回到前台时必须**自己**对一次账——不能等用户手点刷新，也不能等 SSE 自己
/// 醒过来（重连次数耗尽后它是永久停手的）。
///
/// 两件事分别断言：
///
/// 1. `pendingConfirmationsProvider` 被重拉（用户看到的是最新待确认）；
/// 2. 共享 SSE 连接在 `failed` 时被救活，健康时空操作（不白刷回填）。
///
/// 反面断言同样重要：`inactive → resumed`（下拉通知中心又回来）**不得**
/// 触发对账——那不是真正的后台往返。
void main() {
  /// 推进到「首页拉过一次」的稳定状态。
  Future<void> settleHome(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  }

  /// 模拟「切后台 → 回前台」。
  ///
  /// 必须跑**完整序列**：Flutter 的 `AppLifecycleListener` 会断言非法跳转
  /// （如 `resumed → paused` 直跳），而真机回前台也不是一跳
  /// ——`paused → hidden → inactive → resumed`（见 `_LifecycleFocusObserver`
  /// 里「上一层永远是 inactive」的说明）。
  Future<void> backgroundAndResume(WidgetTester tester) async {
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    for (final state in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('回到前台重拉待确认列表；inactive→resumed 不触发', (tester) async {
    var confirmationRequests = 0;
    await pumpApp(
      tester,
      mockPendingConfirmations: false,
      beforePump: (adapter) {
        // 计数版：必须注册在 `beforePump` 里，否则会被 pumpApp 的默认 mock
        // 覆盖掉（那样计数永远是 0）。
        adapter.onGet(
          '/chat/confirmations',
          (server) => server.replyCallback(200, (_) {
            confirmationRequests++;
            return {'items': <Map<String, dynamic>>[]};
          }),
          queryParameters: {'status': 'pending', 'limit': 50},
        );
      },
    );
    await settleHome(tester);

    expect(confirmationRequests, 1, reason: '首页挂载即拉一次');

    // 只是下拉通知中心又回来：进程没被冻结，重拉是浪费。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(
      confirmationRequests,
      1,
      reason: 'inactive→resumed 是「没离开过应用」的往返，不得重拉',
    );

    await backgroundAndResume(tester);

    expect(
      confirmationRequests,
      2,
      reason: '真的从后台回来：供应商 10 分钟 TTL 会清掉卡，必须对一次账',
    );
  });

  testWidgets('回到前台时 failed 的 SSE 被救活，健康连接空操作', (tester) async {
    final sse = FakeSseClient();
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
      sseClient: sse,
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': <String>[],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_x',
          (server) => server.reply(200, {
            'id': 'grp_x',
            'user_id': 'usr_REAL',
            'title': '切后台测试',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_x/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_x', 'limit': 20},
        );
      },
    );
    await settleHome(tester);

    expect(sse.connectedPaths, isNotEmpty, reason: '进入对话页必须已建连');

    // 健康连接：有空闲也是有心跳的，重连只会白刷一次回填。
    await backgroundAndResume(tester);
    expect(sse.resumeCount, 0, reason: 'connected 且未静默 → 空操作');

    // 挂起期间自动重连耗尽 → failed（永久停手）。回到前台必须救活它。
    sse.currentState = SseState.failed;
    await backgroundAndResume(tester);
    expect(sse.resumeCount, 1, reason: 'failed 状态下没人会再重连，回前台是唯一的自救时机');
  });
}
