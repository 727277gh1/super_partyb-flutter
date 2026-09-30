import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';

/// `SecureTokenStore` 的读写 round-trip 与故障语义测试。
///
/// ## 为什么需要假后端
///
/// `flutter_secure_storage` 在 `flutter test`（无平台通道）下调用会抛
/// `MissingPluginException`。这里用 `FlutterSecureStoragePlatform.instance`
/// 换上一个内存实现，使「序列化 → 写入 → 读取 → 反序列化」这条链路能被真跑，
/// 而不是只测「方法存在」。
///
/// ## 这个测试防的是什么
///
/// 存储层最典型的 bug 是**静默丢字段**：`expires_at` 忘了序列化，读回来
/// `expiresAt == null`，于是 [StoredTokens.isExpired] 永远返回 false，
/// token 过期后仍被当成有效值发给服务端 → 每次请求都 401，且看起来像
/// 「后端挂了」。故这里对每个字段都做 round-trip 断言。
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform
    with MockPlatformInterfaceMixin {
  final Map<String, String> data = {};

  /// 让 write/read 抛异常，用于测故障分支。
  bool failWrite = false;
  bool failRead = false;
  bool failDelete = false;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (failWrite) throw StateError('write failed');
    data[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failRead) throw StateError('read failed');
    return data[key];
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => data.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failDelete) throw StateError('delete failed');
    data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(data);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    data.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStoragePlatform backend;
  late SecureTokenStore store;

  setUp(() {
    backend = _FakeSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = backend;
    store = SecureTokenStore();
  });

  group('SecureTokenStore token round-trip', () {
    test('未写入时读取返回 null（不是抛异常）', () async {
      expect(await store.read(), isNull);
    });

    test('写入后读取，所有字段完整还原', () async {
      final expires = DateTime.utc(2026, 9, 28, 12, 0, 0);
      final original = StoredTokens(
        accessToken: 'at_value',
        refreshToken: 'rt_value',
        expiresAt: expires,
        tokenType: 'Bearer',
        scope: 'openid profile email',
      );

      await store.write(original);
      final loaded = await store.read();

      expect(loaded, isNotNull);
      expect(loaded!.accessToken, 'at_value');
      expect(loaded.refreshToken, 'rt_value');
      expect(loaded.tokenType, 'Bearer');
      expect(loaded.scope, 'openid profile email');
      expect(
        loaded.expiresAt,
        expires,
        reason: 'expiresAt 丢失会让 isExpired 永远返回 false',
      );
      expect(loaded.canRefresh, isTrue);
    });

    test('expiresAt 存的是 UTC 绝对时刻（不受本地时区影响）', () async {
      final expires = DateTime.utc(2030, 1, 2, 3, 4, 5);
      await store.write(StoredTokens(accessToken: 'at', expiresAt: expires));

      // 直接看落盘内容：必须是 UTC ISO8601 且带 Z。
      final raw = backend.data[SecureTokenStore.storageKey]!;
      expect(raw, contains('2030-01-02T03:04:05'));
      expect(raw, contains('Z'));

      final loaded = await store.read();
      expect(loaded!.expiresAt!.isUtc, isTrue);
      expect(loaded.expiresAt, expires);
    });

    test('可选字段为 null 时不写入、读回仍为 null', () async {
      await store.write(const StoredTokens(accessToken: 'at_only'));
      final raw = backend.data[SecureTokenStore.storageKey]!;
      expect(raw, isNot(contains('refresh_token')));
      expect(raw, isNot(contains('expires_at')));

      final loaded = await store.read();
      expect(loaded!.refreshToken, isNull);
      expect(loaded.expiresAt, isNull);
      expect(loaded.canRefresh, isFalse);
      // 无 expiresAt 时视为未过期（服务端没给信息，不该由客户端猜）
      expect(loaded.isExpired(), isFalse);
    });

    test('覆盖写入替换旧值（不残留旧 refresh_token）', () async {
      await store.write(
        const StoredTokens(accessToken: 'old_at', refreshToken: 'old_rt'),
      );
      await store.write(const StoredTokens(accessToken: 'new_at'));

      final loaded = await store.read();
      expect(loaded!.accessToken, 'new_at');
      expect(loaded.refreshToken, isNull, reason: '旧 refresh_token 不得残留');
    });

    test('clear 后读取返回 null', () async {
      await store.write(const StoredTokens(accessToken: 'at'));
      expect(await store.read(), isNotNull);

      await store.clear();
      expect(await store.read(), isNull);
      expect(backend.data.containsKey(SecureTokenStore.storageKey), isFalse);
    });

    test('只占一个存储键（刷新时整块原子更新）', () async {
      await store.write(
        const StoredTokens(accessToken: 'a', refreshToken: 'r'),
      );
      expect(backend.data.keys, [SecureTokenStore.storageKey]);
    });

    test('存储键带版本号（便于将来无损迁移格式）', () {
      expect(SecureTokenStore.storageKey, endsWith('.v1'));
      expect(SecureTokenStore.storageKey, startsWith('spb.'));
    });
  });

  group('SecureTokenStore 故障语义', () {
    test('写入失败抛 StorageError（不静默吞掉）', () async {
      backend.failWrite = true;
      await expectLater(
        store.write(const StoredTokens(accessToken: 'at')),
        throwsA(isA<StorageError>()),
      );
    });

    test('清除失败抛 StorageError（登出后凭证仍在设备上属安全问题）', () async {
      backend.failDelete = true;
      await expectLater(store.clear(), throwsA(isA<StorageError>()));
    });

    test('读取失败返回 null（等同未登录，不让应用崩在启动路径）', () async {
      backend.failRead = true;
      expect(await store.read(), isNull);
    });

    test('内容损坏（非法 JSON）返回 null 而非抛异常', () async {
      backend.data[SecureTokenStore.storageKey] = '{not json';
      expect(await store.read(), isNull);
    });

    test('内容非 JSON 对象（如数组）返回 null', () async {
      backend.data[SecureTokenStore.storageKey] = '[1,2,3]';
      expect(await store.read(), isNull);
    });

    test('空串内容视为未登录', () async {
      backend.data[SecureTokenStore.storageKey] = '';
      expect(await store.read(), isNull);
    });

    test('expires_at 无法解析时按 null 处理（不崩）', () async {
      backend.data[SecureTokenStore.storageKey] =
          '{"access_token":"at","expires_at":"not-a-date"}';
      final loaded = await store.read();
      expect(loaded!.accessToken, 'at');
      expect(loaded.expiresAt, isNull);
    });
  });

  group('SecureTokenStore 与 SessionManager 协作', () {
    test('写入的 token 能被 SessionManager 判为有效', () async {
      await store.write(
        StoredTokens(
          accessToken: 'at_valid',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      final manager = SessionManager(
        store: store,
        refresher: (_) async => null,
      );
      expect(await manager.currentAccessToken(), 'at_valid');
    });

    test('已过期的 token 且无 refresh_token 时返回 null（触发重新登录）', () async {
      await store.write(
        StoredTokens(
          accessToken: 'at_expired',
          expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        ),
      );

      final manager = SessionManager(
        store: store,
        refresher: (_) async => null,
      );
      expect(await manager.currentAccessToken(), isNull);
    });

    test('刷新成功后写回安全存储（下次启动可直接用）', () async {
      await store.write(
        StoredTokens(
          accessToken: 'at_old',
          refreshToken: 'rt_1',
          expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        ),
      );

      final manager = SessionManager(
        store: store,
        refresher: (current) async => StoredTokens(
          accessToken: 'at_new',
          refreshToken: 'rt_2',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      expect(await manager.currentAccessToken(), 'at_new');
      // 关键：必须落盘，否则每次启动都要刷新一次
      final persisted = await store.read();
      expect(persisted!.accessToken, 'at_new');
      expect(persisted.refreshToken, 'rt_2');
    });
  });
}
