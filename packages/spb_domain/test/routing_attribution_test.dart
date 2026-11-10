import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// [routingAttributionNotice] / [isRoutineRoutingReason] 的纯函数测试。
///
/// 原因值逐字取自服务端写端（Go `chatpipeline` 的 `GroupReason` 与兜底推导），
/// 判定规则：「新建 > 切换」，无聊原因不展示，未知原因 fail-open 原样透传。
void main() {
  group('isRoutineRoutingReason', () {
    test('服务端全部「复用类」原因都视为无聊', () {
      for (final r in [
        'fixed_reuse',
        'reuse_current',
        'user_specified_reuse',
        'classify_reuse',
        'classify_fastpath',
        'classify_confidence',
        'keep_current_group',
        'reuse_group',
      ]) {
        expect(isRoutineRoutingReason(r), isTrue, reason: r);
      }
    });

    test('新建类原因不是无聊', () {
      for (final r in [
        'create_new',
        'fixed_new',
        'user_specified_new',
        'classify_new_topic',
        'create_new_group',
      ]) {
        expect(isRoutineRoutingReason(r), isFalse, reason: r);
      }
    });

    test('null 与空串视为无聊（没有信息就不占空间）', () {
      expect(isRoutineRoutingReason(null), isTrue);
      expect(isRoutineRoutingReason(''), isTrue);
    });

    test('未知原因不是无聊（fail-open：宁多显示不静默吞）', () {
      expect(isRoutineRoutingReason('some_new_reason_from_server'), isFalse);
    });
  });

  group('routingAttributionNotice', () {
    test('fixed_reuse + 未切换 → null（对话内发送的常态，零空间）', () {
      expect(
        routingAttributionNotice(reason: 'fixed_reuse', switched: false),
        isNull,
      );
    });

    test('全部无聊原因 + 未切换 → null', () {
      for (final r in [
        'reuse_current',
        'user_specified_reuse',
        'classify_reuse',
        'classify_fastpath',
        'classify_confidence',
        'keep_current_group',
        'reuse_group',
      ]) {
        expect(routingAttributionNotice(reason: r), isNull, reason: r);
      }
    });

    test('create_new → 「已新建对话」（newGroup）', () {
      final n = routingAttributionNotice(reason: 'create_new')!;
      expect(n.label, '已新建对话');
      expect(n.tone, RoutingAttributionTone.newGroup);
      expect(n.tooltip, contains('create_new'));
    });

    test('fixed_new（旧 group 失效换新）→ 「已新建对话」', () {
      final n = routingAttributionNotice(reason: 'fixed_new')!;
      expect(n.label, '已新建对话');
      expect(n.tone, RoutingAttributionTone.newGroup);
    });

    test('user_specified_new / classify_new_topic / 旧兜底 → 「已新建对话」', () {
      for (final r in [
        'user_specified_new',
        'classify_new_topic',
        'create_new_group',
      ]) {
        expect(routingAttributionNotice(reason: r)!.label, '已新建对话', reason: r);
      }
    });

    test('无聊原因 + switched=true → 「已切换对话」（classify_reuse 可伴随切换）', () {
      final n = routingAttributionNotice(
        reason: 'classify_reuse',
        switched: true,
      )!;
      expect(n.label, '已切换对话');
      expect(n.tone, RoutingAttributionTone.switched);
      expect(n.tooltip, contains('classify_reuse'));
    });

    test('reason 缺失 + switched=true → 仍显示「已切换对话」', () {
      final n = routingAttributionNotice(reason: null, switched: true)!;
      expect(n.label, '已切换对话');
      expect(n.tone, RoutingAttributionTone.switched);
    });

    test('新建类 + switched（fixed_new 必然伴随）→ 新建优先', () {
      final n = routingAttributionNotice(reason: 'fixed_new', switched: true)!;
      expect(n.label, '已新建对话');
      expect(n.tone, RoutingAttributionTone.newGroup);
    });

    test('未知原因 → 原样透传为徽标文案（info）', () {
      final n = routingAttributionNotice(reason: 'brand_new_kind')!;
      expect(n.label, 'brand_new_kind');
      expect(n.tone, RoutingAttributionTone.info);
      expect(n.tooltip, 'brand_new_kind');
    });

    test('reason 与 switched 全缺 → null', () {
      expect(routingAttributionNotice(), isNull);
    });
  });
}
