import 'package:flutter/material.dart';

import 'package:spb_domain/spb_domain.dart';

/// `ErrorCodeIcon` token → `IconData` 的**唯一**映射。
///
/// ## 为什么映射放在这一层
///
/// `spb_domain` 是纯 Dart 包（禁止 import `package:flutter/*`，分层守卫 +
/// `dart test` 无引擎），故它只能给语义 token
/// （[ErrorCodeIcon.memory] / `.rateLimited` / …）。`IconData` 是 Flutter 类型，
/// 只能在 `spb_features` 落成具体图标。
///
/// ## 为什么按「类别」而不是「每个 code 一个图标」
///
/// 两档超时（`timeout_inactivity` / `timeout_hard`）对用户是同一件事的不同刻度，
/// 给它们不同图标只会让人以为「图标 = 错误名」，而用户并不记忆图标语义。图标只在
/// **类别**层面区分（内存 / 限流 / 服务端 / 时间 / 中断）才有一眼可辨的价值。
IconData errorCodeIcon(String? code) => switch (ErrorCodes.traits(code).icon) {
  ErrorCodeIcon.memory => Icons.memory,
  ErrorCodeIcon.rateLimited => Icons.speed,
  ErrorCodeIcon.server => Icons.cloud_off,
  ErrorCodeIcon.timeout => Icons.timer_off_outlined,
  ErrorCodeIcon.interrupted => Icons.link_off,
  ErrorCodeIcon.generic => Icons.error_outline,
};

/// 分类徽标（如「内存不足」）。未知 / 缺失 `code` 返回 null（见
/// [ErrorCodeTraits.label] 的 fail-open 判据）。
String? errorCodeLabel(String? code) => ErrorCodes.traits(code).label;
