<a name="1.5.15"></a>
## 1.5.15 (2026-07-29)

### 主要功能更新 | Major Updates
- 皮肤增加第 9 套「怀德纳红」（哈佛大学配色）(#77)
  - 取色自哈佛自家品牌规范，官方色逐字节照搬四支：Crimson #A51C30 作选中胶囊、Black #1E1E1E 作正文墨、Parchment #F3F3F1 作卡片、Mortar #8C8179 作辅助墨——正是哈佛红砖配灰浆的「brick and mortar」
  - 命名循胡佛红（Hoover Tower）的地标建筑法，而不是纽约紫 / 黑文蓝的城市法：哈佛所在的 Cambridge 中译「剑桥」在中文里几乎专指剑桥大学，叫「剑桥红」会被读错，故取哈佛园正中心的列柱大馆 Widener Library 定名
  - 三套红靠纸面分家：荔园红暖羊皮纸、胡佛红冷蓝灰、怀德纳红中性灰白纸配暖灰墨

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.14...1.5.15

<a name="1.5.14"></a>
## 1.5.14 (2026-07-29)

### Bug 修復 | Bug Fixes
- 五笔用 `z` 切临时拼音查字时，候选右侧重新显示五笔编码：那串注释并不是拼音，而是法墨拿候选字回五笔词典反查出来的编码——「打拼音顺带把码认下来」正是这一路的练习价值。此前它被「候选编码提示」那个开关连带抹掉了（出厂默认关着），现在两者解耦：编码提示只管五笔本身那一路，z 反查的编码恒显，也不多加一个开关 (#70)
  - 单字会一次列出简码与全码（如 `你` → `wq wqi wqiy`），这是反查的原生行为，没有过滤

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.13...1.5.14

<a name="1.5.13"></a>
## 1.5.13 (2026-07-29)

### 主要功能更新 | Major Updates
- 「任意提问 · 联网搜索」的搜索服务多一档「阿里云百炼」：此前两档（豆包搜索 / Perplexity）都要另去开一个搜索账号、单独买一把 Key，而这一档直接用你在上面「供应商」里已经填过的百炼 Key——配的是 DeepSeek 也照样能联网，因为检索和作答本来就是两件事 (#72)
  - 代价如实说在设置页里：百炼取回的来源只有标题和网址、不带正文摘要，接地效果弱于豆包搜索的整段摘要；想要更好的检索质量仍推荐豆包搜索
  - 检索这一跳做了减法：只取来源、丢掉模型顺带写的那段答案，实测从 8.7 秒降到 2.5 秒，而取回的来源条数一条不少
- 联网搜索开启后改为**强制检索**：此前是模型自己判断这一问要不要联网，它决定不搜时你拿到的其实是训练记忆，回答窗却已经标着「已联网」。宁可没有联网，不要假的联网 (#72)
- 供应商配置多一个「验证连通性」按钮，就在「拉取最新」旁边：拿当前这组端点 + 模型 + API Key 真发一次最小请求。它补的是「拉取最新」证明不了的那一段——模型列表拉得到，不代表你选的那个型号这个端点真的服务，实测撞到过同一把 Key 拉列表一切正常、换成某个型号就是 400 (#72)
  - 失败时会把服务商的原话一起显示出来，并直说下一步该动哪里：401/403 多半是 Key，400/404 多半是型号或端点不匹配
- 阿里云百炼的模型下拉从只有一个型号补到 3.7 全系（qwen3.7-plus / 3.7-flash / 3.7-max，以及 3.6-flash），新建档案默认用 qwen3.7-plus (#72)
- 皮肤增加第 8 套「黑文蓝」（耶鲁大学配色）(#69)

### 改进 | Improvements
- 划词润色 / 提示词优化 / 任务书三条链路统一关闭隐藏思考：此前提示词优化与任务书对通义千问是刻意保留思考的，理由写着「长产出质量优先」。实测推翻了这个判断——同一份草稿，任务书从 54 秒降到 17 秒、提示词优化从 41 秒降到 8 秒，而产出不但没变差，任务书反而更具体。原来那 54 秒离 60 秒硬超时只剩 6 秒，复跑就摸到过 55 秒，随时会被掐断 (#71)
- 快捷短语的内置示例更新：Qwen Code 换成 Qoder，去掉 Antigravity (#68)

### Bug 修復 | Bug Fixes
- 在阿里云百炼上使用它托管的 deepseek-* 型号时，关思考发的是百炼不认识的字段，等于没关：现在按你档案里的供应商来决定字段方言，而不是只看模型名前缀 (#71)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.12...1.5.13

<a name="1.5.12"></a>
## 1.5.12 (2026-07-28)

### 主要功能更新 | Major Updates
- 划词工具箱新增第 8 个技能「任务书」：选中一段口述的模糊需求，按目标七问（目的 / 完成态 / 证据 / 反作弊 / 边界 / 取舍 / 未知）整理成一份能独立交出去执行的任务书，预览确认后替换原文 (#64)
  - 缺的信息分两级处理：能合理推断的直接补上并标注「（推断）」，推断不出的落进〈未知〉一节等你裁决；只有「目的」和「完成态」双双缺失时才会反问你，不会为每个空档都来打断一次
- 候选窗的多行候选改为「翻页才展开」：组字一开始仍是熟悉的单行，只有你真的翻了页才展开上下文行——不翻页的短词输入不再被突然变高的窗口打断 (#63)
  - 翻页后上方固定保留一行前页候选，走到末页也不会掉回单行，回头找刚翻过去的那个字不用再翻回来
  - 后页行数上限从 2 提到 4、默认 4，设置里相应多了「跟 3 页 / 跟 4 页」两档；此前存的 1 行 / 2 行选择原样生效
  - 前后页那几行也显示编码提示注释，与主行同一个开关控制

### Bug 修復 | Bug Fixes
- 用豆包或 MiMo 时，划词润色与提示词优化不再空烧「隐藏思考」：这两家与 DeepSeek 用的是同一种关思考写法，但代码里只关了 DeepSeek 一家。实测火山方舟豆包默认开着隐藏思考，哪怕只回一句话也要先烧掉一批推理 token——润色时你正等着替换选中的文字，这条链路对延迟最敏感；「任务书」那种长产出更会直接顶穿 60 秒硬超时被掐断。修好后任务书单次约 20 秒 (#65, #66)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.11...1.5.12

<a name="1.5.11"></a>
## 1.5.11 (2026-07-27)

### 主要功能更新 | Major Updates
- 新手引导多一步「完整词库」，上一版那次「同意并下载」的问询也搬了进来：首次启动不再是先弹一个模态问你要不要下 90 MB，而是在引导里作为第二步当面讲清楚——版权缘由照旧，但你是在安装向导里做这个决定，不是被一个突然出现的窗口拦住 (#60)
  - 放在第二步是有讲究的：你同意后下载立刻在后台开始，随后「去系统设置启用法墨」和「选方案」这两步（尤其前者要跑一趟系统设置）正好把下载时间盖掉，走到最后一屏时多半已经下完
  - 也因为这个顺序，选方案那步的五笔/双拼不再会撞上「词库还没下」——那些方案的文件本来就在这个包里
  - 最后一屏在下载/编译没完成时会等你一下（按钮上直接显示进度），但留了「暂不等待，先开始使用」的出口；你要是选了「以后再说」，它绝不会拦你
  - 引导窗放大到 880×580，正文更宽、不再挤

### Bug 修復 | Bug Fixes
- 词库下载被打断后不再从头再来：此前中途退出或注销会丢掉已下的部分，重来一次又是完整的 90 MB。现在按文件续传，校验通过的部分直接复用 (#60)
- 下载进度条不再长时间不动：此前进度按「下完一个文件」跳一格，而最大的那个语法模型有 40 MB，下载期间进度条一动不动，看起来像卡死。现在按字节实时走，那个大文件也不再整块占着内存 (#60)
- GitHub 直连不通时自动换源：下载源改成有序的一串（你自己配的镜像 → GitHub 直连 → 两个公共加速源），某个文件在一处取不到就换下一处继续，不再直接报「下载失败」让你自己想办法。所有来源都要通过同一份哈希校验，取到的内容对不上就换下一家，不会装进你的目录 (#60)
- 词库编译完成的时机现在是真的：此前「正在编译词库…」一闪而过，实际编译还在后台跑，你并不知道什么时候能用。现在这个状态会持续到 librime 真的编译完 (#60)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.10...1.5.11
<a name="1.5.10"></a>
## 1.5.10 (2026-07-27)

### 主要功能更新 | Major Updates
- 完整词库改为「你同意了才下」：法墨安装包只内置自建的清洁室精简词库，五笔、简体拼音、小鹤双拼等方案的词库来自第三方开源项目（雾凇拼音 rime-ice、极点五笔86）。此前这批词库（约 90 MB）由首启在后台静默拉取，你既不知道它在下载，失败了也只写进设置页状态——看不到，只会觉得候选质量差 (9f5f260)
  - 既然不随包分发本就是为了避免版权争议，代你下载同样不该由法墨替你决定：现在首启会弹窗说清缘由，你点「同意并下载」才开始拉，并直接跳到设置页看进度
  - 首启这次告知等到你没在打字时才弹（无合成 + 输入空闲），不会中途夺走焦点打断输入；选「稍后」会把焦点还给你原来的应用，之后随时可在「设置 → 键盘输入 → 完整词库」下载
  - 切到尚未下载的方案时会点名再问一次，不必自己去猜哪里能装
  - 设置页「完整词库」卡的说明也补上了这层缘由

### Bug 修復 | Bug Fixes
- 切到未随包分发的方案（如五笔）失败时，提示不再误导：此前会说「该方案可能尚未编译，请在设置里『应用配置改动』后重试」，可那些方案的文件压根不在磁盘上，照做也没用——现在改为说明版权缘由并直接给出下载入口；确实已下载却切换失败（真的未编译）时，原提示照常发出 (9f5f260)
- 已装应用冒烟检查 `check-installed.sh` 修复两处失效：断言仍停在单仓公开化之前，在任何按当前口径安装的机器上恒报 FAIL；且失败即退出，卡在第一条就把后面 6 条同类断言、TIS 层与候选级探针整段遮蔽——真回归无从发现。修复后跑满 23 条断言并汇总 (db8a3e8)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.9...1.5.10

<a name="1.5.9"></a>
## 1.5.9 (2026-07-27)

### 主要功能更新 | Major Updates
- 「任意提问」的联网搜索改为「先检索、再作答」：由独立的搜索服务取回网页，再交给你当前默认的供应商作答。不再依赖模型自带的联网工具——配的是 DeepSeek 也能联网，「哪家模型能联网」这个概念就此消失 (f9b8f74)
  - 后端两家并存、Key 分开保存，切换不用重填：豆包搜索 Global 与 Perplexity Search
  - 一家不肯服务就顺位换下一家（4xx 换人）；断网、限流、服务端错误如实报错，不伪装成「换一家」。全部失败则退回普通问答；检索到 0 条按失败处理，不会注入空资料却署名联网
  - 答案下方的署名写的是真正答这一问的那家，而不是你配的那家
- 「任意提问」全链路强制关闭思考模式：此前只有划词技能和部分供应商的联网请求关了，普通问答与通义千问的联网请求都没关——实测答一句话先烧掉近千个思考 token、多等 5 秒 (f9b8f74)
- 供应商可以直接改模型，不必删了重加（Key 留空即保持不变）；密钥状态由两态改三态「已验证 / 已设置·未验证 / 未设置」——有值不等于能用，实机就踩到过 Key 已失效而设置页仍写「已设置」 (467ee3a)
- 设置页「技能平台」更名为「划词工具箱」，与功能本身同名；页内首卡改叫「启用与权限」。「快捷键设置 → 划词工具箱」补上一行说明：默认唤起键是双击 ⌥（Option），此处录的组合是并行入口，不录也不影响双击唤起 (0fb71a2)

### Bug 修復 | Bug Fixes
- Perplexity 检索结果里的裸控制字符会让整次提问失败（三次里出一次），已在解析前统一清洗；检索接地档位由 low 改 high——实测 low 档 5 条里只有 1 条带摘要，而三档时延完全一样 (e6b39b5)
- 豆包搜索每条结果的配图数上限填 0 等于没填（落回默认 3 张），改用真正生效的最小值 1 (6e4fdfd)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.8...1.5.9

<a name="1.5.8"></a>
## 1.5.8 (2026-07-27)

### Bug 修復 | Bug Fixes
- 修复辅助功能授权后必须重启输入法才生效的问题：此前法墨启动时若尚未获得辅助功能授权，负责跨宿主快捷键的事件监听就不会安装，事后去系统设置授权也不会补上——设置页徽章已经翻绿，但录制的召唤/快发快捷键在 Chrome、VS Code 等宿主里依然没反应，直到注销或重启输入法 (77c033e)
  - 现在授权即刻生效：在系统设置里勾上开关的那一刻就补装完成，不必切回法墨；切回法墨窗口时也会再补一次，两路互为保险
  - 纯事件驱动，没有新增任何后台轮询——打字与划词链路的开销分毫未变
- 「唤起热键」设置行的「需辅助功能权限」提示不再滞留：授权后切回设置窗口即自动撤下 (77c033e)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.7...1.5.8

<a name="1.5.7"></a>
## 1.5.7 (2026-07-26)

### 主要功能更新 | Major Updates
- 候选窗新增「卷轴」排列方向，取代原来的「折行」：一行就是一整页候选，第一行是当前页（带序号、可用数字键选），下方跟着后面一到两页（稍淡、无序号、可用鼠标点选），翻页时整块向上滚一行 (44b07b9)
  - 折行的问题是折来折去还是同一页：候选一个没多、白占高度，行数还随候选宽窄在一到三行之间跳，翻页圆点和展开箭头也跟着候选一起飘到方块里的随机位置
  - 数字键的含义分毫未变——序号只属于第一行。真正连续滚动的候选流需要重新映射数字键，会让「看到第 3 个」和「按 3 选中」对不上，因此没有采用
  - 设置里「排列方向」现在是 自动 / 横排 / 竖排 / 卷轴；选中卷轴后可选跟 1 页或 2 页
- 1.5.4 的「预览后页」开关退役，功能并入卷轴：原来的预览行不可点、纯淡显，现在成了卷轴的后页行，可以直接点选。此前开过这个开关的用户会自动落到卷轴，观感不丢；显式改选其他排列方向即以新选择为准 (44b07b9)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.6...1.5.7

<a name="1.5.6"></a>
## 1.5.6 (2026-07-26)

### 主要功能更新 | Major Updates
- 划词工具箱重设计：不再一选中文字就自动弹出小菜单——选中后双击 ⌥（Option）键（或录制的召唤快捷键）呼出工具箱窗口，顶部是技能按钮行，下方就是「任意提问」输入框，对选中文本用技能加工或直接下指令 (331c371)
  - 三个旧入口退役：选中自动弹出、状态栏「任意提问」菜单项、直达热键；打字期间零 AX 调用，只在明确手势后读一次选区
  - 双击 ⌥ 判定为纯状态机：长按 ⌥、⌥+字母组合键、⌥+点击、双击 Shift 都不会误触发
- 技能列表精简为 7 项：删去公文排版、润色·多版本挑选、润色·仿我的范例——个性化加工需求由「任意提问」对选中文本直接下指令兜底；「结构化·加标签」并入「提示词优化」（补齐四要素并按语义加 XML 标签一次做完）；「任意提问」置顶技能列表并获得自己的开关（默认开），「润色·直接替换」简名「润色」 (331c371)
- 下架智谱 GLM：从供应商预设、联网搜索与来源核验中彻底移除 (c8a308d)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.5...1.5.6

<a name="1.5.5"></a>
## 1.5.5 (2026-07-26)

### 主要功能更新 | Major Updates
- 候选窗选中态改为「通栏圆角」：撤掉顶光渐变、内侧白描边、外投影三层，只留纯色圆角块，并出血到面板内壁。此前四层叠出来的是「贴在玻璃上的一颗按钮」，翻页时整颗物件在飞 (66565f1)
  - 依据：面板本身已是玻璃层，选中态不该再是一个自带材质的物件，只该是面板内的一块 tint；圆角保留 8 而非直角出血，因为 macOS 选中态的惯例是圆角
  - 横竖排共用同一处理，排布切换不跳戏；行文字位置与面板宽度分毫未动

### Bug 修復 | Bug Fixes
- 候选窗与状态提示的窗口投影其实一直没画出来：窗口投影关着，而视图层那层模糊不撑布局、窗口尺寸又严格等于内容尺寸，等于没有落点。改由系统按内容形状绘制，并只在面板尺寸真的变化时重算，不占按键热路径 (66565f1)
- 清掉一个失效旋钮与两处与实现不符的注释：皮肤里的投影半径在上述改动后已零引用（看着能调、调了没反应） (66565f1)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.4...1.5.5

<a name="1.5.4"></a>
## 1.5.4 (2026-07-26)

### Bug 修復 | Bug Fixes
- 快捷短语触发彻底修好：短语码回归裸码，参数对齐雾凇自带 custom_phrase（关前缀补全 + `initial_quality: 99`）——打全码短语置顶，打一半（如 `y`）零干扰 (2ef5973)
  - 1.5.2 的 `` ` `` 前缀方案证伪：`` ` `` 是雾凇拆字辅助码的引导键（search.lua），带前缀的码根本到不了短语 translator，短语等于整个失效
  - 新增启动期迁移：从 `famo_quick_send.json` 重放派生表与 patch，内容一致零写入——升级用户旧格式自动重写，不再依赖「碰巧重新保存」
- 部署提示 emoji off 标签 💀→👍，`ascii_mode`「Ａ」→「英」进公开种子 (2b345f0)

### 主要功能更新 | Major Updates
- 竖排候选窗重设计，横竖候选窗统一薄雾玻璃材质与顶光高亮 (0a2b247)
- 横排候选栏下方预览后两页候选 (b1e90f6)
- 「任意提问」改为划词技能兜底：对选中文本直接下指令、只回结果、一键复制并关窗 (1d74ee5)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.3...1.5.4

<a name="1.5.3"></a>
## 1.5.3 (2026-07-26)

### 主要功能更新 | Major Updates
- 设置「维护与诊断」新增「重置用户词典…」：清空输入习惯与自造词学习记录，方案、皮肤、快捷短语等设置与词库均不受影响。确认弹窗默认按钮是取消；重置前把 `*.userdb` 整目录备份到 `.famo-backup/userdb-reset-<ts>/`，可手工还原 (fca5f6f, 40ce3f0)
  - 修的是 1.4.23 → 1.5.0 那三天种子为 Unihan 全汉字表时被学进 userdb 的繁体词频：升级到干净词库后 `fan ti zi` 首选仍是「繁體字」。属用户自己按的维护动作，不做静默自动净化 (closes #37)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.2...1.5.3

<a name="1.5.2"></a>
## 1.5.2 (2026-07-25)

### Bug 修復 | Bug Fixes
- 快捷短语不再和正常打字抢候选：短语码统一带 `` ` `` 前缀，并关掉前缀补全、把 `initial_quality` 从 100 压到 1。此前码是裸字母且开着补全，打一个 `y` 就能命中码为 `yocc` 的短语，压在 有/用/言 前面 (39f9503, ac1f065)
  - 前缀只加在派生的 Rime 表这一层，`famo_quick_send.json` 仍存裸码 —— **存量短语自动获得前缀，不用重录**

### 主要功能更新 | Major Updates
- 设置「输入方式」卡片署名底座方案：拼音与双拼为雾凇拼音 rime-ice，五笔为极点五笔 86 (d496d19)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.1...1.5.2

<a name="1.5.1"></a>
## 1.5.1 (2026-07-25)

### 主要功能更新 | Major Updates
- 公开包自带清洁授权词库 `famotype_base`（8,454 单字读音 + 336,042 词条，jieba + phrase-pinyin-data + Unihan kTGH，全部 MIT / Unicode-3.0），词条限定《通用规范汉字表》8105 字；同时把繁体字形的 rime-essay 移出发行包 (89cf6ff)
- 首次随 Release 提供首装 DMG（内含 FamoInstaller.app，免注销安装）

### 構建 | Build
- `archive` 补上 `package/sign_update` 依赖，修掉 `Error 127` (37e3d43)
- release ci 只构建到 `package`；archive 与 appcast 由本地 `scripts/release.sh` 负责 (4075dc4)
- 发布门的版本队列断言改用 1.4.17 下限，不再钉死字面量 (e3b5983)
- bump actions/checkout from 6.1.0 to 7.0.1 (0102415)

### 文檔 | Documentation
- README 补安装段落、界面截图与英文版 (b7b09d1, c6e5b66)

**Full Changelog**: https://github.com/semantic-craft/famotype-macos/compare/1.5.0...1.5.1

<a name="1.5.0"></a>
## 1.5.0 (2026-07-24)

### Bug 修復 | Bug Fixes
- honor the show-preedit toggle under inline_preedit (63bb2f6)
- stop derived v-variant rows snowballing into duplicates (40b4a74)
- deploy --build into Famo's own data root, not the process cwd (d6df59d)
- wubi date_translator 修正正则不锚行尾（上游行带尾随注释） (5c726c5)
- deliver Famo CLI notifications immediately so --reload survives DNC suspension (#21)
- 发布净化门只拦私人家目录路径，放行上游 CI（GitHub runner）公共构建前缀

### security
- harden public single-repo development (42ec4eb)
- add Swift CodeQL and dependency updates (#10) (b75d7e8)

### 主要功能更新 | Major Updates
- split 香槟橙 into 藏蓝 and new 燃橙 skins (ecaa1b4)
- 首启用户侧拉取完整词库（方案B） (58b9fa7)

### 文檔 | Documentation
- remove internal development docs from the public tree (66feae1)

### 構建 | Build
- run the release gate on Xcode 26 and seed before packaged builds (5e9f75c)
- declare the periphery scan target (d2d196e)
- pin all workflow actions to full commit SHAs (50e9d57)
- declare least-privilege permissions on product workflows (8cc1cb6)

**Full Changelog**: https://github.com/rime/squirrel/compare/1.4.23...1.5.0

<a name="famo-1.4.23"></a>
## 法墨 Famo 1.4.23 (2026-07-23)

### 更新与分发 | Updates
- 公开核心加入固定版本 Sparkle 2.6.2 更新客户端；更新只读取 `responsay.com/famo/appcast.xml`，不上传输入内容或用户数据。
- Sparkle 更新载荷固定到公开源码/发版仓的同版本 tag，并显式声明 package 安装类型。

<a name="famo-1.4.4"></a>
## 法墨 Famo 1.4.4 (2026-07-10)

### 更新与分发 | Updates
- 修复 Mac 自动更新与 Windows 发布共用 `famo-releases` 时，repository-wide `Latest` 被 Windows 版本占用后导致 Sparkle 更新包和 DMG 链接返回 404 的问题；Mac appcast 现在固定到当前版本 tag。
- 发布脚本改为写入真实 Responsay 官网仓，并在上传时拒绝复用含非 Mac 资产的 tag；发布后验证会跟随重定向并要求最终下载状态成功。

<a name="famo-1.4.2"></a>
## 法墨 Famo 1.4.2 (2026-07-08)

### 设置与输入 | Settings
- 修复「应用默认英文」对用户在设置里手动添加的 App 不生效的问题：现在手动添加的 App 首次聚焦即进入英文态（此前仅出厂预设生效，手动添加的项因未接上生效链而静默无效）。
- 方案切换更稳健：切换拼音方案失败时显式提示而非静默吞掉，并对首键做防退化处理，减少偶发落回旧方案。

### 安装与更新 | Install
- 安装器首屏补充隐私说明，接住系统「可访问键入内容」提示。

<a name="famo-1.4.1"></a>
## 法墨 Famo 1.4.1 (2026-07-07)

### 输入体验 | Input
- 修复在 Chromium 系浏览器（Chrome / Edge 等）地址栏用拼音打整句、宿主强制结束合成时，会落下原始拼音串、且退格易把整段删光的问题：改为落已转换的中文，无转换时回退原码，绝不丢已输入内容。（浏览器地址栏在合成串变短时会单方面终结输入合成，属 Chromium omnibox 与输入法协调的上游限制，此为输入法侧的非破坏性处理。）

<a name="famo-1.3.26"></a>
## 法墨 Famo 1.3.26 (2026-06-29)

### 安装与更新 | Install
- 修复 1.3.25 安装器在 Famo 已运行时可能没有真正执行 `--activate-once` 的问题；安装器现在直接运行短命激活命令，确保更新后写回系统输入源列表并刷新菜单栏。

<a name="famo-1.3.25"></a>
## 法墨 Famo 1.3.25 (2026-06-29)

### 安装与更新 | Install
- 独立安装器在刷新 TIS 输入源后，会启动已安装的 `Famo.app --activate-once` 触发现有输入源自修复，补上 macOS 未立即把法墨放进菜单栏输入源列表的场景。

### AI 与同步 | AI & Sync
- 增加画词菜单开关和选中文本 AI 操作入口，支持带上下文打开 AI 对话并按需自动提交。
- 完善供应商配置、联网搜索能力标识和用户词库/同步相关设置的保存与测试覆盖。

<a name="famo-1.3.24"></a>
## 法墨 Famo 1.3.24 (2026-06-29)

### 安装与更新 | Install
- 独立安装器改为已真机验证的事务更新：先校验内嵌 `Famo.app` 的签名、bundle id 和版本，再以 `.new/.old` 根目录 swap 更新 `/Library/Input Methods/Famo.app`，失败回滚，避免 nested 坏包。
- 更新/修复场景只刷新 TIS 输入源和菜单代理，不强制切换当前输入法；首次安装才尝试切到「法墨」。

<a name="famo-1.3.23"></a>
## 法墨 Famo 1.3.23 (2026-06-28)

### 安装与更新 | Install
- 自动更新改为只提示新版本并引导前往 `responsay.com/famo` 下载独立安装器，不再通过 Sparkle/pkg 自动安装。

<a name="famo-1.3.22"></a>
## 法墨 Famo 1.3.22 (2026-06-28)

### 安装与更新 | Install
- 安装/自动更新后强制刷新 macOS「Text Input」菜单栏状态项的显隐开关，修复系统偏好已开启但菜单栏仍不显示「法墨输入法」的问题。

<a name="famo-1.3.21"></a>
## 法墨 Famo 1.3.21 (2026-06-28)

### 安装与更新 | Install
- 自动更新安装后同时刷新 `TextInputMenuAgent`、`TextInputSwitcher` 和 `SystemUIServer`，让法墨更及时出现在菜单栏输入法列表中。

<a name="famo-1.3.20"></a>
## 法墨 Famo 1.3.20 (2026-06-28)

### 五笔 | Wubi
- 修复极点五笔86下 `z` 临时拼音反查的候选编码提示，打开「候选编码提示」后 `znihao` 可显示 `你好 wqvb`。

<a name="famo-1.3.19"></a>
## 法墨 Famo 1.3.19 (2026-06-28)

### 设置清理 | Settings
- 移除未生效的「符号自动替换」开关，避免用户以为 `16：00` 会被自动改成 `16:00`。
- 移除未生效的「多行自动编号」开关。
- 将空格设置文案收窄为「中文与英文间加入空格」，不再承诺中文与数字之间自动加空格。

### 五笔 | Wubi
- 修复五笔 `z` 临时拼音反查配置，纯五笔和五笔拼音混输下都能看到反查编码提示。

<a name="famo-1.1"></a>
## 法墨 Famo 1.1 (2026-06-20)

首个面向公众发行的法墨版本（此前 1.0 为内测 beta）。本条目随发行任务 G1–G7 增补；当前仅落地发行身份。

### 发行身份 | Release
- 设定法墨自有 marketing 版本为 1.1：应用 target 新增 `MARKETING_VERSION = 1.1`，`resources/Info.plist` 增补 `CFBundleShortVersionString = $(MARKETING_VERSION)`。
- 「关于法墨」现显示 `1.1 (<build>)`；构建号沿用 `CURRENT_PROJECT_VERSION`（继承上游 1.1.2）。

> 以下为继承自上游 Squirrel 的变更历史。

<a name="1.1.2"></a>
## 1.1.2 (2026-01-13)

### 構建 | Build
- use macos-latest image runner (550b355)
- upgrade action with node 24 (2cc3d17)

### 雜項 | Miscellaneous
- update Icon that can adapt with system color scheme (714325e)
- remove unused arg in bump_version (32db10d)

**Full Changelog**: https://github.com/rime/squirrel/compare/1.1.1...1.1.2

<a name="1.1.1"></a>
## 1.1.1 (2026-01-11)

### 構建 | Build
- build universal binary (2154997)

**Full Changelog**: https://github.com/rime/squirrel/compare/1.1.0...1.1.1

<a name="1.1.0"></a>
## 1.1.0 (2026-01-11)

### Bug 修復 | Bug Fixes
- boundary check to prevent crash (#1044) (1a70873)
- no index offset to an empty string (#1045) (ab1db6c)
- 開啓 `inline_candidate` 選項後移動光標導致崩潰 (#1047) (6137702)
- 橫向候選詞列表末尾元素高亮區域渲染錯誤 (#1071)

### 主要功能更新 | Major Updates
- 「系統原生」風格 `native` 跟隨系統主題切換明暗色調；提高文字對比度 (2fb92e8)
- `librime` 更新至 1.16.0：
  - 優化音節切分算法，調整簡拼、歧義切分路徑的權重
  - 修復糾錯候選排序權重以及與造句的策略衝突
  - 拼寫運算增設容錯規則 `derive/X/Y/correction`
  - 輸入方案自動引用組件默認配置 `default:/{navigator,selector}`

### 構建 | Build
- remove paths filter from release-ci for nightly builds (5232c45)
- fix sign_update call (d9a9155)

**Full Changelog**: https://github.com/rime/squirrel/compare/1.0.3...1.1.0

<a name="1.0.3"></a>
## 1.0.3 (2025-01-23)

#### 主要功能更新
* 新增翻䈎提示，以`style/show_paging: true/false`控制
* `librime` 更新至1.13.0：
  * 數字後標點優化，可用`punctuator/digit_separators`調整
  * `translator`可用多個`tag`
  * 詳見 librime [更新紀錄](https://github.com/rime/librime/blob/master/CHANGELOG.md)，含 1.12、1.13 兩個主要版本更新

#### 其它更新內容
* bug 修復
  * 自emoji面板切換後無法使用的問題
  * 每次開機重新布署的問題

#### Major Update
* Added paging indicator, gated by `style/show_paging: true/false`
* Update `librime` to 1.13.0:
  * Optimized punctuator after digits, customizable by `punctuator/digit_separators`
  * Allow `translator` to take multiple `tag`s
  * See librime [change log](https://github.com/rime/librime/blob/master/CHANGELOG.md) for details, including 1.12 and 1.13 major updates

#### Other Updates
* Bug fixes:
  * IME unavailable after using emoji-selection panel
  * Deploy upon every start-up regardless of changes

**Full Changelog**: https://github.com/rime/squirrel/compare/1.0.2...1.0.3

<a name="1.0.2"></a>
## 1.0.2 (2024-06-07)

#### 其它更新內容
* bug 修復
  * 未設定暗色主題時，配色不生效
  * 橫排時序號偏高
  * 帶 Alt 的快捷鍵不生效
  * App 特定設置 inline 不生效
  * `good_old_caps_lock` 關閉，且 Caps Lock 啓用時，Shift 無法輸入大寫字母
* Edge 瀏覧器默認行內編輯 (修 #906)
* 日誌置於 $TMPDIR/rime.squirrel 內，以便查找

#### Other Updates
* Bug fixes:
  * `color_scheme` doesn't apply in dark mode when `color_scheme_dark` is not set
  * Label baseline too high in horizontal orientation
  * Shortcut with Alt doesn't work
  * inline option in app specific setting doesn't work
  * when `good_old_caps_lock` turned to false, and Caps Lock is on, Shift cannot product upper case letter
* Edge defaults to inline mode (fix #906)
* Logs dir is now $TMPDIR/rime.squirrel for clarity

**Full Changelog**: https://github.com/rime/squirrel/compare/1.0.1...1.0.2

<a name="1.0.1"></a>
## 1.0.1 (2024-06-01)

#### 其它更新內容
* bug 修復
  * 不再注冊爲拉丁輸入法，修復 Caps Lock 切換輸入法時不能切換至西文的問題
  * 修復配色中的 candidate_list_layout, text_orientation 不生效問題
  * 修復字體名無法解析時，字號不生效問題
* 不再支持 `style/horizontal` 和 `style/vertical`

#### Other Updates
* Bug fixes:
  * Remove Latn repertoire so that switching IME by Caps Lock can toggle Squirrel and Latin input
  * Fix: candidate_list_layout, text_orientation do not take effect when put in color scheme
  * Fix: font point is ignored when font face is invalid
* Drop support for `style/horizontal` and `style/vertical`

**Full Changelog**: https://github.com/rime/squirrel/compare/1.0.0...1.0.1

<a name="1.0.0"></a>
## 1.0.0 (2024-05-30)

#### 主要功能更新
* 純 Swift 重寫，代碼更易維護，更易讀，貢獻代碼的門檻更低。今天就來看看源代碼，嘗試動手吧！

#### 其它更新內容
* UI 設置【**敬請留意**】
  * `style/candidate_format` 格式修改爲 `"[label]. [candidate] [comment]"`，原格式仍能使用，但建議遷移至更靈活、直觀的新格式
  * `style/horizontal` 將徹底移除，雖然本版程序仍支持，但會被新控件的默認值覆蓋
    請使用 `candidate_list_layout`: `stacked`/`linear` 和 `text_orientation`: `horizontal`/`vertical`
  * `style/label_hilited_color` 已移除，請使用 `style/hilited_candidate_label_color`
  * `native` 配色小幅修改，減小字號，更像原生輸入法
* UI 
  * 在菜單欄新增日志檔案夾，方便快速進入
  * 序號居中顯示，更像原生輸入法
* 新增 `--help` 命令行命令，以便查詢支持的命令
* bug 修復
  * 減少使用<kbd>⇧</kbd>輸入大寫時造成中英切換的可能性
* librime：使用 stdbool 後綴 API，以便與 Swift 更好橋接

#### Major Update
* Migrated code to pure Swift, which is easier to code, read and learn. Build your own Squirrel today!

#### Other Updates
* UI settings (**Breaking Changes**)
  * `style/candidate_format` now updated to `"[index]. [candidate] [comment]"`, while the old format still works, please consider migrating to this more readable and flexible format at your convenience
  * `style/horizontal` will be dropped, it's still supported but will be overwrite by the default values of new options.
    Please adopt `candidate_list_layout`: `stacked`/`linear` and `text_orientation`: `horizontal`/`vertical`
  * `style/label_hilited_color` is removed, please use `style/hilited_candidate_label_color` instead
  * `native` color scheme is updated with smaller font size, to better match macOS builtin IME
* UI
  * Added a menu item for logs folder with easy access
  * labels will vertically center if label font is smaller than candidate font, to better match macOS builtin IME
* Added `--help` command line argument
* Bug fixes:
  * Reduce the chance that ascii mode may unintentionally switch when pressing <kbd>⇧</kbd> to enter Cap case
* librime: Use stdbool flavored API, for better Swift interoperation

**Full Changelog**: https://github.com/rime/squirrel/compare/0.18...1.0.0

<a name="0.18"></a>
## 0.18 (2024-05-04)

#### 主要功能更新
* 現可設定非高亮候選項背景色：
  * 以 `preset_color_schemes/xxx/candidate_back_color: 0xAABBGGRR` 設定，未設定則不啓用本功能
  * 以 `style/surrounding_extra_expansion` 控制非高亮候選背景大小，正數則相對高亮背景擴大，負數則相對高亮背景收縮，默認爲0
* 更稳定的介面渲染，尤其繪文字無論橫排豎排皆能穩定顯示，行高不會跳變
* 支持鼠標操作：
  * 鼠標懸浮則更改高亮候選，點擊則選定候選，滾輪和觸控板滑動則翻䈎
  * 點擊編碼區則可前後移動光標位置
* 其它介面改進：
  * 解決候選框首次出現可能位於屏幕一角的問題
  * `style/border_height`、`style/border_width`、`style/line_spacing`、`style/spacing`現可正確處理負值
  * 字號可包含小數
  * 序號字號不同於候選字號時，序號居中
  * 可以`style/status_message_type`: `mix`(default) / `long` / `short`控制狀態改變時如何展示狀態標籤，默認短標籤優先，無短標籤則使用完整標籤，不再自動截取完整標籤首字，除非設爲`short`
  * 以`style/memorize_size`: `true`/`false`控制候選標是否在接觸屏幕邊緣時有粘性
  * `style/alpha`可爲0，爲0則完全隱藏候選框
  * 以`style/shadow_size`設定高亮候選背景的陰影，默認爲0，即無陰影
  * 以`style/mutual_exclusive`: `true`/`false`控制半透明顏色是否互相疊加，默認爲`false`，即互相疊加
* `librime` 更新至1.11.2：
  * 詳見 librime [更新紀錄](https://github.com/rime/librime/blob/master/CHANGELOG.md)，含 1.9、1.10、1.11 三個主要版本更新
* librime 插件現單獨構建，不再合併於 librime 內，本安裝包含 `lua`、`octagram`、`predict` 三個插件
* 最低支持的系統應爲 13.0，14.0 以上系統經過較好測試

#### 其它更新內容
* 啓用CI自動構建
* 應用 Clang 格式標準化
* 更新已過時的方法
* 支持沙盒機制

#### Main Updates
* Surrounding high lights for all candidates:
  * Set `preset_color_schemes/xxx/candidate_back_color` to enable (Not specified unless explicitly defined)
  * `style/surrounding_extra_expansion` controls the relative size to the selected candidate's surrounding block. Negative value means smaller, while positive means larger, default to 0.
* More reliable text layout, especially in vertical mode, and with exotic characters like Emoji.
* Mouse interactions:
  * Hover over to change selection, click on any candidate to select, and swipe or scroll to change page
  * Click in preedit area to change caret position
* Other UI improvements:
  * Resolve a issue that Squirrel panel shows in corner on first launch
  * `style/border_height`, `style/border_width`, `style/line_spacing` and `style/spacing` can now be negative.
  * All `font_size` accepts float number.
  * Labels are vertically centered when using a different `label_font_size` from the main `font_size`
  * Add `style/status_message_type`: `mix(default) / long / short` to Handle abbrev status label when status updates
  * Add `style/memorize_size: true/false` to control sticking panel width behavior 
  * `style/alpha: 0` is now valid, setting so completely hides the panel
  * Add `style/shadow_size` to specify shadow under selected candidate. Default to `0` with no shadow.
  * Add `style/mutual_exclusive`: `true`/`false` to allow colors not stacking on each other. Default to `false`
* `librime` updated to 1.11.2:
  * See librime [change log](https://github.com/rime/librime/blob/master/CHANGELOG.md) for details, including 1.9, 1.10 and 1.11 major updates
* librime plugins are built separately, no longer integrated inside librime library. This install package is compiled with `lua`, `octagram` and `predict` plugins
* Minimum OS supported should be 13.0, while 14.0+ is better tested

#### Other Updates
* Adopts CI workflow
* Applies Clang linting
* Modernized several deprecated methods
* Supports sandbox

#### 完整更新列表 Change Log
* build: specify build target OS in makefile by @LEOYoon-Tsaw in https://github.com/rime/squirrel/pull/727
* Consolidated update to Squirrel by @LEOYoon-Tsaw in https://github.com/rime/squirrel/pull/749
* Update INSTALL.md: Fix script by @EdgarDegas in https://github.com/rime/squirrel/pull/800
* fix action-changelog.sh by @hezhizhen in https://github.com/rime/squirrel/pull/794
* Update weasel introduction in README.md by @determ1ne in https://github.com/rime/squirrel/pull/777
* Upgrade GitHub action to v4 by @Bambooin in https://github.com/rime/squirrel/pull/834
* chore: use macos 14 runner with M1 by @Bambooin in https://github.com/rime/squirrel/pull/835
* Add mac app sandbox support. by @ShikiSuen in https://github.com/rime/squirrel/pull/841
* Apply clang format by @Bambooin in https://github.com/rime/squirrel/pull/836
* fix: fix wrong git blame ignore by @Bambooin in https://github.com/rime/squirrel/pull/845
* replace deprecated API calls by @groverlynn in https://github.com/rime/squirrel/pull/846
* fix(FamoPanel): text shown in top-left corner by @lotem in https://github.com/rime/squirrel/pull/856
* deps: update librime to 1.11.0 by @ksqsf in https://github.com/rime/squirrel/pull/860
* build(ci): nightly release by @ksqsf in https://github.com/rime/squirrel/pull/861
* ci: disable nightly build in forked repos by @Bambooin in https://github.com/rime/squirrel/pull/862

#### 新增貢獻者 New Contributors
* @EdgarDegas made their first contribution in https://github.com/rime/squirrel/pull/800
* @hezhizhen made their first contribution in https://github.com/rime/squirrel/pull/794
* @determ1ne made their first contribution in https://github.com/rime/squirrel/pull/777
* @ksqsf made their first contribution in https://github.com/rime/squirrel/pull/860

**Full Changelog**: https://github.com/rime/squirrel/compare/0.16.2...0.18

<a name="0.16.2"></a>
## 0.16.2 (2023-02-05)

#### 須知

 * 升級安裝後遇輸入法不可用，須手動重新添加 [#704](https://github.com/rime/squirrel/issues/704)

#### 主要更新

 * 更新 Rime 核心算法庫至 [1.8.5](https://github.com/rime/librime/releases/tag/1.8.5)
 * 修復：橫向候選欄 Tab 鍵應當用作移動插入點 [rime/librime#609](https://github.com/rime/librime/issues/609)
 * 修復：macOS Mojave 及以下版本單擊 Shift 等修飾鍵失效 [#715](https://github.com/rime/squirrel/issues/715)
 * 修復：全新安裝只添加一個輸入法選項（簡體中文） [#714](https://github.com/rime/squirrel/issues/714)


#### Bug Fixes

*   modifier change event in older macOS ([5c2b7e64](https://github.com/rime/squirrel/commit/5c2b7e64980b7e6b7eb3a8b392163ce89d244f37))
*   install one input mode or keep previous ones ([3bc6c2c0](https://github.com/rime/squirrel/commit/3bc6c2c0edbb1adaa22e79da65c6f0116b164de7))



<a name="0.16.1"></a>
## 0.16.1 (2023-01-30)


#### 主要更新

 * 更新 Rime 核心算法庫至 [1.8.4](https://github.com/rime/librime/releases/tag/1.8.4)
 * 修復：橫向候選欄不響應左方向鍵移動插入點



<a name="0.16.0"></a>
## 0.16.0 (2023-01-30)


#### 主要更新

 * 輸入狀態變化時顯示方案中設定的狀態名稱 [#540](https://github.com/rime/squirrel/pull/540)
 * 修正繪文字行高 [#559](https://github.com/rime/squirrel/issues/559)
 * 支持半透明視窗背景 [#589](https://github.com/rime/squirrel/pull/589)
 * 由 GitHub Actions執行自動構建 [#633](https://github.com/rime/squirrel/pull/633)
 * 將鼠鬚管的輸入語言註冊爲簡體中文及繁體中文 [#648](https://github.com/rime/squirrel/pull/648)
 * 可指定使用任意一種系統鍵盤佈局 [#687](https://github.com/rime/squirrel/pull/687)
   例如： `squirrel.yaml:/keyboard_layout: USExtended`
 * 區分左、右修飾鍵 [#688](https://github.com/rime/squirrel/pull/688)
 * 支持以命令行方式同步用戶數據 [#694](https://github.com/rime/squirrel/pull/694)
   命令： `Squirrel --sync`
 * 更新 Rime 核心算法庫至 [1.8.3](https://github.com/rime/librime/releases/tag/1.8.3)



<a name="0.15.2"></a>
## 0.15.2 (2021-02-13)


#### 主要更新

* 切換到其他輸入法或鍵盤時提交未轉換的輸入
* 修復工單 [#513](https://github.com/rime/squirrel/issues/513)
* 重製應用圖標，提升暗色背景下的可見度

#### Bug Fixes

* **FamoInputController:**  commit raw input when switching to other IME, closes #146 ([b875d194](https://github.com/rime/squirrel/commit/b875d194d9799ccc74453292c670fcca892799fa))
* **FamoPanel:**  use of uninitialized local variable linear, vertical ([e8b87a4f](https://github.com/rime/squirrel/commit/e8b87a4f97994001c6889ecc1d43fa38e7589e66))

#### Features

* **RimeIcon:**  updated app icon ([76d742b8](https://github.com/rime/squirrel/commit/76d742b8ee271c24dae5f98251a93930e57279ec))



<a name="0.15.1"></a>
## 0.15.1 (2021-02-11)


#### 主要更新

* 升級核心算法庫 [librime 1.7.3](https://github.com/rime/librime/blob/master/CHANGELOG.md#173-2021-02-11)
  * 修復若干內存安全問題
  * 修復並擊輸入法回車鍵上屏字符按鍵序列

* 指定候選註釋文字的字體、字號 `style/comment_font_face`, `style/comment_font_point`
* 修復無數字序號的候選樣式 `style/candidate_format`
* 優化界面代碼

#### Performance

* **FamoPanel:**  decompose candidate_format when loading theme ([803f6421](https://github.com/rime/squirrel/commit/803f64218384b505cbea1289af85a2b65f8f83f5), closes [#516](https://github.com/rime/squirrel/issues/516))

#### Bug Fixes

*   avoid implicit lossy integer transform ([da4fcbf2](https://github.com/rime/squirrel/commit/da4fcbf2b77ca8298eaa8043937ee2c98f95ee0f))
* **FamoPanel:**
  *  vertical glyph in comment text with smaller font ([c2e6f434](https://github.com/rime/squirrel/commit/c2e6f4347413a67278ab12eb388d5225e02e3fb1), closes [#522](https://github.com/rime/squirrel/issues/522))
  *  unspecified comment_font_point falls back to font_point ([8194d95a](https://github.com/rime/squirrel/commit/8194d95a82554c453f84ff4dd30eaa51affd10ae))
* **FamoPanel.m:**  error with candidate_format without the label part ([d2b839b6](https://github.com/rime/squirrel/commit/d2b839b6b5c415aa1cdd28e1ef7921949b90ee21), closes [#516](https://github.com/rime/squirrel/issues/516))

#### Features

* **FamoPanel:**  comment font config (#511) ([3d0ab6a2](https://github.com/rime/squirrel/commit/3d0ab6a209c31c0ac2b97bd8ab1bddcc269aa9bb))



<a name="0.15.0"></a>
## 0.15.0 (2021-02-06)


#### 主要更新

* 升級核心算法庫 [librime 1.7.1](https://github.com/rime/librime/blob/master/CHANGELOG.md#171-2021-02-06)
  * 遣詞造句性能提升40%
  * 支持拼音輸入法詞典擴展包
  * 升級中日韓統一表意文字和繪文字字符集數據
  * 並擊輸入支持Control、Shift等修飾鍵

* 發行通用二進制代碼，兼容搭載Intel處理器及Apple芯片的Mac電腦

* 界面新功能
  * 在原有界面樣式基礎上新增顯示直書文字的選項 `style/text_orientation`
  * 支持顯示輸入方案自定義的候選序號 `menu/alternative_select_labels`
  * 候選窗超長文字折行顯示
  * 編輯區高亮區塊支持圓角
  * 新增外觀配置項 `border_color`, `preedit_back_color`, `base_offset`（文字基線調整）
  * 支持P3色域
  * 「系統配色」自動適應深淺色外觀，或由用家自選用於深色模式的配色方案
  * 新增明暗兩款Solarized配色方案
    [`squirrel.yaml`](https://github.com/rime/squirrel/blob/master/data/squirrel.yaml)演示了P3色域、自選深淺系配色方案的用法

* 修復及規避若干軟件兼容問題

![有詩爲證](https://github.com/rime/home/raw/master/images/squirrel-vertical-text-light.png)
![有圖爲證](https://github.com/rime/home/raw/master/images/squirrel-vertical-text-dark.png)

#### Bug Fixes

* **FamoInputController:**  add back the Chrome address bar hack ([22ed91ea](https://github.com/rime/squirrel/commit/22ed91ea7d2c9807dedc8cd68709c82cdb3a5fd8), closes [#299](https://github.com/rime/squirrel/issues/299))
* **FamoPanel:**
  *  properties custom getter got wrong names ([d509c779](https://github.com/rime/squirrel/commit/d509c7791d288722a6782cca8c9afd7d0b440db5), closes [#494](https://github.com/rime/squirrel/issues/494))
  *  label format after candidate repeats label before, Closes #489 ([d2c34107](https://github.com/rime/squirrel/commit/d2c34107bdbec5767865582e4d217e546d576eca))
  *  native color scheme can only use semantic colors ([e6c69598](https://github.com/rime/squirrel/commit/e6c695983e610bd78d8c43b033a4c3602b632730))
  *  reimplement blendColors, tune background color fraction to increase contrast ([9b890f60](https://github.com/rime/squirrel/commit/9b890f60667c291216ff971b176534627f6a1cac))
* **FamoPanel.m:**  index out of bounds at drawSmoothLines() ([241b457f](https://github.com/rime/squirrel/commit/241b457fc0378c733ead8cb9352c156c12198cec))
* **build:**
  *  exclude architecture arm64 ([51f62cf7](https://github.com/rime/squirrel/commit/51f62cf7e52d779f8721f2ffcf5fc2b6720155c3))
  *  fix codesign error on Xcode11 ([11486644](https://github.com/rime/squirrel/commit/1148664423ae1fc986df184ef2f794790cd31834))
* **data/squirrel.yaml:**
  *  force inline in Chrome to work around bksp ([69112996](https://github.com/rime/squirrel/commit/69112996441fdae1d1778ac9a32eb98f6a8e7841))
  *  force inline mode in Telegram app ([34f2d382](https://github.com/rime/squirrel/commit/34f2d38216a7483ed8634da5de8409f6a3d7f542))
* **squirrel.yaml:**  unset default value for style/candidate_list_layout to fall back style/horizontal ([a9af3364](https://github.com/rime/squirrel/commit/a9af33644ff6c5ab0b7ea90a2af6715f1113fd68))

#### Features

* **FamoConfig:**  support display P3 color space ([8ff5f8d0](https://github.com/rime/squirrel/commit/8ff5f8d024c034f2217c67cf8dc77aa47a5a7b34))
* **FamoInputController:**
  *  app option `inline` forces inline mode ([699fee0f](https://github.com/rime/squirrel/commit/699fee0fd2c9808667fd60426f1abc8c09d7ff8d))
  *  support chording with Control, Alt or Shift keys ([118aee61](https://github.com/rime/squirrel/commit/118aee617089b4c7a3e448a42ea0b4c65eae5895))
* **FamoPanel:**
  *  optimize window size for big/small text ([150c5533](https://github.com/rime/squirrel/commit/150c5533f8862b242e1837fb0b62e97429cbb2a3))
  *  merge lyc/dark_mode, with slight modifications ([5a587fca](https://github.com/rime/squirrel/commit/5a587fca16d7b6c842682f285949041871ed80bf), closes [#449](https://github.com/rime/squirrel/issues/449))
* **app_options:**  support the `vim_mode` app option ([08ed4f45](https://github.com/rime/squirrel/commit/08ed4f4590e17c969f1536b347bbe1f05737d4aa), closes [#124](https://github.com/rime/squirrel/issues/124))
* **data/squirrel.yaml:**  solarized color schemes ([35b9ea76](https://github.com/rime/squirrel/commit/35b9ea76d2c3c4ce095bc838948ba43761022a12))
* **ui:**  vertical text orientation, rounded corner text with TextStorage, wrapping lone lines and border color ([c6c9302d](https://github.com/rime/squirrel/commit/c6c9302dcd537e0b72af729082390483bc3d07c0))



<a name="0.14.0"></a>
## 0.14.0 (2019-06-23)


#### 主要更新

* 升級核心算法庫 [librime 1.5.3](https://github.com/rime/librime/blob/master/CHANGELOG.md#153-2019-06-22)
  * 修復 `single_char_filter` 組件

* 建設安全、可靠、快速的全自動構建、發佈流程

* 安裝「八股文」語法數據庫（傳承字），可依照 [配方](https://github.com/lotem/rime-octagram-data) 在方案裏啓用

#### Features

* **package/add_data_files:**  update xcode project to install all files under data/plum ([2ab1810e](https://github.com/rime/squirrel/commit/2ab1810e94b963df27e6fd2e399465ccdabba138))
* **travis-ci:**  fetch latest rime binaries in install script, install extra recipes ([027679d5](https://github.com/rime/squirrel/commit/027679d58974845a83a393a313bbd63462a795b1))



<a name="0.13"></a>
## 0.13 (2019-06-17)


#### 主要更新

* 升級核心算法庫 [librime 1.5.2](https://github.com/rime/librime/blob/master/CHANGELOG.md#152-2019-06-17)
  * 修復用戶詞的權重，穩定造句質量、平衡翻譯器優先級 [librime#287](https://github.com/rime/librime/issues/287)

* 安裝預設輸入方案集，避免大多數方案依賴問題 [#279](https://github.com/rime/squirrel/issues/279)

#### Features

* **plum:**  bundle preset recipes ([7885c5fa](https://github.com/rime/squirrel/commit/7885c5fa6006e999c5a07ac1800e9afa15d629a8))



<a name="0.12.0"></a>
## 0.12.0 (2019-06-16)


#### 主要更新

* 升級核心算法庫 [librime 1.5.1](https://github.com/rime/librime/blob/master/CHANGELOG.md#151-2019-06-16)
  * 建設全自動構建、發佈流程
  * 更新第三方庫
  * 將Rime插件納入自動化構建流程。本次發行包含兩款插件：
    - [lbrime-lua](https://github.com/hchunhui/librime-lua)
    - [librime-octagram](https://github.com/lotem/librime-octagram)

#### Bug Fixes

* **squirrel.yaml:**  duplicate YAML key in color scheme dust ([44a4d7ee](https://github.com/rime/squirrel/commit/44a4d7ee3cad94c170616b7c8d9415a4f92c86d5))

#### Features

* **squirrel.yaml:**  udpate UI settings ([d8b1dc56](https://github.com/rime/squirrel/commit/d8b1dc569cc2c168f0fc5e8240ff6e049142fc24))
* **travis-ci:**  deploy release package ([c367b675](https://github.com/rime/squirrel/commit/c367b675bbca4f7e4467b71b9f42adbb888b77a5))



<a name="0.11.0"></a>
## 0.11.0 (2019-01-21)


#### 主要更新

* 安裝完成要求退出登錄，以保證註冊輸入法生效
* 修復升級、部署數據時發生的若干錯誤
* 關閉候選窗對摸蝦未系統深色模式的自動適配，以消除多餘的黑色邊框
* 新增 [拼寫糾錯](https://github.com/rime/librime/pull/228) 選項
  當前僅限 QWERTY 鍵盤佈局及使用 `script_translator` 的方案

#### Features

* **librime:**  update to librime 1.4.0 ([1f07c63c](https://github.com/rime/squirrel/commit/1f07c63c51f60ea5514819c0f3a05c33ee9aba5d))
* **pkg:**  logout after install ([c84001ea](https://github.com/rime/squirrel/commit/c84001ea4348b902543938d89d68306b1ea86b3f))
* **travis-ci:**  add Travis CI automated build ([8855101c](https://github.com/rime/squirrel/commit/8855101c0d90c118d4d1d58b757d11d76354bcda))

#### Bug Fixes

* **app:**  opt out of dark mode ([083817cb](https://github.com/rime/squirrel/commit/083817cba5ccb1f5b9589b7e7a2fbeca4ec4d9dd), closes [#273](https://github.com/rime/squirrel/issues/273))



<a name="0.10.0"></a>
## 0.10.0 (2019-01-01)


#### 主要更新

* 重新設計輸入法介面
* 新增介面配色方案：
  - 幽能／Psionics，作者：雨過之後、佛振，見於 [Rime 主頁](https://rime.im) 效果圖
  - 純粹的形式／Purity of Form
  - 純粹的本質／Purity of Essence
  - 冷漠／Apathy, 作者：LIANG Hai
  - 浮尘／Dust，作者：Superoutman
  - 沙漠夜／Mojave Dark，作者：xiehuc，使用新增的高亮區域圓角特性
  感謝所有 Rime 用家發揮創造力、參與輸入法的藝術加工。新的配色主題層出不窮。
  礙於能量有限，僅收錄了部分貢獻者的配色方案，以展示不同的設計思路和定製技巧。
  請大家利用各種平臺多多分享代碼。
* 改進對全屏遊戲的兼容性
* 修復了並擊輸入（chord-typing）的偶發錯誤
* 升級核心算法庫 [librime 1.3.2](https://github.com/rime/librime/blob/master/CHANGELOG.md#132-2018-11-12)
  * 支持 YAML 節點引用，方便模塊化配置
  * 改進部署流程，在 `build` 子目錄集中存放生成的數據文件
* 精簡安裝包預裝的輸入方案，更多方案可由 [東風破](https://github.com/rime/plum) 取得

#### Features

* **FamoPanel:**  add mojave_dark theme and hilited_corner_radius option ([51a1c8c8](https://github.com/rime/squirrel/commit/51a1c8c840cfc9093ad56777873c8a62abc4964f))
* **app icon:**  update app icon ([593ca16e](https://github.com/rime/squirrel/commit/593ca16ebc87852213348b55d1072d898af75ab6))
* **brise:**  new preset configuration; disable prebuilding binary data during install ([43f4eb0a](https://github.com/rime/squirrel/commit/43f4eb0a0f1551f385f517a24ba30ac364af2a8c))
* **chord:**  Tab, BackSpace, Return can be used as chording keys ([997f1539](https://github.com/rime/squirrel/commit/997f15396615de4a3f65e5595ce1f5edf75263a1))
* **data/squirrel.yaml:**  add two more color schemes ([48b5138c](https://github.com/rime/squirrel/commit/48b5138c53d30e433a5c4de95c7a366e51f94e2e))
* **install:**  preload minimal rime data, fetch packages in postinstall script ([d2b174c9](https://github.com/rime/squirrel/commit/d2b174c9bbb263f1cf0953ddb4a607e68525e396))
* **package:**  make package && make archive ([c350c086](https://github.com/rime/squirrel/commit/c350c086d7321157c955275bbc4cec02a7f9b9eb))
* **squirrel.yaml:**
  *  add color schemes `purity_of_essence`, `apathy`, `dust` ([246a5797](https://github.com/rime/squirrel/commit/246a5797c49bd941fff80523523935dcf3c9a14d))
  *  ascii mode by default in hyper.is ([bda9f48e](https://github.com/rime/squirrel/commit/bda9f48e9c49f2514b885e31cceca579204506c3))
* **submodules:**  switch to /plum/ ([56e62287](https://github.com/rime/squirrel/commit/56e62287004b3f4579c966ed654d92e1dfc51f5e))

#### Bug Fixes

* **FamoPanel:**
  *  highlight overlapping between adjacent candidates ([128c8f31](https://github.com/rime/squirrel/commit/128c8f310e70112282d445aa3716774850fc846c))
  *  fix rounding errors and highlight rounding corners correctly ([026c6980](https://github.com/rime/squirrel/commit/026c6980b5b5899c2f0b2be2c61d315cc49552c9), closes [#240](https://github.com/rime/squirrel/issues/240))
  *  display panel on top level in the proper way ([cee5c5d7](https://github.com/rime/squirrel/commit/cee5c5d70e523f4ab6c336dfd8941f7d7a7d3c35))
* **chord input:**  unfinished chord often caused by fast tap typing ([672af6c9](https://github.com/rime/squirrel/commit/672af6c972fcb99e532b171488ef0a4a3f06e985))
* **postinstall:**
  *  Revert "fix(postinstall): run rime-install preset packages" ([f0a2f45b](https://github.com/rime/squirrel/commit/f0a2f45bba81cafb5a67df09d4392750a38f0483), closes [#262](https://github.com/rime/squirrel/issues/262))
  *  run rime-install preset packages ([de8f32a2](https://github.com/rime/squirrel/commit/de8f32a2c00c4fac4cd0a23b80722e3129477086))
  *  run `Squirrel --install` as login user; do not update packages during installation ([66948afe](https://github.com/rime/squirrel/commit/66948afe6c50ef1a72a55abd505d2c8ceae4fe37))



<a name="0.9.26.2"></a>
## 鼠鬚管 0.9.26.2 (2014-12-23)

  * 修復：安裝後輸入法在一些 app 中無法啓用 [#43](https://github.com/lotem/squirrel/issues/43)

<a name="0.9.26.1"></a>
## 鼠鬚管 0.9.26.1 (2014-12-22)

  * 修復：0.9.26 版本設置 `translator/enable_user_dict: false` 發生崩潰

<a name="0.9.26"></a>
## 鼠鬚管 0.9.26 (2014-12-16)

#### 【鼠鬚管】變更集

  * 修復：在 Java 程序（如 IntelliJ IDEA）中不能輸入的問題
  * 修復：`app_options:` 在 OS X 10.10 Yosemite 下無效的問題

#### Rime 算法庫變更集

  * 變更：採用 LevelDB 格式的用戶詞典，舊的用戶詞典 `*.kct` 將在部署時升級
  * 優化：新的 `.bin` 固態詞典結構，可節省 20% ~ 50% 空間
  * 新增：中文／西文半角標點切換
  * 改進：摺疊方案選單中的狀態切換選項以顯示更多方案，按空格鍵或選 2 展開選項
  * 改進：向左右移動光標後，回退鍵（BackSpace）用於刪除編碼字符而非撤銷選詞
  * 修復：【地球拼音】兼作聲調的「,」鍵在其他情況下未識別爲逗號
  * 修復：`affix_segmentor` 選擇部分匹配的候選詞後應使標籤繼續有效
  * 修復：OpenCC 配置文件及詞典缺失時輸入法崩潰
  * 新增：`cjk_minifier` 可用作 filter 過濾拼音輸入法中的罕用字
  * 新增：`single_char_filter` 使字型輸入法中的候選單字優先於詞組
  * 新增：匹配編碼並自動上屏，配置項 `speller/auto_select_pattern:`

#### 【東風破】變更集

  * 新增：OpenCC 1.0 詞典及配置文件，提供繁→簡、簡→繁轉換及臺灣、香港用字標準
  * 新增：【拼音加加】雙拼方案，標識爲 `double_pinyin_pyjj`
  * 新增：【朙月拼音】【倉頡五代】用 `/a`、/1` 輸入特殊字符、數字
  * 修復：【注音】省略聲調時，音節切分歧義處理不當
  * 優化：【宮保拼音】自動清除無效的按鍵組合
  * 優化：`symbols.yaml` 調整常用字符的順序
  * 更新：【八股文】【朙月拼音】【地球拼音】【粵拼】【中古漢語拼音】

<a name="0.9.25"></a>
## 鼠鬚管 0.9.25 (2014-03-29)

#### Rime 算法庫變更集

  * 新增：中西文切換方式 `clear`，切換時清除未完成的輸入
  * 改進：長按 Shift（或 Control）鍵不觸發中西文切換
  * 改進：並擊輸入，若按回車鍵則上屏按鍵對應的字符
  * 改進：支持對用戶設定中的列表元素打補靪，例如 `switcher/@0/reset: 1`
  * 改進：缺少詞典源文件 `*.dict.yaml` 時利用固態詞典 `*.table.bin` 完成部署
  * 修復：自動組詞的詞典部署時未檢查【八股文】的變更，導致索引失效、候選字缺失
  * 修復：`comment_format` 會對候選註釋重複使用多次的BUG

#### 【東風破】變更集

  * 新增：快捷鍵 `Control+.` 切換中西文標點
  * 更新：【八股文】【朙月拼音】【地球拼音】【五筆畫】
  * 改進：【朙月拼音·語句流】`/0` ~ `/10` 輸入數字符號

<a name="0.9.24.2"></a>
## 鼠鬚管 0.9.24.2 (2013-12-25)

#### 【鼠鬚管】變更集

  * 修復：MySQL Workbench 崩潰

#### Rime 算法庫變更集

  * 更新：librime 升級到 1.1
  * 新增：固定方案選單排列順序的選項 `default.yaml`: `switcher/fix_schema_list_order: true`
  * 修復：正確匹配嵌套的“‘彎引號’”
  * 改進：碼表輸入法自動上屏及頂字上屏（[示例](https://gist.github.com/lotem/f879a020d56ef9b3b792)）<br/>
    若有 `speller/auto_select: true`，則選項 `speller/max_code_length:` 限定第N碼無重碼自動上屏
  * 優化：爲詞組自動編碼時，限制因多音字而產生的組合數目，避免窮舉消耗過量資源

#### 【東風破】變更集

  * 新增：【注音·臺灣正體】
  * 更新：【粵拼】匯入衆多粵語詞彙
  * 優化：調整部分異體字的字頻

<a name="0.9.23"></a>
## 鼠鬚管 0.9.23 (2013-12-01)

#### 【鼠鬚管】變更集

  * 新增：非嵌入式編碼行，`style/inline_preedit: false`
  * 變更：候選窗默認英文字體設爲 Lucida Grande，非嵌入模式中較爲美觀
  * 改進：高亮候選的背景色延伸到候選註釋區域，新增配色選項 `hilited_comment_text_color:`
  * 改進：提示（碼表輸入法）大字符集開關狀態「通用／增廣」
  * 修復：[Issue 509](https://code.google.com/p/rimeime/issues/detail?id=509) 打開方案選單時設定 `style/label_color` 被重置

#### Rime 算法庫變更集

  * 更新：librime 升級到 1.0
  * 修復：`table_translator` 按字符集過濾候選字，修正對 CJK-D 漢字的判斷

#### 【東風破】變更集

  * 優化：【粵拼】兼容[教育學院拼音方案](http://zh.wikipedia.org/wiki/%E6%95%99%E8%82%B2%E5%AD%B8%E9%99%A2%E6%8B%BC%E9%9F%B3%E6%96%B9%E6%A1%88)
  * 更新：`symbols.yaml` 由 Patricivs 重新整理符號表
  * 更新：Emoji 提供更加豐富的繪文字
  * 更新：【八股文】【朙月拼音】【地球拼音】【中古全拼】修正錯別字、註音錯誤

<a name="0.9.22"></a>
## 鼠鬚管 0.9.22 (2013-11-09)

#### 【鼠鬚管】變更集

  * 變更：不再支持 OS X 10.6，因切換到 libc++
  * 修復：安裝後重新登錄系統，鼠鬚管從輸入法列表中消失的BUG
  * 優化：更換狀態欄圖標，與系統自帶輸入法風格一致

#### Rime 算法庫變更集

  * 優化：同步用戶資料時自動備份自定義短語等 .txt 文件
  * 修復：【地球拼音】反查拼音失效的問題
  * 變更：編碼提示不再添加括弧（，）及逗號，可自行設定樣式

#### 輸入方案設計支持

  * 新增：`affix_segmentor` 分隔編碼的前綴、後綴
  * 改進：`translator` 支持匹配段落標籤
  * 改進：`simplifier` 支持多個實例，匹配段落標籤
  * 新增：`switches:` 輸入方案選項支持多選一
  * 新增：`reverse_lookup_filter` 爲候選字標註指定種類的輸入碼

#### 【東風破】變更集

  * 更新：【粵拼】補充大量單字的註音
  * 更新：【朙月拼音】【地球拼音】導入 Unihan 讀音資料
  * 改進：【地球拼音】【注音】啓用自定義短語
  * 修復：【朙月拼音·簡化字】通過快捷鍵 `Control+Shift+4` 簡繁切換
  * 改進：【倉頡五代】開啓繁簡轉換時，提示簡化字對應的傳統漢字
  * 變更：間隔號採用「·」`U+00B7`

<a name="0.9.21.1"></a>
## 鼠鬚管 0.9.21.1 (2013-10-09)

  * 修復：從上一個版本升級【倉頡】輸入方案不會自動更新的問題

<a name="0.9.21"></a>
## 鼠鬚管 0.9.21 (2013-10-06)

  * 新增：【倉頡】開啓自動造詞<br/>
    連續上屏的5字（依設定）以內的組合，或以連打方式上屏的短語，
    按構詞規則記憶爲新詞組；再次輸入該詞組的編碼時，顯示「☯」標記
  * 變更：【五筆】開啓自動造詞；從碼表中刪除與一級簡碼重碼的鍵名字
  * 變更：【地球拼音】當以簡拼輸入時，爲5字以內候選標註完整帶調拼音
  * 新增：【五筆畫】輸入方案（`stroke`），取代 `stroke_simp`
  * 新增：支持在輸入方案中設置介面樣式（`style:`）<br/>
    如字體、字號、橫排／直排等；配色方案除外
  * 改進：在 MacVim 中按 `^C` 或 `^[` 退出插入模式時自動切換輸入法
  * 改進：碼表輸入法連打，按 `Shift+BackSpace`、←鍵以字、詞爲單位回退
  * 修復：多次按「.」鍵翻頁後繼續輸入，不應視爲網址而在編碼中插入「.」
  * 修復：開啓候選字的字符集過濾，導致有時不出現連打候選詞的 BUG
  * 更新：修訂【八股文】詞典、【朙月拼音】【地球拼音】【粵拼】【吳語】
  * 更新：2013款 Rime 輸入法圖標

<a name="0.9.20.4"></a>
## 鼠鬚管 0.9.20.4 (2013-07-25)

  * 修復：原生配色方案候選序號顏色不正確

<a name="0.9.20.3"></a>
## 鼠鬚管 0.9.20.3 (2013-07-24)

  * 修復：0.9.20 版本引入【朙月拼音】詞典缺失詞組的BUG<br/>
    若其他詞典有相同問題，請刪除對應的 `.bin` 文件再重新部署
  * 修復：【地球拼音】「-」鍵輸入第一聲失效的BUG
  * 更新：`symbols.yaml` 增加一批特殊符號

<a name="0.9.20"></a>
## 鼠鬚管 0.9.20 (2013-07-24)

  * 新增：支持全角模式
  * 新增：【倉頡】按快趣取碼規則生成常用詞組
  * 更新：拼音、粵拼、中古漢語等輸入方案、繁簡轉換詞典
  * 修復：大陸與臺灣異讀的字「微」「檔」「蝸」「垃圾」等
  * 變更：設置 `show_notifications_when: never` 不再提示輸入法狀態
  * 修復：自定義中西文切換鍵 `Control+space` 無法切回中文模式
  * 修復：用戶詞典未能完整支持 `derive` 拼寫運算產生的歧義切分
  * 新增：（輸入方案設計用）干預多個 translator 之間的結果排序<br/>
    選項 `translator/initial_quality: 0`

<a name="0.9.19"></a>
## 鼠鬚管 0.9.19 (2013-06-24)

  * 新增：切換輸入法狀態時在光標處延時顯示當前狀態
  * 修復：無法同步／合併 Windows 系統下生成的用戶詞典快照
  * 改進：方案選單按選用輸入方案的時間排列
  * 新增：快捷鍵 Control+Shift+1 切換至下一個輸入方案
  * 新增：快捷鍵 Control+Shift+2~5 切換輸入模式
  * 改進：綜合候選詞的詞頻和詞條質量比較不同 translator 的結果
  * 修復：自定義短語不應參與組詞
  * 修復：「链」「坂」「喂」在簡化字模式下無法組詞（須清除用戶字頻）
  * 新增：對特定類型候選字不做繁簡轉換<br/>
    例如不轉換反查字 `simplifier/exclude_types: [ reverse_lookup ]`

<a name="0.9.18"></a>
## 鼠鬚管 0.9.18 (2013-04-26)

  * 新增：配色方案【曬經石】／Solarized Rock
  * 新增：Control+BackSpace 或 Shift+BackSpace 回退一個音節
  * 新增：固態詞典可引用多份碼表文件以實現分類詞庫
  * 新增：在輸入方案中加載翻譯器的多個具名實例
  * 新增：以選項 `translator/user_dict:` 指定用戶詞典的名稱
  * 新增：支持從用戶文件夾加載文本碼表作爲自定義短語詞典<br/>
    【朙月拼音】系列自動加載名爲 `custom_phrase.txt` 的碼表
  * 修復：繁簡轉換使無重碼自動上屏失效的 BUG
  * 修復：若非以 Caps Lock 鍵進入西文模式，
    按 Caps Lock 只切換大小寫，不返回中文模式
  * 變更：Alfred 2 初始進入西文模式
  * 變更：`r10n_translator` 更名爲 `script_translator`，舊名稱仍可使用
  * 變更：用戶詞典快照改爲文本格式
  * 改進：【八股文】導入《萌典》詞彙，並修正了不少錯詞
  * 改進：【倉頡五代】打單字時，以拉丁字母和倉頡字母並列顯示輸入碼
  * 改進：使自動生成的 YAML 文檔更合理地縮排、方便閱讀
  * 改進：碼表中 `# no comments` 行之後不再識別註釋，以支持 `#` 作文字內容
  * 改進：檢測到因斷電造成用戶詞典損壞時，自動在後臺線程恢復數據文件

<a name="0.9.17"></a>
## 鼠鬚管 0.9.17 (2013-01-31)

  * 改進：安裝完畢自動啓用鼠鬚管
  * 變更：Caps Lock 燈亮時默認輸出大寫字母 [Gist](https://gist.github.com/2981316)
  * 新增：支持設定候選行間距 `style/line_spacing:`
  * 新增：支持並擊輸入；並擊速度選項 `chord_duration:`<br/>
    並擊輸入方案【宮保拼音】
  * 新增：無重碼自動上屏 `speller/auto_select:`<br/>
    輸入方案【倉頡・快打模式】
  * 改進：允許以空格做輸入碼，或作爲符號頂字上屏<br/>
    `speller/use_space:`, `punctuator/use_space:`
  * 改進：【注音】輸入方案以空格輸入第一聲（陰平）
  * 新增：特殊符號表 `symbols.yaml` 用法見↙
  * 改進：【朙月拼音・簡化字】以 `/ts` 等形式輸入特殊符號
  * 改進：標點符號註明〔全角〕〔半角〕
  * 優化：同步用戶資料時更聰明地備份用戶自定義的 YAML 文件
  * 修復：避免創建、使用不完整的詞典文件
  * 修復：糾正用戶詞典中無法調頻的受損詞條

<a name="0.9.16"></a>
## 鼠鬚管 0.9.16 (2013-01-18)

  * 新增：支持設定候選序號的字體和顏色 `squirrel.yaml`
  * 改進：支持備用字體列表，以「`,`」分隔字體名稱
  * 改進：支持在配色方案中設定字體、窗口樣式等選項
  * 新增：預設配色方案「簡約白」by Chongyu Zhu
  * 新增：可選用 OS X 10.8 的通知中心顯示輸入法狀態通知
    感謝 Chongyu Zhu 爲鼠鬚管添加以上新功能。
  * 修復：手動升級後直到註銷登錄仍在使用舊版本的問題
  * 修復：0.9.15 版本安裝了錯誤的詞典文件</br>
    如果除【朙月拼音】外還有其他詞典用 0.9.15 版本編譯後出錯，
    請刪除用戶文件夾中對應的 `.bin` 文件，再用新版本部署。

<a name="0.9.15.1"></a>
## 鼠鬚管 0.9.15.1 (2013-01-17)

  * 新增：Caps Lock 點亮時，切換到西文模式，輸出小寫字母<br/>
    選項 `ascii_composer/switch_key/Caps_Lock:`
  * 新增：支持 Emacs 風格的編輯鍵 Control + 字母
  * 修復：一處內存泄漏
  * 修復：用戶詞典有可能因讀取時 I/O 錯誤導致部份詞序無法調整

<a name="0.9.14.5"></a>
## 鼠鬚管 0.9.14.5 (2013-01-10)

  * 新增：接收外部應用請求重新部署的通知，及命令行選項 Squirrel --reload
  * 修復：從 0.9.11 及更早的版本升級用戶詞典出錯</br>
    如果因此丟失詞彙，手動恢復的方法是：執行「同步用戶資料」

<a name="0.9.14"></a>
## 鼠鬚管 0.9.14 (2013-01-07)

  * 新增：同步用戶詞典，詳見 [Wiki » UserGuide](https://code.google.com/p/rimeime/wiki/UserGuide)
  * 新增：上屏錯誤的詞組後立即按回退鍵（BackSpace）撤銷組詞
  * 改進：拼音輸入法中，按左方向鍵以音節爲單位移動光標
  * 修復：【地球拼音】不能以 - 鍵輸入第一聲
  * 新增：設定候選字及序號格式的選項 `squirrel.yaml`: `style/candidate_format:`

<a name="0.9.13"></a>
## 鼠鬚管 0.9.13 (2012-12-26)

  * 優化：在編碼行分別標記已選定文字和未轉換的編碼
  * 修復：按左右鍵在編碼行移動插入焦點，光標位置更新不及時
  * 新增：切換狀態時是否顯示氣泡通知的選項 `show_notifications_when:`

<a name="0.9.12"></a>
## 鼠鬚管 0.9.12 (2012-12-23)

  * 新增：切換模式、輸入方案時彈出氣泡提示（安裝 Growl 效果最佳）
  * 新增：配色方案「Google」
  * 修復BUG：首次使用用戶目錄缺少 `squirrel.yaml`，部署之後才出現
  * 修復BUG：語句流輸入方案不記憶直接回車上屏的詞
  * 新增：分別以 `` ` ' `` 標誌編碼反查的開始結束，例如 `` `wbb'yuepinyin ``
  * 改進：形碼與拼音混打的設定下，降低簡拼候選的優先級，以降低對逐鍵提示的干擾
  * 優化：控制用戶詞典文件大小，提高大容量（詞條數>100,000）時的查詢速度
  * 刪除：因有用家向用戶詞典導入巨量詞條，故取消自動備份的功能，後續代之以用戶詞典同步

<a name="0.9.11"></a>
## 鼠鬚管 0.9.11 (2012-10-17)

  * 修復：選中的輸入方案、繁簡轉換等選項關機時不會保存的BUG
  * 變更：爲免除困惑，在代碼編輯器中恢復中文狀態（MacVim 除外）
  * 變更：部署快捷鍵由 Cmd+Option+R 改爲 Control+Option+`
  * 改進：部署時自動編譯輸入方案的自訂依賴項，如 emoji 表情
  * 改進：未曾翻頁時按減號鍵，不上屏候選字及符號「-」以免誤操作
  * 新增：開關碼表輸入法連打功能的設定項 `translator/enable_sentence`
  * 更新：《朙月拼音》《地球拼音》《粵拼》，修正多音字
  * 更新：《上海吳語》《上海新派》，修正註音
  * 新增：寒寒豆作《蘇州吳語》輸入方案，方案標識爲 `soutzoe`

<a name="0.9.10"></a>
## 鼠鬚管 0.9.10 (2012-09-19)

  * 修復：全新安裝無法建立用戶文件夾 `~/Library/Rime`
  * 修復：在 Quicksilver 中默認關閉漢字輸入的配置無效

<a name="0.9.9"></a>
## 鼠鬚管 0.9.9 (2012-09-17)

  * 新增：碼表輸入法啓用用戶詞典、字頻調整
  * 優化：自動編譯輸入方案依賴項，如五筆・拼音的反查詞典
  * 修改：日誌系統改用 glog，輸出到 `$TMPDIR/rime.squirrel.*`
  * 新增：針對特定程序禁用漢字輸入，如終端、代碼編輯器等
  * 優化：改進對 MacVim 命令模式的支持
  * 優化：適合 Retina 屏的輸入法圖標，感謝 leon.guan 幫忙！
  * 新增：【emoji表情】輸入方案，用法見 Wiki 《定製指南》
  * 更新：【明月拼音】【粵拼】【吳語】修正註音錯誤、缺字

<a name="0.9.8"></a>
## 鼠鬚管 0.9.8 (2012-07-08)

  * 新的 Rime logo
  * 新特性：碼表方案支持與反查碼混合輸入，無需切換或引導鍵
  * 新特性：碼表方案可在選單中使用字符集過濾開關
  * 新方案：【五筆86】衍生的【五筆・拼音】混合輸入
  * 新方案：《廣韻》音系的中古漢語全拼、三拼輸入法
  * 新方案：X-SAMPA 國際音標輸入法
  * 更新：【吳語】碼表，審定一些字詞的讀音，統一字形
  * 更新：【朙月拼音】碼表，修正多音字

<a name="0.9.7"></a>
## 鼠鬚管 0.9.7 (2012-06-10)

  * 提供指定候選窗邊界高度、寬度的選項 [Gist](https://gist.github.com/2290714)
  * 修復在 M$Office、BBEdit 等軟件中按Cmd鍵會清除選中文字的問題
  * 修復以 `rime_dict_manager` 導入文本碼表不生效的BUG（請升級該工具）；<br/>
    部署時檢查並修復已存在於用戶詞典中的無效條目
  * 檢測到用戶詞典文件損壞時重建詞典並從備份中恢復資料

<a name="0.9.6"></a>
## 鼠鬚管 0.9.6 (2012-06-0x)

  * 候選窗圓角效果、自定義色彩，感謝 waynezhang 貢獻代碼
  * 提供與【小狼毫】相當的一組配色方案
  * 新增「部署」熱鍵 Option+Command+R 、打開設定目錄的菜單項
  * 切換其他輸入法時，未完成的輸入立即上屏
  * 未經轉換的輸入如網址等不再顯示候選窗
  * 可於 `default.custom.yaml` 中設定全局的頁候選數
  * 可於導入【八股文】詞庫時限制詞語的長度、詞頻
  * 【倉頡】支持連續輸入多個字的編碼（不會記憶）
  * 【注音】改爲語句輸入風格，更接近臺灣用戶的習慣
  * 較少用的【筆順五碼】、【速記打字法】不再隨鼠鬚管發行
  * 修改BUG：簡拼 zhzh 因切分歧義使部分用戶詞失效

<a name="0.9.5"></a>
## 鼠鬚管 0.9.5 (2012-05-06)

  * 用 Shift+Del 刪除已記入用戶詞典的詞條，詳見 Issue 117
  * 可選用Shift或Control爲中西文切換鍵，詳見 Issue 133
  * 數字後的句號鍵識別爲小數點、分號鍵識別爲時分秒分隔符
  * 候選字的編碼提示以灰色顯示

<a name="0.9.4"></a>
## 鼠鬚管 0.9.4 (2012-04-15)

  * 探測失敗的啓動，預防設定不當導致持續崩潰、系統響應緩慢
  * 使用 `express_editor` 的輸入方案中，數字、符號鍵直接上屏
  * 輸入簡拼、模糊音時提示正音，【粵拼】【吳語】中默認開啓
  * 拼音反查支持預設的多音節詞、形碼反查可開啓編碼補全
  * 修復整句模式運用定長編碼頂字功能導致崩潰的問題
  * 修復碼表輸入法候選排序問題
  * 修復【朙月拼音】lo、yo 等音節的候選錯誤
  * 修復【地球拼音】聲調顯示不正確、部分字的註音缺失問題
  * 【五笔86】反查引導鍵改爲 z、反查詞典換用簡化字拼音
  * 更新【粵拼】詞典，調整常用粵字的排序、增補粵語常用詞
  * 新增輸入方案【筆順五碼】

<a name="0.9.3"></a>
## 鼠鬚管 0.9.3 (2012-04-04)

  * 支持非US鍵盤佈局
  * 支持多顯示器
  * 支持候選橫排
  * 支持自訂候選窗字體、字號、透明度
  * 通過語言欄菜單執行佈署操作
  * 通過Appcast檢查更新
  * 記憶繁簡轉換、全／半角符號開關狀態
  * 支持定長編碼頂字上屏
  * 延遲加載繁簡轉換、編碼反查詞典，降低資源佔用
  * 純單字構詞時不調頻
  * 新增輸入方案【速成】，速成、倉頡詞句連打
  * 新增【智能ABC雙拼】、【速記打字法】

<a name="0.9.2.1"></a>
## 鼠鬚管 0.9.2.1

  * 消除對第三方庫的依賴（用戶安裝失敗）
  * 新增安裝步驟：預編譯輸入方案，提升首次啓動速度

<a name="0.9.1"></a>
## 鼠鬚管 0.9.1

  * 新增備選輸入方案【注音】、【地球拼音】

<a name="0.9"></a>
## 鼠鬚管 0.9

  * 初試鋒芒
