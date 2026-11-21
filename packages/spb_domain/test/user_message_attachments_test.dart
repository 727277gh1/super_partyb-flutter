import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

void main() {
  ChatEvent event(String id, String type, Map<String, dynamic> payload) =>
      ChatEvent.fromJson({
        'eventId': id,
        'eventType': type,
        'groupId': 'g1',
        'turnId': 't1',
        'userId': 'u1',
        'seq': 1,
        'createdAt': '2026-11-20T00:00:00Z',
        'payload': payload,
      });

  test('纯附件消息可见，路由归因和乐观回显合并不丢文件', () {
    final events = [
      event('user', 'user_message', {
        'input': '',
        'attachments': [
          {
            'name': '截图.png',
            'ufs_file_id': 'ufs1',
            'mime_type': 'image/png',
            'size_bytes': 123,
            'path': '/private/server',
            'text': '内部正文',
          },
          'invalid',
        ],
      }),
    ];
    final first = EventReducer.reduce(events).items
        .whereType<UserMessageItem>()
        .single;
    expect(first.attachments.single.name, '截图.png');
    expect(first.attachments.single.fileId, 'ufs1');
    events.add(
      event('routing', 'routing_selected', {
        'group_decision_reason': 'created_new_group',
        'group_switched': true,
      }),
    );
    events.add(
      event('echo', 'user_message', {'input': '查看附件', 'pending': false}),
    );
    final merged = EventReducer.reduce(events).items
        .whereType<UserMessageItem>()
        .single;
    expect(merged.attachments.single.fileId, 'ufs1');
    expect(merged.attachments.single.sizeBytes, 123);
  });
}
