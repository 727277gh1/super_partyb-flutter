# 仓库工具

以下命令均在仓库根目录执行。新增脚本在本清单登记，修改守卫时运行对应的
`*_selftest.sh`（如有）；自测脚本不逐个列出，用 `ls tools/` 查看全量。

## 守卫

| 脚本 | 查什么 |
|---|---|
| `tools/check_layering.sh` | 分层规则 |
| `tools/check_format.sh` | dart format 门禁 |
| `tools/check_analysis_options.sh` | analysis_options 接线 |
| `tools/check_test_support_sync.sh` | 重复的测试辅助文件一致 |
| `tools/check_workflow_steps.sh` | workflow step 未被注释吞掉 |
| `tools/check_wiring_parity.sh` | 两端接线一致 |
| `tools/check_unused_deps.sh` | 零 import 依赖 |
| `tools/check_silent_catches.sh` | 静默吞异常 |
| `tools/check_type_tokens.sh` | 字号必须来自 `SpbType` 令牌（禁止裸 `fontSize`、禁止无理由的 `labelSmall`） |
| `tools/check_dollar_paren.sh` | 插值里 `$x(` 误写（分析器抓不到，issue #62） |
| `tools/check_codegen.sh` | 生成物漂移 |
| `tools/check_build_defines.sh` | 发布构建传 `--dart-define` |
| `tools/check_agents_refs.sh` | 文档标识符引用与本清单的 Shell 脚本覆盖 |
| `tools/check_agents_numbers.sh` | 文档数字漂移 |
| `tools/check_agents_size.sh` | AGENTS.md 体积与设计决策索引完整性 |

```bash
for f in tools/check_*.sh; do bash "$f" || break; done
```

## 其他工具

| 脚本 | 用途 |
|---|---|
| `tools/coverage.sh` | 覆盖率采集与汇总 |
| `tools/bundle_linux_deps.sh` | Linux 分发依赖打包 |
| `tools/gen_brand_assets.py` | 品牌图标生成 |
| `tools/build_windows_installer.ps1` | Inno Setup 安装包构建 |
| `tools/reverse_verify_issue50.sh` | 双栈降级变异验证 |
| `tools/sync-to-github.sh` | 导出干净仓库并推送 GitHub |
| `tools/scrub-history.sh` | 开源前清理历史中的真实标识；只重写历史，用法见脚本头 |
