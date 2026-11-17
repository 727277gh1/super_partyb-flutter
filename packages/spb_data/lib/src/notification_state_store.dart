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

  /// 上一次后台检查**成功**的时刻（null = 从未成功过）。
  ///
  /// 设置页用它回答「这条链路到底跑过没有」——`WorkManager` 是尽力而为的，
  /// 没有这个读数时用户和我们都只能猜。失败不写：一个旧的时刻配上「跑过」
  /// 的暗示比没有更误导。
  Future<DateTime?> lastCheckAt() async =>
      DateTime.tryParse(await preferences.getString(_lastCheckKey) ?? '');

  Future<void> markChecked(DateTime at) =>
      preferences.setString(_lastCheckKey, at.toUtc().toIso8601String());

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
              if (row.expiresAt != null)
                'expires_at': row.expiresAt!.toUtc().toIso8601String(),
            }),
          ),
        ),
      );

  Future<void> close() => db.close();
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
