# Source provenance

本仓库从经过审查的源码白名单开始，没有继承产品开发仓、撤回仓库或历史源码包的 Git 提交。
首个提交使用 GitHub noreply 身份；后续发布不得合并旧历史。

## 固定上游

| Component | Pinned revision | Use |
|---|---|---|
| Squirrel | `4db2c85ac639c229e14fd9424f79c3c4f97ce478` parent lineage | InputMethodKit frontend base |
| librime | `33e78140250125871856cdc5b42ddc6a5fcd3cd4` | Rime engine and build headers |
| librime-lua | `ec52e48ea18f11af37717a01c337f853215cf70b` | Local Lua extensions used by rime-ice |
| plum | `b1be1969f914cc005add4090631b855db00c2591` | Rime recipe tooling |
| rime-ice | `b681a34f788795034b3b288830f4861980bc8b0d` | Pinyin schema and dictionaries |

`librime`、`librime-lua` 与 `plum` 是固定 SHA 的公开子模块。`scripts/famo-seed.sh` 使用完整 SHA 获取
rime-ice，并把它的 LICENSE 与 Credits 复制到生成的 seed。`make bootstrap` 还会对
`THIRD_PARTY_NOTICES.md` 所列的两个 librime 官方构建包执行 SHA-256 校验，并且只复制
`librime` 与 `librime-lua`；predict 与 octagram 插件不会进入 App 工程。

`plum` 的八个构建期数据包也在 `action-install.sh` 中锁定完整提交 SHA；脚本以 detached HEAD
安装它们，不再从浮动默认分支生成构建输入。生成 seed 所需的通用许可证全文固定到 SPDX
license-list-data `v3.28.0`，每个下载文件都在复制前校验 SHA-256。

## 有意排除

- Sparkle 和所有 appcast / 签名 / 公证发布流程；
- 极点五笔数据：底表的再许可授权链尚未取得可公开验证的依据；
- octagram gram 数据：首个本地核心不启用语法模型；
- 云端服务、辅助功能划词和剪贴板历史实现。

`make release-gate` 会从最终 App 反查原生组件和完整文件清单，写入 SPDX SBOM，并生成绑定根提交、
递归子模块、同版数据 seed 和 App 文件清单的对应源码归档。公开二进制发布材料必须同时包含该 App、
对应源码归档及两者的 SHA-256 清单。
