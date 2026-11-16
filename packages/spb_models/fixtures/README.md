# `fixtures/event-catalog.json` —— 事件契约目录（vendored）

**这份文件不是本仓库的资产，是服务端契约的副本。永远不要手工编辑它。**

## 真源与生成

```
super_partyb/apps/go-api/internal/chatbus/{catalog.go,delivery.go,actions.go}
        ↓  UPDATE_EVENT_CATALOG=1 go test ./internal/chatbus/ -run TestEventCatalogJSON
super_partyb/apps/go-api/docs/event-catalog.json       ← 真源（与 Go 改动同一 commit）
        ↓  bash tools/sync_event_catalog.sh
packages/spb_models/fixtures/event-catalog.json        ← 本文件（与本仓代码同一 commit）
```

内容：`schema_version`、7 值类别闭集（`categories`）、SSE 信封键闭集（`envelope`）、
每条 `(type, form)` 的 `persist/broadcast/retention/timeline/diagnostic/required/optional/
producer/consumers/actions`（`entries`），以及用户动作表（`actions`：
端点 / 提交字段 / 幂等键 / 回执事件）。

上一次同步基线（2026-11-16）：`entries=62`、`类型=60`、`timeline 类型=20`、
`动作=5`、`schema_version=1`。

## 更新流程（三仓联动，顺序不能颠倒）

```
① 服务端改目录（Go 侧 catalog/delivery/actions）
② 重生成 event-catalog.json，与 Go 改动同一个 commit
③ 本仓 bash tools/sync_event_catalog.sh
④ (cd packages/spb_models && dart test test/event_catalog_test.dart)   ← 会红在「本仓未接的新类型/新类别」
⑤ 修本仓代码（必要时补 renderer / 归约分支），fixture 与代码同一 commit
```

## 三条纪律

1. **fixture 与真源逐字节一致**（`tools/sync_event_catalog.sh` 直接 `cp`，不经任何改写）。
   `schema_version` 只在**结构变化**（改字段名、新增必填键）时 +1；**纯新增类型不变更
   schema**——所以「fixture 换了但 schema 没变」是**正常**，别当成漏改。
2. **不允许在本仓库手工编辑 fixture**：真源不在本仓库，改这份只会在下次同步时被覆盖，
   且会掩盖真正的问题（缺实现、归类错、或服务端本就该改）。
3. **不做运行时 / CI 拉取**：本仓 CI 跑在 GitHub Actions，到不了 `git.atjog.com`
   （AGENTS.md §8）。对拍只能读仓库内副本；跨仓一致性由本地脚本负责。

## 谁在读它

只有测试读（`packages/spb_models/test/event_catalog_test.dart`）。**生产代码不 import 它**：
- 它**不是** codegen 输入（本仓硬规则禁 `build_runner`，AGENTS.md §6.2）；
- 生产用的类型常量/分类是**手写**镜像（`lib/src/event_types.dart`、`lib/src/event_category.dart`），
  由上面那个测试与 fixture 对拍——这样「服务端改了 → 本仓测试红」而不是「代码被生成器改」。

## 不覆盖什么

- **payload 字段语义**：目录只声明 `required/optional` 的**键名**，不声明类型与含义。
  `error` 的 `code/message/detail` 分工见 `docs/api-contract.md` §5.4.2；
  `dispatch_stage` 的分阶段语义见 §5.4.1。
- **顺序保证**：目录声明的是「有哪些」，不是「按什么序到达」。
