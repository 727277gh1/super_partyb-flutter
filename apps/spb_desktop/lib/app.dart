import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';

/// 应用根组件。
///
/// 当前为 M0 骨架：只渲染一个状态页，用于验证
/// 「依赖解析 + 分层编译 + 桌面窗口能起来」。
/// 真实路由（go_router）与页面在 M1 接入 `spb_features`。
class SpbDesktopApp extends StatelessWidget {
  const SpbDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Super PartyB',
      debugShowCheckedModeBanner: false,
      theme: SpbTheme.light(),
      darkTheme: SpbTheme.dark(),
      home: const _ScaffoldPage(),
    );
  }
}

class _ScaffoldPage extends StatelessWidget {
  const _ScaffoldPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Super PartyB'), centerTitle: false),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('桌面端骨架已就绪', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                'M0 阶段目标：验证分层架构可编译、依赖可解析、'
                '桌面窗口能启动。\n\n'
                '下一步接入：\n'
                '  • OIDC PKCE 登录（经 api-gateway）\n'
                '  • SSE 实时对话流\n'
                '  • 多窗口 + 托盘 + 全局快捷键\n'
                '  • 交付物同步',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
