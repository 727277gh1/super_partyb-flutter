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
      'on': <String, dynamic>{},
      'actions': <dynamic>[],
    },
    'follow-up-title': {
      'id': 'follow-up-title',
      'type': 'Text',
      'props': {'content': '点击复制问题，可修改后再发送'},
      'children': <dynamic>[],
      'on': <String, dynamic>{},
      'actions': <dynamic>[],
    },
    'follow-up-opt-0': {
      'id': 'follow-up-opt-0',
      'type': 'Button',
      'props': {'label': '总结要点'},
      'children': <dynamic>[],
      'on': {
        'click': [
          {
            'action': 'copy_text',
            'params': {'text': '帮我总结要点', 'label': '总结要点'},
          },
        ],
      },
      'actions': <dynamic>[],
    },
    'follow-up-opt-1': {
      'id': 'follow-up-opt-1',
      'type': 'Button',
      'props': {'label': '查漏补缺'},
      'children': <dynamic>[],
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
      'actions': <dynamic>[],
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
    testWidgets('未知**叶子**渲染占位（带原始 type 名），同卡片的已知元素照常渲染', (tester) async {
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

      // issue #27：占位符必须打印**原始 type 字符串**。此前打印 `type.name`，
      // 而枚举把 Stack/Grid/Chart 全部塌缩成 `unknown`——诊断价值为零。
      expect(find.text('（不支持的组件类型：hologram_3d）'), findsOneWidget);
      expect(find.text('（不支持的组件类型：unknown）'), findsNothing);
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

    // 以下两组用例对应 issue #27 核实过程中发现的**既有缺陷**——它们不是 #27
    // 引入的，而是 #27 要修的那条路径（递归下钻）暴露出来的前置条件。

    testWidgets('互相成环的**容器**不无限递归（A→B→A）', (tester) async {
      // ## 这个测试防的是什么
      //
      // 解析层的 `visited` 只保护 `childrenOf`，**保护不到渲染层的递归**。
      // 改成递归下钻后，两个互相引用的未知容器会让 build 无限递归：实测在
      // 修复前直接挂死（测试永不完成）。故渲染路径必须自带祖先集合。
      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'a',
              'elements': {
                'a': {
                  'type': 'Stack',
                  'children': ['b'],
                },
                'b': {
                  'type': 'Grid',
                  'children': ['a'],
                },
              },
            }),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('嵌套容器不重复渲染深层叶子', (tester) async {
      // ## 这个测试防的是什么
      //
      // 渲染器曾用 `childrenOf`（**整棵子树的扁平列表**）作为「直接子元素」，
      // 而对每个子元素又递归一次——两者叠加让深层元素渲染多次。实测：
      // 3 层树（card → list → text）里叶子出现 **2 次**。
      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'a',
              'elements': {
                'a': {
                  'type': 'card',
                  'props': {'title': 'A'},
                  'children': ['b'],
                },
                'b': {
                  'type': 'list',
                  'children': ['c'],
                },
                'c': {
                  'type': 'text',
                  'props': {'content': '叶子X'},
                },
              },
            }),
          ),
        ),
      );

      expect(
        find.text('叶子X'),
        findsOneWidget,
        reason: '若为 2 则说明「扁平子树 + 逐项递归」叠加导致重复渲染',
      );
    });

    testWidgets('自引用容器不无限递归（A→A）', (tester) async {
      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'a',
              'elements': {
                'a': {
                  'type': 'Stack',
                  'props': {'title': '自引用'},
                  'children': ['a'],
                },
              },
            }),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  // ==========================================================================
  // issue #27：真实生产看板（#14 回归）
  // ==========================================================================

  group('真实生产看板（issue #27 回归）', () {
    /// `super_partyb` `apps/miniapp/src/lib/spec-demo-fixtures.ts` 的
    /// `realDashboardDoc`（注释自称「bcc 工作区实际产出的 dashboard.spec.json
    /// 回归基准」）的 Dart 镜像。
    ///
    /// 形状要点：root 是 `Stack`、其下 `Grid`——**两者都不在白名单**；
    /// 真正的数据在 `Metric` / `Alert`（白名单内）。
    Map<String, dynamic> realDashboardSpec() => {
      'root': 'dashboard',
      'elements': {
        'dashboard': {
          'type': 'Stack',
          'props': {'direction': 'vertical', 'gap': 'md'},
          'children': ['kpi-row', 'trend-chart', 'alert-box', 'data-table'],
        },
        'kpi-row': {
          'type': 'Grid',
          'props': {'columns': 3, 'gap': 'md'},
          'children': ['kpi-sh', 'kpi-sz', 'kpi-cyb'],
        },
        'kpi-sh': {
          'type': 'Metric',
          'props': {
            'title': '上证指数',
            'value': '3864.37',
            'trend': 'down',
            'change': '−0.47%',
            'description': '7/21 收盘',
          },
          'children': <String>[],
        },
        'kpi-sz': {
          'type': 'Metric',
          'props': {
            'title': '深证成指',
            'value': '14264.29',
            'trend': 'down',
            'change': '−1.23%',
          },
          'children': <String>[],
        },
        'kpi-cyb': {
          'type': 'Metric',
          'props': {
            'title': '创业板指',
            'value': '3685.97',
            'trend': 'down',
            'change': '−0.16%',
          },
          'children': <String>[],
        },
        'trend-chart': {
          'type': 'Chart',
          'props': {'title': '三大指数近4日收盘走势', 'chartType': 'line'},
          'children': <String>[],
        },
        'alert-box': {
          'type': 'Alert',
          'props': {'title': '关键信号', 'message': '7/17 单日急跌，随后两日震荡修复。'},
          'children': <String>[],
        },
        'data-table': {
          'type': 'Table',
          'props': {'title': '收盘明细', 'pageSize': 5},
          'children': <String>[],
        },
      },
    };

    testWidgets('未知容器不阻断子树：白名单叶子照常渲染', (tester) async {
      await tester.pumpWidget(
        _host(SpecUiCard(doc: parseSpecUi(realDashboardSpec()))),
      );

      // ## 这个断言就是 #14 的回归本身
      //
      // 修复前整棵树的可见文本只有 `[（不支持的组件类型：unknown）]`——
      // 因为 root 是 Stack（未知）→ 直接截断，下面的 Metric 全部消失。
      expect(find.text('上证指数'), findsOneWidget);
      expect(find.text('3864.37'), findsOneWidget);
      expect(find.text('深证成指'), findsOneWidget);
      expect(find.text('14264.29'), findsOneWidget);
      expect(find.text('创业板指'), findsOneWidget);
      expect(find.text('3685.97'), findsOneWidget);

      // 白名单内的 Alert 也照常渲染。
      expect(find.text('7/17 单日急跌，随后两日震荡修复。'), findsOneWidget);
    });

    testWidgets('未知**叶子**（Chart / Table）渲染占位并打印原始类型名', (tester) async {
      await tester.pumpWidget(
        _host(SpecUiCard(doc: parseSpecUi(realDashboardSpec()))),
      );

      // Stack / Grid 是容器 → 下钻，不留占位。
      expect(find.text('（不支持的组件类型：Stack）'), findsNothing);
      expect(find.text('（不支持的组件类型：Grid）'), findsNothing);

      // Chart / Table 是叶子 → 留占位，且必须打印**原始**类型名。
      expect(find.text('（不支持的组件类型：Chart）'), findsOneWidget);
      expect(find.text('（不支持的组件类型：Table）'), findsOneWidget);
    });

    testWidgets('成环 / 超深的真实看板形态不崩', (tester) async {
      // 真实看板本身无环；这里补一个「真实形状 + 环」的混合输入，确认新递归
      // 路径不会因深度/环而炸（#27 验收标准 4）。
      await tester.pumpWidget(
        _host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'dashboard',
              'elements': {
                'dashboard': {
                  'type': 'Stack',
                  'children': ['kpi-row', 'dashboard'],
                },
                'kpi-row': {
                  'type': 'Grid',
                  'children': ['kpi-sh'],
                },
                'kpi-sh': {
                  'type': 'Metric',
                  'props': {'title': '上证指数', 'value': '3864.37'},
                },
              },
            }),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('上证指数'), findsOneWidget);
    });
  });
}
