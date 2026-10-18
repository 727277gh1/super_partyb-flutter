import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 用平台安全存储持久化待验证的登录请求（`state` + PKCE verifier）。
///
/// ## 为什么必须持久化（这是移动端登录回调失败的静默原因）
///
/// 授权流程把用户带到**外部浏览器**——那是一个独立进程，应用在此期间完全
/// 可能被系统回收（Android 低内存时很常见，用户在浏览器里多停留一会儿就够
/// 了）。回调到达时若应用已重启，内存实现的 `state`/`code_verifier` 已丢失，
/// 接收器读不到「进行中的登录」→ 拒绝回调，表现为**「登录成功回到应用，但
/// 什么也没发生」**，用户无法判断是自己操作错了还是应用坏了。
///
/// ## 为什么必须用安全存储而非 SharedPreferences
///
/// `code_verifier` 是 PKCE 的另一半：授权 URL 里带的是 `code_challenge`
/// （SHA256 不可逆），但拿到 code 后要用 verifier 才能换 token。泄漏 verifier
/// + code 即可冒充本应用换出会话。故它与 token 同级，走 Keychain /
/// Keystore / libsecret / DPAPI。
///
/// ## 存储形态：单键 JSON（与 `SecureTokenStore` 同构）
///
/// `state` 与 verifier 必须一起读写：分键存储下若进程在两次写入之间被杀，
/// 会留下「能过 state 校验但没有 verifier」这种自相矛盾的状态——比完全没有
/// 记录更糟，因为它会走到换 token 时才失败。
///
/// ## 为什么带 TTL（默认 10 分钟）
///
/// 登录是一次**几分钟内完成的交互**，不是长期状态。留 TTL 的理由：
///
/// - **过期条目是真垃圾**：用户在浏览器里放弃登录后，条目会永久留在设备
///   加密存储里（删不掉，因为没有任何 UI 指向它）；
/// - **它同时是一个 CSRF 窗口**：一条陈旧记录意味着某个时刻收到的回调
///   能通过 state 校验。窗口越小越好；
/// - 10 分钟足够走完一次 IdP 登录（含输密码、MFA），且用户中途放弃也不会
///   留下长期状态。
///
/// 读取时超时即丢弃（并清掉），**不返回**给调用方——过期的 state 不能用来
/// 校验任何回调。
class SecurePendingAuthStore implements PendingAuthRequestStore {
  SecurePendingAuthStore({
    FlutterSecureStorage? storage,
    this.ttl = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _now = now ?? _utcNow;

  final FlutterSecureStorage _storage;

  /// 登录请求的有效期，见类文档。
  final Duration ttl;

  /// 可注入时钟（测试用）。
  final DateTime Function() _now;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// 存储键名。带应用前缀与版本号：格式变更时换版本号即可自然丢弃旧数据。
  static const String storageKey = 'spb.pending_auth.v1';

  @override
  Future<void> put(PendingAuthRequest request) async {
    final payload = jsonEncode({
      'state': request.state,
      'code_verifier': request.pkce.verifier,
      'code_challenge': request.pkce.challenge,
      'created_at': _now().toUtc().toIso8601String(),
    });
    try {
      await _storage.write(key: storageKey, value: payload);
    } catch (e) {
      // 写失败必须让调用方知道：静默吞掉会导致「浏览器已打开、回调必失败」，
      // 而用户看到的只是「登录后没反应」，无从定位。
      throw StorageError('写入安全存储失败', cause: e);
    }
  }

  @override
  Future<PendingAuthRequest?> consume() async {
    final request = await _readFresh();
    // 无论读到什么（含「已过期」），都要把记录删掉：consume 是一次性的，
    // 留着会允许同一个回调链接被重放。
    await _delete();
    return request;
  }

  /// 读取仍然有效的请求；无效（不存在 / 格式损坏 / 已过期）返回 null。
  Future<PendingAuthRequest?> _readFresh() async {
    String? raw;
    try {
      raw = await _storage.read(key: storageKey);
    } catch (e) {
      // 读失败（平台通道异常 / Linux 上 keyring 不可用）不该让应用崩溃：
      // 返回 null 等同「没有进行中的登录」，用户重新发起登录即可。
      SpbLog.warn('读取待验证登录请求失败', {'error': e.toString()});
      return null;
    }
    if (raw == null || raw.isEmpty) return null;

    try {
      final json = jsonDecode(raw);
      if (json is! Map) {
        SpbLog.warn('待验证登录请求格式异常（非 JSON 对象）');
        return null;
      }
      return _fromJson(Map<String, dynamic>.from(json));
    } catch (e) {
      // 解码失败（版本不一致 / 数据损坏）：当作没有进行中的登录。
      SpbLog.warn('解析待验证登录请求失败', {'error': e.toString()});
      return null;
    }
  }

  Future<void> _delete() async {
    try {
      await _storage.delete(key: storageKey);
    } catch (e) {
      // 删除失败必须暴露：残留记录意味着回调可被重放。
      throw StorageError('清除安全存储失败', cause: e);
    }
  }

  PendingAuthRequest? _fromJson(Map<String, dynamic> json) {
    final state = json['state']?.toString();
    final verifier = json['code_verifier']?.toString();
    final challenge = json['code_challenge']?.toString();
    if (state == null ||
        state.isEmpty ||
        verifier == null ||
        verifier.isEmpty ||
        challenge == null ||
        challenge.isEmpty) {
      SpbLog.warn('待验证登录请求缺少必需字段');
      return null;
    }

    final createdRaw = json['created_at']?.toString();
    final createdAt = createdRaw == null || createdRaw.isEmpty
        ? null
        : DateTime.tryParse(createdRaw)?.toUtc();
    if (createdAt == null) {
      // 没有时间戳就无法判断是否过期。按「已过期」处理而不是「永久有效」：
      // 失效的代价只是让用户重新点一次登录，而误判为有效会留下一个
      // 无界的 CSRF 窗口。
      SpbLog.warn('待验证登录请求缺少 created_at，按已过期处理');
      return null;
    }
    if (_now().difference(createdAt) > ttl) {
      SpbLog.info('待验证登录请求已过期，丢弃');
      return null;
    }

    return PendingAuthRequest(
      state: state,
      pkce: PkcePair(verifier: verifier, challenge: challenge),
    );
  }
}
