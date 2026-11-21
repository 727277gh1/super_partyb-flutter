import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';

/// `SecurePendingAuthStore` 的持久化与 TTL 语义测试。
///
/// ## 为什么需要假后端
///
/// `flutter_secure_storage` 在 `flutter test`（无平台通道）下调用会抛
/// `MissingPluginException`。用 `FlutterSecureStoragePlatform.instance`
/// 换上内存实现，使「序列化 → 写入 → 读取 → 反序列化」真跑，而不是只测
/// 「方法存在」。
///
/// ## 这个测试防的是什么
///
/// - **重放**：consume 不是一次性的话，重放同一个回调链接就能反复换 token；
/// - **跨实例恢复**：持久化的全部意义就在「进程被杀后回来还能消费」——
///   若写入的字段丢了，恢复出来的请求会在换 token 时才失败；
/// - **TTL**：过期条目是一个无界的 CSRF 窗口，必须被丢弃。
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform
    with MockPlatformInterfaceMixin {
  final Map<String, String> data = {};
  bool failWrite = false;

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
  }) async => data[key];

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

  const request = PendingAuthRequest(
    state: 'st_1',
    pkce: PkcePair(verifier: 'verifier_value', challenge: 'ch_1'),
  );

  late _FakeSecureStoragePlatform platform;
  setUp(() {
    platform = _FakeSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = platform;
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = _FakeSecureStoragePlatform();
  });

  SecurePendingAuthStore store({DateTime Function()? now}) =>
      SecurePendingAuthStore(now: now ?? () => DateTime.utc(2026, 1, 1, 12));

  group('持久化与消费', () {
    test('round-trip：state 与 PKCE 两半都完整恢复', () async {
      final s = store();
      await s.put(request);

      final got = await s.consume();
      expect(got, isNotNull);
      expect(got!.state, 'st_1');
      expect(got.pkce.verifier, 'verifier_value');
      expect(got.pkce.challenge, 'ch_1');
    });

    test('consume 是一次性的（防重放同一个回调链接）', () async {
      final s = store();
      await s.put(request);

      expect(await s.consume(), isNotNull);
      expect(await s.consume(), isNull, reason: '同一个 state 不得被消费两次');
    });

    test('put 覆盖旧请求（用户取消后重新发起登录）', () async {
      final s = store();
      await s.put(request);
      await s.put(
        const PendingAuthRequest(
          state: 'st_2',
          pkce: PkcePair(verifier: 'v2', challenge: 'ch_2'),
        ),
      );

      final got = await s.consume();
      expect(got!.state, 'st_2');
    });

    test('跨实例恢复：新 store（模拟进程重启）能消费旧 store 写入的请求', () async {
      await store().put(request);

      // 新实例 = 应用重启。内存实现到这里已经是 null——这正是它被替换的原因。
      final got = await store().consume();
      expect(got, isNotNull, reason: '进程被回收后回调仍须能完成 state 校验');
      expect(got!.pkce.verifier, 'verifier_value');
      expect(await store().consume(), isNull, reason: '一次性语义跨实例仍成立');
    });
  });

  group('TTL（过期条目必须被丢弃）', () {
    test('超时的请求返回 null（过期的 state 不能校验回调）', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final s = store(now: () => now);
      await s.put(request);

      now = now.add(const Duration(minutes: 11));
      expect(
        await s.consume(),
        isNull,
        reason: '超过 TTL 的条目是一个无界 CSRF 窗口，必须被丢弃',
      );
    });

    test('TTL 边界内仍然有效（10 分钟内完成登录是正常时长）', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final s = store(now: () => now);
      await s.put(request);

      now = now.add(const Duration(minutes: 9));
      expect(await s.consume(), isNotNull);
    });

    test('过期条目也被删除（不留永久垃圾）', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final s = store(now: () => now);
      await s.put(request);

      now = now.add(const Duration(minutes: 11));
      await s.consume();
      expect(platform.data, isEmpty, reason: '过期条目不该留在加密存储里');
    });

    test('缺 created_at 的记录按已过期处理（不误判为永久有效）', () async {
      // 手工写入一条没有时间戳的记录（模拟损坏 / 手工篡改）。
      platform.data[SecurePendingAuthStore.storageKey] =
          '{"state":"st_1","code_verifier":"v","code_challenge":"c"}';

      final got = await store().consume();
      expect(got, isNull, reason: '无法判断过期就必须视为过期，否则留下无界 CSRF 窗口');
    });
  });

  group('故障语义', () {
    test('写失败抛 StorageError（静默吞掉 = 浏览器已打开但回调必失败）', () async {
      platform.failWrite = true;
      await expectLater(store().put(request), throwsA(isA<StorageError>()));
    });

    test('读失败按「没有进行中的登录」处理（不崩启动流程）', () async {
      await store().put(request);
      // 直接把存储内容改成非法 JSON，模拟平台层数据损坏。
      platform.data[SecurePendingAuthStore.storageKey] = 'not-json';

      expect(await store().consume(), isNull);
    });
  });
}
