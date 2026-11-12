/// 本地文件读取抽象：脏检测与回传上传共用的磁盘只读视图。
///
/// ## 为什么独立成文件
///
/// 这个接口同时被**两个方向**消费：
///
/// - 上行（`deliverable_upload.dart` 的 `scanLocalDirtyFiles`）——stat 体积、
///   流式摘要、上传时读整份字节；
/// - 下行（`deliverable_sync.dart` 的 `_detectDirtyLocally`，issue #56）——
///   覆盖前算本地摘要判脏。
///
/// 它定义在 `deliverable_upload.dart` 里时，下行方向 import 它会形成
/// `deliverable_sync.dart → deliverable_upload.dart → deliverable_sync.dart`
/// 的循环 import。独立文件让两个方向都只依赖这个中立接口。
///
/// 实现在 `spb_platform`（`LocalFileSink` 同时实现本接口与 [FileSink]），
/// 测试用内存桩。
library;

/// 只读本地文件（相对同步目录）。
abstract interface class LocalFileReader {
  /// 读取 [relPath]（相对同步目录）的全部字节。
  ///
  /// 路径非法、文件不存在或读取失败时抛错。
  Future<List<int>> readBytes(String relPath);

  /// 只 stat：返回 [relPath] 的字节数，**不读内容**。
  ///
  /// 路径非法、文件不存在或读取失败时抛错（语义同 [readBytes]——抛错而不是
  /// 返回 0，否则 0 字节会被判成「内容变了」而触发覆盖上传）。
  Future<int> sizeOf(String relPath);

  /// 流式算出 [relPath] 的内容 SHA256（十六进制小写）。
  ///
  /// 实现必须**分块读取**（如 `File.openRead()` + `contentHashOfStream`），
  /// 不得先 `readBytes` 再哈希——那样又把整份文件驻留内存了。
  Future<String> contentDigestOf(String relPath);
}
