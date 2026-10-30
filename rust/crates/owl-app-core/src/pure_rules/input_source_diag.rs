use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TisSourceState {
    pub id: String,
    pub bundle_id: String,
    pub localized_name: String,
    pub enable_capable: bool,
    pub select_capable: bool,
    pub enabled: bool,
    pub selected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LayerResult {
    pub layer: String,
    pub ok: Option<bool>,
    pub code: Option<String>,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TisDiagnosis {
    pub layers: Vec<LayerResult>,
    pub first_failing_layer: Option<String>,
    pub code: Option<String>,
}

pub fn classify_tis_diagnosis(
    sources: &[TisSourceState],
    current_source_id: Option<&str>,
    expected_ids: &[String],
    primary_id: &str,
) -> TisDiagnosis {
    let mut layers = Vec::new();
    let registered = !sources.is_empty();
    let primary = sources.iter().find(|s| s.id == primary_id);
    let primary_present = primary.is_some();
    let half_state = current_source_id.and_then(|cur| {
        sources.iter().find(|s| s.id == cur && !s.enabled)
    });

    // 1. register
    layers.push(LayerResult {
        layer: "register".into(),
        ok: Some(registered),
        code: if registered {
            None
        } else {
            Some("OWL-TIS-001".into())
        },
        detail: if registered {
            format!(
                "{} 个 Owltype 输入源可枚举（TISCreateInputSourceList includeAllInstalled=true）",
                sources.len()
            )
        } else {
            "0 个 Owltype 输入源可枚举 → 未注册（核对安装路径/签名/Info.plist）".into()
        },
    });

    // 2. enumerate
    let present_ids: std::collections::HashSet<_> =
        sources.iter().map(|s| &s.id).collect();
    let missing: Vec<_> = expected_ids
        .iter()
        .filter(|id| !present_ids.contains(id))
        .collect();
    if !registered {
        layers.push(LayerResult {
            layer: "enumerate".into(),
            ok: None,
            code: None,
            detail: "未评估（register 失败）".into(),
        });
    } else if !primary_present {
        layers.push(LayerResult {
            layer: "enumerate".into(),
            ok: Some(false),
            code: Some("OWL-TIS-001".into()),
            detail: format!(
                "主输入源 {} 不可枚举；已见 {:?}",
                primary_id,
                sources.iter().map(|s| &s.id).collect::<Vec<_>>()
            ),
        });
    } else {
        layers.push(LayerResult {
            layer: "enumerate".into(),
            ok: Some(true),
            code: None,
            detail: if missing.is_empty() {
                format!("全部期望输入源就位 {:?}", expected_ids)
            } else {
                format!("主输入源就位；次要缺失 {:?}", missing)
            },
        });
    }

    // 3. enable
    if !registered || !primary_present {
        layers.push(LayerResult {
            layer: "enable".into(),
            ok: None,
            code: None,
            detail: "未评估（主输入源不可枚举）".into(),
        });
    } else if let Some(p) = primary {
        if p.enabled {
            layers.push(LayerResult {
                layer: "enable".into(),
                ok: Some(true),
                code: None,
                detail: format!("主输入源 {} 已启用", primary_id),
            });
        } else if half_state.is_some() {
            layers.push(LayerResult {
                layer: "enable".into(),
                ok: None,
                code: None,
                detail: "enabled=false，属选中半态，见 select 层（OWL-TIS-004）".into(),
            });
        } else if !p.enable_capable {
            layers.push(LayerResult {
                layer: "enable".into(),
                ok: Some(false),
                code: Some("OWL-TIS-002".into()),
                detail: format!(
                    "主输入源 {} 不可启用（IsEnableCapable=false / 父条目未启用）",
                    primary_id
                ),
            });
        } else if let Some(wrong) =
            sources.iter().find(|s| s.enabled && !expected_ids.contains(&s.id))
        {
            layers.push(LayerResult {
                layer: "enable".into(),
                ok: Some(false),
                code: Some("OWL-TIS-002".into()),
                detail: format!(
                    "启用了非期望输入源 {} 而非 {}（enable 打在错误条目/按名称选择）—— 只按精确 source id 操作",
                    wrong.id, primary_id
                ),
            });
        } else {
            layers.push(LayerResult {
                layer: "enable".into(),
                ok: Some(false),
                code: Some("OWL-TIS-003".into()),
                detail: format!(
                    "主输入源 {} 可启用但读回 enabled=false —— 运行 --enable-input-source；读回仍 false = 启用不一致",
                    primary_id
                ),
            });
        }
    }

    // 4. select
    if !registered || !primary_present {
        layers.push(LayerResult {
            layer: "select".into(),
            ok: None,
            code: None,
            detail: "未评估（主输入源不可枚举）".into(),
        });
    } else if let Some(half) = half_state {
        layers.push(LayerResult {
            layer: "select".into(),
            ok: Some(false),
            code: Some("OWL-TIS-004".into()),
            detail: format!(
                "当前源 {} 已选中但 enabled=false（吞键死半态）—— 先切 ABC 再重选「猫头鹰」，或系统设置→键盘→输入法重加一次",
                half.id
            ),
        });
    } else if let Some(p) = primary {
        if p.enabled {
            if !p.select_capable {
                layers.push(LayerResult {
                    layer: "select".into(),
                    ok: Some(false),
                    code: Some("OWL-TIS-004".into()),
                    detail: format!("主输入源 {} 已启用但不可选中（IsSelectCapable=false）", primary_id),
                });
            } else if p.selected {
                layers.push(LayerResult {
                    layer: "select".into(),
                    ok: Some(true),
                    code: None,
                    detail: format!("主输入源 {} 已选中（当前）", primary_id),
                });
            } else {
                layers.push(LayerResult {
                    layer: "select".into(),
                    ok: Some(true),
                    code: None,
                    detail: format!("主输入源 {} 已启用且可选中；当前未选中 —— 在输入菜单选「猫头鹰」即可", primary_id),
                });
            }
        } else {
            layers.push(LayerResult {
                layer: "select".into(),
                ok: None,
                code: None,
                detail: "未评估（主输入源未启用）".into(),
            });
        }
    }

    // 5. menuVisible
    let primary_enabled = primary.map_or(false, |p| p.enabled);
    layers.push(LayerResult {
        layer: "menuVisible".into(),
        ok: None,
        code: None,
        detail: if primary_enabled {
            "只读探针看不到输入菜单缓存。若已 enabled 但菜单仍不列「猫头鹰」= OWL-TIS-006（菜单缓存未刷新）：等软/硬窗自然翻绿或用手动菜单代理刷新按钮；刷新后仍不列 = 会话层拒收（TIS 全绿也无用户态解法，2026-08-12 本机实证），注销重登即愈".into()
        } else {
            "未评估（主输入源未启用）".into()
        },
    });

    // 6. clientAttach
    layers.push(LayerResult {
        layer: "clientAttach".into(),
        ok: None,
        code: None,
        detail: format!(
            "系统当前输入源 = {}。某 App 的 IMK client 是否 attach 需活跃 App：TIS 全绿但某「已打开」App 无输入 = OWL-TIS-005，重开该 App（系统天花板，微信同款）",
            current_source_id.unwrap_or("无")
        ),
    });

    let first_failing = layers.iter().find(|l| l.ok == Some(false));
    let first_failing_layer = first_failing.map(|l| l.layer.clone());
    let code = first_failing.and_then(|l| l.code.clone());

    TisDiagnosis {
        layers,
        first_failing_layer,
        code,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LsBundleClaim {
    pub path: String,
    pub team_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LsClaimReport {
    pub bundle_id: String,
    pub claim_count: usize,
    pub unsigned_count: usize,
    pub claims: Vec<LsBundleClaim>,
    pub code: Option<String>,
    pub detail: String,
}

pub fn classify_ls_claims(bundle_id: &str, claims: &[LsBundleClaim]) -> LsClaimReport {
    let claim_count = claims.len();
    let unsigned_count = claims.iter().filter(|c| c.team_id.is_none()).count();
    let (code, detail) = if claim_count > 1 {
        (
            Some("OWL-LS-001".into()),
            format!("{} 个不同构建认领同一 bundle id ({})", claim_count, bundle_id),
        )
    } else if unsigned_count > 0 {
        (
            Some("OWL-LS-002".into()),
            format!("存在未签名构建认领同一 bundle id ({})", bundle_id),
        )
    } else {
        (
            None,
            format!("{} 个构建认领同一 bundle id ({})，无冲突", claim_count, bundle_id),
        )
    };
    LsClaimReport {
        bundle_id: bundle_id.into(),
        claim_count,
        unsigned_count,
        claims: claims.to_vec(),
        code,
        detail,
    }
}
