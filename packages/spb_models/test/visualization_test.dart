import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

const payload = <String, dynamic>{
  'event_version': 1,
  'artifact_id': 'viz_sales',
  'artifact_key': 'sales',
  'revision': 2,
  'profile': 'partyb.readonly',
  'schema_version': 1,
  'title': '销售趋势',
  'summary': '金额单位为元',
};

void main() {
  test('恢复页损坏时整体失败，不能跳过记录后推进水位', () {
    final valid = <String, dynamic>{
      'items': <dynamic>[],
      'through_global_seq': 990,
      'next_after_global_seq': 990,
      'has_more': false,
    };
    expect(
      () => VisualizationRecoveryPage.fromJson({
        ...valid,
        'items': [null],
      }),
      throwsA(isA<TypeError>()),
    );
    expect(
      () => VisualizationRecoveryPage.fromJson(
        {...valid}..remove('through_global_seq'),
      ),
      throwsA(isA<TypeError>()),
    );
  });

  test('SSE 与恢复 REST 保留相同固定版本引用', () {
    final sse = ChatEvent.fromJson({
      'eventId': 'evt_sales',
      'userId': 'u1',
      'groupId': 'g1',
      'turnId': 't1',
      'eventType': 'visualization.published',
      'seq': 3,
      'globalSeq': 501,
      'source': 'agent',
      'createdAt': '2026-11-10T00:00:00Z',
      'payload': payload,
    });
    final page = VisualizationRecoveryPage.fromJson({
      'items': [
        {
          'event_id': 'evt_sales',
          'group_id': 'g1',
          'turn_id': 't1',
          'event_type': 'visualization.published',
          'seq': 3,
          'global_seq': 501,
          'source': 'agent',
          'created_at': '2026-11-10T00:00:00Z',
          'payload': payload,
        },
      ],
      'through_global_seq': 990,
      'next_after_global_seq': 501,
      'has_more': true,
    });
    final rest = page.items.single;
    expect(sse.isKnown, isTrue);
    expect(sse.transient, isFalse);
    expect(rest.eventId, sse.eventId);
    expect(rest.globalSeq, 501);
    expect(rest.userId, ''); // 恢复接口以登录身份鉴权，不回传 user_id。
    expect(rest.visualization?.artifactId, 'viz_sales');
    expect(rest.visualization?.revision, 2);
    expect(rest.visualization?.isSupported, isTrue);
    expect(page.throughGlobalSeq, 990);
    expect(page.nextAfterGlobalSeq, 501);
    expect(page.hasMore, isTrue);
  });

  test('未知或缺失版本不被默认解释为 v1，保留摘要', () {
    for (final changed in [
      {...payload, 'event_version': 2},
      {...payload, 'schema_version': 2},
      {...payload, 'profile': 'future.profile'},
      {...payload}..remove('event_version'),
      {...payload, 'revision': 0},
    ]) {
      final value = VisualizationPublished.fromJson(changed);
      expect(value.isSupported, isFalse);
      expect(value.title, '销售趋势');
    }
    final unrelated = ChatEvent.fromJson({
      'eventId': 'evt_message',
      'eventType': 'message',
      'payload': payload,
    });
    expect(unrelated.visualization, isNull);
  });

  test('版本响应保存 Spec 来源与内容身份，空恢复页仍有权威水位', () {
    final spec = <String, dynamic>{
      'root': 'note',
      'elements': {
        'note': {
          'type': 'Text',
          'props': {'text': '暂无数据'},
        },
      },
      'state': <String, dynamic>{},
    };
    final revision = VisualizationRevision.fromJson({
      ...payload,
      'group_id': 'g1',
      'turn_id': 't1',
      'event_id': 'evt_sales',
      'content_hash': 'sha256:abc',
      'status': 'published',
      'created_at': '2026-11-10T00:00:00Z',
      'data_as_of': '2026-11-09T00:00:00Z',
      'sources': [
        {'label': '业务报表'},
        {'label': '来源', 'url': 'https://example.com'},
      ],
      'spec': spec,
    });
    expect(revision.isSupported, isTrue);
    expect(revision.spec, spec);
    expect(revision.revision, 2);
    expect(revision.eventId, 'evt_sales');
    expect(revision.contentHash, 'sha256:abc');
    expect(revision.sources.first.url, isNull);
    expect(revision.sources.last.url, 'https://example.com');
    expect(revision.dataAsOf, DateTime.utc(2026, 11, 9));
    final page = VisualizationPage.fromJson({
      'items': [
        {...payload, 'group_id': 'g1', 'created_at': '2026-11-10T00:00:00Z'},
      ],
      'next_cursor': 'opaque',
    });
    expect(page.items.single.revision, 2);
    expect(page.nextCursor, 'opaque');
    final recovered = VisualizationRecoveryPage.fromJson({
      'items': <dynamic>[],
      'through_global_seq': 990,
      'next_after_global_seq': 990,
      'has_more': false,
    });
    expect(recovered.items, isEmpty);
    expect(recovered.nextAfterGlobalSeq, 990);
    expect(recovered.hasMore, isFalse);
  });
}
