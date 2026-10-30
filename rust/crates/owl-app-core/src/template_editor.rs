//! Draft mutation policy. Native view state is an editable projection; Rust returns accepted
//! drafts and commit plans, and failed persistence never publishes that plan to readers.
use crate::foundation_text::trim;
use crate::{storage::*, template, template_import, template_library::*};
use serde_json::{json, Value};
fn options(s: &str) -> Vec<String> {
    if s.is_empty() {
        vec![]
    } else {
        s.split(',').map(|s| trim(s).into()).collect()
    }
}
fn field(p: &Parameter, anonymous: bool) -> String {
    let mut text = "{argument".to_owned();
    if !anonymous {
        text.push_str(&format!(" name={}", template::quoted(&p.name)))
    }
    if let Some(v) = &p.default_value {
        text.push_str(&format!(" default={}", template::quoted(v)))
    }
    if !p.options.is_empty() {
        text.push_str(&format!(
            " options={}",
            template::quoted(&p.options.join(", "))
        ))
    }
    text + "}"
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    if operation == "editor_disabled_apps" {
        let mut values: Vec<String> = decode(args["values"].clone())?;
        let text = args["text"].as_str().unwrap_or("");
        if args["remove"] == true {
            let mut kept = vec![];
            for value in values {
                let equal: bool = decode(effect(
                    host,
                    "case_contains",
                    json!({"values":[value], "value":text}),
                )?)?;
                if !equal {
                    kept.push(value);
                }
            }
            values = kept;
        } else {
            let value = trim(text).to_lowercase();
            if !value.contains('.')
                || !regex::Regex::new(r"^[a-z0-9][a-z0-9.-]*$")
                    .unwrap()
                    .is_match(&value)
            {
                return Err("请输入应用的完整 bundle ID，例如 com.apple.TextEdit。".into());
            }
            let exists: bool = decode(effect(
                host,
                "case_contains",
                json!({"values":values,"value":value}),
            )?)?;
            if !exists {
                values.push(value);
            }
        }
        return Ok(json!(values));
    }
    let mut draft: Entry = decode(args["draft"].clone())?;
    if operation == "editor_unsaved" {
        let library: Library = decode(args["library"].clone())?;
        return Ok(json!(if let Some(saved) = library
            .entries
            .iter()
            .find(|e| e.id.eq_ignore_ascii_case(&draft.id))
        {
            serde_json::to_value(saved).ok() != serde_json::to_value(&draft).ok()
        } else {
            !draft.title.is_empty()
                || !draft.body.is_empty()
                || draft.trigger.is_some()
                || !draft.tags.is_empty()
                || draft.is_pinned
        }));
    }
    if operation == "editor_save" {
        if draft.review_state.is_none() {
            if let Some(d) = draft
                .parsed(false)
                .diagnostics
                .iter()
                .find(|d| d.severity == "error")
            {
                return Err(d.message.clone());
            }
        }
        if draft.import_source.is_some() && !template_import::compatibility(&draft).is_empty() {
            draft.review_state = Some(Review::Pending)
        }
        if draft.trigger.as_ref().is_some_and(|s| s.is_empty()) {
            draft.trigger = None
        }
        let mut library: Library = decode(args["library"].clone())?;
        if let Some(e) = library
            .entries
            .iter_mut()
            .find(|e| e.id.eq_ignore_ascii_case(&draft.id))
        {
            *e = draft.clone()
        } else {
            library.entries.push(draft.clone())
        }
        validate(&library)?;
        return Ok(
            json!({"draft":draft,"library":library,"status":if draft.review_state.is_some(){"已保存为待处理；修正并启用前不能执行。"}else{"已保存。候选调用在重新部署后生效。"}}),
        );
    }
    let mut status: Option<String> = None;
    let mut check = false;
    match args["action"].as_str().unwrap_or("") {
        "invocation" => {
            let mode: Invocation = decode(args["mode"].clone())?;
            if mode == Invocation::Automatic && draft.invocation_mode != Invocation::Automatic {
                draft.expansion_mode = Expansion::Immediate
            }
            draft.invocation_mode = mode;
            if mode != Invocation::Candidate {
                draft.candidate_aliases.clear()
            }
        }
        "tag" => {
            let tag = trim(args["text"].as_str().unwrap_or(""));
            let exists: bool = decode(effect(
                host,
                "case_contains",
                json!({"values":draft.tags,"value":tag}),
            )?)?;
            if !tag.is_empty() && !exists {
                draft.tags.push(tag.into())
            }
        }
        "body" => {
            let body = args["text"].as_str().unwrap_or("");
            if draft.body.as_bytes() != body.as_bytes() {
                draft.body = body.into();
                if draft.parameters.iter().any(|p| p.key.starts_with("a:")) {
                    draft.parameters.retain(|p| !p.key.starts_with("a:"));
                    status=Some("正文已修改：匿名参数设置已重置，请重新核对必填、默认值和选项。命名参数设置保留。".into())
                }
            }
        }
        "dynamic" | "temporal" => {
            if draft.body_type != BodyType::Template || draft.syntax != Syntax::Standard {
                return Err("请先明确切换到模板及动态字段语法。".into());
            }
            let text = if args["action"] == "temporal" {
                let mut text = format!("{{{}", args["kind"].as_str().unwrap_or(""));
                let format = args["format"].as_str().unwrap_or("");
                let offset = args["offset"].as_str().unwrap_or("");
                if !format.is_empty() {
                    text.push_str(&format!(" format={}", template::quoted(format)))
                }
                if !trim(offset).is_empty() {
                    text.push_str(&format!(" offset={}", template::quoted(offset)))
                }
                text + "}"
            } else {
                args["text"].as_str().unwrap_or("").into()
            };
            draft.body.push_str(&text);
            check = true;
            status = Some("已插入到正文末尾，保存后生效。".into());
        }
        "insert_parameter" | "update_parameter" => {
            let insert = args["action"] == "insert_parameter";
            if insert && (draft.body_type != BodyType::Template || draft.syntax != Syntax::Standard)
            {
                return Err("请先明确选择模板及动态字段语法。".into());
            }
            let required = args["required"].as_bool().unwrap_or(true);
            let default_value: Option<String> = decode(args["defaultValue"].clone())?;
            let opts = options(args["options"].as_str().unwrap_or(""));
            let (definition, anonymous) = if insert {
                let name = trim(args["name"].as_str().unwrap_or(""));
                let count = draft
                    .parsed(false)
                    .parameters
                    .iter()
                    .filter(|p| p.key.starts_with("a:"))
                    .count()
                    + 1;
                (
                    Parameter {
                        key: if name.is_empty() {
                            format!("a:{count}")
                        } else {
                            format!("n:{name}")
                        },
                        name: if name.is_empty() {
                            format!("参数 {count}")
                        } else {
                            name.into()
                        },
                        is_required: required,
                        default_value,
                        options: opts,
                    },
                    name.is_empty(),
                )
            } else {
                let p: template::Parameter = decode(args["parameter"].clone())?;
                let anonymous = p.key.starts_with("a:");
                (
                    Parameter {
                        key: p.key,
                        name: p.name,
                        is_required: required,
                        default_value,
                        options: opts,
                    },
                    anonymous,
                )
            };
            if insert {
                draft.body.push_str(&field(&definition, anonymous))
            } else {
                let p: template::Parameter = decode(args["parameter"].clone())?;
                if !p.legacy {
                    for range in p.ranges.iter().rev() {
                        let bytes = crate::utf16_range(&draft.body, range.location, range.length)
                            .ok_or("参数无效。")?;
                        draft
                            .body
                            .replace_range(bytes, &field(&definition, anonymous));
                    }
                }
            }
            draft
                .parameters
                .retain(|p| nfc(&p.key) != nfc(&definition.key));
            draft.parameters.push(definition);
            check = true;
            status = Some(
                if insert {
                    "已插入到正文末尾，保存后生效。"
                } else {
                    "参数设置已更新，保存后生效。"
                }
                .into(),
            );
        }
        _ => return Err("unknown_editor_action".into()),
    }
    if check {
        if let Some(error) = draft
            .parsed(false)
            .diagnostics
            .into_iter()
            .find(|d| d.severity == "error")
        {
            return Err(error.message);
        }
    }
    Ok(json!({"draft":draft,"status":status}))
}
