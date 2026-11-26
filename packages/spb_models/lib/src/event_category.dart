/// 事件**类别**（7 值闭集，服务端 `chatbus/catalog.go` 的镜像）。
///
/// ## 为什么需要它（而且不是 enum）
///
/// 事件类型有 60 个，类别只有 7 个。类别回答的是「这类事件在 UI 上归到哪儿」
/// （正文 / 思考 / 交付物 / 确认 / 追问 / 用户输入 / 其余事件），类型回答的是
/// 「具体发生了什么」。前者用于**分流与统计**，后者用于**具体渲染与归约语义**。
///
/// 与 [EventTypes] 同样用 `String` 常量而非 `Dart enum`：服务端可能新增类别，
/// 而移动端发布后无法强制升级。用 enum 时未知值要么抛、要么需要一个假的兜底值，
/// 那会让「类别」这件事从「契约镜像」退化成「客户端猜测」。
///
/// ## 它不是渲染的最终判据（重要）
///
/// 服务端目录里 `tool_call` / `tool_result` / `error` **全都是 `event` 类别**——
/// 类别是粗粒度桶（62 条里 50 条都落在 `event`）。故本仓的 17 个
/// `ConversationItem` 渲染器**保持按类型分派**（见 `docs/design-decisions/chat.md`
/// §6.107）：类别只用于「未知类型兜底」与跨端对拍，不用于合并渲染器。
///
/// ## 真源
///
/// `super_partyb/apps/go-api/docs/event-catalog.json` 的 `categories`（vendored 在
/// `packages/spb_models/fixtures/`）。本类的取值与顺序由
/// `test/event_catalog_test.dart` 对拍，漂移会红。
class EventCategory {
  const EventCategory._(); // 纯常量命名空间，结构上不可实例化。

  static const userInput = 'user_input';
  static const thinking = 'thinking';
  static const assistantText = 'assistant_text';
  static const agentFile = 'agent_file';
  static const confirmation = 'confirmation';
  static const followUp = 'follow_up';

  /// 兜底类别：不属于以上六类的全部事件（含 50/62 条）。
  ///
  /// 「未知事件类型」也归到这里（见 `ConversationItem` 的 `UnknownEventItem`），
  /// 因为服务端新增的时间线事件在类别维度上最可能是 `event`。
  static const event = 'event';

  /// 类别闭集，**顺序与服务端目录一致**（顺序漂移会让 diff 不可审查）。
  static const List<String> all = [
    userInput,
    thinking,
    assistantText,
    agentFile,
    confirmation,
    followUp,
    event,
  ];

  static bool isKnown(String? category) =>
      category != null && all.contains(category);
}
