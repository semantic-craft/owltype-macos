//! Resource transactions. The native host executes filesystem/transport primitives;
//! this module owns preparation, publication, active-last-good and lease ordering.
use crate::storage::*;
use serde_json::{json, Value};

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}
fn err(code: &str, args: Value) -> String {
    format!("resource:{}", json!({"code":code,"args":args}))
}
fn invalid(message: &str) -> String {
    err("activeStateInvalid", json!([message]))
}
fn effect_<H: Host>(h: &mut H, op: &str, a: Value) -> Result<Value> {
    effect(h, &format!("resource_native_{op}"), a)
}
fn path(root: &str, tail: &str) -> String {
    format!("{}/{tail}", root.trim_end_matches('/'))
}
fn parent(p: &str) -> &str {
    p.rsplit_once('/').map(|v| v.0).unwrap_or("")
}
fn generation(m: &Value) -> String {
    format!(
        "sha256-{}",
        s(m, "digest").strip_prefix("sha256:").unwrap_or("")
    )
}
fn record(m: &Value) -> Value {
    json!({"generationId":generation(m),"digest":m["digest"],"manifest":m})
}
fn canonical(v: &Value) -> Vec<u8> {
    fn clean(v: &Value) -> Value {
        match v {
            Value::Object(o) => Value::Object(
                o.iter()
                    .filter(|(_, v)| !v.is_null())
                    .map(|(k, v)| (k.clone(), clean(v)))
                    .collect(),
            ),
            Value::Array(a) => Value::Array(a.iter().map(clean).collect()),
            _ => v.clone(),
        }
    }
    serde_json::to_vec(&clean(v)).expect("JSON value")
}
struct Store<'a, H> {
    h: &'a mut H,
    config: Value,
    engine: Value,
    compatible: bool,
    source_root: Value,
}
impl<H: Host> Store<'_, H> {
    fn root(&self, k: &str) -> String {
        s(&self.config, k).to_owned()
    }
    fn native(&mut self, op: &str, a: Value) -> Result<Value> {
        effect_(self.h, op, a)
    }
    fn check(&mut self) -> Result<()> {
        self.native("cancel", json!({}))?;
        Ok(())
    }
    fn fault(&mut self, p: &str) -> Result<()> {
        self.native("fault", json!({"point":p}))?;
        Ok(())
    }
    fn exists(&mut self, p: &str) -> Result<bool> {
        Ok(self.native("exists", json!({"path":p}))? == true)
    }
    fn mkdir(&mut self, p: &str) -> Result<()> {
        self.native("mkdir", json!({"path":p}))?;
        Ok(())
    }
    fn sync(&mut self, p: &str) -> Result<()> {
        self.native("sync", json!({"path":p}))?;
        Ok(())
    }
    fn remove(&mut self, p: &str) -> Result<()> {
        self.native("remove", json!({"path":p}))?;
        Ok(())
    }
    fn write(&mut self, p: &str, b: &[u8]) -> Result<()> {
        self.native("write", json!({"path":p,"bytes":b}))?;
        Ok(())
    }
    fn rename(&mut self, from: &str, to: &str) -> Result<()> {
        self.native("rename", json!({"source":from,"destination":to}))?;
        Ok(())
    }
    fn now(&mut self) -> Result<Value> {
        self.native("now", json!({}))
    }
    fn uuid(&mut self) -> Result<String> {
        decode(self.native("uuid", json!({}))?)
    }
    fn safe(&mut self, root: &str, relative: &str) -> Result<String> {
        decode(self.native("safe", json!({"root":root,"relative":relative}))?)
    }
    fn list(&mut self, p: &str) -> Result<Vec<String>> {
        decode(self.native("list", json!({"path":p}))?)
    }
    fn read_json(&mut self, p: &str) -> Result<Value> {
        self.native("read_json", json!({"path":p}))
    }
    fn generation_path(&self, r: &Value) -> String {
        path(
            &self.root("libraryRoot"),
            &format!(
                "{}/generations/{}",
                s(&r["manifest"], "packageId"),
                s(r, "generationId")
            ),
        )
    }
    fn verify(&mut self, p: &str, m: &Value) -> Result<()> {
        crate::resource_contract::verify_generation(std::path::Path::new(p), m, &self.engine, true)
    }

    fn verify_record(&mut self, r: &Value) -> Result<()> {
        if r["digest"] != r["manifest"]["digest"]
            || s(r, "generationId") != generation(&r["manifest"])
        {
            return Err(invalid("generationId 与 manifest digest 不一致"));
        }
        self.verify(&self.generation_path(r), &r["manifest"])
    }
    fn read_active(&mut self, kind: &str) -> Result<Value> {
        let p = path(&self.root("stateRoot"), &format!("active/{kind}.json"));
        if !self.exists(&p)? {
            return Ok(Value::Null);
        }
        let v = self
            .read_json(&p)
            .map_err(|_| invalid("active 元数据无法读取"))?;
        if v["schemaVersion"] != 1 || v["inputKind"] != kind {
            return Err(invalid("schema 或 inputKind 不符"));
        }
        self.native("decode_active", json!({"state":v}))?;
        Ok(v)
    }
    fn journal(
        &mut self,
        id: &str,
        kind: &str,
        phase: &str,
        old: &Value,
        new: &Value,
        message: Value,
    ) -> Result<()> {
        let dir = path(&self.root("stateRoot"), "transactions");
        self.mkdir(&dir)?;
        let v = json!({"schemaVersion":1,"id":id,"inputKind":kind,"phase":phase,"oldGenerationId":old,"newGenerationId":new,"updatedAt":self.now()?,"message":message});
        let temp = path(&dir, &format!(".{id}.{}.tmp", self.uuid()?));
        self.write(&temp, &canonical(&v))?;
        self.rename(&temp, &path(&dir, &format!("{id}.json")))?;
        self.sync(&dir)
    }
    fn write_active(&mut self, v: &Value) -> Result<()> {
        let dir = path(&self.root("stateRoot"), "active");
        self.mkdir(&dir)?;
        let kind = s(v, "inputKind");
        let temp = path(&dir, &format!(".{kind}.{}.tmp", self.uuid()?));
        self.write(&temp, &canonical(v))?;
        let result = (|| {
            self.check()?;
            self.fault("beforeActiveRename")?;
            self.rename(&temp, &path(&dir, &format!("{kind}.json")))
        })();
        if let Err(e) = result {
            let _ = self.remove(&temp);
            return Err(e);
        }
        self.fault("afterActiveRename")?;
        self.sync(&dir)
    }
    fn locked<T>(&mut self, kind: &str, f: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        for p in [
            path(&self.root("stagingRoot"), kind),
            path(&self.root("stateRoot"), "locks"),
            path(&self.root("stateRoot"), "transactions"),
            path(&self.root("stateRoot"), "leases"),
        ] {
            self.mkdir(&p)?;
        }
        let p = path(&self.root("stateRoot"), &format!("locks/{kind}.lock"));
        self.native("lock", json!({"path":p}))?;
        let result = f(self);
        let unlock = self.native("unlock", json!({}));
        match result {
            Err(e) => Err(e),
            Ok(v) => {
                unlock?;
                Ok(v)
            }
        }
    }
    fn version(&self, active: &Value, m: &Value) -> Result<()> {
        let old = &active["current"]["manifest"];
        if old["version"].as_i64() >= m["version"].as_i64() {
            if old["version"] == m["version"] {
                return Err(err(
                    "versionDigestConflict",
                    json!([m["packageId"], m["inputKind"], m["version"]]),
                ));
            }
            return Err(err(
                "invalidManifest",
                json!([format!(
                    "新资源版本 {} 不高于 active {}",
                    m["version"], old["version"]
                )]),
            ));
        }
        Ok(())
    }
    fn prepare(&mut self, m: Value) -> Result<Value> {
        crate::resource_contract::validate(&m)?;
        crate::resource_contract::compatibility(&m, &self.engine)?;
        let kind = s(&m, "inputKind").to_owned();
        self.locked(&kind,|this| {
            this.check()?; let active=this.read_active(&kind)?;
            if !active.is_null() {
                if active["current"]["manifest"]["packageId"]!=m["packageId"] { return Err(err("invalidManifest",json!([format!("同一 inputKind 的 active packageId 为 {}",s(&active["current"]["manifest"],"packageId"))]))); }
                this.verify_record(&active["current"])?;
                if active["current"]["digest"]==m["digest"] { return Ok(json!({"record":active["current"],"previousGenerationId":active["previous"]["generationId"]})); }
                this.version(&active,&m)?;
            }
            let dir=path(&this.root("libraryRoot"),&format!("{}/generations",s(&m,"packageId")));
            if this.exists(&dir)? {
                for child in this.list(&dir)? {
                    let existing=this.read_json(&path(&child,"manifest.json")).map_err(|_|err("generationCorrupt",json!(["无法读取 generation manifest.json"])))?;
                    if existing["inputKind"]==m["inputKind"] && existing["version"]==m["version"] && existing["packageId"]==m["packageId"] && existing["digest"]!=m["digest"] { return Err(err("versionDigestConflict",json!([m["packageId"],m["inputKind"],m["version"]]))); }
                }
            }
            let r=record(&m); let old=this.read_active(&kind)?["current"]["generationId"].clone(); let id=this.uuid()?;
            this.journal(&id,&kind,"prepared",&old,&r["generationId"],Value::Null)?;
            let result=(|| { this.check()?; this.stage(&m)?; this.check()?; this.journal(&id,&kind,"generationPublished",&old,&r["generationId"],Value::Null)?; Ok(json!({"record":r,"previousGenerationId":old})) })();
            if let Err(ref e)=result { let _=this.journal(&id,&kind,"failed",&old,&r["generationId"],json!(e)); } result
        })
    }
    fn stage(&mut self, m: &Value) -> Result<()> {
        self.check()?;
        let staging = self.safe(
            &self.root("stagingRoot"),
            &format!("{}/{}", s(m, "packageId"), generation(m)),
        )?;
        if self.exists(&staging)? {
            if self.native("kind", json!({"path":staging}))? != "directory" {
                return Err(err("generationCorrupt", json!(["staging 路径不是目录"])));
            }
            self.native("writable_tree", json!({"path":staging}))?;
        } else {
            self.mkdir(parent(&staging))?;
            self.native("unique_directory", json!({"path":staging}))?;
        }
        let mut files = m["files"].as_array().cloned().ok_or("invalid_payload")?;
        files.sort_by(|a, b| s(a, "path").cmp(s(b, "path")));
        let total = files
            .iter()
            .map(|f| f["size"].as_u64().unwrap_or(0))
            .sum::<u64>()
            .max(1);
        let mut completed = 0u64;
        self.native("progress", json!({"fraction":0}))?;
        for file in files {
            self.check()?;
            let destination = self.safe(&staging, s(&file, "path"))?;
            let valid = self.exists(&destination)?
                && crate::resource_contract::verify_file(std::path::Path::new(&destination), &file)
                    .is_ok();
            if !valid {
                self.mkdir(parent(&destination))?;
                let partial = format!("{destination}.part");
                if self.exists(&partial)? {
                    self.remove(&partial)?;
                }
                self.native(
                    "copy_source",
                    json!({"file":file,"destination":partial,"sourceRoot":self.source_root}),
                )?;
                self.check()?;
                self.fault("afterPayloadWrite")?;
                crate::resource_contract::verify_file(std::path::Path::new(&partial), &file)?;
                self.sync(&partial)?;
                self.fault("afterPayloadSync")?;
                self.rename(&partial, &destination)?;
                self.sync(parent(&destination))?;
            }
            completed += file["size"].as_u64().unwrap_or(0);
            self.native(
                "progress",
                json!({"fraction":(completed as f64 / total as f64).min(1.0)}),
            )?;
        }
        self.check()?;
        self.write(&path(&staging, "manifest.json"), &canonical(m))?;
        self.fault("afterManifestSync")?;
        self.write(
            &path(&staging, ".complete"),
            format!("{}\n", s(m, "digest")).as_bytes(),
        )?;
        self.read_only_files(&staging, m)?;
        self.native("sync_tree", json!({"path":staging}))?;
        self.fault("afterStagingDirectorySync")?;
        self.verify(&staging, m)?;
        self.check()?;
        let final_path = self.generation_path(&record(m));
        if self.exists(&final_path)? {
            self.verify(&final_path, m)?;
            self.read_only_files(&final_path, m)?;
            self.native("readonly_directories", json!({"path":final_path}))?;
            self.native("sync_tree", json!({"path":final_path}))?;
            self.native("writable_tree", json!({"path":staging}))?;
            let _ = self.remove(&staging);
        } else {
            self.mkdir(parent(&final_path))?;
            self.rename(&staging, &final_path)?;
            self.sync(parent(&final_path))?;
            self.native("readonly_directories", json!({"path":final_path}))?;
            self.native("sync_tree", json!({"path":final_path}))?;
        }
        self.fault("afterGenerationPublish")
    }
    fn read_only_files(&mut self, p: &str, m: &Value) -> Result<()> {
        for f in m["files"].as_array().ok_or("invalid_payload")? {
            self.native("chmod", json!({"path":path(p,s(f,"path")),"mode":292}))?;
        }
        for name in ["manifest.json", ".complete"] {
            self.native("chmod", json!({"path":path(p,name),"mode":292}))?;
        }
        Ok(())
    }
    fn activate(&mut self, prepared: Value) -> Result<Value> {
        let r = &prepared["record"];
        let m = &r["manifest"];
        let kind = s(m, "inputKind").to_owned();
        self.locked(&kind, |this| {
            this.check()?;
            if this.compatible {
                crate::resource_catalog::validate_compatible(
                    std::path::Path::new(&this.generation_path(r)),
                    &r["manifest"],
                    true,
                )?;
            }
            this.verify_record(r)?;
            let active = this.read_active(&kind)?;
            if !active.is_null() && active["current"]["digest"] == r["digest"] {
                return Ok(json!({"disposition":"alreadyActive","state":active}));
            }
            if active["current"]["generationId"] != prepared["previousGenerationId"] {
                return Err(invalid("active generation changed after preparation"));
            }
            if !active.is_null() {
                this.version(&active, m)?;
            }
            let state = this.commit(&kind, &active, r, "generationPublished", "activation")?;
            Ok(json!({"disposition":"installed","state":state}))
        })
    }
    fn commit(
        &mut self,
        kind: &str,
        active: &Value,
        r: &Value,
        phase: &str,
        message: &str,
    ) -> Result<Value> {
        let id = self.uuid()?;
        let old = &active["current"]["generationId"];
        self.journal(&id, kind, phase, old, &r["generationId"], json!(message))?;
        let next = json!({"schemaVersion":1,"inputKind":kind,"current":r,"previous":active["current"],"activatedAt":self.now()?});
        let result = (|| {
            self.check()?;
            self.write_active(&next)?;
            self.journal(
                &id,
                kind,
                "activeWritten",
                old,
                &r["generationId"],
                json!(message),
            )?;
            Ok(next)
        })();
        if let Err(ref e) = result {
            let _ = self.journal(&id, kind, "failed", old, &r["generationId"], json!(e));
        }
        result
    }
    fn rollback(&mut self, kind: &str) -> Result<Value> {
        self.locked(kind, |this| {
            let active = this.read_active(kind)?;
            if active.is_null() {
                return Err(err("activeStateMissing", json!([kind])));
            }
            if active["previous"].is_null() {
                return Err(err("rollbackUnavailable", json!([kind])));
            }
            if this.compatible {
                crate::resource_catalog::validate_compatible(
                    std::path::Path::new(&this.generation_path(&active["previous"])),
                    &active["previous"]["manifest"],
                    true,
                )?;
            }
            this.verify_record(&active["previous"])?;
            this.commit(kind, &active, &active["previous"], "prepared", "rollback")
        })
    }
    fn lease_path(&self, id: &str) -> String {
        path(&self.root("stateRoot"), &format!("leases/{id}.json"))
    }
    fn lease_runtime(&mut self, l: &Value) -> Result<String> {
        let id = s(l, "generationId");
        if id.len() != 71
            || !id.starts_with("sha256-")
            || !id.as_bytes()[7..]
                .iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        {
            return Err(err(
                "generationCorrupt",
                json!([format!("lease generationId 无效：{id}")]),
            ));
        }
        self.safe(
            &self.root("runtimeRoot"),
            &format!("{}/{}/{}", s(l, "inputKind"), id, s(l, "id")),
        )
    }
    fn remove_lease(&mut self, l: &Value) -> Result<()> {
        let runtime = self.lease_runtime(l)?;
        if self.exists(&runtime)? {
            self.remove(&runtime)?;
            self.sync(parent(&runtime))?;
        }
        let metadata = self.lease_path(s(l, "id"));
        if self.exists(&metadata)? {
            self.remove(&metadata)?;
            self.sync(parent(&metadata))?;
        }
        Ok(())
    }
    fn recover(&mut self, kind: &str) -> Result<Value> {
        self.locked(kind, |this| {
            let active = this.read_active(kind)?;
            if active.is_null() {
                return Err(err("activeStateMissing", json!([kind])));
            }
            this.verify_record(&active["current"])?;
            let dir = path(&this.root("stateRoot"), "leases");
            if this.exists(&dir)? {
                let mut files = this.list(&dir)?;
                files.sort();
                for p in files.into_iter().filter(|p| p.ends_with(".json")) {
                    if let Ok(v) = this.native("read_lease", json!({"path":p})) {
                        if v["lease"]["inputKind"] == kind
                            && this.native("process_dead", json!({"process":v["process"]}))? == true
                        {
                            this.remove_lease(&v["lease"])?;
                        }
                    }
                }
            }
            Ok(active)
        })
    }
    fn acquire(&mut self, kind: &str) -> Result<Value> {
        self.locked(kind,|this| {
            let active=this.read_active(kind)?; if active.is_null() { return Err(err("activeStateMissing",json!([kind]))); } this.verify_record(&active["current"])?;
            let id=this.uuid()?; let r=&active["current"];
            let runtime=this.safe(&this.root("runtimeRoot"),&format!("{}/{}/{id}",kind,s(r,"generationId")))?;
            let lease=json!({"id":id,"inputKind":kind,"generationId":r["generationId"],"runtimeURL":this.native("file_url",json!({"path":runtime}))?,"acquiredAt":this.now()?});
            let result=(|| {
                this.check()?; let process=this.native("process",json!({}))?; this.mkdir(parent(&runtime))?; this.native("unique_directory",json!({"path":runtime}))?;
                let mut files=r["manifest"]["files"].as_array().cloned().ok_or("invalid_payload")?; files.sort_by(|a,b|s(a,"path").cmp(s(b,"path")));
                for file in files { this.check()?;
                    let source:String=decode(this.native("safe_file",json!({"root":this.generation_path(r),"relative":file["path"]}))?)?;
                    let dest=this.safe(&runtime,s(&file,"path"))?;
                    this.native("copy_synced",json!({"source":source,"destination":dest}))?;
                }
                this.write(&path(&runtime,".owl-runtime-complete"),format!("{}\n",s(r,"digest")).as_bytes())?; this.native("sync_tree",json!({"path":runtime}))?; this.check()?;
                this.write(&this.lease_path(&id),&canonical(&json!({"lease":lease,"process":process})))?; Ok(lease)
            })();
            if result.is_err() { let _=this.remove(&runtime); } result
        })
    }
    fn release(&mut self, l: Value) -> Result<Value> {
        let kind = s(&l, "inputKind").to_owned();
        self.locked(&kind, |this| {
            let p = this.lease_path(s(&l, "id"));
            if !this.exists(&p)? {
                return Ok(json!(true));
            }
            let record = this
                .native("read_lease", json!({"path":p}))
                .map_err(|_| invalid("lease 元数据无法读取"))?;
            let actual = &record["lease"];
            if actual["id"] != l["id"]
                || actual["inputKind"] != l["inputKind"]
                || actual["generationId"] != l["generationId"]
            {
                return Err(err("leaseNotFound", json!([l["id"]])));
            }
            this.remove_lease(actual)?;
            Ok(json!(true))
        })
    }
}
pub fn dispatch<H: Host>(host: &mut H, operation: &str, args: Value) -> Result<Value> {
    if operation.starts_with("resource_contract_") {
        return crate::resource_contract::dispatch(operation, args);
    }
    let mut store = Store {
        h: host,
        config: args["configuration"].clone(),
        engine: args["engine"].clone(),
        compatible: args["compatible"] == true,
        source_root: Value::Null,
    };
    match operation {
        "resource_prepare_bundled" => {
            store.check()?;
            let built = crate::resource_catalog::build(
                std::path::Path::new(s(&args, "sharedSupport")),
                std::path::Path::new(s(&args, "root")),
                crate::resource_catalog::catalog()["packageVersion"]
                    .as_i64()
                    .unwrap(),
            )?;
            store.source_root = args["root"].clone();
            let resource = store.prepare(built["manifest"].clone())?;
            Ok(json!({"resource":resource,"stats":built["stats"]}))
        }
        "resource_install" => {
            let prepared = store.prepare(args["manifest"].clone())?;
            store.activate(prepared)
        }
        "resource_prepare" => store.prepare(args["manifest"].clone()),
        "resource_activate" => store.activate(args["prepared"].clone()),
        "resource_rollback" => store.rollback(s(&args, "inputKind")),
        "resource_recover" => store.recover(s(&args, "inputKind")),
        "resource_acquire" => store.acquire(s(&args, "inputKind")),
        "resource_release" => store.release(args["lease"].clone()),
        _ => Err("invalid_operation".into()),
    }
}
