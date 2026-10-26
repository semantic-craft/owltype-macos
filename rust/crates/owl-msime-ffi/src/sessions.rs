//! Non-recycled opaque handles; session ownership stays on the creating thread.
use super::OwlMsimeSession;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};

#[derive(Default)]
struct ThreadSessions(HashMap<usize, OwlMsimeSession>);

thread_local! {
    static SESSIONS: RefCell<ThreadSessions> = RefCell::new(ThreadSessions::default());
}

pub(super) fn live_sessions() -> &'static Mutex<HashSet<usize>> {
    static LIVE: OnceLock<Mutex<HashSet<usize>>> = OnceLock::new();
    LIVE.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Serializes process-wide cache teardown against session creation and destruction.
pub(super) fn session_lifecycle() -> &'static RwLock<()> {
    static LIFECYCLE: OnceLock<RwLock<()>> = OnceLock::new();
    LIFECYCLE.get_or_init(|| RwLock::new(()))
}

impl Drop for ThreadSessions {
    fn drop(&mut self) {
        // A host thread may exit without explicitly destroying its wrappers. Drop
        // its sessions while caches remain open, then retire every live identity.
        if self.0.is_empty() {
            return;
        }
        let _lifecycle = session_lifecycle()
            .write()
            .unwrap_or_else(|p| p.into_inner());
        let mut live = live_sessions().lock().unwrap_or_else(|p| p.into_inner());
        for (id, mut session) in self.0.drain() {
            session.rerank.invalidate(&mut session.runtime);
            drop(session);
            live.remove(&id);
        }
    }
}

pub(super) fn register_session(session: OwlMsimeSession) -> *mut OwlMsimeSession {
    static NEXT: AtomicUsize = AtomicUsize::new(1);
    // Exhaustion fails closed; wrapping would let a stale handle target a new session.
    let Ok(id) = NEXT.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
    else {
        return std::ptr::null_mut();
    };
    SESSIONS.with(|sessions| sessions.borrow_mut().0.insert(id, session));
    live_sessions()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .insert(id);
    // C and Swift treat this as a token; no Rust session pointer crosses the ABI.
    std::ptr::without_provenance_mut(id)
}

pub(super) fn with_session<T>(
    handle: *const OwlMsimeSession,
    operation: impl FnOnce(&mut OwlMsimeSession) -> T,
) -> Option<T> {
    SESSIONS.with(|sessions| {
        // Wrong-thread and reentrant calls fail closed instead of aliasing !Send state.
        let mut sessions = sessions.try_borrow_mut().ok()?;
        sessions.0.get_mut(&(handle as usize)).map(operation)
    })
}

pub(super) fn destroy_session(handle: *mut OwlMsimeSession) {
    let session =
        SESSIONS.with(|sessions| sessions.try_borrow_mut().ok()?.0.remove(&(handle as usize)));
    if let Some(mut session) = session {
        // The caller holds the lifecycle write lock through invalidation/drop/flush.
        session.rerank.invalidate(&mut session.runtime);
        drop(session);
        live_sessions()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&(handle as usize));
    }
}
