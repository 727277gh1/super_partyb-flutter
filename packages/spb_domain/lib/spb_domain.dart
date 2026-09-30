/// 领域逻辑：用例、状态机、仓储接口。
///
/// **纯 Dart 包**：禁止 import `package:flutter/*`。
/// 依赖方向：`spb_domain` → `spb_api` / `spb_models` / `spb_core`。
/// 反向依赖（api 依赖 domain）是禁止的。
library;

// 导出的领域类型（barrel 文件，便于检索与确认公共 API 面）：
//   ChatStreamController          —— SSE 连接 + 事件缓冲 + 归约后的对话项流
//   EventReducer                  —— 事件流 → List<ConversationItem> 归约器
//   ConversationItem              —— 可渲染项 sealed 家族（User/Assistant/Tool/…）
//   QuickCaptureUseCase           —— 无归属入口提交用例（走 ChatApi.quickCapture）
//   QuickCaptureOutcome           —— 提交结果 sealed 家族（Queued/FeedbackRecorded/Unknown）
//   QuickCaptureEnqueueUseCase    —— 带附件的无归属入口用例（上传→投递两步，走 MQ 渠道）
//   QuickCaptureAttachment        —— 待发送附件（字节 + 文件名，来源无关）
//   QuickCaptureEnqueueResult     —— 部分失败语义的提交结果（delivered/uploaded/failedUploads）
//   SyncStateStore                —— 交付物同步状态契约（key → 游标 + etag 记录）
//   SyncState / SyncedFile        —— 同步状态值类型（含 contentHash：脏检测的比对基准）
//   contentHashOf                 —— 内容 SHA256（下载时记录与回传前比对共用同一算法）
//   workspaceStateKey             —— 「全部/选中若干 group」共用的状态键
//   buildSyncPlan / SyncEngine    —— 交付物同步计划与执行（纯逻辑，可无头单测）
//   SyncScope 家族                —— 同步范围（单 group / workspace / 选中若干）
//   FileSink / FileDownloader     —— 落盘与下载抽象（实现由上层包提供）
//   LocalFileReader               —— 本地文件读取抽象（回传链路，实现在上层包）
//   uploadTargetFor / UploadTarget —— 本地相对路径 + 状态键 → 回传目标（含剥 {gid}/ 前缀）
//   scanLocalDirtyFiles           —— 脏检测（本地内容 SHA256 vs 记录 contentHash，纯逻辑）
//   LocalDirtyFile 等              —— 脏检测结果（脏/未变/无法检测/被过滤/读失败）
//   precheckUpload                —— etag 预检三态（clean/conflict/remoteDeleted，纯函数）
//   DeliverableUploadUseCase      —— 回传编排：脏列表 → 预检 → 上传/冲突物化 → 通知
//   UploadSender 等窄接口          —— 回传用例的依赖契约（UploadSender/QuickCaptureSender/UploadNotifier/RemoteWorkspace）
//   UploadReport / UploadItemResult —— 回传结果（每文件终态 + 摘要，供 UI 渲染）
//   buildConflictPath             —— 冲突副本路径 _conflict/<ts>-<原名>.conflict
//   ChatApiUploadSender 等适配器    —— 真实装配：ChatApi/UfsApi → 四个窄接口
//   DeliverableSyncUseCase        —— 同步编排：分页拉取 → 计划 → 执行 → 存状态
//   UfsFileDownloader             —— UfsApi → FileDownloader 适配（304 语义映射）
//   groupRelativePath 等           —— UFS 路径 → 本地相对路径（含穿越防御）
//   effectiveCursor               —— 游标与 since_days 合并成 updated_since（纯函数）
//   SyncScopeConfig               —— 同步范围**持久化形态**（允许空列表）→ toScope()
//   SyncSettings / LocalSyncStats —— 设置页的表单聚合形态与本地统计
//   buildPrunePlan / isGroupId    —— 本地目录清理计划（纯逻辑，可预览）
//   buildArtifactTree / ArtifactNode —— 交付物清单 → 树（隐式目录、聚合、排序，纯逻辑）
export 'src/artifact_tree.dart';
export 'src/chat_stream_controller.dart';
export 'src/conversation_item.dart';
export 'src/deliverable_sync.dart';
export 'src/deliverable_sync_usecase.dart';
export 'src/deliverable_upload.dart';
export 'src/deliverable_upload_adapters.dart';
export 'src/deliverable_upload_usecase.dart';
export 'src/event_reducer.dart';
export 'src/quick_capture_enqueue_usecase.dart';
export 'src/quick_capture_usecase.dart';
export 'src/sync_cursor.dart';
export 'src/sync_path.dart';
export 'src/sync_prune.dart';
export 'src/tts_audio_path.dart';
export 'src/sync_scope_config.dart';
export 'src/sync_settings.dart';
export 'src/sync_state.dart';
