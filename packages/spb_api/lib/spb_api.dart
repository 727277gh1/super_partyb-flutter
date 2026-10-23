/// HTTP 与 SSE 传输层（dio + 手写 SSE 解析）。
///
/// **纯 Dart 包**：禁止 import `package:flutter/*`。
///
/// 分层边界：本包只负责「把请求发出去、把字节流解析成对象」，
/// **不含任何业务规则**（如「哪个 group 该用哪个 agent」）。
/// 业务规则在 `spb_domain`。
library;

export 'src/agents_api.dart';
export 'src/auth_interceptor.dart';
export 'src/chat_api.dart';
export 'src/endpoint_health_interceptor.dart';
export 'src/goal_api.dart';
export 'src/habit_api.dart';
export 'src/http_client.dart';
export 'src/loopback_redirect_server.dart';
export 'src/miniapp_api.dart';
export 'src/oidc_callback.dart';
export 'src/oidc_client.dart';
export 'src/pending_auth_store.dart';
export 'src/sse_client.dart';
export 'src/session_credential.dart';
export 'src/token_store.dart';
export 'src/ufs_api.dart';
