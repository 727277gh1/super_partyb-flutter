import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:flutter_test/flutter_test.dart';

/// `createPreviewMediaAccess`：视频走 compact、失败回落 original（UFS #16）。
///
/// ## 这个测试防的是什么
///
/// 回落逻辑写错的症状都很安静：
///
/// - 没有回落 → 用户在「变体服务没开 / 文件太大 / ffmpeg 挂了」的部署上
///   **完全打不开视频**（415/413 被当成预览失败，转去旧预览页）；
/// - 回落范围写窄（只 catch 某个错误类）→ 网络抖动也会让预览直接失败；
/// - 阈值判据写反 → 图片被送去要 compact（服务端 415 再回落，白跑一趟），
///   或者大视频永远拉原片（移动数据上多下几十 MB）。
class _FakeUfs extends UfsApi {
  // 所有方法都被覆写，Dio 不会真的发请求；baseUrl 指向不可达地址只是防御。
  _FakeUfs() : super(createDio(baseUrl: 'http://127.0.0.1:1'));

  /// 非 null 时 `variant: 'compact'` 抛该错误（模拟 415/413/5xx/网络）。
  Object? compactError;

  /// 非 null 时 `variant: 'original'` 抛该错误（模拟回落也失败）。
  Object? originalError;

  /// 每次调用的 variant，按顺序记录（断言「先 compact 再 original」）。
  final List<String> variants = [];

  @override
  Future<UfsMediaAccess> createMediaAccess(
    String fileId, {
    String variant = 'original',
    int? size,
  }) async {
    variants.add(variant);
    if (variant == 'compact' && compactError != null) throw compactError!;
    if (variant == 'original' && originalError != null) throw originalError!;
    return UfsMediaAccess(
      url: 'https://dever.atjog.com/ufs/media/s/$variant-$fileId',
      expiresAt: DateTime.utc(2026, 1, 1),
      variant: variant,
    );
  }
}

const _bigVideo = kCompactVideoMinBytes;

void main() {
  test('大视频：先要 compact，成功就不再拉原片', () async {
    final ufs = _FakeUfs();
    final route = await createPreviewMediaAccess(
      ufs,
      fileId: 'f1',
      mimeType: 'video/mp4',
      fileName: 'recording.mp4',
      sizeBytes: _bigVideo,
    );

    expect(route.variant, 'compact');
    expect(ufs.variants, ['compact']);
  });

  test('小视频 / 音频 / 图片 / PDF：直接 original，不试 compact', () async {
    final cases = [
      (mime: 'video/mp4', name: 'short.mp4', size: 1024),
      (mime: 'audio/mpeg', name: 'long.mp3', size: _bigVideo * 10),
      (mime: 'image/png', name: 'huge.png', size: _bigVideo * 10),
      (mime: 'application/pdf', name: 'doc.pdf', size: _bigVideo * 10),
    ];
    for (final c in cases) {
      final ufs = _FakeUfs();
      final route = await createPreviewMediaAccess(
        ufs,
        fileId: 'f2',
        mimeType: c.mime,
        fileName: c.name,
        sizeBytes: c.size,
      );
      expect(route.variant, 'original', reason: '${c.name} 不该试 compact');
      expect(ufs.variants, ['original'], reason: '${c.name} 只该请求一次');
    }
  });

  test('compact 415（变体服务未启用 / 类型无产物）→ 回落 original', () async {
    final ufs = _FakeUfs()..compactError = const HttpError(415, '该资源没有可用的压缩版本');
    final route = await createPreviewMediaAccess(
      ufs,
      fileId: 'f3',
      mimeType: 'video/mp4',
      fileName: 'recording.mp4',
      sizeBytes: _bigVideo,
    );

    expect(route.variant, 'original');
    expect(ufs.variants, ['compact', 'original'], reason: '先试压缩，再回落');
  });

  test('compact 413（源文件超限）→ 回落 original', () async {
    final ufs = _FakeUfs()..compactError = const HttpError(413, '源文件超出压缩上限');
    final route = await createPreviewMediaAccess(
      ufs,
      fileId: 'f4',
      mimeType: 'video/quicktime',
      fileName: 'huge.mov',
      sizeBytes: _bigVideo * 4,
    );

    expect(route.variant, 'original');
    expect(ufs.variants, ['compact', 'original']);
  });

  test('compact 网络错误 → 同样回落（压缩版是优化，不是依赖）', () async {
    final ufs = _FakeUfs()..compactError = const NetworkError('连接超时');
    final route = await createPreviewMediaAccess(
      ufs,
      fileId: 'f5',
      mimeType: 'video/webm',
      fileName: 'clip.webm',
      sizeBytes: _bigVideo,
    );

    expect(route.variant, 'original');
    expect(ufs.variants, ['compact', 'original']);
  });

  test('回落也失败时把错误抛给上层（交给旧预览页兜底）', () async {
    final ufs = _FakeUfs()
      ..compactError = const HttpError(415, 'no variant')
      ..originalError = const HttpError(403, '权限不足');

    await expectLater(
      createPreviewMediaAccess(
        ufs,
        fileId: 'f6',
        mimeType: 'video/mp4',
        fileName: 'recording.mp4',
        sizeBytes: _bigVideo,
      ),
      throwsA(isA<HttpError>()),
    );
  });
}
