import 'package:spb_models/spb_models.dart';

/// 语音播报状态（由 `tts_started` / `tts_completed` / `tts_failed` 归一化而来）。
///
/// ## 它解决什么问题
///
/// 群级开启「语音回复」后，文本回复会异步合成语音。合成可能耗时数秒到数十秒，
/// 且**可能失败**（服务端失败文案明确写着「本次文本回复不受影响」）。这段时间里
/// 时间线是静的：用户不知道语音在合成、合成完了、还是已经悄悄失败了。
///
/// ## 四态（含 idle）
///
/// | 阶段 | 含义 | 来源 |
/// |---|---|---|
/// | [TtsPhase.idle] | 尚无播报（未开语音 / 未开始 / 已失效） | 本地构造 |
/// | [TtsPhase.started] | 合成中 | `tts_started`（Transient） |
/// | [TtsPhase.completed] | 合成完成 | `tts_completed`（落库） |
/// | [TtsPhase.failed] | 合成失败，带 [message] / [reason] | `tts_failed`（落库） |
///
/// `idle` 是**显式状态**而非 null：调用方（归约器 / 控制器）始终持有一个非空
/// 快照，无需到处判空；UI 用 [hasStatus] 决定是否展示。
///
/// ## ⚠️ 本模型只做「状态展示」，不引入播放
///
/// 客户端既有决策是「TTS 仅下载不播放」（AGENTS.md §11：没有音频播放插件，
/// 交付物同步只把 `reports/tts/**` 拉到本地）。本模型因此**只**回答
/// 「播报进行到哪一步 / 为什么失败」，不持有可播放句柄，也不触发任何播放。
/// 音频文件本身仍走既有的交付物同步链路（见 `tts_audio_path.dart`）。
///
/// ## ⚠️ 纠正任务前提：三个事件**并非都是 Transient**
///
/// 任务描述称「三个事件均为 Transient」。实测 `cmd/server/main.go:715`：
///
/// ```go
/// Transient: ev.EventType == tts.EventTTSStarted,
/// ```
///
/// 即**只有 `tts_started` 是 Transient**（仅实时广播、不落库，避免历史回放过期
/// 状态）；`tts_completed` / `tts_failed` **是落库的**（`tts/service.go:170`
/// 注释：「started 仅实时广播，终态事件持久化」），故它们有有效 `eventId`、
/// **会推进 SSE 游标**、**会回放**。
///
/// 两个后果（与 `queue_state` 那轮同源）：
///
/// 1. 归约器**不需要** Transient 豁免；
/// 2. 状态覆盖必须按到达顺序（归约循环本身即 globalSeq 升序），这样回放一段
///    「started → completed」的历史会得到终态，而不是永远停在「合成中」。
class TtsStatus {
  const TtsStatus({
    required this.turnId,
    required this.phase,
    this.message,
    this.reason,
    this.mode,
    this.parts,
    this.failedPart,
    this.lostChars,
    this.at,
  });

  /// 空闲：尚无播报事件，或上一轮状态已失效。
  ///
  /// `turnId` 默认空串——它不代表任何 turn。
  const TtsStatus.idle({this.turnId = ''})
    : phase = TtsPhase.idle,
      message = null,
      reason = null,
      mode = null,
      parts = null,
      failedPart = null,
      lostChars = null,
      at = null;

  /// 所属 turn。播报是 per-turn 的（一个 group 里可能多轮先后合成）。
  final String turnId;

  /// 播报阶段。
  final TtsPhase phase;

  /// 面向用户的失败文案（`tts_failed.message`，服务端已给中文）。
  ///
  /// 只有 [TtsPhase.failed] 时非空。UI 应优先用它而不是自己拼。
  final String? message;

  /// 内部原因（`reason`）：`synthesize_failed` / `first_delta` 等。
  ///
  /// ⚠️ 这是**诊断值**，不是文案——不要直接渲染给用户（同
  /// `ExecutionStatus.reason` 的取舍）。
  final String? reason;

  /// 播报模式（`tts_started.mode`）：`message`（整段）/ `stream`（流式）。
  final String? mode;

  /// 已生成的语音分段数。
  ///
  /// `completed` 取 `parts`；`failed` 取 `completed_parts`（失败前已完成数）。
  final int? parts;

  /// 失败发生在第几段（1-based）。
  final int? failedPart;

  /// 因失败丢失的字符数。
  final int? lostChars;

  /// 事件到达时间；[TtsPhase.idle] 时为 null（空闲不是事件）。
  final DateTime? at;

  /// 从事件构造；非 TTS 三事件，或载荷不可用时返回 null。
  ///
  /// 返回 null 表示「这不是播报事件」，**不是** [TtsPhase.idle]——归约器据此
  /// 区分「本条事件与播报无关」与「显式置为空闲」。
  ///
  /// `turnId` 为空的事件无法按 turn 归并（丢弃而非静默挂到空 turn 上）。
  static TtsStatus? fromEvent(ChatEvent ev) {
    if (ev.turnId.isEmpty) return null;
    if (!ev.isTtsEvent) return null;

    switch (ev.eventType) {
      case EventTypes.ttsStarted:
        return TtsStatus(
          turnId: ev.turnId,
          phase: TtsPhase.started,
          mode: ev.ttsMode,
          reason: ev.ttsReason,
          at: ev.createdAt,
        );
      case EventTypes.ttsCompleted:
        return TtsStatus(
          turnId: ev.turnId,
          phase: TtsPhase.completed,
          parts: ev.ttsParts,
          at: ev.createdAt,
        );
      case EventTypes.ttsFailed:
        return TtsStatus(
          turnId: ev.turnId,
          phase: TtsPhase.failed,
          message: ev.ttsMessage,
          reason: ev.ttsReason,
          // 失败时 parts 的语义是「已完成数」，取 completed_parts；
          // 退化到 parts（message 模式失败不带 completed_parts）。
          parts: ev.ttsCompletedParts ?? ev.ttsParts,
          failedPart: ev.ttsFailedPart,
          lostChars: ev.ttsLostChars,
          at: ev.createdAt,
        );
      default:
        return null;
    }
  }

  /// 是否有值得展示的状态（即非 [TtsPhase.idle]）。
  ///
  /// UI 用它决定是否渲染状态条——避免为「空闲」占一行空白。
  bool get hasStatus => phase != TtsPhase.idle;

  /// 是否为终态（合成已结束：成功或失败）。
  ///
  /// UI 用它决定「还要不要显示进行中指示」——终态可以停留展示（让用户看到
  /// 结果与失败原因），而 `started` 是过渡态。
  bool get isTerminal =>
      phase == TtsPhase.completed || phase == TtsPhase.failed;

  @override
  String toString() =>
      'TtsStatus(${phase.wire}, turn=$turnId'
      '${parts != null ? ', parts=$parts' : ''}'
      '${message != null ? ', message=$message' : ''})';
}

/// 播报阶段。
///
/// 用 enum 而非原样 String：UI 的 `switch` 可穷举（编译期保证不漏分支）。
/// 未知类型由 [TtsStatus.fromEvent] 直接返回 null（不认识就当没有）。
enum TtsPhase {
  /// 空闲：尚无播报事件（未开语音 / 尚未开始 / 上一轮已失效）。
  idle('idle'),

  /// 合成已开始（`tts_started`，Transient）。
  started('started'),

  /// 合成完成（`tts_completed`，落库）。
  completed('completed'),

  /// 合成失败（`tts_failed`，落库）。
  failed('failed');

  const TtsPhase(this.wire);

  /// 服务端原始值（`idle` 无服务端对应，为本地态）。
  final String wire;
}
