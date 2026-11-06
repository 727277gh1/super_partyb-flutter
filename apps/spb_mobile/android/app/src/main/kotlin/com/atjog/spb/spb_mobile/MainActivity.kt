package com.atjog.spb.spb_mobile

import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * 本机门禁（issue #94）要求 `FlutterFragmentActivity`，不是 `FlutterActivity`。
 *
 * `local_auth` 的 Android 实现用 androidx `BiometricFragment` 弹验证框，而该
 * Fragment 只有 `FragmentActivity` 才有 `FragmentManager`。用 `FlutterActivity`
 * 时的表现是**运行时**抛
 * `java.lang.ClassCastException: ... cannot be cast to FragmentActivity`
 * （插件文档里记为 `AUTHENTICATE_FAILED` / `uiUnavailable`），编译期没有任何
 * 提示——即「设置里能打开开关，但每次解锁都失败」。
 *
 * 行为差异（除 Fragment 支持外）：`FlutterFragmentActivity` 的窗口与
 * `FlutterActivity` 等价，官方模板对需要插件 Fragment 的应用默认用它。
 */
class MainActivity : FlutterFragmentActivity()
