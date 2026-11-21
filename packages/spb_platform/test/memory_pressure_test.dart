import 'package:flutter/painting.dart'
    show
        ImageInfo,
        ImageStreamListener,
        OneFrameImageStreamCompleter,
        imageCache;
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [installMemoryPressureHandler] 的行为测试（docs/memory-audit.md G9）。
///
/// 测试方式：直接调 `WidgetsBinding.instance.handleMemoryPressure()`——那是
/// 框架在收到 `SystemChannels.system` 的 `memoryPressure` 消息时走的**同一条**
/// 派发路径（`binding.dart` 的 `handleMemoryPressure` 遍历 observer 并调
/// `didHaveMemoryPressure`）。因此这里测到的是真实链路，不是自造的桩。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('installMemoryPressureHandler', () {
    test('收到压力时连带清空 live images 并回调 onRelease', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      // 前置必须把图放进缓存**且保持 live**（挂外部 listener）。否则
      // `currentSize == 0` / `liveImageCount == 0` 的断言恒真——清不清都绿
      // （§6.17 那类假绿；实测曾踩过：无 listener 的图在微任务后 live 自归零）。
      final completer = await _seedLiveImage();
      expect(imageCache.currentSize, 1, reason: '前置：条目真的进了缓存');
      expect(imageCache.liveImageCount, 1, reason: '前置：图仍处于 live 状态');
      var released = 0;

      final dispose = installMemoryPressureHandler(onRelease: () => released++);
      addTearDown(dispose);

      binding.handleMemoryPressure();

      expect(released, 1, reason: 'onRelease 必须被调用一次');
      expect(imageCache.currentSize, 0);
      // 这是本模块相对框架的真实增量：`RendererBinding.handleMemoryPressure`
      // 只调 `clear()`（不动 live images，实测清完后 live 仍为 1）；
      // `clearLiveImages()` 才把它降到 0。
      expect(imageCache.liveImageCount, 0, reason: 'live images 也应被释放');
      completer.maybeDispose();
    });

    test('多次压力信号每次都回调（幂等，不累积状态）', () {
      final binding = TestWidgetsFlutterBinding.instance;
      var released = 0;
      final dispose = installMemoryPressureHandler(onRelease: () => released++);
      addTearDown(dispose);

      binding.handleMemoryPressure();
      binding.handleMemoryPressure();

      expect(released, 2);
    });

    test('未注册 onRelease 时只清缓存，不抛', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final completer = await _seedLiveImage();
      expect(imageCache.currentSize, 1);

      final dispose = installMemoryPressureHandler();
      addTearDown(dispose);

      expect(() => binding.handleMemoryPressure(), returnsNormally);
      expect(imageCache.currentSize, 0);
      completer.maybeDispose();
    });

    test('解绑后不再回调（返回的 dispose 真的移除 observer）', () {
      final binding = TestWidgetsFlutterBinding.instance;
      var released = 0;
      final dispose = installMemoryPressureHandler(onRelease: () => released++);

      binding.handleMemoryPressure();
      expect(released, 1);

      dispose();
      binding.handleMemoryPressure();
      expect(released, 1, reason: '解绑后不应再收到压力信号');
    });
  });
}

/// 真的往全局 imageCache 放一条目**并保持 live**（挂一个外部 listener）。
///
/// 不可以用「只设上限」或「放完不挂 listener」冒充：
/// - 只设上限 → 缓存是空的，`currentSize == 0` 恒真；
/// - 不挂 listener → completer 完成后的微任务里 live 自行归零（缓存内部
///   listener 移除后 `_LiveImage` 自动释放），`liveImageCount == 0` 恒真。
/// 两种情形下清不清缓存用例都绿。
Future<OneFrameImageStreamCompleter> _seedLiveImage() async {
  final image = await createTestImage(width: 8, height: 8);
  final completer = OneFrameImageStreamCompleter(
    Future.value(ImageInfo(image: image)),
  );
  // 先挂外部 listener 再入缓存：保证 completer 完成时仍有外部持有者。
  completer.addListener(ImageStreamListener((_, _) {}, onError: (_, _) {}));
  imageCache.putIfAbsent('memory-pressure-test', () => completer);
  // completer 的回调在微任务里，先冲一轮再返回，否则 putIfAbsent 后的
  // currentSize 断言读到的是 pending 态（还没入缓存）。
  await Future<void>.delayed(Duration.zero);
  return completer;
}
