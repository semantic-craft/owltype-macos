//! Pure host capability policy. Native discovery and secure-input reads stay in Swift.
//! Reasons, precedence and explicit user overrides preserve the existing App contract.
use serde_json::{json, Value};

fn decision(allowed: bool, reason: &str) -> Value {
    json!({"allowed":allowed,"reason":reason})
}
fn lower(value: &Value) -> String {
    value.as_str().unwrap_or("").to_lowercase()
}

struct Facts<'a> {
    input: &'a Value,
    bundle: String,
    secure: bool,
    password: bool,
    word: bool,
    office: bool,
    docs: bool,
    chromium: bool,
    electron: bool,
    safari_address: bool,
    terminal: bool,
    launcher: bool,
    appkit: bool,
}
impl<'a> Facts<'a> {
    fn new(input: &'a Value) -> Self {
        let host = &input["host"];
        let bundle = lower(&host["bundleID"]);
        let app = lower(&host["appName"]);
        let role = lower(&host["fieldRole"]);
        let signal = lower(&host["fieldIdentifierSignal"]);
        let title = lower(&host["windowTitle"]);
        let url = lower(&host["urlHost"]);
        let word = bundle == "com.microsoft.word";
        Self {
            input,
            secure: input["privacy"]["isSecureInputEnabled"] == true,
            password: input["privacy"]["isPasswordLike"] == true
                || signal.contains("password")
                || role.contains("secure"),
            word,
            office: word
                || [
                    "com.microsoft.excel",
                    "com.microsoft.powerpoint",
                    "com.microsoft.powerpoint.mac",
                    "com.microsoft.outlook",
                ]
                .contains(&bundle.as_str()),
            docs: url == "docs.google.com"
                || url.ends_with(".docs.google.com")
                || title.contains("google docs")
                || title.contains("google 文档")
                || title.contains("google 試算表"),
            chromium: [
                "com.google.chrome",
                "com.google.chrome.canary",
                "org.chromium.chromium",
                "com.microsoft.edgemac",
                "com.brave.browser",
                "com.vivaldi.vivaldi",
                "com.operasoftware.opera",
            ]
            .contains(&bundle.as_str()),
            // Runtime framework discovery covers new Electron applications. ToDesktop's family
            // and the verified fallback list preserve behavior when no bundle URL is available.
            electron: host["linksElectronFramework"] == true
                || bundle.starts_with("com.todesktop.")
                || [
                    "com.tinyspeck.slackmacgap",
                    "com.hnc.discord",
                    "com.microsoft.vscode",
                    "com.github.githubclient",
                    "com.openai.chat",
                    "com.anthropic.claudefordesktop",
                    "com.openai.codex",
                    "notion.id",
                ]
                .contains(&bundle.as_str())
                || signal.contains("electron")
                || app.contains("electron"),
            safari_address: bundle == "com.apple.safari"
                && (role.contains("search")
                    || signal.contains("address")
                    || signal.contains("url")
                    || signal.contains("search")),
            terminal: [
                "com.apple.terminal",
                "com.googlecode.iterm2",
                "dev.warp.warp-stable",
                "com.github.wez.wezterm",
            ]
            .contains(&bundle.as_str()),
            launcher: [
                "com.apple.spotlight",
                "com.raycast.macos",
                "com.runningwithcrayons.alfred",
            ]
            .contains(&bundle.as_str())
                || app.contains("spotlight")
                || app.contains("raycast"),
            appkit: [
                "com.apple.textedit",
                "com.apple.notes",
                "com.apple.mail",
                "com.apple.stickies",
            ]
            .contains(&bundle.as_str()),
            bundle,
        }
    }
    fn overridden(&self, capability: &str) -> Option<Value> {
        if self.bundle.is_empty() {
            return None;
        }
        for (name, allowed, reason) in [
            ("forceDeniedCapabilitiesByBundleID", false, "userForcedDeny"),
            (
                "forceAllowedCapabilitiesByBundleID",
                true,
                "userForcedAllow",
            ),
        ] {
            let contains = self.input["workarounds"][name]
                .as_object()
                .is_some_and(|bundles| {
                    bundles.iter().any(|(bundle, capabilities)| {
                        bundle.to_lowercase() == self.bundle
                            && capabilities
                                .as_array()
                                .is_some_and(|values| values.iter().any(|v| v == capability))
                    })
                });
            if contains {
                return Some(decision(allowed, reason));
            }
        }
        None
    }
    fn decide(&self, capability: &str) -> Value {
        if capability == "nonzeroCharacterIndexAttributes" {
            return decision(false, "deniedNonzeroCharacterIndexHotPath");
        }
        if let Some(value) = self.overridden(capability) {
            return value;
        }
        let deny = |reason| decision(false, reason);
        let allow = |reason| decision(true, reason);
        match capability {
            "selectedRange" | "replacementRange" => {
                if self.secure {
                    return deny("deniedSecureInput");
                }
                if self.password {
                    return deny("deniedPasswordLikeContext");
                }
                if self.office {
                    return deny("deniedOfficeRange");
                }
                if self.docs {
                    return deny("deniedGoogleDocsClient");
                }
                if self.chromium {
                    return deny("deniedChromiumClient");
                }
                if self.electron {
                    return deny("deniedElectronClient");
                }
                if self.safari_address {
                    return deny("deniedSafariAddressBar");
                }
                if self.launcher {
                    return deny("deniedLauncherSearchClient");
                }
                allow(if capability == "replacementRange" && self.appkit {
                    "allowedAppKitClient"
                } else {
                    "allowedDefault"
                })
            }
            "surroundingText" => {
                if self.secure {
                    return deny(if self.terminal {
                        "deniedTerminalSecureInput"
                    } else {
                        "deniedSecureInput"
                    });
                }
                if self.password {
                    return deny("deniedPasswordLikeContext");
                }
                if self.docs {
                    return deny("deniedGoogleDocsClient");
                }
                if self.chromium {
                    return deny("deniedChromiumClient");
                }
                if self.electron {
                    return deny("deniedElectronClient");
                }
                if self.safari_address {
                    return deny("deniedSafariAddressBar");
                }
                if self.launcher {
                    return deny("deniedLauncherSearchClient");
                }
                allow("allowedDefault")
            }
            "caretAttributes" => {
                if self.secure {
                    return deny("deniedSecureInput");
                }
                if self.password {
                    return deny("deniedPasswordLikeContext");
                }
                if self.launcher {
                    return deny("deniedLauncherSearchClient");
                }
                allow("allowedDefault")
            }
            "inputModeSwitch" => {
                if self.word {
                    return deny("deniedOfficeInputMode");
                }
                if self.launcher {
                    return deny("deniedLauncherSearchClient");
                }
                allow("allowedDefault")
            }
            "contextMenu" => {
                if self.secure {
                    return deny("deniedSecureInput");
                }
                if self.password {
                    return deny("deniedPasswordLikeContext");
                }
                if self.launcher {
                    return deny("deniedLauncherSearchClient");
                }
                if self.safari_address {
                    return deny("deniedSafariAddressBar");
                }
                allow("allowedDefault")
            }
            "delayedCandidatePositioning" => {
                if self.docs {
                    return allow("delayedForGoogleDocsClient");
                }
                if self.chromium {
                    return allow("delayedForChromiumClient");
                }
                if self.electron {
                    return allow("delayedForElectronClient");
                }
                if self.safari_address {
                    return allow("delayedForSafariAddressBar");
                }
                deny("notNeeded")
            }
            "privacyComposition" => {
                if self.secure
                    || self.password
                    || self.input["privacy"]["isPrivacyModeRequested"] == true
                {
                    allow("allowedPrivacyComposition")
                } else {
                    deny("notNeeded")
                }
            }
            _ => unreachable!("internal capability catalog"),
        }
    }
}

pub fn evaluate(input: &Value) -> Value {
    let facts = Facts::new(input);
    [
        "selectedRange",
        "replacementRange",
        "surroundingText",
        "caretAttributes",
        "nonzeroCharacterIndexAttributes",
        "inputModeSwitch",
        "contextMenu",
        "delayedCandidatePositioning",
        "privacyComposition",
    ]
    .into_iter()
    .map(|name| (name.to_owned(), facts.decide(name)))
    .collect()
}
