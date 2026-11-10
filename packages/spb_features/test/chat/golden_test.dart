import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/golden_fonts.dart';

/// `spb_features` 里**纯展示、不依赖平台能力**的组件的 golden（issue #25）。
///
/// ## 为什么只挑 `SpecUiCard`（而不是把 features 铺满）
///
/// issue #25 明确点名了「spec 卡」——它是本仓库**唯一由服务端 JSON 驱动**的
/// 渲染器（`JsonUiSchema`），含多种元素类型、每种的排版各不相同。它改错的
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

    testWidgets('系统字号 2.0：画布上的标签跟着放大（§6.80）', (tester) async {
      // 画布标签是 `TextPainter` 手绘的，**不会**自动跟随系统字体缩放——
      // 曾经它固定 12px，于是 2 倍字号下「卡片文字变大、地图标签没变」。
      // 这张基线把「标签确实跟随缩放（且仍在 120px 宽内省略）」钉住：
      // 若哪天有人去掉 `textScaler`，标签会缩回 1 倍大小，这张图立刻变。
      tester.binding.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
      );

      // ⚠️ 两处高度都要放大，否则红的是**测试宿主**而不是卡片：
      // 1. 默认测试画布是 800×600（`tester.view`），比字号先撞天花板——
      //    不放开就会看到 `Column` 溢出 19px，误判成「卡片有 bug」；
      // 2. `host()` 的 SizedBox 也要更高（2.0 倍时卡片整体高 ~19px）。
      // 真实页面里卡片在可滚动的时间线里，不受这些上限约束。
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        host(
          MapSpecCard(schema: parseMapSchema(realMapSpec())!),
          size: const Size(600, 760),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MapSpecCard),
        matchesGoldenFile('goldens/map_spec_card_scale2.png'),
      );
    });
  });

  group('TurnDetailPanel golden（§6.78 / §6.79 / §6.82）', () {
    // 详情面板是**纯展示 + 数据驱动**（输入是已落库事件，无实时增量、无平台
    // 能力），正是 §6.13 说的「稳定 + 纯展示 + 改错代价高」那一类：
    //
    // - §6.78 把它当重灾区（8 处 11px），但改动**没有任何基线保护**；
    // - §6.79 的行高、§6.82 的正文档位都会改变它的排版；
    // - 它是排障视图，密度变化要是没人看得出来，用户读到的是「挤成一团」。
    //
    // 时间戳一律写死（`_formatTime` 是绝对时间，不读 `DateTime.now()`），
    // 否则基线每天都不一样。
    ChatTurn turn({
      String status = 'failed',
      int errorCount = 1,
      String? channel = '微信',
    }) => ChatTurn(
      id: 'turn_1',
      groupId: 'grp_1',
      userId: 'usr_1',
      inputText: '帮我看一下这个报错，日志里说工具调用失败了',
      status: status,
      fanoutCount: 1,
      completedCount: 2,
      errorCount: errorCount,
      channel: channel,
      createdAt: DateTime(2024, 3, 5, 12, 0),
    );

    ChatEvent event({
      required String eventType,
      int seq = 1,
      String source = 'agent',
      Map<String, dynamic>? payload,
    }) => ChatEvent(
      eventId: 'ev_$seq',
      userId: 'usr_1',
      groupId: 'grp_1',
      turnId: 'turn_1',
      eventType: eventType,
      seq: seq,
      source: source,
      createdAt: DateTime(2024, 3, 5, 12, 0, seq),
      payload: payload,
    );

    /// 面板是 `ListView`，高度由宿主给；宽度取「移动端宽屏 / 桌面窄窗」量级。
    ///
    /// ⚠️ 必须有 `Center`：`MaterialApp.home` 拿到的是**紧约束**（整屏），
    /// 少了它就等于 `SizedBox` 的宽高被忽略——基线会变成整屏尺寸，而且
    /// 「窄屏下文案怎么折行」这件事根本没被测到（第一版就是这样，diff 里
    /// 内容横跨 600px 才发现）。
    Widget detailHost(Widget child, {Size size = const Size(480, 720)}) =>
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: SpbTheme.light(),
          home: Center(
            child: RepaintBoundary(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Material(child: child),
                ),
              ),
            ),
          ),
        );

    testWidgets('满事件流：meta chips + 用户输入 + 思考/工具/错误/回复', (tester) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        detailHost(
          TurnDetailPanel(
            detail: TurnDetail(
              turn: turn(),
              events: [
                event(
                  eventType: EventTypes.thought,
                  seq: 1,
                  payload: {'text': '先读一下日志，看看工具调用返回了什么。'},
                ),
                event(
                  eventType: EventTypes.toolCall,
                  seq: 2,
                  payload: {
                    'tool': 'read_file',
                    'args': {'path': '/var/log/partyb/agent.log'},
                    'output': 'permission denied: /var/log/partyb/agent.log',
                    'ok': false,
                  },
                ),
                event(
                  eventType: EventTypes.error,
                  seq: 3,
                  payload: {'message': '读取日志失败：权限不足（permission denied）'},
                ),
                event(
                  eventType: EventTypes.message,
                  seq: 4,
                  payload: {
                    'text':
                        '日志读不到：当前进程对 `/var/log/partyb/agent.log` 没有读权限。'
                        '需要把该文件所属组加给服务账号，或改用 `journalctl` 取日志。',
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(TurnDetailPanel),
        matchesGoldenFile('goldens/turn_detail_panel_full.png'),
      );
    });

    testWidgets('空事件：说明文案的密度（11px→12px 的落点）', (tester) async {
      // 这条基线锁的正是 §6.78 修掉的那两行：`这一轮没有可展示的事件` +
      // `事件可能已超出时间线窗口，或尚未落库。`（后者曾经是 11px）。
      await tester.pumpWidget(
        detailHost(
          TurnDetailPanel(
            detail: TurnDetail(
              turn: turn(status: 'completed', errorCount: 0, channel: null),
              events: const [],
            ),
          ),
          size: const Size(480, 320),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(TurnDetailPanel),
        matchesGoldenFile('goldens/turn_detail_panel_empty.png'),
      );
    });
  });
}
