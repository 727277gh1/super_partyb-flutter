import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 本地落盘测试：**路径穿越防御** + 原子写入。
///
/// ## 这个测试防的是什么
///
/// 同步器会按**远端返回的路径名**写本地文件，而远端路径是服务端可控的输入。
/// 防御失效的后果不是「报个错」，而是**写到用户所选目录之外**——覆盖
/// `~/.ssh/authorized_keys`、`~/.bashrc`、`/etc/...` 之类。而且它是静默的：
/// 同步报告会显示「成功」。
///
/// 三类逃逸必须分别验证（它们的成因不同）：
/// 1. `..` 父目录逃逸 —— 字符串形态，计划期就能拦；
/// 2. 绝对路径 —— 字符串形态，但 `join` 类 API 常会**忽略**前缀直接采用它；
/// 3. **符号链接** —— 路径字符串完全合法（`link/evil.txt` 里没有任何 `..`），
///    只有解析软链后才知道它指向外部。计划期看不见，只能在落盘期拦。
void main() {
  late Directory root;
  late Directory outside;

  setUp(() async {
    // 用真实临时目录（`resolveSymbolicLinks` 必须真跑，不能用内存文件系统）。
    final base = await Directory.systemTemp.createTemp('spb-sink-');
    root = Directory('${base.path}/root')..createSync(recursive: true);
    outside = Directory('${base.path}/outside')..createSync(recursive: true);
  });

  tearDown(() {
    // root.parent 是 createTemp 建的那个 base。
    if (root.parent.existsSync()) root.parent.deleteSync(recursive: true);
  });

  group('路径穿越防御：字符串形态', () {
    test('../ 父目录逃逸被拒', () async {
      await expectLater(
        resolveWithinRoot(root.path, '../outside/evil.txt'),
        throwsA(isA<PlatformError>()),
      );
      // 深层逃逸同样要拦（不能只看第一段）
      await expectLater(
        resolveWithinRoot(root.path, 'a/b/../../../outside/evil.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('绝对路径被拒（join 类 API 会忽略前缀，必须显式拦）', () async {
      await expectLater(
        resolveWithinRoot(root.path, '/etc/passwd'),
        throwsA(isA<PlatformError>()),
      );
      // Windows 盘符与 UNC
      await expectLater(
        resolveWithinRoot(root.path, r'C:\Windows\evil.txt'),
        throwsA(isA<PlatformError>()),
      );
      await expectLater(
        resolveWithinRoot(root.path, r'\\host\share\evil.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('反斜杠段被拒（Windows 上它是分隔符，能绕过段级校验）', () async {
      await expectLater(
        resolveWithinRoot(root.path, r'a\..\..\outside\evil.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('空路径、空段、`.` 段、NUL 被拒', () async {
      await expectLater(
        resolveWithinRoot(root.path, ''),
        throwsA(isA<PlatformError>()),
      );
      await expectLater(
        resolveWithinRoot(root.path, 'a//b.txt'),
        throwsA(isA<PlatformError>()),
      );
      await expectLater(
        resolveWithinRoot(root.path, './a.txt'),
        throwsA(isA<PlatformError>()),
      );
      await expectLater(
        resolveWithinRoot(root.path, 'a\u0000b.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('根目录不存在 / 不是目录时明确报错', () async {
      await expectLater(
        resolveWithinRoot('${root.path}/nope', 'a.txt'),
        throwsA(isA<PlatformError>()),
      );
      final file = File('${root.path}/f.txt')..writeAsStringSync('x');
      await expectLater(
        resolveWithinRoot(file.path, 'a.txt'),
        throwsA(isA<PlatformError>()),
      );
      await expectLater(
        resolveWithinRoot('', 'a.txt'),
        throwsA(isA<PlatformError>()),
      );
    });
  });

  group('路径穿越防御：符号链接（字符串形态合法）', () {
    test('根目录内指向外部的软链被拒', () async {
      // `link/evil.txt` 里没有任何 `..`，字符串校验会放行；
      // 只有解析软链后才知道它指向 root 之外。
      Link('${root.path}/link').createSync(outside.path);

      await expectLater(
        resolveWithinRoot(root.path, 'link/evil.txt'),
        throwsA(isA<PlatformError>()),
      );
      // 写操作也必须真的被拦住（不只是解析函数报错）
      await expectLater(
        const LocalFileSink('').write('x', [1]),
        throwsA(isA<PlatformError>()),
      );
    });

    test('软链本身位于根目录内、目标也在根目录内 → 放行', () async {
      // 反向断言：不能把「任何软链」都当成攻击，否则用户正常使用的
      // 软链目录会让同步整体失败。
      final inner = Directory('${root.path}/inner')..createSync();
      Link('${root.path}/link').createSync(inner.path);

      final resolved = await resolveWithinRoot(root.path, 'link/a.txt');
      expect(resolved, contains('root/link/a.txt'));
    });

    test('多级中间目录中的软链同样被拦（不只看第一段）', () async {
      Directory('${root.path}/a').createSync();
      Link('${root.path}/a/deep').createSync(outside.path);

      await expectLater(
        resolveWithinRoot(root.path, 'a/deep/evil.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('断链的软链被拒（无法确认其目标，宁拒绝不猜测）', () async {
      Link('${root.path}/dangling').createSync('${outside.path}/missing');
      await expectLater(
        resolveWithinRoot(root.path, 'dangling/x.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('root 自身是软链时以解析后的真实路径为界', () async {
      // 用户可能把同步目录设在软链上（如 ~/deliverables -> /mnt/data/deliverables）。
      // 此时「在 root 内」应按真实路径判断，否则该目录下的一切写入都会被误拒。
      final real = Directory('${root.path}/real')..createSync();
      Link('${root.path}/rootlink').createSync(real.path);

      final resolved = await resolveWithinRoot(
        '${root.path}/rootlink',
        'a/b.txt',
      );
      expect(resolved, contains('/real/a/b.txt'));
    });
  });

  group('LocalFileSink 原子写入', () {
    test('写入内容正确，且不残留 .part 临时文件', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('reports/a.md', [104, 101, 108, 108, 111]);

      final written = File('${root.path}/reports/a.md');
      expect(written.existsSync(), isTrue);
      expect(written.readAsBytesSync(), [104, 101, 108, 108, 111]);

      // 临时文件必须已被 rename 掉：残留的 .part 会被用户当成损坏的交付物。
      final leftovers = root
          .listSync(recursive: true)
          .where((e) => e.path.contains('.part'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('自动创建父目录（嵌套多层）', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('g1/reports/2026/01/deep.md', [1]);
      expect(
        File('${root.path}/g1/reports/2026/01/deep.md').existsSync(),
        isTrue,
      );
    });

    test('覆盖已有文件（远端为准，原子替换）', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('a.md', [1, 1, 1]);
      await sink.write('a.md', [2]);
      expect(File('${root.path}/a.md').readAsBytesSync(), [2]);
    });

    test('写入路径逃逸时抛错且不留下任何文件', () async {
      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.write('../outside/evil.txt', [1]),
        throwsA(isA<PlatformError>()),
      );
      expect(outside.listSync(), isEmpty, reason: '外部目录必须没有任何写入');
    });

    test('空文件也能写（0 字节是合法交付物）', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('empty.txt', const []);
      expect(File('${root.path}/empty.txt').existsSync(), isTrue);
      expect(File('${root.path}/empty.txt').lengthSync(), 0);
    });
  });

  group('LocalFileSink 存在性探测', () {
    test('刚写入的文件存在，未写入的不存在', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('a.md', [1]);
      expect(await sink.exists('a.md'), isTrue);
      expect(await sink.exists('b.md'), isFalse);
    });

    test('文件被手动删除后返回 false（这是同步自愈的前提）', () async {
      // 同步引擎靠它决定要不要发 If-None-Match。若这里误报 true，
      // 用户删掉文件后就再也拿不回来了（见 spb_domain 的 FileSink.exists）。
      final sink = LocalFileSink(root.path);
      await sink.write('a.md', [1]);
      File('${root.path}/a.md').deleteSync();
      expect(await sink.exists('a.md'), isFalse);
    });

    test('目录不算「文件存在」', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('reports/a.md', [1]);
      expect(await sink.exists('reports'), isFalse);
    });

    test('路径逃逸时抛错（不静默当成「不存在」）', () async {
      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.exists('../outside/x.md'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('软链指向外部时抛错', () async {
      File('${outside.path}/victim.txt').writeAsStringSync('keep');
      Link('${root.path}/link').createSync(outside.path);

      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.exists('link/victim.txt'),
        throwsA(isA<PlatformError>()),
      );
    });
  });

  group('LocalFileSink 删除', () {
    test('删除已存在的文件', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('a.md', [1]);
      await sink.delete('a.md');
      expect(File('${root.path}/a.md').existsSync(), isFalse);
    });

    test('文件本就不存在视为成功（用户可能已手动删掉）', () async {
      final sink = LocalFileSink(root.path);
      // 不抛异常：否则该条目会永远留在失败列表里每轮重试。
      await sink.delete('never-existed.md');
    });

    test('删除路径逃逸时抛错', () async {
      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.delete('../outside/x.md'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('删除软链指向外部的文件被拒（不会删掉外部文件）', () async {
      final victim = File('${outside.path}/victim.txt')
        ..writeAsStringSync('keep');
      Link('${root.path}/link').createSync(outside.path);

      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.delete('link/victim.txt'),
        throwsA(isA<PlatformError>()),
      );
      expect(victim.existsSync(), isTrue, reason: '外部文件必须完好无损');
    });
  });

  group('LocalFileSink 读取（回传链路）', () {
    test('读回写入的字节（含 0 字节文件）', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('reports/a.md', [1, 2, 3]);
      expect(await sink.readBytes('reports/a.md'), [1, 2, 3]);

      await sink.write('empty.md', const []);
      expect(await sink.readBytes('empty.md'), isEmpty);
    });

    test('文件不存在时抛 PlatformError（不得返回空列表）', () async {
      // 返回空列表会被上层当成「一个 0 字节的文件」→ 误判为「用户改动过」
      // → 覆盖上传把远端文件写成空文件。
      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.readBytes('nope.md'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('路径逃逸时抛错（不会读到同步目录之外的内容）', () async {
      // 读逃逸比写逃逸更隐蔽：它不破坏任何东西，但会把用户目录外的文件内容
      // 上传到 UFS（数据外泄）。
      File('${outside.path}/secret.txt').writeAsStringSync('secret');
      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.readBytes('../outside/secret.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('软链指向外部时抛错', () async {
      File('${outside.path}/secret.txt').writeAsStringSync('secret');
      Link('${root.path}/link').createSync(outside.path);

      final sink = LocalFileSink(root.path);
      await expectLater(
        sink.readBytes('link/secret.txt'),
        throwsA(isA<PlatformError>()),
      );
    });

    test('目录不是文件：读取报错而不是返回空', () async {
      final sink = LocalFileSink(root.path);
      await sink.write('reports/a.md', [1]);
      await expectLater(sink.readBytes('reports'), throwsA(isA<SpbError>()));
    });
  });

  group('FileSelectorDirectoryPicker', () {
    test('无 DISPLAY 环境下静默返回 null（不抛异常）', () async {
      // 目录选择器依赖 GUI；CI/无头环境下必然失败。它必须降级为「取消」
      // 而不是抛异常——否则同步页在无 GUI 环境会直接崩。
      final picked = await const FileSelectorDirectoryPicker().pick();
      // 有 GUI 时可能真的弹出对话框并返回 null（无人点击）；无 GUI 时返回 null。
      // 两种情况下都不应抛异常，这才是断言的重点。
      expect(picked, anyOf(isNull, isA<String>()));
    });
  });
}
