/// 认证功能模块：登录页与认证状态。
///
/// ## 分层职责
///
/// 本目录只做**渲染与状态表达**：登录页展示按钮与错误，[AuthState] 表达
/// 「未知 / 已登录 / 未登录」。
///
/// **不含**以下内容（各自归属明确）：
/// - 授权 URL 构造与 token 交换 → `spb_api`（`OidcClient`）；
/// - 凭证持久化 → `spb_data`（`SecureTokenStore`）；
/// - 刷新与 401 重放 → `spb_api`（`SessionManager` / `AuthInterceptor`）；
/// - 打开浏览器 / 接收回调 → app 装配层（各平台机制不同，见
///   `docs/oidc-verification.md` §2.3）。
library;

export 'auth_state.dart';
export 'login_page.dart';
