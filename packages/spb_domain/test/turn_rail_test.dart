import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';

/// 轮次导航条数据投影的纯逻辑回归（§6.94）。
///
/// ## 这个文件防的是什么
///
/// 刻度条的价值全在「它与消息流是同一份历史的两种视图」：顺序错一位，用户按
/// 刻度上下来回穿梭时会发现相邻两格在正文里也是反的；标签取错一条消息，面板
/// 里显示的就是**别人那一轮**的问题——两者都不抛异常、不报日志，只是「点了
/// 跳到一个好像不是这里的地方」。
///
/// 故这里钉住四件事：顺序（旧 → 新）、标签口径（该轮**最后**一条用户消息）、
/// 截断与折叠、以及无归属项不进目录。
void main() {
  const turnA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const turnB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const turnC = 'cccccccccccccccccccccccccccccccc';

  UserMessageItem user(String id, String turnId, String text, {int sec = 0}) =>
      UserMessageItem(
        id: id,
        createdAt: DateTime.utc(2026, 3, 5, 12, 0, sec),
        text: text,
        turnId: turnId,
      );

  AssistantMessageItem reply(String id, String turnId, {int sec = 0}) =>
      AssistantMessageItem(
        id: id,
        createdAt: DateTime.utc(2026, 3, 5, 12, 0, sec),
        text: '回复正文不该进标签',
        turnId: turnId,
      );

  group('buildTurnRailEntries', () {
    test('按消息流顺序（旧 → 新）投影，序号从 1 起、最后一轮标 isLatest', () {
      final entries = buildTurnRailEntries([
        user('u1', turnA, '第一个问题', sec: 1),
        reply('a1', turnA, sec: 2),
        user('u2', turnB, '第二个问题', sec: 3),
        reply('a2', turnB, sec: 4),
        user('u3', turnC, '第三个问题', sec: 5),
      ]);

      expect(entries.map((e) => e.turnId), [turnA, turnB, turnC]);
      expect(entries.map((e) => e.index), [1, 2, 3]);
      expect(entries.map((e) => e.label), ['第一个问题', '第二个问题', '第三个问题']);
      expect(entries.map((e) => e.isLatest), [false, false, true]);
    });

    test('标签取该轮**最后**一条用户消息（服务端重发时取最完整那份）', () {
      final entries = buildTurnRailEntries([
        user('u1', turnA, '短', sec: 1),
        user('u2', turnA, '重发后的完整问题', sec: 2),
      ]);

      expect(entries.single.label, '重发后的完整问题');
    });

    test('createdAt 取该轮第一条项的时间（与 TurnGroup 同口径）', () {
      final entries = buildTurnRailEntries([
        user('u1', turnA, '问题', sec: 7),
        reply('a1', turnA, sec: 19),
      ]);

      expect(entries.single.createdAt, DateTime.utc(2026, 3, 5, 12, 0, 7));
    });

    test('没有用户消息的轮次给出占位标签，而不是空行', () {
      final entries = buildTurnRailEntries([reply('a1', turnA)]);

      expect(entries.single.label, kTurnRailEmptyLabel);
    });

    test('turnId 归一后为 null 的项不进目录（无归属项点不进任何地方）', () {
      final entries = buildTurnRailEntries([
        user('u0', '', '无归属的提交'),
        user('u1', turnA, '正常问题', sec: 1),
      ]);

      expect(entries.map((e) => e.turnId), [turnA]);
    });

    test('turnId 写法差异（大写 / 带连字符）归一到同一格', () {
      final entries = buildTurnRailEntries([
        user('u1', turnA, '第一段', sec: 1),
        user('u2', 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA', '同一轮', sec: 2),
      ]);

      expect(entries.length, 1);
      expect(entries.single.label, '同一轮');
    });

    test('空输入返回空列表（不是一格占位）', () {
      expect(buildTurnRailEntries(const <ConversationItem>[]), isEmpty);
    });

    test('maxChars 由调用方决定：只影响标签，不影响格数', () {
      final entries = buildTurnRailEntries([
        user('u1', turnA, '一二三四五六七八九十', sec: 1),
        user('u2', turnB, '另一轮', sec: 2),
      ], maxChars: 4);

      expect(entries.map((e) => e.label), ['一二三四…', '另一轮']);
      expect(entries.length, 2);
    });
  });

  group('truncateTurnLabel', () {
    test('折叠换行与连续空白：多段文本只占一行', () {
      expect(truncateTurnLabel('第一行\n\n第二行\t 第三行'), '第一行 第二行 第三行');
    });

    test('等于上限时不加省略号（刚好 24 字不带 …）', () {
      final exactly = '字' * kTurnRailLabelMaxChars;

      final longer = '$exactly多';

      expect(truncateTurnLabel(exactly), exactly);
      expect(
        truncateTurnLabel(longer),
        '${exactly.substring(0, kTurnRailLabelMaxChars)}…',
      );
    });

    test('按码位截断：不切碎代理对（emoji 不出现乱码）', () {
      // 每个 emoji 是「代理对」：用 substring 截 3 个 code unit 会切碎它。
      final label = truncateTurnLabel('😀😀😀', maxChars: 2);

      expect(label, '😀😀…');
      expect(label.contains('\uFFFD'), isFalse);
    });

    test('空白与空串归一成空标签', () {
      expect(truncateTurnLabel('   \n\t '), '');
      expect(truncateTurnLabel(''), '');
    });
  });

  group('turnIdOfRow', () {
    test('三种行形态都取到自己的轮次，并归一化', () {
      final single = SingleItemRow(user('u1', turnA.toUpperCase(), '问题'));
      final fileRow = AgentFileBatchRow(
        files: [
          AgentFileItem(
            id: 'f1',
            createdAt: DateTime.utc(2026),
            turnId: turnB,
            relativePath: 'grp_1/a.png',
            fileName: 'a.png',
            displayName: 'a.png',
            action: 'created',
            ufsFileId: 'ufs_1',
          ),
        ],
        verb: '生成',
      );

      expect(turnIdOfRow(single), turnA);
      expect(turnIdOfRow(fileRow), turnB);
    });

    test('无归属项返回 null（不伪造一个轮次）', () {
      expect(turnIdOfRow(SingleItemRow(user('u1', '', '无归属'))), isNull);
    });
  });
}
