# 法墨输入法开源许可证审计

审计日期：2026-07-23  
审计对象：`macos/FamoInputMethod`（审计开始时 `43f1e05349a9b3abdc57521105372a7fbf6cabd4`）、当前构建脚本，以及本机已安装的 Famo 1.4.21。  
目标许可：项目整体按 **GPL-3.0-only** 发布。  
证据规则：许可证结论只采用上游官方仓库的固定提交文件、官方发布资产元数据和本仓实际构建/打包结果；没有一手证据的事项保持为“未确认”。

> 本文是工程合规审计，不替代律师出具的法律意见。

## 结论

**当前状态：私有完整产品树不应重新发布二进制；计划中的最小本地核心仓也尚未达到公开放行条件。源码仓库可以继续整理，但不能宣称第三方许可已经完全收口。**

已识别的许可证本身（GPLv3、LGPLv3、Apache-2.0、BSD、MIT、BSL-1.0 等）原则上都能与 GPL-3.0-only 项目共同分发；真正的阻断项是：一个插件许可证写错、二进制没有随附多项必须保留的许可/版权文本、GPL 插件的精确对应源码没有进入发布源码包、rime-ice 的再分发归属没有随附，以及极点五笔底表的授权链仍不明确。

## 两个审计范围必须分开

本报告随后保留“当前私有完整树”的完整依赖账本，因为 Famo 1.4.21 曾经公开分发；仓库改回 private 不会消除已经发生的二进制再分发义务。计划中的新仓 `semantic-craft/famotype-macos` 则按 [`open-source-export-policy.md`](open-source-export-policy.md) 生成一个不含网络、辅助功能选区/剪贴板、Sparkle 和发布运营面的新历史。两者的许可证范围如下。

### A. 当前私有完整产品树及已分发 1.4.21

适用本报告全部清单，包括：

- Famo/Squirrel、librime 及静态依赖；
- librime-lua、librime-octagram、librime-predict；
- rime-ice、极点五笔、OpenCC、octagram data、plum；
- **Sparkle 2.6.2 及其完整 external licenses**；
- 私有树中的 AI/联网、AX 选区、剪贴板和发布脚本（这些主要是隐私/运营边界；当前未发现它们新增独立第三方代码库）。

只要再次向组织外提供完整 App/PKG/DMG，就必须先修复本报告所有 P0。旧 1.4.21 已分发产物缺许可文本和 GPL 插件对应源码的问题，应通过撤回说明、同版本修复版 license/source bundle 和长期可访问的源码链接补救；把仓库设为 private 不是补救手段。

### B. `famotype-macos` 首发最小本地核心

导出策略要求物理删除而非“默认关闭”以下面，因此它们**不进入首发核心许可证账本**：

| 排除面 | 对首发核心许可证的影响 |
|---|---|
| 云端供应商、联网搜索、AI 会话和真实 key live tests | 当前均为 Famo 自有 Swift/测试逻辑；删除主要降低隐私与密钥风险，不减少已识别的 RIME 第三方栈 |
| AX 选区观察、文本插入、剪贴板历史 | 当前使用 Apple 系统框架且为 Famo 自有实现；删除主要降低隐私/TCC 风险 |
| Sparkle 子模块、更新 UI/控制器接线 | **首发核心可完全移除 Sparkle、Sparkle MIT 和其 external-license 随附义务**，前提是 Git 索引、Xcode project、链接产物和 App bundle 均无 Sparkle 残留 |
| 签名、公证、appcast、release CI 和真实供应商联调 | 当前为 Famo 自有运营代码；从公开树排除，不改变核心运行时第三方许可证 |

首发核心白名单仍明确包含 InputMethodKit + librime、全拼/双拼/五笔、简繁转换和本地 seed。因此下列依赖与动作**仍然必须保留**：

| 首发核心必需面 | 仍需履行的许可证/动作 |
|---|---|
| Famo/Squirrel | GPL-3.0-only；提供完整对应源码、修改说明、构建/安装信息和 GPL 文本 |
| librime + Boost/glog/LevelDB/marisa/OpenCC/yaml-cpp/Darts/UTF8-CPP/X11/RapidJSON | 保留各 BSD/MIT/Apache/BSL/内嵌许可全文和版权声明 |
| rime-ice | GPL-3.0-only；同时保留固定快照 Credits 以及 Unicode、CC BY、MIT、Apache、LGPL、GPL 分项归属 |
| 极点五笔 | Apache-2.0；但底表授权链未确认，仍是首发阻断 |
| librime-lua + Lua | 只要 rime-ice/Wubi 的 Lua 功能仍启用就属于核心；BSD-3 + Lua MIT，并固定 Lua 来源 SHA |
| librime-octagram + octagram data | 当前 seed 的 `rime_ice.custom.yaml` 启用 grammar 且打包 `.gram`，所以默认仍属于核心；GPL-3.0 + LGPL-3.0，必须给精确插件源码和数据许可。若首发不需要语法模型，必须同时从配置、插件 copy phase、seed、构建产物和 README 物理删除，才可从账本移除 |
| librime-predict | 当前 Xcode copy phase 会打包；若核心不用预测插件，应物理删除引用和 dylib。保留则附 BSD-3 全文 |
| plum / `rime-install` | 当前 App 会复制 `rime-install`；若最小核心改成只用已锁定 seed，可从 App 和公开构建链物理删除。保留则履行 LGPLv3、固定来源并提供对应源码 |

因此，首发核心的最小许可放行条件不是“删掉 Sparkle 即可”，而是：完成 Squirrel/librime/Rime 数据栈的 license bundle；修复 octagram 许可和对应源码；补 rime-ice Credits；解决 Wubi 底表授权；把所有保留依赖固定到完整 SHA。只有最终导出树和最终 `.app` 的反查结果才能决定某一项是否真的从账本消失。

## 发布阻断项

### P0-1：`librime-octagram` 被误写成 BSD-3-Clause

当前 `THIRD_PARTY_NOTICES.md` 把 `librime-lua / librime-octagram / librime-predict` 三者一起写成 BSD-3-Clause。实际固定构建版本中：

- `librime-lua` `ec52e48ea18f11af37717a01c337f853215cf70b`：BSD-3-Clause；
- `librime-octagram` `dfcc15115788c828d9dd7b4bff68067d3ce2ffb8`：**GNU GPL v3 全文**；未找到“or later”授权语句，应保守按 GPL-3.0-only 处理；
- `librime-predict` `920bd41ebf6f9bf6855d14fbe80212e54e749791`：BSD-3-Clause。

一手证据：[librime-lua LICENSE](https://github.com/hchunhui/librime-lua/blob/ec52e48ea18f11af37717a01c337f853215cf70b/LICENSE)、[librime-octagram LICENSE](https://github.com/lotem/librime-octagram/blob/dfcc15115788c828d9dd7b4bff68067d3ce2ffb8/LICENSE)、[librime-predict LICENSE](https://github.com/rime/librime-predict/blob/920bd41ebf6f9bf6855d14fbe80212e54e749791/LICENSE)。

处置：立即拆开三项登记；`librime-octagram` 标为 GPL-3.0-only，并把其精确对应源码纳入每个二进制版本的源码交付。

### P0-2：已安装二进制没有完整随附必须保留的许可证与版权文本

本机 `/Library/Input Methods/Famo.app` 1.4.21 中只找到：

- `Contents/Resources/LICENSE.txt`；
- `Contents/Resources/THIRD_PARTY_NOTICES.md`；
- `Contents/SharedSupport/rime-ice.LICENSE`；
- `Contents/SharedSupport/wubi86-jidian.LICENSE`。

没有随附 librime、三个插件、Sparkle（含其内含第三方代码）、OpenCC、plum、octagram data、Boost、glog、LevelDB、marisa、yaml-cpp、Lua、Darts、RapidJSON、UTF8-CPP、X11 keysyms 等对应的完整版权/许可文本。仅在 Markdown 表格里写许可证名称并链接上游，不满足 BSD/MIT/Apache 等许可证要求的“在二进制分发的文档或其他材料中重现版权声明和条款”。

处置：建立受版本控制的 `LICENSES/`（或等价目录），将本报告列出的固定版本许可文本原样收录；构建时把整个目录复制进 `Famo.app/Contents/Resources/Licenses/`，并在安装器、DMG 和源码包中一并提供。Sparkle 必须收录其完整 `LICENSE`，因为该文件还列出 bsdiff、sais-lite、Ed25519、`SUSignatureVerifier.m` 的再分发条款。

### P0-3：GPL 插件没有可验证的精确对应源码交付

`action-install.sh` 下载 librime 1.17.0 官方预编译包；其 `version-info.txt` 记录：

```text
RIME_PLUGINS=hchunhui/librime-lua lotem/librime-octagram rime/librime-predict
librime 33e7814
hchunhui/librime-lua ec52e48
lotem/librime-octagram dfcc151
rime/librime-predict 920bd41
```

但是 `download/` 被 gitignore，插件源码也不是 App 仓库的子模块。当前发布源码组合脚本会归档 App 的 tracked tree 和生成的 `famo-rime` seed，但不会把这三个插件的源码放入源码包。对 BSD 插件这是可复现性缺口；对 **GPL-3.0 `librime-octagram`** 则是对应源码交付阻断。

处置：

1. 把完整插件 SHA 写入受版本控制的锁文件，而不是只留在 ignored 下载目录；
2. 发布源码包必须包含 `librime-octagram@dfcc151…` 的完整首选修改形式、构建脚本和其许可证，或在与二进制完全相同的下载位置提供可长期取得的精确源码包；
3. 最稳妥的做法是把三个插件都作为固定 SHA 的子模块/源码归档纳入 release composition，并让 CI 断言二进制 `version-info` 与锁文件一致。

官方资产与固定来源：[librime 1.17.0 release](https://github.com/rime/librime/releases/tag/1.17.0)、[librime-octagram 固定源码](https://github.com/lotem/librime-octagram/tree/dfcc15115788c828d9dd7b4bff68067d3ce2ffb8)。

### P0-4：rime-ice 的上游归属链没有随分发保留

Famo seed 从 rime-ice 固定快照复制 `cn_dicts/`、`en_dicts/`、`lua/`、`opencc/`、schemas 和 dictionaries；当前只复制了根 `LICENSE`，没有复制 rime-ice 的 `others/docs/Credits.md`。该 Credits 文件明确列出再利用来源，包括：

- Unicode Unihan（Unicode License v3）；
- `rime-essay-simp`（LGPL-3.0）；
- THUOCL（MIT）；
- 腾讯词向量整理数据（CC BY 3.0）；
- `rime-melt`（Apache-2.0）；
- `rime-radical-pinyin`（GPL-3.0）；
- `librime-lua-script` 的 Unicode 脚本（MIT）；
- `98wubi` 的数字/人民币脚本（LGPL-3.0）。

其中 CC BY 3.0 明确要求署名、许可证链接及修改说明；仅携带 rime-ice 的 GPL 文本不能替代这些要求。

一手证据：[rime-ice 固定快照 Credits](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/others/docs/Credits.md)、[rime-ice 固定快照 LICENSE](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/LICENSE)、[rime-ice README 的 GPL-3.0-only 声明](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/README.md#许可证)。

处置：至少原样随附固定快照的 `Credits.md`，并在总 NOTICE 中保留其来源、作者、许可链接和 Famo 的修改说明；把适用于实际复制文件的 Unicode、CC BY 3.0、MIT、Apache-2.0、LGPL-3.0、GPL-3.0 文本一并收录。若无法确认某个聚合词典的精确来源和授权，应从 seed 移除该词典而不是猜测许可。

### P0-5：极点五笔底表的授权链不完整

Famo 使用的 `KyleBing/rime-wubi86-jidian@a194fb8…` 根仓库明确提供 Apache-2.0，Famo 也保存了该 LICENSE；这部分表面许可兼容 GPLv3。可是该仓 README 同时声明其单字顺序“严格对标原极点输入法词库”，并链接 `KyleBing/wubi-jidan-dict`。被链接的官方 GitHub 仓库在审计时没有 LICENSE，GitHub API 也返回 `license: null`。

一手证据：[rime-wubi86-jidian 固定 README](https://github.com/KyleBing/rime-wubi86-jidian/blob/a194fb8b3ec41ef9dcf079d3a67876fa75f79135/README.md)、[其 Apache-2.0 LICENSE](https://github.com/KyleBing/rime-wubi86-jidian/blob/a194fb8b3ec41ef9dcf079d3a67876fa75f79135/LICENSE)、[无 LICENSE 的 wubi-jidan-dict 仓库](https://github.com/KyleBing/wubi-jidan-dict)。

不能从“GitHub 上可见”推断底表允许再分发，也不能仅凭下游仓库的 Apache 文件判断下游作者有权再许可原始极点码表。

处置（三选一）：取得上游维护者关于底表权利来源和 Apache 再许可权限的可公开确认；改用来源与开放许可清楚的五笔码表；或在发布版中移除这套五笔数据。确认前按发布阻断处理。

### P0-6：项目自己的许可证表达冲突

当前 README、PROVENANCE 与 notices 只写“GPLv3 / GPL-3.0”，而 installer 的 `Info.plist` 与 `project.yml` 写的是 **`GPL-3.0-or-later`**。本次目标却是 **GPL-3.0-only**。仅放一份 GPLv3 全文不能自动说明项目选择的是 only 还是 or-later。

处置：由版权人明确选择一个表达；若选择本报告目标 `GPL-3.0-only`，则统一 README、PROVENANCE、安装器 metadata、源码文件头、仓库 metadata 和 SPDX 标识。不要在没有所有相关版权人授权的情况下把既有代码从 only 改为 or-later。

### P0-7：构建输入仍有浮动分支，许可清单不能稳定复现

- `famo-seed.sh` 对 rime-ice 和 wubi 执行 `git clone --depth 1`，没有 checkout 固定 SHA；生成 manifest 虽记录当次 SHA，但下一次构建会漂移。
- `plum/rime-install` 会更新包仓库；octagram data 的 `master`、`hans`、`hant` 三个分支没有在构建配置中固定提交。
- `librime-lua/action-install.sh` 从 `thirdparty` 浮动分支克隆 Lua 源码。根据官方 release 时间与分支历史，可推断 librime 1.17.0 资产使用当时分支头 `fa40fadd…`（Lua 5.4.8），但下载资产本身没有记录这个 SHA，因此仍是来源锁缺口。

处置：所有下载都改成“固定 SHA + 内容散列校验”；锁文件同时记录许可证文件散列。只要依赖发生变化，CI 必须强制重新审计 NOTICE 与许可证清单。

## 实际分发面

当前 `make release` 先让 Xcode 复制传统 `data/plum`，随后 `copy-famo-seed` 使用 `rsync --delete` 以 `data/famo-rime` 完全替换 App 的 `SharedSupport`。因此安装版的实际第三方面如下：

| 分发面 | 实际内容 |
|---|---|
| 前端与安装器 | Famo 自有修改 + Squirrel 派生代码 |
| 引擎 | `librime.1.dylib` 1.17.0、`rime_deployer`、`rime_dict_manager` |
| 插件 | `librime-lua`、`librime-octagram`、`librime-predict` |
| 更新框架 | Sparkle 2.6.2 |
| 打包工具 | `plum/rime-install`（被复制进 App 的 `Contents/MacOS`） |
| 输入数据 | rime-ice seed、KyleBing 五笔 overlay、OpenCC 标准数据、octagram 简繁 gram |

传统 bopomofo/cangjie/luna/quick/stroke/terra 等 `data/plum` 中间产物会被 seed 覆盖删除，不属于安装版运行时；但 `plum` 自身的 `rime-install` 确实随 App 分发，仍需履行 LGPLv3。

## 直接组件清单

“兼容”只表示许可证条款可以与 GPL-3.0-only 组合，不表示当前分发动作已经合规。

| 组件与用途 | 固定版本 / 来源 | 许可与一手证据 | GPL-3.0-only 兼容性 | 必须执行的分发动作 | 当前状态 |
|---|---|---|---|---|---|
| Squirrel；Famo 的 IMK 前端基座 | `4db2c85ac639c229e14fd9424f79c3c4f97ce478`（Famo 首个 fork commit 的父提交） | GPL v3；[LICENSE](https://github.com/rime/squirrel/blob/4db2c85ac639c229e14fd9424f79c3c4f97ce478/LICENSE.txt)、[固定提交](https://github.com/rime/squirrel/commit/4db2c85ac639c229e14fd9424f79c3c4f97ce478) | 是 | GPLv3 全文、版权声明、修改说明、对应源码、构建/安装信息 | 源码历史保留；许可表达需统一 |
| librime；输入引擎与 CLI | `33e78140250125871856cdc5b42ddc6a5fcd3cd4` / 1.17.0 | BSD-3-Clause；[LICENSE](https://github.com/rime/librime/blob/33e78140250125871856cdc5b42ddc6a5fcd3cd4/LICENSE) | 是 | 二进制材料中原样重现版权、条件、免责声明；禁止暗示背书 | 缺完整 BSD 文本 |
| librime-lua；Lua 插件 | `ec52e48ea18f11af37717a01c337f853215cf70b` | BSD-3-Clause；[LICENSE](https://github.com/hchunhui/librime-lua/blob/ec52e48ea18f11af37717a01c337f853215cf70b/LICENSE) | 是 | 同 BSD-3；另履行内嵌 Lua MIT | 缺完整文本；Lua 来源锁不完整 |
| librime-octagram；语法模型插件 | `dfcc15115788c828d9dd7b4bff68067d3ce2ffb8` | GPL v3；[LICENSE](https://github.com/lotem/librime-octagram/blob/dfcc15115788c828d9dd7b4bff68067d3ce2ffb8/LICENSE) | 是 | GPL 全文、版权/修改声明、精确对应源码及构建信息 | **许可证写错且源码交付缺失** |
| librime-predict；预测插件 | `920bd41ebf6f9bf6855d14fbe80212e54e749791` | BSD-3-Clause；[LICENSE](https://github.com/rime/librime-predict/blob/920bd41ebf6f9bf6855d14fbe80212e54e749791/LICENSE) | 是 | 原样重现 BSD 条款 | 缺完整文本 |
| Sparkle；更新 UI/校验 | 2.6.2 / `41847a58cdef7506b257591fcca6f9495df591d4` | MIT + bundled external licenses；[release](https://github.com/sparkle-project/Sparkle/releases/tag/2.6.2)、[完整 LICENSE](https://github.com/sparkle-project/Sparkle/blob/41847a58cdef7506b257591fcca6f9495df591d4/LICENSE) | 是 | 随二进制原样附上整个 LICENSE（含外部许可段） | App 内缺失 |
| plum；`rime-install` | `b1be1969f914cc005add4090631b855db00c2591` | LGPL v3；[LICENSE](https://github.com/rime/plum/blob/b1be1969f914cc005add4090631b855db00c2591/LICENSE) | 是 | LGPL+GPL 文本、显著使用声明、可取得的对应源码及修改信息 | App 内缺 LGPL/声明；源码为固定子模块但发布包应实装 |
| rime-ice；拼音 seed | `b681a34f788795034b3b288830f4861980bc8b0d` | GPL-3.0-only；[LICENSE](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/LICENSE)、[README 声明](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/README.md#许可证) | 是 | GPL 文本、对应源文件、修改说明；另保留 Credits 中各来源义务 | 根 LICENSE 已带；Credits/分项许可缺失 |
| rime-wubi86-jidian；五笔 seed | `a194fb8b3ec41ef9dcf079d3a67876fa75f79135` | Apache-2.0；[LICENSE](https://github.com/KyleBing/rime-wubi86-jidian/blob/a194fb8b3ec41ef9dcf079d3a67876fa75f79135/LICENSE) | 是（Apache-2.0 与 GPLv3 兼容） | Apache 全文、版权/修改声明；若上游有 NOTICE 则保留（该固定树未发现 NOTICE） | Apache 文本已带；底表授权链未确认 |
| rime-octagram-data；简繁 `.gram` | `master` `8ceef1b…`、`hans` `9c482c6…`、`hant` `bb8e131…` | LGPL v3；[master](https://github.com/lotem/rime-octagram-data/blob/8ceef1b42eb77e86501382a52e85c309c0f2f04c/LICENSE)、[hans](https://github.com/lotem/rime-octagram-data/blob/9c482c6660fa9e3268bd1d1a9341ef26aa90f94d/LICENSE)、[hant](https://github.com/lotem/rime-octagram-data/blob/bb8e1313552f0f27f2f968031dfaf4563e55d982/LICENSE) | 是 | LGPL+GPL 文本、显著使用声明、对应数据/修改形式 | seed 含 gram，但未携 LGPL/归属，manifest 也未记录三个 SHA |
| OpenCC；静态库及转换数据 | `556ed22496d650bd0b13b6c163be9814637970ae` | Apache-2.0；[LICENSE](https://github.com/BYVoid/OpenCC/blob/556ed22496d650bd0b13b6c163be9814637970ae/LICENSE) | 是 | Apache 全文、版权与修改声明；保留其嵌入依赖的许可 | App 内缺失 |

## librime 与 OpenCC 的编译期/静态依赖

`librime.1.dylib` 的 `otool -L` 只列 Apple 系统库和 libc++；下列依赖因此是静态编入或以头文件形式进入分发物，而不是由系统动态提供。

| 组件 | 固定版本 / 许可证据 | 许可选择 | 兼容性与动作 |
|---|---|---|---|
| Boost | 1.89.0（构建脚本同时固定官方 tarball SHA-256）；[BSL-1.0](https://github.com/boostorg/boost/blob/boost-1.89.0/LICENSE_1_0.txt) | BSL-1.0 | 兼容；附版权与许可文本 |
| glog | `7b134a5c82c0c0b5698bb6bf7a835b230c5638e4`；[COPYING](https://github.com/google/glog/blob/7b134a5c82c0c0b5698bb6bf7a835b230c5638e4/COPYING) | BSD-3-Clause | 兼容；二进制材料重现完整条款 |
| LevelDB | `99b3c03b3284f5886f9ef9a4ef703d57373e61be`；[LICENSE](https://github.com/google/leveldb/blob/99b3c03b3284f5886f9ef9a4ef703d57373e61be/LICENSE) | BSD-3-Clause | 兼容；二进制材料重现完整条款 |
| marisa-trie（librime 及 OpenCC 内嵌版本） | librime `3e87d53…`；[COPYING](https://github.com/s-yata/marisa-trie/blob/3e87d53b78e15f2f43783d5e376561a8c9722051/COPYING.md) | 选择双许可中的 BSD-2-Clause | 兼容；明确记录采用 BSD-2 选项并重现条款 |
| yaml-cpp | `2f86d13775d119edbb69af52e5f566fd65c6953b`；[LICENSE](https://github.com/jbeder/yaml-cpp/blob/2f86d13775d119edbb69af52e5f566fd65c6953b/LICENSE) | MIT | 兼容；附版权与许可文本 |
| Darts-clone | 随 librime 固定提交 vendored；[固定 COPYING](https://github.com/rime/librime/blob/33e78140250125871856cdc5b42ddc6a5fcd3cd4/include/COPYING.darts-clone) | BSD-3-Clause | 兼容；二进制材料重现完整条款 |
| UTF8-CPP | 随 librime 固定提交 vendored；[固定头文件内许可](https://github.com/rime/librime/blob/33e78140250125871856cdc5b42ddc6a5fcd3cd4/include/utf8/core.h) | Boost 风格宽松许可 | 兼容；源码保留头注，NOTICE 收录版权与条款 |
| X11 keysyms headers | 随 librime 固定提交 vendored；[固定头文件内许可](https://github.com/rime/librime/blob/33e78140250125871856cdc5b42ddc6a5fcd3cd4/include/X11/keysymdef.h) | X11/MIT 风格许可 | 兼容；保留 The Open Group / DEC 声明及禁止背书条件 |
| RapidJSON（OpenCC 内） | 随 `OpenCC@556ed224…` vendored；[固定头文件内 MIT 声明](https://github.com/BYVoid/OpenCC/blob/556ed22496d650bd0b13b6c163be9814637970ae/deps/rapidjson-1.1.0/rapidjson/document.h) | MIT | 兼容；收录版权和 MIT 条款 |
| Lua（librime-lua 内） | release 构建时应为 `thirdparty@fa40fadd8af1e5b1fbd55703ccbd54476956d74c`、Lua 5.4.8，但资产未记录该 SHA；[lua.h 内 MIT 声明](https://github.com/hchunhui/librime-lua/blob/fa40fadd8af1e5b1fbd55703ccbd54476956d74c/lua5.4/lua.h) | MIT | 兼容；先把来源 SHA 正式锁定，再附版权与许可文本 |

`googletest@f8d7d77…` 是 librime 的测试依赖，不进入当前 Famo 安装版运行时；若发布完整递归源码或单独分发测试二进制，仍应保留其 [BSD-3-Clause LICENSE](https://github.com/google/googletest/blob/f8d7d77c06936315286eb55f8de22cd23c188571/LICENSE)。

## rime-ice 聚合来源的最低归属要求

本报告没有把 rime-ice Credits 中没有固定版本的来源猜成某个提交。下表记录的是固定 rime-ice 快照自己给出的来源与许可证声明；真正的 release ledger 应进一步把每个实际复制文件映射到上游版本。

| rime-ice 声明的来源 | 许可 | Famo 动作 |
|---|---|---|
| Unihan | Unicode License v3 | 保留 Unicode 版权、许可、免责声明；标明经 rime-ice 汇编/修改 |
| rime-essay-simp | LGPL-3.0 | 附 LGPL+GPL；提供实际复制数据及修改说明 |
| THUOCL | MIT | 附版权与 MIT 条款 |
| 腾讯词向量整理数据 | CC BY 3.0 | 显著署名 Tencent AI Lab 和整理来源，链接 CC BY 3.0，说明 Famo/rime-ice 的改动 |
| rime-melt | Apache-2.0 | 附 Apache 全文、版权与修改声明 |
| rime-radical-pinyin | GPL-3.0 | 与项目 GPLv3 兼容；提供对应源码/修改说明 |
| librime-lua-script `unicode.lua` | MIT | 保留源码内作者/许可，NOTICE 收录 |
| 98wubi `number.lua` | LGPL-3.0 | 附 LGPL+GPL，保留作者与修改声明 |

来源总证据：[rime-ice `Credits.md` 固定快照](https://github.com/iDvel/rime-ice/blob/b681a34f788795034b3b288830f4861980bc8b0d/others/docs/Credits.md)。

## 推荐的发布结构

```text
Famo.app/Contents/Resources/
├── LICENSE.txt                         # Famo / Squirrel / GPL 组件的 GPL-3.0-only 全文
├── THIRD_PARTY_NOTICES.md              # 组件、固定版本、版权、修改、用途索引
└── Licenses/
    ├── LGPL-3.0-only.txt
    ├── Apache-2.0.txt
    ├── BSD-2-Clause-marisa.txt
    ├── BSD-3-Clause-librime.txt
    ├── BSD-3-Clause-librime-lua.txt
    ├── BSD-3-Clause-librime-predict.txt
    ├── BSD-3-Clause-glog.txt
    ├── BSD-3-Clause-leveldb.txt
    ├── BSD-3-Clause-darts-clone.txt
    ├── MIT-Sparkle-and-external-components.txt
    ├── MIT-yaml-cpp.txt
    ├── MIT-Lua.txt
    ├── MIT-RapidJSON.txt
    ├── BSL-1.0-Boost.txt
    ├── UTF8-CPP.txt
    ├── X11-keysyms.txt
    ├── Unicode-License-v3.txt
    ├── CC-BY-3.0.txt
    └── rime-ice-Credits.md
```

同一目录应进入独立安装器、DMG、PKG 和 source archive。`THIRD_PARTY_NOTICES.md` 应当是索引和归属清单，不能替代要求原样保留的许可证文本。

## 对应源码与构建信息要求

每个公开二进制版本至少应同时发布：

1. Famo/Squirrel 的精确 tracked source；
2. `librime@33e7814…` 及其固定依赖来源锁；
3. **`librime-octagram@dfcc151…` 的完整源码**；
4. 实际生成 seed 的 rime-ice、wubi、OpenCC 数据和 octagram data 快照；
5. 生成二进制所需的脚本、补丁、编译参数及安装修改版所需的信息；
6. 一份机器可读 lock/SBOM，记录 remote、完整 SHA、许可证表达、许可证文件 SHA-256、是否修改、二进制/资源落点；
7. 从二进制 release 页面到同版本源码包的直接链接，而不是仅指向会继续变化的默认分支。

当前 `release_composition_artifacts.py` 把实际 `famo-rime` seed 放入源码包，这是正确基础；需要继续补上 GPL 插件源码、固定依赖来源和全部许可证/归属文本。只在 lock 里写一个公开 remote 和 SHA，而归档中没有可初始化的 Git 元数据，不应当被当成“源码已经随包提供”的唯一依据。

## 建议新增的 release gates

1. **无浮动依赖**：构建脚本中第三方 clone 必须立即 checkout 完整 SHA；发现 `pull`、默认分支或无散列下载即失败。
2. **二进制清单反查**：对最终 `.app`、PKG payload 和 DMG 枚举所有 dylib/framework/tool/data source，逐项命中 SBOM。
3. **许可证随附门**：SBOM 中每个组件必须有本地 license file；构建后验证这些文件确实位于 App/DMG/PKG/source archive。
4. **GPL 对应源码门**：所有 GPL/LGPL 运行时组件必须命中 source archive 中的实体内容，而不是空 gitlink 或默认分支 URL。
5. **版本一致门**：校验 librime `version-info.txt`、Mach-O 版本、Sparkle Info.plist、seed manifest、lock/SBOM 完全一致。
6. **归属门**：rime-ice Credits、CC BY 署名、Apache 修改声明和 BSD 禁止背书条款必须存在。
7. **许可证表达门**：扫描 `GPL-3.0-only` / `GPL-3.0-or-later`；仓库只能出现版权人最终选定的一种项目许可表达（第三方例外必须位于明确的第三方上下文）。
8. **未知许可即阻断**：任何新增词典、模型、图标、字体、脚本或复制代码没有固定来源和许可时，release 失败，不以“上游仓库公开”代替授权。

## 现有文档需要纠正的要点

- `THIRD_PARTY_NOTICES.md`：把 octagram 从 BSD 改为 GPLv3；拆开每个插件；补静态依赖、rime-ice 聚合来源、完整 SHA、修改状态和本地许可证路径。
- `THIRD_PARTY_NOTICES.md` 的“完整许可证以上游为准、避免逐字复制”原则必须删除；二进制分发恰恰需要随附若干完整文本。
- `PROVENANCE.md` 目前自称“完整记录来源”，但未覆盖插件 SHA、静态依赖、rime-ice Credits、Lua、Sparkle 外部组件和 Wubi 底表问题；在补齐前应改为非穷尽性摘要。
- README 的许可段应明确 `GPL-3.0-only`（若版权人最终选择 only）、对应源码取得方式、第三方 notices 与许可证目录。
- installer 中的 `GPL-3.0-or-later` 必须与最终决策统一。

## 最终放行条件

以下条件全部满足后，才可把许可证门标为通过：

- octagram 许可更正，且精确 GPL 对应源码实际进入 release source archive；
- 最终 App、安装器、DMG、PKG、源码包都携带完整 license bundle；
- rime-ice Credits/CC BY 等归属完整；
- Wubi 底表获得可公开验证的授权链，或替换/移除；
- 项目 only/or-later 表达统一；
- 所有第三方依赖固定完整 SHA 与内容散列；
- release gate 从最终产物反查通过，而不是只检查源码仓中的一张汇总表。
