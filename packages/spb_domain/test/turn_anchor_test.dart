import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';

/// 「跳到某一轮」锚点契约的纯逻辑回归。
///
/// ## 这个文件防的是什么
///
/// 深链（`/chat/{groupId}?turn=<turnId>`）的失败方式是**静默**的：点了没反应、
/// 跳到列表顶部、跳到别的轮次——没有异常、没有日志。故判据必须在这里逐条钉住：
///
/// - 非法锚点值不能生效（它来自 URL，任何人都能改；还会被拿去比较行键）；
/// - 「最后一轮」必须被识别成「跟随最新」（否则用户跳回最新还要手动滚到底）；
/// - 无归属项（空 `turnId`）不能把「最后一轮」的判定带偏。
///
/// 与 webapp `turn-anchor.test.ts` 的口径对齐（同一份契约的两个实现）。
///
/// ⚠️ 夹具用**真实形态**的 turn id（32 位 hex，对齐 Go `chatid.NewID`）作为主用例，
/// 并单独钉住一个边界：归一化**不**按 hex 写死（否则一个未预料到的 id 形态就会
/// 变成一个完全静默的失效），但仍挡掉会破坏键比较的字符。
void main() {
  const idA = '0123456789abcdef0123456789abcdef';
  const idB = 'fedcba9876543210fedcba9876543210';
  const idC = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  group('normalizeTurnAnchor', () {
    test('接受 32 位 hex，并统一成小写去空白', () {
      expect(normalizeTurnAnchor(idA), idA);
      expect(normalizeTurnAnchor('  ${idA.toUpperCase()} '), idA);
    });

    test('接受带连字符的 uuid 形态并归一化成无连字符', () {
      expect(normalizeTurnAnchor('01234567-89ab-cdef-0123-456789abcdef'), idA);
      expect(normalizeTurnAnchor('01234567-89AB-CDEF-0123-456789ABCDEF'), idA);
    });

    test('非法值一律视为「没有锚点」，不抛', () {
      for (final bad in <String?>[
        null,
        '',
        '   ',
        // 含会破坏日志/URL/键比较的字符
        'turn 1',
        'turn/1',
        'turn.1',
        '0123456789abcdef0123456789abcdef"',
        // 超长（>64）
        'a' * 65,
      ]) {
        expect(normalizeTurnAnchor(bad), isNull, reason: 'bad=$bad');
      }
    });

    test('不按 hex 写死：合法形状的非 hex id 也归一化（否则静默失效）', () {
      // 服务端主路径是 32 位 hex，但历史数据/缓存/未来生成器未必。
      // 这里宁可「找不到就提示不够」，也不要「连提示都不出」。
      expect(normalizeTurnAnchor('turn_1'), 'turn_1');
      expect(normalizeTurnAnchor('TURN_1'), 'turn_1');
      expect(
        normalizeTurnAnchor('zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'),
        'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
      );
    });
  });

  group('findTurnIndex / turnAnchorItemId', () {
    final items = <ConversationItem>[
      _user('e1', idA, '第一轮'),
      _assistant('e2', idA, '回复 A'),
      _assistant('e3', '', '无归属'),
      _user('e4', idB, '第二轮'),
      _assistant('e5', idB, '回复 B'),
    ];

    test('返回该轮第一项的下标', () {
      expect(findTurnIndex(items, idA), 0);
      expect(findTurnIndex(items, idB), 3);
    });

    test('规范化后比较（大小写/连字符不影响命中）', () {
      const dashed = '01234567-89ab-cdef-0123-456789abcdef';
      final list = <ConversationItem>[_user('e1', idA, 'x')];
      expect(findTurnIndex(list, dashed), 0);
      expect(findTurnIndex(list, idA.toUpperCase()), 0);
      expect(turnAnchorItemId(list, dashed), 'e1');
    });

    test('不在已加载区间返回 -1 / null', () {
      expect(findTurnIndex(items, idC), -1);
      expect(findTurnIndex(items, ''), -1);
      expect(turnAnchorItemId(items, idC), isNull);
      expect(turnAnchorItemId(items, null), isNull);
      expect(findTurnIndex(const [], idA), -1);
    });

    test('行主键取该轮首个「已确认且有 id」的项', () {
      expect(turnAnchorItemId(items, idA), 'e1');
      expect(turnAnchorItemId(items, idB), 'e4');
    });

    test('跳过空 id；只有发送中的回显时退回它', () {
      final sending = <ConversationItem>[
        _user('', idC, '正在发送'),
        _assistant('e9', idC, '回复'),
      ];
      // 空 id 不是稳定行键 → 落到下一项
      expect(turnAnchorItemId(sending, idC), 'e9');

      final onlyPending = <ConversationItem>[
        _user('local:1', idC, '正在发送', pending: true),
      ];
      // 全部不合格时退回候选，而不是返回 null（否则「点了没反应」）
      expect(turnAnchorItemId(onlyPending, idC), 'local:1');
    });
  });

  group('isLatestTurn', () {
    test('目标之后没有别的轮次 → true', () {
      final items = <ConversationItem>[
        _user('e1', idA, '第一轮'),
        _assistant('e2', idA, '回复 A'),
        _user('e3', idB, '第二轮'),
        _assistant('e4', idB, '回复 B'),
      ];
      expect(isLatestTurn(items, idB), isTrue);
      expect(isLatestTurn(items, idA), isFalse);
    });

    test('无归属项（空 turnId）不影响判定', () {
      final items = <ConversationItem>[
        _user('e1', idA, '第一轮'),
        _assistant('e2', idA, '回复 A'),
        _assistant('e3', '', '无归属的确认卡'),
      ];
      // 关键：否则「跳到最新」会意外进入锚点态（高亮 + 关掉跟随）
      expect(isLatestTurn(items, idA), isTrue);
    });

    test('不在已加载区间 → false（由调用方走 missing 分支）', () {
      final items = <ConversationItem>[_user('e1', idA, 'x')];
      expect(isLatestTurn(items, idC), isFalse);
      expect(isLatestTurn(items, null), isFalse);
      expect(isLatestTurn(const [], idA), isFalse);
    });
  });
}

UserMessageItem _user(
  String id,
  String turnId,
  String text, {
  bool pending = false,
}) => UserMessageItem(
  id: id,
  createdAt: DateTime.utc(2024, 3, 5, 8, 9, 10),
  text: text,
  turnId: turnId,
  pending: pending,
);

AssistantMessageItem _assistant(String id, String turnId, String text) =>
    AssistantMessageItem(
      id: id,
      createdAt: DateTime.utc(2024, 3, 5, 8, 9, 11),
      text: text,
      turnId: turnId,
    );
