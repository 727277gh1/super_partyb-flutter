# 交付物回传（本地改动 → agent 感知）最终方案

> 状态：设计定稿（纯客户端范围，Go API 零改动）
> 背景：交付物同步是单向的（UFS → 本地，见 `spb_features/lib/src/sync/sync_page.dart`
> 的「为什么同步是单向的」）。用户在本地目录修改文件后，agent 不知道、下轮同步
> 还会把本地改动静默覆盖掉——这是本方案要消除的两个困惑。
> 涉及的前序讨论结论都已在 `super_partyb` / `unified-file-service` 代码中核实，
> 引用处以 `文件:行` 标注。

---

## 0. 结论速览

| 问题 | 决策 |
|---|---|
| 本地改动的文件如何回到 agent？ | 客户端 `POST /chat/groups/:gid/workspace-sync/ufs-upload`（现成端点，一次调用同时落 UFS + workspace） |
| agent 怎么知道文件被人类改了？ | 上传成功后发一条聊天消息（复用 `POST /users/:uid/chat/messages`） |
| 脏检测的比对基准？ | 下载时记录的**本地内容 SHA256**（`SyncedFile.contentHash`）。UFS 的 etag 是 `W/"<file_id>:<updated_at_nano>"`（`unified-file-service/internal/model/model.go:158`），**与内容无关**，不能当作内容指纹用 |
| 上传撞上 agent 新版本怎么办？ | 客户端 etag 预检（数据在 `SyncState` 里现成有）；冲突时把两个版本物化到 workspace 的 `_conflict/`，开 turn 交 agent 裁决 |
| 文件超过服务端体积上限怎么办？ | 不做体积预判（拿不到服务端配置值），按 413 响应改走既有 quick-capture 附件链兜底，**不修改服务端配置** |
| 冲突谁赢？ | 固定规则：文本小冲突 agent 自动合并；二进制/大文件人类版本优先；高风险合并走 confirmation |
| 为什么不让 agent 直接持 UFS API key？ | key 是全用户命名空间权限（`ufs auth.go:145`），且被 `session_inject: false` 刻意排除（`credential_services.yaml:549`）；拒绝 |
| 为什么不反向同步器（客户端→UFS→workspace 自动同步）？ | 服务端无该方向（`pigo_executor.go:91` agent 只读 workspace 挂载目录），新建需改 Go API，且会产生归因错乱的事件回路；拒绝 |

---

## 1. 问题与目标

### 1.1 现状缺口

1. **感知缺口**：agent 在容器里唯一的文件视图是按原路径挂载的 workspace
   （`chatexec/pigo_executor.go:91`），没有 UFS 访问能力（pigo 执行器不注入
   UFS 凭证 env）。本地目录在客户端机器上，两条链路都看不见它。
2. **覆盖风险**：同步是「远端为准」，用户改动会在下一轮同步被远端版本覆盖，
   且无任何提示。

### 1.2 目标

- 用户改动可以**显式、可预期地**送达 agent；
- 冲突（agent 与人类先后改同一文件）**可追溯、有明确裁决规则**；
- 不改 Go API；不触碰 `agent.file.*` 的归因语义（最后写 workspace 的是
  服务端 ufs-upload 端点，事件链看到的与 webapp 上传无异）。

---

## 2. 核心链路：脏检测 → 上传 → 通知

```
本地目录（用户编辑）
   │ ①脏检测：本地内容 SHA256 vs SyncState 记录的 contentHash
   ▼
SyncPage「回传」入口（列出脏文件，用户逐个或批量确认）
   │ ②etag 预检：listFiles 取远端当前 etag vs SyncState 下载时 etag
   │    一致 → 直接上传
   │    不一致 → 冲突分支（见 §3）
   ▼
③POST /chat/groups/:gid/workspace-sync/ufs-upload（relative_path = 同步相对路径）
   │    服务端一次完成：UFS overwrite（新版本入 file_versions）
   │                  + os.WriteFile 写 workspace（sync_status=local_synced）
   │    413（超服务端上限）→ 改走 quick-capture 附件链兜底
   ▼
④发聊天消息：告诉 agent「我改了 reports/x.md，请基于新内容继续」
   │    （POST /users/:uid/chat/messages，GroupBinding 固定本 group）
   ▼
agent 在下一 turn 读到 workspace 新内容 → 后续产出照常经 groupsync → UFS
   ▼
⑤客户端下轮同步：etag 已变 → 拉回权威版本，本地脏标记清除
   （上传响应**不含 etag**，本层无法直接标记已同步，故收口只能靠这一轮）
```

### 2.1 各环节要点

**① 脏检测（新增，纯逻辑）**

- 比对基准是 `SyncState` 里每个 `SyncedFile` 的 **`contentHash`**——**下载时**对
  实际落盘字节计算的 SHA256。判定「本地动没动过」必须拿它比，不能拿 etag：
  UFS 的 `GenerateETag()` 是 `W/"<file_id>:<updated_at_unix_nano>"`
  （`unified-file-service/internal/model/model.go:158`），只随文件记录 ID 与时间
  变化，**与内容无关**，无法回答「本地这份是不是还是远端那一份」。
- 因此 `SyncedFile` 需要新增 `contentHash` 字段（nullable，向后兼容），并做
  drift schema `1 → 2` 迁移；`SyncEngine.run` 在 `sink.write` 成功后对**实际写入
  字节**计算 sha256 记入状态，304 未变更分支沿用旧值（内容未重下）。
- 旧状态记录没有 `contentHash`（升级前已同步的文件）：降级为「无法检测」，**不算
  脏**（宁可漏报也不误报）；这些文件在下次被重新下载后会获得 hash 并纳入检测。
- 与过滤规则共用 `SyncFilterConfig`：TTS 前缀、超限媒体本来就不在同步范围，
  它们的本地改动不产生「agent 应该知道」的预期，不进脏列表。
- 只遍历 `SyncState.files.keys`（与状态条目同阶），**不递归扫整个目录**（生产
  实测 5666 个文件）。
- 产出：`List<LocalDirtyFile>`（relPath、groupId、localSize）。放 `spb_domain`，
  无头单测。

**② etag 预检（新增，纯逻辑 + 一次 listFiles 调用）**

- `UfsApi.listFiles(pathPrefix: gid)` 取该路径当前 etag（清单里本就带 etag 字段），
  与 `SyncedFile.etag` 比对。
  > 这里用 etag 是**对的**：它回答的是「远端记录自上次同步后有没有被写过」
  > （`file_id` + `updated_at` 变化即说明写过），而不是「内容是不是同一份」。
  > 后者才是脏检测要回答的问题，故脏检测走 `contentHash`（见 ①）。
- 一致 → 自上次同步后无人动过远端，安全上传（服务端 overwrite 走
  `UploadNewVersion`，`unified-file-service/internal/service/file_version.go:90`，
  旧版本进 `file_versions`，内容不丢）。
- 不一致 → §3 冲突分支。
- 注意：PartyB 的 `ufs.Client` 上传不传 `If-Match`（`ufs/client.go:339` 只写
  conflict_strategy），所以 412 乐观锁保护**代理端拿不到**——预检必须在客户端做，
  且做成**正常流程分支**而非错误路径。

**③ 上传端点的既有约束**

- 端点：`POST /chat/groups/:group_id/workspace-sync/ufs-upload`
  （`super_partyb/apps/go-api/internal/server/workspace_sync.go:404`）。`/chat`
  前缀来自 `router.go:88` 的 `chatRG := r.Group("/chat")`，经 `chat_ext.go:102`
  注册；**漏掉 `/chat` 会 404**。
- 体积上限：`WorkbenchFileContextMaxBytes`（`internal/config/config.go:178`，env
  `WORKBENCH_FILE_CONTEXT_MAX_BYTES`，**代码默认 1048576 = 1 MiB**），超限返回
  **413**。客户端**不做体积预判**（它拿不到服务端实际生效值），而是按 413 响应
  把该文件改走 quick-capture 附件链（见 ④）；**不修改服务端配置**。
- 上传响应（`fileEntryToMap`，`workspace_sync.go:711`）**不含 etag**：客户端无法
  据此 `markSynced`。收口靠下一轮同步（远端 etag 已变 → 重新下载刚上传的内容
  覆盖本地 → 脏状态自然清除）。因此 UI 只能显示「**已回传**」，不能显示
  「已同步」。
- 路径黑名单：`isSystemExcluded` 会拒 `_attachments/**` 等系统路径（400）。
- 已知副作用（与 webapp 现行为一致，非新增风险）：服务端写 workspace 后
  groupsync 的 fsnotify 会再 emit 一条 `agent.file.modified`；内容相同 UFS 按
  SHA256 去重（上传很便宜），但事件照发，渲染推送/播报可能被触发。若实测
  骚扰明显，再考虑服务端抑制（属 Go API 演进，本方案不依赖它）。

**④ 通知消息**

- 为什么必须发：ufs-upload **不建 turn、不通知 agent**，文件只是静静落位。
  agent 只在 turn 里运行，没有消息就没有「知道」的时机。
- 内容模板：文件相对路径 + 一句话说明（用户可编辑）+ 明确指令
  （「请基于新版本继续，旧内容已过时」）。
- 与快速捕获（quick-capture enqueue）的关系：那是「无归属入口」，消息由
  分类链判组；本场景用户就在某个 group 的上下文里操作，走
  `POST /users/:uid/chat/messages` 带 `group_id` 固定归属
  （`chat_stream.go:145` 的 GroupFixed 语义），不绕分类链。
- 超上限文件的替代通道：ufs-upload 返回 **413** 时，改走 quick-capture 附件链
  （`/me/quick-capture/attachments` 单文件上限 50 MiB + `/me/quick-capture/enqueue`），
  服务端把附件落 workspace 的 `_attachments/{turnID}/` 并把路径拼进提示词。客户端
  API 已实现（`spb_api` 的 `uploadQuickCaptureAttachment` / `enqueueQuickCapture`），
  客户端侧只需在 enqueue 的 input 里写明「用户修改的 <原名>，目标路径 <relativePath>」，
  由 agent 落位到真实路径。此路径**不新增任何服务端依赖**。

---

## 3. 冲突处理

### 3.1 冲突的真实形态

- **窄窗口**：agent 写 workspace → groupsync 上传 UFS 只差 debounce 1.5s
  （`groupsync.go:78`）。人类改动撞上这个窗口的概率很低。
- **宽窗口（真实风险）**：agent 在人类编辑期间（下一 turn）重新生成同一文件。
  结果 = 最后写入者成为工作副本，但两个版本都在 UFS `file_versions` /
  PartyB `file_versions`（FileVersionProjector 物化，`domain.go:333`）可追溯。

### 3.2 处理流程（etag 预检不一致时）

1. 客户端下载远端（agent）版本到内存；
2. 把**人类版本**经 ufs-upload 写到目标 `relative_path`（工作副本 = 人类改动，
   落默认裁决「人类优先」，见 3.3）；
3. 把**agent 版本**用同一端点写到 `_conflict/<RFC3339时间戳>-<原名>.conflict`。
   选 `_conflict/` 目录的原因：不在 groupsync include globs（`.specs/*.md`、
   `reports/**`、`*.spec.json`、`*.html`、`*.pdf`，`groupsync.go:89`）→ 不被上传、
   不 emit 事件；但它在 workspace 里 → agent（容器挂载视图）能读。
   **`.conflict` 后缀是必需的**：include globs 含 `**/*.spec.json`、`**/*.html`、
   `**/*.pdf` 等**全目录**模式，若副本保持原名，`_conflict/<ts>-foo.spec.json`
   仍会命中白名单而被 groupsync 上传 UFS 并 emit `agent.file.*`（归因错乱，且可能
   触发 IM 推送）。统一加 `.conflict` 后缀后，原名里的扩展名不再位于末尾，
   从而不命中任何 include glob。
   > 注意：`_conflict/` 副本会长期留在 workspace 与 UFS（本期不做自动清理）。
4. 开 turn 交 agent 裁决（消息里给出：目标路径、人类版本路径、agent 版本
   `_conflict/` 路径、两侧 etag/时间、裁决规则）。agent 有文件工具，能读两份、
   合并、写回目标路径；写回后 groupsync 照常上传 UFS，客户端下轮同步收口。

### 3.3 裁决规则（固定，不让 agent 临场发挥）

| 情形 | 规则 |
|---|---|
| 文本类、双方改动小 | agent 自动合并，结果 + 理由发回对话 |
| 二进制 / 大文件 / 合并影响面大 | agent 给方案，走 `ChatConfirmation` 等人类确认 |
| 人类不想比对 | 默认**人类版本优先**，agent 只需把差异讲清楚（对比两份内容后总结） |

约束：
- 合并结果必须**显式落回对话**（message 或 confirmation），不允许静默改写——
  否则「我的改动没了」变成「agent 悄悄改了我的东西」，只是换了个方向。
- agent 只出**决策与文本**，不做 UFS 操作（见 §4）。
- LLM 合并非确定、有 token 成本，只用于小文本；10 MB 量级直接走人类优先。

---

## 4. 已否决的备选方案（记录理由，防止复议）

### 4.1 反向同步器（本地 → UFS → workspace 自动双向）

- 服务端不存在该方向的同步循环：groupsync 是单向 workspace → UFS
  （fsnotify 监听 + 上传 + emit，`groupsync.go:339`）；唯一的 UFS → workspace
  路径是逐文件手动端点（MQ 入站附件用）。新建反向同步器要改 Go API。
- 会产生写回路：反向写 workspace → fsnotify → groupsync 当普通 modify 再上传
  UFS + emit 事件；下游 `agentfilerender` 会把人类编辑渲染后推 IM（iLink 主动
  推送额度仅 10 条/24h）、`filesummary` 会播报成 agent 产出——归因全错。
- 事件系统有 `attribution_source` 字段（`groupsync/events.go:198`），将来若做
  「人类编辑」通道应走它，但那是 Go API 演进，本方案不依赖。

### 4.2 给 agent 发 UFS API key + 技能

- `credential_services.yaml:549` 的 `unified-file-service.api_key` 是
  `session_inject: false`，注释明确「只走服务间认证、不该暴露进 agent 子进程」；
  同文件 `super-partyb` 是 `session_inject: true` 的正面先例——管道现成，
  但开闸推翻的是刻意安全决策。
- UFS API key 认证以 `token.UserID` 构建完整身份（`ufs auth.go:145`），owner
  判定即完全控制：agent 获得的是**用户全部 UFS 命名空间**读写（含 /inbound/、
  其他 group 交付物），远超「处理本 group 冲突」所需。
- workspace 文件内容是不可信输入（可携带提示词注入指令），持 key agent 的
  爆炸半径从单 group 扩到全用户文件。
- 上传/比对 etag 是确定性操作，客户端代码做免费、可测试；agent 做则耗 token、
  不可复现。agent 只在 turn 里存活，与「上传瞬间做预检」的时机也不匹配。
- 允许的将来演进：只读、路径受限的 key 供 agent 合并时翻版本历史
  （`GET /api/files/{id}/versions` 现成）；或 PartyB 提供窄代理端点。

### 4.3 客户端直连 UFS 上传

- `ufs-upload` 端点注释已说明（`quick_capture_enqueue.go:231`）：UFS 上传只收
  `parent_id`（无 path-based 上传），客户端直连需自实现「逐级 mkdir + 409 回查」，
  且要自带 UFS 凭证。走 PartyB 代理则身份由网关注入、凭证由服务端解析，客户端
  零凭证。不采用。

---

## 5. 实现拆分（全部客户端，按依赖排序）

| # | 内容 | 包 | 测试 |
|---|---|---|---|
| 0 | `SyncedFile.contentHash` + drift schema `1 → 2` 迁移（脏检测的数据前提） | `spb_domain` / `spb_data` | 无头单测 + 内存库迁移用例 |
| 1 | 脏检测纯逻辑：`LocalDirtyFile` + 与 `SyncState.contentHash` 比对 | `spb_domain` | 无头单测（内存桩） |
| 2 | etag 预检纯逻辑：`UploadPrecheck`（一致/冲突/远端已删 三态） | `spb_domain` | 无头单测 |
| 3 | `ChatApi` 增加 `uploadWorkspaceFile`（multipart → ufs-upload 端点） | `spb_api` | Dio mock |
| 4 | 冲突物化用例：下载 agent 版本 → 双写（目标路径 + `_conflict/`） | `spb_domain` | 用例单测 |
| 5 | 回传编排：脏列表 → 预检 → 上传/冲突 → 通知消息 | `spb_domain` | 用例单测 |
| 6 | SyncPage 增加「回传改动」入口 + 进度/冲突 UI | `spb_features` | widget test |
| 7 | 冲突裁决消息模板 + confirmation 接入 | `spb_features`（chat） | widget test |

里程碑：先 1–3（打通「改动能上去」），再 4–7（打通「冲突有裁决」）。
1、2 是纯函数，先行落地无风险。

---

## 6. 用户体验原则

- 上传前**逐文件可见**：哪些会被覆盖、哪些有冲突，不搞「一键全传」黑箱。
- 冲突 UI 的默认按钮是规则推演的结果（人类优先），不是「取消」——用户点
  确认就一定有确定的结果。
- 413 / 400（黑名单路径）等服务端拒绝按「此文件无法回传 + 原因」呈现，
  不算同步失败。
- 通知消息默认可编辑，让用户自己补充上下文（agent 合并质量高度依赖它）。
