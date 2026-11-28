import 'dart:convert';
import 'dart:io';

import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

void main() {
  test('Go 通知矩阵的所有站内类型均保留文案、版本和深链', () {
    final fixture = jsonDecode(
      File('fixtures/notification-contract.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final now = DateTime.parse(fixture['now'] as String);
    final notices = (fixture['notices'] as List).cast<Map<String, dynamic>>();
    expect(notices, isNotEmpty);
    for (final raw in notices) {
      final notice = Notice.fromJson(raw);
      expect(notice.title, raw['title']);
      expect(notice.route, '/chat/group-1');
      expect(notice.isRead, isFalse);
      expect(
        notice.displayBody(now),
        notice.kind == 'confirmation_required'
            ? '${raw['body']}（已失效，仅作记录）'
            : raw['body'],
      );
      final updated = Notice.fromJson({
        ...raw,
        'updated_at': '2026-11-20T11:00:00Z',
      });
      expect(updated.id, notice.id);
      expect(updated.revision, isNot(notice.revision));
    }
  });
}
