import 'dart:async';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/src/visualization_recovery.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

Map<String, dynamic> event(int seq, {String group = 'g'}) => {
  'event_id': 'e$seq',
  'group_id': group,
  'turn_id': 't',
  'event_type': EventTypes.visualizationPublished,
  'global_seq': seq,
  'seq': seq,
  'source': 'agent',
  'created_at': '2026-11-10T00:00:00Z',
  'payload': {
    'event_version': 1,
    'artifact_id': 'a',
    'revision': seq,
    'profile': 'partyb.readonly',
    'schema_version': 1,
    'title': '报告',
    'summary': '结论',
  },
};
VisualizationRecoveryPage page(
  List<Map<String, dynamic>> items,
  int high, {
  int? next,
  bool more = false,
}) => VisualizationRecoveryPage.fromJson({
  'items': items,
  'through_global_seq': high,
  'next_after_global_seq': next ?? high,
  'has_more': more,
});

void main() {
  test('冻结高水位恢复超过 500 条，并按 eventId 去重保留所有 revision', () async {
    final saved = <String, ChatEvent>{'e900': ChatEvent.fromJson(event(900))};
    final calls = <(int, int?)>[];
    final recovery = VisualizationRecovery(
      groupId: 'g',
      fetch: (after, through) async {
        calls.add((after, through));
        final next = (after + 200).clamp(0, 650);
        return page(
          List.generate(next - after, (i) => event(after + i + 1)),
          650,
          next: next,
          more: next < 650,
        );
      },
      save: (items) {
        for (final item in items) {
          saved[item.eventId] = item;
        }
      },
    );
    await recovery.refresh();
    expect(saved.length, 651);
    expect(calls, [(0, null), (200, 650), (400, 650), (600, 650)]);
    final items = EventReducer.reduce(saved.values.toList()).items
        .whereType<VisualizationItem>()
        .toList();
    expect(items.length, 651);
    expect(items.last.reference.revision, 650);
  });
  test('保存失败不推进水位；409 从零重建', () async {
    final calls = <(int, int?)>[];
    var fail = true;
    final recovery = VisualizationRecovery(
      groupId: 'g',
      fetch: (after, through) async {
        calls.add((after, through));
        if (after == 1) {
          throw const HttpError(
            409,
            'reset',
            body: '{code: cursor_reset_required}',
          );
        }
        return page([event(1)], 1);
      },
      save: (_) {
        if (fail) throw StateError('保存失败');
      },
    );
    await expectLater(recovery.refresh(), throwsStateError);
    fail = false;
    await recovery.refresh();
    await recovery.refresh();
    expect(calls, [(0, null), (0, 1), (1, null), (0, null)]);
  });
  test('切组与登出停止恢复，旧响应不可保存', () async {
    final pending = Completer<VisualizationRecoveryPage>();
    var saved = false;
    final recovery = VisualizationRecovery(
      groupId: 'g',
      fetch: (_, _) => pending.future,
      save: (_) => saved = true,
    );
    final first = recovery.refresh();
    expect(identical(first, recovery.refresh()), isTrue);
    recovery.stop();
    pending.complete(page([event(1)], 1));
    await first;
    expect(saved, isFalse);
  });
  test('拒绝串组、乱序和不完整分页', () async {
    for (final bad in [
      page([event(1, group: 'other')], 1),
      page([event(2), event(1)], 2),
      page([], 2, next: 1, more: true),
    ]) {
      var saved = false;
      final recovery = VisualizationRecovery(
        groupId: 'g',
        fetch: (_, _) async => bad,
        save: (_) => saved = true,
      );
      await expectLater(recovery.refresh(), throwsFormatException);
      expect(saved, isFalse);
    }
  });
}
