import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import '../support/golden_fonts.dart';

/// `spb_features` 里**纯展示、不依赖平台能力**的组件的 golden（issue #25）。
///
/// ## 为什么只挑 `SpecUiCard`（而不是把 features 铺满）
///
/// issue #25 明确点名了「spec 卡」——它是本仓库**唯一由服务端 JSON 驱动**的
/// 渲染器（`JsonUiSchema`），元素 type 有 12 种、每种的排版各不相同。它改错的
/// 代价高（服务端加一个 type，客户端渲染错了没人会发现——因为单测断言的是
/// 「渲染了哪个 widget」而不是「长得对不对」）。
///
/// `spb_features` 的其它组件（对话时间线、侧边栏、面板）**不**加 golden：
/// - 它们依赖大量回调与状态（`_ChatPageState` 的私有方法、Riverpod provider），
///   构造完整场景的成本远超收益；
/// - 它们大多有详细的行为单测（`spb_features` 行覆盖率 **93.7%**，见
///   `tools/coverage.sh` 的输出）。
///
/// ## 基线里中文是 tofu（空心方块）——预期行为
///
/// SDK 不带 CJK 字体。golden 锁的是**布局**（元素位置、间距、徽标形状、进度条
/// 长度），这些维度上 tofu 与真字形一致。看懂文案的断言在
/// `spec_ui_card_test.dart` 里用 `find.text` 做。
///
/// ## 更新基线
///
/// ```bash
/// cd packages/spb_features
/// flutter test --update-goldens test/chat/golden_test.dart
/// ```
void main() {
  setUpAll(loadGoldenFonts);

  Widget host(Widget child, {Size size = const Size(360, 260)}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: SpbTheme.light(),
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Material(child: Center(child: child)),
          ),
        ),
      ),
    ),
  );

  group('SpecUiCard golden（issue #25）', () {
    testWidgets('goal_gate 目标卡：card + progress + metric 的组合排版', (tester) async {
      // 形状取自 `chatgate/goal_gate_spec.go` 的 buildTaskSpec（见
      // `spec_ui_card_test.dart` 的 goalGateSpec）。
      await tester.pumpWidget(
        host(
          SpecUiCard(
            doc: parseSpecUi({
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
                  'props': {
                    'label': '状态 · 第 1/5 轮',
                    'value': '进行中',
                    'hint': '下一个：写文档',
                  },
                },
              },
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(SpecUiCard),
        matchesGoldenFile('goldens/spec_ui_goal_card.png'),
      );
    });

    testWidgets('follow_up 建议卡：按钮列表（多行动作）', (tester) async {
      await tester.pumpWidget(
        host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'follow-up-card',
              'elements': {
                'follow-up-card': {
                  'id': 'follow-up-card',
                  'type': 'Card',
                  'props': {'title': '后续提问建议', 'description': '基于本次对话，你可以继续追问'},
                  'children': ['follow-up-opt-0', 'follow-up-opt-1'],
                  'on': <String, dynamic>{},
                  'actions': <dynamic>[],
                },
                'follow-up-opt-0': {
                  'type': 'button',
                  'props': {'label': '把这个过程写成文档'},
                  'on': {'press': 'copy_text'},
                  'actions': [
                    {'type': 'copy_text', 'text': '把这个过程写成文档'},
                  ],
                },
                'follow-up-opt-1': {
                  'type': 'button',
                  'props': {'label': '再补充一下边界条件'},
                  'on': {'press': 'send_next_input'},
                  'actions': [
                    {'type': 'send_next_input', 'text': '再补充一下边界条件'},
                  ],
                },
              },
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(SpecUiCard),
        matchesGoldenFile('goldens/spec_ui_follow_up_card.png'),
      );
    });

    testWidgets('未知 type 降级为占位（不崩、不留白）', (tester) async {
      // 服务端将来新增 type 时，老客户端必须「照常渲染其它部分」——
      // 这条基线锁的是降级占位的**尺寸**（不能是 0 高，否则布局会跳）。
      await tester.pumpWidget(
        host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'root',
              'elements': {
                'root': {
                  'type': 'card',
                  'props': {'title': '未知元素'},
                  'children': ['unknown-1'],
                },
                'unknown-1': {
                  'type': 'future_widget_that_does_not_exist',
                  'props': {'foo': 'bar'},
                },
              },
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(SpecUiCard),
        matchesGoldenFile('goldens/spec_ui_unknown_type.png'),
      );
    });
  });

  group('MapSpecCard golden（issue #12）', () {
    /// 真实产物：`super_partyb` 生产 workspace 的
    /// `reports/route-changban-dashadong.map.spec.json`。
    Map<String, dynamic> realMapSpec() => {
      'type': 'map',
      'version': '1',
      'title': '公交路线',
      'description': '公交路线，共 5 个方案',
      'markers': [
        {
          'id': 'marker-1',
          'longitude': 113.349324,
          'latitude': 23.178369,
          'title': '起点',
        },
        {
          'id': 'marker-2',
          'longitude': 113.458515,
          'latitude': 23.106216,
          'title': '终点',
        },
      ],
      'routes': [
        {
          'id': 'route-1',
          'mode': 'transfer',
          'title': '公交路线',
          'distanceMeters': 12400,
          'durationSeconds': 3300,
          'polyline': [
            [113.349324, 23.178369],
            [113.458515, 23.106216],
          ],
        },
      ],
    };

    testWidgets('真实产物：轨迹图 + 路线 + 地点', (tester) async {
      // 尺寸要装得下 560×300 的轨迹图加下方列表；用宽屏，跟真实预览
      // 对话框的宽度同量级。
      await tester.pumpWidget(
        host(
          MapSpecCard(schema: parseMapSchema(realMapSpec())!),
          size: const Size(600, 620),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MapSpecCard),
        matchesGoldenFile('goldens/map_spec_card.png'),
      );
    });
  });
}
