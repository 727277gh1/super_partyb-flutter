import 'package:spb_core/spb_core.dart';

import 'preferences_store.dart';

/// 离线缓存的用户归属；只存 `/api/auth/me` 的结果，不参与请求鉴权。
///
/// 换凭证前必须 [clear]。清理与保存串行，且旧会话的网络响应携带旧 [generation]，
/// 因此既不会晚到回写，也不会让已经开始的旧写入越过清理操作（issue #103）。
class SessionIdentityCache {
  SessionIdentityCache(this._preferences);

  static const preferenceKey = 'auth.cached_user_id';
  final PreferencesStore _preferences;
  Future<void> _pending = Future<void>.value();
  int _generation = 0;
  bool _acceptWrites = true;
  bool _canRead = true;

  int get generation => _generation;

  /// 新凭证已写入（冷启动恢复也可调用），旧请求从此不能保存身份。
  void beginSession() {
    _generation++;
    _acceptWrites = true;
  }

  Future<String?> read() async {
    final generation = _generation;
    await _pending;
    if (!_canRead) return null;
    final id = await _preferences.getString(preferenceKey);
    return generation == _generation && id != null && id.isNotEmpty ? id : null;
  }

  Future<void> save(String userId, {required int generation}) => _enqueue(
    () async {
      if (!_acceptWrites || generation != _generation || userId.isEmpty) return;
      await _preferences.setString(preferenceKey, userId);
      if (generation == _generation) _canRead = true;
    },
  );

  Future<void> clear() {
    _generation++;
    _acceptWrites = false;
    _canRead = false;
    return _enqueue(() async {
      try {
        await _preferences.remove(preferenceKey);
      } on Object catch (e) {
        // 凭证入口只处理领域错误，不能让 SQLite 异常绕过登录失败提示。
        throw StorageError('清除会话缓存归属失败', cause: e);
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    // 调用者仍拿到原始失败；队列本身必须继续，避免一次磁盘失败阻断下一次清理。
    _pending = result.catchError((Object error) {
      SpbLog.warn('更新会话缓存归属失败', {'error': error.toString()});
    });
    return result;
  }
}
