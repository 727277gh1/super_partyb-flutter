; Super PartyB 桌面端 —— Inno Setup 安装包脚本
;
; ## 谁调用它
;
; `tools/build_windows_installer.ps1`（CI 的 `build-windows` job 与 release 的
; `windows` job 都走它）。手跑也可以，见 `docs/windows-release.md` §2。
;
; ## 为什么路径全部来自 /D
;
; 脚本里**不写死**任何构建机绝对路径：`BundleDir`（Flutter Release 产物目录）与
; `OutputDir` 由调用方用 `/D` 传入。否则「同一个 .iss 在本地与 CI 都能用」就是
; 一句空话——两边的目录结构不同（本地 `build\windows\x64\runner\Release`，
; CI 上多一层 workspace）。
;
; ## 为什么发普通安装包而不是 MSIX
;
; MSIX 有已知崩溃：`flutter_windows.dll` 在 MSIX 沙箱内 `INVALID_POINTER_READ`
; （同样产物直接跑不崩，见 AGENTS.md §8 坑 3），且薄壳应用还要额外声明
; `internetClientServer` / `runFullTrust` 能力，否则网络调用 hang。Inno Setup
; 出的就是普通 exe 安装包，装完的行为与 zip 版**完全一致**（同一个 exe、同一套
; 用户目录），没有沙箱这一层。
;
; ## 编码
;
; 本文件是 **UTF-8 带 BOM**。ISCC 在没有 BOM 时按 ANSI 读，中文注释会变乱码
; （注释乱码不影响编译，但排障时看不懂；而 `AppName` 等字符串必须保持 ASCII，
; 故中文只出现在注释里）。

#ifndef AppName
  #define AppName "Super PartyB"
#endif

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef BundleDir
  #error 缺少 /DBundleDir=<Flutter Release 产物目录>：没有它不知道要打包什么
#endif

#ifndef OutputDir
  #define OutputDir "."
#endif

#ifndef SetupIconFile
  #define SetupIconFile "setup_icon.ico"
#endif

[Setup]
; ⚠️ AppId **永不改变**：Windows 靠它识别「这是同一个产品的升级/卸载项」。改了
; 它，升级安装会变成「又装了一份」，卸载列表里出现两个条目，用户还得手动删旧
; 的那一份。
AppId={{8E1D7A2C-5B4F-4C3A-9E6D-2F7B1C8A4D91}
AppName={#AppName}
; AppVersion 必须是纯数字 x.y.z（由 ps1 侧归一化）。非数字时 Inno 无法判断
; 谁更新，升级安装的「已安装更新版本」判断会失效。
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Super PartyB
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
AllowNoIcons=yes
; 默认**不弹 UAC**：`PrivilegesRequired=lowest` 时 `{autopf}` 落到
; `%LOCALAPPDATA%\Programs`（每用户安装）。这与本客户端「解压即用、不碰系统
; 目录」的定位一致；想装进 Program Files 的用户可在向导里选「为所有用户安装」
; （`PrivilegesRequiredOverridesAllowed=dialog` 提供那个单选）。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename=spb_desktop-windows-x64-setup
SetupIconFile={#SetupIconFile}
UninstallDisplayIcon={app}\spb_desktop.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
; 升级安装时用 Restart Manager 关掉正在运行的客户端。不设它的话，客户端常驻
; 托盘时「文件被占用」会让升级失败（而用户通常不知道要先退出应用）。
CloseApplications=yes
RestartApplications=no

; `x64compatible` 是 Inno 6.3 才引入的标识符（旧的 `x64` 自 6.3 起弃用但仍在）。
; 按**编译器版本**二选一：runner 镜像若还停在 6.2，直接写 `x64compatible` 会
; 编译失败，而那是「CI 红在打包步骤」这种最难自查的形态。
#if VER >= EncodeVer(6, 3, 0)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 整个 Release 目录（含 `data\` 与上一步拷进来的 VC++ 运行库 DLL）。
; `ignoreversion` 让升级时无条件覆盖——否则同名同版本号的旧插件会被保留，
; 表现为「升级后还是老行为」。
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\spb_desktop.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\spb_desktop.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\spb_desktop.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
