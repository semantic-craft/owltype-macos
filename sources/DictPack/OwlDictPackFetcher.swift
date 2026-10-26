//
//  OwlDictPackFetcher.swift
//  Owltype
//
//  dict-pack 的下载/校验/装配引擎（方案B）。逐文件流式下载 pin 处的上游原文件（边下边写
//  staging 边算 sha256，字节级进度）、套用既知 patch、全部就绪后原子落盘 user_data_dir、
//  写 `.owl-dictpack.json` 装机记录。staging 跨次复用 —— 半途被打断（含注销杀进程）后
//  重跑只补缺，不重下 90 MB。下载源是有序链（用户镜像 → raw 直连 → 内置兜底），单文件
//  失败自动换源。纯值语义 + 注入依赖（baseURL/userDir），不触碰 UI 与 librime —— 部署
//  触发在 Center。
//

import CryptoKit
import Foundation

enum OwlDictPackError: Error, LocalizedError, Equatable {
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
struct OwlDictPackInstallResult: Equatable {
  var installed: [String]
  var skippedUserFiles: [String]
}

/// 一个下载源：把清单条目 (repo, ref, path) 解析成完整 URL。
/// `rawPrefix` 形状为 `<prefix>/<repo>/<ref>/<path>`（raw.githubusercontent 及其同构的
/// 镜像/加速代理）；`jsDelivr` 用 gh CDN 形状 `…/gh/<repo>@<ref>/<path>`（单文件 20 MB
/// 上限，超限的 .gram 由链上其它源承担 —— 换源是按文件粒度的）。
enum OwlDictPackSource: Equatable {
  case rawPrefix(String)
  case jsDelivr

  func url(for file: OwlDictPackFile) -> URL? {
    switch self {
    case .rawPrefix(let prefix):
      return URL(string: "\(prefix)/\(file.repo)/\(file.ref)/\(file.path)")
    case .jsDelivr:
      return URL(string: "https://cdn.jsdelivr.net/gh/\(file.repo)@\(file.ref)/\(file.path)")
    }
  }
}

struct OwlDictPackFetcher {
  let manifest: OwlDictPackManifest
  let userDir: URL
  /// 覆盖下载源前缀；nil 时按 OwlDictPackPreferences.mirror / raw.githubusercontent 解析。
  /// 测试注入 `file:///fixture/root`（其后同样拼 `/<repo>/<ref>/<path>`）。
  let baseURLOverride: String?
  /// 覆盖整条下载源链（测试换源逻辑用）；比 baseURLOverride 优先。
  let sourceChainOverride: [OwlDictPackSource]?

  init(
    manifest: OwlDictPackManifest, userDir: URL, baseURLOverride: String? = nil,
    sourceChainOverride: [OwlDictPackSource]? = nil
  ) {
    self.manifest = manifest
    self.userDir = userDir
    self.baseURLOverride = baseURLOverride
    self.sourceChainOverride = sourceChainOverride
  }

  // MARK: - 状态评估

  /// 装机状态：有记录按版本判断；无记录但存在关键词库文件 = 用户自备（永不覆盖）。
  func assess() -> OwlDictPackStatus {
    let fm = FileManager.default
    if let record = OwlDictPackRecord.load(userDir: userDir) {
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
    case .userProvided, .downloading, .deploying, .prepared,
         .activating, .rollingBack, .failed:
      return false
    }
  }

  // MARK: - 执行

  /// 全量执行。progress 以累计字节比例回调（0...1，流式字节级 —— 40 MB 的 .gram 下载
  /// 期间进度也在走）。顺序：全部文件先下载+校验+patch 到 staging，全部就绪后才逐个落盘
  /// —— 半程网络失败不会留下混合状态的 user_data_dir。
  ///
  /// 断点续传：staging 不再开场清空 —— 上一次被打断（含注销杀进程）留下的无 patch 文件
  /// 经 sha256 复验后直接复用，只有装配成功才整体清掉 staging。
  func run(progress: @escaping @Sendable (Double) -> Void) async throws -> OwlDictPackInstallResult {
    let fm = FileManager.default
    let staging = userDir.appending(component: ".owl-dictpack-staging", directoryHint: .isDirectory)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)

    let record = OwlDictPackRecord.load(userDir: userDir)
    let total = Double(max(manifest.totalBytes, 1))
    var done = 0

    // ── 阶段1：下载 + 校验 + patch → staging ──────────────────────────────
    let chain = sources()
    var preferredSource = 0  // 上一个成功源的下标 —— 主源不可达时不必 48 个文件各超时一遍
    var stagedHashes: [String: String] = [:]  // dest → post-patch sha256
    for file in manifest.files {
      let stagedURL = staging.appending(path: file.dest, directoryHint: .notDirectory)
      if file.patch == nil, Self.stagedFileValid(at: stagedURL, sha256: file.sha256) {
        stagedHashes[file.dest] = file.sha256
        done += file.size
        progress(min(Double(done) / total, 1))
        continue
      }
      try fm.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let doneSoFar = done
      preferredSource = try await downloadVerified(
        file, to: stagedURL, chain: chain, startAt: preferredSource,
        onBytes: { received in progress(min((Double(doneSoFar) + Double(received)) / total, 1)) })
      if file.patch != nil {
        let patched = try applyPatch(file, data: Data(contentsOf: stagedURL))
        try patched.write(to: stagedURL)
        stagedHashes[file.dest] = Self.sha256Hex(patched)
      } else {
        stagedHashes[file.dest] = file.sha256
      }
      done += file.size
      progress(min(Double(done) / total, 1))
    }

    // ── 阶段2：落盘（保护用户自备/用户改过的文件）──────────────────────────
    var result = OwlDictPackInstallResult(installed: [], skippedUserFiles: [])
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

    try OwlDictPackRecord(version: manifest.version, files: newRecordFiles).save(userDir: userDir)
    try? fm.removeItem(at: staging)  // 成功才清；失败留给下次续传
    return result
  }

  // MARK: - 内部件

  /// 下载源顺序链：测试 override 独占；否则 用户镜像（若设）→ raw 直连 → 内置兜底。
  /// 所有源受同一 sha256 pin 约束 —— 恶意/过期镜像给错内容只会校验失败换下一源，
  /// 绝不会装进用户目录，所以加第三方兜底不扩大信任面。
  func sources() -> [OwlDictPackSource] {
    if let sourceChainOverride { return sourceChainOverride }
    if let override = baseURLOverride, !override.isEmpty { return [.rawPrefix(override)] }
    var chain: [OwlDictPackSource] = []
    let mirror = OwlDictPackPreferences.mirror
    if !mirror.isEmpty { chain.append(.rawPrefix(mirror)) }
    chain.append(.rawPrefix("https://raw.githubusercontent.com"))
    chain.append(.rawPrefix("https://gh-proxy.com/https://raw.githubusercontent.com"))
    chain.append(.jsDelivr)
    return chain
  }

  /// staging 里的既有文件是否可复用（断点续传判据）：内容 sha256 与清单一致。
  static func stagedFileValid(at url: URL, sha256: String) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
    return sha256Hex(data) == sha256
  }

  /// 从 `startAt` 起沿链逐源尝试，直到某源流式下载且校验通过；返回成功源下标。
  /// 全链失败抛最后一个错误（badURL 的源直接跳过）。
  private func downloadVerified(
    _ file: OwlDictPackFile, to stagedURL: URL, chain: [OwlDictPackSource], startAt: Int,
    onBytes: (Int) -> Void
  ) async throws -> Int {
    var lastError = OwlDictPackError.downloadFailed(dest: file.dest, underlying: "无可用下载源")
    for offset in 0..<chain.count {
      let index = (startAt + offset) % chain.count
      do {
        try await streamDownload(file, from: chain[index], to: stagedURL, onBytes: onBytes)
        return index
      } catch let error as OwlDictPackError {
        lastError = error
        onBytes(0)  // 换源重下，本文件进度回落到起点
      }
    }
    throw lastError
  }

  /// 单源流式下载：边收边写 stagedURL 边算 sha256（大文件不整块驻留内存），按块回调
  /// 已收字节数，收尾校验哈希 —— 不符即抛（由 downloadVerified 换源）。
  private func streamDownload(
    _ file: OwlDictPackFile, from source: OwlDictPackSource, to stagedURL: URL,
    onBytes: (Int) -> Void
  ) async throws {
    guard let url = source.url(for: file) else {
      throw OwlDictPackError.badURL("\(source) + \(file.path)")
    }
    do {
      let (bytes, response) = try await URLSession.shared.bytes(from: url)
      if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw OwlDictPackError.downloadFailed(dest: file.dest, underlying: "HTTP \(http.statusCode)")
      }
      FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
      let handle = try FileHandle(forWritingTo: stagedURL)
      defer { try? handle.close() }
      var hasher = SHA256()
      var received = 0
      var buffer = Data()
      buffer.reserveCapacity(Self.streamChunkSize)
      for try await byte in bytes {
        buffer.append(byte)
        if buffer.count >= Self.streamChunkSize {
          hasher.update(data: buffer)
          try handle.write(contentsOf: buffer)
          received += buffer.count
          onBytes(received)
          buffer.removeAll(keepingCapacity: true)
        }
      }
      if !buffer.isEmpty {
        hasher.update(data: buffer)
        try handle.write(contentsOf: buffer)
        received += buffer.count
        onBytes(received)
      }
      let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      guard actual == file.sha256 else {
        throw OwlDictPackError.hashMismatch(dest: file.dest, expected: file.sha256, actual: actual)
      }
    } catch let error as OwlDictPackError {
      throw error
    } catch {
      throw OwlDictPackError.downloadFailed(dest: file.dest, underlying: error.localizedDescription)
    }
  }

  private static let streamChunkSize = 256 * 1024

  private func applyPatch(_ file: OwlDictPackFile, data: Data) throws -> Data {
    guard let patch = file.patch else { return data }
    switch patch {
    case .wubiDateTranslator:
      // 对齐 owl-seed-full.sh：只改行首缩进后的 active 行，不碰注释里已带 `*` 的行。
      // 不锚行尾（上游该行带尾随注释「# 自定义系统变量输出」，owl-seed-full 的 sed 同样不锚），
      // 只替换匹配段，行尾注释原样保留。
      guard let text = String(data: data, encoding: .utf8) else {
        throw OwlDictPackError.patchDidNothing(dest: file.dest)
      }
      let pattern = #"(?m)^(\s*)- lua_translator@date_translator\b"#
      let patched = text.replacingOccurrences(
        of: pattern,
        with: "$1- lua_translator@*wubi86_jidian_date_translator",
        options: .regularExpression
      )
      guard patched != text else { throw OwlDictPackError.patchDidNothing(dest: file.dest) }
      return Data(patched.utf8)
    }
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
