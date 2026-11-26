import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_mobile/providers.dart';

class MemoryPreferences implements PreferencesStore {
  final values = <String, String>{};
  bool failRemove = false;

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async {
    if (failRemove) throw StateError('磁盘故障');
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _IdentityApi implements ChatApi {
  String userId = 'A';
  int calls = 0;
  Completer<CurrentUser>? pending;
  bool offline = false;

  @override
  Future<CurrentUser> me() async {
    calls++;
    if (offline) throw const NetworkError('离线');
    return pending?.future ?? CurrentUser(id: userId, email: '', name: userId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ProviderContainer container;
  late _IdentityApi api;
  late MemoryPreferences preferences;
  late InMemoryTokenStore tokens;

  setUp(() async {
    api = _IdentityApi();
    preferences = MemoryPreferences();
    tokens = InMemoryTokenStore();
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        chatApiProvider.overrideWithValue(api),
        tokenStoreProvider.overrideWithValue(tokens),
        preferencesStoreProvider.overrideWithValue(preferences),
      ],
    );
    container.read(authStateProvider);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() => container.dispose());

  Future<void> login(String id) async {
    api.userId = id;
    final error = await container
        .read(authStateProvider.notifier)
        .importSession('access_token=test_$id');
    expect(error, isNull);
  }

  test('退出 A 后登录 B：身份、缓存与持久化归属全部更新', () async {
    await login('A');
    expect(await container.read(currentUserIdProvider.future), 'A');
    expect(await container.read(cachedUserIdProvider.future), 'A');
    await container.read(authStateProvider.notifier).signOut();
    expect(await container.read(cachedUserIdProvider.future), isNull);
    expect(await preferences.getString(cachedUserIdPrefKey), isNull);
    await login('B');
    expect(await container.read(currentUserIdProvider.future), 'B');
    expect(await container.read(cachedUserIdProvider.future), 'B');
    expect(await preferences.getString(cachedUserIdPrefKey), 'B');
    expect(api.calls, 2);
  });

  test('会话失效后重新登录也重新读取身份', () async {
    await login('A');
    expect(await container.read(currentUserIdProvider.future), 'A');
    container.read(authStateProvider.notifier).markUnauthenticated('已失效');
    expect(await container.read(cachedUserIdProvider.future), isNull);
    await login('B');
    expect(await container.read(currentUserIdProvider.future), 'B');
    expect(await preferences.getString(cachedUserIdPrefKey), 'B');
  });

  test('新账号联网失败时不回落旧账号缓存', () async {
    await login('A');
    await container.read(currentUserIdProvider.future);
    await login('B');
    api.offline = true;
    final failed = Completer<void>();
    final sub = container.listen(currentUserProvider, (_, next) {
      if (next.hasError && !failed.isCompleted) failed.complete();
    }, fireImmediately: true);
    addTearDown(sub.close);
    await failed.future;
    expect(await container.read(cachedUserIdProvider.future), isNull);
    expect(await preferences.getString(cachedUserIdPrefKey), isNull);
  });

  test('旧账号请求迟到时不得回写新账号的缓存归属', () async {
    await login('A');
    final old = Completer<CurrentUser>();
    api.pending = old;
    final subscription = container.listen(currentUserProvider, (_, _) {});
    addTearDown(subscription.close);
    await Future<void>.delayed(Duration.zero);
    await container.read(authStateProvider.notifier).signOut();
    api.pending = null;
    await login('B');
    expect(await container.read(currentUserIdProvider.future), 'B');
    old.complete(const CurrentUser(id: 'A', email: '', name: 'A'));
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(currentUserIdProvider.future), 'B');
    expect(await preferences.getString(cachedUserIdPrefKey), 'B');
  });

  test('清理归属失败时不能落盘新账号凭证', () async {
    await login('A');
    await container.read(currentUserIdProvider.future);
    preferences.failRemove = true;
    final error = await container
        .read(authStateProvider.notifier)
        .importSession('access_token=test_B');
    expect(error, isNotNull);
    expect((await tokens.read())?.accessToken, 'test_A');
    expect(await container.read(cachedUserIdProvider.future), isNull);
  });

  test('缓存磁盘故障不应阻止退出登录', () async {
    await login('A');
    await container.read(currentUserIdProvider.future);
    preferences.failRemove = true;
    await container.read(authStateProvider.notifier).signOut();
    expect(await tokens.read(), isNull);
    expect(container.read(authStateProvider).isUnauthenticated, isTrue);
    expect(await container.read(cachedUserIdProvider.future), isNull);
  });

  test('同一会话离线恢复仍能读取已有缓存归属', () async {
    await preferences.setString(cachedUserIdPrefKey, 'A');
    await tokens.write(const StoredTokens(accessToken: 'test_A'));
    await container.read(authStateProvider.notifier).restore();
    api.offline = true;
    final failed = Completer<void>();
    final sub = container.listen(currentUserProvider, (_, next) {
      if (next.hasError && !failed.isCompleted) failed.complete();
    }, fireImmediately: true);
    addTearDown(sub.close);
    await failed.future;
    expect(await container.read(cachedUserIdProvider.future), 'A');
  });
}
