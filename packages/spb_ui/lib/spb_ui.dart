/// 通用组件库（无业务语义）
///
/// 公共 API 出口：本文件是本包唯一允许被外部 import 的入口，
/// `lib/src/` 下的实现细节不对外暴露。
///
/// ## 收录标准
///
/// 只放**在 `spb_features` 里出现过 ≥ 2 份重复**的无业务语义组件。单份使用的
/// 私有组件留在页面自己文件里——搬进公共库只是换个地方放，不是去重，反而让
/// 「谁在用这个组件」变得难以追查。
///
/// 当前收录：
///   errorBanner     —— 错误提示条（登录页 / 同步页各一份，仅测试 key 不同）
///   hintLine        —— 内联提示行 + 其数据对象 Hint（悬浮输入窗 / 快速提交页逐字节重复）
///   sectionTitle    —— 小节标题（设置页 / 工作详情页各一份，样式不同故可传参）
///   copyIconButton  —— 复制到剪贴板（用户气泡 / 助手气泡各一份）
///   emptyState      —— 空状态（对话页 / 对话列表页 / 搜索页各一份，样式互不相同）
///   errorState      —— 整页错误 + 重试（对话列表页 / 搜索页各一份，逐字段相同）
///   highlightedText —— 搜索命中高亮（搜索页 / 对话内搜索各一份，逐字段相同）
///
/// ## 与 `spb_design` 的分工
///
/// `spb_design` 是**令牌**（颜色/间距/圆角/时长，不含 Widget）；
/// `spb_ui` 是**组件**（由令牌拼装而成）。故本包依赖 `spb_design`，反之不然。
library;

export 'src/copy_icon_button.dart';
export 'src/empty_state.dart';
export 'src/error_banner.dart';
export 'src/error_state.dart';
export 'src/hint_line.dart';
export 'src/highlighted_text.dart';
export 'src/section_title.dart';
