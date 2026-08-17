//
//  FamoElectronHostDetector.swift
//  Famo
//
//  Generic Electron host detection — the "never maintain the list again" seam.
//
//  2026-08-17 真机实锤（Cursor，com.todesktop.230313mzl4w4u92）：候选窗不跟随光标。根因是
//  Electron 判定靠一份手工 bundle ID 名单，Cursor 不在名单里 → delayedCandidatePositioning
//  被判 notNeeded → 同步 caret 查询拿到的陈旧矩形没有第二次修正机会。名单永远追不上新 App，
//  所以这里改为看事实：Electron 应用的包里必然带 `Contents/Frameworks/Electron Framework
//  .framework`（Cursor/VS Code/Slack 等实测均如此）。检测结果作为 host 事实喂给纯策略
//  `FamoClientCapabilityPolicy`（它保持纯函数、可单测；文件系统探测隔离在这里）。
//
//  成本控制：每个 bundleID 只做一次目录列举（NSLock 保护的进程内缓存），命中缓存后是一次
//  字典查找，可以安全地跑在每键 showPanel 热路径上。解析不到运行中的宿主时返回 false 且
//  不缓存——避免把启动竞态期间的未命中钉死成永久答案。
//

import AppKit
import Foundation

final class FamoElectronHostDetector: @unchecked Sendable {
  static let shared = FamoElectronHostDetector()

  private let lock = NSLock()
  private var cache: [String: Bool] = [:]

  /// Resolve the running app for `bundleID` and sniff its bundle for an Electron framework.
  func linksElectron(bundleID: String?) -> Bool {
    guard let bundleID, !bundleID.isEmpty else { return false }
    let key = bundleID.lowercased()
    lock.lock()
    if let cached = cache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    guard let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .first?.bundleURL else {
      return false
    }
    let result = Self.bundleLinksElectron(at: url)
    lock.lock()
    cache[key] = result
    lock.unlock()
    return result
  }

  /// Same sniff for callers that already hold the app's bundle URL (AX 路径拿得到
  /// NSRunningApplication，不必再按 bundleID 反查)。
  func linksElectron(bundleURL: URL?, cacheKey: String?) -> Bool {
    guard let bundleURL else { return false }
    guard let cacheKey, !cacheKey.isEmpty else { return Self.bundleLinksElectron(at: bundleURL) }
    let key = cacheKey.lowercased()
    lock.lock()
    if let cached = cache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let result = Self.bundleLinksElectron(at: bundleURL)
    lock.lock()
    cache[key] = result
    lock.unlock()
    return result
  }

  static func bundleLinksElectron(at bundleURL: URL) -> Bool {
    let frameworksPath = bundleURL
      .appendingPathComponent("Contents/Frameworks", isDirectory: true).path
    let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworksPath)) ?? []
    return frameworkNamesLinkElectron(names)
  }

  /// Pure core, unit-testable without a filesystem: does the framework directory listing
  /// contain an Electron framework? Prefix match — the standard name is
  /// `Electron Framework.framework` and versioned/renamed variants keep the prefix.
  static func frameworkNamesLinkElectron(_ names: [String]) -> Bool {
    names.contains { $0.lowercased().hasPrefix("electron framework") }
  }
}
