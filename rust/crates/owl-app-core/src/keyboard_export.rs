//! Retained keyboard YAML export. Production activation uses keyboard::application, not YAML.
#![allow(non_snake_case)]
use serde::Deserialize;
#[derive(Deserialize)]
pub struct Snapshot {
    inputMethod: String,
    doublePinyin: String,
    shiftSwitchCJK: bool,
    cjkPunctToggle: bool,
    pageSize: i64,
    pageMinusEquals: bool,
    pageBrackets: bool,
    pageCommaPeriod: bool,
    select23Semicolon: bool,
    fuzzy: Fuzzy,
    wubiCodeHint: bool,
    wubiAutoClear: bool,
    wubiCandidateMode: String,
    goodOldCapsLock: bool,
    wubiScheme: String,
    wubiZReverseLookup: bool,
    wubiUserDictLearning: bool,
    angleSymbolMenu: bool,
    slashSymbolMenu: bool,
    wubiEnglishChannel: bool,

    appEnglishBundleIDs: Vec<String>,
}
#[derive(Deserialize)]
struct Fuzzy {
    zhz: bool,
    chc: bool,
    shs: bool,
    nl: bool,
    rl: bool,
    fh: bool,
    anang: bool,
    eneng: bool,
    ining: bool,
}
#[derive(Deserialize)]
pub struct Target {
    fileName: String,
    displayName: String,
}
#[derive(Default)]
struct Lines(Vec<String>);
impl Lines {
    fn append(&mut self, value: impl Into<String>) {
        self.0.push(value.into());
    }
    fn extend(&mut self, values: impl IntoIterator<Item = String>) {
        self.0.extend(values);
    }
    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}
impl IntoIterator for Lines {
    type Item = String;
    type IntoIter = std::vec::IntoIter<String>;
    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}
impl<const N: usize> From<[&str; N]> for Lines {
    fn from(value: [&str; N]) -> Self {
        Self(value.into_iter().map(str::to_owned).collect())
    }
}
impl Snapshot {
    fn double_schema(&self) -> String {
        super::keyboard::catalog()["doublePinyinSchemas"][&self.doublePinyin]
            .as_str()
            .unwrap()
            .to_owned()
    }
    fn double_name(&self) -> String {
        super::keyboard::schema(&self.double_schema())["name"]
            .as_str()
            .unwrap()
            .to_owned()
    }
    fn wubi_schema(&self) -> String {
        super::keyboard::catalog()["wubiSchemas"][&self.wubiScheme]
            .as_str()
            .unwrap()
            .to_owned()
    }
    fn wubi_name(&self) -> &str {
        match self.wubiScheme.as_str() {
            "pinyinMix" => "86 版五笔拼音混输",
            "jidian98" => "98 版五笔",
            "pinyinMix98" => "98 版五笔拼音混输",
            _ => "86 版五笔",
        }
    }
    fn candidate_filter(&self) -> Option<String> {
        super::keyboard::catalog()["candidateFilters"][&self.wubiCandidateMode]
            .as_str()
            .map(str::to_owned)
    }
}
pub fn default_yaml(s: &Snapshot) -> String {
    let mut lines = Lines::default();

    lines.append("# 猫头鹰生成（草案）— 应用前请真机验证");
    lines.append("# 写入 ~/Library/Application Support/Owltype/default.custom.yaml 后需在猫头鹰设置里「应用配置改动」");
    lines.append("patch:");

    if s.inputMethod == "pinyin" {
        lines.append("  # 默认方案顺序：全拼 rime_ice 置顶（首项=新会话默认方案）");
        lines.append("  schema_list:");
        lines.append("    - { schema: rime_ice }             # 雾凇全拼");
        lines.append("    - { schema: pinyin_simp }          # 简体拼音");
        lines.append("    - { schema: wubi86_jidian }        # 极点五笔86");
        lines.append("    - { schema: wubi86_jidian_pinyin } # 五笔拼音混输");
        lines.append("    - { schema: wubi86_jidian_trad }   # 五笔简入繁出");
        lines.append("    - { schema: wubi86_jidian_trad_pinyin } # 五笔拼音混输·简入繁出");
        lines.append(format!("  \"menu/page_size\": {}", s.pageSize));
    } else if s.inputMethod == "doublePinyin" {
        lines.append("  # 默认方案顺序：把所选双拼置顶（首项=新会话默认方案）");
        lines.append("  schema_list:");
        lines.append(format!(
            "    - {{ schema: {} }}  # {}",
            s.double_schema(),
            s.double_name()
        ));
        lines.append("    - { schema: rime_ice }             # 雾凇全拼");
        lines.append("    - { schema: wubi86_jidian }        # 极点五笔86");
        lines.append("    - { schema: wubi86_jidian_pinyin } # 五笔拼音混输");
        lines.append("    - { schema: wubi86_jidian_trad }   # 五笔简入繁出");
        lines.append("    - { schema: wubi86_jidian_trad_pinyin } # 五笔拼音混输·简入繁出");
        lines.append(format!("  \"menu/page_size\": {}", s.pageSize));
    } else if s.inputMethod == "wubi" {
        let primary = s.wubi_schema();
        lines.append(format!(
            "  # 默认方案顺序：{} 置顶（首项=新会话默认方案）",
            s.wubi_name()
        ));
        lines.append("  schema_list:");
        lines.append(format!("    - {{ schema: {} }}", primary));
        for scheme in [
            "wubi86_jidian",
            "wubi86_jidian_pinyin",
            "wubi98",
            "wubi98_pinyin",
        ]
        .into_iter()
        .filter(|id| *id != primary)
        {
            lines.append(format!("    - {{ schema: {} }}", scheme));
        }
        for schema in [
            "wubi86_jidian_trad",
            "wubi86_jidian_trad_pinyin",
            "wubi98_trad",
            "wubi98_trad_pinyin",
        ] {
            lines.append(format!("    - {{ schema: {} }}", schema));
        }
        lines.append("    - { schema: rime_ice }             # 雾凇全拼");
        lines.append("    - { schema: pinyin_simp }          # 简体拼音");
        lines.append(format!("  \"menu/page_size\": {}", s.pageSize));
    }

    if s.shiftSwitchCJK {
        lines.append("  # 中英文切换键：左/右 Shift 都切中英文（commit_code）");
        lines.append("  \"ascii_composer/switch_key/Shift_L\": commit_code");
        lines.append("  \"ascii_composer/switch_key/Shift_R\": commit_code");
        lines.append("  \"ascii_composer/switch_key/Caps_Lock\": commit_code");
        lines.append(format!(
            "  \"ascii_composer/good_old_caps_lock\": {}",
            s.goodOldCapsLock
        ));
    }

    if s.pageBrackets {
        lines.append("  # [] 翻页：先停用 rime-ice 以词定字（select_character Lua 处理器在 key_binder 前执行），");
        lines.append("  # 置空这两个键后 [ ] 才会落到下面的 key_binder 翻页绑定。");
        lines.append("  \"key_binder/select_first_character\": \"\"");
        lines.append("  \"key_binder/select_last_character\": \"\"");
    }

    lines.extend(punctuator_patch_lines(s));

    let bindings = key_binder_bindings(s);
    if !bindings.is_empty() {
        lines.append("  # 候选翻页 / 快速选词 / 全半角·中英标点热键（追加，不替换用户已有 bindings；已去重）");
        lines.append("  \"key_binder/bindings/+\":");
        lines.extend(bindings);
    }

    let savedOptions = save_options(s);
    if !savedOptions.is_empty() {
        lines.append("  # 让方案选单记住这些开关状态");
        lines.append("  \"switcher/save_options/+\":");
        lines.extend(
            savedOptions
                .0
                .into_iter()
                .map(|option| format!("    - {}", option))
                .collect::<Vec<_>>(),
        );
    }

    return lines.0.join("\n") + "\n";
}

pub fn app_options_yaml(s: &Snapshot) -> String {
    let mut lines = Lines::default();
    lines.append("# 猫头鹰生成（草案）— 应用前请真机验证");
    lines.append("# 写入 ~/Library/Application Support/Owltype/owltype.custom.yaml 后需在猫头鹰设置里「应用配置改动」");
    lines.append("patch:");

    let appEnglishBundleIDs =
        super::keyboard::normalized_bundle_ids(&s.appEnglishBundleIDs.join("\n"));
    if !appEnglishBundleIDs.is_empty() {
        lines.append("  # App 默认英文：复用 Rime/Squirrel app_options，只追加用户指定的 bundle id（owltype 域，与出厂预设同域）");
        for bundleID in appEnglishBundleIDs {
            lines.append(format!("  \"app_options/{}/ascii_mode\": true", bundleID));
        }
    }

    return lines.0.join("\n") + "\n";
}

pub fn fuzzy_yaml(s: &Snapshot) -> String {
    let mut lines = Lines::default();

    lines.append("# rime_ice.custom.yaml — 雾凇全拼方案级（模糊音）");
    lines.append("# 猫头鹰生成（草案）— 应用前请真机验证");
    lines.append("# 写入 ~/Library/Application Support/Owltype/rime_ice.custom.yaml 后需在猫头鹰设置里「应用配置改动」");

    let fuzzyDerives = fuzzy_algebra_derives(&s.fuzzy);
    if fuzzyDerives.is_empty() {
        lines.append("# 当前未开启任何模糊音；无需 rime_ice.custom.yaml。");
        return lines.0.join("\n") + "\n";
    }

    lines.append("patch:");
    lines.append(
        "  # 模糊拼音（追加到 speller/algebra；注意与方案既有 algebra 的顺序，建议真机验证）",
    );
    lines.append("  \"speller/algebra/+\":");
    lines.extend(fuzzyDerives);

    return lines.0.join("\n") + "\n";
}

pub fn wubi_yaml(s: &Snapshot, target: &Target) -> String {
    let mut lines = Lines::default();

    lines.append(format!(
        "# {} — {} 方案级",
        target.fileName, target.displayName
    ));
    lines.append("# 猫头鹰生成（草案）— 应用前请真机验证");
    lines.append(format!(
        "# 写入 ~/Library/Application Support/Owltype/{} 后需在猫头鹰设置里「应用配置改动」",
        target.fileName
    ));
    lines.append("patch:");

    lines.extend(currency_symbol_menu_patch_lines());
    lines.extend(slash_symbol_menu_patch_lines(s));

    lines.append("  # 候选编码提示：默认隐藏五笔候选的编码。");
    if s.wubiCodeHint {
        lines.append("  \"translator/comment_format\": []");
    } else {
        lines.append("  \"translator/comment_format\":");
        lines.append("    - xform/.+//");
    }

    lines.append("  # z 临时拼音反查始终显示五笔编码（练习用），不受上面的候选编码提示影响。");
    lines.append("  \"reverse_lookup/comment_format\": []");

    lines.append("  # 空码自动清码：打开后空码到最大码长时自动清空。");
    lines.append(format!(
        "  \"speller/auto_clear\": {}",
        if s.wubiAutoClear {
            "max_length"
        } else {
            "\"\""
        }
    ));

    if let Some(filter) = s.candidate_filter() {
        lines.append("  # 单字候选：两个 Lua filter 互斥，只追加当前选择。");
        lines.append("  \"engine/filters/+\":");
        lines.append(format!("    - {}", filter));
    }

    if s.wubiZReverseLookup {
        lines.append("  # z 临时拼音反查：统一 86 / 拼音混输 / 繁体变体使用 z 前缀。");
        lines.append("  \"reverse_lookup/prefix\": \"z\"");
        lines.append("  \"reverse_lookup/suffix\": \"'\"");
        lines.append("  \"reverse_lookup/tips\": [拼音]");
        lines.append("  \"recognizer/patterns/reverse_lookup\": \"^z[a-z]*'?$\"");
    } else {
        lines.append("  # z 临时拼音反查：关闭时清空 recognizer 反查正则，z 不再触发拼音反查。");
        lines.append("  \"recognizer/patterns/reverse_lookup\": \"\"");
    }

    if s.wubiUserDictLearning {
        lines.append("  # 个性化：记住你常用的词并按你的词频重排（user_dict）。userdb 由引擎自建自管，猫头鹰不碰。");
        lines.append("  \"translator/enable_user_dict\": true");
    }

    if s.wubiEnglishChannel {
        lines.append("  # ` 临时英文（melt_eng）：` 进入英文组句，五笔四码上屏不受影响。");
        lines.append("  \"speller/alphabet\": \"zyxwvutsrqponmlkjihgfedcba`\"");
        lines.append("  \"engine/segmentors\":");
        lines.append("    - ascii_segmentor");
        lines.append("    - matcher");
        lines.append("    - affix_segmentor@melt_eng");
        lines.append("    - abc_segmentor");
        lines.append("    - punct_segmentor");
        lines.append("    - fallback_segmentor");
        lines.append("  \"engine/translators/+\":");
        lines.append("    - table_translator@melt_eng");
        lines.append("  melt_eng:");
        lines.append("    tag: melt_eng");
        lines.append("    dictionary: melt_eng");
        lines.append("    prefix: \"`\"");
        lines.append("    tips: 〔英文〕");
        lines.append("    closing_tips: 〔英文〕");
        lines.append("    enable_completion: true");
        lines.append("    enable_sentence: false");
        lines.append("    initial_quality: 1");
        lines.append("  \"recognizer/patterns/melt_eng\": \"^`[A-Za-z]*$\"");
    }

    return lines.0.join("\n") + "\n";
}

fn fuzzy_algebra_derives(f: &Fuzzy) -> Lines {
    let mut entries = Lines::default();

    let mut append = |rule: &str, comment: &str| {
        entries.append(format!("    - {}  # {}", rule, comment));
    };

    if f.zhz {
        append("derive/^zh/z/", "zh → z");
    }
    if f.chc {
        append("derive/^ch/c/", "ch → c");
    }
    if f.shs {
        append("derive/^sh/s/", "sh → s");
    }
    if f.nl {
        append("derive/^n/l/", "n → l");
        append("derive/^l/n/", "l → n");
    }
    if f.rl {
        append("derive/^r/l/", "r → l");
    }
    if f.fh {
        append("derive/^f/h/", "f → h");
        append("derive/^h/f/", "h → f");
    }
    if f.anang {
        append("derive/an$/ang/", "an → ang");
        append("derive/ang$/an/", "ang → an");
    }
    if f.eneng {
        append("derive/en$/eng/", "en → eng");
        append("derive/eng$/en/", "eng → en");
    }
    if f.ining {
        append("derive/in$/ing/", "in → ing");
        append("derive/ing$/in/", "ing → in");
    }

    return entries;
}

fn slash_symbol_menu_patch_lines(s: &Snapshot) -> Lines {
    if !s.slashSymbolMenu {
        return Lines::default();
    }
    return Lines::from([
        "  # 符号：/ 弹出候选（、 ASCII/ 全角／ ÷）；关闭本开关时猫头鹰改为切英文并直接输出 /",
        "  \"punctuator/half_shape/+\":",
        "    \"/\": [\"、\", \"/\", \"／\", \"÷\"]",
        "  \"punctuator/full_shape/+\":",
        "    \"/\": [\"、\", \"/\", \"／\", \"÷\"]",
    ]);
}

fn currency_symbol_menu_patch_lines() -> Lines {
    return Lines::from([
        "  # 货币：Shift+4 弹出候选；ASCII $ 第一（Codex skill），人民币符号 ¥ 第二",
        "  \"punctuator/half_shape/$\": [\"$\", \"¥\"]",
        "  \"punctuator/full_shape/$\": [\"$\", \"¥\"]",
    ]);
}

fn punctuator_patch_lines(s: &Snapshot) -> Lines {
    let mut lines = currency_symbol_menu_patch_lines();
    lines.extend(slash_symbol_menu_patch_lines(s));
    if s.angleSymbolMenu {
        lines.append(
            "  # 符号：< 弹出符号选单（《 〈 ASCII< 「 弯引号“；首选仍是《，继续打字自动上屏首选）",
        );
        lines.append(
            "  # 每项都是单字符开括号——选中后由「自动配对括号」补成对并居中光标（弯引号同表）。",
        );
        lines.append("  \"punctuator/half_shape/<\": [\"《\", \"〈\", \"<\", \"「\", \"“\"]");
    }
    return lines;
}

fn key_binder_bindings(s: &Snapshot) -> Lines {
    let mut seen = std::collections::HashSet::new();
    let mut entries = Lines::default();
    let mut add = |when: &str, accept: &str, action: &str, comment: &str| {
        if seen.insert(format!("{}|{}", accept, action)) {
            entries.append(format!(
                "    - {{ when: {}, accept: {}, {} }}  # {}",
                when, accept, action, comment
            ));
        }
    };

    if s.pageMinusEquals {
        add("has_menu", "minus", "send: Page_Up", "减号上一页");
        add("has_menu", "equal", "send: Page_Down", "等号下一页");
    }
    if s.pageBrackets {
        add("has_menu", "bracketleft", "send: Page_Up", "左括号上一页");
        add(
            "has_menu",
            "bracketright",
            "send: Page_Down",
            "右括号下一页",
        );
    }
    if s.pageCommaPeriod {
        add("has_menu", "comma", "send: Page_Up", "逗号上一页");
        add("has_menu", "period", "send: Page_Down", "句号下一页");
    }
    if s.select23Semicolon {
        add("has_menu", "semicolon", "send: 2", "分号选第 2 位");
        add("has_menu", "apostrophe", "send: 3", "引号选第 3 位");
    }
    add(
        "always",
        "Control+Shift+3",
        "toggle: ascii_punct",
        "中英标点切换",
    );
    add(
        "always",
        "Control+Shift+numbersign",
        "toggle: ascii_punct",
        "中英标点切换（shifted 键名兼容）",
    );

    return entries;
}

fn save_options(s: &Snapshot) -> Lines {
    let mut options = Lines::default();
    if s.cjkPunctToggle {
        options.append("ascii_punct");
    }
    return options;
}

/// A complete export plan, including empty blocks that clear previously exported overrides.
pub fn plan(snapshot: &Snapshot) -> serde_json::Value {
    use serde_json::json;
    let mut files = vec![
        (
            "default.custom.yaml".to_owned(),
            "OWL MANAGED DEFAULT PATCH v1",
            default_yaml(snapshot),
        ),
        (
            "owltype.custom.yaml".to_owned(),
            "OWL MANAGED OWLTYPE_CUSTOM APP_OPTIONS v1",
            app_options_yaml(snapshot),
        ),
        (
            "rime_ice.custom.yaml".to_owned(),
            "OWL MANAGED RIME_ICE PATCH v1",
            fuzzy_yaml(snapshot),
        ),
    ];
    for target in super::keyboard::catalog()["exportTargets"]
        .as_array()
        .unwrap()
    {
        let target: Target = serde_json::from_value(target.clone()).expect("export target");
        files.push((
            target.fileName.clone(),
            "OWL MANAGED WUBI86_JIDIAN PATCH v1",
            wubi_yaml(snapshot, &target),
        ));
    }
    files
        .into_iter()
        .map(|(file, marker, yaml)| json!({"fileName":file,"block":managed_block(&yaml, marker)}))
        .collect()
}

pub fn managed_block(yaml: &str, marker: &str) -> serde_json::Value {
    let mut body = Vec::new();
    let mut seen_patch = false;
    for line in yaml.split('\n') {
        if !seen_patch {
            let trimmed = line.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r');
            if trimmed == "patch:" {
                seen_patch = true;
                continue;
            }
            if trimmed.starts_with('#') || trimmed.is_empty() {
                continue;
            }
        }
        body.push(line);
    }
    while body.last().is_some_and(|line| {
        line.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r')
            .is_empty()
    }) {
        body.pop();
    }
    serde_json::json!({"marker":marker,"yamlLinesIndentedUnderPatch":body})
}

/// Preserve unrelated YAML and replace only the named managed block.
pub fn render_managed(original: &str, marker: &str, lines: &[String]) -> Option<String> {
    use std::sync::OnceLock;
    static EMPTY_PATCH: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = EMPTY_PATCH
        .get_or_init(|| regex::Regex::new(r"(?m)^patch:\s*\{\s*\}[ \t]*(#.*)?$").unwrap());
    let original = pattern.replace_all(original, "patch: $1");
    let begin = format!("  # >>> {marker}");
    let end = format!("  # <<< {marker}");
    let managed = std::iter::once(begin.as_str())
        .chain(lines.iter().map(String::as_str))
        .chain(std::iter::once(end.as_str()))
        .collect::<Vec<_>>()
        .join("\n");
    if let (Some(start), Some(finish)) = (original.find(&begin), original.find(&end)) {
        let finish = finish + end.len();
        if start > finish {
            return None;
        }
        return Some(format!(
            "{}{}{}",
            &original[..start],
            managed,
            &original[finish..]
        ));
    }
    if !original.contains("patch:") {
        return None;
    }
    Some(format!(
        "{}\n\n{}\n",
        original.trim_matches(['\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}']),
        managed
    ))
}
