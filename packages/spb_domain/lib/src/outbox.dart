import 'dart:async';
import 'dart:math';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:uuid/uuid.dart';

/// 离线写队列的条目（issue #26 切片 C / issue #30）。
///
/// ## 为什么是「一条待投递的用户消息」
///
/// 粒度必须与「一次 `POST /users/:uid/chat/messages`」一致：那是唯一带
/// `request_id` 幂等键的端点（`chat_stream.go:49`），而幂等键正是重试安全的
/// 前提。若按「一次网络请求」入队（例如把附件上传也拆成条目），重试就无法
/// 用一个键覆盖整件事。
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.userId,
    required this.input,
    this.groupId,
    this.agentId,
    this.routingMode = 'auto',
    required this.createdAt,
    this.attempts = 0,
    required this.nextAttemptAt,
    this.lastError,
    this.maxAttempts = OutboxRetryPolicy.defaultMaxAttempts,
  });

  /// **就是 `request_id`**（幂等键与主键合一，见设计文档 §7bis.1）。
  ///
  /// 分开存会引入「哪个才是真键」的问题；合并后「重试复用同一 `request_id`」
  /// 在结构上不可能写错。
  final String id;

  /// 归属用户。队列按它隔离（同 `CachedGroups.userId` 的理由：同一台机器
  /// 换账号会串）。
  final String userId;

  /// null = 无归属入口（服务端分类链判定，见 AGENTS.md §5.5）。
  ///
  /// ⚠️ 这里必须保留 null 与「空串」的区别：**空串是无效值**，null 才是
  /// 「让服务端判定」。持久化层要原样保住 null。
  final String? groupId;

  final String? agentId;

  final String routingMode;

  final String input;

  /// 入队时刻（FIFO 排序依据）。
  final DateTime createdAt;

  /// 已尝试投递次数（含首次）。
  final int attempts;

  /// 下次可尝试的时刻（退避算出）。
  final DateTime nextAttemptAt;

  /// 最近一次失败原因（诊断用，UI 可展示）。
  final String? lastError;

  /// 本条目适用**当时的**重试上限（入队时从策略快照下来）。
  ///
  /// ## 为什么必须存在条目上，而不是去问策略
  ///
  /// [status] 要判「重试用尽」，而它拿不到队列的策略实例（`OutboxEntry` 是
  /// 纯数据，`OutboxQueue` 才有策略）。若 `status` 硬编码
  /// [OutboxRetryPolicy.defaultMaxAttempts]，那么任何自定义 `maxAttempts`
  /// 的策略都会让条目**永远到不了** [OutboxStatus.failed]——`_nextSendable`
  /// 也就永远不跳过它，退化成无限重试（实测：`maxAttempts: 3` 的队列会一直
  /// 重试到 10 次以上）。
  ///
  /// 存在条目上还顺带解决「重启后策略变了」：一条在上限 10 下入队的条目，
  /// 不该因为下次启动时上限改成 3 就突然被判失败。
  final int maxAttempts;

  /// 状态**派生**自三个字段，不另存（设计文档 §7bis.2）。
  ///
  /// 多一个可写字段就多一处「派生值与存储值不一致」的机会。
  OutboxStatus get status {
    if (lastError != null && attempts >= maxAttempts) {
      return OutboxStatus.failed;
    }
    return attempts == 0 ? OutboxStatus.pending : OutboxStatus.retrying;
  }

  OutboxEntry copyWith({
    int? attempts,
    DateTime? nextAttemptAt,
    String? lastError,
    bool clearLastError = false,
  }) => OutboxEntry(
    id: id,
    userId: userId,
    input: input,
    groupId: groupId,
    agentId: agentId,
    routingMode: routingMode,
    createdAt: createdAt,
    attempts: attempts ?? this.attempts,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
    maxAttempts: maxAttempts,
  );

  /// 传给 API 的请求体字段。
  Map<String, dynamic> toRequestFields() => {
    'input': input,
    'request_id': id,
    if (groupId != null) 'group_id': groupId,
    if (agentId != null) 'agent_id': agentId,
    'routing_mode': routingMode,
  };

  @override
  String toString() =>
      'OutboxEntry($id, attempts=$attempts, group=$groupId, '
      'len=${input.length})';
}

/// 队列条目状态（派生，不落库）。
enum OutboxStatus {
  /// 还没试过（`attempts == 0`）。
  pending,

  /// 试过但失败，还会自动重试。
  retrying,

  /// 已达重试上限，**只能手动重试或删除**（不自动删除——那是用户输入的文本）。
  failed,
}

/// 投递成功事件。
///
/// 控制器订阅它，用**服务端返回的 turnId** 注入乐观回显（设计文档 §7bis.6）
/// ——此时 turnId 是真的，故服务端随后的 `user_message` 事件会原位合并，
/// 不会出现两个气泡。
class OutboxDelivered {
  const OutboxDelivered({required this.entry, required this.result});

  final OutboxEntry entry;
  final SendMessageResult result;
}

/// 终态失败（不可重试 / 已达上限），条目已从队列移除。
///
/// ## 为什么必须上报而不是静默丢弃
///
/// 它装的是**用户输入的文本**。静默丢弃等于「用户打了字、我们弄丢了、
/// 还不告诉他」。
class OutboxFailure {
  const OutboxFailure({
    required this.entry,
    required this.error,
    required this.exhausted,
  });

  final OutboxEntry entry;
  final SpbError error;

  /// true = 重试次数用尽（条目仍在表里，等用户手动处理）；
  /// false = 终态错误（条目已删除，重试无用）。
  final bool exhausted;
}

/// 提交结果。
///
/// ## 为什么需要区分「已投递」与「已入队」
///
/// UI 对两者的反馈完全不同：已投递 → 消息进时间线；已入队 → 消息进「待发送」
/// 条。把它们合成一个「成功」会让用户以为消息已经送达。
sealed class OutboxSubmitOutcome {
  const OutboxSubmitOutcome();
}

/// 立即投递成功（网络可用）。消息已进时间线。
final class OutboxSubmittedNow extends OutboxSubmitOutcome {
  const OutboxSubmittedNow({required this.result});

  final SendMessageResult result;
}

/// 已入队，等待投递（网络不可用）。消息进「待发送」条。
final class OutboxQueuedOffline extends OutboxSubmitOutcome {
  const OutboxQueuedOffline({required this.entry});

  final OutboxEntry entry;
}

/// 入队**也失败**了（本地存储故障）。
///
/// 这是降级为旧行为：写不进队列 → 提示发送失败（修复前的表现）。比
/// 「假装排队成功、其实什么都没存」好——后者会让用户以为消息发出去了。
final class OutboxEnqueueFailed extends OutboxSubmitOutcome {
  const OutboxEnqueueFailed({required this.error});

  final SpbError error;
}

/// 重试策略（纯函数，便于在 `dart test` 里逐条断言）。
class OutboxRetryPolicy {
  const OutboxRetryPolicy({
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 5),
    this.maxAttempts = defaultMaxAttempts,
    this.jitterRatio = 0.2,
  });

  /// 默认重试上限。
  ///
  /// 10 次配合 `baseDelay=2s` / `maxDelay=5min` 覆盖约 25 分钟——超过这个时长
  /// 的断网，让用户看到明确的「失败」比继续无声等待更好（他可能想改用别的
  /// 方式联系）。
  static const int defaultMaxAttempts = 10;

  /// 首次退避时长；之后指数增长。
  final Duration baseDelay;

  /// 退避上限。
  final Duration maxDelay;

  final int maxAttempts;

  /// 抖动比例（±）。
  ///
  /// ## 为什么必须有
  ///
  /// 多个客户端同时恢复网络时，固定退避会让请求在同一毫秒撞上服务端。抖动把
  /// 它们错开。`0` = 关闭（测试用，让断言确定）。
  final double jitterRatio;

  /// 第 [attempts] 次失败后的退避时长（`attempts` 从 1 起算）。
  Duration delayFor(int attempts, {Random? random}) {
    if (attempts <= 0) return baseDelay;
    // 指数：base × 2^(n-1)。
    //
    // ⚠️ **必须**用 `pow(2.0, …)` 而不是 `pow(2, …)`。
    //
    // `dart:math` 的 `pow` 在「整数底 + 非负整数指数」时返回 **int**，而
    // Dart 的 int 是定长 64 位——`pow(2, 99)` 会**静默回绕成 0**（不抛、不
    // 报错）。结果是 `micros = 0`，`delayFor` 返回零延迟，`_scheduleRetry`
    // 立刻重投 → 忙循环打服务端。
    //
    // 用 double 底数后 `pow` 恒返回 double（大指数得到 `Infinity`，由下面的
    // `isInfinite` 分支接管）。
    final factor = pow(2.0, attempts - 1).toDouble();
    var micros = baseDelay.inMicroseconds * factor;
    if (micros > maxDelay.inMicroseconds || micros.isInfinite) {
      micros = maxDelay.inMicroseconds.toDouble();
    }
    if (jitterRatio > 0) {
      final r = random ?? Random();
      // ±jitterRatio：0.8 ～ 1.2（jitterRatio=0.2 时）。
      final scale = 1 - jitterRatio + r.nextDouble() * 2 * jitterRatio;
      micros *= scale;
    }
    final out = micros.round();
    return Duration(microseconds: out < 0 ? 0 : out);
  }

  /// 这个错误还值得重试吗（设计文档 §7bis.4 的表）。
  ///
  /// ## 为什么按类型分而不是按「是否有网」
  ///
  /// 客户端**没有可靠的联网检测**（`connectivity_plus` 这类插件在桌面端的
  /// 语义是「有没有默认路由」，不等于「服务端可达」）。而错误类型是**确凿的
  /// 证据**：400 说明请求本身有问题，重试一万次也是 400。
  static bool isRetryable(SpbError error) {
    switch (error) {
      case NetworkError(:final retryable):
        // retryable=false 是明确不可重试的（如 TLS 证书错误）。
        return retryable;
      case HttpError(:final statusCode):
        if (statusCode == 408) return true; // 请求超时
        if (statusCode == 429) return true; // 限流
        return statusCode >= 500; // 5xx 服务端故障
      case AuthError():
        // 401/403：重试只会一直 401。需重新登录。
        return false;
      case ParseError():
        // 契约漂移，重试无用——应尽快暴露。
        return false;
      case ValidationError():
      case StorageError():
        return false;
      case MessageQueuedError():
      case MessageDeliveryFailedError():
        // 这两个是**本队列自己**产出的状态信号，不是投递失败的原因。
        // 走到这里说明调用方把队列的输出又喂回给了队列（编程错误）——
        // 保守地不重试，避免无限自激。
        return false;
      default:
        // 未知错误类型：保守地不重试（避免无限重试一个系统性故障）。
        return false;
    }
  }
}

/// 队列存储契约。
///
/// ## 与切片 A/B 相反：**不是**可丢弃数据
///
/// | | `GroupCacheStore` / `TimelineCacheStore` | `OutboxStore` |
/// |---|---|---|
/// | 装什么 | 可重拉的缓存 | **用户输入的文本** |
/// | 读失败 | 返回空 | 抛 `StorageError` |
/// | 写失败 | 静默降级 | **抛 `StorageError`** |
///
/// 写失败时调用方降级为「发送失败提示」——即修复前的行为。这比「假装排队
/// 成功、其实什么都没存」好（设计文档 §7bis.9）。
abstract interface class OutboxStore {
  /// 读该用户的全部条目，按 `createdAt` **升序**（FIFO）。
  Future<List<OutboxEntry>> load(String userId);

  /// 插入或更新一条。
  Future<void> upsert(OutboxEntry entry);

  /// 删除一条（投递成功 / 终态失败 / 用户手动删除）。
  Future<void> delete(String id);

  /// 清空该用户的队列（登出时调用）。
  Future<void> clear(String userId);
}

/// 投递回调：把一条队列条目交给 API。
typedef OutboxSend = Future<SendMessageResult> Function(OutboxEntry entry);

/// 离线写队列（issue #26 切片 C / issue #30）。
///
/// ## 三个不变式
///
/// 1. **严格全局 FIFO**：只投递队首；队首可重试地失败就**停下**，不跳过它。
///    两条消息调换顺序会改变语义（「帮我改这个」「算了别改了」）。`failed`
///    的条目被跳过（它的重试权在用户手里，不该挡住后面的）。
/// 2. **幂等键持久化**：`id` 就是 `request_id`，重试永远复用同一个。
/// 3. **投递中不可取消**：见 [cancel]。服务端**没有**删除 turn 的端点，故
///    「标记取消 + 忽略结果」会留下静默不一致。
///
/// ## 与 `ChatStreamController` 的方向（单向，无循环）
///
/// 控制器**依赖**队列（`send` 可重试失败时入队）；队列**不**依赖控制器
/// （投递成功只推 [delivered] 流，控制器订阅它）。故队列可以是 app 级
/// **非** autoDispose 的 provider——重试定时器必须活过对话页生命周期，
/// 否则用户发完消息切走，消息就永远卡在队列里没人投递。
class OutboxQueue {
  OutboxQueue({
    required OutboxStore store,
    required OutboxSend send,
    OutboxRetryPolicy policy = const OutboxRetryPolicy(),
    Uuid? uuid,
    Random? random,
    DateTime Function()? now,
  }) : _store = store,
       _send = send,
       _policy = policy,
       _uuid = uuid ?? const Uuid(),
       _random = random,
       _now = now ?? DateTime.now;

  final OutboxStore _store;
  final OutboxSend _send;
  final OutboxRetryPolicy _policy;
  final Uuid _uuid;
  final Random? _random;
  final DateTime Function() _now;

  final _entriesController = StreamController<List<OutboxEntry>>.broadcast();
  final _deliveredController = StreamController<OutboxDelivered>.broadcast();
  final _failureController = StreamController<OutboxFailure>.broadcast();

  final List<OutboxEntry> _entries = [];

  /// 正在投递的条目 id（投递中不可取消，见 [cancel]）。
  final Set<String> _inFlight = {};

  /// 是否有一轮 drain 在跑（防并发 drain 把同一队首投两次）。
  bool _draining = false;

  Timer? _timer;
  bool _disposed = false;

  /// 当前 userId（[load] / [submit] 时确定）。
  ///
  /// 目前只用于诊断日志——队列的**隔离**由存储层按 `userId` 过滤完成（同
  /// `CachedGroups` 的理由：同一台机器换账号会串），队列自己不做过滤。
  String? _userId;

  /// 当前 userId（null = 尚未加载）。供装配层做「换了账号要重新 load」的判断。
  String? get userId => _userId;

  /// 队列快照流（全量推送，同 `ChatStreamController.items` 的取向）。
  Stream<List<OutboxEntry>> get entries => _entriesController.stream;

  /// 当前快照。
  List<OutboxEntry> get snapshot => List.unmodifiable(_entries);

  /// 投递成功流。
  Stream<OutboxDelivered> get delivered => _deliveredController.stream;

  /// 终态失败流。
  Stream<OutboxFailure> get failures => _failureController.stream;

  /// 从存储加载该用户的队列（启动 / 登录后调用一次）。
  ///
  /// 失败时**不抛**：调用方（app 装配层）此时没有可展示错误的上下文，而队列
  /// 本身后续每次 `submit` 都会重新尝试存储。但会记 warn。
  Future<void> load(String userId) async {
    _userId = userId;
    try {
      final rows = await _store.load(userId);
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _entries
        ..clear()
        ..addAll(rows);
      _emit();
      // 上次进程退出时可能有没投完的：立刻续上。
      unawaited(drain());
    } catch (e) {
      SpbLog.warn('离线队列加载失败（后续 submit 会重试存储）', {'error': e.toString()});
    }
  }

  /// 提交一条消息。
  ///
  /// ## 三种结果（见 [OutboxSubmitOutcome]）
  ///
  /// 1. 网络可用 → 直接投递，返回 [OutboxSubmittedNow]；
  /// 2. 网络不可用（可重试错误）→ 入队，返回 [OutboxQueuedOffline]；
  /// 3. 入队本身失败（存储故障）→ [OutboxEnqueueFailed]。
  ///
  /// 终态错误（400 等）**不入队**，直接上抛——重试无用，入队只会让用户在
  /// 「待发送」里看到一条永远发不出去的消息。
  Future<OutboxSubmitOutcome> submit({
    required String userId,
    required String input,
    String? groupId,
    String? agentId,
    String routingMode = 'auto',
  }) async {
    _userId = userId;
    final now = _now();
    final entry = OutboxEntry(
      // 幂等键在这里生成一次，此后每次重试都用它。
      id: _uuid.v4(),
      userId: userId,
      input: input,
      groupId: groupId,
      agentId: agentId,
      routingMode: routingMode,
      createdAt: now,
      nextAttemptAt: now,
      maxAttempts: _policy.maxAttempts,
    );

    try {
      final result = await _send(entry);
      // 直接成功：**不入队**（队列里出现一条已投递的行是纯噪声）。
      if (!_deliveredController.isClosed) {
        _deliveredController.add(OutboxDelivered(entry: entry, result: result));
      }
      return OutboxSubmittedNow(result: result);
    } on SpbError catch (e) {
      if (!OutboxRetryPolicy.isRetryable(e)) {
        // 终态错误：不入队，上抛给 UI（重试无用）。
        rethrow;
      }
      final queued = entry.copyWith(attempts: 1, lastError: e.message);
      // 入队失败 → 降级为旧行为（提示发送失败），而不是假装排队成功。
      try {
        await _store.upsert(queued);
      } catch (storageError) {
        return OutboxEnqueueFailed(
          error: storageError is SpbError
              ? storageError
              : StorageError('离线队列写入失败：$storageError'),
        );
      }
      _entries.add(queued);
      _emit();
      SpbLog.info('消息已入离线队列', {
        'user_id': userId,
        'request_id': queued.id,
        'attempts': queued.attempts,
      });
      _scheduleRetry(queued);
      return OutboxQueuedOffline(entry: queued);
    }
  }

  /// 尝试投递队首（以及其后的条目，直到遇到一个需要等待的）。
  ///
  /// 幂等：并发调用只会有一轮真正在跑。
  Future<void> drain() async {
    if (_disposed || _draining) return;
    _draining = true;
    try {
      // ## 进度哨兵（防忙循环）
      //
      // `while` 的退出依赖「每一轮要么投出去一条、要么因退避停下」这个
      // 不变式。若将来有人改坏 `_nextSendable` / `_attempt` 使某个条目**既
      // 没被移除也没推进 `nextAttemptAt`**（例如 `_nextSendable` 忘了跳过
      // `failed`），本循环会**永远转下去**——不抛异常、不占 CPU 峰值，只是
      // 一个卡死的后台任务，而且 `_draining` 永远为 true，后续 drain 全被
      // 静默吞掉。
      //
      // 实测过一次：去掉 `_nextSendable` 的 failed 跳过后，测试挂死到超时。
      // 故用「本轮队列长度必须下降」作为哨兵，触发即中断并记 error（不静默）。
      var remaining = _entries.length;
      while (!_disposed) {
        final head = _nextSendable();
        if (head == null) break;

        final now = _now();
        if (head.nextAttemptAt.isAfter(now)) {
          // 还没到时间：排一个定时器，本轮结束。
          _scheduleRetry(head);
          break;
        }

        final resolved = await _attempt(head);
        if (!resolved) break; // 可重试失败 → 停下等退避（队首阻塞）

        if (_entries.length >= remaining) {
          // 本轮「已解决」却没让队列变短 → 不变式被破坏，绝不能继续转。
          SpbLog.error(
            '离线队列 drain 未取得进展，已中断本轮（不变式被破坏）',
            fields: {
              'entries': _entries.length,
              'head': head.id,
              'head_status': head.status.name,
            },
          );
          break;
        }
        remaining = _entries.length;
      }
    } finally {
      _draining = false;
    }
  }

  /// 取消一条**未在投递中**的条目。
  ///
  /// 返回 false 表示拒绝（条目正在投递，或不存在）。
  ///
  /// ## 为什么投递中要拒绝（而不是标记取消）
  ///
  /// 「标记取消 + 忽略结果」会留下静默不一致：用户以为取消了，服务端却建了
  /// turn——而服务端**没有**删除 turn 的端点可用来补救。拒绝则是诚实的：
  /// 请求已经发出去了，等它 resolve 再决定。
  Future<bool> cancel(String id) async {
    if (_inFlight.contains(id)) return false;
    final idx = _entries.indexWhere((e) => e.id == id);
    if (idx < 0) return false;
    final removed = _entries.removeAt(idx);
    _emit();
    try {
      await _store.delete(id);
    } catch (e) {
      // 存储删除失败：条目已从内存移除，但重启后会「复活」。记 warn 并
      // **把它放回原位**——两份状态不一致比「取消没生效」更糟。
      SpbLog.warn('离线队列条目删除失败，已回滚内存状态', {
        'request_id': id,
        'error': e.toString(),
      });
      _entries.insert(idx.clamp(0, _entries.length), removed);
      _emit();
      return false;
    }
    return true;
  }

  /// 手动重试（重置 `attempts`，清掉 `lastError`，立即投递）。
  ///
  /// 供 UI 的「重试」按钮使用，主要针对 [OutboxStatus.failed] 的条目。
  Future<bool> retryNow(String id) async {
    final idx = _entries.indexWhere((e) => e.id == id);
    if (idx < 0) return false;
    final now = _now();
    final revived = _entries[idx].copyWith(
      attempts: 0,
      nextAttemptAt: now,
      clearLastError: true,
    );
    _entries[idx] = revived;
    _emit();
    try {
      await _store.upsert(revived);
    } catch (e) {
      SpbLog.warn('离线队列重置失败', {'request_id': id, 'error': e.toString()});
      return false;
    }
    unawaited(drain());
    return true;
  }

  /// 删除一条（用户手动丢弃 [OutboxStatus.failed] 的条目）。
  Future<void> remove(String id) async {
    await cancel(id);
  }

  /// 通知「网络可能恢复了」（SSE 状态变为 `connected` 时调用）。
  ///
  /// ## 为什么用 SSE 状态而不是轮询
  ///
  /// 它是**最强的恢复信号**——连接真的建立了，说明服务端可达。比轮询准确
  /// （轮询在断网时纯耗电），也比 `connectivity_plus` 之类的「有默认路由」
  /// 判断更接近「服务端可达」这个真正关心的条件。
  ///
  /// 把所有条目的 `nextAttemptAt` 拉到现在，让 [drain] 立刻可以推进。
  Future<void> onConnectivityRestored() async {
    if (_disposed || _entries.isEmpty) return;
    final now = _now();
    var changed = false;
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      // 只提前「还会自动重试」的；`failed` 的重试权在用户手里。
      if (e.status == OutboxStatus.failed) continue;
      if (e.nextAttemptAt.isAfter(now)) {
        _entries[i] = e.copyWith(nextAttemptAt: now);
        changed = true;
      }
    }
    if (!changed) return;
    _emit();
    // 持久化新的时间（失败不影响本轮投递）。
    for (final e in _entries) {
      try {
        await _store.upsert(e);
      } catch (err) {
        // 时间戳没落盘只影响重启后的首次投递时刻，不影响本次。
        //
        // 但仍要记一笔（issue #45）：否则「重启后行为与预期不符」这一现象
        // 在诊断报告里**完全没有痕迹**，排查时只能靠猜。
        SpbLog.debug('离线队列提前重试时间未落盘（重启后首次投递时刻可能偏后）', {
          'request_id': e.id,
          'error': err.toString(),
        });
      }
    }
    _timer?.cancel();
    _timer = null;
    unawaited(drain());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _entriesController.close();
    await _deliveredController.close();
    await _failureController.close();
  }

  /// 队首「可发送」的条目：跳过 `failed`（其重试权在用户手里）。
  OutboxEntry? _nextSendable() {
    for (final e in _entries) {
      if (e.status != OutboxStatus.failed) return e;
    }
    return null;
  }

  /// 投递一条。返回 true = 已解决（成功或终态移除），可以继续下一条；
  /// false = 可重试失败，本轮应停下。
  Future<bool> _attempt(OutboxEntry entry) async {
    _inFlight.add(entry.id);
    try {
      final result = await _send(entry);
      // 成功：移出队列 + 推事件。
      _entries.removeWhere((e) => e.id == entry.id);
      _emit();
      try {
        await _store.delete(entry.id);
      } catch (e) {
        // 删除失败：重启后这条会「复活」并被重复投递——但**不会**产生重复
        // turn（request_id 幂等，服务端会返回既有 turn）。故记 warn 即可。
        SpbLog.warn('离线队列条目删除失败（重启后可能重复投递，幂等键可兜底）', {
          'request_id': entry.id,
          'error': e.toString(),
        });
      }
      if (!_deliveredController.isClosed) {
        _deliveredController.add(OutboxDelivered(entry: entry, result: result));
      }
      SpbLog.info('离线队列投递成功', {
        'request_id': entry.id,
        'attempts': entry.attempts,
        'turn_id': result.turnId,
      });
      return true;
    } on SpbError catch (e) {
      final attempts = entry.attempts + 1;

      if (!OutboxRetryPolicy.isRetryable(e)) {
        // 终态错误：移出队列 + 上报（不是静默丢弃）。
        _entries.removeWhere((x) => x.id == entry.id);
        _emit();
        try {
          await _store.delete(entry.id);
        } catch (err) {
          // 删除失败是**幂等兜底**：条目已从内存移出，重启后它会再次被投递，
          // 而服务端的 `(user_id, request_id)` 幂等键会去重。故不必 warn。
          // 记 debug 是为了在诊断报告里留下「为什么重启后出现重复投递」的线索。
          SpbLog.debug('离线队列终态条目删除失败（重启后可能重复投递，幂等键兜底）', {
            'request_id': entry.id,
            'error': err.toString(),
          });
        }
        if (!_failureController.isClosed) {
          _failureController.add(
            OutboxFailure(entry: entry, error: e, exhausted: false),
          );
        }
        SpbLog.warn('离线队列条目终态失败（不再重试）', {
          'request_id': entry.id,
          'error': e.toString(),
        });
        // 队首已解决 → 继续投后面的。
        return true;
      }

      // ⚠️ 用 **entry.maxAttempts**（入队时快照的），不是 `_policy.maxAttempts`。
      //
      // 策略可能在两次启动之间被改（配置或代码升级）。一条在上限 10 下入队
      // 的条目，不该因为下次启动时上限改成 3 就突然被判失败——用户并没有
      // 改过这条消息的重试意愿。反之，`entry.maxAttempts` 与 `status` 的判据
      // 同源，两处不会打架。
      if (attempts >= entry.maxAttempts) {
        // 重试次数用尽：**保留条目**（那是用户输入的文本，不自动删除），
        // 标 failed 等用户手动处理。
        final failed = entry.copyWith(attempts: attempts, lastError: e.message);
        _replace(failed);
        _emit();
        try {
          await _store.upsert(failed);
        } catch (err) {
          // 内存态已正确（条目是 failed），但**没落盘**：重启后它会回到
          // 上次落盘的 `pending`，用户会看到「已耗尽重试」的条目又开始重试。
          // 这是「重启后行为与用户所见不一致」的真实来源，必须留痕。
          SpbLog.warn('离线队列条目状态未落盘（重启后可能仍按 pending 重试）', {
            'request_id': entry.id,
            'status': failed.status.name,
            'error': err.toString(),
          });
        }
        if (!_failureController.isClosed) {
          _failureController.add(
            OutboxFailure(entry: failed, error: e, exhausted: true),
          );
        }
        SpbLog.warn('离线队列条目重试次数用尽', {
          'request_id': entry.id,
          'attempts': attempts,
        });
        // 它现在是 `failed`，会被 `_nextSendable` 跳过 → 继续投后面的。
        return true;
      }

      final delay = _policy.delayFor(attempts, random: _random);
      final updated = entry.copyWith(
        attempts: attempts,
        nextAttemptAt: _now().add(delay),
        lastError: e.message,
      );
      _replace(updated);
      _emit();
      try {
        await _store.upsert(updated);
      } catch (err) {
        // 同上面的 failed 分支：内存里退避时间是对的，但没落盘 → 重启后
        // 首次投递时刻会比预期早（回到上次落盘的时间）。
        SpbLog.debug('离线队列退避时间未落盘（重启后首次投递时刻可能偏早）', {
          'request_id': entry.id,
          'attempts': attempts,
          'error': err.toString(),
        });
      }
      SpbLog.debug('离线队列投递失败，将退避重试', {
        'request_id': entry.id,
        'attempts': attempts,
        'delay_ms': delay.inMilliseconds,
      });
      _scheduleRetry(updated);
      return false;
    } finally {
      _inFlight.remove(entry.id);
    }
  }

  void _replace(OutboxEntry entry) {
    final idx = _entries.indexWhere((e) => e.id == entry.id);
    if (idx >= 0) {
      _entries[idx] = entry;
    } else {
      _entries.add(entry);
    }
  }

  /// 按 [entry] 的 `nextAttemptAt` 排一个定时器。
  void _scheduleRetry(OutboxEntry entry) {
    if (_disposed) return;
    _timer?.cancel();
    final wait = entry.nextAttemptAt.difference(_now());
    _timer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(drain()),
    );
  }

  void _emit() {
    if (_entriesController.isClosed) return;
    _entriesController.add(List.unmodifiable(_entries));
  }
}
