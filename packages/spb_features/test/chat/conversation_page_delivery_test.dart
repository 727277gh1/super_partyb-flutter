import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// ConversationPage 超时兜底 / 文件卡缩略图 / 批量聚合 / 预览透传
///
/// ⚠️ 本文件由 `conversation_page_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `test/support/conversation_page_harness.dart`。
void main() {
  setUpHarness();
  tearDownHarness();

  group('ConversationPage 超时兜底', () {
    /// 推一个 stale 集合（页面订阅的是 [staleController]）。
    Future<void> pushStale(WidgetTester tester, Set<String> ids) async {
      await tester.runAsync(() async {
        staleController.add(ids);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
    }

    testWidgets('stale turn → 展示提示条', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onCancelTurn: (id) async {},
        staleTurnIds: {'turn_1'},
      );
      await pushStreamingMessage(tester);

      expect(
        find.byKey(const ValueKey('conversation-stale-turn')),
        findsOneWidget,
      );
    });

    testWidgets('stale turn → 停止按钮仍可点（用户唯一的出路）', (tester) async {
      // 这是本方案最关键的一条不变式：stale 只是「客户端没再收到进展」，
      // turn 可能仍在后台跑。禁用取消会让用户彻底失去出路。
      final cancelled = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onCancelTurn: (id) async => cancelled.add(id),
        staleTurnIds: {'turn_1'},
      );
      await pushStreamingMessage(tester);

      final button = find.byKey(const ValueKey('conversation-cancel-turn'));
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);

      await tester.tap(button);
      await tester.pump();
      await tester.pump();

      expect(cancelled, ['turn_1']);
    });

    testWidgets('stale turn → 活动指示器让位（不显示「执行中」）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, staleTurnIds: {'turn_1'});
      // 先推一条活动快照，再推流式正文（有正文时活动指示本就不显示，
      // 故这里只推活动 + 空正文的流式 thought）。
      await pushEvent(
        tester,
        EventTypes.turnActivity,
        sseEvent(
          'turn_activity',
          id: 'e_act',
          payload: {'elapsed_ms': 60000},
          transient: true,
        ),
      );
      await pushEvent(
        tester,
        EventTypes.thought,
        sseEvent(
          'thought',
          id: 'e_thought',
          payload: {'text': '想想'},
          transient: true,
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
        reason: '「执行中 · 已运行 1 分」与「长时间无进展」自相矛盾',
      );
      expect(
        find.byKey(const ValueKey('conversation-stale-turn')),
        findsOneWidget,
      );
    });

    testWidgets('stale 解除（集合变空）→ 提示条消失', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onCancelTurn: (id) async {},
        staleTurnIds: {'turn_1'},
      );
      await pushStreamingMessage(tester);
      expect(
        find.byKey(const ValueKey('conversation-stale-turn')),
        findsOneWidget,
      );

      await pushStale(tester, const {});

      expect(
        find.byKey(const ValueKey('conversation-stale-turn')),
        findsNothing,
        reason: 'turn 又动了（或已终结）时应立刻恢复',
      );
    });

    testWidgets('未注入 staleTurnIds 时不展示提示（纯只读时间线）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, wireStaleTurnIds: false);
      await pushStreamingMessage(tester);

      expect(
        find.byKey(const ValueKey('conversation-stale-turn')),
        findsNothing,
      );
    });

    testWidgets('stale 的是别的 turn 时不影响本 turn 的流式态', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onCancelTurn: (id) async {},
        staleTurnIds: {'turn_other'},
      );
      await pushStreamingMessage(tester, turnId: 'turn_1');

      expect(
        find.byKey(const ValueKey('conversation-stale-turn')),
        findsNothing,
        reason: '集合按 turnId 匹配，不得把无关 turn 判成 stale',
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('conversation-cancel-turn')),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('ConversationPage 文件卡缩略图透传', () {
    /// 推一条 `agent.file.created`（形态照抄生产事件：snake_case 载荷）。
    Future<void> pushAgentFile(
      WidgetTester tester, {
      String path = 'grp_1/pic.png',
      String? ufsFileId = 'ufs_1',
      String? mimeType = 'image/png',
      String id = 'e_file',
    }) => pushEvent(
      tester,
      EventTypes.agentFileCreated,
      sseEvent(
        EventTypes.agentFileCreated,
        id: id,
        payload: {
          'relative_path': path,
          if (ufsFileId != null) 'ufs_file_id': ufsFileId,
          if (mimeType != null) 'mime_type': mimeType,
          'size_bytes': 1024,
        },
      ),
    );

    testWidgets('注入回调后，图片类卡片会发起缩略图请求', (tester) async {
      final requested = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onLoadThumbnailAgentFile: (file) async {
          requested.add(file.ufsFileId ?? '');
          return null; // 退化到图标，避免测试依赖真实图片字节
        },
      );
      await pushAgentFile(tester);

      expect(find.byType(AgentFileCard), findsOneWidget);
      expect(requested, ['ufs_1'], reason: '页面必须把回调透传给卡片，否则缩略图能力永远不生效');
    });

    testWidgets('未注入回调时完全不发起请求（只读时间线不受影响）', (tester) async {
      var called = 0;
      mockTimeline();
      await startController(tester);
      await pumpPage(tester); // 不传 onLoadThumbnailAgentFile
      await pushAgentFile(tester);

      expect(find.byType(AgentFileCard), findsOneWidget);
      expect(called, 0);
      // 没有缩略图时仍渲染文件图标（功能不因缺回调而缺失）。
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('非图片文件不发起请求（避免为文档白拉缩略图）', (tester) async {
      final requested = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onLoadThumbnailAgentFile: (file) async {
          requested.add(file.ufsFileId ?? '');
          return null;
        },
      );
      await pushAgentFile(
        tester,
        path: 'grp_1/readme.md',
        mimeType: 'text/markdown',
      );

      expect(find.byType(AgentFileCard), findsOneWidget);
      expect(requested, isEmpty, reason: '仅图片类有意义（卡片 isImage 判定）');
    });

    testWidgets('ufsFileId 为空的卡片不发请求（不拼出 /files//thumbnails/256）', (
      tester,
    ) async {
      final requested = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onLoadThumbnailAgentFile: (file) async {
          requested.add(file.ufsFileId ?? '');
          return null;
        },
      );
      // created 无 fileId 会被归约器跳过，故改用 deleted（它本就不带 id）。
      await pushEvent(
        tester,
        EventTypes.agentFileDeleted,
        sseEvent(
          EventTypes.agentFileDeleted,
          id: 'e_del',
          payload: {
            'relative_path': 'grp_1/gone.png',
            'mime_type': 'image/png',
          },
        ),
      );

      expect(find.byType(AgentFileCard), findsOneWidget);
      expect(requested, isEmpty);
    });

    testWidgets('与文件无关的流式增量不再重拉缩略图', (tester) async {
      // 缺陷现场：`AgentFileCard.didUpdateWidget` 曾用「回调 identity 变了」
      // 作判据，而页面在 `_buildItem` 里现包闭包——**每次 build 都是新实例**，
      // 于是推一条无关增量（甚至状态条刷新）就会清缓存重拉。
      // 实测修复前：1 条图片卡 + 3 条无关增量 → 4 次请求。
      final requested = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onLoadThumbnailAgentFile: (file) async {
          requested.add(file.ufsFileId ?? '');
          return null;
        },
      );
      await pushAgentFile(tester);
      expect(requested, ['ufs_1'], reason: '前置：首次挂载必须拉一次');

      for (var i = 0; i < 3; i++) {
        await pushStreamingMessage(
          tester,
          id: 'e_stream_$i',
          turnId: 'turn_1',
          text: '增量 $i',
          seq: 10 + i,
        );
      }

      expect(
        requested,
        ['ufs_1'],
        reason:
            '文件身份没变（id/ufsFileId/isDeleted 全同）就不该重拉；'
            '修复前每次 build 都因闭包新实例而重拉，实测 4 次',
      );
    });

    testWidgets('滚出视口再滚回不重拉缩略图', (tester) async {
      // 卡片的 `_thumbnail` 活在该行的 State 里，而 `ListView.builder` 的子项
      // 一旦滚出 `cacheExtent` 就被 dispose（本页未混入
      // `AutomaticKeepAliveClientMixin`）——滚回来 `initState` 重跑 → 又拉
      // 一次。页面层的 `_thumbnailMemo` 就是为此存在。
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final requested = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onLoadThumbnailAgentFile: (file) async {
          requested.add(file.ufsFileId ?? '');
          return null;
        },
      );
      await pushAgentFile(tester);
      expect(requested, ['ufs_1'], reason: '前置：首次挂载拉一次');

      // 把内容撞到远超一屏 + cacheExtent：图片卡在最顶上，必然被回收。
      for (var i = 0; i < 40; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'u$i',
            turnId: 'turn_u$i',
            seq: 100 + i,
            payload: {'input': '填充消息 $i'},
          ),
        );
      }
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(
        position.maxScrollExtent,
        greaterThan(position.viewportDimension * 2),
        reason: '前置：内容必须真的可滚动，否则图片卡从未离开视口',
      );

      // 三段跳：顶部（能看到卡）→ 底（卡被回收）→ 顶（卡重建）。
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byType(AgentFileCard), findsOneWidget, reason: '前置：顶部能看到图片卡');

      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        find.byType(AgentFileCard),
        findsNothing,
        reason: '前置：滚到底后图片卡必须已被回收（否则本用例测不到滚出滚回）',
      );

      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byType(AgentFileCard), findsOneWidget, reason: '滚回后卡片重建');

      expect(
        requested,
        ['ufs_1'],
        reason:
            '卡片 State 被销毁重建，但页面层的 `_thumbnailMemo` 按 ufsFileId '
            '记忆化，故不该重拉；修复前这里会是 2 次',
      );
    });
  });

  group('ConversationPage 批量聚合渲染', () {
    /// 推一条 `agent.file.created`（同秒，供聚合用）。
    ///
    /// 时间戳固定到同一秒：归约器的 `AgentFileItem.createdAt` 取自事件的
    /// `createdAt`，而 `sseEvent` 默认恒为 `2024-03-05T08:09:10Z`——故连续推
    /// 多条就天然同秒，无需额外构造。
    Future<void> pushFile(
      WidgetTester tester, {
      required String path,
      String? mimeType = 'text/markdown',
      String action = EventTypes.agentFileCreated,
      int seq = 1,
    }) => pushEvent(
      tester,
      action,
      sseEvent(
        action,
        id: 'e_$path',
        seq: seq,
        payload: {
          'relative_path': path,
          'ufs_file_id': 'ufs_$path',
          if (mimeType != null) 'mime_type': mimeType,
          'size_bytes': 1024,
        },
      ),
    );

    /// 连续推 [count] 个同秒文件。
    Future<void> pushFiles(
      WidgetTester tester,
      int count, {
      String prefix = 'f',
      String? mimeType = 'text/markdown',
    }) async {
      for (var i = 0; i < count; i++) {
        await pushFile(
          tester,
          path: 'out/$prefix$i.md',
          mimeType: mimeType,
          seq: i + 1,
        );
      }
    }

    testWidgets('同秒 5 个 → 渲染一张批量卡，不逐条渲染', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onDownloadAgentFile: (_) async {});
      await pushFiles(tester, 5);

      expect(find.byType(AgentFileBatchCard), findsOneWidget);
      // 折叠态下逐条卡一张都不渲染（这是聚合的全部意义）。
      expect(find.byType(AgentFileCard), findsNothing);
      expect(find.text('生成了 5 个文件'), findsOneWidget);
    });

    testWidgets('同秒 4 个 → 逐条渲染，无批量卡（阈值边界）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onDownloadAgentFile: (_) async {});
      await pushFiles(tester, 4);

      expect(find.byType(AgentFileBatchCard), findsNothing);
      expect(find.byType(AgentFileCard), findsNWidgets(4));
    });

    testWidgets('展开后逐条渲染原始文件卡（可下载/打开）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onDownloadAgentFile: (_) async {},
        onOpenAgentFile: (_) async => true,
      );
      await pushFiles(tester, 5);

      expect(find.byType(AgentFileCard), findsNothing);

      await tester.tap(find.byKey(const ValueKey('agent-file-batch-toggle')));
      await tester.pump();

      // 展开后 5 张原始卡都渲染（复用了单卡，故下载/打开入口都在）。
      expect(find.byType(AgentFileCard), findsNWidgets(5));
      expect(find.byType(AgentFileBatchCard), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsNWidgets(5));
      // 每个成员都有「打开」菜单（未删除、有 fileId）。
      expect(find.byKey(const ValueKey('agent-file-menu')), findsNWidgets(5));

      // 再点收起。
      await tester.tap(find.byKey(const ValueKey('agent-file-batch-toggle')));
      await tester.pump();
      expect(find.byType(AgentFileCard), findsNothing);
    });

    testWidgets('批量卡标题按最新态动词（含删除批 → 「删除」）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onDownloadAgentFile: (_) async {});
      await pushFiles(tester, 4);
      // 第 5 个是删除事件（同秒）→ 动词变「删除」。
      await pushFile(
        tester,
        path: 'out/gone.md',
        action: EventTypes.agentFileDeleted,
        seq: 5,
      );

      expect(find.text('删除了 5 个文件'), findsOneWidget);
      expect(find.textContaining('含 1 个已删除'), findsOneWidget);
    });

    testWidgets('TTS 语音分段不参与聚合（同秒 5 个仍逐条）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onDownloadAgentFile: (_) async {});
      // reports/tts/ 下的语音产物：即使同秒且达阈值，也不得聚合成批量卡。
      for (var i = 0; i < 5; i++) {
        await pushFile(
          tester,
          path: 'reports/tts/turn_1/speech_turn_1_$i.mp3',
          mimeType: 'audio/mpeg',
          seq: i + 1,
        );
      }

      expect(find.byType(AgentFileBatchCard), findsNothing);
      // 语音产物渲染为语音条目（TtsStreamKind != null），仍是 5 个卡片。
      expect(find.byType(AgentFileCard), findsNWidgets(5));
    });

    testWidgets('未注入任何文件回调时，批量卡仍渲染摘要（只读时间线）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushFiles(tester, 5);

      // 摘要不依赖回调（与单卡不同：单卡没回调就只是个禁用按钮）。
      expect(find.byType(AgentFileBatchCard), findsOneWidget);
      expect(find.text('生成了 5 个文件'), findsOneWidget);
    });
  });

  group('ConversationPage 预览透传（issue #8）', () {
    /// 推一个单文件（不触发批量聚合，便于定位单卡）。
    Future<void> pushSingleFile(
      WidgetTester tester, {
      String path = 'out/report.md',
      String? mimeType = 'text/markdown',
    }) => pushEvent(
      tester,
      EventTypes.agentFileCreated,
      sseEvent(
        EventTypes.agentFileCreated,
        id: 'e_$path',
        seq: 1,
        payload: {
          'relative_path': path,
          'ufs_file_id': 'ufs_$path',
          if (mimeType != null) 'mime_type': mimeType,
          'size_bytes': 1024,
        },
      ),
    );

    testWidgets('未注入 onPreviewAgentFile 时单卡不渲染预览按钮', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushSingleFile(tester);

      expect(find.byType(AgentFileCard), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-file-preview')), findsNothing);
    });

    testWidgets('注入后单卡渲染预览按钮，点击弹出对话框', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onPreviewAgentFile: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('hello'),
        ),
      );
      await pushSingleFile(tester);

      await tester.tap(find.byKey(const ValueKey('agent-file-preview')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsOneWidget,
      );
    });

    testWidgets('批量卡展开后每个成员也能预览（透传链路完整）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onPreviewAgentFile: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('hello'),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await pushSingleFile(tester, path: 'out/f$i.md');
      }

      expect(find.byType(AgentFileBatchCard), findsOneWidget);
      // 折叠态：成员未渲染，预览按钮也不存在。
      expect(find.byKey(const ValueKey('agent-file-preview')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('agent-file-batch-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-file-preview')),
        findsNWidgets(5),
      );
    });
  });
}
