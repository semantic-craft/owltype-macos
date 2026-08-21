# 猫头鹰输入法 · Owltype for macOS

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://responsay.com/owltype/)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE.txt)

**English: [README.en.md](README.en.md)** · 产品页：<https://responsay.com/owltype/>

猫头鹰是一个本地优先的 macOS 中文输入法。它把 Rime 引擎与全部词库数据自包含进 App，用 SwiftUI
重做了候选窗、设置、引导与表情面板——装好就能打字，不用手写配置文件。

![猫头鹰候选窗](docs/screenshots/candidates.png)

## 安装

系统要求 macOS 14 及以上，通用二进制（Apple Silicon / Intel）。

1. 从 [responsay.com](https://responsay.com/owltype/Owltype-update.pkg) 下载
   `Owltype-update.pkg`，双击安装（安装包需要管理员授权）。
2. 打开**系统设置 → 键盘 → 输入法**，把「猫头鹰」加进输入法列表。
3. 如果输入菜单里没有立即出现猫头鹰，注销后重新登录一次即可。

已经装过的用户不用重复下载：App 自带 Sparkle 更新客户端，只读取
`responsay.com/owltype/appcast.xml`，检测到新版后下载同一个签名、公证过的
`Owltype-update.pkg` 就地升级，**不需要注销**。更新检查不上传输入内容或用户数据。

卸载：安装包内附 `卸载猫头鹰.command`，或在系统设置里移除输入法后删除
`/Library/Input Methods/Owltype.app`。

## 特性

- **自包含 Rime**——雾凇拼音（全拼 / 小鹤双拼）、极点五笔 86、简繁转换开箱即用，
  不需要手动配置任何 YAML。
- **上下文感知**——记住你的用词习惯，结合上文调整候选顺序；自学习全程在本机。
- **统一设置**——候选个数、简入繁出、皮肤、字体、横竖排等对全拼、双拼与五笔一并生效，
  改完即时或异步部署，不用重启。
- **多套皮肤**——学院风配色，明暗自适应，即时换肤。
- **快捷短语、剪贴板与场景词库**——常用片段随手可取。
- **表情与符号面板**——常驻输入法菜单。
- **可选 AI 助手**——默认关闭，边界见下。

## 界面

九套配色皮肤，明暗跟随系统，选中即时生效：

![皮肤外观](docs/screenshots/skins.png)

换一套皮肤，候选窗随之改变：

![香槟橙（燃橙）皮肤下的候选窗](docs/screenshots/candidates-flame.png)

设置面板按侧栏分页，方案、默认状态、词库都在一处，不用碰 YAML：

![键盘输入设置](docs/screenshots/keyboard-settings.png)

## 隐私边界

- 正常输入、组字、候选生成与词库处理在本机完成。
- 云端 AI 默认关闭；开启后也只会在用户明确触发云端功能时发起请求。
- 云端请求只包含用户主动提交的问题、明确选中的文本和当前对话历史。
- 请求不会附带输入法原始编码、组字、候选词、屏幕内容、窗口或浏览器信息、焦点字段全文、
  光标前后文本等隐式上下文。
- 提供商密钥存入 macOS Keychain，不写入配置文件或仓库。

详见 [PRIVACY.md](PRIVACY.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 当前状态

- **Cursor Origin 是猫头鹰的唯一开发主仓库**：完整产品（含云端 AI 功能层）在
  `https://origin.cursor.com/xianwei/owltype-macos.git` 开发并通过 PR 合并。
  GitHub 保留为私有备份与 issue tracker；签名安装包、Sparkle feed 和逐版对应源码由
  `responsay.com` 发布。
- 仓库历史从经过隐私审查的 1.4.22 源码快照开始，不包含更早期的 Git 历史。
- 1.4.21 及更早的公开发布已经停止分发，不再受支持。
- Windows 版在 [owltype-win](https://github.com/semantic-craft/owltype-win) 维护，代码、tag 与发布资产与本仓库相互独立。

## 从源码构建

需要 Xcode 26+ 与 macOS 14+：

```sh
git clone https://origin.cursor.com/xianwei/owltype-macos.git
cd owltype-macos
git submodule update --init --recursive
make setup-dev
make deps
make release
```

`make setup-dev` 为当前 checkout 启用仓库自带的 pre-push 门禁。推送前会阻止密钥文件、
个人主目录绝对路径、私有仓 remote、非 GitHub noreply 提交身份与 secret scanner 命中。
请把本仓库的 Git email 配置为 GitHub 提供的 noreply 地址；本地密钥使用 Keychain 或
被 `.gitignore` 排除的环境文件保存，不要把 AI 会话、调试日志或本机配置加入 Git。

公开构建使用清洁室词库种子（`scripts/owl-seed.sh`）：只包含授权链可审计的输入，
生成的词表限定在《通用规范汉字表》8105 字内。完整词库由 App 首启时从上游原仓库拉取，
猫头鹰自身不再分发那批数据。种子的逐项来源见构建产物里的 `OWLTYPE-SEED-SOURCES.md`。

签名、公证与打包由 `scripts/release.sh` 处理；验证完成后由
`scripts/owl_distribution.py --publish` 将完整 cohort 发布到 responsay.com。本项目没有托管
CI：合并前的门禁由开发机上的 `scripts/gate.sh` 执行，详见
[docs/operations/ci.md](docs/operations/ci.md)。

## 来源与许可

本项目以 **GPL-3.0** 发布，许可证全文见 [LICENSE.txt](LICENSE.txt)。猫头鹰是
[RIME 鼠须管（Squirrel）](https://github.com/rime/squirrel) 与
[librime](https://github.com/rime/librime) 的派生作品。基于本项目分发二进制时，必须同时提供
对应的修改源码、GPL-3.0 许可证文本与版权声明，不得作为闭源制品分发。
每个二进制版本的完整对应源码可从[官网固定入口](https://responsay.com/owltype/source.tar.gz)取得；
开发仓库保持私有不改变接收者依 GPL 获得、修改和再分发该份源码的权利。

完整来源脉络见 [PROVENANCE.md](PROVENANCE.md)，第三方组件许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 致谢

- [RIME / 中州韻输入法引擎](https://rime.im)——librime 与 Squirrel
- [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice)
- [极点五笔 86](https://github.com/KyleBing/rime-wubi86-jidian)
