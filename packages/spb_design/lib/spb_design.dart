/// 设计令牌：颜色、排版、间距、主题（无业务语义）。
///
/// WHY 独立成包：`spb_ui`（组件）与 `spb_features`（页面）都需要主题，
/// 若主题放在 `spb_ui` 里会造成「features 依赖 ui 只为拿颜色」的循环味道。
library;

export 'src/theme.dart';
export 'src/theme_mode.dart';
export 'src/tokens.dart';
