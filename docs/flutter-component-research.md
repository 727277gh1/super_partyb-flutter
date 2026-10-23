# Flutter 组件文档调研（context7）

> 用途：为 `super_partyb-flutter` 的客户端功能实现提供**官方文档依据**。
> 只留结论与最小可用片段，不复制大段文档。
>
> 调研工具：`uv run $HOME/.pi/agent/skills/context7/scripts/context7_search.py`
> （`--check-auth` 已通过）。命令可复现，库 ID 与版本见下表。

---

## 0. 库 ID / 版本对照

| 主题 | context7 library-id | 文档版本 / 最后更新 | 本仓库实际版本 |
|---|---|---|---|
| go_router | `/flutter/packages`（StatefulShellRoute 真源）、`/websites/pub_dev_packages_go_router` | 2026-08-13 | `go_router 16.3.0` |
| Riverpod | `/rrousselgit/riverpod` | `riverpod-v3.0.2`（2026-09-27） | `flutter_riverpod 3.4.3` |
| Flutter 框架（Material / 滚动 / 输入） | `/flutter/website`、`/websites/api_flutter_dev` | `__branch__main`（2026-09-26） | Flutter 3.47.5 / Dart 3.13.4 |
| Material 组件示例 | `/material-components/material-components-flutter` | 2026-09-21 | 随 Flutter SDK |
| dio | `/cfug/dio`（源码 README 最权威）、`/websites/pub_dev_dio` | 2026-09-22 | `dio 5.11.1` |

复现命令（任一）：

```bash
timeout 180 uv run $HOME/.pi/agent/skills/context7/scripts/context7_search.py \
  search --library go_router --topic StatefulShellRoute
timeout 180 uv run $HOME/.pi/agent/skills/context7/scripts/context7_search.py \
  docs --library-id /flutter/packages --topic "go_router StatefulShellRoute"
```

> 坑：`docs --library-id /websites/pub_dev_packages_go_router --topic "StatefulShellRoute.indexedStack"`
> 会返回 `404 Not Found`——该库是 pub.dev 页面镜像，只收录 example 级片段。
> **查 go_router 的 StatefulShellRoute 必须用 `/flutter/packages`**（`doc/configuration.md`
> 与 `doc/state-restoration.md` 是其真源）。

---

## 1. go_router 16.x

### 1.1 路由表 + `MaterialApp.router`

来源：`/websites/pub_dev_packages_go_router` → `pub.dev/packages/go_router/example`

```dart
final GoRouter _router = GoRouter(
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      builder: (BuildContext context, GoRouterState state) => const HomeScreen(),
      routes: <RouteBase>[
        GoRoute(path: 'details', builder: (context, state) => const DetailsScreen()),
      ],
    ),
  ],
);

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp.router(routerConfig: _router);
}
```

### 1.2 `StatefulShellRoute` 分支（移动端底部导航 / 桌面端侧边栏）

来源：`/flutter/packages` → `packages/go_router/doc/configuration.md`

```dart
branches: <StatefulShellBranch>[
  StatefulShellBranch(
    navigatorKey: _sectionANavigatorKey,
    routes: <RouteBase>[
      GoRoute(path: '/a', builder: (context, state) => const SectionA()),
    ],
  ),
],
```

`StatefulShellRoute.indexedStack` 还支持 `restorationScopeId`（来源
`packages/go_router/doc/state-restoration.md`），可为 shell 与每个 branch 保留导航栈：

```dart
StatefulShellRoute.indexedStack(
  restorationScopeId: 'appShell',
  pageBuilder: (context, state, navigationShell) =>
      MaterialPage(restorationId: 'appShellPage', child: AppShell(navigationShell: navigationShell)),
  branches: [ /* ... */ ],
)
```

**本项目采纳结论**

- 两个 app 用 `MaterialApp.router(routerConfig: ...)` + 顶层 `GoRouter`。
- 桌面端（宽屏）用「列表 + 内容」两栏布局，**不用** `StatefulShellRoute`——侧边栏只是
  布局而非独立导航栈，引入 shell 反而让「点列表项切换对话」多一层 navigator。
- 移动端（窄屏）如需底部标签栏，再用 `StatefulShellRoute.indexedStack`。
- 路由形态：`/`（对话列表）、`/chat/:groupId`（时间线）、`/quick-capture`（悬浮输入窗）、
  `/settings`（占位）。`groupId` 用 path 参数，`state.pathParameters['groupId']` 读取。

---

## 2. Riverpod 3.x

### 2.1 `FutureProvider` 用 `ref.watch` 组合依赖

来源：`/rrousselgit/riverpod` → `packages/riverpod/dartdoc/providers.md`

```dart
final weatherProvider = FutureProvider((ref) async {
  final city = ref.watch(cityProvider); // 依赖变化时自动重算
  return fetchWeather(city: city);
});
```

### 2.2 `ConsumerWidget` + `AsyncValue` 分支

来源：`/rrousselgit/riverpod` → `README.md`、`website/docs/how_to/pull_to_refresh.mdx`

```dart
class Home extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(boredSuggestionProvider);
    return switch (value) {
      AsyncData(:final value) => Text('data: $value'),
      AsyncError(:final error) => Text('error: $error'),
      _ => const Text('loading'),
    };
    // 等价写法：value.when(data: ..., error: ..., loading: ...)
  }
}
```

### 2.3 生命周期：`ref.onCancel` / `ref.onDispose`

来源：`/rrousselgit/riverpod` → `website/docs/from_provider/provider_vs_riverpod.mdx`

```dart
ref.onCancel(() => print('No one listens to me anymore!'));
ref.onDispose(() => print('If autoDispose, I just got disposed!'));
```

> 3.0 修复了 2.0 的坑：**异步 provider 在 `await` 之后 watch autoDispose provider
> 不再被意外销毁**（`website/docs/whats_new.mdx`）。`autoDispose` 默认关闭
> 需要 `@Riverpod(keepAlive: true)` 或 `.autoDispose` 后缀，代码生成与手写两种风格
> 行为一致（`website/docs/concepts2/auto_dispose.mdx`）。

**本项目采纳结论**

- **不启用 `riverpod_generator`**：本仓库 `.gitignore` 忽略 `*.g.dart`，引入代码生成
  会让 `dart analyze` 在未跑 `build_runner` 时失败。全部手写 provider。
- `dioProvider` / `chatApiProvider` / `sseClientProvider` / `currentUserProvider` 用普通
  `Provider` / `FutureProvider`（进程级单例，不 autoDispose）。
- `chatStreamControllerProvider` 用 `Provider.autoDispose` + `ref.onDispose(() => c.dispose())`
  ——它持有 SSE 长连接，页面退出必须断开，否则后台持续耗电/占连接。
- `currentUserProvider`（`GET /api/auth/me`）用 `FutureProvider`，`ref.watch` 取 userId，
  **不要在 UI 里手写「先 await 拿 id 再发第二条请求」**——让 Riverpod 缓存这次结果。
- 测试用 `ProviderScope(overrides: [...])` 注入 fake，禁止真实网络（见
  `website/docs/whats_new.mdx` 的 `Override scoped provider with ProviderScope`）。

---

## 3. Material 3 组件

### 3.1 `ListView.builder` + `ScrollController`

来源：`/flutter/website` → `sites/docs/src/content/release/breaking-changes/default-scroll-behavior-drag.md`

```dart
final ScrollController controller = ScrollController();
ListView.builder(
  controller: controller,
  itemBuilder: (BuildContext context, int index) => Text('Item $index'),
);
```

> 桌面端要点：Flutter 默认 `ScrollBehavior.dragDevices` **不含鼠标拖拽**，
> 需自定义 `MaterialScrollBehavior.dragDevices` 并套 `ScrollConfiguration`
> （同一文档来源）。触控板/滚轮不受影响。

### 3.2 `TextField` 自适应与 `InputDecoration`

来源：`/flutter/website` → `sites/docs/src/content/ui/adaptive-responsive/platform-adaptations.md`

```dart
final _border = OutlineInputBorder(
  borderSide: BorderSide(color: CupertinoColors.lightBackgroundGray),
);
final iOSDecoration = InputDecoration(
  border: _border, enabledBorder: _border, focusedBorder: _border,
  filled: true, fillColor: CupertinoColors.white,
  contentPadding: EdgeInsets.fromLTRB(10, 0, 0, 0),
);
```

`TextField` 的提交回调类型见 `/websites/api_flutter_dev`：`onFieldSubmitted` 与
`AutocompleteFieldViewBuilder = Widget Function(BuildContext, TextEditingController,
FocusNode, VoidCallback)`。

### 3.3 Chip / BottomSheet（M3）

来源：`/flutter/website`（Flutter 3.13 release notes）+ `/material-components/material-components-flutter`

- `FilterChip.elevated` / `ChoiceChip.elevated` / `ActionChip.elevated` 是 M3 新增变体。
- `showBottomSheet(context: context, builder: ...)`：用 `Wrap` 包裹内容，否则默认高度是屏幕一半。

**本项目采纳结论**

- 对话时间线用 `ListView.builder` + **稳定 `ValueKey(item.id)`**（归约层已保证 id 稳定），
  配 `ScrollController` 在新增项后 `animateTo(maxScrollExtent)`；用 `SpbDuration.fast`
  而非硬编码时长。
- **不要**在时间线里用 `SpbSpacing.lg` 之外的魔法数；间距/圆角一律取
  `spb_design` 的 `SpbSpacing` / `SpbRadius` / `SpbDuration`。
- 输入框用主题里已配好的 `inputDecorationTheme`（`spb_design/lib/src/theme.dart`
  已设 `isDense: true` + `SpbRadius.inputAll`），组件里**不要再传 `border`**，
  否则覆盖主题造成风格漂移。
- `follow_up_suggested` 的建议列表用 `ActionChip`（点击即发送）；`ConfirmationItem`
  的选项用 `Card` + 按钮，不用 `showBottomSheet`——桌面端悬浮窗场景下 bottom sheet
  的模态行为与「置顶小窗」冲突。
- 移动端若要底部弹层，用 `showModalBottomSheet` 并在内容外包 `Wrap`。

---

## 4. dio 5.x 流式读取与错误映射

### 4.1 `ResponseType.stream`

来源：`/cfug/dio` → `dio/README.md`

```dart
final rs = await dio.get(
  url,
  options: Options(responseType: ResponseType.stream),
);
print(rs.data.stream); // Response stream.
```

`ResponseType` 取值语义（同一来源的 dartdoc）：`json`（默认，按 content-type 自动解析）、
`plain`（String）、`bytes`（完整字节）、`stream`（**流式二进制字节**）。

### 4.2 本项目既有实现（无需改）

`packages/spb_api/lib/src/sse_client.dart` 已经手写了 SSE 解析（`dio.get` +
`ResponseType.stream` + 逐帧拆分 `event:`/`data:`/空行 + `: heartbeat` 注释行），
并在 `auth_interceptor.dart` 里用 `mapDioError` 把 `DioException` 统一映射为
`SpbError` 家族（`NetworkError` / `HttpError` / `ParseError` / `AuthError`）。

**本项目采纳结论**

- **不引入新的 SSE/流式依赖**（AGENTS.md §6.1 已定「实时流统一 SSE」，且禁 WebSocket）。
- `createDio` 的 `validateStatus: (s) => s < 500` 意味着 4xx **不会**抛 `DioException`，
  调用方必须自行判 `res.statusCode`；5xx 才走 `onError` → `mapDioError`。
  新增 API 方法沿用既有的 `_get/_post/_patch/_delete` 私有辅助，不绕过统一错误映射。
- 测试用已声明的 `http_mock_adapter 0.6.1` 造响应，**断言请求体形状**（例如
  quick-capture 只允许 `{'input': ...}`），而非只断言返回解析结果。

---

## 5. 待后续任务验证的假设

1. `StatefulShellRoute` 在移动端的实际效果未在本机验证（无 Android 模拟器 / 无 DISPLAY）。
2. 桌面端鼠标拖拽滚动需自定义 `ScrollBehavior`——本轮只加代码，交互无法本地验证。
3. `riverpod 3.4.3` 的 `AsyncValue` 模式匹配（`switch` + `AsyncData(:final value)`）
   语法基于 Dart 3 的模式匹配，需在 `dart analyze` 下确认无 lint 报错。
