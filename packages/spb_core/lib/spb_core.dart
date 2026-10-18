/// 基础设施：日志、错误类型、环境配置、平台无关工具。
///
/// **纯 Dart 包**：禁止 import `package:flutter/*`。原因见仓库 AGENTS.md
/// 「分层规则」——本包要能在无 Flutter 引擎的环境下被单测。
library;

export 'src/endpoints.dart';
export 'src/env.dart';
export 'src/errors.dart';
export 'src/logger.dart';
