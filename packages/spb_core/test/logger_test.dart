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
}
