import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// `AutoSyncScheduler` 的排程行为。
///
/// ## 为什么这些用例必须存在
///
/// 调度器的每一条判据都是**静默**的：排不上计时器 = 功能悄悄不工作，且没有
/// 任何界面能看出区别（设置页的开关仍然是开着的）。而验证它的自然方式
/// （真等 15 分钟）在 CI 里不可行——故全部用 `fake_async` 驱动假时钟。
void main() {
  /// 造一个「记录调用次数、可手动完成」的执行体。
  ///
  /// 返回 `(run, 调用计数访问器, 完成器)`。用可控 Future 而不是立刻返回，
  /// 是为了验证「上一轮未跑完时不叠加下一轮」。
  ({
    AutoSyncRun run,
    int Function() calls,
    void Function() complete,
    bool Function() isPending,
  })
  makeRunner() {
    var calls = 0;
    var pending = false;
    final completers = <Completer<void>>[];
    Future<void> run() {
      calls++;
      pending = true;
      final c = Completer<void>();
      completers.add(c);
      return c.future.whenComplete(() => pending = false);
    }

    void complete() {
      if (completers.isEmpty) return;
      completers.removeAt(0).complete();
    }

    return (
      run: run,
      calls: () => calls,
      complete: complete,
      isPending: () => pending,
    );
  }

  group('启动同步（onLaunch）', () {
    test('首次 apply 且 onLaunch=true → 立刻跑一轮', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(onLaunch: true));
        async.flushMicrotasks();
        expect(r.calls(), 1);
        s.dispose();
      });
    });

    test('onLaunch=false → 不跑', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();
        expect(r.calls(), 0);
        s.dispose();
      });
    });

    test('启动同步只跑一次（重复 apply 同一配置不重跑）', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(onLaunch: true));
        async.flushMicrotasks();
        r.complete();
        async.flushMicrotasks();
        s.apply(const AutoSyncConfig(onLaunch: true));
        async.flushMicrotasks();
        expect(r.calls(), 1);
        s.dispose();
      });
    });

    test('全关配置 → 不跑、不排程', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(AutoSyncConfig.disabled);
        async.flushMicrotasks();
        expect(r.calls(), 0);
        expect(s.isScheduled, isFalse);
        expect(s.isApplied, isFalse);
        s.dispose();
      });
    });
  });

  group('周期同步', () {
    test('到点跑一轮，并在**结束后**续排下一轮', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();
        expect(r.calls(), 0, reason: '未到点不该跑');

        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 1);
        r.complete();
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 2);
        r.complete();
        async.flushMicrotasks();
        s.dispose();
      });
    });

    test('长轮次期间**暂停排程**，结束后恢复（不叠加）', () {
      // ## 为什么是「暂停」而不是「照排」
      //
      // 一次性计时器在上一轮结束后才续排（见 `_tick` 的说明）。首轮全量
      // 可能跑很久，若期间照排，会变成「一轮接一轮背靠背」——而那正是
      // `Timer.periodic` 的问题。代价：长轮次期间 `isScheduled` 为 false，
      // 这是**正确**状态（现在确实没排着东西）。
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 1);

        // 不 complete：模拟长轮次。再推进 3 个周期也不该新增调用。
        async.elapse(const Duration(minutes: 45));
        expect(r.calls(), 1);
        expect(s.isScheduled, isFalse, reason: '轮次在途时没有排程');

        r.complete();
        async.flushMicrotasks();
        expect(s.isScheduled, isTrue, reason: '结束后必须恢复排程');
        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 2);
        r.complete();
        async.flushMicrotasks();
        s.dispose();
      });
    });

    test('轮次在途时改了配置 → 新计时器到点时跳过，并续排（链不断）', () {
      // 这条专门覆盖 `_running` 分支——它是**可达**的：唯一的排程来源
      // 就是「长轮次期间又 apply 了一份新配置」。
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 1, reason: '轮次已开始且未完成');

        // 在途期间改配置 → 排了一个新计时器。
        s.apply(const AutoSyncConfig(intervalMinutes: 30));
        async.flushMicrotasks();
        expect(s.isScheduled, isTrue);

        // 新计时器到点，但上一轮仍在跑 → 本轮跳过。
        async.elapse(const Duration(minutes: 30));
        expect(r.calls(), 1, reason: '在途时必须跳过，而不是叠一轮');
        expect(s.isScheduled, isTrue, reason: '跳过也必须续排，否则自动同步永久停摆');

        r.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 30));
        expect(r.calls(), 2);
        r.complete();
        async.flushMicrotasks();
        s.dispose();
      });
    });

    test('intervalMinutes=0 → 不排程（只启动同步）', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(onLaunch: true));
        async.flushMicrotasks();
        r.complete();
        async.flushMicrotasks();
        expect(s.isScheduled, isFalse);
        async.elapse(const Duration(hours: 5));
        expect(r.calls(), 1);
        s.dispose();
      });
    });
  });

  group('幂等（apply 的配置相等）', () {
    test('重复 apply 相同配置不重置周期计时器', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 10));
        // 此刻再喂一份相同配置：若重排计时器，第 15 分钟不会触发。
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 5));
        expect(r.calls(), 1, reason: '相同配置不该重置已走过的周期');
        r.complete();
        async.flushMicrotasks();
        s.dispose();
      });
    });

    test('配置真的变了 → 重排（旧周期作废）', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 10));
        s.apply(const AutoSyncConfig(intervalMinutes: 60));
        async.flushMicrotasks();

        // 旧的 15 分钟周期已作废：再走 10 分钟不该触发。
        async.elapse(const Duration(minutes: 10));
        expect(r.calls(), 0);
        // 从改配置起算 60 分钟才触发。
        async.elapse(const Duration(minutes: 50));
        expect(r.calls(), 1);
        r.complete();
        async.flushMicrotasks();
        s.dispose();
      });
    });

    test('从启用改为全关 → 停排', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();
        expect(s.isScheduled, isTrue);

        s.apply(AutoSyncConfig.disabled);
        async.flushMicrotasks();
        expect(s.isScheduled, isFalse);
        expect(s.isApplied, isFalse);

        async.elapse(const Duration(hours: 2));
        expect(r.calls(), 0);
        s.dispose();
      });
    });
  });

  group('pause / 重新武装', () {
    test('pause 取消计时器且不再跑', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();
        s.pause();
        async.elapse(const Duration(hours: 2));
        expect(r.calls(), 0);
        expect(s.isScheduled, isFalse);
        s.dispose();
      });
    });

    test('pause 后 apply **相同**配置必须重新武装（不是被幂等吞掉）', () {
      // ## 这条是本文件最容易被写反的一条
      //
      // 若 `pause` 只取消计时器而保留 `_applied`，重新登录时装配层会喂一份
      // **相同**配置，`apply` 的幂等判定让它直接返回 → 自动同步在第二次
      // 登录后永久失效，且没有任何征兆。
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        const cfg = AutoSyncConfig(intervalMinutes: 15);

        s.apply(cfg);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 1);
        r.complete();
        async.flushMicrotasks();

        s.pause();
        expect(s.isApplied, isFalse);

        s.apply(cfg);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 2, reason: 'pause 后重新 apply 相同配置必须重新排程');
        r.complete();
        async.flushMicrotasks();
        s.dispose();
      });
    });

    test('pause 后 apply 相同配置且 onLaunch=true → 会再跑一次启动同步', () {
      // 语义：重新登录 = 新会话 = 又一次「启动」。
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        const cfg = AutoSyncConfig(onLaunch: true);

        s.apply(cfg);
        async.flushMicrotasks();
        expect(r.calls(), 1);
        r.complete();
        async.flushMicrotasks();

        s.pause();
        s.apply(cfg);
        async.flushMicrotasks();
        expect(r.calls(), 2);
        s.dispose();
      });
    });
  });

  group('失败与释放', () {
    test('执行体抛异常 → 只记日志，不向上抛，且照常续排', () {
      fakeAsync((async) {
        var calls = 0;
        final s = AutoSyncScheduler(
          run: () async {
            calls++;
            throw const PlatformError('boom');
          },
        );
        s.apply(const AutoSyncConfig(onLaunch: true, intervalMinutes: 15));
        async.flushMicrotasks();
        expect(calls, 1, reason: '启动轮已执行');

        // 失败不得让排程链断掉：15 分钟后再跑一轮。
        async.elapse(const Duration(minutes: 15));
        expect(calls, 2);
        expect(async.pendingTimers, isNotEmpty, reason: '失败后必须续排');
        s.dispose();
      });
    });

    test('dispose 后不再跑，也不留计时器', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();
        s.dispose();
        expect(s.isScheduled, isFalse);
        async.elapse(const Duration(hours: 3));
        expect(r.calls(), 0);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('dispose 后 apply 是空操作（不复活）', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.dispose();
        s.apply(const AutoSyncConfig(onLaunch: true, intervalMinutes: 15));
        async.flushMicrotasks();
        expect(r.calls(), 0);
        expect(s.isScheduled, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(r.calls(), 0);
      });
    });

    test('执行中途 dispose → 结束后不再续排', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        s.apply(const AutoSyncConfig(intervalMinutes: 15));
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 15));
        expect(r.calls(), 1);
        s.dispose();
        r.complete();
        async.flushMicrotasks();
        expect(s.isScheduled, isFalse);
        async.elapse(const Duration(hours: 2));
        expect(r.calls(), 1);
      });
    });

    test('isRunning 如实反映在途状态', () {
      fakeAsync((async) {
        final r = makeRunner();
        final s = AutoSyncScheduler(run: r.run);
        expect(s.isRunning, isFalse);
        s.apply(const AutoSyncConfig(onLaunch: true));
        async.flushMicrotasks();
        expect(s.isRunning, isTrue);
        r.complete();
        async.flushMicrotasks();
        expect(s.isRunning, isFalse);
        s.dispose();
      });
    });
  });
}
