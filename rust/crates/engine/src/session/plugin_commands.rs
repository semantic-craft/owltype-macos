//! 脚本插件在 `/` 模式里给出的行（来源 `Plugin`）。写法照 `/fy`（`online.rs` 的 `command_translation_query`、`apply_command_translation`）：引擎只说「这份预编辑串要问哪条插件指令」，宿主问过插件之后把行交回来；会话或预编辑串已经变了的回答被拒绝。
//!
//! 和 `/fy` 不同的是行会缓存（`InputSession::plugin_rows`）：`update_local_candidates` 每次都从头重建 `local_candidates`，没有缓存的话方向键、翻页、换表之后插件行就丢了，又不会再问。缓存只有一槽，预编辑串一变就清掉。

use super::input::InputSession;
use crate::local::command::{RESULT_LIMIT, TEXT_UTF16_LIMIT};
use crate::types::{CandidateSource, LocalInputMode, PluginCommandQuery, WordItem};

impl InputSession {
    /// 只在 `/` 模式里、不在专用英文、输入属于某条生效的插件指令、这份预编辑串还没有缓存的行时返回 `Some`；问过一次（哪怕插件给了 0 行）之后同一份预编辑串不再问。
    pub(super) fn plugin_command_query(&self) -> Option<PluginCommandQuery> {
        if self.dedicated_english || self.local_mode != LocalInputMode::Command {
            return None;
        }
        if self
            .plugin_rows
            .as_ref()
            .is_some_and(|(preedit, _)| *preedit == self.local_preedit)
        {
            return None;
        }
        let code = self.local_preedit.get(1..)?;
        let (trigger, argument) = self.queries.plugin_command_source(code)?;
        Some(PluginCommandQuery {
            session_id: self.online_requests.session_id,
            preedit: self.local_preedit.clone(),
            trigger: trigger.to_owned(),
            argument: argument.to_owned(),
        })
    }

    /// 把插件给的行（文本，插件注释）写进缓存并放到列表前面，有行时去掉兜底行；注释不进引擎，由 runtime 保管。查询过期（会话不同、预编辑串变了、已经缓存过）时返回 false，什么都不改。引擎仍然丢掉它用不了的行：空白、含控制字符、超过 `TEXT_UTF16_LIMIT` 个 UTF-16 码元、和前面的行同文，最多留 `RESULT_LIMIT` 行。一行都不剩时缓存成空表，兜底行（原样的 `/xxx`）留着。
    pub(super) fn apply_plugin_command_rows(
        &mut self,
        query: &PluginCommandQuery,
        rows: &[(String, String)],
    ) -> bool {
        if self.plugin_command_query().as_ref() != Some(query) {
            return false;
        }
        let mut texts: [Option<&str>; RESULT_LIMIT] = [None; RESULT_LIMIT];
        let mut text_count = 0;
        for (text, _) in rows {
            if text_count == RESULT_LIMIT {
                break;
            }
            if !text.trim().is_empty()
                && !text.chars().any(char::is_control)
                && text.encode_utf16().count() <= TEXT_UTF16_LIMIT
                && !texts[..text_count]
                    .iter()
                    .flatten()
                    .any(|existing| *existing == text)
            {
                texts[text_count] = Some(text);
                text_count += 1;
            }
        }
        let count = text_count;
        let items = texts
            .into_iter()
            .take(count)
            .flatten()
            .enumerate()
            .map(|(index, text)| {
                WordItem::new(
                    query.trigger.clone(),
                    text,
                    (count - index) as i64,
                    CandidateSource::Plugin,
                    "",
                )
            })
            .collect::<Vec<_>>();
        if !items.is_empty() {
            // 插件行顶替兜底行；以后列表重建时由 `update_local_candidates` 从缓存放回。
            self.local_candidates.retain(|item| {
                item.source != CandidateSource::Fallback
                    && !items.iter().any(|row| row.word == item.word)
            });
            self.local_candidates.splice(0..0, items.iter().cloned());
        }
        self.plugin_rows = Some((query.preedit.clone(), items));
        true
    }
}
