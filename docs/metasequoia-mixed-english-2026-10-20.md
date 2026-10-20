# 中英混输排序：参照水杉输入法（2026-10-20）

## 问题

全拼中文模式打 `di`，第一页只有三个中文，其后是数百个英文补全（did、die、dig……），
想打的“低”要翻页才能找到。用 `/Library/Input Methods/Owltype.app` 在隔离用户目录复现：
干净种子加五个英文资源时，`di` 的第 4 到第 222 个候选都是英文。

原因：`table_translator@melt_eng` 的补全词质量分高于 `script_translator` 的拼音词，
Rime 合并翻译时按质量排序，英文压过中文。原过滤器只把一、二字母输入的前三个中文提上来，
其余位置仍由权重决定。

## 水杉的做法

出处：[metasequoiaime/msime](https://github.com/metasequoiaime/msime) 提交
`e94115df5b048ccfbb79706a7ac495cdee1c6e10`，`crates/engine/src/ime/queries.rs`
（`CandidateQueries::mixed`、`insert_mixed_rows_with_japanese`、`priority_slot`、
`spells_whole_syllables`）。

- 英文混输默认关闭，前缀至少 2 个字母，每次最多混入 5 个英文词。
- 英文不和拼音比权重；源码注释说两边“不在一个尺度上”。
- 输入**不能**整段切成完整拼音音节，并且第一个英文词正好等于整段输入时，这个英文词排第一。
- 否则第一个英文词放在“优先位置”：首选之后（有云候选时再后一位），其余英文排在整个列表末尾。

## Owltype 的实现

规则写在自有的 Lua 过滤器 `lua_filter@*owltype_pinned_words`
（[OwlPinyinCandidateDeployment.swift](../sources/Settings/OwlPinyinCandidateDeployment.swift)），
只对纯小写字母的当前段生效，ASCII 模式和用户自定义过滤链不受影响。

| 输入 | 英文位置 |
| --- | --- |
| 不是完整音节，且第一个英文词等于输入（`hello`、`dir`、`github`） | 第一位 |
| 不是完整音节，其他（`hel`、`gith`） | 第一个英文在第二位（一、二字母输入在第四位），其余排到中文之后 |
| 完整音节（`di`、`nihao`、`you`） | 与输入相同的英文词排在第一页之后，其余排到中文之后 |

与水杉的差异：

- **完整音节输入不在第二位放英文。** 水杉对 `di` 也会把一个英文补全放在第二位；用户反馈的正是这类干扰，所以改为只给与输入相同的词（如 `you`）留第二页第一位。
- **不删英文，只后移。** 水杉每次最多取 5 个；这里保留全部英文，排在中文之后，候选总数和内容不变。
- 首个英文的前瞻上限为 64 个候选，超过时英文按 Rime 原位置出现。
- 完整音节判断用词典里的 417 个全拼音节（含 `lue`、`nue`，不含 `hm`、`m`、`n`、`ng`）；模糊音和双拼不在本次范围。

## 验证

[check-pinyin-short-code.py](../scripts/check-pinyin-short-code.py) 用真实 Rime 和固定哈希的英文词典核对：
`di`、`shi`、`nihao` 第一页没有英文且候选不丢不重；`hello`、`dir`、`github` 英文领先；
`hel`、`gith` 英文在第二位；另用夹具翻译器覆盖“只看第一个英文”、大小写匹配和末尾补位。
