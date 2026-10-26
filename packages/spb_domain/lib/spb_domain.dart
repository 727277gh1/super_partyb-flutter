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
//   GroupCacheStore               —— 对话列表缓存契约（issue #26 切片 A；**可丢弃数据**，
//                                    读失败返回空列表、写失败不抛——与 SyncStateStore 相反）
//   TimelineCacheStore / isCacheableEvent —— 对话 timeline 只读缓存契约（切片 B / issue #29；
//                                    增量 upsert，只存落库事件）
//   OutboxStore / OutboxQueue / OutboxRetryPolicy —— 离线写队列（切片 C / issue #30；
//                                    **不是**可丢弃数据：读写失败抛 StorageError）
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
//   resolveLocalDeliverablePath 等  —— 已同步交付物 → 本地相对路径（打开/定位用，含布局校验）
//   effectiveCursor               —— 游标与 since_days 合并成 updated_since（纯函数）
//   SyncScopeConfig               —— 同步范围**持久化形态**（允许空列表）→ toScope()
//   SyncSettings / LocalSyncStats —— 设置页的表单聚合形态与本地统计
//   buildPrunePlan / isGroupId    —— 本地目录清理计划（纯逻辑，可预览）
//   buildArtifactTree / ArtifactNode —— 交付物清单 → 树（隐式目录、聚合、排序，纯逻辑）
//   GateDecision / GateDecisionKind / GateSourceKind —— Gate 决策（adaptive_decision / goal_gate_decision 归约输出，独立于时间线）
//   collectGateDecisions / gateDecisionFrom —— 事件流 → Gate 决策列表（纯函数）
//   TurnActivitySnapshot          —— 执行中活动快照（turn_activity 归约输出，空窗期进度指示）
//   ContextUsage / ContextCost    —— 上下文用量与费用（context_update 归约输出，诊断区展示）
//   ExecutionStatus / Kind        —— 执行等待/重试状态（queue_state / retry_scheduled 归约输出）
//   TtsStatus / TtsPhase          —— 语音播报状态（tts_started / tts_completed / tts_failed 归约输出）
//   GroupUpdate / GroupUpdateOp   —— group 变更通知（group_updated 归约输出，驱动列表实时刷新）
//   TurnGroup / groupItemsByTurn —— 对话项按 turn 分组（侧边栏待办/工具调用面板用，纯逻辑）
//   resolvePreviewKind / FilePreviewKind —— 文件预览类型判定（text/image/external，纯逻辑）
//   resolveTextPreview / TextPreviewPayload —— 内容层判定（map / spec 文档 or 原文，纯逻辑）
//   extractSpecSchemaFromUnknown          —— 从任意 JSON 深度下探提取 spec schema
//   MapSchema / parseMapSchema            —— map spec（*.map.spec.json）解析（顶层 type=map + markers/routes）
//   MapProjection                         —— 经纬度 → 视口像素的等比投影（纯数学，可无头单测）
//   MapMarker / MapRoute / amapMarkerUrl  —— map spec 的元素类型与高德跳转 URI
//   buildTextPreview / TextPreview     —— 文本预览裁剪（大文件截断 + 明确提示）
//   groupFileEventsForDisplay / FILE_BATCH_MIN_COUNT —— 时间线 → 展示行（同 turn 同秒批量聚合，纯逻辑）
//   TimelineDisplayRow / SingleItemRow / AgentFileBatchRow —— 展示行 sealed 家族（不改归约结果）
//   deliverableDownloadRelPath / agentFileDownloadRelPath —— 下载到本地的落地相对路径（{groupId}/<group 内相对路径>，两端同一口径）
export 'src/agent_file_batch.dart';
export 'src/artifact_tree.dart';
export 'src/chat_stream_controller.dart';
export 'src/confirmation_notifier.dart';
export 'src/notifications.dart';
export 'src/conversation_item.dart';
export 'src/conversation_search.dart';
export 'src/deliverable_sync.dart';
export 'src/deliverable_sync_usecase.dart';
export 'src/deliverable_upload.dart';
export 'src/deliverable_upload_adapters.dart';
export 'src/deliverable_upload_usecase.dart';
export 'src/event_reducer.dart';
export 'src/auto_sync_scheduler.dart';
export 'src/execution_status.dart';
export 'src/file_preview.dart';
export 'src/gate_decision.dart';
export 'src/goal_update.dart';
export 'src/group_cache.dart';
export 'src/group_sync_probe.dart';
export 'src/local_deliverable_path.dart';
export 'src/local_download_path.dart';
export 'src/map_schema.dart';
export 'src/quick_capture_enqueue_usecase.dart';
export 'src/quick_capture_usecase.dart';
export 'src/spec_ui.dart';
export 'src/sync_auto_config.dart';
export 'src/sync_cursor.dart';
export 'src/sync_path.dart';
export 'src/sync_prune.dart';
export 'src/outbox.dart';
export 'src/timeline_cache.dart';
export 'src/tts_audio_path.dart';
export 'src/tts_status.dart';
export 'src/turn_activity.dart';
export 'src/turn_detail.dart';
export 'src/turn_group.dart';
export 'src/sync_scope_config.dart';
export 'src/sync_settings.dart';
export 'src/sync_state.dart';
