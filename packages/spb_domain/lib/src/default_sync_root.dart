/// 默认的交付物同步目录（用户**从未选过**目录时使用的那个）。
///
/// ## 为什么需要默认目录
///
/// 此前 `localRoot` 的语义是「null = 尚未选择，此时不能同步」
/// （见 `spb_domain` 的 `SyncSettings.localRoot`）。于是首次启动的用户必须先进设置页选一个
/// 目录，否则：
///
/// - 托盘「立即同步交付物」是**禁用**的（`isSyncConfigured` 为 false）；
/// - 「进入对话时按需同步」被 `canSync` 门控跳过；
/// - 设置页显示「尚未选择（点右侧按钮选择）」。
///
/// 用户报障原话是「同步目录如果没选的话给个默认设置」——即**功能看起来不存在**。
/// 有一个可见的默认目录后，打开对话就能同步，用户想换再换。
///
/// ## 为什么优先 `~/Documents/Super PartyB`
///
/// 同步目录的价值是「用户能自己打开它」（编辑器 / 资源管理器 / 脚本）。
/// 藏在 `$XDG_DATA_HOME` 下的 `.local/share/...` 是**隐藏目录**——用户可以
/// 找得到但看不见，与「交付物放到我电脑上」的预期不符。
///
/// 但 `~/Documents` 并不总存在（精简容器、某些 Windows 账号被重定向到
/// OneDrive 且本地无该目录）。故：
///
/// | 顺序 | 条件 | 结果 |
/// |---|---|---|
/// | 1 | `SPB_SYNC_ROOT` 非空 | 直接用它（便携部署 / 测试 / 运维指定） |
/// | 2 | `<home>/Documents` **存在** | `<home>/Documents/Super PartyB` |
/// | 3 | 有应用数据目录 | `<data>/super_partyb/deliverables` |
/// | 4 | 连 home 都没有 | `null`（调用方按「未配置」处理，不会崩） |
///
/// ## 为什么是纯函数、参数全部显式
///
/// 判据（哪一条命中）是**正确性核心**：判错会让文件落到用户找不到的地方，
/// 或让「同步成功」变成「文件在某个谁也不看的角落」。而 `Platform.environment`
/// 与 `Directory.existsSync` 在测试里都要注入才能覆盖各分支，故一切外部状态
/// 走参数：缓存环境、`documentsExists` 由调用方（装配层）探测。
///
/// ## 已知边界
///
/// - **不持久化**：默认值每次纯计算得出，不写进 `sync_bindings`。这样「换机器
///   / 换 HOME」不会把旧机器的绝对路径带过来；代价是用户把目录清空后无法
///   表达「我要一个空目录」，会**静默回落到默认值**（设置页保存时会把默认值
///   落盘，故实际影响仅限「清空后立刻观察」）。
/// - **不感知本地化目录名**：Windows 上「文档」的真实路径可能是
///   `<home>/OneDrive/Documents`，本函数只看 `<home>/Documents`。探测不到就
///   落到应用数据目录——不会错，只是不够显眼。
library;

/// 默认同步目录里那一层「按产品名」的子目录名。
const String defaultSyncFolderName = 'Super PartyB';

/// 计算默认同步目录。返回 `null` 表示**给不出**（调用方应视作未配置）。
///
/// [documentsExists] 由调用方探测（本函数不碰文件系统，便于逐分支单测）。
String? defaultSyncLocalRoot({
  required Map<String, String> environment,
  required bool isWindows,
  bool documentsExists = false,
}) {
  final override = environment['SPB_SYNC_ROOT']?.trim();
  if (override != null && override.isNotEmpty) return override;

  final home = (isWindows ? environment['USERPROFILE'] : environment['HOME'])
      ?.trim();
  final hasHome = home != null && home.isNotEmpty;

  if (hasHome && documentsExists) {
    return '$home/Documents/$defaultSyncFolderName';
  }

  final String? dataBase;
  if (isWindows) {
    final appData = environment['APPDATA']?.trim();
    dataBase = (appData != null && appData.isNotEmpty)
        ? appData
        : (hasHome ? '$home/AppData/Roaming' : null);
  } else {
    final xdgDataHome = environment['XDG_DATA_HOME']?.trim();
    dataBase = (xdgDataHome != null && xdgDataHome.isNotEmpty)
        ? xdgDataHome
        : (hasHome ? '$home/.local/share' : null);
  }
  if (dataBase == null || dataBase.isEmpty) return null;

  return '$dataBase/super_partyb/deliverables';
}
