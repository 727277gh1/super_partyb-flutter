import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_data/spb_data.dart';

void main() {
  late AppDatabase db;
  late PreferencesStore preferences;
  late SessionIdentityCache cache;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    preferences = PreferencesStore(db);
    cache = SessionIdentityCache(preferences);
  });
  tearDown(() => db.close());

  test('冷启动可读已有归属，联网身份覆盖旧值', () async {
    await preferences.setString(SessionIdentityCache.preferenceKey, 'A');
    expect(await cache.read(), 'A');
    cache.beginSession();
    await cache.save('B', generation: cache.generation);
    expect(await cache.read(), 'B');
  });

  test('换会话后拒绝旧网络响应保存', () async {
    final oldGeneration = cache.generation;
    await cache.save('A', generation: oldGeneration);
    await cache.clear();
    cache.beginSession();
    await cache.save('B', generation: cache.generation);
    await cache.save('A', generation: oldGeneration);
    expect(await cache.read(), 'B');
  });

  test('清理等待已开始的写入，最终不会留下旧用户', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final blocked = _DelayedPreferences(db, started, release);
    cache = SessionIdentityCache(blocked);
    final writing = cache.save('A', generation: cache.generation);
    await started.future;
    final clearing = cache.clear();
    release.complete();
    await writing;
    await clearing;
    expect(await cache.read(), isNull);
    expect(
      await preferences.getString(SessionIdentityCache.preferenceKey),
      isNull,
    );
  });

  test('清理期间开始的身份请求也不能保存，直到新会话确认', () async {
    await cache.clear();
    await cache.save('A', generation: cache.generation);
    expect(await cache.read(), isNull);
    cache.beginSession();
    await cache.save('B', generation: cache.generation);
    expect(await cache.read(), 'B');
  });
}

class _DelayedPreferences extends PreferencesStore {
  _DelayedPreferences(super.db, this.started, this.release);
  final Completer<void> started;
  final Completer<void> release;

  @override
  Future<void> setString(String key, String value) async {
    started.complete();
    await release.future;
    await super.setString(key, value);
  }
}
