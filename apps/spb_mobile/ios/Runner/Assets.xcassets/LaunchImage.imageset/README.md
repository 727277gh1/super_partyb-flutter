# LaunchImage

启动画面中央的品牌标志（super_partyb 的 logo）。

- 尺寸：1x=96pt、2x=192pt、3x=288pt，铺满各自画布（正方形）。
- 背景色由 `LaunchScreen.storyboard` 提供，**不是**这里的图片：图片只放标志
  本身，铺满画布是为了让 storyboard 的 `contentMode="center"` 不缩放。

⚠️ 这是 Flutter 模板遗留的 `LaunchImage` 机制（storyboard 里引用该 imageset）。
不要换成 `flutter_native_splash` 之类的生成器：那会重写 `LaunchScreen.storyboard`，
而该文件同时承载了 OIDC 回调的窗口配置（见 `docs/mobile-oidc-deeplink.md`）。
