# 首装免注销探针（RequireLogout 是否可挪进引导末尾）

状态：**待真机验证**（2026-07-27 立项）。探针脚本：`scripts/probe-no-logout-install.sh`。

## 背景与要回答的问题

新手引导已改为 5 步（欢迎 → 启用 → 选方案 → 词库 → 完成），词库下载（约 90 MB）在引导
期间真实展示、完成页软阻塞。设想的终态（方案乙）：首装 pkg 去掉 `onConclusion=RequireLogout`，
把唯一一次注销挪到引导末尾——「注销并完成设置」，注销发生时词库已下载编译完，登录回来满血。
注销从"装完就赶人"变成"万事俱备的收尾键"。

前提是回答：**postinstall 的用户会话激活序列（register→enable→select→open + killall
输入菜单代理，见 `scripts/postinstall`）在不注销的情况下，单独是否足够可靠？**

历史包袱：1.4.6 时代「免注销保持选中态」在真机不可靠，才改成诚实强推注销
（`FamoUpdateLogoutPrompt.swift` 头注释）。但那是**更新路径的选中态还原**问题；本探针问的
是**首装路径的注册/启用可见性**，是不同的问题，需要独立证据。

## 探针原理

`sudo installer -pkg Famo.pkg -target /` 命令行安装器**不执行** `onConclusion`——现成的
发布 pkg 就是一次天然的无注销首装，无需构建改包。装完立即（不注销）验收。

## 硬约束

- **绝不在日常主力机上跑**：
  - 运行中重装 Famo 会触发 Karabiner-Elements 析构 bug → VirtualHID 卡死、全键盘失灵
    （2026-07 真机实录）。preflight 检测到 Karabiner 即拒跑。
  - 主力机已装法墨 → 测出的是重装路径（postinstall 跳过 enable/select），对首装问题无效。
- HIToolbox plist（`AppleEnabledInputSources`）有会话缓存不可信，一律用 App 自带的
  TIS API 探测口（`--diagnose-tis` / `--detect-activation` / `--current-input-source`）。

## 步骤

```bash
./scripts/probe-no-logout-install.sh preflight
sudo installer -pkg <path-to>/Famo.pkg -target /
./scripts/probe-no-logout-install.sh verify   # 取证 + 人工清单，先不注销
# 人工验收 (a)(b)(c)(d) → 注销重登 → 复测 (a)(b)(c)
```

## 结果表

| macOS 版本 | (a) 系统设置列表可添加 | (b) 输入菜单可见可切 | (c) 新开 App 可打字 | (d) 旧 App 表现 | 注销后复测 | 备注 |
|---|---|---|---|---|---|---|
| （待填） | | | | | | |
| （待填） | | | | | | |

## 判读

- **(a)(b)(c) 全过（≥2 个 macOS 版本）** → 方案乙可行：
  1. `package/Distribution` 去掉 `onConclusion="RequireLogout"`；
  2. `scripts/check-release.sh` 的 RequireLogout 断言反转（首装也必须**无**）；
  3. 引导完成页在需要时把「开始使用」升级为「注销并完成设置」（复用 `FamoLogoutAction`），
     判据：本次会话内首装且未注销过（可用 pkg 安装时间 vs 会话启动时间判断，实现时再定）；
  4. 引导第 1 步（启用）文案适配免注销语境。
- **任一不过（尤其 (b) 输入菜单缺失）** → 保留 RequireLogout（方案甲）；引导维持现状
  （词库露出 + 软阻塞），fusion 只做更新路径：更新后的注销建议弹窗等词库就绪再弹。
- **(d) 预期本来就需要重开旧 App**（squirrel#68 边界），不作为否决项，只影响文案措辞。
