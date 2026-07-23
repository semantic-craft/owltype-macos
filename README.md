# Famotype for macOS

> 你的输入法，应该先把字打好。

Famotype（法墨）是一款基于 Rime 的 macOS 中文输入法。它把输入核心、候选窗和设置界面放在本机，
专注于稳定的中文输入、清晰的候选反馈和可理解的配置。

当前仓库是首个开源核心的预发布版本。源码可审查、可构建，但在第三方许可证归属清单和独立安装流程
完成最终验证前，不提供公开二进制。

## 现在包含什么

- 全拼与双拼输入，支持简繁转换；
- 原生 InputMethodKit 会话与 librime 引擎；
- SwiftUI 候选窗、横排/竖排、字体、候选数和主题设置；
- 本地快捷短语、提示词、表情符号和场景词库；
- 模糊音、翻页键、标点和中英文状态等本地配置；
- 默认拒绝的隐私边界和不含正文的诊断日志。

## 明确不包含什么

首个开源核心不包含云端 AI、联网搜索、辅助功能划词、剪贴板历史、全局键盘事件监听、自动更新，
也没有网络客户端 entitlement。极点五笔数据和 octagram 语法模型数据在授权链完成复核前不进入
开源 seed 或公开二进制。

快捷短语热键只在 Famotype 已是当前输入法、按键交给 InputMethodKit 时生效；程序不会安装
session-wide event tap。

## 构建

要求 macOS 14 或更高版本，以及当前稳定版 Xcode。

```bash
git clone --recursive https://github.com/semantic-craft/famotype-macos.git
cd famotype-macos
make bootstrap
make famo-seed
make debug
```

`make bootstrap` 只从 librime 的官方 GitHub Release 获取固定版本构建依赖；
`make famo-seed` 只获取固定提交的 rime-ice，并把其许可证和 Credits 一并放入本地生成的 seed。

## 隐私设计

- 用户数据目录权限为 `0700`，含用户文本或配置的文件权限为 `0600`；
- 组字、候选、提示词和场景词库留在本机；
- 日志只记录阶段、计数、长度和状态，不记录原始编码、候选或提交正文；
- 没有云端请求代码、选区读取器或剪贴板历史存储。

完整边界见 [PRIVACY.md](PRIVACY.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。
准备公开前还必须逐项通过 [公开发布清单](docs/PUBLISHING_CHECKLIST.md)；源码公开与二进制发布是两道独立的门。

## 许可证与来源

Famotype 的项目代码按 `GPL-3.0-only` 发布；各上游组件保留其各自许可证。
来源锁与再分发义务见 [PROVENANCE.md](PROVENANCE.md) 和
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。任何许可证不明确的数据都不会进入公开产物。

## English

Famotype is a local-first Chinese input method for macOS, built with InputMethodKit, librime and
SwiftUI. The initial open-source core includes Pinyin, double-Pinyin, local phrases, prompts,
themes and diagnostics. It intentionally excludes cloud AI, selection readers, clipboard history,
global event taps, automatic updates and network entitlements.
