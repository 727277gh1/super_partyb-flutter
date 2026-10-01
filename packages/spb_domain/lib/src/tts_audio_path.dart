/// TTS 语音回复产物的路径解析。
///
/// 契约真源（三处必须保持一致，改一处要三处同步）：
/// - 后端 `internal/workers/groupsync.turnIDFromPath`（turn_id 段解析，**前缀锚定开头**）
/// - 后端 `internal/workers/agentfilerender.ttsStreamKind` / `ttsPartNumber`（流种类与排序键）
/// - webapp `lib/workbench/agent-file.ts` 的 `parseTTSAudioPath`（客户端展示语义）
///
/// ## 关键：前缀锚定在开头
///
/// 复用 `ttsRelPrefix`（`deliverable_sync.dart`），它锚定在路径**开头**：
/// `x/reports/tts/a.mp3` **不算** TTS 产物（见 `isMachineGenerated` 的文档与后端
/// `turnIDFromPath` 的测试用例 `{"/abs/reports/tts/t1/x.mp3", ""}`）。
/// webapp 的 `indexOf` 写法较宽松，以后端 `HasPrefix` 为准——客户端不能把任意
/// 子路径误判成 TTS，否则会把用户的普通音频文件错误折叠进语音回复区。
///
/// ## kind 的客户端映射
///
/// 后端 `ttsStreamKind` 返回 `speech` / `narration` / `filesummary`（三流独立队列）。
/// 客户端展示语义把 `speech_` / `message_` 合并成 **reply**（回复正文），
/// 其余两类保持原名（对齐 webapp 的 `TTSStreamKind`）。
library;

import 'deliverable_sync.dart' show ttsRelPrefix;

/// TTS 音频流种类（客户端展示语义，对齐 webapp）。
enum TtsStreamKind {
  /// 回复正文（文件名前缀 `speech_` 或 `message_`）。
  reply,

  /// 思考阶段填充语（文件名前缀 `narration_`）。
  narration,

  /// 文件产出播报（文件名前缀 `filesummary_`）。
  filesummary,
}

/// 解析后的 TTS 音频元数据。
class TtsAudioMeta {
  const TtsAudioMeta({
    required this.turnId,
    required this.part,
    required this.kind,
  });

  /// 所属 turn 的 id（路径 `reports/tts/{turnId}/` 段）。
  final String turnId;

  /// 同流内的稳定排序键（来自 [ttsPartNumber]）。
  final int part;

  /// 流种类（决定折叠/展开与展示）。
  final TtsStreamKind kind;

  @override
  String toString() => 'TtsAudioMeta(turnId=$turnId, part=$part, kind=$kind)';
}

/// 从 agent.file.* 事件的文件路径解析 TTS 语音回复标记。
///
/// 仅 `reports/tts/{turn_id}/` 下、且 `turn_id` 仅含 `[A-Za-z0-9_-]`、
/// 文件名可被 [ttsPartNumber] 解析时才识别为 TTS；否则返回 null（视为普通音频产物，
/// 由普通文件卡渲染而非语音条目）。
///
/// 对齐后端 `groupsync.turnIDFromPath` 与 webapp `parseTTSAudioPath`。
TtsAudioMeta? parseTTSAudioPath(String relPath) {
  if (relPath.isEmpty) return null;
  final rel = _normalize(relPath);
  // 前缀锚定开头（见类文档「关键」节）。webapp 用 indexOf 较宽松，此处以后端为准。
  if (!rel.startsWith(ttsRelPrefix)) return null;
  final rest = rel.substring(ttsRelPrefix.length);
  if (rest.isEmpty) return null;

  final slashIdx = rest.indexOf('/');
  final turn = slashIdx >= 0 ? rest.substring(0, slashIdx) : rest;
  if (turn.isEmpty || !_isTurnId(turn)) return null;

  final fileName = slashIdx >= 0 ? rest.substring(slashIdx + 1) : '';
  final part = ttsPartNumber(fileName);
  if (part == null) return null;

  return TtsAudioMeta(turnId: turn, part: part, kind: ttsStreamKind(fileName));
}

/// 解析语音块文件名的稳定排序键（对齐后端 `agentfilerender.ttsPartNumber`）。
///
/// - `narration_{turn_id}_{part}` / `speech_{turn_id}_{part}` /
///   `filesummary_{turn_id}_{part}`：直接取末段 part（必须 > 0）；
/// - `message_{seq}[_n]`：取 `seq*1000+n`，使同一消息的分块紧邻且位于下一条消息之前；
/// - 无法解析返回 null。
int? ttsPartNumber(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return null;
  final stem = fileName.substring(0, dot);

  // narration_ / speech_ / filesummary_：末段即 part。
  if (stem.startsWith('narration_') ||
      stem.startsWith('speech_') ||
      stem.startsWith('filesummary_')) {
    final sep = stem.lastIndexOf('_');
    if (sep == stem.length - 1) return null; // 以 _ 结尾，无 part
    final part = int.tryParse(stem.substring(sep + 1));
    return (part != null && part > 0) ? part : null;
  }

  if (!stem.startsWith('message_')) return null;
  final parts = stem.substring('message_'.length).split('_');
  if (parts.length > 2 || parts.isEmpty) return null;
  final seq = int.tryParse(parts[0]);
  if (seq == null || seq <= 0) return null;
  var sub = 0;
  if (parts.length == 2) {
    sub = int.tryParse(parts[1]) ?? -1;
    if (sub <= 0 || sub >= 1000) return null;
  }
  return seq * 1000 + sub;
}

/// 文件名 → 客户端展示流种类（对齐 webapp）。
///
/// 后端 `ttsStreamKind` 返回 `speech`，此处映射为 [TtsStreamKind.reply]
/// （`speech_` 与 `message_` 同属回复正文）。
TtsStreamKind ttsStreamKind(String fileName) {
  if (fileName.startsWith('speech_') || fileName.startsWith('message_')) {
    return TtsStreamKind.reply;
  }
  if (fileName.startsWith('filesummary_')) {
    return TtsStreamKind.filesummary;
  }
  return TtsStreamKind.narration;
}

bool _isTurnId(String s) {
  for (final c in s.codeUnits) {
    final ok =
        (c >= 0x30 && c <= 0x39) // 0-9
        ||
        (c >= 0x41 && c <= 0x5A) // A-Z
        ||
        (c >= 0x61 && c <= 0x7A) // a-z
        ||
        c ==
            0x2D // -
            ||
        c == 0x5F; // _
    if (!ok) return false;
  }
  return true;
}

String _normalize(String path) {
  if (!path.contains('\\') &&
      !path.contains('//') &&
      !path.startsWith('/') &&
      !path.endsWith('/')) {
    return path;
  }
  return path
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+'), '/')
      .replaceFirst(RegExp(r'^/+'), '')
      .replaceFirst(RegExp(r'/+$'), '');
}
