import 'package:spb_core/spb_core.dart';

import 'database.dart';

/// 本地偏好（键值）存储。
///
/// ## 为什么不用 `shared_preferences`
///
/// 同步相关的偏好（`local_root` / `include_media` / `max_file_size` /
/// `scope` / `since_days`）与同步状态**必须一起更新**：换目录时既改偏好又清
/// 状态，若两者分属不同存储就会出现「目录已改、状态没清」的中间态（表现为
/// 「换目录后同步显示成功，但新目录是空的」）。
///
/// 因此偏好与状态同库（见 `database.dart` 的 [SyncBindings] 说明），
/// 由 drift 的事务保证一致性。
///
/// ⚠️ 会话凭证**不在这里**：token 必须加密存储（见 `secure_token_store.dart`），
/// 明文落盘等于把登录态交给任何能读应用数据目录的进程。
class PreferencesStore {
  PreferencesStore(this._db);

  final AppDatabase _db;

  /// 读字符串；不存在返回 null。
  Future<String?> getString(String key) async {
    final rows = await (_db.select(
      _db.preferences,
    )..where((t) => t.key.equals(key))).get();
    return rows.isEmpty ? null : rows.first.value;
  }

  /// 写字符串（覆盖）。
  Future<void> setString(String key, String value) async {
    try {
      await _db
          .into(_db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(key: key, value: value),
          );
    } catch (e) {
      throw StorageError('写入偏好失败（$key）：$e', cause: e);
    }
  }

  /// 读布尔；不存在或值无法解析时返回 [defaultValue]。
  ///
  /// 不抛异常：偏好是「配置」而非「数据」，一个坏值不该让应用起不来。
  /// 解析失败时返回默认值并记日志，便于发现写入方写错了格式。
  Future<bool> getBool(String key, {required bool defaultValue}) async {
    final raw = await getString(key);
    if (raw == null) return defaultValue;
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    SpbLog.warn('偏好值不是合法布尔，使用默认值', {'key': key, 'value': raw});
    return defaultValue;
  }

  Future<void> setBool(String key, {required bool value}) =>
      setString(key, value ? 'true' : 'false');

  /// 读整数；不存在或无法解析时返回 [defaultValue]。
  Future<int> getInt(String key, {required int defaultValue}) async {
    final raw = await getString(key);
    if (raw == null) return defaultValue;
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      SpbLog.warn('偏好值不是合法整数，使用默认值', {'key': key, 'value': raw});
      return defaultValue;
    }
    return parsed;
  }

  Future<void> setInt(String key, {required int value}) =>
      setString(key, '$value');

  /// 删除单个键。
  Future<void> remove(String key) async {
    await (_db.delete(_db.preferences)..where((t) => t.key.equals(key))).go();
  }
}
