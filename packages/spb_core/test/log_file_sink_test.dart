import 'dart:io';

import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// [FileLogSink] 与 [defaultLogFilePath] / [previousSessionExitedCleanly] 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 这几个东西的全部价值是「**进程已经死了**之后还能看到证据」。它们出错时
/// 没有任何运行时反馈：写盘失败静默停用、轮转写错把最新日志扔掉、会话标记
/// 顺序写反让「崩溃」永远被报成「正常退出」——而这三件事都**只在不方便调试
/// 的时候**（崩溃后）才会被用到。
void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('spb_log_test');
    path = '${tmp.path}/logs/app.log';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String readLog() => File(path).readAsStringSync();

  group('FileLogSink 基本写入', () {
    test('建父目录并追加写入（不覆盖已存在的日志）', () {
      // 父目录不存在也要能写：应用首次启动时 logs/ 一定不存在。
      File(path).parent.createSync(recursive: true);
      File(path).writeAsStringSync('旧日志\n');

      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, '第一条', {'k': 'v'});

      final all = readLog();
      expect(all, contains('旧日志'));
      expect(all, contains('第一条'));
      // 字段以 `k=v` 形式落盘（与诊断报告同一 format()）。
      expect(all, contains('k=v'));
      expect(sink.writes, 1);
      expect(sink.isDisabled, isFalse);
    });

    test('首次写入时自动创建目录', () {
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.warn, 'hi');
      expect(File(path).existsSync(), isTrue);
    });

    test('每条一行（多行消息不破坏行结构）', () {
      final sink = FileLogSink(path: path, redact: false);
      sink.write(LogLevel.info, 'a\nb');
      final lines = readLog().trimRight().split('\n');
      // LogRecord.format() 把换行**转义成字面 `\n`**（不是折成空格）——否则
      // 「一行一日志」不成立，而 `previousSessionExitedCleanly` 的「最后一行」
      // 判据就依赖它（多行消息会把退出标记挤出末尾）。
      expect(lines.length, 1);
      expect(lines.single, contains(r'a\nb'));
    });
  });

  group('FileLogSink 脱敏', () {
    test('写盘前过 redactSecrets（Bearer 令牌不落盘）', () {
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, 'Authorization: Bearer abc.def.ghi');
      final all = readLog();
      expect(all, isNot(contains('abc.def.ghi')));
      // 值被整体掩码（`authorization: ***`），键名保留以便看出「这里原是凭证」。
      expect(all.toLowerCase(), contains('authorization'));
      expect(all, contains('***'));
    });

    test('redact: false 时保留原文（仅用于测试与排障对照）', () {
      final sink = FileLogSink(path: path, redact: false);
      sink.write(LogLevel.info, 'Authorization: Bearer abc.def.ghi');
      expect(readLog(), contains('abc.def.ghi'));
    });
  });

  group('FileLogSink 轮转', () {
    test('超过上限时滚成 .1/.2，最旧的被丢弃', () {
      // 每条约 84 字节（时间戳 26 + 级别 7 + 消息 + 换行），maxBytes=200
      // 意味着每 2~3 条轮转一次；写 12 条必然转够两次（否则 .2 不会出现）。
      final sink = FileLogSink(path: path, maxBytes: 200, maxFiles: 2);

      for (var i = 0; i < 12; i++) {
        sink.write(LogLevel.info, '第 $i 条 ${'x' * 40}');
      }

      expect(File('$path.1').existsSync(), isTrue, reason: '应保留一份历史');
      expect(File('$path.2').existsSync(), isTrue, reason: '应保留两份历史');
      expect(
        File('$path.3').existsSync(),
        isFalse,
        reason: 'maxFiles=2 之外的不该出现（否则无界增长）',
      );
      // 最新一条一定在**当前**文件里——写反（滚到 .1 之后才写当前）会让
      // 用户拿到的最新日志缺失。
      expect(readLog(), contains('第 11 条'));
      // 最旧的一定已经不在了。
      expect(readLog(), isNot(contains('第 0 条')));
      expect(File('$path.1').readAsStringSync(), isNot(contains('第 0 条')));
    });

    test('maxFiles = 0 时不保留历史（清空当前文件）', () {
      final sink = FileLogSink(path: path, maxBytes: 200, maxFiles: 0);
      for (var i = 0; i < 5; i++) {
        sink.write(LogLevel.info, '第 $i 条 ${'y' * 40}');
      }
      expect(File('$path.1').existsSync(), isFalse);
      expect(File(path).lengthSync(), lessThan(200));
    });

    test('轮转后 size 归零（否则每写一条都会再轮转一次）', () {
      final sink = FileLogSink(path: path, maxBytes: 150, maxFiles: 1);
      for (var i = 0; i < 6; i++) {
        sink.write(LogLevel.info, '第 $i 条 ${'z' * 30}');
      }
      // 归零写错时 `_size` 只增不减，于是后面每条都轮转 → .1 里只剩一条。
      expect(File(path).lengthSync(), lessThan(150));
      expect(File('$path.1').lengthSync(), greaterThan(0));
    });

    test('已有文件超出上限时，下一次写入前先轮转', () {
      File(path).parent.createSync(recursive: true);
      File(path).writeAsStringSync('a' * 1000);

      final sink = FileLogSink(path: path, maxBytes: 500, maxFiles: 1);
      sink.write(LogLevel.info, '新的一条');

      expect(File('$path.1').existsSync(), isTrue);
      expect(readLog(), contains('新的一条'));
    });
  });

  group('FileLogSink 失败安全', () {
    test('目录不可创建时停用而**不抛**（日志是旁路，不能让启动失败）', () {
      // 用一个「父路径是文件」的位置：createSync 必然失败。
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('x');
      final sink = FileLogSink(path: '${blocker.path}/app.log');

      expect(sink.isDisabled, isTrue);
      expect(sink.lastError, isNotNull);
      // 停用后写入是空操作，不抛。
      expect(() => sink.write(LogLevel.info, 'x'), returnsNormally);
      expect(sink.writes, 0);
    });

    test('目录被删掉后写入失败 → 停用，不再重试刷屏', () {
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, 'ok');
      expect(sink.writes, 1);

      // 把目录换成文件，模拟「磁盘/权限在运行中变化」。
      Directory('${tmp.path}/logs').deleteSync(recursive: true);
      File('${tmp.path}/logs').writeAsStringSync('blocker');

      sink.write(LogLevel.info, 'fail');
      expect(sink.isDisabled, isTrue);
      expect(sink.writes, 1);

      // 已停用：后续写入静默跳过（不会每条都尝试并 print）。
      sink.write(LogLevel.info, 'again');
      expect(sink.writes, 1);
    });
  });

  group('MultiLogSink', () {
    test('扇出到每个 sink', () {
      final a = _RecordingSink();
      final b = _RecordingSink();
      MultiLogSink([a, b]).write(LogLevel.info, 'msg', {'k': 1});

      expect(a.messages, ['msg']);
      expect(b.messages, ['msg']);
      expect(a.fields.single['k'], 1);
    });

    test('一个 sink 抛异常不影响其它 sink，也不冒泡', () {
      final good = _RecordingSink();
      final sink = MultiLogSink([_ThrowingSink(), good]);

      expect(
        () => sink.write(LogLevel.error, 'msg', const {}),
        returnsNormally,
      );
      expect(good.messages, ['msg'], reason: '日志是旁路，不该因前一个 sink 失败');
    });
  });

  group('previousSessionExitedCleanly（会话标记）', () {
    test('无文件 → null（首次运行，不可判为异常）', () {
      expect(previousSessionExitedCleanly(path), isNull);
    });

    test('空文件 → null', () {
      File(path).parent.createSync(recursive: true);
      File(path).writeAsStringSync('');
      expect(previousSessionExitedCleanly(path), isNull);
    });

    test('末尾是退出标记 → true', () {
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, logSessionStartMessage);
      sink.write(LogLevel.info, logSessionCleanExitMessage);
      expect(previousSessionExitedCleanly(path), isTrue);
    });

    test('最近一次会话只有启动标记 → false（崩溃 / 被杀 / 掉电）', () {
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, logSessionStartMessage);
      sink.write(LogLevel.info, '按 Alt+Space 后卡住');
      expect(previousSessionExitedCleanly(path), isFalse);
    });

    test('退出标记之后还有收尾日志 → 仍为 true（收尾阶段的日志不算「未退出」）', () {
      // `quit()` 之后 `dispose()` 还会写日志，这是真实顺序。若判据是「最后
      // 一条必须是退出标记」，这里就会误报崩溃——而误报会永远出现。
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, logSessionStartMessage);
      sink.write(LogLevel.info, logSessionCleanExitMessage);
      sink.write(LogLevel.info, '桌面能力已释放');
      expect(previousSessionExitedCleanly(path), isTrue);
    });

    test('一次崩溃 + 一次正常退出 → true（崩溃不会被级联误报）', () {
      final sink = FileLogSink(path: path);
      // 会话 1：崩溃（无退出标记）
      sink.write(LogLevel.info, logSessionStartMessage);
      sink.write(LogLevel.info, '卡住');
      // 会话 2：正常退出，但收尾之后还有日志
      sink.write(LogLevel.info, logSessionStartMessage);
      sink.write(LogLevel.info, '上次会话未正常退出（无退出标记）');
      sink.write(LogLevel.info, logSessionCleanExitMessage);
      sink.write(LogLevel.info, '桌面能力已释放');
      expect(previousSessionExitedCleanly(path), isTrue);
    });

    test('退出标记之后又开了一个新会话 → false（那一段才是「上次」）', () {
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, logSessionCleanExitMessage);
      sink.write(LogLevel.info, logSessionStartMessage);
      sink.write(LogLevel.info, '新会话跑着跑着没了');
      expect(previousSessionExitedCleanly(path), isFalse);
    });

    test('标记之前的老日志不影响判断（无标记 → null）', () {
      final sink = FileLogSink(path: path);
      sink.write(LogLevel.info, '旧版本留下的日志，没有会话标记');
      expect(previousSessionExitedCleanly(path), isNull);
    });

    test('只看末尾 tailBytes：大文件不会整读，标记仍在末尾时判 true', () {
      File(path).parent.createSync(recursive: true);
      // 前面塞 64 KB 噪声，标记在最后。
      File(path).writeAsStringSync('${'x' * 65536}\n');
      FileLogSink(path: path).write(LogLevel.info, logSessionCleanExitMessage);
      expect(previousSessionExitedCleanly(path, tailBytes: 4096), isTrue);
    });

    test('tailBytes 切在中文多字节字符中间时不抛（allowMalformed）', () {
      final sink = FileLogSink(path: path);
      // 「会话」是 3 字节字符，制造一个会被截断的尾部窗口。
      sink.write(LogLevel.info, '会话会话会话');
      expect(
        () => previousSessionExitedCleanly(path, tailBytes: 5),
        returnsNormally,
      );
    });

    test('截断的最后一行（进程写在半行上死掉）→ 按上一行判定，不抛', () {
      File(path).parent.createSync(recursive: true);
      // 崩溃发生在写某条日志的中途：尾部是半行，且没有退出标记。
      File(path).writeAsStringSync(
        '2026-11-04T10:00:00 INFO  $logSessionStartMessage\n'
        '2026-11-04T10:00:01 INFO  会话结束（正常退',
      );
      expect(previousSessionExitedCleanly(path), isFalse);
    });

    test('路径不可读（是目录）→ null，不抛', () {
      expect(previousSessionExitedCleanly(tmp.path), isNull);
    });
  });

  group('defaultLogFilePath', () {
    test('Linux：XDG_DATA_HOME 优先', () {
      expect(
        defaultLogFilePath(
          environment: {'XDG_DATA_HOME': '/xdg', 'HOME': '/home/u'},
          isWindows: false,
        ),
        '/xdg/super_partyb/logs/app.log',
      );
    });

    test('Linux：无 XDG_DATA_HOME 时用 ~/.local/share', () {
      expect(
        defaultLogFilePath(environment: {'HOME': '/home/u'}, isWindows: false),
        '/home/u/.local/share/super_partyb/logs/app.log',
      );
    });

    test('Windows：APPDATA 优先，退回 USERPROFILE/AppData/Roaming', () {
      expect(
        defaultLogFilePath(
          environment: {'APPDATA': r'C:\Users\me\AppData\Roaming'},
          isWindows: true,
        ),
        r'C:\Users\me\AppData\Roaming/super_partyb/logs/app.log',
      );
      expect(
        defaultLogFilePath(
          environment: {'USERPROFILE': r'C:\Users\me'},
          isWindows: true,
        ),
        r'C:\Users\me/AppData/Roaming/super_partyb/logs/app.log',
      );
    });

    test('SPB_LOG_DIR 覆盖目录（便携部署 / 测试）', () {
      expect(
        defaultLogFilePath(
          environment: {'SPB_LOG_DIR': '/tmp/override', 'HOME': '/home/u'},
          isWindows: false,
        ),
        '/tmp/override/app.log',
      );
    });

    test('空白的覆盖值不算覆盖（防止 SPB_LOG_DIR= 变成相对路径）', () {
      expect(
        defaultLogFilePath(
          environment: {'SPB_LOG_DIR': '   ', 'HOME': '/home/u'},
          isWindows: false,
        ),
        '/home/u/.local/share/super_partyb/logs/app.log',
      );
    });

    test('无 HOME / APPDATA → null（调用方只用控制台 sink）', () {
      expect(
        defaultLogFilePath(environment: const {}, isWindows: false),
        isNull,
      );
      expect(
        defaultLogFilePath(environment: const {}, isWindows: true),
        isNull,
      );
    });
  });
}

class _RecordingSink implements LogSink {
  final messages = <String>[];
  final fields = <Map<String, Object?>>[];

  @override
  void write(LogLevel level, String message, Map<String, Object?> fields) {
    messages.add(message);
    this.fields.add(fields);
  }
}

class _ThrowingSink implements LogSink {
  @override
  void write(LogLevel level, String message, Map<String, Object?> fields) {
    throw StateError('boom');
  }
}
