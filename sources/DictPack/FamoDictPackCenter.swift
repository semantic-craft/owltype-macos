//
//  FamoDictPackCenter.swift
//  Famo
//
//  dict-pack 编排层（MainActor）：状态发布给设置页、启动自动拉取、完成后触发 deploy()。
//  下载在后台 Task 里跑 FamoDictPackFetcher；本类只做状态机与线程切换，不做 IO。
//

import AppKit
import Observation

@Observable
@MainActor
final class FamoDictPackCenter {
  static let shared = FamoDictPackCenter()

  private(set) var status: FamoDictPackStatus = .notInstalled
  private var running = false

  private func makeFetcher() -> FamoDictPackFetcher {
    FamoDictPackFetcher(manifest: .current, userDir: FamoApp.userDir)
  }

  func refresh() {
    guard !running else { return }
    status = makeFetcher().assess()
  }

  /// 启动时机（Main.swift，loadSettings 之后）调用：未装且开关开 → 自动开始；否则只刷新状态。
  func autoFetchIfNeeded() {
    refresh()
    guard FamoDictPackPreferences.autoFetch, makeFetcher().needsFetch() else { return }
    start()
  }

  /// 设置页「立即下载完整词库」按钮 / 自动拉取共用入口。幂等：进行中再点无效。
  func start() {
    guard !running else { return }
    running = true
    status = .downloading(progress: 0)
    let fetcher = makeFetcher()
    Task.detached(priority: .utility) {
      do {
        let result = try await fetcher.run { fraction in
          Task { @MainActor in
            FamoDictPackCenter.shared.noteProgress(fraction)
          }
        }
        await MainActor.run {
          FamoDictPackCenter.shared.finish(result: result)
        }
      } catch {
        await MainActor.run {
          FamoDictPackCenter.shared.fail(error)
        }
      }
    }
  }

  private func noteProgress(_ fraction: Double) {
    guard running else { return }
    status = .downloading(progress: fraction)
  }

  private func finish(result: FamoDictPackInstallResult) {
    if !result.skippedUserFiles.isEmpty {
      print("Famo dict-pack: kept \(result.skippedUserFiles.count) user-provided files untouched.")
    }
    status = .deploying
    // 词库落盘完成 → 全量重部署编译新词库。deploy() 内部 start_maintenance 是异步的，
    // 这里返回即视为已交棒（rebuild 在 librime 维护线程进行）。
    _ = NSApp.famoAppDelegate.deploy()
    running = false
    status = makeFetcher().assess()
  }

  private func fail(_ error: Error) {
    running = false
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    print("Famo dict-pack: fetch failed: \(message)")
    status = .failed(message)
  }
}
