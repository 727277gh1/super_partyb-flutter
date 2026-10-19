import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 记录收到的日志，供断言检查。
///
/// 不直接用 [NullLogSink]：本测试要验的正是「sink 收到了什么」，
/// 丢掉内容就没法断言字段是否结构化。
class _RecordingSink implements LogSink {
  final calls =
      <({LogLevel level, String message, Map<String, Object?> fields})>[];

  @override
  void write(LogLevel level, String message, Map<String, Object?> fields) {
    calls.add((level: level, message: message, fields: fields));
  }

  List<LogLevel> get levels => calls.map((c) => c.level).toList();
}

/// `spb_core` 日志的契约测试。
///
/// ## 这个测试防的是什么
///
/// `SpbLog` 是**可变全局单例**（文档明说这是有意设计：日志要能在无 DI 的纯函数
/// 里取到）。这带来两个极易出错、且出错后**很难发现**的点：
///
///   1. **阈值过滤的方向**：`_log` 里是 `level.severity < _minLevel.severity`
///      才 return。写反成 `>` 会让「设成 warn 之后连 error 都被过滤掉」——
///      服务崩了却没有任何日志，且没有任何报错。
///   2. **minLevel 的持久性**：`configure(minLevel:)` 只在**传了非 null** 时改
///      阈值。于是「设成 error 后，下一次 configure 不带 minLevel」会**保留**
///      error 阈值。测试之间若不显式复位，就会出现「单跑绿、全量跑挂」的
///      顺序依赖——本文件的 tearDown 就是为此。
void main() {
  // 每个用例后把全局状态复位，避免顺序依赖（见上方说明 2）。
  tearDown(() {
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.info);
    // 环形缓冲也是全局单例：不清会跨用例累积（断言「缓冲里有什么」
    // 之前必须先清，否则结果取决于用例执行顺序）。
    SpbLog.clearRecentLogs();
  });

  group('SpbLog.configure', () {
    test('返回旧 sink，便于调用方恢复', () {
      final a = _RecordingSink();
      final b = _RecordingSink();

      final old1 = SpbLog.configure(sink: a);
      final old2 = SpbLog.configure(sink: b);

      // 第一次替换前的默认 sink 是 ConsoleLogSink。
      expect(old1, isA<ConsoleLogSink>());
      // 第二次返回的是刚装上的 a，不是默认 sink。
      expect(old2, same(a));
    });

    test('configure 不带 minLevel 时**保留**上次的阈值', () {
      // 这是文档化的行为（`if (minLevel != null) _minLevel = minLevel;`）。
      // 把它当成「不传就恢复默认」是常见误读，故显式钉住。
      SpbLog.configure(sink: _RecordingSink(), minLevel: LogLevel.error);
      SpbLog.configure(sink: _RecordingSink());

      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);
      SpbLog.warn('应被 error 阈值滤掉');
      expect(sink.calls, isEmpty, reason: '阈值应仍是 error');
    });

    test('显式传 minLevel 才改阈值', () {
      SpbLog.configure(sink: _RecordingSink(), minLevel: LogLevel.error);
      SpbLog.configure(sink: _RecordingSink(), minLevel: LogLevel.debug);

      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);
      SpbLog.debug('应通过');
      expect(sink.calls, hasLength(1));
    });
  });

  group('minLevel 过滤', () {
    test('低于阈值的日志不进 sink', () {
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink, minLevel: LogLevel.warn);

      SpbLog.debug('d');
      SpbLog.info('i');
      SpbLog.warn('w');
      SpbLog.error('e');

      // 方向正确：**低于**阈值被滤掉，等于或高于的通过。
      expect(sink.levels, [LogLevel.warn, LogLevel.error]);
      expect(sink.calls.map((c) => c.message), ['w', 'e']);
    });

    test('阈值等于某级别时，该级别**通过**（边界，不是严格大于）', () {
      // `severity < minLevel` 用的是严格小于，故阈值本身必须放行。
      // 若被改成 `<=`，把阈值设成 info 会把所有 info 日志全丢掉。
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink, minLevel: LogLevel.info);

      SpbLog.info('恰好等于阈值');
      expect(sink.calls, hasLength(1));
    });

    test('阈值设为 debug 时四级全通过（最宽松）', () {
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink, minLevel: LogLevel.debug);

      SpbLog.debug('d');
      SpbLog.info('i');
      SpbLog.warn('w');
      SpbLog.error('e');

      expect(sink.levels, [
        LogLevel.debug,
        LogLevel.info,
        LogLevel.warn,
        LogLevel.error,
      ]);
    });

    test('阈值设为 error 时只有 error 通过（最严格）', () {
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink, minLevel: LogLevel.error);

      SpbLog.debug('d');
      SpbLog.info('i');
      SpbLog.warn('w');
      SpbLog.error('e');

      expect(sink.levels, [LogLevel.error]);
    });
  });

  group('LogLevel 元数据', () {
    test('severity 单调递增（过滤逻辑依赖它）', () {
      // 过滤是按 severity 数值比较的，不是按 enum 声明顺序。若有人调整了
      // 数值让它们不再单调，过滤行为会静默错乱。
      expect(LogLevel.debug.severity, lessThan(LogLevel.info.severity));
      expect(LogLevel.info.severity, lessThan(LogLevel.warn.severity));
      expect(LogLevel.warn.severity, lessThan(LogLevel.error.severity));
    });

    test('label 是大写短名（对齐服务端 slog 字段约定）', () {
      expect(LogLevel.debug.label, 'DEBUG');
      expect(LogLevel.info.label, 'INFO');
      expect(LogLevel.warn.label, 'WARN');
      expect(LogLevel.error.label, 'ERROR');
    });
  });

  group('结构化字段', () {
    test('字段原样传给 sink（键与值都不改写）', () {
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);

      SpbLog.info('发送消息', {'request_id': 'req_1', 'group_id': 'grp_1'});

      expect(sink.calls, hasLength(1));
      expect(sink.calls.single.message, '发送消息');
      expect(sink.calls.single.fields, {
        'request_id': 'req_1',
        'group_id': 'grp_1',
      });
    });

    test('不传字段时是空 Map（不是 null）', () {
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);

      SpbLog.info('无字段');

      expect(sink.calls.single.fields, isEmpty);
      expect(sink.calls.single.fields, isA<Map<String, Object?>>());
    });

    test('error 把 error / stackTrace 富化进 fields', () {
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);

      final st = StackTrace.current;
      SpbLog.error(
        '请求失败',
        error: const NetworkError('超时'),
        stackTrace: st,
        fields: {'request_id': 'req_2'},
      );

      final f = sink.calls.single.fields;
      // 既有字段保留。
      expect(f['request_id'], 'req_2');
      // error 被 toString 后放进 `error` 键（与服务端字段名对齐）。
      expect(f['error'], 'NetworkError: 超时');
      expect(f['stack'], st.toString());
    });

    test('error 不带 error / stackTrace 时不产生这些键', () {
      // 关键：不能写入 `'error': 'null'` 这种字符串——那会让日志看起来
      // 像是真的发生了名为 null 的错误。
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);

      SpbLog.error('光秃秃的错误');

      final f = sink.calls.single.fields;
      expect(f.containsKey('error'), isFalse);
      expect(f.containsKey('stack'), isFalse);
      expect(f, isEmpty);
    });

    test('error 的 fields 不被调用方传入的 Map 污染（复制而非共享）', () {
      // `_log` 里用 `{...fields, ...}` 建了新 Map。若改成直接改传入的 Map，
      // 调用方复用的常量 Map 会被写入 error 键——下一次用它就带着上次的错误。
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);

      final shared = <String, Object?>{'request_id': 'req_3'};
      SpbLog.error('失败', error: const StorageError('磁盘满'), fields: shared);

      expect(shared.containsKey('error'), isFalse, reason: '调用方的 Map 不该被改');
      expect(shared, {'request_id': 'req_3'});
      expect(sink.calls.single.fields['error'], 'StorageError: 磁盘满');
    });
  });

  group('NullLogSink / ConsoleLogSink', () {
    test('NullLogSink 丢弃一切（测试用，不抛）', () {
      // 它被大量用于测试环境；抛异常会污染无关用例。
      expect(
        () => const NullLogSink().write(LogLevel.error, 'x', const {}),
        returnsNormally,
      );
    });

    test('ConsoleLogSink 可构造且不抛（含空字段与非空字段）', () {
      // 不捕获 stdout 断言格式（那会把测试绑死在打印格式上），只确认
      // 两条分支都不会抛——字段为空时的分支最容易被漏掉。
      expect(
        () => const ConsoleLogSink().write(LogLevel.info, '无字段', const {}),
        returnsNormally,
      );
      expect(
        () =>
            const ConsoleLogSink().write(LogLevel.info, '有字段', const {'a': 1}),
        returnsNormally,
      );
    });
  });

  _recentLogsTests();
  _redactSecretsTests();
  _diagnosticsReportTests();
}

/// 环形缓冲（issue #40）。
///
/// ## 这个测试防的是什么
///
/// 缓冲是「导出诊断日志」的唯一数据源，而它挂在**可变全局单例**上：
/// - 上限算错（`>` vs `>=`、`removeRange` 的区间）→ 内存随运行时长无限
///   增长，或「保留最近 500 条」变成「保留最早的 500 条」——两种都让报告
///   失去价值，而没有任何报错；
/// - 阈值过滤放在缓冲**之后** → 报告里出现用户实际看不到的 debug 日志，
///   「日志里没有」被误读成「没发生」；
/// - 存的是字段 Map 的引用 → 调用方复用同一个可变 Map 时，历史记录会被
///   后来的写入篡改（时间线错乱）。
void _recentLogsTests() {
  group('SpbLog 环形缓冲', () {
    test('按记录顺序保留（最旧在前）', () {
      final sink = _RecordingSink();
      SpbLog.configure(sink: sink);

      SpbLog.info('第一条');
      SpbLog.warn('第二条');
      SpbLog.error('第三条');

      expect(SpbLog.recentLogs.map((r) => r.message), ['第一条', '第二条', '第三条']);
      expect(SpbLog.recentLogs.map((r) => r.level), [
        LogLevel.info,
        LogLevel.warn,
        LogLevel.error,
      ]);
    });

    test('超过上限时丢弃**最旧**的（不是最新的）', () {
      // 方向写反（丢最新）会让报告只剩启动时的日志——而报障要的正是
      // 「出问题前后那几十条」。
      SpbLog.configure(sink: _RecordingSink());
      const capacity = SpbLog.recentLogCapacity;
      expect(capacity, greaterThan(2), reason: '上限太小就测不出环形行为');

      for (var i = 0; i < capacity + 3; i++) {
        SpbLog.info('日志$i');
      }

      final messages = SpbLog.recentLogs.map((r) => r.message).toList();
      expect(messages, hasLength(capacity));
      expect(messages.first, '日志3', reason: '最旧的 0/1/2 应被丢掉');
      expect(messages.last, '日志${capacity + 2}');
    });

    test('恰好等于上限时**不**丢（边界：是 > 不是 >=）', () {
      SpbLog.configure(sink: _RecordingSink());
      const capacity = SpbLog.recentLogCapacity;

      for (var i = 0; i < capacity; i++) {
        SpbLog.info('日志$i');
      }

      final messages = SpbLog.recentLogs.map((r) => r.message).toList();
      expect(messages, hasLength(capacity));
      expect(messages.first, '日志0');
    });

    test('低于阈值的日志**不进**缓冲（与 sink 同口径）', () {
      // 若缓冲放在阈值过滤之前，报告里会有用户从未看到的日志。
      SpbLog.configure(sink: _RecordingSink(), minLevel: LogLevel.warn);

      SpbLog.debug('看不到的 debug');
      SpbLog.info('看不到的 info');
      SpbLog.warn('看得到的 warn');

      expect(SpbLog.recentLogs.map((r) => r.message), ['看得到的 warn']);
    });

    test('记录的字段是快照（调用方复用可变 Map 不会篡改历史）', () {
      SpbLog.configure(sink: _RecordingSink());

      final shared = <String, Object?>{'request_id': 'req_1'};
      SpbLog.info('第一次', shared);
      shared['request_id'] = 'req_2';
      SpbLog.info('第二次', shared);

      expect(SpbLog.recentLogs[0].fields['request_id'], 'req_1');
      expect(SpbLog.recentLogs[1].fields['request_id'], 'req_2');
    });

    test('记录不可被外部修改（只读视图）', () {
      SpbLog.configure(sink: _RecordingSink());
      SpbLog.info('x');

      // 「导出」的前提是报告反映真实发生过的事；能被调用方删改就不是了。
      expect(() => SpbLog.recentLogs.clear(), throwsUnsupportedError);
    });

    test('clearRecentLogs 清空缓冲（测试专用）', () {
      SpbLog.configure(sink: _RecordingSink());
      SpbLog.info('x');
      expect(SpbLog.recentLogs, isNotEmpty);

      SpbLog.clearRecentLogs();
      expect(SpbLog.recentLogs, isEmpty);
    });

    test('error 的 error / stackTrace 也进缓冲', () {
      SpbLog.configure(sink: _RecordingSink());

      SpbLog.error('崩了', error: const NetworkError('超时'));

      final fields = SpbLog.recentLogs.single.fields;
      expect(fields['error'], 'NetworkError: 超时');
    });
  });

  group('LogRecord.format', () {
    test('单行形态：时间戳 + 对齐的 level + message + 字段', () {
      final record = LogRecord(
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
        level: LogLevel.warn,
        message: 'SSE 连接失败',
        fields: const {'status': '502'},
      );

      final line = record.format();
      expect(line, startsWith('2026-01-02T03:04:05.000Z WARN  '));
      expect(line, contains('SSE 连接失败'));
      expect(line, contains('status=502'));
      expect(line, isNot(contains('\n')), reason: '一条日志必须是一行');
    });

    test('字段值里的换行被转义成字面量 \\n（堆栈不会把一条拆成多条）', () {
      // 报告会被用户贴进 issue。堆栈原样输出会让读者把堆栈第 2 行当成
      // 「又一条日志」。
      final record = LogRecord(
        timestamp: DateTime.utc(2026, 1, 2),
        level: LogLevel.error,
        message: '异常',
        fields: const {'stack': 'at a\nat b\r\nat c\rat d'},
      );

      final line = record.format();
      expect(line, isNot(contains('\n')));
      expect(line, isNot(contains('\r')));
      expect(line, contains(r'at a\nat b\nat c\nat d'));
    });

    test('含空格的字段值加引号（人读时能看出边界）', () {
      final record = LogRecord(
        timestamp: DateTime.utc(2026, 1, 2),
        level: LogLevel.info,
        message: 'm',
        fields: const {'path': '/home/u/my out', 'host': 'a.example.com'},
      );

      expect(record.format(), contains('path="/home/u/my out"'));
      expect(record.format(), contains('host=a.example.com'));
    });

    test('null 字段值渲染成字面量 null（不是空）', () {
      // 空值会让读者分不清「字段不存在」与「值为空」。
      final record = LogRecord(
        timestamp: DateTime.utc(2026, 1, 2),
        level: LogLevel.info,
        message: 'm',
        fields: const {'cursor': null},
      );

      expect(record.format(), contains('cursor=null'));
    });

    test('toString 委托给 format（日志里内插 record 不会拿到默认输出）', () {
      final record = LogRecord(
        timestamp: DateTime.utc(2026, 1, 2),
        level: LogLevel.info,
        message: 'm',
        fields: const {},
      );

      expect(record.toString(), record.format());
      expect(record.toString(), isNot(contains('Instance of')));
    });
  });
}

/// 脱敏（issue #40）。
///
/// ## 这个测试防的是什么
///
/// 诊断报告会被用户贴进公开 issue / 聊天窗口，而**泄漏的凭证收不回来**。
/// 日志侧虽已克制（`session_credential.dart` 明写「绝不记录 token 值」），
/// 但那是约定、不是机制——将来有人不小心把 header 打进日志，这里就是最后
/// 一道防线。
///
/// 另一半同样重要：**不能过度掩码**。把「收到 401，会话凭证可能已失效」
/// 这种无辜文本抹掉，等于把诊断信息删了——报告就白导了。
void _redactSecretsTests() {
  group('redactSecrets：掩掉凭据', () {
    test('Authorization 头（Bearer + JWT）', () {
      final out = redactSecrets(
        'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.abc123',
      );
      expect(out, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(out, contains('Authorization'));
    });

    test('裸 Bearer（无 Authorization 前缀）', () {
      final out = redactSecrets('header = Bearer abcdefghijklmnop');
      expect(out, isNot(contains('abcdefghijklmnop')));
    });

    test('JSON 形态的 access_token / refresh_token', () {
      final out = redactSecrets(
        '{"access_token":"secret-value-1","refresh_token":"secret-value-2"}',
      );
      expect(out, isNot(contains('secret-value-1')));
      expect(out, isNot(contains('secret-value-2')));
      // 键名保留：报告里「哪个字段被掩了」本身就是诊断信息。
      expect(out, contains('access_token'));
      expect(out, contains('refresh_token'));
    });

    test('key=value 形态（api_key / password / client_secret）', () {
      final out = redactSecrets(
        'api_key=abc123 password: hunter2 client_secret="s3cr3t"',
      );
      expect(out, isNot(contains('abc123')));
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('s3cr3t')));
    });

    test('已知前缀的长期令牌（sk- / ghp_ / xoxb- / AKIA）', () {
      final out = redactSecrets(
        'sk-abcdefghijklmnopqrstuvwxyz ghp_0123456789012345678901234567890'
        ' xoxb-1234567890-abcdefghij AKIAIOSFODNN7EXAMPLE',
      );
      expect(out, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz')));
      expect(out, isNot(contains('ghp_0123456789012345678901234567890')));
      expect(out, isNot(contains('xoxb-1234567890-abcdefghij')));
      expect(out, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
    });

    test('URL 里的 user:pass@', () {
      final out = redactSecrets('https://alice:hunter2@api.example.com/x');
      expect(out, isNot(contains('hunter2')));
      expect(out, contains('api.example.com'));
    });

    test('PEM 私钥头', () {
      final out = redactSecrets('-----BEGIN RSA PRIVATE KEY-----');
      expect(out, isNot(contains('PRIVATE KEY')));
    });

    test('一条文本里的多处凭据全被掩掉（不因先命中一处而漏后面的）', () {
      final out = redactSecrets(
        'Authorization: Bearer abcdefghijklmnop api_key=secret123',
      );
      expect(out, isNot(contains('abcdefghijklmnop')));
      expect(out, isNot(contains('secret123')));
    });

    test('大小写不敏感（Authorization / authorization / PASSWORD）', () {
      final out = redactSecrets(
        'AUTHORIZATION=abcdefghijklmnop PASSWORD=secret',
      );
      expect(out, isNot(contains('abcdefghijklmnop')));
      expect(out, isNot(contains('secret')));
    });
  });

  group('redactSecrets：**不**过度掩码', () {
    test('普通的 401 提示文案原样保留', () {
      // 这是 `auth_interceptor.dart` 真实记录的一条日志。若键名黑名单写得
      // 太宽（如把「凭证」也算上），这条诊断信息会被抹掉。
      const line = '收到 401，会话凭证可能已失效';
      expect(redactSecrets(line), line);
    });

    test('路径 / 域名 / 端口 / 环境名原样保留', () {
      const line =
          'path=/home/u/out scheme=https host=api.example.com port=443 env=prod';
      expect(redactSecrets(line), line);
    });

    test('不含凭据的 JSON 原样保留', () {
      const line = '{"status":"running","count":3}';
      expect(redactSecrets(line), line);
    });

    test('无凭据的长文本原样返回（不做全量替换）', () {
      final text = List.generate(50, (i) => '日志第 $i 行').join('\n');
      expect(redactSecrets(text), text);
    });

    test('英文句子里的 bearer 一词不被误伤（词后无 token 形态）', () {
      const line = 'the bearer of bad news';
      expect(redactSecrets(line), line);
    });
  });
}

/// 诊断报告组装（issue #40）。
///
/// ## 这个测试防的是什么
///
/// 报告是用户报障时**唯一**的信息来源，也是最容易被写错的一环：
/// - 把凭证原样带进去（上组已单独测）；
/// - 环境信息为空（「导出成功但什么都没有」）；
/// - 日志条数与实际不符（用户据此判断「是不是日志被截断了」）。
void _diagnosticsReportTests() {
  group('buildDiagnosticsReport', () {
    test('含版本 / 平台等环境信息与日志条数', () {
      final report = buildDiagnosticsReport(
        environment: const {'app': '0.1.0+1', 'platform': 'linux'},
        logs: const [],
        generatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );

      expect(report, contains('Super PartyB 诊断报告'));
      expect(report, contains('2026-01-02T03:04:05.000Z'));
      expect(report, contains('app: 0.1.0+1'));
      expect(report, contains('platform: linux'));
      expect(report, contains('最近日志（0 条'));
    });

    test('逐条渲染日志（时间戳 / 级别 / 文本 / 字段）', () {
      final report = buildDiagnosticsReport(
        environment: const {'app': '0.1.0+1'},
        logs: [
          LogRecord(
            timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
            level: LogLevel.error,
            message: 'SSE 连接异常',
            fields: const {'error': 'timeout'},
          ),
        ],
      );

      expect(report, contains('2026-01-02T03:04:05.000Z ERROR SSE 连接异常'));
      expect(report, contains('error=timeout'));
      expect(report, contains('最近日志（1 条'));
    });

    test('条数上限写进报告（用户能判断日志是否被截断）', () {
      final report = buildDiagnosticsReport(environment: const {});
      expect(report, contains('上限 ${SpbLog.recentLogCapacity}'));
    });

    test('环境信息为空时如实说明（而不是留白）', () {
      final report = buildDiagnosticsReport(environment: const {});
      expect(report, contains('（未提供）'));
    });

    test('无日志时如实说明', () {
      final report = buildDiagnosticsReport(
        environment: const {'app': 'x'},
        logs: const [],
      );
      expect(report, contains('（无）'));
    });

    test('不传 logs 时取环形缓冲的当前内容', () {
      SpbLog.configure(sink: _RecordingSink());
      SpbLog.info('来自缓冲的日志');

      final report = buildDiagnosticsReport(environment: const {'app': 'x'});
      expect(report, contains('来自缓冲的日志'));
      expect(report, contains('最近日志（1 条'));
    });

    test('输出**必定**已脱敏（调用方无需自己再掩一次）', () {
      // 这是本函数的核心不变量：不管环境信息与日志里混进了什么，
      // 出参都过了 redactSecrets。
      final report = buildDiagnosticsReport(
        environment: const {
          'app': '0.1.0+1',
          // 模拟「有人不小心把 header 写进了环境信息」。
          'debug_header': 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def',
        },
        logs: [
          LogRecord(
            timestamp: DateTime.utc(2026, 1, 2),
            level: LogLevel.error,
            message: 'api_key=supersecret123',
            fields: const {'token': 'another-secret'},
          ),
        ],
      );

      expect(report, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(report, isNot(contains('supersecret123')));
      expect(report, isNot(contains('another-secret')));
    });

    test('环境信息里的换行被转义（值不能撑破报告的段落结构）', () {
      final report = buildDiagnosticsReport(
        environment: const {'os': 'line1\nline2'},
      );
      expect(report, contains(r'os: line1\nline2'));
    });

    test('日志之间不产生空行（每条一行，便于阅读与复制）', () {
      final report = buildDiagnosticsReport(
        environment: const {},
        logs: [
          for (var i = 0; i < 3; i++)
            LogRecord(
              timestamp: DateTime.utc(2026, 1, 2),
              level: LogLevel.info,
              message: '第$i条',
              fields: const {},
            ),
        ],
      );

      // 只取「最近日志」与「说明」两节之间的内容。
      final logSection = report.split('## 最近日志')[1].split('## 说明')[0];
      final lines = logSection
          .split('\n')
          .where((l) => l.contains('第') && l.contains('条'))
          .toList();
      expect(lines, hasLength(3));
      // 日志区内部的最后一条与下一节之间允许一个空行（节分隔），
      // 但**日志之间**不得有空行（空行会把报告从 500 行撑成 1000 行）。
      expect(
        logSection.trimRight(),
        isNot(contains('\n\n')),
        reason: '节内除节尾外不得有空行',
      );
    });
  });
}
