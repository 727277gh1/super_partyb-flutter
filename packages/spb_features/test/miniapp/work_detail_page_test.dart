import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 工作详情页测试。
///
/// ## 这个测试防的是什么
///
/// 三类静默错误，都不会抛异常、不会崩溃，只是行为不对：
///
/// 1. **派发失败嵌在响应体里**：`dispatchWorkMessage` 出错时返回
///    `{error: ...}` 而 HTTP 仍是 201。不检查 `hasError` 会把「发送失败」
///    显示成成功，用户一直等一个不存在的回答。
/// 2. **`complete`/`stop` 对已结束的 work 返回 404**（不是幂等 200）。
///    把它当错误弹「失败」会让用户以为操作没生效，而实际目标状态已达成。
/// 3. **能力位必须读服务端的**：`can_send_message` / `can_stop` / `can_complete`
///    由服务端按状态机算好。客户端自己推（如 `status != 'completed'`）会漂移——
///    `resolveWorkStatus` 有 6 个分支，客户端复刻一份必然对不上。
void main() {
  Map<String, dynamic> detailJson({
    String id = 'w1',
    String status = 'running',
    String statusLabel = '运行中',
    bool canSend = true,
    bool canStop = true,
    bool canComplete = true,
    List<Map<String, dynamic>> steps = const [],
    List<Map<String, dynamic>> confirmations = const [],
    String? latestResult,
    String? goal,
  }) => {
    'id': id,
    'title': '做个报表',
    'goal': goal,
    'status': status,
    'status_label': statusLabel,
    'progress': {'total': 3, 'completed': 1, 'percent': 33},
    'steps': steps,
    'latest_result': latestResult == null
        ? null
        : {'title': '最新结果', 'content': latestResult},
    'pending_confirmations': confirmations,
    'artifacts': <Map<String, dynamic>>[],
    'recent_events': <Map<String, dynamic>>[],
    'can_send_message': canSend,
    'can_stop': canStop,
    'can_complete': canComplete,
    'created_at': '2024-03-05T08:09:10Z',
    'updated_at': '2024-03-05T08:09:12Z',
  };

  Map<String, dynamic> confirmationJson({String id = 'c1'}) => {
    'id': id,
    'work_id': 'w1',
    'type': 'risk_approval',
    'title': '需要确认风险操作',
    'description': '将删除 3 个文件',
    'options': [
      {'key': 'approve', 'label': '同意', 'recommended': true},
      {'key': 'reject', 'label': '拒绝'},
    ],
    'required_inputs': <Map<String, dynamic>>[],
    'status': 'pending',
    'created_at': '2024-03-05T08:09:10Z',
  };

  Map<String, dynamic> artifactJson({String id = 'a1'}) => {
    'id': id,
    'work_id': 'w1',
    'name': 'report.md',
    'type': 'document',
    'mime_type': 'text/markdown',
    'size_bytes': 2048,
    'preview_mode': 'text',
    'created_at': '2024-03-05T08:09:11Z',
  };

  Map<String, dynamic> eventRowJson({
    String id = 'e1',
    String type = 'message',
  }) => {
    'id': id,
    'turnId': 't1',
    'groupId': 'w1',
    'userId': 'u1',
    'agentId': {'String': 'agt_1', 'Valid': true},
    'sessionId': {'String': '', 'Valid': false},
    'eventType': type,
    'seq': 1,
    'globalSeq': 3,
    'source': 'agent',
    'payloadJson': '{"content":"你好"}',
    'createdAt': '2024-03-05T08:09:10Z',
  };

  late List<MiniappWorkEvent> events;
  late List<MiniappArtifact> artifacts;
  late List<String> sent;
  late List<(String, String)> resolved;
  late List<String> savedPaths;
  late int completeCalls;
  late int stopCalls;

  // ## 为什么这些声明必须放在 setUpStubs 之前
  //
  // Dart 的局部变量**必须先声明后使用**（与类字段不同）。这些 stub 闭包被
  // setUpStubs 赋值、被 pumpPage 读取，故声明顺序必须是
  // 声明 → setUpStubs → pumpPage。
  //
  // `_currentDetail` 是「服务端当前状态」：动作后服务端会返回新对象，测试可
  // 改它来模拟状态推进（如 complete 后变成 completed）。
  MiniappWorkDetail? currentDetail;
  Future<MiniappWorkDetail> Function() stubDetail = () async =>
      throw StateError('unset');
  Future<MiniappWorkDetail> Function() stubComplete = () async =>
      throw StateError('unset');
  Future<MiniappWorkDetail> Function() stubStop = () async =>
      throw StateError('unset');
  Future<MiniappDispatchResult> Function(String) stubSend = (_) async =>
      throw StateError('unset');
  Future<void> Function(String, String) stubResolve = (_, _) async =>
      throw StateError('unset');
  Future<List<int>> Function(String) stubDownload = (_) async =>
      throw StateError('unset');
  Future<String> Function(String, List<int>) stubSave = (_, _) async =>
      throw StateError('unset');

  void setUpStubs({
    MiniappWorkDetail? detailValue,
    Future<MiniappWorkDetail> Function()? onComplete,
    Future<MiniappWorkDetail> Function()? onStop,
    Future<MiniappDispatchResult> Function(String)? onSend,
    Future<void> Function(String, String)? onResolve,
    Future<List<int>> Function(String)? onDownload,
    Future<String> Function(String, List<int>)? onSave,
    SpbError? detailError,
  }) {
    events = const [];
    artifacts = const [];
    sent = [];
    resolved = [];
    savedPaths = [];
    completeCalls = 0;
    stopCalls = 0;

    final d = detailValue ?? MiniappWorkDetail.fromJson(detailJson());
    currentDetail = d;
    stubDetail = () async {
      if (detailError != null) throw detailError;
      return currentDetail ?? d;
    };
    stubComplete = () async {
      completeCalls++;
      if (onComplete != null) return onComplete();
      return currentDetail ?? d;
    };
    stubStop = () async {
      stopCalls++;
      if (onStop != null) return onStop();
      return currentDetail ?? d;
    };
    stubSend = (input) async {
      sent.add(input);
      if (onSend != null) return onSend(input);
      return const MiniappDispatchResult(turnId: 't9');
    };
    stubResolve = (id, action) async {
      resolved.add((id, action));
      await onResolve?.call(id, action);
    };
    stubDownload = (id) async => onDownload?.call(id) ?? [1, 2, 3];
    stubSave = (name, bytes) async {
      final p = onSave != null ? await onSave(name, bytes) : '/tmp/$name';
      savedPaths.add(p);
      return p;
    };
  }

  /// 页面主体是 `ListView`（惰性构建）：默认 800×600 视口下，靠后的区块
  /// （步骤 / 确认卡 / 产物 / 事件 / 底部动作按钮）**根本不在树上**，
  /// `find.byKey` 找不到，`ensureVisible` 也无从下手。
  /// 故统一用高视口，让整页内容一次构建出来。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: WorkDetailPage(
          loadDetail: () => stubDetail(),
          loadEvents: () async => events,
          loadArtifacts: () async => artifacts,
          downloadArtifact: (id) => stubDownload(id),
          saveArtifact: (name, bytes) => stubSave(name, bytes),
          sendMessage: (input) => stubSend(input),
          complete: () => stubComplete(),
          stop: () => stubStop(),
          resolveConfirmation: (id, action) => stubResolve(id, action),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  tearDown(() => currentDetail = null);

  testWidgets('渲染状态名 / 进度 / 最新结果 / 能力位按钮', (tester) async {
    setUpStubs(
      detailValue: MiniappWorkDetail.fromJson(
        detailJson(latestResult: '已抓取 3 个数据源', goal: '生成月度报表'),
      ),
    );
    await pumpPage(tester);

    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('已抓取 3 个数据源'), findsOneWidget);
    expect(find.text('目标：生成月度报表'), findsOneWidget);
    expect(find.byKey(const ValueKey('miniapp-work-complete')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniapp-work-stop')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('miniapp-work-message-field')),
      findsOneWidget,
    );
  });

  testWidgets('能力位为 false 时不展示对应控件（不自己推状态）', (tester) async {
    // 已完成的 work：服务端下发 can_* 全 false。页面必须**直接读**它们，
    // 而不是自己判 `status != 'completed'`——状态机在服务端，6 个分支。
    setUpStubs(
      detailValue: MiniappWorkDetail.fromJson(
        detailJson(
          status: 'completed',
          statusLabel: '已完成',
          canSend: false,
          canStop: false,
          canComplete: false,
        ),
      ),
    );
    await pumpPage(tester);

    expect(find.byKey(const ValueKey('miniapp-work-complete')), findsNothing);
    expect(find.byKey(const ValueKey('miniapp-work-stop')), findsNothing);
    expect(
      find.byKey(const ValueKey('miniapp-work-message-field')),
      findsNothing,
    );
  });

  testWidgets('加载失败展示错误与重试，且不清空为空白页', (tester) async {
    setUpStubs(detailError: const NetworkError('连接超时'));
    await pumpPage(tester);

    expect(find.byKey(const ValueKey('miniapp-work-error')), findsOneWidget);
    expect(find.textContaining('连接超时'), findsOneWidget);
    expect(find.byKey(const ValueKey('miniapp-work-retry')), findsOneWidget);
  });

  testWidgets('发送消息走注入的 sendMessage', (tester) async {
    setUpStubs();
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('miniapp-work-message-field')),
      '再补充一点',
    );
    await tester.tap(find.byKey(const ValueKey('miniapp-work-message-send')));
    await tester.pump();
    await tester.pump();

    expect(sent, ['再补充一点']);
  });

  testWidgets('派发失败（hasError）提示失败，不显示成成功', (tester) async {
    // ## 这个测试防的是什么
    //
    // 服务端把派发失败嵌在 200/201 响应体里（`{"dispatch":{"error":...}}`），
    // HTTP 状态码是成功的。不检查 hasError 会把「发送失败」显示成成功。
    setUpStubs(
      onSend: (_) async => const MiniappDispatchResult(
        turnId: '',
        error: 'queued turn quota exceeded',
      ),
    );
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('miniapp-work-message-field')),
      'x',
    );
    await tester.tap(find.byKey(const ValueKey('miniapp-work-message-send')));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('发送失败'), findsOneWidget);
    expect(find.textContaining('queued turn quota exceeded'), findsOneWidget);
  });

  testWidgets('feedback_recorded 提示已记录归属反馈（不建 turn，不等回答）', (tester) async {
    setUpStubs(
      onSend: (_) async => const MiniappDispatchResult(
        turnId: '',
        status: 'feedback_recorded',
        feedbackRecorded: true,
      ),
    );
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('miniapp-work-message-field')),
      '这属于另一个对话',
    );
    await tester.tap(find.byKey(const ValueKey('miniapp-work-message-send')));
    await tester.pump();
    await tester.pump();

    expect(find.text('已记录归属反馈'), findsOneWidget);
  });

  testWidgets('标记完成调用 complete 并更新详情', (tester) async {
    // 初始是 running（有「标记完成」按钮），complete 返回 completed。
    // ⚠️ 不能在 pumpPage **之前**把 currentDetail 改成 completed——那样首次
    // 加载拿到的就是已完成状态，按钮根本不存在，测试会以「找不到按钮」失败。
    final completed = MiniappWorkDetail.fromJson(
      detailJson(
        status: 'completed',
        statusLabel: '已完成',
        canSend: false,
        canStop: false,
        canComplete: false,
      ),
    );
    setUpStubs(onComplete: () async => completed);

    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('miniapp-work-complete')));
    await tester.pump();
    await tester.pump();

    expect(completeCalls, 1);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('已标记完成'), findsOneWidget);
  });

  testWidgets('complete 返回 404 时提示「已结束」而非失败（目标状态已达成）', (tester) async {
    // 服务端对非 active 的 work 返回 404（不是幂等 200）。重复点击时把
    // 「已经是完成态」当成错误弹「失败」会让用户以为没生效。
    // complete 404（目标状态已达成）后刷新详情 → 拿到已完成状态。
    final completed = MiniappWorkDetail.fromJson(
      detailJson(status: 'completed', statusLabel: '已完成', canSend: false),
    );
    setUpStubs(onComplete: () async => throw const HttpError(404, 'HTTP 404'));
    // 首次加载仍是 running，故「标记完成」按钮存在。
    // 404 之后页面会调 loadDetail 刷新——此时返回 completed，
    // 模拟「服务端说它已经结束了」。
    var refreshed = false;
    stubDetail = () async {
      if (refreshed) return completed;
      refreshed = true;
      return currentDetail!;
    };

    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('miniapp-work-complete')));
    await tester.pump();
    await tester.pump();

    expect(find.text('该工作已结束'), findsOneWidget);
    expect(find.textContaining('失败'), findsNothing);
  });

  testWidgets('停止工作调用 stop', (tester) async {
    final stopped = MiniappWorkDetail.fromJson(
      detailJson(status: 'stopped', statusLabel: '已停止', canStop: false),
    );
    setUpStubs(onStop: () async => stopped);

    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('miniapp-work-stop')));
    await tester.pump();
    await tester.pump();

    expect(stopCalls, 1);
    expect(find.text('已停止'), findsWidgets);
  });

  testWidgets('确认卡展示选项并回调 resolveConfirmation', (tester) async {
    setUpStubs(
      detailValue: MiniappWorkDetail.fromJson(
        detailJson(confirmations: [confirmationJson()]),
      ),
    );
    await pumpPage(tester);

    expect(find.text('需要确认风险操作'), findsOneWidget);
    expect(find.text('将删除 3 个文件'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('miniapp-confirm-c1-approve')));
    await tester.pump();
    await tester.pump();

    expect(resolved, [('c1', 'approve')]);
  });

  testWidgets('确认卡 resolve 返回 404 时提示「已处理过」而非失败', (tester) async {
    // 404 = 非本人 / 已处理 / 已过期。服务端刻意统一成一个响应以避免存在性
    // 探针；调用方应把 404 当「这张卡不用再显示了」。
    setUpStubs(
      detailValue: MiniappWorkDetail.fromJson(
        detailJson(confirmations: [confirmationJson()]),
      ),
      onResolve: (_, _) async => throw const HttpError(404, 'HTTP 404'),
    );
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('miniapp-confirm-c1-approve')));
    await tester.pump();
    await tester.pump();

    expect(find.text('这张确认已处理过了'), findsOneWidget);
    // 已处理 → 选项置灰（不可再点）。
    final approve = tester.widget<FilledButton>(
      find.byKey(const ValueKey('miniapp-confirm-c1-approve')),
    );
    expect(approve.onPressed, isNull);
  });

  testWidgets('产物下载走 downloadArtifact + saveArtifact 并提示落地路径', (tester) async {
    setUpStubs(onSave: (name, bytes) async => '/home/u/deliverables/$name');
    artifacts = [MiniappArtifact.fromJson(artifactJson())];

    await pumpPage(tester);
    expect(find.text('report.md'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('miniapp-artifact-download-a1')),
    );
    await tester.pump();
    await tester.pump();

    expect(savedPaths, ['/home/u/deliverables/report.md']);
    expect(
      find.textContaining('/home/u/deliverables/report.md'),
      findsOneWidget,
    );
  });

  testWidgets('产物下载失败提示原因（合成 id 查不到是常态，不是功能坏了）', (tester) async {
    // 事件投影出的产物 id 可能是服务端合成的 "<group_id>:<relative_path>"，
    // 这种 id UFS 查不到 → 404。属于常态，不该当成功能故障。
    setUpStubs(onDownload: (_) async => throw const HttpError(404, 'HTTP 404'));
    artifacts = [MiniappArtifact.fromJson(artifactJson())];

    await pumpPage(tester);
    await tester.tap(
      find.byKey(const ValueKey('miniapp-artifact-download-a1')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('下载失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('事件列表渲染（用 MiniappWorkEvent，payloadJson 字符串）', (tester) async {
    setUpStubs();
    events = [MiniappWorkEvent.fromJson(eventRowJson())];

    await pumpPage(tester);

    expect(find.text('message'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
  });

  testWidgets('步骤列表展示完成与运行中状态', (tester) async {
    setUpStubs(
      detailValue: MiniappWorkDetail.fromJson(
        detailJson(
          steps: [
            {
              'id': 's1',
              'title': '抓数据',
              'status': 'completed',
              'order_index': 1,
            },
            {'id': 's2', 'title': '生成', 'status': 'running', 'order_index': 2},
          ],
        ),
      ),
    );
    await pumpPage(tester);

    expect(find.text('抓数据'), findsOneWidget);
    expect(find.text('生成'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.play_circle), findsOneWidget);
  });

  testWidgets('动作进行中禁用发送按钮（不重复提交）', (tester) async {
    final gate = Completer<MiniappDispatchResult>();
    setUpStubs(onSend: (_) => gate.future);
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('miniapp-work-message-field')),
      'x',
    );
    await tester.tap(find.byKey(const ValueKey('miniapp-work-message-send')));
    await tester.pump();

    final send = tester.widget<IconButton>(
      find.byKey(const ValueKey('miniapp-work-message-send')),
    );
    expect(send.onPressed, isNull);

    gate.complete(const MiniappDispatchResult(turnId: 't1'));
    await tester.pump();
    await tester.pump();
  });

  group('工作台：上传附件', () {
    /// 造一个真实存在的临时文件并 mock 系统文件选择器返回它。
    ///
    /// ## 为什么用真实文件
    ///
    /// 页面对每个选中文件调 `readBytes()`；不存在的文件会抛，测试会以
    /// 「上传失败」形式失败，而根因是 fixture 而不是被测逻辑。
    ({Directory dir, File file}) makeTempFile(
      WidgetTester tester,
      String name,
    ) {
      final dir = Directory.systemTemp.createTempSync('work-upload');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/$name')
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => call.method == 'openFile' ? [file.path] : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        );
      });
      return (dir: dir, file: file);
    }

    /// 挂载带上传注入的页面，返回捕获到的上传调用。
    Future<List<({String filename, List<int> bytes})>> pumpWithUpload(
      WidgetTester tester, {
      Future<void> Function({
        required String filename,
        required List<int> bytes,
      })?
      upload,
      Future<List<MiniappArtifact>> Function()? loadArtifacts,
    }) async {
      final uploads = <({String filename, List<int> bytes})>[];
      useTallViewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: WorkDetailPage(
            loadDetail: () => stubDetail(),
            loadEvents: () async => events,
            loadArtifacts: loadArtifacts ?? () async => artifacts,
            downloadArtifact: (id) => stubDownload(id),
            saveArtifact: (name, bytes) => stubSave(name, bytes),
            sendMessage: (input) => stubSend(input),
            complete: () => stubComplete(),
            stop: () => stubStop(),
            resolveConfirmation: (id, action) => stubResolve(id, action),
            onUploadFile:
                upload ??
                ({required filename, required bytes}) async {
                  uploads.add((filename: filename, bytes: bytes));
                },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return uploads;
    }

    /// 点上传并等待整条链路完成。
    ///
    /// ## 为什么整条链路必须在**一个** `runAsync` 里
    ///
    /// `_upload` 依次做三件跨时区的事：调平台通道（`file_selector`）→
    /// `readBytes()`（真实文件 I/O）→ 调注入点。测试默认跑在 FakeAsync 时区，
    /// 平台通道与文件 I/O 都只会在**真实**时区里完成。
    ///
    /// 若只把「等一会儿」包进 runAsync（而 `tap` 留在外面），`_upload` 的续体
    /// 是在 FakeAsync 时区注册的，它 await 的平台通道 Future 永远不会被推进——
    /// 实测 `uploadCalls` 恒为 0，且页面不报任何错，看起来像「按钮点了没反应」。
    ///
    /// 也不能用 `pumpAndSettle` 收尾：上传期间按钮位置是
    /// `CircularProgressIndicator`（无限动画），settle 永远等不到「无动画」。
    Future<void> tapUpload(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('miniapp-work-upload')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump();
    }

    testWidgets('未注入 onUploadFile 时不展示上传按钮（只读用法）', (tester) async {
      setUpStubs();
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('miniapp-work-upload')),
        findsNothing,
        reason: '没注入实现却展示按钮，点下去什么也不会发生',
      );
    });

    testWidgets('点上传 → 选中的文件透传给 onUploadFile（文件名 + 字节）', (tester) async {
      setUpStubs();
      final tmp = makeTempFile(tester, '报告.pdf');
      final uploads = await pumpWithUpload(tester);

      await tapUpload(tester);

      expect(uploads, hasLength(1));
      expect(
        uploads.single.filename,
        '报告.pdf',
        reason: '文件名要原样传（服务端用它做安全化后落盘）',
      );
      expect(uploads.single.bytes, const [
        1,
        2,
        3,
        4,
      ], reason: '字节必须真的读出来，而不是传个空数组');
      expect(tmp.file.existsSync(), isTrue);
    });

    testWidgets('用户取消选择（返回空）时不调用上传', (tester) async {
      setUpStubs();
      // mock 返回空列表 = 用户取消。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => <String>[],
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        );
      });
      final uploads = await pumpWithUpload(tester);

      await tapUpload(tester);

      expect(uploads, isEmpty, reason: '取消不是错误，不该发出一个空文件的上传');
    });

    testWidgets('上传成功后重拉列表（产物由服务端投影，不本地拼接）', (tester) async {
      setUpStubs();
      makeTempFile(tester, 'a.txt');
      var artifactLoads = 0;
      final uploads = await pumpWithUpload(
        tester,
        loadArtifacts: () async {
          artifactLoads++;
          return const [];
        },
      );
      final before = artifactLoads;

      await tapUpload(tester);

      expect(uploads, hasLength(1));
      expect(
        artifactLoads,
        greaterThan(before),
        reason: '不重拉的话用户看不到刚上传的文件，会以为上传失败',
      );
    });

    testWidgets('单个文件上传失败不阻断整批，且提示哪几个失败', (tester) async {
      setUpStubs();
      makeTempFile(tester, 'bad.txt');
      final uploads = await pumpWithUpload(
        tester,
        upload: ({required filename, required bytes}) async =>
            throw const HttpError(413, '文件过大'),
      );

      await tapUpload(tester);

      expect(find.textContaining('bad.txt'), findsWidgets);
      expect(tester.takeException(), isNull, reason: '失败必须被捕获，不能让页面崩');
      expect(uploads, isEmpty);
    });
  });
}
