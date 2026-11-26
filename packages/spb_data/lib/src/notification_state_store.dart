import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';

import 'database.dart';
import 'preferences_store.dart';

/// 单独的小库隔离通知/凭证协调，避免网络刷新期间占用聊天缓存、文件同步的写锁。
/// 复用现有 schema 和迁移，只使用 preferences；数据库不保存 token。
class NotificationStateStore implements ConfirmationReceiptStore {
  NotificationStateStore(this.db) : preferences = PreferencesStore(db);

  factory NotificationStateStore.open(Future<File> Function() resolve) =>
      NotificationStateStore(
        AppDatabase(
          LazyDatabase(() async {
            final file = await resolve();
            await file.parent.create(recursive: true);
            return NativeDatabase.createInBackground(
              file,
              setup: (db) => db.execute('PRAGMA busy_timeout = 90000'),
            );
          }),
        ),
      );

  final AppDatabase db;
  final PreferencesStore preferences;
  final Object _zoneKey = Object();
  static const _receiptsKey = 'notifications.receipts.v1';
  static const _generationKey = 'notifications.session_generation';
  static const _lastCheckKey = 'notifications.last_success';
  static const _lastResultKey = 'notifications.last_check_result.v1';

  /// 上一次后台检查**成功**的时刻（null = 从未成功过）。
  ///
  /// 设置页用它回答「这条链路到底跑过没有」——`WorkManager` 是尽力而为的，
  /// 没有这个读数时用户和我们都只能猜。失败不写：一个旧的时刻配上「跑过」
  /// 的暗示比没有更误导。
  Future<DateTime?> lastCheckAt() async =>
      DateTime.tryParse(await preferences.getString(_lastCheckKey) ?? '');

  Future<void> markChecked(DateTime at) =>
      preferences.setString(_lastCheckKey, at.toUtc().toIso8601String());

  /// 设置页的完整读数：上次成功时刻 + **最近一次**（任意结局）。
  ///
  /// 两者缺一不可：`lastSuccessAt` 回答「跑通过没有」，`last` 回答「这一次
  /// 为什么没弹」。只给前者时，用户报「收不到通知」我们区分不了「在前台」
  /// 「没权限」「在退避」。
  Future<BackgroundCheckReport> backgroundCheckReport() async =>
      BackgroundCheckReport(
        lastSuccessAt: await lastCheckAt(),
        last: _decodeResult(await preferences.getString(_lastResultKey)),
      );

  /// 记一轮后台检查的结局（成功也写）。
  ///
  /// 成功时顺带刷新 [lastCheckAt]：两者是同一次事实的两个视角，分成两处写
  /// 会出现「最近一次成功、上次成功时刻却是旧的」这种自相矛盾的读数。
  ///
  /// 失败/跳过**不动** [lastCheckAt]——旧时刻代表「确实成功过」，不是本轮。
  Future<void> recordBackgroundCheck(BackgroundCheckResult result) async {
    if (result.outcome == BackgroundCheckOutcome.ok) {
      await markChecked(result.at);
    }
    await preferences.setString(
      _lastResultKey,
      jsonEncode({
        'outcome': result.outcome.name,
        'at': result.at.toUtc().toIso8601String(),
        if (result.skip != null) 'skip': result.skip!.name,
        if (result.failure != null) 'failure': result.failure!.name,
        if (result.unread != null) 'unread': result.unread,
        if (result.fetched != null) 'fetched': result.fetched,
        if (result.shown != null) 'shown': result.shown,
        if (result.error != null) 'error': result.error,
      }),
    );
  }

  /// 解析失败一律当「没有这条记录」：诊断读数坏掉不能连累排程与设置页。
  static BackgroundCheckResult? _decodeResult(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.tryParse(data['at'] as String? ?? '');
      final outcome = _byName(BackgroundCheckOutcome.values, data['outcome']);
      if (at == null || outcome == null) return null;
      return BackgroundCheckResult(
        outcome: outcome,
        at: at,
        skip: _byName(BackgroundCheckSkip.values, data['skip']),
        failure: _byName(BackgroundCheckFailure.values, data['failure']),
        unread: data['unread'] as int?,
        fetched: data['fetched'] as int?,
        shown: data['shown'] as int?,
        error: data['error'] as String?,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<T> exclusive<T>(Future<T> Function() action) {
    if (Zone.current[_zoneKey] == true) return action();
    return db.transaction(() async {
      // 必须先写后读：SQLite 的写锁跨 engine/进程有效，崩溃会自动释放。
      // 不能使用 Dart Future 锁或 File.lock（POSIX 锁不隔离同进程的 engine）。
      await preferences.setString('notifications.mutex', '1');
      return runZoned(action, zoneValues: {_zoneKey: true});
    });
  }

  Future<int> generation() =>
      preferences.getInt(_generationKey, defaultValue: 0);

  Future<void> advanceSession() async {
    await preferences.setInt(_generationKey, value: await generation() + 1);
    await saveReceipts({});
  }

  @override
  Future<Map<String, ConfirmationReceipt>> loadReceipts() async {
    final raw = await preferences.getString(_receiptsKey);
    if (raw == null) return {};
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return data.map((id, value) {
      final row = value as Map<String, dynamic>;
      return MapEntry(
        id,
        ConfirmationReceipt(
          shown: row['shown'] == true,
          expiresAt: DateTime.tryParse(row['expires_at'] as String? ?? ''),
          revision: row['revision'] as String?,
        ),
      );
    });
  }

  @override
  Future<void> saveReceipts(Map<String, ConfirmationReceipt> receipts) =>
      preferences.setString(
        _receiptsKey,
        jsonEncode(
          receipts.map(
            (id, row) => MapEntry(id, {
              'shown': row.shown,
              if (row.revision != null) 'revision': row.revision,
              if (row.expiresAt != null)
                'expires_at': row.expiresAt!.toUtc().toIso8601String(),
            }),
          ),
        ),
      );

  Future<void> close() => db.close();
}

/// 按枚举 `name` 反查（未知值返回 null，不抛）。
///
/// 不用 `package:collection` 的 `firstOrNull`：本包只在测试里用它，为一行反查
/// 引一个运行期依赖不值得；而「升级/回滚时读到未来版本的枚举名」必须当成
/// 「没有这条记录」而不是异常。
T? _byName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// 凭证仍在 Keystore；所有 engine 的**登录、登出和 refresh** 共享数据库互斥。
///
/// 互斥只覆盖「会轮换 refresh_token 的写路径」：读是原子的（Keystore 按键读写），
/// 把它也塞进事务会让**每个 HTTP 请求**都做一次 SQLite 写事务（[NotificationStateStore.exclusive]
/// 靠写 mutex 键取写锁），既费电，又会排到另一个 engine 的刷新后面（最长 90 秒）。
class CoordinatedTokenStore implements ExclusiveTokenStore {
  CoordinatedTokenStore({
    required this.tokens,
    required this.state,
    required this.cancelNotification,
  });

  final TokenStore tokens;
  final NotificationStateStore state;
  final Future<void> Function(String) cancelNotification;

  @override
  Future<StoredTokens?> read() => tokens.read();

  @override
  Future<void> write(StoredTokens value) => state.exclusive(() async {
    await _resetNotifications();
    await tokens.write(value);
  });

  @override
  Future<void> clear() => state.exclusive(() async {
    await _resetNotifications();
    await tokens.clear();
  });

  Future<void> _resetNotifications() async {
    final receipts = await state.loadReceipts();
    for (final entry in receipts.entries) {
      if (entry.value.shown) await cancelNotification(entry.key);
    }
    await state.advanceSession();
  }

  @override
  Future<T> withExclusiveAccess<T>(Future<T> Function(TokenStore) action) =>
      state.exclusive(() => action(tokens));
}
