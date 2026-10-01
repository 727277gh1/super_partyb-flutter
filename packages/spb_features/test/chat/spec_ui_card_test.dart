import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 包一层 MaterialApp（组件依赖 Theme 与 Directionality）。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// goal_gate_decision 的 spec_schema（`chatgate/goal_gate_spec.go` buildTaskSpec）。
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
      'props': {'value': 40, 'label': '2/5'},
    },
    'goal-status': {
      'type': 'metric',
      'props': {'label': '状态 · 第 1/5 轮', 'value': '进行中', 'hint': '下一个：写文档'},
    },
  },
};

/// follow_up_suggested 的 spec_schema（两条建议，第二条带 agent_id）。
Map<String, dynamic> followUpSpec() => {
  'root': 'follow-up-card',
  'elements': {
    'follow-up-card': {
      'id': 'follow-up-card',
      'type': 'Card',
      'props': {'title': '后续提问建议', 'description': '基于本次对话，你可以继续追问'},
      'children': ['follow-up-title', 'follow-up-opt-0', 'follow-up-opt-1'],
      'on': {},
      'actions': [],
    },
    'follow-up-title': {
      'id': 'follow-up-title',
      'type': 'Text',
      'props': {'content': '点击复制问题，可修改后再发送'},
      'children': [],
      'on': {},
      'actions': [],
    },
    'follow-up-opt-0': {
      'id': 'follow-up-opt-0',
      'type': 'Button',
      'props': {'label': '总结要点'},
      'children': [],
      'on': {
        'click': [
          {
            'action': 'copy_text',
            'params': {'text': '帮我总结要点', 'label': '总结要点'},
          },
        ],
      },
      'actions': [],
    },
    'follow-up-opt-1': {
      'id': 'follow-up-opt-1',
      'type': 'Button',
      'props': {'label': '查漏补缺'},
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
      'actions': [],
    },
  },
};

void main() {
  group('目标进度卡（goal_gate spec）', () {
    testWidgets('渲染卡片标题、进度条与状态指标', (tester) async {
      await tester.pumpWidget(
        _host(SpecUiCard(doc: parseSpecUi(goalGateSpec()))),
      );

      expect(find.text('目标进度'), findsOneWidget);
      expect(find.byKey(const ValueKey('spec-progress-bar')), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('spec-progress-bar')),
            )
            .value,
        0.4,
      );
      expect(find.text('进行中'), findsOneWidget);
      expect(find.text('下一个：写文档'), findsOneWidget);
      expect(find.text('2/5'), findsOneWidget);
    });

    testWidgets('spec 为 null / root 悬空时不渲染（不崩）', (tester) async {
      await tester.pumpWidget(_host(const SpecUiCard(doc: null)));
      expect(find.byType(SpecUiCard), findsOneWidget);
      expect(find.text('目标进度'), findsNothing);

      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'missing',
              'elements': {
                'a': {'type': 'text'},
              },
            }),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing, reason: 'root 悬空应整体不渲染');
    });

    testWidgets('progress 的坏值被夹紧（0–100，不崩）', (tester) async {
      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'r',
              'elements': {
                'r': {
                  'type': 'card',
                  'children': ['p'],
                },
                'p': {
                  'type': 'progress',
                  'props': {'value': 300},
                },
              },
            }),
          ),
        ),
      );

      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('spec-progress-bar')),
            )
            .value,
        1.0,
        reason: '超界值必须夹紧到 1.0，否则 LinearProgressIndicator 断言失败',
      );
    });
  });

  group('建议列表卡（follow_up spec）', () {
    testWidgets('每条建议一个按钮，点击上抛 copy_text 动作', (tester) async {
      final seen = <SpecUiAction>[];
      await tester.pumpWidget(
        _host(SpecUiCard(doc: parseSpecUi(followUpSpec()), onAction: seen.add)),
      );

      expect(find.text('后续提问建议'), findsOneWidget);
      expect(find.text('点击复制问题，可修改后再发送'), findsOneWidget);
      expect(find.text('总结要点'), findsOneWidget);
      expect(find.text('查漏补缺'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('spec-button-总结要点')));
      await tester.pump();

      expect(seen, hasLength(1));
      expect(seen.single.type, SpecUiActionType.copyText);
      expect(seen.single.text, '帮我总结要点');
    });

    testWidgets('带 agent_id 的建议把 agent 一并上抛（点击时切 agent）', (tester) async {
      final seen = <SpecUiAction>[];
      await tester.pumpWidget(
        _host(SpecUiCard(doc: parseSpecUi(followUpSpec()), onAction: seen.add)),
      );

      await tester.tap(find.byKey(const ValueKey('spec-button-查漏补缺')));
      await tester.pump();

      expect(seen.single.agentId, 'agt_review');
    });

    testWidgets('onAction 为 null 时按钮禁用（只读展示）', (tester) async {
      await tester.pumpWidget(
        _host(SpecUiCard(doc: parseSpecUi(followUpSpec()))),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('spec-button-总结要点')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('降级（未知 type 不崩）', () {
    testWidgets('未知 type 渲染占位，同卡片的已知元素照常渲染', (tester) async {
      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'r',
              'elements': {
                'r': {
                  'type': 'card',
                  'props': {'title': '混合卡片'},
                  'children': ['u', 't'],
                },
                'u': {'type': 'hologram_3d'},
                't': {
                  'type': 'text',
                  'props': {'content': '正常文本'},
                },
              },
            }),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('spec-unknown-placeholder')),
        findsOneWidget,
      );
      expect(find.text('正常文本'), findsOneWidget);
      expect(find.text('混合卡片'), findsOneWidget);
    });

    testWidgets('成环的 spec 渲染不崩（解析层已掐断，渲染层跟着停）', (tester) async {
      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'a',
              'elements': {
                'a': {
                  'type': 'card',
                  'children': ['a', 'b'],
                },
                'b': {
                  'type': 'text',
                  'props': {'content': '叶子'},
                },
              },
            }),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('叶子'), findsOneWidget);
    });
  });
}
