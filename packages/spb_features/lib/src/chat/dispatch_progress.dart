import 'dart:async';

import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'turn_status.dart';

/// 「已发送 → 首 token」之间的分发进度条（issue #114 / super_partyb#181）。
///
/// ## 它填补的是哪一段空窗
///
/// 发消息后到首 token 之间，服务端要做一串与「回答」无关的事：判归属、挑
/// Agent、入队。这段时间此前对用户完全不可见——[TurnStatusStrip] 说的是
/// 「服务端已经建好 turn、正在执行」，而 turn 还没建的那几百毫秒到几秒里，
/// 界面只有一条「发送中」的气泡。
///
/// 生产基线（123，7 天）：p90 **27ms**，长尾 **3711ms**（其中 3147ms 在 Agent
/// 匹配的 Jev 仲裁里）。所以这个组件必须**对绝大多数发送不出现**，否则每次
/// 发送都闪一条——那是噪声。门槛见 [dispatchProgressMinVisibleMs]。
///
/// ## 为什么自带计时器
///
/// 分发帧发生在 turn 建立**之前**，服务端没有 `elapsed_ms` 可给（root 收尾帧
/// 才有，那时条已收起）。所以「已等待多久」只能由客户端按首帧到达时刻算，
/// 而「过了 500ms 才显示」也必须靠计时器触发一次重建。计时器只在有进度时
/// 存在：进度为 null 时立刻取消，页面空转时不占一个 timer。
///
/// ## 它不是权威状态
///
/// 帧是 Transient（不落库、不回放）：断线就没了，重连也不会补齐。故这里只做
/// 「现在大概在做什么」的提示，不做任何终态判断（那仍看时间线）。
class DispatchProgressBar extends StatefulWidget {
  const DispatchProgressBar({super.key, required this.progress, this.clock});

  /// 当前分发进度；null 时组件渲染为空白（`SizedBox.shrink`）。
  final DispatchStageProgress? progress;

  /// 时钟（仅测试注入，用来把「过了 500ms」变成确定性断言）。
  final DateTime Function()? clock;

  @override
  State<DispatchProgressBar> createState() => _DispatchProgressBarState();
}

class _DispatchProgressBarState extends State<DispatchProgressBar> {
  Timer? _timer;

  /// 每次重建读一次的「现在」。
  ///
  /// 不在 build 里直接 `DateTime.now()`：同一帧内多次读会得到不同值，让
  /// 「已等待 1 秒」与「是否过门槛」两个判定互相矛盾（也让测试无法确定）。
  DateTime _now = DateTime.now();

  DateTime _clock() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _reschedule();
  }

  @override
  void didUpdateWidget(DispatchProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在新请求 / 新起点时重排：同一请求内「当前段变了」不影响计时（起点没变），
    // 下一次 tick（或父层重建）自然会把文案换过来。
    if (oldWidget.progress?.requestId != widget.progress?.requestId ||
        oldWidget.progress?.startedAt != widget.progress?.startedAt) {
      _reschedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// 排下一次重建的时刻：门槛未到 → 一次性定时到门槛；已过门槛 → 每秒一次。
  ///
  /// 为什么不一律 `Timer.periodic(1s)`：那样条最早在 1s 出现，而门槛是 500ms
  /// ——实测大量发送落在 500~900ms 区间，直接少掉一档可见性。
  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    final progress = widget.progress;
    if (progress == null) return;

    _now = _clock();
    const threshold = Duration(milliseconds: dispatchProgressMinVisibleMs);
    final elapsed = _now.difference(progress.startedAt);
    if (elapsed < threshold) {
      _timer = Timer(threshold - elapsed, () {
        if (!mounted) return;
        setState(() => _now = _clock());
        _reschedule();
      });
      return;
    }
    // 已可见：每秒刷一次「已等待 N 秒」。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = _clock());
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    // 门槛判定交给领域层（纯函数，可无引擎单测）。
    if (!shouldShowDispatchProgress(progress, now: _now)) {
      return const SizedBox.shrink();
    }
    final p = progress!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final animate = !MediaQuery.disableAnimationsOf(context);
    final elapsed = formatTurnElapsed(
      _now.difference(p.startedAt).inMilliseconds,
    );
    final done = p.completedCount;

    return Material(
      key: const ValueKey('conversation-dispatch-progress'),
      // 比 `TurnStatusStrip`（secondaryContainer）更轻：这是**还没开始**的
      // 等待，不该与「正在跑」抢视觉重量。
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
        child: Row(
          children: [
            ExcludeSemantics(
              child: SizedBox(
                width: SpbSpacing.lg,
                height: SpbSpacing.lg,
                child: animate
                    ? CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onSurfaceVariant,
                      )
                    : Icon(
                        Icons.hourglass_empty,
                        size: SpbSpacing.lg,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: SpbSpacing.sm),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    dispatchProgressText(p),
                    key: const ValueKey('conversation-dispatch-progress-text'),
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            // 「已等待 N 秒」+ 已完成的段数：前者是唯一的时间参照（这段时间
            // 没有正文），后者让「它在动」这件事有第二个证据（卡住时不会变）。
            Text(
              done > 0 ? '$elapsed · 已过 $done 步' : elapsed,
              key: const ValueKey('conversation-dispatch-progress-elapsed'),
              style: SpbType.listMeta(textTheme)
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: SpbSpacing.md),
          ],
        ),
      ),
    );
  }
}
