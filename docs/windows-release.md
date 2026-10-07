# Windows 桌面端：下载与出包

> 对应流水线（**两个文件，职责不同**）：
> - **交付**：`.github/workflows/release.yml` 的 `windows` job —— 出 zip 并挂到 GitHub Release；
> - **验证**：`.github/workflows/ci.yml` 的 `build-windows` job —— 只在 main 推送时验证「能不能构建」。
>
> 相关约束：`AGENTS.md` §8（构建平台限制）、§6.6（相对 Tauri 的净损失）

---

## 1. 下载现成的 exe（普通用户）

**前提**：仓库维护者已经打过 tag（`v*`）或手动跑过一次 `release`（见 §2.2）。

### 路径 A：从 Release 下载（推荐）

1. 打开仓库的 **Releases** 页（`https://github.com/<owner>/<repo>/releases`）；
2. 找到最新版本，在 **Assets** 里下载 `spb_desktop-windows-x64.zip`；
3. 解压到**任意可写目录**；
4. 双击 `spb_desktop.exe`。

### 路径 B：从 Actions 产物下载（未打 tag 时）

1. 打开 **Actions** → 左侧选 `release`；
2. 点开最近一次成功的运行；
3. 页面底部 **Artifacts** → 下载 `windows-x64`（`release.yml` 的 windows job 里 `upload-artifact` 的 `name`）；
4. 同上解压运行。

> ⚠️ Actions 产物需要**登录 GitHub** 才能下载，且默认只存 30 天。
> 要长期可下载、免登录，就必须打 tag 走 Release。

### 运行要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11，**x64**（无 arm64 构建） |
| VC++ 运行库 | **无需安装**——zip 里已内置 `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll` |
| 解压方式 | 必须**整包解压**后运行。只把 exe 拷出来会缺 `data/` 与 `flutter_windows.dll`，直接闪退 |
| 磁盘 | 约 80 MB（解压后） |

### 两个常见提示怎么处理

**「Windows 已保护你的电脑」（SmartScreen）**
本包未做代码签名（个人项目无证书），首次运行会提示「未知发布者」。
点「更多信息」→「仍要运行」。

**杀毒软件报毒**
Flutter 打包的 exe 未签名 + 自解压结构，偶被启发式误报。可先用
`Get-FileHash .\spb_desktop-windows-x64.zip -Algorithm SHA256` 与 Release
页面公布的值核对。

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
| 无自动更新 | Tauri 有 `tauri-plugin-updater`，Flutter 没有对应方案（`AGENTS.md` §6.6）。升级靠重新下载 zip |
| 体积 | 解压后约 80 MB（Tauri 约 10 MB） |
| 无 arm64 | 只出 x64 |
| 未做安装包 | 只发 zip。要 Inno Setup / MSIX 需另加步骤；**MSIX 有已知崩溃问题**（`AGENTS.md` §8 坑 3），暂不建议 |
| MSIX 沙箱内崩溃 | `flutter_windows.dll` 在 MSIX 沙箱内 `INVALID_POINTER_READ`，同样产物直接跑不崩。故本流水线**只发 zip** |
