import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// `AgentFileItem.contentRevision`（覆盖写检测令牌）的口径测试。
///
/// ## 这个测试防的是什么
///
/// 令牌是「同一个 `ufsFileId` 下内容是否已变」的**唯一**判据（docs/memory-audit.md
/// G8 / issue #70）：对话页缩略图缓存与文件卡的重拉判据都用它。写错的两种方向
/// 都是静默的：
///
/// - 漏字段（如只取 `modifiedAt`）→ 某些覆盖写检测不到，缩略图继续显示旧图；
/// - 多取 `createdAt` → 归约时它锚定首次出现、覆盖写不变，看似无害，但会
///   让「同一文件的新建与后续事件」被判成不同版本，触发无意义的重拉。
void main() {
  final base = DateTime.utc(2026, 9, 14, 8);

  AgentFileItem file({
    String action = 'created',
    DateTime? createdAt,
    DateTime? modifiedAt,
    DateTime? deletedAt,
    int? sizeBytes = 1024,
    String? mimeType = 'image/png',
    String? ufsFileId = 'ufs_1',
  }) => AgentFileItem(
    id: 'grp_1/pic.png',
    createdAt: createdAt ?? base,
    relativePath: 'grp_1/pic.png',
    fileName: 'pic.png',
    displayName: 'pic.png',
    action: action,
    ufsFileId: ufsFileId,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    modifiedAt: modifiedAt,
    deletedAt: deletedAt,
  );

  test('同字段的两个实例令牌相等（record 结构比较）', () {
    expect(file().contentRevision, file().contentRevision);
  });

  test('modified 事件（新 modifiedAt）→ 令牌变化', () {
    final created = file();
    final modified = file(
      action: 'modified',
      modifiedAt: base.add(const Duration(seconds: 30)),
    );
    expect(modified.contentRevision, isNot(created.contentRevision));
  });

  test('仅 sizeBytes / mimeType 变化也能检出（同 id 覆盖写）', () {
    final original = file();
    expect(
      file(sizeBytes: 2048).contentRevision,
      isNot(original.contentRevision),
    );
    expect(
      file(mimeType: 'image/jpeg').contentRevision,
      isNot(original.contentRevision),
    );
  });

  test('deleted 事件 → 令牌变化（卡片要重走一遍，不再展示旧缩略图）', () {
    final original = file();
    final deleted = file(
      action: 'deleted',
      deletedAt: base.add(const Duration(minutes: 1)),
    );
    expect(deleted.contentRevision, isNot(original.contentRevision));
  });

  test('createdAt 不参与令牌（归约锚定首次出现，覆盖写不变）', () {
    expect(
      file(createdAt: base.add(const Duration(days: 3))).contentRevision,
      file().contentRevision,
      reason: '取了 createdAt 会把「同一条文件的时间锚点变化」误判成新版本',
    );
  });
}
