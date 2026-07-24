//
//  FamoDictPackFetcher.swift
//  Famo
//
//  dict-pack 的下载/校验/装配引擎（方案B）。逐文件下载 pin 处的上游原文件、sha256 校验、
//  套用既知 patch、经 staging 原子落盘 user_data_dir、写 `.famo-dictpack.json` 装机记录。
//  纯值语义 + 注入依赖（baseURL/userDir），不触碰 UI 与 librime —— 部署触发在 Center。
//

import CryptoKit
import Foundation

enum FamoDictPackError: Error, LocalizedError, Equatable {
  case badURL(String)
  case downloadFailed(dest: String, underlying: String)
  case hashMismatch(dest: String, expected: String, actual: String)
  case patchDidNothing(dest: String)

  var errorDescription: String? {
    switch self {
    case .badURL(let url): return "无效下载地址：\(url)"
    case .downloadFailed(let dest, let underlying): return "下载失败 \(dest)：\(underlying)"
    case .hashMismatch(let dest, _, _): return "校验不符：\(dest)（上游文件与 pin 不一致）"
    case .patchDidNothing(let dest): return "修正未命中：\(dest)（上游内容已变，需重新生成 manifest）"
    }
  }
}

/// 一次装配的结果：真正写入的文件 + 因用户自备而跳过的文件。
struct FamoDictPackInstallResult: Equatable {
  var installed: [String]
  var skippedUserFiles: [String]
}

struct FamoDictPackFetcher {
  let manifest: FamoDictPackManifest
  let userDir: URL
  /// 覆盖下载源前缀；nil 时按 FamoDictPackPreferences.mirror / raw.githubusercontent 解析。
  /// 测试注入 `file:///fixture/root`（其后同样拼 `/<repo>/<ref>/<path>`）。
  let baseURLOverride: String?

  init(manifest: FamoDictPackManifest, userDir: URL, baseURLOverride: String? = nil) {
    self.manifest = manifest
    self.userDir = userDir
    self.baseURLOverride = baseURLOverride
  }

  // MARK: - 状态评估

  /// 装机状态：有记录按版本判断；无记录但存在关键词库文件 = 用户自备（永不覆盖）。
  func assess() -> FamoDictPackStatus {
    let fm = FileManager.default
    if let record = FamoDictPackRecord.load(userDir: userDir) {
      return .installed(version: record.version)
    }
    // 关键文件探针：任一存在即视为用户自己放置过完整词库。
    for probe in ["cn_dicts/base.dict.yaml", "rime_ice.dict.yaml"] {
      if fm.fileExists(atPath: userDir.appending(component: probe, directoryHint: .notDirectory).path) {
        return .userProvided
      }
    }
    return .notInstalled
  }

  /// 是否需要（可以）自动拉取：未装才拉；用户自备/已装当前版本都不动。
  /// 已装旧版本（record.version < manifest.version）也重拉 —— 只覆盖未被用户改过的记录内文件。
  func needsFetch() -> Bool {
    switch assess() {
    case .notInstalled: return true
    case .installed(let version): return version < manifest.version
    case .userProvided, .downloading, .deploying, .failed: return false
    }
  }

  // MARK: - 执行

  /// 全量执行。progress 以累计字节比例回调（0...1）。
  /// 顺序：全部文件先下载+校验+patch 到 staging，全部就绪后才逐个落盘 —— 半程网络失败
  /// 不会留下混合状态的 user_data_dir。
  func run(progress: @escaping @Sendable (Double) -> Void) async throws -> FamoDictPackInstallResult {
    let fm = FileManager.default
    let staging = userDir.appending(component: ".famo-dictpack-staging", directoryHint: .isDirectory)
    try? fm.removeItem(at: staging)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }

    let record = FamoDictPackRecord.load(userDir: userDir)
    let total = Double(max(manifest.totalBytes, 1))
    var done = 0.0

    // ── 阶段1：下载 + 校验 + patch → staging ──────────────────────────────
    var stagedHashes: [String: String] = [:]  // dest → post-patch sha256
    for file in manifest.files {
      let data = try await download(file)
      let actual = Self.sha256Hex(data)
      guard actual == file.sha256 else {
        throw FamoDictPackError.hashMismatch(dest: file.dest, expected: file.sha256, actual: actual)
      }
      let patched = try applyPatch(file, data: data)
      let stagedURL = staging.appending(path: file.dest, directoryHint: .notDirectory)
      try fm.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try patched.write(to: stagedURL)
      stagedHashes[file.dest] = Self.sha256Hex(patched)
      done += Double(file.size)
      progress(min(done / total, 1))
    }

    // ── 阶段2：落盘（保护用户自备/用户改过的文件）──────────────────────────
    var result = FamoDictPackInstallResult(installed: [], skippedUserFiles: [])
    var newRecordFiles = record?.files ?? [:]
    for file in manifest.files {
      let dst = userDir.appending(path: file.dest, directoryHint: .notDirectory)
      if fm.fileExists(atPath: dst.path) {
        let ownedHash = record?.files[file.dest]
        let diskHash = (try? Data(contentsOf: dst)).map(Self.sha256Hex)
        if ownedHash == nil || ownedHash != diskHash {
          // 不是我们写的，或写后被用户改过 —— 一律不碰。
          result.skippedUserFiles.append(file.dest)
          continue
        }
        try fm.removeItem(at: dst)
      }
      try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.moveItem(at: staging.appending(path: file.dest, directoryHint: .notDirectory), to: dst)
      newRecordFiles[file.dest] = stagedHashes[file.dest]
      result.installed.append(file.dest)
    }

    try FamoDictPackRecord(version: manifest.version, files: newRecordFiles).save(userDir: userDir)
    return result
  }

  // MARK: - 内部件

  private func baseURL() -> String {
    if let override = baseURLOverride, !override.isEmpty { return override }
    let mirror = FamoDictPackPreferences.mirror
    return mirror.isEmpty ? "https://raw.githubusercontent.com" : mirror
  }

  private func download(_ file: FamoDictPackFile) async throws -> Data {
    let urlString = "\(baseURL())/\(file.repo)/\(file.ref)/\(file.path)"
    guard let url = URL(string: urlString) else { throw FamoDictPackError.badURL(urlString) }
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw FamoDictPackError.downloadFailed(dest: file.dest, underlying: "HTTP \(http.statusCode)")
      }
      return data
    } catch let error as FamoDictPackError {
      throw error
    } catch {
      throw FamoDictPackError.downloadFailed(dest: file.dest, underlying: error.localizedDescription)
    }
  }

  private func applyPatch(_ file: FamoDictPackFile, data: Data) throws -> Data {
    guard let patch = file.patch else { return data }
    switch patch {
    case .wubiDateTranslator:
      // 对齐 famo-seed-full.sh：只改行首缩进后的 active 行，不碰注释里已带 `*` 的行。
      guard let text = String(data: data, encoding: .utf8) else {
        throw FamoDictPackError.patchDidNothing(dest: file.dest)
      }
      let pattern = #"(?m)^(\s*)- lua_translator@date_translator$"#
      let patched = text.replacingOccurrences(
        of: pattern,
        with: "$1- lua_translator@*wubi86_jidian_date_translator",
        options: .regularExpression
      )
      guard patched != text else { throw FamoDictPackError.patchDidNothing(dest: file.dest) }
      return Data(patched.utf8)
    }
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
