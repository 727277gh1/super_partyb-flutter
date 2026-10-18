/// 小程序工作台（miniapp BFF）功能模块。
///
/// ## 这一层做什么
///
/// 消费 `spb_api` 的 [MiniappApi] 与 `spb_models` 的 miniapp 契约，渲染
/// **工作列表**与**工作详情**（进度 / 步骤 / 确认卡 / 产物下载 / 事件）。
///
/// ## 页面不碰网络与文件系统
///
/// 与 `sync` / `settings` / `chat` 同一模式：所有副作用依赖注入
/// （`loadWorks` / `downloadArtifact` / `saveArtifact` / ...）。这样：
///
/// 1. widget test 无需 HTTP mock 或平台插件即可覆盖全部分支；
/// 2. `spb_features` 不为「下载产物」引入 `path_provider` / `file_picker`
///    之类的平台依赖（那些只在 app 装配层出现）。
///
/// ## 实时更新复用 SSE，不引入长连接推送
///
/// 服务端另有 `/ws` + `/ws-tickets`（`miniapp_ws.go`），本仓库**不封装**
/// （AGENTS.md §6.1：会造成两套事件推送链路）。故本模块是「加载 + 手动/下拉
/// 刷新」模型；实时性由 app 层既有的 SSE 接线提供。
///
/// ## `work` 就是 `chat_groups` 行
///
/// 服务端没有独立的 works 表，`work.id` 即 group id。故详情页拿到的 id 可以直接
/// 用于跳回对话流（若将来需要）。
library;

export 'work_detail_page.dart';
export 'works_page.dart';
