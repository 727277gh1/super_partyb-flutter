import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 回到前台时的连接自救（issue #88 方案 C 的客户端部分）。
///
/// ## 为什么要单独一个文件
///
/// 它验证的不是「怎么连」，而是**「回来时该不该连」的判定矩阵**——每个分支
/// 对应一种真实的平台行为（后见 [ChatStreamController.recoverIfStalled] 的表）：
/// 自动重连耗尽、连接已关、挂起后被系统静默回收的僵尸连接、以及「健康且
/// 空闲」这个最容易被误判的状态。
///
/// 误判的代价不对称：该连不连 → 时间线永远不动（用户以为没人说话）；
/// 不该连乱连 → 每切一次前后台就重连一次、弱网下反复回填。
void main() {
  setUpHarness();

  /// 建一个**已 start**（有连接）的控制器。
  ///
  /// `start(groupId: null)` 走全局模式：不回填、不触网（[FakeSseClient] 的
  /// `connect` 只记录），只是把控制器置成「已建立过连接」。
  Future<ChatStreamController> started() async {
    final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
    await c.start();
    return c;
  }

  group('未 start：没有可恢复的连接', () {
    test('isConnected 为 false 时不重连（resume 无处可去）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      sse.currentState = SseState.failed;

      expect(await c.recoverIfStalled(), isFalse);
      expect(sse.resumeCount, 0, reason: '没有 path 时 resume 是空操作，不得假装重连了');

      await c.dispose();
    });
  });

  group('需要重连的三种状态', () {
    test('failed：自动重连耗尽 maxRetries 后永久停手，只有外部能救', () async {
      final c = await started();
      sse.currentState = SseState.failed;

      expect(await c.recoverIfStalled(), isTrue);
      expect(sse.resumeCount, 1);

      await c.dispose();
    });

    test('idle：连接已关（如 close() 之后），重新建立', () async {
      final c = await started();
      sse.currentState = SseState.idle;

      expect(await c.recoverIfStalled(), isTrue);
      expect(sse.resumeCount, 1);

      await c.dispose();
    });

    test('connected 但静默超阈值：僵尸连接（无 error 也无 onDone）', () async {
      final c = await started();
      sse.currentState = SseState.connected;
      sse.silent = true;

      expect(await c.recoverIfStalled(), isTrue);
      expect(sse.resumeCount, 1);

      await c.dispose();
    });
  });

  group('不该重连的三种状态', () {
    test('connected 且有心跳：空闲对话也是健康的，不得重连', () async {
      final c = await started();
      sse.currentState = SseState.connected;
      sse.silent = false;

      expect(await c.recoverIfStalled(), isFalse);
      expect(sse.resumeCount, 0, reason: '健康连接重连会白刷一次回填');

      await c.dispose();
    });

    test('reconnecting：退避机制还活着，抢话会打乱退避节奏', () async {
      final c = await started();
      sse.currentState = SseState.reconnecting;

      expect(await c.recoverIfStalled(), isFalse);
      expect(sse.resumeCount, 0);

      await c.dispose();
    });

    test('connecting：正在建连，重复触发会撞上防重入守卫', () async {
      final c = await started();
      sse.currentState = SseState.connecting;

      expect(await c.recoverIfStalled(), isFalse);
      expect(sse.resumeCount, 0);

      await c.dispose();
    });
  });

  test('控制器已 dispose 后调用：空操作（不能复活已关闭的流）', () async {
    final c = await started();
    sse.currentState = SseState.failed;
    await c.dispose();

    expect(await c.recoverIfStalled(), isFalse);
    expect(sse.resumeCount, 0);
  });

  test('默认静默阈值 ≥ 3 个心跳周期（3s 一次）', () {
    // 服务端每 3s 一条 `: heartbeat`；阈值低于 3 个周期会把「偶发丢一跳」
    // 误判成断线，于是在弱网下反复重连。
    expect(
      ChatStreamController.resumeSilenceThreshold.inSeconds,
      greaterThanOrEqualTo(9),
    );
  });
}
