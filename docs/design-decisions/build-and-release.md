# 构建、分发与发布

> 本文件由 `AGENTS.md` 拆出（内容等价，仅按主题重排）。开源镜像同步、CI 基础镜像与 action 运行时、生产部署接线、构建参数（`--dart-define`）、
Windows 安装包，以及 Linux 分发依赖（§7）与各平台构建限制（§8）。

> 编号（`§6.x` / `§5.x` / `§7` …）**全局稳定**，跨文件引用已改成相对链接；完整索引见 [`设计决策索引`](README.md)。

---

### 6.29 开源镜像同步（`tools/sync-to-github.sh`）

权威源是 **Gitea**（`git@git.atjog.com:dever/super_partyb-flutter.git`，完整历史 +
blame）。GitHub 上另有一份**公开镜像**：
**`git@github.com:727277gh1/super_partyb-flutter.git`**（`main` 分支），用 squash
方案导出：只含「恰好 HEAD 这一棵树」，一条提交。

> 镜像地址写在这里是**有意的**：它本来就是公开信息（GitHub 页面 + 提交 author
> 都可见，`727277gh1` 同时是 noreply 邮箱前缀），不写只会让下次同步的人再问一遍。
> 真正需要隐藏的是**生产部署标识**（域名 / IP / 目录 / 邮箱），那些在仓库外的
> 映射文件里。

```bash
# 三个变量都没有内置默认值以外的必需项：前两个有默认路径，第三个**必须**设。
export SPB_OS_MAP="$HOME/.config/spb-flutter/opensource-map.env"
export SPB_OS_EXTRA_RULES="$HOME/.config/spb-flutter/extra-rules.txt"
export SPB_GITHUB_REMOTE="git@github.com:727277gh1/super_partyb-flutter.git"

bash tools/sync-to-github.sh --verify    # 只校验**当前工作区**是否已干净
bash tools/sync-to-github.sh --dry-run   # 预演：导出 + 替换 + 校验，不推送
bash tools/sync-to-github.sh             # 执行（force-push）
bash tools/sync-to-github.sh --help      # 打印脚本头部的说明
```

`--verify` 与 `--dry-run` 的区别（易混）：前者查的是**工作区**（回答「我的仓库
里还有没有真实值」），后者查的是**导出的临时树**（回答「这次推送会带出什么」）。
未清理干净时 `--verify` 报残留而 `--dry-run` 也报——但只有后者会真的中止推送。

#### 可选环境变量（文档曾漏记，实测补齐）

| 变量 | 默认值 | 用途 |
|---|---|---|
| `SPB_GITHUB_REMOTE` | **无（必填）** | 目标仓库。未设时 `run` 模式直接报错退出 |
| `SPB_OS_MAP` | `$HOME/.config/spb-flutter/opensource-map.env` | 真实值 → 占位符映射 |
| `SPB_OS_EXTRA_RULES` | `$HOME/.config/spb-flutter/extra-rules.txt` | 映射表装不下的形态 |
| `SPB_GITHUB_BRANCH` | `main` | 推送到哪个分支 |
| `SPB_SYNC_COMMIT_MSG` | `chore: import super_partyb-flutter (Flutter 客户端)` | 镜像上那条提交的正文 |

⚠️ **GitHub 上那条 `chore: import super_partyb-flutter (Flutter 客户端)` 是脚本
产物，不是手写提交**。看到它不要以为是有人手工 import——它的作者信息
（`jim <727277gh1@users.noreply.github.com>`）也**继承自主仓库的 `git config`**
（脚本显式用 `git -c user.name=... -c user.email=...` 传入，避免公开仓库里出现
意外的作者信息）。

#### 它内部在 `/tmp` 里建了一个一次性仓库（退出即删）

`/tmp` 那个临时仓库不是人工建的，是脚本自己建的：

```bash
work=$(mktemp -d)          # 第 94 行
cleanup() { rm -rf "$work"; }
trap cleanup EXIT          # 第 96 行：退出时自动删除，故事后找不到
```

六个步骤（对应脚本第 215–256 行）：

| # | 动作 | 行 |
|---|---|---|
| 1 | `git archive HEAD \| tar -x -C "$work/tree"` — 只导出 HEAD 那棵树（不含 `.git` / 未跟踪 / 构建产物） | 215 |
| 2 | `apply_rules` — 按规则替换**文本**文件（`grep -I` 跳过二进制） | 218 |
| 3 | `verify_clean` — 任一真实值残留则**中止，不推送** | 221 |
| 4 | `git init -q -b "$BRANCH"` — 在临时树里建**全新孤立仓库** | 245 |
| 5 | `commit -m "$COMMIT_MSG"` — 单条提交 | 250 |
| 6 | `git push -f -u github "$BRANCH"` — force-push | 256 |

⚠️ **工作区有未提交改动时脚本只警告、不中止**（第 205–208 行）：`git archive`
只导出 HEAD，未提交的东西**不会**进镜像。想包含就先提交——否则会出现「本地
改了但 GitHub 上没变」的困惑。

#### 为什么是 squash 而不是重写历史

Gitea 历史含生产部署标识。把它们从**历史**里清掉需重写所有提交哈希
（`tools/scrub-history.sh`），而 Gitea 是权威源，不该为了一次镜像而改写。
`git archive HEAD` 只导出当前树，用一条新提交承载：GitHub 看到干净的现状，
Gitea 保留完整历史。

#### ⚠️ 代价（务必知晓）

| 代价 | 后果 |
|---|---|
| 历史全丢 | GitHub 上永远只有一条提交，`git blame` / `git log -p` 退化为单条；`release.yml` 的「由 `git log` 生成发布说明」在镜像上无意义 |
| 两边无共同祖先 | GitHub 那份是**孤立仓库**。**绝不**把 Gitea 合并进来或反向拉取——两个无关联历史的合并极难收拾 |
| 每次都是 force-push | GitHub 历史每次被整体替换，有人在那边开 PR 会被打断（故它只适合「只读镜像」） |

#### 为什么脚本里没有任何真实值

与 `scrub-history.sh` 同一取向：本脚本会入库、会被公开。若把「真实值 → 占位符」
的映射（或真实值的任何片段）写进脚本，同步本身就**成了泄露渠道**。故真实值与
规则**全部**来自仓库外的映射文件，脚本里只出现变量名与文件名。

规则文件是**两份**：

| 文件 | 内容 |
|---|---|
| `$SPB_OS_MAP` | 11 个 `SPB_REAL_*` 变量 + 对应 `*_PLACEHOLDER`（与 `scrub-history.sh` 共用同一份） |
| `$SPB_OS_EXTRA_RULES` | 映射表装不下的形态（`查找==>替换`），如「主机名嵌在一整条 SSH URL 里」 |

#### 两个易写错的点

1. **必须跳过二进制**。本仓库有 44 个 golden 基线 PNG，是**逐字节比对**的；
   用 `perl -i` 之类的文本工具处理会损坏文件。故一律用 `grep -I` 筛出文本文件。
2. **规则行要跳过 `#` 注释**。`extra-rules.txt` 里为可读性写了注释行；
   不跳过会把 `# 内网 Gitea 端点…` 当成「查找串」（实测踩过：产物多出无意义替换）。

#### 反向验证（实测）

- `--verify` 在未清理的树上报告残留（实测 2 条规则 / 2 个文件）；
- 脚本产物与手工推送的 GitHub HEAD **逐文件 diff 一致**（`diff -r --brief` 无输出）；
- `--dry-run` 报「替换 2 处、涉及 2 个文件」+「23 条规则全部无残留」，
  与手工流程的数字完全一致。

#### 实测：镜像对应哪个 Gitea 提交（2026-10-20）

GitHub 上当时的 HEAD `8715622` 对应 Gitea 的 **`30cbbf2`**（品牌图标那次）：

```bash
git worktree add --detach /tmp/gitea-x 30cbbf2
diff -rq --exclude=.git /tmp/gitea-x /tmp/gh-clone
# → 只有 2 个文件不同，且差异全是**脱敏替换**：
#     AGENTS.md              （idp.atjog.com → idp.<internal-domain>，tbcc → app.example.com）
#     .github/dependabot.yml （git.atjog.com → git@<gitea-host>）
```

时间戳也对得上（Gitea `11:23:52` → GitHub `11:24:03`）。故**核对镜像是否落后**
的可靠办法不是看提交标题（每次都一样），而是逐文件 diff：

```bash
git clone --depth 1 https://github.com/727277gh1/super_partyb-flutter /tmp/gh-check
git worktree add --detach /tmp/gitea-head HEAD
diff -rq --exclude=.git /tmp/gitea-head /tmp/gh-check   # 只应有脱敏替换造成的差异
```

### 6.30 CI 基础镜像固定与 action 运行时升级

#### 一、`ubuntu-latest` → `ubuntu-24.04`（**必做**，否则会随机变红）

GitHub 官方公告（`actions/runner-images#14748`）：`ubuntu-latest` 自
**2026-10-19 起滚动数周**切到 Ubuntu 26.04，11-19 完成。

**为什么这条必须处理**：`ubuntu-latest` 会在某个**不可预测的时刻**翻转。
同一份代码今天绿、下周某次 push 莫名红——而且红在 `apt-get install` 或
CMake 链接阶段，报错指向系统库而不是我们的代码。

我们依赖的、Ubuntu 26 可能变化的点：

| 依赖 | 风险 |
|---|---|
| `libkeybinder-3.0-dev` / `libayatana-appindicator3-dev` | 第三方包，可能改名或消失 |
| `libglu1-mesa-dev` | 老包，历来是迁移牺牲品 |
| `patchelf` 修的 RUNPATH | glibc 换代后 loader 行为可能变 |

故 7 处 `runs-on: ubuntu-latest` 全部钉为 `ubuntu-24.04`（LTS，官方明确仍可用）。
**固定版本才能让 CI 结果可复现**——与「锁 Flutter 3.47.5」同一取向。

> 等 Ubuntu 26 生态稳定、或我们主动验证过依赖齐全，再改成 `ubuntu-26.04`
> （**不是**改回 `ubuntu-latest`：那会再次把不确定性引回来）。

#### 二、action 运行时 node20 → node24

GitHub 用 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` 强制 node20 的 action 跑在
node24 上，故**功能正常、只是警告**。但这是临时兜底，某天移除后 node20
action 会直接失败。

升级时选了**每个 action 首次支持 node24 的最低版本**（最小变更原则，
避免顺带引入无关 breaking）：

| action | 旧 | 新 | 选择依据 |
|---|---|---|---|
| `actions/checkout` | v4 | **v5** | v5 是首个 node24；v6/v7 的 breaking 只涉 `pull_request_target`（本仓零使用） |
| `actions/upload-artifact` | v4 | **v6** | v6 是首个**默认** node24（v5 仅预备支持、默认仍 node20） |
| `actions/download-artifact` | v4 | **v7** | v7 是首个 node24；**特意避开 v8**——v8 把 digest 不匹配从「警告」改为「直接失败」（新的破坏性默认值） |
| `actions/setup-java` | v4 | **v6** | 官方已明确「v1–v4 deprecated」，该直接升 v6；我们用 `distribution`+`java-version`，未碰 v5/v6 改名的 `jdkFile`/GPG 选项 |
| `android-actions/setup-android` | v3.2.2 | **v4.0.4** | v4.0.4 changelog 正是「Fix for removed tools package」 |
| `subosito/flutter-action` | v2.23.0 | **不变** | 它是 `using: composite`，**不跑 Node**，无需升级 |

#### 三、顺带删掉 `packages: platform-tools` 补丁

上一轮为绕过「`tools` 包被 cmdline-tools 16 移除」加的 `packages: platform-tools`
已可删：`setup-android@v4` 的 `action.yml` 里 `packages` **默认值就是**
`platform-tools`，即 v4 内置了这个修复。

#### 四、守卫不能绑死 action 主版本号

`check_workflow_steps.sh` 原本断言 `'actions/download-artifact@v4' not in uses`。
升到 v7 后它会误报。

**改法**：断言 `any(u.startswith('actions/download-artifact@v'))`。这里要守的是
「release job 有下载步骤」这个**结构事实**，不是某个具体版本。

> 绑死版本的守卫很快会被加进忽略列表——而误报的守卫比没有守卫更危险
> （[§6.17](testing.md) 的同一教训）。

#### 反向验证（实测）

- 两个 workflow 的 YAML 语法：`yaml.safe_load` 通过；
- `check_workflow_steps` + 自测（5 条）全绿——证明版本断言改宽后仍能
  抓住「download-artifact 被注释吞掉」那个历史缺陷形态；
- `check_agents_refs` / `check_format` 通过；
- 全仓 `uses:` 无残留 `@v4`（`grep -c` 为 0）。

### 6.31 生产部署接线：public client、release.yml 的两个缺陷、tbcc6 判定

把客户端接到 `tbcc.atjog.com` 的过程中查出四件事，其中**两个是 release.yml
的真实缺陷**（CI 绿不代表 release 绿——两条 workflow 的构建步骤从未对齐过）。

#### 一、桌面端 OIDC client 必须是 **public + loopback**

生产 IdP 的 `flutter-client` 初始配置有两处不对，逐一有代码依据：

| 字段 | 错值 | 正确值 | 依据 |
|---|---|---|---|
| `tokenEndpointAuthMethod` | `client_secret_basic` | **`none`** | 客户端**从不下发 secret**：`env.dart` 无 `SPB_OIDC_CLIENT_SECRET`，所有调用点都是 `OidcConfig.fromEnv()` 无参（`providers.dart:160`、`auth_browser.dart:42`），`oidc_client.dart:427` 仅 secret 非空才加 `Basic` 头；`auth_loopback.dart:77` 还会**主动拒绝**带 secret 的配置 |
| `redirectUris` | 两个 https 网关回调 | **`["http://127.0.0.1/callback"]`** | 见下 |

**注册值的四条硬约束**（fosite v0.49.0 `authorize_helper.go:117` 的
`isMatchingAsLoopback`）：

```go
if requested.Scheme == "http" &&
    isLoopbackAddress(requested.Hostname()) &&
    registered.Hostname() == requested.Hostname() &&
    // The port is skipped here - see codedoc above!
    registered.Path == requested.Path &&
    registered.RawQuery == requested.RawQuery {
```

1. **scheme 必须 `http`**（不是 https）；
2. **hostname 必须是字面 `127.0.0.1`**——`registered.Hostname() == requested.Hostname()`
   是字面比较，注册成 `localhost` 时客户端发 `127.0.0.1` → 精确匹配与 loopback
   匹配**双双失败**；
3. **path 必须 `/callback`**（`LoopbackRedirectServer.defaultPath`）；
4. **不能带端口**——端口被显式跳过比对（源码注释原文 `The port is skipped here`）。

且 `redirectUris` 的值与 `env.dart:101` 的 `SPB_OIDC_REDIRECT_URI` 默认值
**逐字相同**（运行时由 `auth_loopback.dart:103` 的 `copyWithRedirectUri` 覆盖为
随机端口，故注册值必须是不带端口的那个）。

**PKCE 不可关闭**：`provider.go:63` 硬编码 `EnforcePKCEForPublicClients: true`，
与可配的 `EnforcePKCE`（`cfg.RequirePKCE`）是**两个不同开关**。故 `requirePkce`
字段对 public client 不产生实际差异，但仍应写 `true`（如实反映 + 防将来改为
confidential 时静默降级）。

**活体验证**（直接打生产 authorize 端点，比查库更有说服力）：

| 发送的 `redirect_uri` | 期望 | 实测 |
|---|---|---|
| `http://127.0.0.1:8347/callback`（随机端口） | 通过 | **302 → 登录页** ✅ |
| `http://127.0.0.1/callback` | 通过 | **302 → 登录页** ✅ |
| `http://localhost:8347/callback` | 拒绝 | 400 `invalid_request` ✅ |
| `https://evil.example.com/callback` | 拒绝 | 400 `invalid_request` ✅ |

⚠️ **IdP 的 admin API 不认 API key**：`adminRoute`（`server.go:495`）只挂
`adminauth.Middleware`（`adminauth.go:23`）——`idp_access_token` Cookie 或
`Authorization: Bearer` + 角色含 `admin`/`super_admin`。`serviceauth`
（X-App-ID/X-App-Secret）只挂在 wechat/feishu/dingtalk/ilink binding 路由上；
`applications` 表的 `apiKeyEnabled/apiKeyConfig` 是**应用自身**的属性，与
admin clients 无关。另：`oidc/provider.go:364` 的 `RegisterClient`（RFC 7591
动态注册风格）**无任何 HTTP 路由与调用方，是死代码**。

#### 二、`release.yml` 的 linux job 缺 4 个依赖（真实缺陷）

ci.yml 装了 8 个包，release.yml 只有 5 个——**两条 workflow 的依赖清单从未对齐**。
缺的四个都会让构建**直接失败**（不是功能降级）：

| 缺失包 | 谁需要 | 后果 |
|---|---|---|
| `libsecret-1-dev` | `flutter_secure_storage_linux` | CMake `REQUIRED`，构建即失败 |
| `libkeybinder-3.0-dev` | `hotkey_manager_linux` | 同上（AGENTS.md §7 已记） |
| `libayatana-appindicator3-dev` | `tray_manager` | 同上 |
| `patchelf` | `bundle_linux_deps.sh` | 修 RUNPATH 失败 → 分发即挂 |

⚠️ **第一个失败掩盖了第二个**：修好依赖后才走到 RUNPATH 检查，才暴露下一个缺陷。

#### 三、`release.yml` 的 RUNPATH 检查是**假红**（真实缺陷）

```bash
if find lib -name '*.so*' -exec sh -c 'patchelf --print-rpath "$1" | grep -q /home/' _ {} \; ; then
  echo "❌ RUNPATH 仍指向构建机 /home 路径"; exit 1
fi
```

`find` **不看** `-exec` 的退出码，遍历完即返回 0 → `if` 恒为真 → **恒报错**。
于是 linux job 在「构建成功 + 依赖打包成功」后仍判失败。

这与 §6.30 之前修过的 ci.yml 同一条检查是**同一个 bug**——当时只修了 ci.yml，
release.yml 漏改。**改这类检查时必须全仓 grep 同型模式**（本次复查：只剩注释里
的说明文字，无其他实例）。正确写法是先收集命中项再判空：

```bash
bad=$(find lib -name '*.so*' -exec sh -c \
  'patchelf --print-rpath "$1" | grep -q /home/ && echo "$1"' _ {} \;)
[ -n "$bad" ] && { echo "❌ $bad"; exit 1; }
```

#### 四、`tbcc6.atjog.com` **应该**配进 `SPB_PREFERRED_HOSTS`（含一次错误判断的纠正）

**本节最初写的是「不应配置」，结论错了。** 记录纠正过程，因为错误的推理方式
比错误本身更值得防。

**当时的错误推理**：DNS 实测显示 tbcc6 指向家宽动态地址，于是判为「不是可用
的生产端点」，并认为配置它会「制造随机故障」。DNS 事实（下列仍准确）：

| 证据 | 值 |
|---|---|
| CNAME 链 | `tbcc6.atjog.com` → `qpoweiurty.atjog.com`（随机串，DDNS 特征） |
| AAAA | `2409:8a55:a20:8570:be24:11ff:fee3:581a` |
| 地址段 | `2409:8a55::/32` = 中国移动（家宽段） |
| 接口标识 | `be24:11ff:fee3:581a` = EUI-64（由网卡 MAC 推导）→ 动态地址 |
| TTL | CNAME 600s（DDNS 常用短 TTL，便于换 IP） |

**错在哪**：§5.1.1 的机制**就是为「首选端点可能不可达」设计的**，把
「地址会变」当成否决理由，等于把设计要容错的情形当成了缺陷。逐条看代码：

| 顾虑 | 代码事实 |
|---|---|
| 地址随时会变 | 旧地址变黑洞 → 3 次连接失败降级回 CDN；**下次启动重解析 DNS** 拿新地址 → 再探 → 可达则升级。自愈 |
| 证书未必匹配 | `classifyDioFailure` 把 `badCertificate` 归为 `connectivity`（`endpoint_health_interceptor.dart:63`）→ 计入降级。但**探测是纯 TCP**（`Socket.connect`，`endpoints.dart:96`）不校验证书，故证书问题只影响升级后的前几个请求 |
| 其他网络连不上 | 探测失败 → `kept` → **保持编译期地址**，与不配置**完全相同** |
| 中途切网 | 降级是**快路径**：不探测、不等冷却，连续 3 次即退回 |

**失败模式枚举**（没有任何一行比不配置更差）：

| 场景 | 结果 |
|---|---|
| 无 IPv6（多数用户） | 探测失败 → 保持 CDN |
| 有 IPv6、tbcc6 可达、证书对 | **升级到直连源站**（收益） |
| 有 IPv6、tbcc6 不可达 | 探测失败 → 保持 CDN |
| 升级后断网/换网/证书失效 | 3 次失败 → 降级 CDN，冷却后重探 |

**第二个错误**：曾说「`tbcc.atjog.com` 本身已是双栈，不需要 preferred hosts」。
**双栈 ≠ 直连源站**——`tbcc.atjog.com` 的 AAAA 是 EdgeOne **边缘节点**
（`240d:c010::/32`），流量仍过 CDN；`tbcc6` 是**绕过 CDN 直连源站**，两者目的
完全不同，IPv6 只是顺带的。把两件事混为一谈，就得出了「不需要配」的错误结论。

**实际配置**：

```
SPB_PREFERRED_HOSTS = tbcc.atjog.com=tbcc6.atjog.com
```

一条规则即可：`api` 与 `ufs` 的 host 都是 `tbcc.atjog.com`，`resolveEndpoints`
在循环里对两者各调一次 `_rewriteHost`。**issuer 不受影响**（`SpbEndpoints`
无 issuer 字段），且桌面端 loopback 回调打 `127.0.0.1`，与 tbcc6 完全正交。

> ⚠️ **本机与 bcc 都无 IPv6 出口**，无法直接验证 tbcc6 可达性（check-host.net
> 的节点也只解析 A 记录，连 `ipv6.google.com` 都报 `Unknown host`）。证书由部署
> 方确认覆盖该域名。若将来 tbcc6 下线，**改/删这个 Variable 即可**，无需发版。

#### 五、GitHub Variables（公开仓库，值全部会进二进制）

| Variable | 值 |
|---|---|
| `SPB_API_BASE_URL` | `https://tbcc.atjog.com/pba` |
| `SPB_UFS_BASE_URL` | `https://tbcc.atjog.com/ufs` |
| `SPB_OIDC_ISSUER` | `https://tbcc.atjog.com/idp` |
| `SPB_OIDC_CLIENT_ID` | public client 的 `clientId`（**公开值**，会出现在授权 URL） |
| `SPB_PREFERRED_HOSTS` | `tbcc.atjog.com=tbcc6.atjog.com`（见上节四） |

`--dart-define` 的值**必然编译进二进制**（在 `lib/libapp.so` 的 Dart AOT 常量区，
`strings` 可提取），故配进公开 Variables 不构成新泄露。验证方式：下载产物后
`strings -a lib/libapp.so | grep tbcc`——同时应确认旧默认值 `127.0.0.1:8000` 已消失。

`release.yml` 四个平台均接入了全部 5 个 define（windows `:174`、linux `:274`、
android `:388`、macos `:475`），config job 会逐项打印 `set` / `unset`。

⚠️ **`ci.yml` 同样必须传**（2026-10 修）：它的 `build-*` job 曾一个 define 都
没传，而产物被上传成 Actions artifact 供人下载——于是拿到的是「连 127.0.0.1」
的包，运行时报「远程计算机拒绝网络连接」。详见 §6.33。
`tools/check_build_defines.sh` 守这件事。

⚠️ **`gh` 的 fine-grained PAT 需要 `Actions: Read and write`** 才能读写 Variables：
只有 read 时 `POST /actions/variables` 报 403 `Resource not accessible by personal
access token`（`PUT` 对不存在的变量报 404，容易误判成路径错）。

### 6.33 CI 产物也用 127.0.0.1：构建参数没传（2026-10 真实缺陷）

**症状**：下载 CI 构建的 Windows 包，双击运行后弹「远程计算机拒绝网络连接」
（`ECONNREFUSED`）。包能启动、界面正常、**所有请求都失败**。

**根因不是参数写错，而是根本没传**。`ci.yml` 的三个 `build-*` job 都只写了
`flutter build <platform> --release`，整文件 `dart-define` **零命中**。于是产物
用的是 `SpbEnv` 的编译期默认值：

| 常量 | 默认值 |
|---|---|
| `apiBaseUrl` | `http://127.0.0.1:8000` |
| `ufsBaseUrl` | `http://127.0.0.1:9000/ufs` |
| `oidcIssuer` | `http://127.0.0.1:3000/idp` |

客户端去连**用户自己机器的 8000 端口**——那里什么都没有。

#### 为什么所有门禁都是绿的

这是本仓库反复出现的那一类「绿不代表对」（同 [§6.21](testing.md) 的 codegen 漂移、[§6.26](testing.md) 的
`analysis_options` 未生效）：

| 门禁 | 结果 | 为什么抓不到 |
|---|---|---|
| `dart analyze` | ✅ | 默认值是**合法字符串**，不是错误 |
| 3400+ 用例 | ✅ | 测试注入 Fake API，不碰真实地址 |
| `flutter build windows` | ✅ | 编译成功，参数缺失不影响编译 |
| Linux 自包含检查 | ✅ | 查的是 `ldd` 与 RUNPATH，与地址无关 |

#### 为什么 `release.yml` 是对的、`ci.yml` 是错的

`release.yml` 有独立的 `config` job 解析「dispatch 输入 > 仓库 Variables >
内置默认值」，四个平台各 5 条 define 全部传了。`ci.yml` 只打算「验证能不能编译」，
却把产物**上传成 Actions artifact 供人下载**（`retention-days: 7`）。

两者的**意图**不同（验证 vs 交付），**产物却是同一种**。用户不会区分——
他看到一个能下载的 zip，就会去运行它。故现在 ci.yml 也复用同一套参数解析。

#### 守卫：`tools/check_build_defines.sh`（两道，缺一漏一类）

| 道 | 做法 | 能抓什么 |
|---|---|---|
| **静态** | 每个执行 `flutter build <p> --release` 的 job 必须在该 job 内出现 `--dart-define=SPB_API_BASE_URL` | 「没传」 |
| **动态** | AOT 快照里不得残留 `127.0.0.1:8000` | 「传了但没生效」 |

动态那条是**直接证据**，且实测可靠：传了 `--dart-define` 后，未被使用的默认值
字符串会被 **tree-shake 掉**。同一份代码实测：

```
flutter build linux --release
  → strings -a lib/libapp.so | grep -c 127.0.0.1:8000  →  1

flutter build linux --release --dart-define=SPB_API_BASE_URL=https://example.test/pba
  → 同上 → 0；grep -c example.test/pba → 1
```

故「产物含 127.0.0.1:8000」**等价于**「这个包连的是本机」。

快照位置各端不同：Linux `bundle/lib/libapp.so`、Windows `Release/data/app.so`、
Android `lib/<abi>/libapp.so`（在 APK 里，需先 `unzip`）。

#### ⚠️ 按 **job** 切块检查，不能整文件 grep

这是最容易写错的一处，也是自测用例 3 专门钉住的：`release.yml` 的 define 在
`config` job 里**解析**、在 `build` job 里**使用**——两者是分开的 job。若守卫对
整个文件 grep，就会因为「config 里出现过这个字符串」而放行一个没传的构建 job。
按 job 切块后才拦得住。

#### 只要求 api 那一个 define

不要求 UFS / OIDC 齐全：`apiBaseUrl` 是「连不上就什么都做不了」的根，其余缺失是
**功能降级**（OIDC 缺失 → 登录不可用，其余正常）。要求全部齐全会让守卫在「故意
只配 api」的场景误报，而误报的守卫很快会被加进忽略列表。

#### 自测（`check_build_defines_selftest.sh`，16 条断言）

在 `mktemp -d` 里造最小仓库、把真守卫**逐字节复制**过去执行（不是副本实现）。
钉住四处相反方向的判定：漏报（没传必须报错）/ 误报（传了必须放行）/
按 job 切块（别的 job 传了不算）/ 防空转（一个构建 job 都没有时必须报错）。

反向验证逐条实测：撤掉 `build-windows` 的 define → 报错；把守卫改回整文件 grep
→ 用例 3 失败；去掉二进制检查 → 用例 6 失败。

#### ⚠️ 本地 `.so` 的陷阱（写这类守卫时）

`cleanup` 里别写 `for d in "${arr[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done`
——空数组时 `${arr[@]:-}` 展开成空串，`[ -n "" ]` 失败让**函数返回 1**，
EXIT trap 会把整个脚本的退出码改成 1。实测现象：16 条断言全绿、最后一行打印
「自测通过」，退出码却是 1。写成 `for d in ${arr[@]+"${arr[@]}"}` 并显式
`return 0`。

#### 若将来新增出包平台

必须同时做两件事，否则复发：

1. 在该 job 内传 `--dart-define=SPB_API_BASE_URL`（`check_build_defines.sh`
   会拦）；
2. 把该平台的 AOT 快照路径加进守卫的 `SNAPSHOTS` 数组（否则二进制断言
   对它静默跳过）。

### 6.61 Windows 分发：zip 之外再发 Inno Setup 安装包（2026-11）

此前 Windows 只有 `spb_desktop-windows-x64.zip`（解压即用）。问题不是「不能用」，
而是它把**安装的每一步都推给用户**：自己挑目录、自己建快捷方式、升级时先手动退出
（否则文件被占用）、卸载时自己去删文件夹（还会漏掉 `%LOCALAPPDATA%` 里的数据）。

`docs/windows-release.md` §4 早就把「未做安装包」列为已知限制，本节兑现它。

#### 三个候选里为什么是 Inno Setup

| 方案 | 结论 |
|---|---|
| **Inno Setup**（选用） | 单个 `.exe`，产物与 zip **内容完全相同**（同一个 exe、同一套用户目录），没有额外运行时；Windows runner 预装 |
| MSIX | ❌ **已知崩溃**：`flutter_windows.dll` 在沙箱内 `INVALID_POINTER_READ`（同样产物直接跑不崩，§8 坑 3），且薄壳应用要额外声明 `internetClientServer` / `runFullTrust`，否则网络调用 hang |
| Tauri 时代的 updater | ❌ 与本仓库无关（那是另一个栈的能力），且需要签名/托管 |

#### 两个产物，一份内容

| 产物 | 用途 |
|---|---|
| `spb_desktop-windows-x64-setup.exe` | **推荐**：开始菜单快捷方式、卸载项、升级时自动关掉正在运行的客户端 |
| `spb_desktop-windows-x64.zip` | 便携版：不动系统任何位置（**保留**，不是过渡态——U 盘/免安装场景没有替代品） |

#### 实现的三块

| 文件 | 职责 |
|---|---|
| `apps/spb_desktop/windows/installer/spb_desktop.iss` | 安装包脚本（**UTF-8 带 BOM**，见下） |
| `tools/build_windows_installer.ps1` | 找 ISCC / 算版本号 / 传 `/D` / 断言产物存在 |
| `apps/spb_desktop/windows/installer/setup_icon.ico` | 安装包图标（由 `gen_brand_assets.py` 生成，见 [§6.32](ui.md)） |

两个 workflow 各只有一行调用（`ci.yml` 的 `build-windows` 与 `release.yml` 的
`windows`），且都放在**已有 job 内部**——`tools/check_build_defines.sh` 按 job 切块
断言「有 `flutter build windows --release` 的 job 也必须传
`--dart-define=SPB_API_BASE_URL`」，拆成新 job 就要把整套 define 再抄一遍，而漏抄
的表现正是 §6.33 那个「连 127.0.0.1」的真实缺陷。

#### 六个易写错的点

1. **`.iss` 必须 UTF-8 带 BOM**。没有 BOM 时 ISCC 按 ANSI/系统码页读，中文注释
   变乱码。故文件用 `encoding='utf-8-sig'` 写；而 `AppName` 等**字符串保持 ASCII**
   （`{cm:...}` 的 `[Languages]` 也不引第三方 `ChineseSimplified.isl`——那是非官方
   翻译，runner 上不存在，引了就是构建失败）。
2. **`ArchitecturesAllowed` 按编译器版本二选一**。`x64compatible` 是 Inno 6.3 才
   引入的标识符，`windows-2022` 上装的若是 6.2 就直接编译失败，而「红在打包步骤」
   是最难自查的形态。故用 ISPP 守卫：`#if VER >= EncodeVer(6,3,0)` → `x64compatible`，
   `#else` → `x64`。
3. **版本号必须归一成纯数字 `x.y.z`**。Inno 靠 `AppVersion` 判断「谁更新」，非数字
   时升级安装的版本比较失效。故 `v1.2.3-rc1` → `1.2.3`（正则 `^v?(\d+(\.\d+){0,2})`），
   来源链 `-Version` → `$env:GITHUB_REF_NAME` → pubspec `version:` → `0.0.0`。
4. **`AppId` 永不改变**。Windows 靠它识别「同一个产品的升级/卸载项」，改了就会
   「又装一份」，卸载列表出现两个条目。
5. **`PrivilegesRequired=lowest`**：不弹 UAC，`{autopf}` 落到
   `%LOCALAPPDATA%\Programs`（每用户安装），与本客户端「不碰系统目录」的定位一致；
   要装进 Program Files 的用户可在向导里选（`PrivilegesRequiredOverridesAllowed=dialog`）。
6. **不能取 PATH 上第一个 `ISCC.exe`，而「6.0+」这个门只能是 best-effort**。
   装了 Chocolatey 的机器（GitHub 的 `windows-2022` 就是——`InnoSetup 6.7.1` 由
   choco 装）PATH 上有一个 `C:\ProgramData\Chocolatey\bin\ISCC.exe` **shim**
   （shimgen 生成的转发器），真正的编译器在 `Program Files (x86)\Inno Setup 6` 下。
   2026-11 CI 实测：`需要 Inno Setup 6.0+，当前 0.0.0.0（...\Chocolatey\bin\ISCC.exe）`
   ——**本机没有 Windows，这一条只在 CI 上才会现形**（本节「验证」写明「没有
   Windows 手测」，这就是它的代价）。

   ⚠️ **第一版修法错了**：以为「按 `FileVersion` 挑最高」能让真身（6.x）胜出。
   下一次 CI 的日志证明 **`ISCC.exe` 根本没有版本资源**——shim 与真身**都是**
   `0.0.0.0`（`ISCC 候选：...Chocolatey\bin\ISCC.exe (v0.0.0.0); ...Inno Setup 6\ISCC.exe (v0.0.0.0)`）。
   于是版本永远并列，「挑最高」等价于「取第一个」，实际调用的仍是 shim。

   最终两条：① 候选顺序改成**安装目录优先、PATH 最后**（并列时先命中者被调用，
   这样调用的是编译器本身而不是转发器）；② 「读不出版本号」**不等于**「版本太旧」，
   只 warn 不抛——在一个真装了 6.7.1 的机器上按 `0 < 6` 判死是纯粹的误伤，真到
   Inno 5 时 ISCC 自己会报 `Unknown parameter`，同样能定位。候选清单与最终选择
   都打进日志，下次镜像变化时一眼可查。

#### 安装包图标为什么另做一份

`windows/runner/resources/app_icon.ico` 是 **PNG 帧**的 256px 图标（`Runner.rc` 的
exe 资源用它，资源管理器正常）。而 ISCC 读 `SetupIconFile` 时对 PNG 压缩帧的支持
**未经验证**——本机没有 Windows/ISCC，测不了；且这与 [§6.55](platform.md) 的托盘图标是同一个坑
（`LoadImage` 只认 BMP 系资源）。故 `gen_brand_assets.py` 新增 `windows_installer()`，
出**纯 BMP 帧**的 16/32/48/64/128（82 KB）。**不含 256×256**：BMP 帧不压缩，单张
就 256 KB，而 128 放大到资源管理器的大图标尺寸肉眼无差。

#### 验证（**没有 Windows 手测**，如实记录）

本机无 Windows/ISCC，故 `.iss` 的编译与装出来的行为**都没跑过**。已做的自动化验证：

- `tools/build_windows_installer.ps1` 用 pwsh 7.4 在 Linux 上跑通**全部五条路径**
  （成功 / 缺运行库 / 找不到 ISCC / ISCC 非 0 退出 / ISCC 成功但无产物），
  并用假 ISCC 断言 `/D` 参数是**单个 argv**（路径含空格也不被拆）；
- 版本推导四种来源逐条实测（`v1.2.3-rc1` → `1.2.3`、`GITHUB_REF_NAME=v0.9.0` →
  `0.9.0`、pubspec → `0.1.0`、兜底 `0.0.0`）；
- `setup_icon.ico` 用 `file` 确认 `5 icons, 16x16, 24 bits/pixel`（BMP 帧）；
- YAML 语法 + `check_workflow_steps` / `check_build_defines` / `check_agents_refs`
  全绿。

首次真机验证清单：装→开始菜单快捷方式→卸载→重装（确认没有两个条目）→升级安装
（确认自动关掉正在运行的客户端）。

#### 有意不做

- **不做自动更新器**：需要签名与托管，且与「无代码签名」现状冲突（见 [§8](#8-构建平台限制) 的签名/公证限制）。
- **不做 MSIX**：见上，有已知崩溃。
- **不给安装包单独写一套 UI/脚本逻辑**：`.iss` 只做「拷文件 + 快捷方式 + 卸载项」，
  安装后的行为与 zip 版**逐字节相同**——两套行为就是两套 bug。
- **不在 `.iss` 里引中文语言包**：非官方翻译文件在 runner 上不存在，引了即构建失败。

### 6.87 升级安装卡在「正在关闭应用」：关窗即隐藏把 Restart Manager 的 WM_CLOSE 拦下了（2026-11）

**现象**：客户端留在托盘时直接装新版本，安装向导走到「正在关闭应用」就停住；
「下一步」按了没反应（或反复提示应用关不掉），只能强杀进程再装。

**根因**是两条**各自正确**的设计撞在一起：

1. 客户端「关窗 = 隐藏到托盘」（`setHideOnClose` → `window_manager` 的
   `preventClose`），目的是让交付物同步在后台继续跑（见
   `packages/spb_platform/lib/src/desktop_capabilities.dart` 的 `setHideOnClose`）；
2. `.iss` 用 `CloseApplications=yes`，即让 Inno Setup 通过 **Restart Manager**
   关掉正在运行的客户端，否则升级时 `spb_desktop.exe`/DLL 被占用、覆盖失败。

Restart Manager 的关闭序列（MS「Restart Manager — Guidelines for Applications」）
是 `WM_QUERYENDSESSION`（lParam = `ENDSESSION_CLOSEAPP`）→ `WM_ENDSESSION` →
对仍未退出的 GUI 应用**再用 `WM_CLOSE` 兜底**。本客户端在第一步没应答、第二步
没退出，第三步的 `WM_CLOSE` 又正好被 `preventClose` 拦成「隐藏到托盘」——
进程始终不退，安装程序就卡在那里。卸载器同理。

```
修复前：RM 发 WM_QUERYENDSESSION → DefWindowProc 应答 TRUE（没人管它）
        → RM 发 WM_ENDSESSION   → 没人管它
        → RM 发 WM_CLOSE        → window_manager 看到 preventClose，返回 -1
        → 进程仍在 → 安装程序「关不掉」

修复后：WM_QUERYENDSESSION(CLOSEAPP) → 原生侧应答 TRUE
        → WM_ENDSESSION(TRUE)         → 通知 Dart 走 quit()（摘监听器/注销
                                        全局快捷键/销毁托盘图标/结束进程）
        → Dart 没来得及退出时 WM_CLOSE 直接 DefWindowProc（不再换 hide）
```

**修法的四处**（少一处就退回原样）：

| 位置 | 内容 |
|---|---|
| `apps/spb_desktop/windows/runner/flutter_window.cpp` | 在 `MessageHandler` 里、**`HandleTopLevelWindowProc` 之前**接住三个消息：`WM_QUERYENDSESSION` 应答 `TRUE`、`WM_ENDSESSION` 调通道、`session_ending_` 时放行 `WM_CLOSE` |
| `packages/spb_platform/lib/src/session_end.dart` | `installSessionEndHandler` / `uninstallSessionEndHandler`：通道路由到调用方的退出动作（`kHostLifecycleChannelName = 'com.atjog.spb/host_lifecycle'`，与原生侧逐字一致） |
| `apps/spb_desktop/lib/desktop_integration.dart` | `quitApplication`：托盘「退出」与会话结束**共用**一条路径，且幂等（`_quitting`）——RM 在 Dart 收尾慢时还会再发一次 |
| `apps/spb_desktop/windows/installer/spb_desktop.iss` | `CloseApplications=yes` → **`force`**：RM 仍先走正常关闭（即上面那条干净路径），超时才强关，作为最后一道保险 |

**为什么 `.iss` 还要 `force`**：这是**先礼后兵**，不是替代。干净退出的价值在于托盘图标
被注销、全局快捷键被摘除、会话正常退出标记被写下（下次启动不会把这次退出当成「中途
崩溃」）；只有 Dart 侧确实跑不完时才强关。代价可控：本地库是 WAL，交付物写盘走
`.part` + rename（[§6.42](sync.md)），强关不会留下半截文件。

**顺带得到的**：退出日志现在区分来源（`quit(reason: 'user')` / `'session-end'`），
「应用为什么自己退了」不再和「用户点了退出」混为一谈。

**验证与边界**（本机（Linux LXC）**没有 Windows**，如实记录）：

- 能自动验证的部分：`dart analyze` + `apps/spb_desktop` 单测（模拟原生侧发来
  `sessionEnding` 后确实走 `quit`、`detach` 后不再响应）；`.iss` 的改动只有一行
  指令，编译验证在 CI 的 `build-windows` job；
- **不能**验证的部分：真机升级安装的全过程（`WM_*` 消息序列、Dart 收尾是否
  在 RM 超时内完成）。故 [§6.61](#661-windows-分发zip-之外再发-inno-setup-安装包2026-11)
  的那条真机验证清单里，「升级安装（确认自动关掉正在运行的客户端）」现在有
  两个含义：装成功 **且** 托盘没有僵尸图标。

**有意不做**：

- **不处理普通关机/注销的 `WM_ENDSESSION`**（lParam 不含 `ENDSESSION_CLOSEAPP`）
  ——保持既有行为（由系统兜底杀进程）。扩大到那条路径等于给「注销时还在写盘」
  加一个未验证的时序，而它不在本次报障范围内。
- **Linux/macOS 不加对应接线**：它们的安装形态是解压替换、没有 Restart Manager
  这一步；同一条通道在那边**没有人调用**，注册处理器天然是空操作。
- **不把 `preventClose` 关掉**：那会让「关窗即隐藏」失效（§6.4 的既有行为），
  也解决不了问题——RM 的 `WM_QUERYENDSESSION` 仍无人应答。

## 7. Linux 桌面端系统依赖（**分发必读**）


### 编译期依赖

```bash
# 基础（Debian/Ubuntu）
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libglu1-mesa-dev

# 插件依赖
sudo apt install libkeybinder-3.0-dev          # hotkey_manager
sudo apt install libayatana-appindicator3-dev  # tray_manager
sudo apt install libsecret-1-dev               # flutter_secure_storage
```

**`libkeybinder-3.0-dev` 不是默认安装项**，缺它时报：

```
CMake Error at flutter/ephemeral/.plugin_symlinks/hotkey_manager_linux/linux/CMakeLists.txt:49 (message):
  The `hotkey_manager` package requires keybinder-3.0.
```

**免 sudo 安装路径**（本仓库惯例 `~/.local/opt`）：

```bash
cd /tmp && mkdir kb && cd kb
apt-get download libkeybinder-3.0-dev libkeybinder-3.0-0
for f in *.deb; do dpkg-deb -x "$f" root/; done
PREFIX="$HOME/.local/opt/keybinder"
mkdir -p "$PREFIX/lib/pkgconfig"
cp root/usr/lib/x86_64-linux-gnu/libkeybinder-3.0.so.0.0.0 "$PREFIX/"
cp -r root/usr/include "$PREFIX/"
cd "$PREFIX" && ln -sf libkeybinder-3.0.so.0.0.0 libkeybinder-3.0.so && ln -sf libkeybinder-3.0.so.0.0.0 libkeybinder-3.0.so.0
sed -e "s|^prefix=.*|prefix=$PREFIX|" -e "s|^libdir=.*|libdir=\${prefix}|" \
    -e "s|^includedir=.*|includedir=\${prefix}/include/keybinder-3.0|" \
    /tmp/kb/root/usr/lib/x86_64-linux-gnu/pkgconfig/keybinder-3.0.pc > "$PREFIX/lib/pkgconfig/keybinder-3.0.pc"

export PKG_CONFIG_PATH="$HOME/.local/opt/keybinder/lib/pkgconfig:$PKG_CONFIG_PATH"
```

### 分发：**必须**跑 `bundle_linux_deps.sh`

```bash
cd apps/spb_desktop && flutter build linux --release
cd ../.. && bash tools/bundle_linux_deps.sh
```

**为什么必须**：`libkeybinder-3.0.so.0` 若装在非标准前缀，构建产物会把该**绝对路径写进 RUNPATH**，结果「开发机能跑、分发即挂」。

脚本做两件事：
1. 把非系统库复制进 `bundle/lib/`；
2. 用 `patchelf` 修正 RUNPATH。

⚠️ **RUNPATH 修正的关键细节**：主程序在 `bundle/`，插件在 `bundle/lib/`，**两者 `$ORIGIN` 不同**：

| 目标 | 正确 RUNPATH | 错误写法 |
|---|---|---|
| `bundle/spb_desktop` | `$ORIGIN/lib` | `$ORIGIN` |
| `bundle/lib/*.so` | `$ORIGIN` | `$ORIGIN/lib` ← 指向不存在的 `bundle/lib/lib`，加载器回退到开发机绝对路径 |

`patchelf` 不在 Debian 默认安装项，同样可走 `apt-get download patchelf` + `dpkg-deb -x` 到 `~/.local/bin`。

### 验证分发包自包含

```bash
cd apps/spb_desktop/build/linux/x64/release/bundle
LD_LIBRARY_PATH= ldd spb_desktop | grep "not found"     # 应无输出
for f in lib/*.so*; do patchelf --print-rpath "$f"; done # 不应出现 /home/
```

## 8. 构建平台限制

### Windows：**本机（Linux）无法构建**

```console
$ flutter build windows
"build windows" only supported on Windows hosts.
```

根因：`my_app.exe` 是 MSVC 编译的 C++ runner，Flutter 的 `windows/runner/` 就是这套 CMake + C++ 源码。Linux 无 MSVC。

Flutter 检查的硬性依赖（`packages/flutter_tools/lib/src/windows/visual_studio.dart`）：

```dart
static const _requiredWorkloads = <String>[
  'Microsoft.VisualStudio.Workload.NativeDesktop',  // 或关系，命中其一即可
  'Microsoft.VisualStudio.Workload.VCTools',
];
// 必需组件
'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'   // MSVC x64/x86 build tools
'Microsoft.VisualStudio.Component.VC.CMake.Project'   // C++ CMake tools
```

**GitHub `windows-latest` runner 全部预装**（已逐条比对 [runner-images Windows2025 清单](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md)）：VS2022 Enterprise + NativeDesktop 工作负载 + Windows SDK + CMake + VSWhere + **Inno Setup 6.7.1**，**只差 Flutter SDK**。

最小 CI job：

```yaml
windows:
  runs-on: windows-latest
  steps:
    - uses: actions/checkout@v4
    - uses: subosito/flutter-action@v2
      with: { flutter-version: '3.47.5', channel: stable, cache: true }
    - run: flutter config --enable-windows-desktop
    - run: flutter pub get
    - run: flutter build windows --release
    - name: Bundle VC++ runtime      # ← 见下「坑 1」
      shell: pwsh
      run: |
        $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
        $crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -Directory | Sort-Object Name -Descending | Select-Object -First 1
        Copy-Item "$($crt.FullName)\*.dll" build\windows\x64\runner\Release\
    - uses: actions/upload-artifact@v4
      with: { name: windows-release, path: build/windows/x64/runner/Release/ }
```

**三个坑**：

1. **VC++ 运行库不在产物里**：`Release/` 只有 `flutter_windows.dll` / `my_app.exe` / `data/`，**没有** `msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`。目标机未装 [VC++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) 会**直接闪退且报错不友好**。必须手动拷贝（上面的 pwsh 步骤）。
2. **`windows-latest` 正迁往 VS 2026**：Flutter 3.47.5 已适配（`cmakeGenerator` 有 `'Visual Studio 18 2026'` 分支）。要可复现就锁 `runs-on: windows-2022`。
3. **MSIX 沙箱内崩溃**：`flutter_windows.dll` 在 MSIX 沙箱内崩溃（`INVALID_POINTER_READ` @ `FlutterWindowsViewController::engine`），**同样产物直接跑不崩**。且薄壳类应用需声明 `internetClientServer` / `runFullTrust` 能力，否则网络调用 hang。**故本项目发 zip + Inno Setup 安装包，不碰 MSIX（见 §6.61）。**

> 上面的最小示例只出 zip。实际流水线（`ci.yml` 的 `build-windows` 与
> `release.yml` 的 `windows`）在拷完运行库后再调
> `tools/build_windows_installer.ps1` 出 Inno Setup 安装包——两个产物内容
> 完全相同，只差分发形态。

### macOS / iOS：需 macOS 主机

macOS runner 在 GitHub Actions 上**按 10× 计费倍数**，成本显著（见下节）。

#### macOS 出包（已在 `release.yml` 实现，仅 tag 触发）

不需要 Apple Developer 账号：Flutter 的 macOS 模板在 project 级设了
`CODE_SIGN_IDENTITY = "-"`（**ad-hoc 签名**）。Apple Silicon **强制要求**
二进制至少被 ad-hoc 签过，故不能像 iOS 那样「完全跳过签名」。

两个易踩的点：

1. **打包必须用 `ditto`，不能用 `zip`**。`.app` 是目录，内含符号链接
   （Frameworks 里大量使用）与可执行位；`zip` 会把符号链接存成普通文件、
   丢掉权限位，解压后签名校验失败、app 启动即崩。
2. **Release 默认产出 universal（arm64 + x86_64）**，无需显式指定 `ARCHS`。

代价：产物未用 Developer ID 签名也未公证，用户首次打开被 Gatekeeper
拦下，需右键→打开，或 `xattr -dr com.apple.quarantine <app>`。

#### ✅ 已修复：macOS 交付物同步写用户所选目录

`Release.entitlements` / `DebugProfile.entitlements` **两份都已包含**：

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

（修复于 commit `2f5d778`。此前两份 entitlements 均缺该键。）

**为什么必须有这一项**（别删，删了就回退）：`file_selector` 的 macOS README
明确要求它（沙箱下访问用户所选目录）。交付物同步会用 `LocalFileSink` 向用户
选定的同步目录写文件，**缺这一项沙箱会拒绝**，表现为「同步报写入失败」。
debug 构建沙箱较松可能不暴露，**只在正式包上现形**——与上面
`network.client` 的陷阱同型。

改动这两份文件后请顺手核对本段，避免再次出现「代码已修、文档说没修」的漂移。

### iOS：必须 Apple Developer 账号

无法像 macOS 那样 ad-hoc 凑合——需 $99/年账号 + 签名证书 + 描述文件。

### CI 成本参考（私有仓库 Free 计划 2,000 Linux 分钟/月）

| 平台 | 配额倍数 | 单次构建 | 月 20 次 |
|---|---|---|---|
| Linux | 1× | ~7 min | 140（7%） |
| Android | 1× | ~15 min | 300（15%） |
| Windows | **2×** | ~12 min | 500（25%） |
| macOS | **10×** | ~16 min | **3,200（160% ← 必超额）** |

**结论：Linux + Android + Windows 三端全在免费额度内（约 47%）。macOS 是唯一会花钱的。**

发布流水线据此做了限制：macOS job **只在 tag 触发时跑**（见 `.github/workflows/release.yml`），
PR 与手动触发均不跑——避免日常开发白烧 10× 额度。

### CI / 发布流水线速查

| 文件 | 职责 | 触发 | 产物保留 |
|---|---|---|---|
| `.github/workflows/ci.yml` | **验证**：analyze / format / 12 个守卫 + 7 个自测 / test / 能否构建 | push main + PR | Actions 7 天 |
| `.github/workflows/release.yml` | **交付**：三端出包 + 建 Release | `v*` tag + 手动 | Release 长期 / Actions 30 天 |

⚠️ **两条流水线的产物都会被人下载运行**。`ci.yml` 名义上是「验证能否构建」，
但 artifact 在 Actions 页 7 天内可下载——用户不会区分它和 release 的包。故两边
必须传同一套构建参数（§6.33）。

发布构建的地址参数（API/UFS/webapp/OIDC）由仓库 **Variables** 提供
（Settings → Secrets and variables → Actions → Variables），优先级：
`workflow_dispatch` 输入 > Variables > `SpbEnv` 内置默认值。

> ⚠️ **公开仓库里 Variables 是全局可见的**（与 Secrets 不同）。
> 不要把内网主机名或未公开域名填进去；不宜公开的地址改用 dispatch 输入。

Android 正式签名走 **Secrets**（`ANDROID_KEYSTORE_BASE64` / `ANDROID_STORE_PASSWORD` /
`ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`）；未配置时回退 debug 签名并打印警告。
