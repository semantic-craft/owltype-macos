use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Glyph {
    pub char: String,
    pub keywords: String,
    pub wide: bool,
}

impl Glyph {
    fn g(c: &str, k: &str) -> Self {
        Glyph {
            char: c.to_string(),
            keywords: k.to_string(),
            wide: false,
        }
    }
    fn w(c: &str, k: &str) -> Self {
        Glyph {
            char: c.to_string(),
            keywords: k.to_string(),
            wide: true,
        }
    }
}

pub fn emoji_catalog(category: &str) -> Vec<Glyph> {
    match category {
        "emoji" => vec![
            Glyph::g("😀", "smile 笑 开心"),
            Glyph::g("😄", "笑 happy"),
            Glyph::g("😁", "grin"),
            Glyph::g("😂", "laugh 笑哭 哭笑"),
            Glyph::g("🤣", "rofl 大笑"),
            Glyph::g("😊", "smile 微笑"),
            Glyph::g("🙂", "slight"),
            Glyph::g("😉", "wink 眨眼"),
            Glyph::g("😍", "love 爱 心 喜欢"),
            Glyph::g("😘", "kiss 亲"),
            Glyph::g("😎", "cool 酷"),
            Glyph::g("🤩", "star 星星眼"),
            Glyph::g("🥳", "party 庆祝"),
            Glyph::g("😏", "smirk"),
            Glyph::g("😴", "sleep 睡"),
            Glyph::g("🤔", "think 思考"),
            Glyph::g("😭", "cry 哭"),
            Glyph::g("😅", "sweat"),
            Glyph::g("😡", "angry 生气"),
            Glyph::g("🥺", "plead 委屈"),
            Glyph::g("👍", "thumbsup 赞 好 顶"),
            Glyph::g("👎", "thumbsdown 踩"),
            Glyph::g("👏", "clap 鼓掌"),
            Glyph::g("🙏", "pray 拜托 谢谢"),
            Glyph::g("💪", "muscle 加油"),
            Glyph::g("🤝", "handshake 握手"),
            Glyph::g("❤️", "heart 心 爱"),
            Glyph::g("🧡", "orange heart"),
            Glyph::g("💛", "yellow heart"),
            Glyph::g("💚", "green heart"),
            Glyph::g("💙", "blue heart"),
            Glyph::g("💜", "purple heart"),
            Glyph::g("🔥", "fire 火 热"),
            Glyph::g("✨", "sparkle 闪"),
            Glyph::g("🎉", "party 庆祝 撒花"),
            Glyph::g("🎊", "confetti"),
            Glyph::g("⭐", "star 星"),
            Glyph::g("💯", "hundred 满分 百分"),
            Glyph::g("✅", "check 对"),
            Glyph::g("❌", "cross 错"),
            Glyph::g("💡", "idea 灯泡"),
            Glyph::g("🚀", "rocket 火箭"),
        ],
        "symbol" => vec![
            Glyph::g("×", "times 乘 叉"),
            Glyph::g("÷", "divide 除"),
            Glyph::g("±", "plusminus 正负"),
            Glyph::g("∓", ""),
            Glyph::g("°", "degree 度"),
            Glyph::g("′", ""),
            Glyph::g("″", ""),
            Glyph::g("µ", "micro"),
            Glyph::g("§", "section 节 章节"),
            Glyph::g("¶", "pilcrow 段落"),
            Glyph::g("→", "arrow 箭头 右"),
            Glyph::g("←", "arrow 左"),
            Glyph::g("↑", "上"),
            Glyph::g("↓", "下"),
            Glyph::g("↔", ""),
            Glyph::g("⇒", "implies"),
            Glyph::g("★", "star 星 实心"),
            Glyph::g("☆", "star 星 空心"),
            Glyph::g("♥", "heart 心"),
            Glyph::g("♦", ""),
            Glyph::g("♣", ""),
            Glyph::g("♠", ""),
            Glyph::g("✓", "check 对勾"),
            Glyph::g("✗", "cross"),
            Glyph::g("∞", "infinity 无穷"),
            Glyph::g("≈", "approx 约"),
            Glyph::g("≠", "neq 不等"),
            Glyph::g("≤", "leq"),
            Glyph::g("≥", "geq"),
            Glyph::g("√", "root 根号"),
            Glyph::g("∑", "sum 求和"),
            Glyph::g("∫", "integral 积分"),
            Glyph::g("π", "pi"),
            Glyph::g("Ω", "omega"),
            Glyph::g("©", "copyright 版权"),
            Glyph::g("®", "registered"),
            Glyph::g("™", "trademark 商标"),
            Glyph::g("№", "number 编号"),
            Glyph::g("‰", "permille 千分"),
            Glyph::g("†", "dagger"),
        ],
        "kaomoji" => vec![
            Glyph::w("(๑•́ ₃ •̀๑)", "撇嘴 委屈"),
            Glyph::w("¯\\_(ツ)_/¯", "耸肩 摊手 shrug"),
            Glyph::w("(╯°□°)╯︵ ┻━┻", "掀桌 flip"),
            Glyph::w("┬─┬ ノ( ゜-゜ノ)", "摆正 putback"),
            Glyph::w("(´；ω；｀)", "哭 cry"),
            Glyph::w("(≧▽≦)", "开心 happy"),
            Glyph::w("(＾▽＾)", "笑 smile"),
            Glyph::w("(╥﹏╥)", "大哭"),
            Glyph::w("(ಠ_ಠ)", "无语 disapprove"),
            Glyph::w("ʕ•ᴥ•ʔ", "熊 bear"),
            Glyph::w("(☞ﾟヮﾟ)☞", "指 point"),
            Glyph::w("(◍•ᴗ•◍)", "可爱 cute"),
            Glyph::w("(｀・ω・´)", "认真"),
            Glyph::w("(ノ°▽°)ノ︵", "撒"),
            Glyph::w("σ(￣、￣〃)", "思考"),
            Glyph::w("(*/ω＼*)", "害羞 shy"),
        ],
        "punct" => vec![
            Glyph::g("《》", "书名号 shumihao"),
            Glyph::g("「」", "引号 quote"),
            Glyph::g("『』", "引号 双书名"),
            Glyph::g("【】", "方头括号"),
            Glyph::g("（）", "括号 paren"),
            Glyph::g("〈〉", "尖括号"),
            Glyph::g("—", "破折号 dash"),
            Glyph::g("…", "省略号 ellipsis"),
            Glyph::g("§", "节 section"),
            Glyph::g("¶", "段落 paragraph"),
            Glyph::g("、", "顿号"),
            Glyph::g("；", "分号 semicolon"),
            Glyph::g("：", "冒号 colon"),
            Glyph::g("·", "间隔号 middot"),
            Glyph::g("※", "参考 reference"),
            Glyph::g("～", "波浪 tilde"),
            Glyph::g("‖", "双竖线"),
            Glyph::g("＂", "引号"),
            Glyph::g("•", "项目符号 bullet"),
            Glyph::g("‹›", "单尖括号"),
            Glyph::g("«»", "法文引号"),
            Glyph::g("¡", "倒叹号"),
            Glyph::g("¿", "倒问号"),
            Glyph::g("℃", "摄氏度"),
        ],
        _ => vec![],
    }
}

pub fn emoji_search(query: &str) -> Vec<Glyph> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return vec![];
    }
    let mut all = emoji_catalog("emoji");
    all.extend(emoji_catalog("symbol"));
    all.extend(emoji_catalog("punct"));
    all.extend(emoji_catalog("kaomoji"));
    all.into_iter()
        .filter(|g| g.char.to_lowercase().contains(&q) || g.keywords.to_lowercase().contains(&q))
        .collect()
}

pub fn recents_seed() -> Vec<String> {
    vec![
        "😂".into(),
        "❤️".into(),
        "👍".into(),
        "《》".into(),
        "「」".into(),
        "§".into(),
        "—".into(),
        "→".into(),
        "🎉".into(),
        "✓".into(),
        "°".into(),
        "…".into(),
    ]
}

pub fn recents_push(recents: &[String], item: &str, cap: usize) -> Vec<String> {
    let mut list: Vec<String> = recents.iter().filter(|&x| x != item).cloned().collect();
    list.insert(0, item.to_string());
    if list.len() > cap {
        list.truncate(cap);
    }
    list
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_emoji_search() {
        let results = emoji_search("笑");
        assert!(!results.is_empty());
        assert!(results.iter().any(|g| g.char == "😀"));
    }

    #[test]
    fn test_recents_push() {
        let seed = recents_seed();
        let updated = recents_push(&seed, "🔥", 14);
        assert_eq!(updated[0], "🔥");
        assert_eq!(updated.len(), 13);

        let capped = recents_push(&updated, "⭐", 5);
        assert_eq!(capped.len(), 5);
        assert_eq!(capped[0], "⭐");
    }
}
