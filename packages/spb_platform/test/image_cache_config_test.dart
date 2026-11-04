import 'dart:ui' show FlutterView;

import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [configureImageCache] / [imageDecodeCeilingFor] 的行为测试
/// （docs/memory-audit.md G4b）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('configureImageCache', () {
    test('默认值写入 imageCache.maximumSizeBytes', () {
      final returned = configureImageCache();
      expect(returned, kImageCacheMaxBytes, reason: '返回值应等于默认上限');
      expect(
        TestWidgetsFlutterBinding.instance.imageCache.maximumSizeBytes,
        kImageCacheMaxBytes,
      );
    });

    test('注入值覆盖默认值', () {
      const small = 1024;
      final returned = configureImageCache(limit: small);
      expect(returned, small);
      expect(
        TestWidgetsFlutterBinding.instance.imageCache.maximumSizeBytes,
        small,
      );
    });

    test('重复调用幂等（后者覆盖前者）', () {
      configureImageCache(limit: 4096);
      configureImageCache(limit: 8192);
      expect(
        TestWidgetsFlutterBinding.instance.imageCache.maximumSizeBytes,
        8192,
        reason: '重复调用不防重入也不叠加，后调者为准',
      );
      // 还原，避免影响其它测试文件的全局状态。
      addTearDown(() => configureImageCache());
    });
  });

  group('imageDecodeCeilingFor', () {
    test('逻辑宽 × DPR 向上取整', () {
      final view = _FakeFlutterView(2.0);
      expect(imageDecodeCeilingFor(displayLogicalWidth: 48, view: view), 96);
      // 48 × 2.5 = 120 精确；48 × 2.375（Redmond 常见缩放）= 114 → 取 114。
      expect(
        imageDecodeCeilingFor(
          displayLogicalWidth: 48,
          view: _FakeFlutterView(2.375),
        ),
        114,
      );
      expect(
        imageDecodeCeilingFor(
          displayLogicalWidth: 48.1,
          view: _FakeFlutterView(2.0),
        ),
        97,
        reason: '非整数积向上取整',
      );
    });

    test('view 为 null → 按 DPR 1.0 自退', () {
      expect(imageDecodeCeilingFor(displayLogicalWidth: 48), 48);
      expect(imageDecodeCeilingFor(displayLogicalWidth: 48.6), 49);
    });

    test('DPR 异常值（≤0 / NaN / 无穷）→ 按 1.0 处理', () {
      expect(
        imageDecodeCeilingFor(
          displayLogicalWidth: 48,
          view: _FakeFlutterView(0),
        ),
        48,
      );
      expect(
        imageDecodeCeilingFor(
          displayLogicalWidth: 48,
          view: _FakeFlutterView(-1.5),
        ),
        48,
      );
      expect(
        imageDecodeCeilingFor(
          displayLogicalWidth: 48,
          view: _FakeFlutterView(double.nan),
        ),
        48,
      );
      expect(
        imageDecodeCeilingFor(
          displayLogicalWidth: 48,
          view: _FakeFlutterView(double.infinity),
        ),
        48,
      );
    });

    test('结果至少为 1', () {
      expect(
        imageDecodeCeilingFor(
          displayLogicalWidth: 0.0001,
          view: _FakeFlutterView(0.5),
        ),
        1,
      );
      expect(imageDecodeCeilingFor(displayLogicalWidth: 0), 1);
    });
  });
}

/// 只实现测试用到的成员；FlutterView 是接口，测试环境无法构造真实实例。
class _FakeFlutterView implements FlutterView {
  _FakeFlutterView(this.devicePixelRatio);

  @override
  final double devicePixelRatio;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试桩只实现 devicePixelRatio');
}
