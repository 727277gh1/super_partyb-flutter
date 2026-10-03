/// 功能模块：chat / works / settings / sync
///
/// ## 公共 API 出口
///
/// 本文件是本包唯一允许被外部 import 的入口，`lib/src/` 下的实现细节不对外暴露。
/// **漏 export 会让 app 无法 import**（编译器报「未找到该名称」）。
///
/// 当前导出：
///   auth          —— 登录页与认证状态（登录页不直接开浏览器，由 app 注入）
///   chat          —— 对话列表 / 时间线 / 输入框 / 各类 item 组件
///   habit         —— 习惯管理页（规则列表 / 执行历史 / 新建）
///   miniapp       —— 小程序工作台（工作列表 / 详情 / 产物下载 / 确认卡）
///   quickCapture  —— 悬浮输入窗（无归属入口，不接受 group_id）
///   settings      —— 设置页（同步目录/范围/过滤/清理，读写由 app 注入）
///   sync          —— 交付物同步页（目录选择/触发同步由 app 注入）
library;

export 'src/auth/auth.dart';
export 'src/chat/chat.dart';
export 'src/habit/habit.dart';
export 'src/miniapp/miniapp.dart';
export 'src/quick_capture/quick_capture.dart';
export 'src/settings/settings.dart';
export 'src/sync/sync.dart';
