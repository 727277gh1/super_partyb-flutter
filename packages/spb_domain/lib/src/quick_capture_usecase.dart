import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

import 'chat_stream_controller.dart';

/// 「无归属入口」的提交结果。
///
/// ## 为什么用 sealed class 而不是「一个对象 + 布尔字段」
///
/// 服务端用字符串 [QuickCaptureResult.status] 表达状态（`queued` /
/// `feedback_recorded`），调用方若直接比字符串，**漏处理一个分支编译器不会报错**，
/// 而漏处理的后果是具体的：
///
/// - 把 `feedback_recorded` 当 `queued` → UI 导航到一个 group 后**永远等不到回答**
///   （该分支根本没建 turn）；
/// - 把 `queued` 当 `feedback_recorded` → 消息**静默消失**（用户以为发出去了）。
///
/// sealed class 让 UI 的 `switch` 在编译期穷举，把「漏分支」从运行时静默错误
/// 变成编译错误。
///
/// ## 三个变体而非两个
///
/// 服务端刻意用 String 而非 bool 表达状态，以便**新增状态不必改响应形状**。
/// 那么客户端就必须回答「遇到未知状态怎么办」：[QuickCaptureUnknown] 显式表达
/// 「服务端有了新状态，本端未适配」——既不当作终态（会丢消息），也不当作
/// 已入队（会导航到不存在的地方）。
sealed class QuickCaptureOutcome {
  const QuickCaptureOutcome({required this.groupId, required this.result});

  /// 服务端判定的归属 group。
  ///
  /// **这是本端点的核心产出**：调用方没给 group_id，归属由服务端分类链判定
  /// （与 MQ inbound 同一条链，见 AGENTS.md §5.5）。注意在
  /// [QuickCaptureFeedbackRecorded] 下它指向「被评价的那次归属」，
  /// 不是「新消息的落点」。
  final String groupId;

  /// 原始响应，供 UI 展示 `matched_title` / `route_source` 等诊断信息。
  final QuickCaptureResult result;
}

/// 已入队：有 turn 可等，UI 应导航到 [groupId] 并等待回答。
final class QuickCaptureQueued extends QuickCaptureOutcome {
  const QuickCaptureQueued({
    required super.groupId,
    required super.result,
    required this.turnId,
  });

  /// 新建的 turn ID。可用于订阅该 turn 的进度或做本地去重。
  final String turnId;

  /// 是否为服务端**新建**的 group（而非落到既有对话）。
  bool get createdGroup => result.createdGroup;

  /// 匹配到的 group 标题（可能为 null）。
  String? get matchedTitle => result.matchedTitle;
}

/// 归属反馈回执：**终态**。
///
/// 用户输入的是元指令（评价上一次归属），服务端已把它记为标注事件。
/// 本分支**没有建 turn**，故：
///
/// - **不导航**：导航到 [groupId] 会停在一个永远没有回答的对话；
/// - **不等回答**：没有回答会来；
/// - **不回显**：用户输入的不是一条消息，回显会在对话里留下一个
///   「发了但没处理」的假气泡。
///
/// UI 的正确反应是给一个轻量提示（如 SnackBar「已记录归属反馈」）后关闭。
final class QuickCaptureFeedbackRecorded extends QuickCaptureOutcome {
  const QuickCaptureFeedbackRecorded({
    required super.groupId,
    required super.result,
  });
}

/// 服务端返回了本端不认识的状态。
///
/// 触发条件：服务端新增了状态值而客户端未适配。按 [QuickCaptureResult.status]
/// 的原始值判断，**不猜测**其语义。
///
/// 处理建议：当作「已提交但行为未知」——不导航（避免停到错误对话）、不回显，
/// 同时记一条日志以便发现契约漂移。
final class QuickCaptureUnknown extends QuickCaptureOutcome {
  const QuickCaptureUnknown({required super.groupId, required super.result});

  /// 服务端返回的原始状态字符串。
  String get status => result.status;
}

/// 无归属入口（quick capture）用例。
///
/// ## 语义
///
/// 「把一句话交给平台，由平台决定它属于哪个对话」——与 MQ inbound 完全相同
/// （两者都**没有对话 UI**，故都无法指定 group）。服务端为此专设
/// `POST /me/quick-capture`：调用方**不传** group_id，响应里的 group_id 是判定结果。
///
/// ## 客户端不写落点
///
/// 「上次落点」由**服务端**写 `router_preferences` 的 `user.desktop_last_group_id`
/// （见 `chat_quick_capture.go` 的 `saveDesktopGroup`）。客户端**只读**响应里的
/// group_id 用于导航，**不得**自行持久化落点：
///
/// 1. 落点需要服务端校验「该 group 仍是 active」——客户端存下来的指针可能已失效
///    （用户在 webapp 删掉了那个对话）；
/// 2. 更要紧的是**不能写 `chat_access_entries`**：那张表还有第二个消费者
///    `RecentOutboundChannel`（按 `last_used_at DESC` 取一条），决定 agent 生成的文件
///    推到哪个 IM 渠道。插一行 `channel='desktop'` 会让钉钉用户的文件推送
///    落到 mq-server 的 default 分支（iLink），**把文件推给不相关的微信**。
///
/// 见 AGENTS.md §5.6。
class QuickCaptureUseCase {
  QuickCaptureUseCase(this._api);

  final ChatApi _api;

  /// 提交一句话。
  ///
  /// [echoInto] 非空时，在**成功入队**后立刻把用户消息注入该控制器的缓冲以即时
  /// 回显（不等服务端 SSE 事件往返）。仅在 [QuickCaptureQueued] 下注入——
  /// 见 [QuickCaptureFeedbackRecorded] 与 [QuickCaptureUnknown] 的说明。
  ///
  /// ## ⚠️ echoInto 的时序要求
  ///
  /// 传 [echoInto] 时，调用方**必须保证该控制器当前已聚焦 [groupId]**，否则注入
  /// 的内容会立刻丢失：`ChatStreamController.switchGroup` 会 `_buffer.clear()`，
  /// 先注入再切 group 等于白注入（该 group 的历史仍会由 `_backfill` 从 timeline
  /// 正常拉回，只是失去了「即时」这一效果）。
  ///
  /// 故**需要导航**的调用方应这样写（先切 group 再回显）：
  ///
  /// ```dart
  /// final outcome = await useCase.submit(input: text);
  /// if (outcome is QuickCaptureQueued) {
  ///   await controller.switchGroup(outcome.groupId);   // 先导航
  ///   controller.injectLocalUserMessage(               // 后回显
  ///     input: text, groupId: outcome.groupId, turnId: outcome.turnId,
  ///   );
  /// }
  /// ```
  ///
  /// 而「用户已经在看那个对话」的场景可以直接传 [echoInto]。
  ///
  /// ## 为什么注入不需要去重
  ///
  /// 注入项与服务端稍后到达的 `user_message` 事件**携带同一 turnId**，
  /// [EventReducer] 据此原位合并（见 [ChatStreamController.injectLocalUserMessage]）。
  Future<QuickCaptureOutcome> submit({
    required String input,
    ChatStreamController? echoInto,
  }) async {
    final result = await _api.quickCapture(input: input);

    // 分支顺序刻意与「危险程度」相反：先判终态。
    //
    // `isFeedbackRecorded` / `isQueued` 都是**显式等值比较**（不是
    // `status != 'queued'`），故未知状态既不会被当成终态、也不会被当成已入队。
    if (result.isFeedbackRecorded) {
      // 终态：不导航、不回显。回显会留下「发了但没处理」的假气泡。
      SpbLog.debug('quick capture 命中归属反馈回执（终态，不导航）', {
        'groupId': result.groupId,
      });
      return QuickCaptureFeedbackRecorded(
        groupId: result.groupId,
        result: result,
      );
    }

    if (result.isQueued) {
      echoInto?.injectLocalUserMessage(
        input: input,
        groupId: result.groupId,
        turnId: result.turnId,
      );
      return QuickCaptureQueued(
        groupId: result.groupId,
        result: result,
        turnId: result.turnId,
      );
    }

    // 未知状态：不猜语义。记日志以便发现契约漂移（服务端新增了状态值）。
    SpbLog.warn('quick capture 返回未知 status，按未知处理', {
      'status': result.status,
      'groupId': result.groupId,
    });
    return QuickCaptureUnknown(groupId: result.groupId, result: result);
  }
}
