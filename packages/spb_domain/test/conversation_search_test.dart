import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// [searchConversationItems] 的正确性测试。
///
/// 纯函数（无 IO、无 Flutter），故可无头单测——这正是它放在 `spb_domain`
/// 而不是页面里的理由。
void main() {
  final t0 = DateTime.utc(2024, 3, 5, 8, 9);

  UserMessageItem user(String id, String text, {String turnId = 't1'}) =>
      UserMessageItem(id: id, createdAt: t0, text: text, turnId: turnId);

  AssistantMessageItem assistant(String id, String text) =>
      AssistantMessageItem(id: id, createdAt: t0, text: text);

  ThoughtItem thought(String id, String text) =>
      ThoughtItem(id: id, createdAt: t0, text: text);

  group('基本匹配', () {
    test('命中用户消息与 agent 回复（两类都搜）', () {
      final r = searchConversationItems([
        user('u1', '帮我看一下这个报错'),
        assistant('a1', '这个报错来自空指针'),
      ], '报错');

      expect(r.hits, hasLength(2));
      expect(r.hits.map((h) => h.itemId), ['u1', 'a1']);
      expect(r.totalMatches, 2);
      expect(r.truncated, isFalse);
    });

    test('不区分大小写（搜 error 命中 Error）', () {
      final r = searchConversationItems([
        assistant('a1', 'Error: connection refused'),
      ], 'error');

      expect(r.hits, hasLength(1));
      expect(r.hits.single.itemId, 'a1');
    });

    test('query 大小写原样保留（供展示），匹配长度按查询串', () {
      final r = searchConversationItems([
        assistant('a1', 'ERROR happened'),
      ], 'Error');

      expect(r.query, 'Error');
      expect(r.hits, hasLength(1));
      expect(r.hits.single.matchLength, 5);
    });

    test('query 前后空白被 trim', () {
      final r = searchConversationItems([
        assistant('a1', 'hello world'),
      ], '  world  ');

      expect(r.query, 'world');
      expect(r.hits, hasLength(1));
    });

    test('命中顺序按传入的 items 顺序（即时间线顺序）', () {
      final r = searchConversationItems([
        assistant('a1', 'x'),
        user('u1', 'x'),
        assistant('a2', 'x'),
      ], 'x');

      expect(r.hits.map((h) => h.itemId), ['a1', 'u1', 'a2']);
    });
  });

  group('空查询', () {
    test('空串返回空结果', () {
      final r = searchConversationItems([user('u1', 'hello')], '');
      expect(r.hits, isEmpty);
      expect(r.totalMatches, 0);
      expect(r.truncated, isFalse);
    });

    test('全空白视为空查询', () {
      final r = searchConversationItems([user('u1', 'hello')], '   \n\t ');
      expect(r.hits, isEmpty);
      expect(r.totalMatches, 0);
    });

    test('空查询不误报 upperHistoryUnloaded', () {
      final r = searchConversationItems(
        [user('u1', 'hello')],
        '',
        upperHistoryUnloaded: true,
      );
      // empty() 的构造不带该标记：空查询没有「没搜到」的语义。
      expect(r.upperHistoryUnloaded, isFalse);
    });
  });

  group('可搜索的项类型', () {
    test('思考过程可搜', () {
      final r = searchConversationItems([thought('th1', '先看看目录结构')], '目录');
      expect(r.hits, hasLength(1));
    });

    test('工具调用：名称 / 参数 / 输出都能搜到', () {
      final items = [
        ToolCallItem(
          id: 'tc1',
          createdAt: t0,
          name: 'bash',
          args: {'command': 'npm test'},
          output: 'All tests passed',
        ),
      ];

      expect(searchConversationItems(items, 'bash').hits, hasLength(1));
      expect(searchConversationItems(items, 'npm test').hits, hasLength(1));
      expect(searchConversationItems(items, 'passed').hits, hasLength(1));
    });

    test('工具调用：args/output 为 null 时不炸（只搜名称）', () {
      final items = [ToolCallItem(id: 'tc1', createdAt: t0, name: 'read_file')];

      expect(searchConversationItems(items, 'read_file').hits, hasLength(1));
      expect(searchConversationItems(items, 'null').hits, isEmpty);
    });

    test('错误消息可搜', () {
      final r = searchConversationItems([
        ErrorItem(id: 'e1', createdAt: t0, message: '模型返回 429'),
      ], '429');
      expect(r.hits, hasLength(1));
    });

    test('诊断说明可搜', () {
      final r = searchConversationItems([
        DiagnosticNoticeItem(id: 'd1', createdAt: t0, content: '检测到失效的会话绑定'),
      ], '会话绑定');
      expect(r.hits, hasLength(1));
    });

    test('文件卡：展示名与真实文件名都能搜', () {
      final items = [
        AgentFileItem(
          id: 'f1',
          createdAt: t0,
          relativePath: 'reports/report.md',
          fileName: 'report.md',
          displayName: '季度报告',
          action: 'created',
        ),
      ];

      expect(searchConversationItems(items, '季度').hits, hasLength(1));
      expect(searchConversationItems(items, 'report.md').hits, hasLength(1));
    });

    test('文件卡：displayName == fileName 时不重复拼串', () {
      final items = [
        AgentFileItem(
          id: 'f1',
          createdAt: t0,
          relativePath: 'a.md',
          fileName: 'a.md',
          displayName: 'a.md',
          action: 'created',
        ),
      ];

      final r = searchConversationItems(items, 'a.md');
      // 拼接重复会让高亮长度/片段错位；断言片段里只出现一次。
      expect(r.hits.single.snippet, 'a.md');
    });

    test('交互控件（确认卡 / 反馈请求 / 建议）不参与搜索', () {
      final items = <ConversationItem>[
        ConfirmationItem(id: 'c1', createdAt: t0, question: '是否同意执行该操作'),
        FeedbackRequestItem(
          id: 'fb1',
          createdAt: t0,
          token: 'tok1',
          turnId: 't1',
          question: '再试一次',
        ),
        FollowUpSuggestionItem(
          id: 's1',
          createdAt: t0,
          suggestions: const ['再试一次'],
        ),
      ];

      // 「同意」只出现在确认卡上——不该被搜到（否则搜"同意"全是按钮文案）。
      expect(searchConversationItems(items, '同意').hits, isEmpty);
      expect(searchConversationItems(items, '再试一次').hits, isEmpty);
    });
  });

  group('片段截取与高亮位置', () {
    test('短文本不加省略号', () {
      final r = searchConversationItems([user('u1', 'hello world')], 'world');
      expect(r.hits.single.snippet, 'hello world');
      expect(r.hits.single.matchStart, 6);
    });

    test('长文本左侧截断时加前置省略号，且高亮位置已补偿', () {
      final long = '${'前' * 100}目标${'后' * 100}';
      final r = searchConversationItems([user('u1', long)], '目标');
      final hit = r.hits.single;

      expect(hit.snippet.startsWith('…'), isTrue);
      expect(hit.snippet.endsWith('…'), isTrue);
      // 关键：snippet[matchStart..matchStart+matchLength] 必须**就是**命中词。
      expect(
        hit.snippet.substring(hit.matchStart, hit.matchStart + hit.matchLength),
        '目标',
      );
    });

    test('命中在开头时不加前置省略号', () {
      final text = '目标${'后' * 100}';
      final r = searchConversationItems([user('u1', text)], '目标');
      expect(r.hits.single.snippet.startsWith('…'), isFalse);
      expect(r.hits.single.matchStart, 0);
    });

    test('命中在结尾时不加后置省略号', () {
      final text = '${'前' * 100}目标';
      final r = searchConversationItems([user('u1', text)], '目标');
      expect(r.hits.single.snippet.endsWith('…'), isFalse);
    });

    test('每个项只出一条命中（取首次出现）', () {
      final r = searchConversationItems([user('u1', 'x x x')], 'x');
      expect(r.hits, hasLength(1));
      expect(r.totalMatches, 1);
    });
  });

  group('字面量匹配（不当正则）', () {
    test('含正则元字符的查询按字面量处理', () {
      final r = searchConversationItems([
        user('u1', '调用 foo(a, b) 即可'),
      ], '(a, b)');

      expect(r.hits, hasLength(1));
    });

    test('单个左括号不报错（当正则会语法错误）', () {
      expect(
        () => searchConversationItems([user('u1', 'a ( b')], '('),
        returnsNormally,
      );
    });

    test('星号按字面量匹配，不当作通配', () {
      final r = searchConversationItems([
        user('u1', '文件 *.md'),
        user('u2', '没有星号'),
      ], '*.md');

      expect(r.hits, hasLength(1));
      expect(r.hits.single.itemId, 'u1');
    });
  });

  group('截断与完整性标记', () {
    test('超过 maxHits 时只返回前 N 条，totalMatches 仍为全量', () {
      final items = List.generate(5, (i) => user('u$i', 'hit me'));
      final r = searchConversationItems(items, 'hit', maxHits: 3);

      expect(r.hits, hasLength(3));
      expect(r.totalMatches, 5);
      expect(r.truncated, isTrue);
      expect(r.hits.map((h) => h.itemId), ['u0', 'u1', 'u2']);
    });

    test('刚好等于 maxHits 时不算截断', () {
      final items = List.generate(3, (i) => user('u$i', 'hit me'));
      final r = searchConversationItems(items, 'hit', maxHits: 3);

      expect(r.truncated, isFalse);
    });

    test('upperHistoryUnloaded 原样透传（「没找到」不等于「不存在」）', () {
      final r = searchConversationItems(
        [user('u1', 'hello')],
        'nonexistent',
        upperHistoryUnloaded: true,
      );

      expect(r.hits, isEmpty);
      expect(r.upperHistoryUnloaded, isTrue);
    });

    test('upperHistoryUnloaded 默认 false', () {
      final r = searchConversationItems([user('u1', 'hello')], 'hello');
      expect(r.upperHistoryUnloaded, isFalse);
    });
  });

  test('空 items 列表不炸', () {
    final r = searchConversationItems(const [], 'x');
    expect(r.hits, isEmpty);
    expect(r.totalMatches, 0);
  });
  test('前提：Dart 的 toLowerCase 长度不变（下标可直接互用）', () {
    // `searchConversationItems` 与小部件 `HighlightedText` 都依赖「小写串的
    // 下标 == 原文的下标」，才能用小写匹配的结果去切**原文**（保留原大小写）。
    //
    // 这成立是因为 Dart 的 `toLowerCase` 用**简单大小写映射**：每个码点独立
    // 转换、长度不变，不展开成多码点（如土耳其语 `İ` → `i̇`）。
    //
    // 本用例把这个前提钉住：若某次 Dart 升级改成完整映射，这里会失败，
    // 而报错信息会指向需要改成「双下标映射」的那两个文件。
    for (final s in ['İstanbul', 'ẞ', 'Ǆ', '中文ABC', 'straße', 'İİ']) {
      expect(
        s.toLowerCase().length,
        s.length,
        reason: 'toLowerCase 若改变长度，切片段的下标假设就不成立',
      );
    }
  });

  test('大小写不敏感匹配，且片段保留原文大小写', () {
    final r = searchConversationItems([user('u1', 'İstanbul 的行程')], 'stanbul');

    expect(r.hits, hasLength(1));
    // 片段取自原文，不是小写化的版本。
    expect(r.hits.single.snippet, contains('İstanbul'));
  });
}
