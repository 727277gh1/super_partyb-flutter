import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';

/// 移动端应用根组件。
///
/// 当前为 M0 骨架，与桌面端共用 `spb_design` 主题与 `spb_features` 页面，
/// 差异仅在导航形态（底部标签栏 vs 侧边栏）与平台能力。
class SpbMobileApp extends StatelessWidget {
  const SpbMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Super PartyB',
      debugShowCheckedModeBanner: false,
      theme: SpbTheme.light(),
      darkTheme: SpbTheme.dark(),
      home: const _PlaceholderPage(),
    );
  }
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Super PartyB')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('移动端骨架已就绪', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                '与桌面端共用 spb_core / spb_models / spb_api / spb_domain /\n'
                'spb_design / spb_ui / spb_features。\n\n'
                '差异收敛在 spb_platform（桌面能力为空实现）。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
