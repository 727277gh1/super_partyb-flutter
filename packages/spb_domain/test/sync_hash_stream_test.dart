import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 内容摘要的三条通道必须给出**同一个**十六进制小写 SHA256。
///
/// ## 这个测试防的是什么
///
/// 脏检测的判据是「本地内容摘要 == 状态里记录的 [SyncedFile.contentHash]」。
/// 三条通道（[contentHashOf] / [contentHashOfAsync] / [contentHashOfStream]）
/// 中任何一条的算法或编码漂了，后果都不是报错，而是**整目录被判成「用户改动
/// 过」**——用户看到一屏自己没动过的文件，顺手确认回传就把 agent 的版本覆盖了。
///
/// 故这里逐条对**已知向量**断言，而不只是「两条通道互相相等」：后者在两处
/// 同时改错时仍然会绿。
void main() {
  /// SHA256("")。
  const emptySha =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// SHA256("abc")。
  const abcSha =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

  /// 把字节按 [size] 切块，模拟 `File.openRead()` 的块流。
  Stream<List<int>> chunked(List<int> bytes, {int size = 64}) async* {
    for (var i = 0; i < bytes.length; i += size) {
      final end = i + size < bytes.length ? i + size : bytes.length;
      yield bytes.sublist(i, end);
    }
  }

  group('contentHashOfStream', () {
    test('已知向量：空输入', () async {
      expect(
        await contentHashOfStream(const Stream<List<int>>.empty()),
        emptySha,
      );
    });

    test('已知向量："abc"', () async {
      expect(await contentHashOfStream(Stream.value('abc'.codeUnits)), abcSha);
    });

    test('与整份哈希逐字相等（跨多块）', () async {
      final bytes = List<int>.generate(200 * 1024, (i) => (i * 17 + 3) % 256);
      final whole = contentHashOf(bytes);
      final streamed = await contentHashOfStream(chunked(bytes));
      expect(streamed, whole);
      expect(streamed, hasLength(64), reason: '十六进制小写，64 字符');
      expect(streamed, streamed.toLowerCase());
    });

    test('块边界不影响结果（1 字节块 == 整份）', () async {
      final bytes = List<int>.generate(1000, (i) => i % 256);
      expect(
        await contentHashOfStream(chunked(bytes, size: 1)),
        contentHashOf(bytes),
      );
    });

    test('与 contentHashOfAsync 一致（同一基准，否则脏检测全误报）', () async {
      final bytes = List<int>.generate(9 * 1024, (i) => i % 251);
      expect(
        await contentHashOfStream(chunked(bytes)),
        await contentHashOfAsync(bytes),
      );
    });

    test('流中途抛错时向上抛（调用方记失败，不静默当成「未改动」）', () async {
      Stream<List<int>> failing() async* {
        yield [1, 2, 3];
        throw StateError('读取中断');
      }

      await expectLater(
        contentHashOfStream(failing()),
        throwsA(isA<StateError>()),
      );
    });
  });
}
