# 应用状态记忆、真实试打、候选置顶

2026-10-02 用户确认采用原型推荐的 A 版布局，本文件保留正式实现的决定。A 版融入现有键盘设置、欢迎引导与候选窗；新增独立「输入习惯」页的 B 版、集中在菜单栏的 C 版未采用。设计确认不等于安装后的运行验收。

## 当前 Rust 数据边界（2026-10-26）

本节以 Rust 引擎和现有 Swift 控制器的源码为准。

- **学习数据**：Rust 引擎把学习、排序、固定位置、选择、纠错、个人词组与置顶等状态写入
  `Application Support/Owltype/msime-user/msime_user.db`；SQLite 的 `-wal`、`-shm`、
  `-journal` 和 `msime_user.db.corrupt-*` 属于同一学习日志组。工作词典在
  `msime-user/dictionaries/<content-id>/`，资源代次切换时由引擎重建。
- **界面置顶词**：右键置顶仍保存于 `owl_pinned_words`，按原始全拼、简繁状态和用户操作
  顺序排列，并通过 session property 提供给当前会话。旧版迁移把它完整复制到迁移清单，
  Rust 的 `pinned_candidates` 只按规范化全拼上下文写入每项上下文的第一条；后续同上下文
  冲突或没有有效全拼的置顶保留在 `owl_pinned_words`，迁移结果显示
  `pinsExternalOnly`，不声称 Rust 表能无损代替原列表。
- **旧 Rime 原件**：迁移只读取 `installation.yaml` 指向的同步根（未配置时为
  `sync/`）下、固定两层布局中的 `*.userdb.txt` 快照，不读取正在使用的 LevelDB。
  自定义同步路径只改变读取位置，不写回 `installation.yaml`，迁移清单仍使用
  `sync/<installation>/...` 的逻辑路径。阶段写入前后重新核对同一同步根。
- **重置用户词典**：只完整备份并删除 `msime-user/msime_user.db*` 与
  `msime-user/dictionaries/`；旧版 `*.userdb`、同步快照、`installation.yaml`、
  旧输入习惯文件、方案与界面设置均保留。删除失败时整组从备份恢复。
- **同步入口**：旧 Rime 的“同步用户数据”和“设置同步目录”已从菜单、设置页、通知与
  App CLI 退役。需要迁移旧学习记录时使用“迁移旧版输入记录…”；Rust 日志本身没有
  旧 Rime 同步导出。

## 入口与行为

- **键盘输入 → 中英文与初始状态**：默认开启按应用记忆，跨进程重启保留。只保存 bundle ID 与中英文布尔值。已有记忆优先于应用初始英文和全局初始语言；简繁体、全半角沿用已有设置。管理面板可逐个忘记应用。
- **欢迎与引导 → 第 5 步试打**：使用原生 NSTextView，核验当前猫头鹰输入源以及真实组字提交。输入「你好，猫头鹰」后开放「开始使用」。粘贴不计入，其他输入源的内容需要清空重试；允许稍后再试。从前一步重新进入会重新验证。引导仍可从现有「关于」入口打开。
- **候选窗**：右键候选词可置顶或取消置顶；单击仍然直接上屏。默认快捷键为 Control Shift P，只在有效全拼候选中处理，不注册为全局热键。若该组合已被其他功能占用，则不自动占用，用户可在「快捷键设置 → 候选词置顶」录制其他组合及管理置顶词。

## 当前验证入口

```sh
cd rust
cargo fmt --all -- --check
cargo test -p owl-msime-ffi
```

在仓库根目录运行 Swift 聚焦检查：

```sh
python3 scripts/verify.py swift \
  --test OwlUserMigrationTests \
  --test OwlUserDictResetTests \
  --test OwlInputHabitsTests \
  --test OwlInputHabitsIntegrationTests \
  --test OwlRustEngineTests \
  --test OwlCLIEntryPointTests
```

`verify.py` 负责补齐 Rust seed、签名本地测试宿主并保留回执。Rust crate 测试需要先在
仓库根目录执行 `make owl-seed`；`make test` 会自动完成这一步。上述检查不使用真实用户
数据，也不安装或选择输入法。
