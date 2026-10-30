use serde::{Deserialize, Serialize};

pub const PRIMARY_SOURCE: &str = "im.owltype.inputmethod.Owltype.Hans";
pub const INSTALLED_EXECUTABLE: &str = "/Library/Input Methods/Owltype.app/Contents/MacOS/Owltype";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestartServer {
    pub pid: i32,
    pub executable: String,
    pub version: String,
    pub maps_installed_executable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestartObservation {
    pub parent_enabled: bool,
    pub mode_enabled: bool,
    pub selected_source: String,
    pub servers: Vec<RestartServer>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestartRequest {
    pub first_install: bool,
    pub source_before: String,
    pub expected_version: String,
}

impl RestartRequest {
    pub fn selection_target(&self) -> Option<String> {
        if self.first_install {
            return Some(PRIMARY_SOURCE.into());
        }
        if self.source_before == "im.owltype.inputmethod.Owltype.Hans"
            || self.source_before == "im.owltype.inputmethod.Owltype.Hant"
        {
            Some(self.source_before.clone())
        } else {
            None
        }
    }

    pub fn expected_source(&self) -> String {
        self.selection_target().unwrap_or_else(|| self.source_before.clone())
    }

    pub fn probe_mode(&self) -> String {
        self.selection_target().unwrap_or_else(|| PRIMARY_SOURCE.into())
    }
}

pub fn maps_lsof(lsof: &str, path: &str, inode: u64) -> bool {
    let path_marker = format!("n{path}");
    let inode_marker = format!("i{inode}");
    for record in lsof.split("ftxt\n").skip(1) {
        let lines: Vec<&str> = record.lines().collect();
        if lines.contains(&path_marker.as_str()) && lines.contains(&inode_marker.as_str()) {
            return true;
        }
    }
    false
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UnmetCondition {
    SourceNotEnabled,
    SelectedSourceDiffers,
    NoServer,
    MultipleServers,
    ServerOutsideInstalledApp,
    ServerVersionDiffers,
    ServerMapsOtherExecutable,
}

pub fn unmet_server_conditions(servers: &[RestartServer], expected_version: &str) -> Vec<UnmetCondition> {
    if servers.is_empty() {
        return vec![UnmetCondition::NoServer];
    }
    let mut unmet = Vec::new();
    if servers.len() > 1 {
        unmet.push(UnmetCondition::MultipleServers);
    }
    for server in servers {
        if server.executable != INSTALLED_EXECUTABLE {
            unmet.push(UnmetCondition::ServerOutsideInstalledApp);
        }
        if !server.version.is_empty() && !expected_version.is_empty() && server.version != expected_version {
            unmet.push(UnmetCondition::ServerVersionDiffers);
        }
        if !server.maps_installed_executable {
            unmet.push(UnmetCondition::ServerMapsOtherExecutable);
        }
    }
    unmet
}

pub fn unmet_conditions(observation: &RestartObservation, request: &RestartRequest) -> Vec<UnmetCondition> {
    let mut unmet = Vec::new();
    if !observation.parent_enabled || !observation.mode_enabled {
        unmet.push(UnmetCondition::SourceNotEnabled);
    }
    let expected = request.expected_source();
    if !expected.is_empty() && observation.selected_source != expected {
        unmet.push(UnmetCondition::SelectedSourceDiffers);
    }
    unmet.extend(unmet_server_conditions(&observation.servers, &request.expected_version));
    unmet
}
