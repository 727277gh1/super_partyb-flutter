import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';

/// 对话页缩略图缓存（`ThumbnailMemo`）的容量与失效语义。
///
/// ## 这个测试防的是什么
///
/// G8（issue #70）是**两个**问题，修法不同、退化的表现也不同：
///
/// - 无界增长 → 加界后如果淘汰分支写错（如 `LinkedHashMap` 重复赋值不移动
///   位置、淘汰时没扣字节），内存会继续涨但**所有功能测试仍绿**；
/// - 版本覆盖不失效 → 令牌判据写错时缩略图继续显示旧内容，而「请求了没有」
///   这种断言必须用计数，不能看毫秒。
void main() {
  /// 让 `resolve` 内部 `.then` 的记账回调跑完。
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  group('命中与版本失效', () {
    test('同版本重复请求复用同一个 Future（不重复加载）', () async {
      final memo = ThumbnailMemo();
      var loads = 0;
      Future<List<int>?> load() async {
        loads++;
        return [1, 2, 3];
      }

      final first = memo.resolve('ufs_1', 'v1', load);
      final second = memo.resolve('ufs_1', 'v1', load);

      expect(identical(first, second), isTrue, reason: '并发窗口内必须共享同一 Future');
      await flush();
      expect(loads, 1);
      expect(memo.stats.hits, 1);
      expect(memo.stats.misses, 1);
    });

    test('版本令牌变化 → 逐出旧条目并重新加载（覆盖写后缩略图刷新）', () async {
      final memo = ThumbnailMemo();
      final loaded = <String>[];
      Future<List<int>?> load(String version) async {
        loaded.add(version);
        return [version.codeUnitAt(0)];
      }

      await memo.resolve('ufs_1', 'v1', () => load('v1'));
      await flush();
      await memo.resolve('ufs_1', 'v1', () => load('v1'));
      expect(loaded, ['v1'], reason: '前置：同版本不重拉');

      await memo.resolve('ufs_1', 'v2', () => load('v2'));
      await flush();

      expect(loaded, ['v1', 'v2'], reason: '版本变了必须重新请求');
      expect(memo.stats.invalidations, 1);
      expect(memo.length, 1, reason: '旧版本条目要被逐出，不能两版各留一份');
    });

    test('显式 evict（文件被删除）逐出条目并计入 invalidations', () async {
      final memo = ThumbnailMemo();
      await memo.resolve('ufs_1', 'v1', () async => [1]);
      await flush();
      expect(memo.bytes, 1);

      memo.evict('ufs_1');
      expect(memo.contains('ufs_1'), isFalse);
      expect(memo.bytes, 0);
      expect(memo.stats.invalidations, 1);

      memo.evict('ufs_missing');
      expect(memo.stats.invalidations, 1, reason: '不存在时不该计数');
    });
  });

  group('容量上界', () {
    test('条目数超限淘汰最旧写入（不是最后请求的）', () async {
      final memo = ThumbnailMemo(maxEntries: 2);
      for (final id in ['a', 'b', 'c']) {
        await memo.resolve(id, 'v1', () async => [1]);
        await flush();
      }

      expect(memo.length, 2);
      expect(memo.contains('a'), isFalse, reason: '最旧写入先被淘汰');
      expect(memo.contains('b'), isTrue);
      expect(memo.contains('c'), isTrue);
      expect(memo.stats.evictions, 1);
      expect(memo.stats.peakEntries, 2);
    });

    test('字节超限淘汰最旧已解析条目，但保留刚解析的那条', () async {
      final memo = ThumbnailMemo(maxEntries: 10, maxBytes: 10);
      await memo.resolve('a', 'v1', () async => List<int>.filled(8, 0));
      await flush();
      expect(memo.bytes, 8);

      // 再进 8 字节 → 总 16 > 10：应淘汰 a（最旧），保留刚解析的 b。
      await memo.resolve('b', 'v1', () async => List<int>.filled(8, 0));
      await flush();

      expect(memo.contains('a'), isFalse);
      expect(memo.contains('b'), isTrue);
      expect(memo.bytes, 8);
      expect(memo.stats.evictions, 1);
      expect(memo.stats.peakBytes, 16, reason: '峰值要记录淘汰前的瞬时占用');
    });

    test('单条自身超预算时不被反复淘汰（避免每帧重拉）', () async {
      final memo = ThumbnailMemo(maxEntries: 10, maxBytes: 4);
      await memo.resolve('huge', 'v1', () async => List<int>.filled(9, 0));
      await flush();

      expect(
        memo.contains('huge'),
        isTrue,
        reason: '只剩自己时宁可超预算，也不能淘汰掉导致每次 build 重拉',
      );
      expect(memo.bytes, 9);

      // 再次请求必须命中（没有陷入「淘汰→重拉」循环）。
      final again = memo.resolve('huge', 'v1', () async => fail('不应重新加载'));
      await again;
      expect(memo.stats.hits, 1);
    });

    test('未解析的条目被淘汰后，迟到的解析结果不计账', () async {
      final memo = ThumbnailMemo(maxEntries: 1);
      final slow = Completer<List<int>?>();
      // 故意不 await：这条请求在解析前就会被容量挤出。
      unawaited(memo.resolve('slow', 'v1', () => slow.future));

      // 第二个条目把 slow 挤出容量。
      await memo.resolve('fast', 'v1', () async => [1]);
      await flush();
      expect(memo.contains('slow'), isFalse);

      slow.complete(List<int>.filled(100, 0));
      await flush();
      expect(memo.bytes, 1, reason: '已被逐出的 Future 解析后不该把字节加回账上（identical 判据）');
    });
  });

  group('失败项与清理', () {
    test('失败（null）项照样缓存且不计字节（永久失败不反复重试）', () async {
      final memo = ThumbnailMemo();
      var loads = 0;
      Future<List<int>?> load() async {
        loads++;
        return null;
      }

      await memo.resolve('x', 'v1', load);
      await flush();
      await memo.resolve('x', 'v1', load);
      await flush();

      expect(loads, 1);
      expect(memo.length, 1);
      expect(memo.bytes, 0);
    });

    test('load 同步抛错时不写入任何状态（与旧 putIfAbsent 语义一致）', () async {
      final memo = ThumbnailMemo();
      expect(
        () => memo.resolve('x', 'v1', () => throw StateError('boom')),
        throwsStateError,
      );
      expect(memo.length, 0);
      expect(memo.stats.misses, 1);
    });

    test('clear 清空条目与字节，但保留累计统计与峰值（诊断要看整页生命周期）', () async {
      final memo = ThumbnailMemo();
      await memo.resolve('a', 'v1', () async => [1, 2]);
      await flush();

      memo.clear();
      expect(memo.length, 0);
      expect(memo.bytes, 0);
      expect(memo.stats.peakBytes, 2);
      expect(memo.stats.misses, 1);
    });
  });
}
