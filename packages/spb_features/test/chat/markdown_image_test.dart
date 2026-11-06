import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/custom_error_image.dart'
    show CustomImageError;

import 'package:spb_features/spb_features.dart';
import 'package:spb_platform/spb_platform.dart'
    show kImageDecodeCeilingLogicalWidth;

/// Markdown 内联图片的解码降采样（docs/memory-audit.md G10）。
///
/// ## 这个测试防的是什么
///
/// 接管 `GptMarkdown.imageBuilder` 是**替换整个图片 widget**，不是只换
/// provider。写错的方式都是静默的：
///
/// - 忘了 `ResizeImage`/`cacheWidth` → 等于没修（原图分辨率解码 ≈ 48MB/张，
///   而它在气泡里最多 1024dp 宽）。**这是本组的主断言**；
/// - 忘了尺寸盒子（`SizedBox(width, height)`）→ Markdown alt 里的 `=宽x高`
///   失效，图片按原始尺寸铺开；
/// - `data:` URL 的字节缓存丢了/无界 → 流式回复里每帧重解码并闪一下（插件
///   原本有一份 32 条/32MB 的私有缓存，接管 builder 就等于接管了它）；
/// - 非法 `data:` 让异常冒出去 → 一条坏图拖垮整条回复的渲染。
///
/// 反向验证：把 `markdownImageBuilder` 里的 `ResizeImage` 换回裸 provider，
/// 本文件前两个用例立刻红。
void main() {
  setUp(clearDataUrlImageMemo);

  /// 在真实 context 下构造一次 builder（不需要 GptMarkdown 解析）。
  ///
  /// 同时返回**整个** builder 产物（`root`）与其中的 `Image`：前者用于断言
  /// 尺寸盒子，后者用于断言 provider 链。
  Future<({Widget root, Image? image})> buildImage(
    WidgetTester t, {
    required String url,
    double? width,
    double? height,
    double dpr = 3.0,
  }) async {
    // 与真机一致：解码宽 = 逻辑宽 × 设备像素比。
    t.view.devicePixelRatio = dpr;
    addTearDown(t.view.resetDevicePixelRatio);

    Widget? root;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              root = markdownImageBuilder(context, url, width, height);
              return root!;
            },
          ),
        ),
      ),
    );
    await t.pump();
    final found = find.byType(Image);
    return (
      root: root!,
      image: found.evaluate().isEmpty ? null : t.widget<Image>(found),
    );
  }

  /// 取 provider 链底层的 URL（`ResizeImage → NetworkImage`）。
  String? networkUrlOf(ImageProvider<Object> provider) => switch (provider) {
    ResizeImage(:final imageProvider) => switch (imageProvider) {
      NetworkImage(:final url) => url,
      _ => null,
    },
    NetworkImage(:final url) => url,
    _ => null,
  };

  /// 取 provider 链底层的字节（`ResizeImage → MemoryImage`）。
  List<int>? bytesOf(ImageProvider<Object> provider) => switch (provider) {
    ResizeImage(:final imageProvider) => switch (imageProvider) {
      MemoryImage(:final bytes) => bytes,
      _ => null,
    },
    MemoryImage(:final bytes) => bytes,
    _ => null,
  };

  group('网络图', () {
    testWidgets('按显示尺寸限制解码宽（ResizeImage + 不放大）', (t) async {
      final built = await buildImage(t, url: 'https://example.com/a.png');

      final provider = built.image!.image;
      expect(
        provider,
        isA<ResizeImage>(),
        reason: '不传 cacheWidth 时插件用裸 NetworkImage：按原图分辨率解码进 imageCache',
      );
      final resize = provider as ResizeImage;
      // 未声明宽 → 退到视口宽（测试默认 800dp），× DPR 3.0 = 2400。
      expect(resize.width, 2400);
      expect(
        resize.allowUpscaling,
        isFalse,
        reason: '小原图不该被拉到上限（放大不省内存，只是白解码）',
      );
      expect(networkUrlOf(provider), 'https://example.com/a.png');
    });

    testWidgets('Markdown 声明了 `=宽x高` 时用声明的宽做上限，并保留尺寸盒子', (t) async {
      final built = await buildImage(
        t,
        url: 'https://example.com/a.png',
        width: 200,
        height: 100,
      );

      expect(
        (built.image!.image as ResizeImage).width,
        600,
        reason: '200dp × DPR 3.0',
      );
      // 尺寸盒子仍在：alt 里的逻辑尺寸是紧约束（插件默认行为）。
      final box = built.root;
      expect(box, isA<SizedBox>(), reason: '整个产物是尺寸盒子，不是裸 Image');
      expect((box as SizedBox).width, 200);
      expect(box.height, 100);
    });

    testWidgets('声明宽超过基准上限时封顶 1024dp（与预览图同一取舍）', (t) async {
      final built = await buildImage(
        t,
        url: 'https://example.com/a.png',
        width: 4000,
      );

      expect(
        (built.image!.image as ResizeImage).width,
        (kImageDecodeCeilingLogicalWidth * 3).round(),
        reason: '4000dp 的图在气泡里仍被视口约束，按 4000dp 解码纯属浪费',
      );
    });

    testWidgets('窄窗口下按窗口宽解码（图片不会比窗口更宽）', (t) async {
      t.view.physicalSize = const Size(400 * 3, 600 * 3);
      addTearDown(t.view.resetPhysicalSize);

      final built = await buildImage(t, url: 'https://example.com/a.png');

      expect(
        (built.image!.image as ResizeImage).width,
        1200,
        reason: '400dp × DPR 3.0',
      );
    });
  });

  group('data: URL', () {
    // 任意合法 base64 即可：本组断言的是**字节实例**与解码宽，不依赖解码成功
    //（单帧 pump 不会完成解码，故也不会有解码错误冒出来）。
    const dataUrl =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

    testWidgets('走 MemoryImage 且同样受限解码宽', (t) async {
      final built = await buildImage(t, url: dataUrl, width: 100);

      final image = built.image!;
      expect(image.image, isA<ResizeImage>());
      expect((image.image as ResizeImage).width, 300);
      expect(bytesOf(image.image), isNotNull, reason: '底应是 MemoryImage');
    });

    testWidgets('同一条 URL 跨重建复用同一份字节（流式回复不逐帧重解码）', (t) async {
      // `MemoryImage` 的相等性是字节列表**同一性**，故每帧重新 base64Decode
      // 会得到全新 provider：缓存永不命中、并闪一下。
      final first = await buildImage(t, url: dataUrl, width: 100);
      final firstBytes = bytesOf(first.image!.image);

      final second = await buildImage(t, url: dataUrl, width: 100);
      final secondBytes = bytesOf(second.image!.image);

      expect(firstBytes, isNotNull);
      expect(
        identical(firstBytes, secondBytes),
        isTrue,
        reason: '插件原本有一份私有字节缓存，接管 builder 后必须补上等价物',
      );
    });

    testWidgets('不同 URL 各自一份字节（不会串图）', (t) async {
      final a = await buildImage(t, url: dataUrl, width: 100);
      final b = await buildImage(
        t,
        url: 'data:image/png;base64,AAAA',
        width: 100,
      );

      expect(
        identical(bytesOf(a.image!.image), bytesOf(b.image!.image)),
        isFalse,
      );
    });

    testWidgets('缓存有界：超过条数上限后最旧的被淘汰（重新解码）', (t) async {
      // 32 条上限（与插件原实现同级）。这里逐条塞满再回看第一条：
      // 若被淘汰，拿到的字节实例就不可能是最初那份。
      final first = await buildImage(
        t,
        url: 'data:image/png;base64,AAAA',
        width: 10,
      );
      final firstBytes = bytesOf(first.image!.image);

      for (var i = 0; i < kDataUrlMemoMaxEntries; i++) {
        // 合法且互不相同的 4 字符 base64 payload（字母表里取 32 个字符；
        // 不能用 `fromCharCode(65+i)`：i ≥ 26 时会跑到 base64 字母表外，
        // 解码失败 → 不入缓存 → 淘汰根本没被触发，用例会假绿）。
        const alphabet =
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        await buildImage(
          t,
          url: 'data:image/png;base64,QUF${alphabet[i]}',
          width: 10,
        );
      }

      final again = await buildImage(
        t,
        url: 'data:image/png;base64,AAAA',
        width: 10,
      );
      expect(
        identical(bytesOf(again.image!.image), firstBytes),
        isFalse,
        reason: '无界缓存就是一条随会话增长的泄漏（memory-audit 的 A 类判据）',
      );
    });

    testWidgets('非法 base64 → 错误占位，不是抛异常也不是空白', (t) async {
      final built = await buildImage(
        t,
        url: 'data:image/png;base64,@@@not-base64@@@',
      );

      expect(built.image, isNull, reason: '解不出来就不该构造 Image（会拿空字节去解码）');
      expect(find.byType(CustomImageError), findsOneWidget);
    });

    testWidgets('空 payload 同样退化为错误占位', (t) async {
      final built = await buildImage(t, url: 'data:image/png;base64,');

      expect(built.image, isNull);
      expect(find.byType(CustomImageError), findsOneWidget);
    });
  });

  group('接线：AssistantMessageBubble 的 Markdown 图片真的走了这个 builder', () {
    testWidgets('正文里的图片被 ResizeImage 包裹（不是插件的裸 provider）', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            // 可滚动：气泡里的图片按内在高度撑开，固定 600dp 高度会 RenderFlex
            // 溢出（那是测试容器的限制，不是组件行为）。
            body: SingleChildScrollView(
              child: AssistantMessageBubble(
                text: '看图：![截图](https://example.com/shot.png)',
              ),
            ),
          ),
        ),
      );
      await t.pump();

      final image = t.widget<Image>(find.byType(Image));
      expect(
        image.image,
        isA<ResizeImage>(),
        reason: '漏传 imageBuilder 时这里是裸 NetworkImage——G10 会静默回退',
      );
      expect(networkUrlOf(image.image), 'https://example.com/shot.png');
    });
  });
}
