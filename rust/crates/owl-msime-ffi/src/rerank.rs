//! Optional neural candidate reranking for the Owltype C ABI.
//!
//! Models load on workers: the keyboard model runs on every key, while the desktop model runs
//! only after a pause. Configuration and the first key never read a model file, and a missing or
//! malformed model leaves the ordinary input session usable.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock, Weak};

use msime_engine::host::Session as EngineSession;
use msime_input_runtime::{
    score_settled_rerank, Reranker, Runtime, SentenceModel, SettledRerankScore,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

type OwlRuntime = Runtime<EngineSession>;

const MAX_MODEL_BYTES: u64 = 64 * 1024 * 1024;
static MODEL_CACHE: OnceLock<Mutex<HashMap<PathBuf, Weak<LoadedModel>>>> = OnceLock::new();
static NEXT_JOB_TOKEN: AtomicUsize = AtomicUsize::new(1);

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
struct ModelSetting {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    path: String,
    #[serde(default)]
    source: String,
    #[serde(default)]
    version: String,
    #[serde(default)]
    expected_sha256: String,
}

#[derive(Debug, Default, Deserialize)]
struct RerankConfig {
    #[serde(default)]
    keyboard: ModelSetting,
    #[serde(default)]
    settled: ModelSetting,
}

#[derive(Clone, Debug)]
struct LoadedModel {
    model: Arc<SentenceModel>,
    sha256: String,
    size: u64,
    license: String,
    attribution: String,
}

#[derive(Clone, Debug)]
struct ModelFailure {
    state: &'static str,
    reason: String,
}

impl ModelFailure {
    fn missing(reason: impl Into<String>) -> Self {
        Self {
            state: "missing",
            reason: reason.into(),
        }
    }

    fn oversized(reason: impl Into<String>) -> Self {
        Self {
            state: "oversized",
            reason: reason.into(),
        }
    }

    fn corrupt(reason: impl Into<String>) -> Self {
        Self {
            state: "corrupt",
            reason: reason.into(),
        }
    }

    fn error(reason: impl Into<String>) -> Self {
        Self {
            state: "error",
            reason: reason.into(),
        }
    }
}

struct LoadSlot {
    result: Mutex<Option<Result<Arc<LoadedModel>, ModelFailure>>>,
}

impl LoadSlot {
    fn new() -> Self {
        Self {
            result: Mutex::new(None),
        }
    }

    fn take(&self) -> Option<Result<Arc<LoadedModel>, ModelFailure>> {
        self.result
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
    }

    fn finish(self: &Arc<Self>, result: Result<Arc<LoadedModel>, ModelFailure>) {
        *self
            .result
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(result);
    }
}

#[derive(Clone, Copy)]
enum ModelKind {
    Keyboard,
    Settled,
}

#[derive(Default)]
struct Preference {
    setting: ModelSetting,
    loading: Option<Arc<LoadSlot>>,
    ready: Option<Arc<LoadedModel>>,
    failure: Option<ModelFailure>,
    attached: bool,
}

#[derive(Serialize)]
struct ModelStatus {
    enabled: bool,
    state: &'static str,
    path: Option<String>,
    source: Option<String>,
    version: Option<String>,
    expected_sha256: Option<String>,
    sha256: Option<String>,
    size: Option<u64>,
    license: Option<String>,
    attribution: Option<String>,
    attached: bool,
    error: Option<String>,
}

struct SettledJob {
    token: u64,
    presentation_epoch: u64,
    inner: Mutex<SettledPhase>,
}

enum SettledPhase {
    Running,
    Ready(Box<SettledRerankScore>),
    Done,
    Failed(String),
}

impl SettledJob {
    fn new(token: u64, presentation_epoch: u64) -> Self {
        Self {
            token,
            presentation_epoch,
            inner: Mutex::new(SettledPhase::Running),
        }
    }

    fn take(&self) -> SettledPhase {
        std::mem::replace(
            &mut *self.inner.lock().unwrap_or_else(|error| error.into_inner()),
            SettledPhase::Done,
        )
    }

    fn finish(&self, result: Result<SettledRerankScore, String>) {
        let next = match result {
            Ok(score) => SettledPhase::Ready(Box::new(score)),
            Err(reason) => SettledPhase::Failed(reason),
        };
        *self.inner.lock().unwrap_or_else(|error| error.into_inner()) = next;
    }
}

pub(super) struct RerankState {
    keyboard: Preference,
    settled: Preference,
    job: Option<Arc<SettledJob>>,
    presentation_epoch: u64,
}

impl Default for RerankState {
    fn default() -> Self {
        Self {
            keyboard: Preference::default(),
            settled: Preference::default(),
            job: None,
            presentation_epoch: 0,
        }
    }
}

impl Drop for RerankState {
    fn drop(&mut self) {
        if let Some(job) = self.job.take() {
            if let SettledPhase::Ready(score) = job.take() {
                drop(score);
            }
        }
    }
}

impl RerankState {
    pub(super) fn configure(
        &mut self,
        runtime: &mut OwlRuntime,
        input: &str,
    ) -> Result<(), String> {
        let config: RerankConfig = serde_json::from_str(input)
            .map_err(|error| format!("invalid rerank config: {error}"))?;
        let keyboard = validated(config.keyboard)?;
        let settled = validated(config.settled)?;
        self.invalidate(runtime);
        self.reconfigure(ModelKind::Keyboard, keyboard, runtime);
        self.reconfigure(ModelKind::Settled, settled, runtime);
        self.apply_pending(runtime);
        Ok(())
    }

    pub(super) fn status(&mut self, runtime: &mut OwlRuntime) -> Value {
        self.apply_pending(runtime);
        json!({
            "ok": true,
            "keyboard": self.preference(ModelKind::Keyboard).status(),
            "settled": self.preference(ModelKind::Settled).status(),
        })
    }

    pub(super) fn apply_pending(&mut self, runtime: &mut OwlRuntime) {
        self.collect(ModelKind::Keyboard);
        self.collect(ModelKind::Settled);
        self.attach(ModelKind::Keyboard, runtime);
        self.attach(ModelKind::Settled, runtime);
    }

    pub(super) fn invalidate(&mut self, runtime: &mut OwlRuntime) {
        self.presentation_epoch = self.presentation_epoch.wrapping_add(1);
        let Some(job) = self.job.as_ref() else {
            return;
        };
        let mut phase = job.inner.lock().unwrap_or_else(|error| error.into_inner());
        match &*phase {
            SettledPhase::Running => {
                // The worker owns the model until it finishes. Leave the job intact so a
                // subsequent poll can return that model to the runtime.
            }
            SettledPhase::Ready(_) | SettledPhase::Done | SettledPhase::Failed(_) => {
                let finished = std::mem::replace(&mut *phase, SettledPhase::Done);
                drop(phase);
                if let SettledPhase::Ready(score) = finished {
                    runtime.discard_settled_rerank(*score);
                }
                self.job = None;
            }
        }
    }

    pub(super) fn start_settled(&mut self, runtime: &mut OwlRuntime) -> Value {
        self.apply_pending(runtime);
        self.invalidate_done();
        if let Some(job) = &self.job {
            return json!({"status": "pending", "token": job.token});
        }
        let Some(request) = runtime.begin_settled_rerank() else {
            let moved = runtime.rerank_settled();
            return json!({"status": "done", "current": true, "moved": moved});
        };
        let token = next_job_token();
        let job = Arc::new(SettledJob::new(token, self.presentation_epoch));
        let worker = Arc::clone(&job);
        let (sender, receiver) = mpsc::channel();
        let spawned = std::thread::Builder::new()
            .name("owltype-settled-rerank".into())
            .spawn(move || {
                let Ok(request) = receiver.recv() else {
                    return;
                };
                let result = catch_unwind(AssertUnwindSafe(|| score_settled_rerank(request)))
                    .map_err(|_| "settled rerank worker panicked".to_owned());
                worker.finish(result);
            });
        if spawned.is_err() {
            drop(request);
            self.recover_settled_worker_failure(runtime);
            return json!({
                "status": "done",
                "current": false,
                "error": "cannot start settled rerank worker"
            });
        }
        if let Err(error) = sender.send(request) {
            drop(error.0);
            self.recover_settled_worker_failure(runtime);
            return json!({
                "status": "done",
                "current": false,
                "error": "settled rerank worker exited"
            });
        }
        self.job = Some(job);
        json!({"status": "pending", "token": token})
    }

    pub(super) fn poll_settled(
        &mut self,
        runtime: &mut OwlRuntime,
        token: u64,
        accept: bool,
    ) -> Value {
        self.apply_pending(runtime);
        let Some(job) = self.job.as_ref().filter(|job| job.token == token) else {
            return json!({"status": "done", "current": false, "moved": false});
        };
        let accept = accept && job.presentation_epoch == self.presentation_epoch;
        match job.take() {
            SettledPhase::Running => {
                let mut guard = job.inner.lock().unwrap_or_else(|error| error.into_inner());
                if matches!(*guard, SettledPhase::Done) {
                    *guard = SettledPhase::Running;
                }
                json!({"status": "pending", "token": token})
            }
            SettledPhase::Ready(score) => {
                self.job = None;
                if accept {
                    let applied = runtime.apply_settled_rerank(*score);
                    json!({
                        "status": "done",
                        "current": applied.current,
                        "moved": applied.moved,
                    })
                } else {
                    runtime.discard_settled_rerank(*score);
                    json!({"status": "done", "current": false, "moved": false})
                }
            }
            SettledPhase::Done => {
                self.job = None;
                json!({"status": "done", "current": false, "moved": false})
            }
            SettledPhase::Failed(error) => {
                self.job = None;
                json!({"status": "done", "current": false, "moved": false, "error": error})
            }
        }
    }

    fn invalidate_done(&mut self) {
        let finished = self.job.as_ref().is_some_and(|job| {
            matches!(
                *job.inner.lock().unwrap_or_else(|error| error.into_inner()),
                SettledPhase::Done | SettledPhase::Failed(_)
            )
        });
        if finished {
            self.job = None;
        }
    }

    fn reconfigure(&mut self, kind: ModelKind, setting: ModelSetting, runtime: &mut OwlRuntime) {
        let preference = self.preference_mut(kind);
        let reload = preference.setting.enabled != setting.enabled
            || preference.setting.path != setting.path
            || preference.setting.expected_sha256 != setting.expected_sha256;
        preference.setting = setting.clone();
        preference.attached = false;
        detach(kind, runtime);

        if !setting.enabled {
            preference.loading = None;
            preference.ready = None;
            preference.failure = None;
            return;
        }
        if !reload && (preference.loading.is_some() || preference.ready.is_some()) {
            return;
        }

        preference.ready = None;
        preference.failure = None;
        let slot = Arc::new(LoadSlot::new());
        preference.loading = Some(Arc::clone(&slot));
        let path = PathBuf::from(&setting.path);
        let expected = setting.expected_sha256.clone();
        if std::thread::Builder::new()
            .name("owltype-rerank-model".into())
            .spawn(move || {
                let result = catch_unwind(AssertUnwindSafe(|| load_shared(&path, &expected)))
                    .unwrap_or_else(|_| Err(ModelFailure::error("rerank model loader panicked")));
                slot.finish(result);
            })
            .is_err()
        {
            let preference = self.preference_mut(kind);
            preference.loading = None;
            preference.failure = Some(ModelFailure::error(
                "cannot start rerank model loader worker",
            ));
        }
    }

    fn collect(&mut self, kind: ModelKind) {
        let Some(result) = self
            .preference(kind)
            .loading
            .as_ref()
            .and_then(|slot| slot.take())
        else {
            return;
        };
        let preference = self.preference_mut(kind);
        preference.loading = None;
        match result {
            Ok(model) => {
                preference.ready = Some(model);
                preference.failure = None;
            }
            Err(error) => {
                preference.ready = None;
                preference.failure = Some(error);
            }
        }
    }

    fn attach(&mut self, kind: ModelKind, runtime: &mut OwlRuntime) {
        let preference = self.preference_mut(kind);
        if !preference.setting.enabled || preference.attached {
            return;
        }
        let Some(model) = preference.ready.as_ref() else {
            return;
        };
        match kind {
            ModelKind::Keyboard => {
                runtime.set_reranker(Some(Reranker::new(Arc::clone(&model.model))));
            }
            ModelKind::Settled => {
                runtime.set_settled_reranker(Some(Reranker::new(Arc::clone(&model.model))));
                runtime.set_settled_rerank_enabled(true);
            }
        }
        preference.attached = true;
    }

    pub(super) fn recover_settled_worker_failure(&mut self, runtime: &mut OwlRuntime) {
        // begin_settled_rerank takes the model out of the runtime. Reattach the already-loaded
        // model after dropping a request that never reached its worker.
        self.settled.attached = false;
        self.attach(ModelKind::Settled, runtime);
    }

    fn preference(&self, kind: ModelKind) -> &Preference {
        match kind {
            ModelKind::Keyboard => &self.keyboard,
            ModelKind::Settled => &self.settled,
        }
    }

    fn preference_mut(&mut self, kind: ModelKind) -> &mut Preference {
        match kind {
            ModelKind::Keyboard => &mut self.keyboard,
            ModelKind::Settled => &mut self.settled,
        }
    }
}

impl Preference {
    fn status(&self) -> ModelStatus {
        let setting = &self.setting;
        let mut status = ModelStatus {
            enabled: setting.enabled,
            state: if !setting.enabled {
                "disabled"
            } else if self.loading.is_some() {
                "loading"
            } else if self.ready.is_some() {
                "ready"
            } else if let Some(failure) = &self.failure {
                failure.state
            } else {
                "error"
            },
            path: nonempty(&setting.path),
            source: nonempty(&setting.source),
            version: nonempty(&setting.version),
            expected_sha256: nonempty(&setting.expected_sha256),
            sha256: None,
            size: None,
            license: None,
            attribution: None,
            attached: self.attached,
            error: self.failure.as_ref().map(|failure| failure.reason.clone()),
        };
        if let Some(model) = &self.ready {
            status.sha256 = Some(model.sha256.clone());
            status.size = Some(model.size);
            status.license = nonempty(&model.license);
            status.attribution = nonempty(&model.attribution);
        }
        status
    }
}

fn detach(kind: ModelKind, runtime: &mut OwlRuntime) {
    match kind {
        ModelKind::Keyboard => runtime.set_reranker(None),
        ModelKind::Settled => {
            runtime.set_settled_reranker(None);
            runtime.set_settled_rerank_enabled(false);
        }
    }
}

fn validated(mut setting: ModelSetting) -> Result<ModelSetting, String> {
    if !setting.enabled {
        return Ok(setting);
    }
    if setting.path.trim().is_empty() {
        return Err("enabled rerank model requires a path".to_owned());
    }
    if !Path::new(&setting.path).is_absolute() {
        return Err(format!(
            "rerank model path must be absolute: {}",
            setting.path
        ));
    }
    setting.expected_sha256 = setting.expected_sha256.trim().to_ascii_lowercase();
    if !setting.expected_sha256.is_empty()
        && (setting.expected_sha256.len() != 64
            || !setting
                .expected_sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit()))
    {
        return Err("expected_sha256 must be 64 hexadecimal characters".to_owned());
    }
    Ok(setting)
}

fn nonempty(value: &str) -> Option<String> {
    (!value.trim().is_empty()).then(|| value.to_owned())
}

fn load_shared(path: &Path, expected_sha256: &str) -> Result<Arc<LoadedModel>, ModelFailure> {
    let cache = MODEL_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut cache = cache.lock().unwrap_or_else(|error| error.into_inner());
    cache.retain(|_, weak| weak.strong_count() != 0);
    if let Some(model) = cache.get(path).and_then(Weak::upgrade) {
        if expected_sha256.is_empty() || model.sha256 == expected_sha256 {
            return Ok(model);
        }
    }
    let model = Arc::new(load_model(path, expected_sha256)?);
    cache.insert(path.to_path_buf(), Arc::downgrade(&model));
    Ok(model)
}

fn load_model(path: &Path, expected_sha256: &str) -> Result<LoadedModel, ModelFailure> {
    let parent = path
        .parent()
        .ok_or_else(|| ModelFailure::error("rerank model path has no parent directory"))?;
    msime_path_trust::reject_symlinked_components(parent)
        .map_err(|error| ModelFailure::error(format!("unsafe model path: {error}")))?;
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            ModelFailure::missing(format!("model is missing at {}: {error}", path.display()))
        } else {
            ModelFailure::error(format!("cannot inspect {}: {error}", path.display()))
        }
    })?;
    if metadata.file_type().is_symlink() {
        return Err(ModelFailure::error("model file must not be a symlink"));
    }
    if !metadata.file_type().is_file() {
        return Err(ModelFailure::error("model path is not a regular file"));
    }
    if metadata.len() > MAX_MODEL_BYTES {
        return Err(ModelFailure::oversized(format!(
            "model is {} bytes; maximum is {MAX_MODEL_BYTES}",
            metadata.len()
        )));
    }
    let mut file = fs::File::open(path)
        .map_err(|error| ModelFailure::error(format!("cannot open {}: {error}", path.display())))?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.by_ref()
        .take(MAX_MODEL_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| ModelFailure::error(format!("cannot read {}: {error}", path.display())))?;
    if bytes.len() as u64 > MAX_MODEL_BYTES {
        return Err(ModelFailure::oversized(format!(
            "model grew past {MAX_MODEL_BYTES} bytes while being read"
        )));
    }
    let digest = Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    if !expected_sha256.is_empty() && digest != expected_sha256 {
        return Err(ModelFailure::corrupt(format!(
            "model digest {digest} does not match expected {expected_sha256}"
        )));
    }
    let model = SentenceModel::load(&bytes)
        .map_err(|error| ModelFailure::corrupt(format!("cannot parse model: {error}")))?;
    let license = model.license().to_owned();
    let attribution = model.attribution().to_owned();
    Ok(LoadedModel {
        model: Arc::new(model),
        sha256: digest,
        size: bytes.len() as u64,
        license,
        attribution,
    })
}

fn next_job_token() -> u64 {
    loop {
        let token = NEXT_JOB_TOKEN.fetch_add(1, Ordering::Relaxed) as u64;
        if token != 0 {
            return token;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_bad_oversized_and_symlink_models_are_classified() {
        let root = tempfile::Builder::new()
            .prefix("owl-rerank-model-test-")
            .tempdir_in("/private/tmp")
            .unwrap();
        let missing = load_model(&root.path().join("missing.safetensors"), "");
        assert_eq!(missing.unwrap_err().state, "missing");

        let bad = root.path().join("bad.safetensors");
        fs::write(&bad, b"not a model").unwrap();
        assert_eq!(load_model(&bad, "").unwrap_err().state, "corrupt");

        let oversized = root.path().join("oversized.safetensors");
        let file = fs::File::create(&oversized).unwrap();
        file.set_len(MAX_MODEL_BYTES + 1).unwrap();
        assert_eq!(load_model(&oversized, "").unwrap_err().state, "oversized");

        #[cfg(unix)]
        {
            let link = root.path().join("link.safetensors");
            std::os::unix::fs::symlink(&bad, &link).unwrap();
            assert!(load_model(&link, "").is_err());
        }
    }

    #[test]
    fn the_pinned_model_reports_its_provenance_when_available() {
        let Some(directory) = std::env::var_os("MSIME_NEURAL_MODEL_DIR").map(PathBuf::from) else {
            eprintln!("skipping: MSIME_NEURAL_MODEL_DIR is not set");
            return;
        };
        let path = directory.join("sentence-model.safetensors");
        if !path.is_file() {
            eprintln!("skipping: {} is absent", path.display());
            return;
        }
        let model = load_model(
            &path,
            "86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1",
        )
        .unwrap();
        assert_eq!(model.size, 4_486_280);
        assert_eq!(model.license, "Apache-2.0");
        assert!(model.attribution.contains("LCCC"));
    }
}
