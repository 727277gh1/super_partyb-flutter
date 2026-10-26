import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 用平台安全存储持久化会话凭证。
///
/// ## 为什么必须用安全存储而非 SharedPreferences
///
/// access / refresh token 是**会话凭证本身**：拿到它就能冒充该用户调 API。
/// SharedPreferences 是明文 XML/plist（Android 上任何能读应用数据目录的进程
/// 都能取到），而本类走的 Keychain（iOS/macOS）、Keystore/EncryptedSharedPrefs
/// （Android）、libsecret（Linux）、DPAPI（Windows）由系统提供加密与访问控制。
///
/// ## 存储形态：单键 JSON
///
/// 整个 [StoredTokens] 序列化成一个 JSON 串存在一个键下，而非拆成
/// `access_token` / `refresh_token` / `expires_at` 三个键。理由：
///
/// - **原子性**：刷新时三个字段必须一起更新。分键存储下若进程在两次写入之间
///   被杀，会留下「新 access + 旧 refresh」这种自相矛盾的状态；
/// - **读写次数**：安全存储的每次操作都是一次平台通道往返（Android 上还可能
///   触发密钥派生），一次读写比三次快得多。
///
/// ## 为什么不缓存到内存
///
/// 每次 [read] 都真的去读平台存储。看起来慢，但：
/// - token 的消费方只有 [AuthInterceptor]，每个请求一次读，量不大；
/// - 加内存缓存就得处理「另一处登出后缓存未失效」的失效问题，
///   而这正是「登出后仍能发请求」这类安全 bug 的来源。
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// 存储键名。带应用前缀避免与同设备其他应用/其他用途的键冲突。
  static const String storageKey = 'spb.session.tokens.v1';

  @override
  Future<StoredTokens?> read() async {
    String? raw;
    try {
      raw = await _storage.read(key: storageKey);
    } catch (e) {
      // 读失败（平台通道异常 / Linux 上 keyring 不可用）不应让整个应用崩溃：
      // 返回 null 等同于「未登录」，用户重新登录即可。
      SpbLog.warn('读取安全存储失败，按未登录处理', {'error': e.toString()});
      return null;
    }
    if (raw == null || raw.isEmpty) return null;

    try {
      final json = jsonDecode(raw);
      if (json is! Map) {
        SpbLog.warn('安全存储中的凭证格式异常（非 JSON 对象）');
        return null;
      }
      return _tokensFromJson(Map<String, dynamic>.from(json));
    } catch (e) {
      // 解码失败说明写入方与读取方版本不一致（或数据损坏）。
      // 返回 null 让用户重新登录，比抛异常卡住启动流程更合理。
      SpbLog.warn('解析安全存储中的凭证失败', {'error': e.toString()});
      return null;
    }
  }

  @override
  Future<void> write(StoredTokens tokens) async {
    final payload = jsonEncode({
      'access_token': tokens.accessToken,
      if (tokens.refreshToken != null) 'refresh_token': tokens.refreshToken,
      // 存 ISO8601 UTC 串而非毫秒数：跨时区/跨设备人工排查时可读，
      // 且不会因「本地时区偏移」被误读。
      if (tokens.expiresAt != null)
        'expires_at': tokens.expiresAt!.toUtc().toIso8601String(),
      'token_type': tokens.tokenType,
      if (tokens.scope != null) 'scope': tokens.scope,
    });
    try {
      await _storage.write(key: storageKey, value: payload);
    } catch (e) {
      // 写失败必须让调用方知道：静默吞掉会导致「登录成功但下次启动又要求登录」
      // 这种极难定位的现象。
      throw StorageError('写入安全存储失败', cause: e);
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: storageKey);
    } catch (e) {
      // 清除失败同样抛出：登出后凭证仍在设备上属于安全问题，必须暴露。
      throw StorageError('清除安全存储失败', cause: e);
    }
  }

  /// 从 JSON 还原。
  ///
  /// 不放在 `StoredTokens` 上是因为那是 `spb_api` 的公共模型，而「存储格式」
  /// 是本包（`spb_data`）的实现细节——存储格式升级不应改公共 API。
  static StoredTokens _tokensFromJson(Map<String, dynamic> json) {
    final access = json['access_token']?.toString() ?? '';
    final expiresRaw = json['expires_at']?.toString();
    return StoredTokens(
      accessToken: access,
      refreshToken: _nonEmpty(json['refresh_token']),
      expiresAt: expiresRaw == null || expiresRaw.isEmpty
          ? null
          : DateTime.tryParse(expiresRaw)?.toUtc(),
      tokenType: _nonEmpty(json['token_type']) ?? 'Bearer',
      scope: _nonEmpty(json['scope']),
    );
  }

  static String? _nonEmpty(Object? v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }
}
