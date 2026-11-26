import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';

/// 铸「媒体签名 URL」：视频且体积超阈值时优先要 `compact`（压缩版），
/// 拿不到就回落 `original`。
///
/// ## 为什么要回落而不是报错
///
/// UFS 的 `compact` 只在「变体服务已启用 + 该 MIME 有变体来源」时可用：
/// 未启用 / 音频 / 文档 → **415**，源文件超出转码上限 → **413**，ffmpeg 失败
/// → 415（见 UFS #16）。这些都是「这条**优化**不适用」，不是「预览失败」——
/// 按票里的回落语义（`docs/api-contract.md` §6.110）改拉原片，用户不该看到
/// 报错。回落也失败时才把错误抛给上层（走既有的旧预览页兜底）。
///
/// ## 为什么判据在 domain 而调用在 features
///
/// 「多大算大」是领域规则（[shouldPreferCompactVideo]，含与小程序对齐的阈值），
/// 而「两次调用 + 一次回落」是装配动作。放进 features 是为了让 desktop 与
/// mobile 两个 router 共用同一份实现——两端各抄一遍必然漂移，而症状只是
/// 「一边走压缩一边不走」。
Future<UfsMediaAccess> createPreviewMediaAccess(
  UfsApi ufs, {
  required String fileId,
  String? mimeType,
  required String fileName,
  int? sizeBytes,
}) async {
  final preferCompact = shouldPreferCompactVideo(
    mimeType: mimeType,
    fileName: fileName,
    sizeBytes: sizeBytes,
  );
  if (!preferCompact) return ufs.createMediaAccess(fileId);

  try {
    return await ufs.createMediaAccess(fileId, variant: 'compact');
  } on Object catch (e) {
    // 415/413/403/5xx/网络都走这里：压缩版是优化，不是依赖。
    SpbLog.info('compact 变体不可用，回落 original', {
      'file_id': fileId,
      'error': '$e',
    });
  }
  return ufs.createMediaAccess(fileId);
}
