import 'dart:async';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

void main() {
  setUpHarness();
  test('普通缓冲裁剪后保留恢复卡片，切组清除独立集合', () async {
    mockTimeline();
    final recovered = sseEvent(
      EventTypes.visualizationPublished,
      id: 'visualization',
      payload: {
        'event_version': 1,
        'artifact_id': 'a',
        'revision': 1,
        'profile': 'partyb.readonly',
        'schema_version': 1,
        'title': '报告',
        'summary': '结论',
      },
    );
    adapter.onGet(
      '/chat/groups/grp_1/visualization-events',
      (server) => server.reply(200, {
        'items': [recovered],
        'through_global_seq': 1,
        'next_after_global_seq': 1,
        'has_more': false,
      }),
      queryParameters: {'after_global_seq': 0, 'limit': 200},
    );
    final controller = ChatStreamController(
      sse: sse,
      api: api,
      userId: 'usr_1',
    );
    await controller.start(groupId: 'grp_1');
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot.whereType<VisualizationItem>(), hasLength(1));
    // 普通消息超过缓冲上限；每条分属不同 turn，确实触发整轮裁剪。
    for (var i = 2; i < 2105; i++) {
      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'e$i',
          turnId: 't$i',
          globalSeq: i,
          payload: {'text': '内容'},
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(controller.bufferedEventCount, lessThanOrEqualTo(2000));
    expect(controller.snapshot.whereType<VisualizationItem>(), hasLength(1));
    for (final seq in [3000, 2900, 3000]) {
      sse.push(
        EventTypes.visualizationPublished,
        sseEvent(
          EventTypes.visualizationPublished,
          id: 'viz$seq',
          globalSeq: seq,
          payload: {'event_version': 2, 'title': '未来报告', 'summary': '结论'},
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.snapshot.whereType<VisualizationItem>().map((item) => item.id),
      ['visualization', 'viz2900', 'viz3000'],
    );
    await controller.switchGroup(null);
    expect(controller.snapshot.whereType<VisualizationItem>(), isEmpty);
    await controller.dispose();
    await sse.dispose();
  });
}
