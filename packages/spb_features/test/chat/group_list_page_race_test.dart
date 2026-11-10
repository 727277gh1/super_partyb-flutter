import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

class _ControlledApi extends ChatApi {
  _ControlledApi() : super(Dio());
  List<ChatGroup> initial = [];
  final requests = <int>[];
  final nextPage = Completer<List<ChatGroup>>();
  final createdGroup = Completer<ChatGroup>();
  bool offline = false;

  @override
  Future<List<ChatGroup>> listGroups({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    requests.add(offset);
    if (offline) throw const NetworkError('离线');
    return offset == 0 ? initial : nextPage.future;
  }

  @override
  Future<ChatGroup> getGroup(String groupId) => createdGroup.future;
}

class _DelayedCache implements GroupCacheStore {
  final loaded = Completer<List<ChatGroup>>();
  List<ChatGroup> saved = [];

  @override
  Future<List<ChatGroup>> load(String userId) => loaded.future;

  @override
  Future<DateTime?> lastFetchedAt(String userId) async => DateTime(2026);

  @override
  Future<void> save(String userId, List<ChatGroup> groups) async {
    saved = List.of(groups);
  }

  @override
  Future<void> clear(String userId) async => saved = [];
}

ChatGroup group(String id, {bool snapshot = false}) => ChatGroup.fromJson({
  'id': id,
  'user_id': 'user_A',
  'title': id,
  'status': snapshot ? 'archived' : 'active',
  'created_at': '2026-11-09T00:00:00Z',
  'updated_at': '2026-11-09T00:00:00Z',
  if (snapshot)
    'archive_snapshot': {
      'id': 'snapshot_1',
      'version': 1,
      'status': 'ready',
      'archive_reason': 'explicit',
      'download_available': true,
      'site': {'status': 'ready', 'access_url': '/site/'},
      'links': {'markdown': '/snapshot/markdown'},
    },
});

Future<void> _pumpList(
  WidgetTester tester,
  _ControlledApi api, {
  Stream<GroupUpdate>? updates,
  GroupCacheStore? cache,
  int pageSize = 30,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: GroupListPage(
        api: api,
        groupUpdates: updates,
        cache: cache,
        userId: 'user_A',
        pageSize: pageSize,
        onOpenSnapshotSite: (_) async => true,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('改名事件不应移除归档结项入口', (tester) async {
    final api = _ControlledApi()..initial = [group('归档对话', snapshot: true)];
    final cache = _DelayedCache();
    final updates = StreamController<GroupUpdate>.broadcast();
    addTearDown(updates.close);
    await _pumpList(tester, api, updates: updates.stream, cache: cache);
    expect(find.text('结项记录'), findsOneWidget);
    updates.add(
      const GroupUpdate(op: GroupUpdateOp.title, groupId: '归档对话', title: '新标题'),
    );
    await tester.pump();
    expect(find.text('新标题'), findsOneWidget);
    expect(find.text('结项记录'), findsOneWidget);
    expect(cache.saved.single.archiveSnapshot, isNotNull);
  });

  testWidgets('刷新成功后旧离线缓存读取迟到不能覆盖新列表', (tester) async {
    final api = _ControlledApi()..offline = true;
    final cache = _DelayedCache();
    await _pumpList(tester, api, cache: cache);
    api
      ..offline = false
      ..initial = [group('刷新后的对话')];
    final refresh = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    await refresh.onRefresh();
    await tester.pump();
    cache.loaded.complete([group('旧缓存对话')]);
    await tester.pump();
    await tester.pump();
    expect(api.requests, [0, 0]);
    expect(find.text('刷新后的对话'), findsOneWidget);
    expect(find.text('旧缓存对话'), findsNothing);
    expect(find.textContaining('离线数据'), findsNothing);
    expect(cache.saved.single.title, '刷新后的对话');
  });

  testWidgets('翻页请求在途时刷新仍应重拉首页且丢弃旧响应', (tester) async {
    final api = _ControlledApi()
      ..initial = List.generate(30, (i) => group('首页_$i'));
    await _pumpList(tester, api);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    expect(api.requests, [0, 30]);
    final refresh = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    await refresh.onRefresh();
    api.nextPage.complete([group('旧分页结果')]);
    await tester.pump();
    await tester.pump();
    expect(api.requests, [0, 30, 0]);
    expect(find.text('旧分页结果'), findsNothing);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(0);
    await tester.pump();
    expect(find.text('首页_0'), findsOneWidget);
  });

  testWidgets('创建查询完成前收到删除不能复活已删除对话', (tester) async {
    final api = _ControlledApi();
    final updates = StreamController<GroupUpdate>.broadcast();
    addTearDown(updates.close);
    await _pumpList(tester, api, updates: updates.stream);
    updates.add(
      const GroupUpdate(
        op: GroupUpdateOp.created,
        groupId: '已删除对话',
        title: '已删除对话',
      ),
    );
    await tester.pump();
    updates.add(const GroupUpdate(op: GroupUpdateOp.deleted, groupId: '已删除对话'));
    await tester.pump();
    api.createdGroup.complete(group('已删除对话'));
    await tester.pump();
    expect(find.text('已删除对话'), findsNothing);
  });
  testWidgets('创建查询在删除后返回 404 时不能插入占位条目', (tester) async {
    final api = _ControlledApi();
    final updates = StreamController<GroupUpdate>.broadcast();
    addTearDown(updates.close);
    await _pumpList(tester, api, updates: updates.stream);
    updates.add(
      const GroupUpdate(
        op: GroupUpdateOp.created,
        groupId: '已删除对话',
        title: '已删除对话',
      ),
    );
    await tester.pump();
    updates.add(const GroupUpdate(op: GroupUpdateOp.deleted, groupId: '已删除对话'));
    await tester.pump();
    api.createdGroup.completeError(const HttpError(404, '不存在'));
    await tester.pump();
    expect(find.text('已删除对话'), findsNothing);
  });
}
