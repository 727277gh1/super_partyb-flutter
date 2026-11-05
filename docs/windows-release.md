# Windows 桌面端：下载与出包

> 对应流水线（**两个文件，职责不同**）：
> - **交付**：`.github/workflows/release.yml` 的 `windows` job —— 出 **Inno Setup 安装包 + 便携 zip**，都挂到 GitHub Release；
> - **验证**：`.github/workflows/ci.yml` 的 `build-windows` job —— 只在 main 推送时验证「能不能构建」（同样出两个产物）。
>
> 相关约束：`AGENTS.md` §8（构建平台限制）、§6.6（相对 Tauri 的净损失）、§6.61（安装包决策）

---

## 1. 下载现成的 exe（普通用户）

**前提**：仓库维护者已经打过 tag（`v*`）或手动跑过一次 `release`（见 §2.2）。

### 路径 A：从 Release 下载（推荐）

1. 打开仓库的 **Releases** 页（`https://github.com/<owner>/<repo>/releases`）；
2. 找到最新版本，在 **Assets** 里选一个 Windows 包：

   | 文件 | 形态 | 适合 |
   |---|---|---|
   | `spb_desktop-windows-x64-setup.exe` | **安装包（推荐）** | 当普通软件用：建开始菜单快捷方式、有卸载项、升级时自动关掉正在运行的客户端 |
   | `spb_desktop-windows-x64.zip` | 便携版 | 免安装 / U 盘 / 没权限写「应用」目录 |

   两个包**内容完全相同**（同一个 exe、同一套用户目录），只差分发形态。

3. 安装包：双击 → 下一步到底（默认装到**当前用户**，不弹 UAC）。
   便携版：解压到**任意可写目录** → 双击 `spb_desktop.exe`。

**卸载**：设置 → 应用 → 已安装的应用 → `Super PartyB` → 卸载。
卸载会删程序目录与快捷方式，**不动**你的同步目录和
`%LOCALAPPDATA%\super_partyb` 里的本地缓存（重装后设置与离线数据仍在）。

### 路径 B：从 Actions 产物下载（未打 tag 时）

1. 打开 **Actions** → 左侧选 `release`（或 `ci`）；
2. 点开最近一次成功的运行；
3. 页面底部 **Artifacts** → 下载 `windows-x64`（zip）或 `windows-installer`
   （安装包）——即 `release.yml` 的 windows job 里 `upload-artifact` 的 `name`；
4. 同上安装或解压运行。

> ⚠️ Actions 产物需要**登录 GitHub** 才能下载，且默认只存 30 天。
> 要长期可下载、免登录，就必须打 tag 走 Release。

### 运行要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11，**x64**（无 arm64 构建） |
| VC++ 运行库 | **无需安装**——两个包里都已内置 `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll` |
| 便携版解压方式 | 必须**整包解压**后运行。只把 exe 拷出来会缺 `data/` 与 `flutter_windows.dll`，直接闪退 |
| 磁盘 | 安装后约 80 MB（安装包本身约 25–30 MB） |

### 两个常见提示怎么处理

**「Windows 已保护你的电脑」（SmartScreen）**
本包未做代码签名（个人项目无证书），首次运行会提示「未知发布者」。
点「更多信息」→「仍要运行」。

**杀毒软件报毒**
Flutter 打包的 exe 未签名 + 自解压结构，偶被启发式误报。可先用
`Get-FileHash .\spb_desktop-windows-x64-setup.exe -Algorithm SHA256`（或对 zip）
与 Release 页面公布的值核对。

---

## 2. 自己出包（构建者）

### 2.1 本地（必须有 Windows 主机）

Linux / macOS 上**无法**构建 Windows 包：产物里的 `spb_desktop.exe` 是
MSVC 编译的 C++ runner，Linux 没有 MSVC。Flutter 会直接拒绝：

```console
$ flutter build windows
"build windows" only supported on Windows hosts.
```

在 Windows 上：

```powershell
flutter pub get
cd apps\spb_desktop
flutter build windows --release
```

产物在 `apps\spb_desktop\build\windows\x64\runner\Release\`。

**别忘了拷 VC++ 运行库**（见 §3），否则分发给别人会闪退。

想顺便出安装包（与流水线完全同一条路径）：

```powershell
# 需先装 Inno Setup 6：https://jrsoftware.org/isdl.php
.\tools\build_windows_installer.ps1 -Version 0.1.0
# 产物：build\windows-installer\spb_desktop-windows-x64-setup.exe
```

不传 `-Version` 时会自动从 `$env:GITHUB_REF_NAME` 或 `apps/spb_desktop/pubspec.yaml`
推导（见 §5）。

### 2.2 用 GitHub Actions（无需 Windows 主机）

**打 tag 出正式 Release：**

```bash
git tag v0.1.0
git push <github-remote> v0.1.0
```

流水线会构建 → 打包 zip → 创建 Release 并上传 asset。

**手动触发（只出 artifact，验证参数用）：**

Actions → `release` → **Run workflow**，可填：

| 输入 | 说明 | 留空时 |
|---|---|---|
| `api_base_url` | PartyB Go API 基地址（含网关前缀 `/pba`） | 取仓库 Variable，再回落本地默认 |
| `ufs_base_url` | UFS 文件服务基地址 | 同上 |
| `oidc_issuer` | OIDC issuer（IdP 基地址，含 basePath） | 同上 |
| `oidc_client_id` | OIDC client_id | 同上 |

**优先级**：`workflow_dispatch` 输入 > 仓库 Variables > 代码里的默认值。

> 手动触发只出 `windows-x64` 这类 Actions artifact（存 30 天）；要长期免登录
> 下载的 Release asset，得推 `v*` tag。手动触发时 macOS job 不跑
> （10× 配额，见 `release.yml` 文件头）。

### 2.3 配置仓库 Variables

Settings → Secrets and variables → Actions → **Variables** 标签页，按需添加：

| Variable | 示例 |
|---|---|
| `SPB_API_BASE_URL` | `https://api.example.com/pba` |
| `SPB_UFS_BASE_URL` | `https://api.example.com/ufs` |
| `SPB_OIDC_ISSUER` | `https://example.com/idp` |
| `SPB_OIDC_CLIENT_ID` | `client_xxxxxxxx` |

> ⚠️ **公开仓库里 Variables 是全局可见的**（与 Secrets 不同）。
> 不要把内网主机名或未公开域名填进来。这些值会出现在任何访客都能读到的
> 仓库设置页上。若地址不宜公开，改用 `workflow_dispatch` 输入——
> 输入值不会出现在设置页，且流水线日志只打印「set / unset」不打印值本身。

**这些值是什么、从哪来**：见 `packages/spb_core/lib/src/env.dart` 的逐项注释。

### 2.4 不出包时会怎样

不传 `SPB_OIDC_CLIENT_ID` 时，包**仍能构建和运行**，只是登录不可用
（UI 会提示「OIDC client_id 未配置」）。其余功能正常。

不传 `SPB_API_BASE_URL` 时会回落到 `http://127.0.0.1:8000`——本机开发用，
分发给别人等于「连不上」。

---

## 3. 为什么必须手动拷 VC++ 运行库

Flutter 的 Windows 产物**不含** C++ 运行库：

```
Release\
├── spb_desktop.exe
├── flutter_windows.dll
├── data\
└── plugin\          ← 没有 msvcp140.dll / vcruntime140.dll
```

目标机若未安装 [VC++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)，
会**直接闪退且不给出可读错误**——用户只看到窗口一闪而过。

流水线里的处理（`.github/workflows/release.yml` 的 `windows` job，另见
`.github/workflows/ci.yml` 的 `build-windows` job 的同一段拷贝）：

```powershell
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
  -latest -property installationPath
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -Directory |
  Sort-Object Name -Descending | Select-Object -First 1
Copy-Item "$($crt.FullName)\*.dll" build\windows\x64\runner\Release\ -Force
```

拷完**断言**三个 DLL 都在，缺任一即让出包失败——比发布一个必然闪退的包好。

---

## 4. 已知限制

| 限制 | 说明 |
|---|---|
| 未做代码签名 | 每次运行都会弹 SmartScreen；无法免除，除非买代码签名证书 |
| 无自动更新 | Tauri 有 `tauri-plugin-updater`，Flutter 没有对应方案（`AGENTS.md` §6.6）。升级靠重新下载安装包或 zip |
| 体积 | 安装后约 80 MB（Tauri 约 10 MB） |
| 无 arm64 | 只出 x64 |
| 安装包未真机验证过 | 已发 Inno Setup 安装包（§5），但本仓开发机无 Windows/ISCC，**编译与装机行为均未人工验证**；首次发布后请按 §5.4 清单走一遭 |
| 未采用 MSIX | `flutter_windows.dll` 在 MSIX 沙箱内 `INVALID_POINTER_READ`，同样产物直接跑不崩。故本流水线发 **zip + Inno Setup 安装包**，不碰 MSIX |

---

## 5. 安装包是怎么打的（Inno Setup）

> 决策背景（为什么不用 MSIX、为什么另做一份图标）见 `AGENTS.md` §6.61。

### 5.1 三块分工

| 文件 | 职责 |
|---|---|
| `apps/spb_desktop/windows/installer/spb_desktop.iss` | 安装包脚本（**UTF-8 带 BOM**） |
| `tools/build_windows_installer.ps1` | 找 ISCC / 算版本号 / 传 `/D` / 断言产物存在 |
| `apps/spb_desktop/windows/installer/setup_icon.ico` | 安装包图标（`tools/gen_brand_assets.py` 生成，BMP 帧） |

两个 workflow（`ci.yml` 的 `build-windows`、`release.yml` 的 `windows`）各只有
一行调用，且都放在**已有 job 内部**——`tools/check_build_defines.sh` 按 job
切块断言「有 `flutter build windows --release` 的 job 也必须传
`--dart-define=SPB_API_BASE_URL`」，拆成新 job 就要把整套 define 再抄一遍，
漏抄的表现就是「包连 127.0.0.1」（`AGENTS.md` §6.33）。

### 5.2 版本号从哪来

`-Version` 参数 → `$env:GITHUB_REF_NAME` → `apps/spb_desktop/pubspec.yaml` 的
`version:` → `0.0.0`。一律归一成纯数字 `x.y.z`（`v1.2.3-rc1` → `1.2.3`），
因为 Inno 靠 `AppVersion` 判断「谁更新」，非数字会让升级安装的版本比较失效。

### 5.3 本地/CI 的前置条件

- **Inno Setup 6.0+**（`ISCC.exe`）。脚本会在 `Program Files` /
  `Program Files (x86)` / `%LOCALAPPDATA%\Programs` 下找 `Inno Setup 6`；
  找不到时尝试 `choco install innosetup`，仍失败则报错并给出下载链接。
- Flutter Release 产物**已拷好 VC++ 运行库**（§3）。缺任一 DLL 时脚本直接
  **抛错**——比发布一个必然闪退的包好。
- `x64compatible` 是 Inno 6.3 才引入的架构标识符，`.iss` 里用 ISPP
  `#if VER >= EncodeVer(6,3,0)` 二选一，故 6.0–6.2 也能编。

### 5.4 首次发布后的验证清单（**必做**）

本仓开发机没有 Windows/ISCC，`.iss` 的编译与装机行为**从未人工跑过**
（脚本逻辑本身已在 Linux + 假 ISCC 上跑通五条路径）。首次发布后请逐条确认：

1. 双击安装 → 默认装到 `%LOCALAPPDATA%\Programs\Super PartyB`，**不弹 UAC**；
2. 开始菜单有 `Super PartyB` 快捷方式，点开能启动并正常登录；
3. 设置 → 应用 → 已安装的应用 里有 `Super PartyB`，卸载后目录与快捷方式都消失；
4. 重装一次 → 卸载列表里**仍然只有一个**条目（`AppId` 未变）；
5. 在客户端运行中直接装新版本 → 安装向导提示并自动关掉正在运行的客户端；
6. 卸载后重装 → 设置与离线缓存仍在（`%LOCALAPPDATA%\super_partyb` 未被删）。
