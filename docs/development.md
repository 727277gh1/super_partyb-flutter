# 开发环境

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。本机工具链、已知环境限制，以及「无头验证能证明什么、不能证明什么」。

> 编号（`§6.x` / `§5.x` / `[§7](design-decisions/build-and-release.md)` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](design-decisions/README.md)。

---

## 9. 开发环境

### 本机（Debian 12, LXC 容器）

| 项 | 值 |
|---|---|
| Flutter | 3.47.5 stable（Dart 3.13.4） |
| 安装位置 | `~/.local/opt/flutter` |
| Android SDK | `~/.local/share/android-sdk`（build-tools 35/36、platforms 35/36、NDK r28c） |
| `~/.zshenv` | `PATH` / `PUB_CACHE` / `JAVA_HOME` / `ANDROID_HOME` |

```bash
export PATH="$HOME/.local/opt/flutter/bin:$HOME/.local/bin:$PATH"
export PUB_CACHE="$HOME/.local/share/pub-cache"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOME="$HOME/.local/share/android-sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

### 已知环境限制

| 限制 | 影响 | 说明 |
|---|---|---|
| **无 `/dev/kvm`** | Android 模拟器**不可用** | LXC 容器未透传。宿主 `kvm_amd` 已加载且 `nested=1`，CPU 有 `svm`——**只是设备节点缺失**。修复需在 PVE 宿主 LXC 配置加 `lxc.cgroup2.devices.allow: c 10:232 rwm` + `lxc.mount.entry`。**已决议不改宿主**（`super_partyb#30`）：回归验证走 CI（analyze + 逐包 test + APK 构建与验签），UI 交互走真机 |
| **无 `DISPLAY`** | GUI 交互**无法验证** | 可用 `xvfb-run` 验证「进程能启动、窗口能创建」，但**无法验证交互**（点击、拖拽、悬浮窗焦点） |
| 无 Windows/macOS | 无法出对应包 | 见 [§8](design-decisions/build-and-release.md) |

### 无头验证的边界

`xvfb-run` 下**渲染不稳定**（实测同一命令有时窗口创建成功，有时停在 10x10 占位窗）。**不要把「Xvfb 下窗口出现了」当作渲染正确的证据**。

可可靠验证的：
- ✅ `dart analyze` 无问题
- ✅ `flutter test` 通过
- ✅ `flutter build linux --release` 成功
- ✅ `ldd` 无缺失动态库
- ✅ 进程能启动并存活（`timeout 15 ./spb_desktop` 退出码 124 = 正常）
- ✅ Impeller 初始化（日志 `Using the Impeller rendering backend`）

**需真机/有桌面环境手测**：多窗口、托盘、`Alt+Space`、OIDC 登录回跳、交付物同步。

## 常用命令

以下命令从 workspace 根执行，纯 Dart 测试在对应包目录运行。§6.x 见 [设计决策索引](design-decisions/README.md)，分层与验证入口见 [项目规则](../AGENTS.md)。

```bash
# 依赖（workspace 根执行，所有包共享一份 lockfile；CI 用 --enforce-lockfile，
# 改依赖要把根 pubspec.lock 一起提交——否则构建不可复现）
flutter pub get
# 升级依赖只能走这一条（Dependabot 不管 pub：它的 lock 被 flutter_test 的
# 精确 pin 判死，见 §6.93）。先 `flutter upgrade` 到 FLUTTER_VERSION 再升级。
# 两个故意锁住的 major 及升级触发条件见 §6.101（别顺手升、也别当欠债）。
flutter pub upgrade

# 静态分析 / 格式化
dart analyze .
dart format .

# 全部仓库守卫（用途见 tools/README.md；改某个守卫时必跑它的 *_selftest.sh）
(set -e; for f in tools/check_*.sh; do bash "$f"; done)

# 测试
(cd apps/spb_desktop && flutter test)   # 桌面端
(cd apps/spb_mobile && flutter test)   # 移动端
dart test                             # 纯 Dart 包（spb_core/models/api/domain）
(cd packages/spb_data && flutter test)  # ⚠️ 依赖链含 Flutter，dart test 会报 dart:ui 不可用

# 覆盖率（逐包采集汇总，默认剔除生成代码；用法见 tools/coverage.sh 文件头）
bash tools/coverage.sh [包名] [--summary-only]

# golden 基线——更新前先确认 diff 是你有意改的！
(cd packages/spb_ui && flutter test --update-goldens test/golden_test.dart)
(cd packages/spb_features && flutter test --update-goldens test/chat/golden_test.dart)

# 构建
(cd apps/spb_desktop && flutter build linux --release)
(cd apps/spb_mobile && flutter build apk --release)

# Linux 分发包（必须：把非系统依赖库打进 bundle，见 §7）
bash tools/bundle_linux_deps.sh

# 代码生成（drift：spb_data 的 database.g.dart）
# ⚠️ 必须 cd 进包目录（根目录跑静默空转），跑完必须 format——见 tools/check_codegen.sh 文件头
(cd packages/spb_data && dart run build_runner build && dart format lib)
```

### Melos（可选）

`melos run analyze|layering|gen|build:linux|...` 等价上面的命令，清单见 `melos.yaml`。

---

正式发布只使用 GitHub Actions 产物；以下本机能力用于调试验证。

## 本机构建能力

| 平台 | 本机可构建 | 调试构建环境 | 备注 |
|---|---|---|---|
| Linux | ✅ | 本地 / CI 调试 | 需 GTK 开发库 + `bundle_linux_deps.sh` |
| Android | ✅ | 本地 / CI 调试 | **模拟器不可用**（无 `/dev/kvm`），回归与验签一律走 CI，依据见上方环境限制 |
| Windows | ❌ | GitHub `windows-2022` | 无代码签名（运行弹 SmartScreen） |
| macOS | ❌ | GitHub `macos-14`（**仅 tag**，10× 计费） | 未公证（首开需绕过 Gatekeeper） |
| iOS | ❌ | 未出包 | 需 Apple Developer 账号 |

为什么（MSVC runner / Gatekeeper / 三个 Windows 坑 / `ditto` 打包）见
[`build-and-release.md`](design-decisions/build-and-release.md) §8。
