# 法墨输入法 · Famotype for macOS

法墨是一个现代化的 macOS 系统输入法。它把 Rime 引擎与数据自包含进 App，并用
SwiftUI 重做候选窗、设置、引导与表情符号面板。

> 仓库名为 **Famotype**；为保持已安装版本兼容，代码、Bundle 与构建产物中仍使用 `Famo` 标识。

## 当前状态

- 本仓库是法墨的**唯一开发仓库**：完整产品（含云端 AI 功能层）在此公开开发，
  签名安装包与 Sparkle 更新也从本仓库的 Releases 发布。
- 仓库历史从经过隐私审查的 1.4.22 源码快照开始，不包含更早期的 Git 历史。
- 1.4.21 及更早的公开发布已经停止分发，不再受支持。

## 隐私边界

- 正常输入、组字、候选生成与词库处理在本机完成。
- 云端 AI 默认关闭；开启后也只会在用户明确触发云端功能时发起请求。
- 云端请求只包含用户主动提交的问题、明确选中的文本和当前对话历史。
- 请求不会附带输入法原始编码、组字、候选词、屏幕内容、窗口或浏览器信息、焦点字段全文、
  光标前后文本等隐式上下文。
- 提供商密钥存入 macOS Keychain，不写入配置文件或仓库。

详见 [PRIVACY.md](PRIVACY.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 特性

- **自包含 Rime**：雾凇拼音、极点五笔 86、小鹤双拼、繁体转换等，无需手动配置。
- **全局设置**：候选个数、简入繁出等对全拼、双拼与五笔统一生效。
- **SwiftUI 界面**：键盘输入、候选窗外观、皮肤、快捷短语、剪贴板、场景词库与可选 AI 助手。
- 表情与符号面板常驻输入法菜单。

## 构建

需要 Xcode 26+ 与 macOS 14+：

```sh
git submodule update --init --recursive
make deps
make release
```

签名、公证与打包由 `scripts/release.sh` 处理；完整发布编排另有对应源码、manifest 与人工验收门。

## 来源与许可

本项目以 **GPL-3.0** 发布，许可证全文见 [LICENSE.txt](LICENSE.txt)。法墨是
[RIME 鼠须管（Squirrel）](https://github.com/rime/squirrel) 与
[librime](https://github.com/rime/librime) 的派生作品。基于本项目分发二进制时，必须同时提供
对应的修改源码、GPL-3.0 许可证文本与版权声明，不得作为闭源制品分发。

完整来源脉络见 [PROVENANCE.md](PROVENANCE.md)，第三方组件许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 致谢

- [RIME / 中州韻输入法引擎](https://rime.im)——librime 与 Squirrel
- [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice)
- [极点五笔 86](https://github.com/KyleBing/rime-wubi86-jidian)
