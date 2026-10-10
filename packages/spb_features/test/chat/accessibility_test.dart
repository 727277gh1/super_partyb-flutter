import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

/// 无障碍（a11y）守卫测试（issue #24）。
///
/// ## 这个测试防的是什么
///
/// 本仓库的语义树覆盖率**不靠全仓扫描**保证（issue #24 备注明确否定了
/// 「批量加标签」）——而是给「屏幕阅读器读不出内容」的几个具体位置各钉一个
/// 用例。每个用例都对应一个**真实会读错**的场景：
///
/// | 场景 | 不加标签时屏幕阅读器念出 |
/// |---|---|
/// | 进度条（自绘矩形） | 百分比，但不知道**是什么的**百分比 |
/// | 长按/右键菜单（无键盘入口） | 什么也没有——动作对键盘用户不存在 |
/// | 附件移除 ✕（无可见文本） | 「按钮」——不知道移除哪个附件 |
///
/// ## 两条容易写错的测试约定
///
/// 1. **必须 `tester.ensureSemantics()`**。`flutter_test` 默认**关闭**语义树，
///    不开的话语义断言永远落空，测试以「找不到」失败，看起来像「标签没加上」。
/// 2. **必须显式 `handle.dispose()`**（不用 `addTearDown`）。语义句柄的
///    「是否都已释放」检查跑在 `_endOfTestVerifications` 里，**早于** teardown
///    回调——用 `addTearDown` 会报 `All SemanticsHandle instances must be
///    disposed`，而那条错误信息完全不提「该显式 dispose」。
///
/// ## 断言用 `find.byType` 而非 `find.bySemanticsLabel`
///
/// `bySemanticsLabel` 会把**可见文本节点**也算进去（进度条的 `label` 文本与
/// 进度条自己的语义节点同名，`findsOneWidget` 会失败成「找到 2 个」）。故一律
/// 先定位组件，再读它自己的 `SemanticsNode.getSemanticsData()`。
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 读某个组件自身的语义数据。
  SemanticsData semanticsOf(WidgetTester tester, Finder finder) =>
      tester.getSemantics(finder).getSemanticsData();

  group('进度条：semanticsLabel（issue #24）', () {
    testWidgets('spec_ui progress：label 非空时用它作 semanticsLabel', (tester) async {
      // `label` 是图上的**可见文本**，但对屏幕阅读器它是并列的另一个节点——
      // 进度条自身没有名字，只会念出一个孤零零的百分比。
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'p',
              'elements': {
                'p': {
                  'type': 'progress',
                  'props': {'label': '构建进度', 'value': 60},
                },
              },
            }),
          ),
        ),
      );

      final data = semanticsOf(tester, find.byType(LinearProgressIndicator));
      expect(data.label, '构建进度', reason: '进度条必须能说出「这是什么进度」，而不只是一个百分比');
      expect(data.value, '60', reason: '比例仍由 Flutter 自动算，无需手写');

      handle.dispose();
    });

    testWidgets('spec_ui progress：label 为空时不编造「进度」标签', (tester) async {
      // 编一个「进度」对用户零信息——同 issue #24 备注否定的
      // 「给纯装饰图标加 label: '图标'」。此时保留 Flutter 默认的百分比读数。
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        host(
          SpecUiCard(
            doc: parseSpecUi({
              'root': 'p',
              'elements': {
                'p': {
                  'type': 'progress',
                  'props': {'value': 30},
                },
              },
            }),
          ),
        ),
      );

      final data = semanticsOf(tester, find.byType(LinearProgressIndicator));
      expect(data.label, isNot('进度'));
      expect(data.value, '30');

      handle.dispose();
    });

    testWidgets('目标任务进度条：semanticsLabel 说明这是什么的进度', (tester) async {
      // 面板里的「已完成 3/5（60%）」是**另一个**文本节点，屏幕阅读器不会
      // 自动把它和进度条关联起来（两个并列节点）。故进度条得自己带名字。
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        host(
          GoalTasksPanel(
            snapshot: GoalSnapshot(
              goal: Goal.fromJson({
                'id': 'goal_1',
                'group_id': 'grp_1',
                'goal_text': '把 CI 修绿',
                'status': 'active',
                'tasks_source': 'manual',
                'created_at': '2024-03-05T08:00:00Z',
                'updated_at': '2024-03-05T08:00:00Z',
              }),
              tasks: const [],
              progress: GoalProgress.fromJson({
                'total': 5,
                'completed': 3,
                'in_progress': 0,
                'blocked': 0,
                'error_stopped': 0,
                'pending': 2,
                'percent': 60,
              }),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // `getSemantics` 拿到的是**最近的祖先语义节点**——进度条的
      // `Semantics` 没开 `container`，会与上面的目标文本合并成一个节点。
      // 故用 `contains` 而不是相等：要锁的是「进度条贡献了自己的名字」，
      // 而不是「这个节点只有这个名字」（后者是无关的布局细节）。
      final data = semanticsOf(tester, find.byType(LinearProgressIndicator));
      expect(data.label, contains('目标任务完成进度'));
      expect(data.value, '60');

      handle.dispose();
    });
  });

  group('对话条目的长按菜单：customSemanticsActions（issue #24）', () {
    late Dio dio;
    late DioAdapter adapter;
    late ChatApi api;

    setUp(() {
      dio = createDio(baseUrl: 'https://api.test/pba');
      adapter = DioAdapter(dio: dio);
      api = ChatApi(dio);
    });

    /// 挂一页 groups 响应（形状对齐 `groupRowToDict`）。
    void mockPage(List<Map<String, dynamic>> items) {
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(200, {'items': items}),
        queryParameters: {'limit': 30, 'offset': 0},
      );
    }

    Map<String, dynamic> groupJson(String title) => {
      'id': 'g1',
      'user_id': 'usr_1',
      'title': title,
      'status': 'active',
      'created_at': '2024-03-05T08:00:00Z',
      'updated_at': '2024-03-05T08:09:10Z',
    };

    /// 等 dio mock 的响应落地。
    ///
    /// ⚠️ 用 `pump(Duration)` 推进**假时钟**，不能用 `runAsync`：dio 的 mock
    /// 响应在一个 `Timer` 里 resolve，而 `testWidgets` 跑在 FakeAsync 时区——
    /// `runAsync` 跑真实时区，不会推进假时钟，Timer 永不触发。
    Future<void> settleIo(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
    }

    /// 条目暴露的自定义语义动作标签。
    List<String?> customActions(WidgetTester tester, String title) {
      final ids =
          semanticsOf(tester, find.text(title)).customSemanticsActionIds ??
          const <int>[];
      return ids
          .map((id) => CustomSemanticsAction.getAction(id)?.label)
          .toList();
    }

    testWidgets('有管理入口时，条目暴露「对话操作」自定义语义动作', (tester) async {
      // 重命名/归档/删除**只能**从长按或右键菜单到达，键盘用户与屏幕阅读器
      // 用户没有任何入口。Flutter 不会从「包了一个 GestureDetector」推断出
      // 「这里有自定义动作」——必须显式声明 customSemanticsActions。
      final handle = tester.ensureSemantics();

      mockPage([groupJson('报错排查')]);
      await tester.pumpWidget(
        MaterialApp(
          home: GroupListPage(
            api: api,
            onGroupAction: (_, _) async => const GroupActionApplied(),
          ),
        ),
      );
      await settleIo(tester);
      expect(find.text('报错排查'), findsOneWidget);

      expect(
        customActions(tester, '报错排查'),
        contains('对话操作（重命名/归档/删除）'),
        reason: '没有这个动作，键盘/屏幕阅读器用户无法重命名或归档对话',
      );

      handle.dispose();
    });

    testWidgets('未注入管理入口（onGroupAction 为 null）时不暴露该动作', (tester) async {
      // 只读用法（如「选择对话」场景）不该给一个点了没反应的语义动作。
      final handle = tester.ensureSemantics();

      mockPage([groupJson('只读条目')]);
      await tester.pumpWidget(MaterialApp(home: GroupListPage(api: api)));
      await settleIo(tester);
      expect(find.text('只读条目'), findsOneWidget);

      expect(customActions(tester, '只读条目'), isNot(contains('对话操作（重命名/归档/删除）')));

      handle.dispose();
    });
  });

  group('附件移除按钮：Semantics label（issue #24）', () {
    testWidgets('每个附件 chip 的移除按钮有带文件名的语义标签', (tester) async {
      // 这个按钮**没有任何可见文本**（只是一个 ✕ 图标），屏幕阅读器在它上面
      // 只会念出「按钮」——用户不知道移除的是哪个附件。故 label 必须带文件名。
      final handle = tester.ensureSemantics();

      final dragDrop = _RecordingDragDrop();
      await tester.pumpWidget(
        host(
          OverlayQuickCapturePage(
            submit: ({
              required String input,
              required List<QuickCaptureAttachment> attachments,
              void Function(int done, int total)? onUploadProgress,
            }) async => const QuickCaptureEnqueueResult(delivered: true),
            dragDrop: dragDrop,
          ),
        ),
      );

      // 无附件 → 不应有「移除附件」节点（守卫的负向面）。
      expect(find.bySemanticsLabel(RegExp('移除附件')), findsNothing);

      // 拖入两个文件 → 每个 chip 的 ✕ 各自带自己的文件名。
      dragDrop.onFiles!([
        DroppedFile.fromBytes(name: '报告.pdf', bytes: const [1]),
        DroppedFile.fromBytes(name: '图.png', bytes: const [2]),
      ]);
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('移除附件 报告.pdf'),
        findsOneWidget,
        reason: '不带上文件名，屏幕阅读器只会念出「按钮」',
      );
      expect(find.bySemanticsLabel('移除附件 图.png'), findsOneWidget);

      handle.dispose();
    });
  });
}

/// 记录拖拽回调的假能力（本文件只用来把文件塞进附件列表）。
class _RecordingDragDrop implements DragDropCapability {
  void Function(List<DroppedFile> files)? onFiles;

  @override
  bool get isSupported => true;

  @override
  Widget buildDropZone({
    required Widget child,
    required void Function(List<DroppedFile> files) onFiles,
    void Function(bool hovering)? onHoverChanged,
  }) {
    this.onFiles = onFiles;
    return child;
  }
}
