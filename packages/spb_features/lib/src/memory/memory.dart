/// 记忆（memory）功能模块：用户记忆浏览 / 编辑 / 归档 / 恢复。
///
/// 与 `habit/habit.dart` 同一取向：页面只做**渲染与交互**，HTTP 调用与错误翻译
/// 归 app 装配层（回调注入）。这样 widget test 不需要 HTTP mock 就能验证
/// 「什么条件下可点、点到底传了什么」。
library;

export 'memory_page.dart';
