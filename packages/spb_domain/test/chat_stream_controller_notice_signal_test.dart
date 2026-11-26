import 'dart:async';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 通知失效信号（`EventTypes.noticeAffecting`）的分流点。
///
/// 这里测的是**信号**，不是通知内容：信号只说明「`owner_notices` 可能变了」，
/// 消费方收到后去 `GET /me/notices` 拉真值（见 `NoticeCenter.poke`）。
void main() {
  setUpHarness();

  test('轮次终态发信号，正文增量不发（避免把流式帧变成拉取风暴）', () async {
    final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
    mockTimeline();
    await c.start(groupId: 'grp_1');
    var signals = 0;
    final sub = c.noticeSignals.listen((_) => signals++);

    sse.push(
      EventTypes.message,
      sseEvent(
        EventTypes.message,
        id: 'm1',
        payload: {'content': '正文'},
        seq: 1,
        globalSeq: 1,
      ),
    );
    sse.push(
      EventTypes.thought,
      sseEvent(
        EventTypes.thought,
        id: 't1',
        payload: {'content': '想一想'},
        seq: 2,
        globalSeq: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(signals, 0, reason: '流式增量与通知无关，逐帧拉取会打爆 /me/notices');

    sse.push(
      EventTypes.done,
      sseEvent(
        EventTypes.done,
        id: 'd1',
        payload: {'status': 'completed'},
        seq: 3,
        globalSeq: 3,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(signals, 1);

    await sub.cancel();
    await c.dispose();
  });

  test('别的群跑完也发信号（信号在 group 过滤之前）', () async {
    final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
    mockTimeline();
    await c.start(groupId: 'grp_1');
    var signals = 0;
    final sub = c.noticeSignals.listen((_) => signals++);

    // 用户正看着 grp_1，grp_2 跑完了——横幅的价值恰恰在这里。
    sse.push(
      EventTypes.done,
      sseEvent(
        EventTypes.done,
        id: 'd2',
        turnId: 'turn_2',
        groupId: 'grp_2',
        payload: {'status': 'completed'},
        seq: 4,
        globalSeq: 4,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(signals, 1);

    await sub.cancel();
    await c.dispose();
  });

  test('确认卡出现/作答/作废都发信号（服务端同时写通知表）', () async {
    final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
    mockTimeline();
    await c.start(groupId: 'grp_1');
    var signals = 0;
    final sub = c.noticeSignals.listen((_) => signals++);

    sse.push(
      EventTypes.confirmationRequired,
      sseEvent(
        EventTypes.confirmationRequired,
        id: 'cf1',
        payload: {'question': '继续吗？', 'confirmation_id': 'cf_row_1'},
        seq: 5,
        globalSeq: 5,
      ),
    );
    sse.push(
      EventTypes.confirmationResolved,
      sseEvent(
        EventTypes.confirmationResolved,
        id: 'cf2',
        payload: {'confirmation_id': 'cf_row_1', 'answer': '继续'},
        seq: 6,
        globalSeq: 6,
      ),
    );
    sse.push(
      EventTypes.confirmationExpired,
      sseEvent(
        EventTypes.confirmationExpired,
        id: 'cf3',
        payload: {'confirmation_id': 'cf_row_1'},
        seq: 7,
        globalSeq: 7,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(signals, 3);

    await sub.cancel();
    await c.dispose();
  });

  test('dispose 后信号流关闭，不再向已关闭的控制器写入', () async {
    final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
    mockTimeline();
    await c.start(groupId: 'grp_1');
    var done = false;
    final sub = c.noticeSignals.listen((_) {}, onDone: () => done = true);
    await c.dispose();
    // 关闭是 await 的：dispose 返回后订阅方已经收到 onDone。
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
    await sub.cancel();
  });
}
