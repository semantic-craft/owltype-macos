//
//  FamoLaneTasks.swift
//  Famo — per-lane AI task supervisor (B8)
//
//  Stops superseded AI menu requests from running to completion and wasting network /
//  DeepSeek tokens. Each AI menu action used to spawn a bare `Task { @MainActor in … }` with
//  no handle and no cancellation, so triggering one AI action then another left BOTH in-flight
//  requests running to the end (staleness was caught only at WRITE time via
//  `FamoSnapshotRegistry.isCurrent`, which drops the result but not the in-flight work).
//
//  This tiny supervisor holds one `Task` per lane. A new `run` on a lane cancels the prior
//  same-lane task before storing the new one; `cancelAll()` cancels every lane on teardown.
//
//  Threading: held on `FamoInputController` (one supervisor per input session) and otherwise
//  accessed only from the main thread, like the rest of the controller. The single exception is
//  `cancelAll()`, which `deinit` (nonisolated) calls — it only invokes `Task.cancel()` (thread
//  safe) and reads the map, so it carries no main-actor requirement.
//

import Foundation

final class FamoLaneTasks {
  enum Lane: Hashable {
    case cloud
    case polish
  }

  /// One in-flight task per lane. A finished task is held (harmless) until the next `run` on the
  /// same lane overwrites it or a `cancel`/`cancelAll` clears it — no self-clear-on-completion, so
  /// there is no generation counter to keep in sync.
  private var tasks: [Lane: Task<Void, Never>] = [:]

  /// Run `operation` on `lane`, cancelling the lane's prior in-flight task first (a no-op if it
  /// already finished). The new task is stored so a later `run`/`cancel` can supersede it.
  func run(_ lane: Lane, _ operation: @escaping @MainActor () async -> Void) {
    tasks[lane]?.cancel()
    tasks[lane] = Task { @MainActor in
      await operation()
    }
  }

  /// Cancel the stored task for `lane` (no-op if none / already finished).
  func cancel(_ lane: Lane) {
    tasks[lane]?.cancel()
  }

  /// Cancel every stored task. Safe to call from `deinit` (only `Task.cancel()`, which is thread
  /// safe; no main-actor requirement).
  func cancelAll() {
    for task in tasks.values {
      task.cancel()
    }
  }
}

/// Shared predicate for "this error is a cancellation" so the cloud service and the
/// selection-polish handler both swallow a superseded request the SAME way (B8). A cancelled
/// request must be SILENT: the `isCurrent` staleness gate does NOT suppress it (a newer same-lane
/// action can supersede on a still-current snapshot), so without this a cancelled fetch would
/// surface a spurious error toast.
enum FamoLaneCancellation {
  static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if (error as? URLError)?.code == .cancelled { return true }
    if Task.isCancelled { return true }
    return false
  }
}
