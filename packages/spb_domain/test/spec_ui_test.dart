import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// [parseSpecUi] 的解析正确性与安全边界测试。
///
/// ## fixture 来源（逐字段照抄服务端代码，非推测）
///
/// - goal_gate：`chatgate/goal_gate_spec.go` buildTaskSpec（type 小写、
///   元素体内无 id 字段、无动作）；
/// - follow_up：`chatgate/followup_suggest.go` BuildFollowUpSpecJSON
///   （type 首字母大写、动作在 `on.click[]`、字段名 `action`、params 带
///   text/label/agent_id）；
/// - classify_feedback：`chatpipeline/classify_feedback.go`
///   BuildClassifyFeedbackSpecJSON（动作在 `actions[]`、字段名 `type`、
///   带 nextInput）。
///
/// 三个生产者连「动作字段叫 action 还是 type」都不一致——这些形状差异没有
/// 契约保证，解析器对**任何一种**的误判都会让卡片静默丢按钮。
void main() {
  /// goal_gate_decision 的 spec_schema（buildTaskSpec 真实产出，截取渲染所需）。
  Map<String, dynamic> goalGateSpec() => {
    'root': 'goal-card',
    'elements': {
      'goal-card': {
        'type': 'card',
        'props': {'title': '目标进度'},
        'children': ['goal-progress', 'goal-status'],
      },
      'goal-progress': {
        'type': 'progress',
        'props': {'value': 50, 'label': '1/2'},
      },
      'goal-status': {
        'type': 'metric',
        'props': {'label': '状态 · 第 1/5 轮', 'value': '进行中', 'hint': '下一个：写文档'},
      },
    },
    'goal': '整理周报',
    'status': '进行中',
    '_order': ['goal-progress', 'goal-status'],
  };

  /// follow_up_suggested 的 spec_schema（BuildFollowUpSpecJSON 两条建议时）。
  Map<String, dynamic> followUpSpec() => {
    'root': 'follow-up-card',
    'elements': {
      'follow-up-card': {
        'id': 'follow-up-card',
        'type': 'Card',
        'props': {
          'title': '后续提问建议',
          'description': '基于本次对话，你可以继续追问',
          'variant': 'default',
        },
        'children': ['follow-up-title', 'follow-up-opt-0', 'follow-up-opt-1'],
        'on': {},
        'watch': {},
        'actions': [],
      },
      'follow-up-title': {
        'id': 'follow-up-title',
        'type': 'Text',
        'props': {'content': '点击复制问题，可修改后再发送'},
        'children': [],
        'on': {},
        'watch': {},
        'actions': [],
      },
      'follow-up-opt-0': {
        'id': 'follow-up-opt-0',
        'type': 'Button',
        'props': {'label': '总结要点', 'variant': 'outline', 'fullWidth': true},
        'children': [],
        'on': {
          'click': [
            {
              'action': 'copy_text',
              'params': {'text': '帮我总结要点', 'label': '总结要点'},
            },
          ],
        },
        'watch': {},
        'actions': [],
      },
      'follow-up-opt-1': {
        'id': 'follow-up-opt-1',
        'type': 'Button',
        'props': {'label': '查漏补缺', 'variant': 'outline', 'fullWidth': true},
        'children': [],
        'on': {
          'click': [
            {
              'action': 'copy_text',
              'params': {
                'text': '帮我查漏补缺',
                'label': '查漏补缺',
                'agent_id': 'agt_review',
              },
            },
          ],
        },
        'watch': {},
        'actions': [],
      },
    },
    'state': {},
  };

  /// routing_feedback_request 的 spec_schema（BuildClassifyFeedbackSpecJSON）。
  Map<String, dynamic> classifyFeedbackSpec() => {
    'root': 'classify-feedback-card',
    'elements': {
      'classify-feedback-card': {
        'id': 'classify-feedback-card',
        'type': 'Card',
        'props': {'title': '归属确认', 'description': '', 'variant': 'default'},
        'children': [
          'classify-feedback-title',
          'classify-feedback-ok',
          'classify-feedback-bad',
        ],
        'on': {},
        'watch': {},
        'actions': [],
      },
      'classify-feedback-title': {
        'id': 'classify-feedback-title',
        'type': 'Text',
        'props': {'content': '这条消息我归到了《团队周报》，准确吗？'},
        'children': [],
        'on': {},
        'watch': {},
        'actions': [],
      },
      'classify-feedback-ok': {
        'id': 'classify-feedback-ok',
        'type': 'Button',
        'props': {'label': '准确', 'variant': 'default'},
        'children': [],
        'on': {},
        'watch': {},
        'actions': [
          {'type': 'send_next_input', 'label': '准确', 'nextInput': '反馈#正确'},
        ],
      },
      'classify-feedback-bad': {
        'id': 'classify-feedback-bad',
        'type': 'Button',
        'props': {'label': '不准确', 'variant': 'outline'},
        'children': [],
        'on': {},
        'watch': {},
        'actions': [
          {'type': 'send_next_input', 'label': '不准确', 'nextInput': '反馈#tok#错误'},
        ],
      },
    },
    'state': {'classify_feedback': true, 'token': 'tok'},
  };

  group('goal_gate 进度卡（小写 type、无 id 字段）', () {
    test('root 与元素齐全，type 小写也能识别', () {
      final doc = parseSpecUi(goalGateSpec());

      expect(doc, isNotNull);
      expect(doc!.rootId, 'goal-card');
      expect(doc.elements, hasLength(3));
      expect(doc.root!.type, SpecUiType.card);
      expect(doc.root!.prop('title'), '目标进度');
    });

    test('元素 id 取 map 键（元素体内没有 id 字段）', () {
      final doc = parseSpecUi(goalGateSpec())!;

      expect(doc.elements.keys.toSet(), {
        'goal-card',
        'goal-progress',
        'goal-status',
      });
    });

    test('progress 与 metric 的 props 可读', () {
      final doc = parseSpecUi(goalGateSpec())!;
      final children = doc.childrenOf(doc.root!);

      expect(children, hasLength(2));
      expect(children[0].type, SpecUiType.progress);
      expect(children[0].propNum('value'), 50);
      expect(children[0].prop('label'), '1/2');
      expect(children[1].type, SpecUiType.metric);
      expect(children[1].prop('value'), '进行中');
      expect(children[1].prop('hint'), '下一个：写文档');
    });
  });

  group('follow_up 建议卡（大写 type、动作在 on.click）', () {
    test('Card/Text/Button 大写 type 识别为同一白名单', () {
      final doc = parseSpecUi(followUpSpec())!;

      expect(doc.root!.type, SpecUiType.card);
      final children = doc.childrenOf(doc.root!);
      expect(children[0].type, SpecUiType.text);
      expect(children[1].type, SpecUiType.button);
      expect(children[1].prop('label'), '总结要点');
    });

    test('on.click[] 里的 copy_text 动作被解析（字段名 action）', () {
      final doc = parseSpecUi(followUpSpec())!;
      final buttons = doc
          .childrenOf(doc.root!)
          .where((e) => e.type == SpecUiType.button)
          .toList();

      final a0 = buttons[0].actions.single;
      expect(a0.type, SpecUiActionType.copyText);
      expect(a0.text, '帮我总结要点');
      expect(a0.label, '总结要点');
      expect(a0.agentId, '', reason: '历史建议无 agent_id（omitempty）');
    });

    test('params 里的 agent_id 被解析（按建议追问时切 agent 用）', () {
      final doc = parseSpecUi(followUpSpec())!;
      final buttons = doc
          .childrenOf(doc.root!)
          .where((e) => e.type == SpecUiType.button)
          .toList();

      expect(buttons[1].actions.single.agentId, 'agt_review');
    });
  });

  group('classify_feedback 反馈卡（动作在 actions[]，字段名 type）', () {
    test('actions[] 里的 send_next_input 被解析（字段名 type，与 on.click 不同）', () {
      final doc = parseSpecUi(classifyFeedbackSpec())!;
      final buttons = doc
          .childrenOf(doc.root!)
          .where((e) => e.type == SpecUiType.button)
          .toList();

      final ok = buttons[0].actions.single;
      expect(ok.type, SpecUiActionType.sendNextInput);
      expect(ok.nextInput, '反馈#正确');
      expect(ok.label, '准确');

      final bad = buttons[1].actions.single;
      expect(bad.type, SpecUiActionType.sendNextInput);
      expect(bad.nextInput, '反馈#tok#错误');
    });
  });

  group('降级（不抛异常是硬约束）', () {
    test('未知 type 解析为 unknown，不影响其余元素', () {
      final doc = parseSpecUi({
        'root': 'r',
        'elements': {
          'r': {
            'type': 'card',
            'children': ['a', 'b'],
          },
          'a': {'type': 'hologram_3d'},
          'b': {'type': 'text'},
        },
      })!;

      final children = doc.childrenOf(doc.root!);
      expect(children[0].type, SpecUiType.unknown);
      expect(children[1].type, SpecUiType.text);
    });

    test('悬空 children 指向不存在的元素 → 遍历时跳过', () {
      final doc = parseSpecUi({
        'root': 'r',
        'elements': {
          'r': {
            'type': 'card',
            'children': ['ghost', 'real'],
          },
          'real': {'type': 'text'},
        },
      })!;

      final children = doc.childrenOf(doc.root!);
      expect(children.map((e) => e.id), ['real']);
    });

    test('悬空 root → root 为 null（文档本身可解析）', () {
      final doc = parseSpecUi({
        'root': 'missing',
        'elements': {
          'a': {'type': 'text'},
        },
      })!;

      expect(doc.root, isNull);
      expect(doc.elements, hasLength(1));
    });

    test('自环（A 的 children 指回 A）不无限循环', () {
      final doc = parseSpecUi({
        'root': 'a',
        'elements': {
          'a': {
            'type': 'card',
            'children': ['a', 'b'],
          },
          'b': {'type': 'text'},
        },
      })!;

      expect(
        () => doc.childrenOf(doc.root!),
        returnsNormally,
        reason: '环引用必须被 visited 集合掐断，而不是栈溢出',
      );
      expect(doc.childrenOf(doc.root!), hasLength(1));
    });

    test('互相成环（A→B→A）不无限循环', () {
      final doc = parseSpecUi({
        'root': 'a',
        'elements': {
          'a': {
            'type': 'card',
            'children': ['b'],
          },
          'b': {
            'type': 'card',
            'children': ['a'],
          },
        },
      })!;

      expect(() => doc.childrenOf(doc.root!), returnsNormally);
      expect(doc.childrenOf(doc.root!), hasLength(1));
    });

    test('深度超限按截断处理（默认上限 32）', () {
      // 造 60 层链：c0 → c1 → … → c59。
      final elements = <String, Object>{
        for (var i = 0; i < 60; i++)
          'c$i': {
            'type': 'card',
            'children': i < 59 ? ['c${i + 1}'] : <String>[],
          },
      };
      final doc = parseSpecUi({'root': 'c0', 'elements': elements})!;

      final flat = doc.childrenOf(doc.root!);
      expect(
        flat.length,
        lessThan(60),
        reason: '超深嵌套必须截断——服务端真实产出最多 3 层，余量 32 足够',
      );
    });

    test('null / 非 Map / 缺关键字段的输入返回 null', () {
      expect(parseSpecUi(null), isNull);
      expect(parseSpecUi('not a spec'), isNull);
      expect(parseSpecUi({'root': 'r'}), isNull, reason: '缺 elements');
      expect(parseSpecUi({'elements': {}}), isNull, reason: '缺 root');
      expect(parseSpecUi({'root': 'r', 'elements': 'not-a-map'}), isNull);
    });

    test('形状不对的元素被跳过，不影响其余元素', () {
      final doc = parseSpecUi({
        'root': 'r',
        'elements': {
          'r': {
            'type': 'card',
            'children': ['bad', 'good'],
          },
          'bad': 'not-a-map',
          'good': {'type': 'text'},
        },
      })!;

      expect(doc.elements.containsKey('bad'), isFalse);
      expect(doc.childrenOf(doc.root!).map((e) => e.id), ['good']);
    });

    test('props 非法形状降级为空表（不抛）', () {
      final doc = parseSpecUi({
        'root': 'r',
        'elements': {
          'r': {'type': 'card', 'props': 'not-a-map'},
        },
      })!;

      expect(doc.root!.props, isEmpty);
      expect(doc.root!.prop('title'), '');
    });

    test('children 混入非字符串项被丢弃', () {
      final doc = parseSpecUi({
        'root': 'r',
        'elements': {
          'r': {
            'type': 'card',
            'children': [123, null, 'ok'],
          },
          'ok': {'type': 'text'},
        },
      })!;

      expect(doc.root!.childIds, ['ok']);
    });
  });

  group('SpecUiType.from（大小写不敏感）', () {
    test('三种大小写形态映射到同一白名单项', () {
      expect(SpecUiType.from('Card'), SpecUiType.card);
      expect(SpecUiType.from('card'), SpecUiType.card);
      expect(SpecUiType.from('BUTTON'), SpecUiType.button);
      expect(SpecUiType.from('ListItem'), SpecUiType.listItem);
    });

    test('null / 未知值 → unknown（不抛）', () {
      expect(SpecUiType.from(null), SpecUiType.unknown);
      expect(SpecUiType.from('hologram_3d'), SpecUiType.unknown);
    });
  });
}
