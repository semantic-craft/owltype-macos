//
//  OwlDictPack.swift
//  Owltype
//
//  方案B（2026-07-24）：公开发布包只带清洁室 Rime 种子（owl-seed.sh，Unihan + essay），
//  完整词库由 App 首启在用户机器上按 pin 从上游原仓库拉取 → Owltype 不再分发第三方
//  词库数据。本文件是 dict-pack 的模型层：清单条目、装机记录（所有权清单）、状态与偏好。
//  下载/校验/装配在 OwlDictPackFetcher；UI/触发编排在 OwlDictPackCenter。
//

import Foundation

/// 下载校验通过后由 fetcher 套用的既知修正（对齐 owl-seed-full.sh 的必修 bug 列表）。
enum OwlDictPackPatch: String, Codable {
  /// KyleBing `_trad`/`_trad_pinyin` schema 里 active 的短名 `lua_translator@date_translator`
  /// 改为按 `*` 约定自动加载的 `lua_translator@*wubi86_jidian_date_translator`。
  case wubiDateTranslator
}

/// 清单中的一个目标文件。`sha256` 是上游原文件（patch 前）的内容哈希 —— 校验对象是
/// 我们下载到的东西是否就是 pin 处的上游文件；patch 是本地既知变换，装机记录才存 patch 后哈希。
struct OwlDictPackFile: Equatable {
  let repo: String     // e.g. "iDvel/rime-ice"
  let ref: String      // pinned commit sha
  let path: String     // path inside the repo
  let dest: String     // path relative to user_data_dir
  let sha256: String   // upstream content hash (pre-patch)
  let size: Int        // upstream bytes — drives download progress
  let patch: OwlDictPackPatch?

  init(repo: String, ref: String, path: String, dest: String, sha256: String, size: Int, patch: OwlDictPackPatch? = nil) {
    self.repo = repo
    self.ref = ref
    self.path = path
    self.dest = dest
    self.sha256 = sha256
    self.size = size
    self.patch = patch
  }
}

struct OwlDictPackManifest {
  let version: Int
  let files: [OwlDictPackFile]

  var totalBytes: Int { files.reduce(0) { $0 + $1.size } }
}

/// 装机记录 `.owl-dictpack.json`（user_data_dir 根）：dict-pack 自己写过哪些文件、写入时
/// （patch 后）的哈希。升级/重装只覆盖「记录在案且用户没改过」的文件 —— 无记录但文件已存在
/// 视为用户自备（如 2026-07-24 的手工恢复），永不触碰。
struct OwlDictPackRecord: Codable, Equatable {
  var version: Int
  /// dest（相对 user_data_dir）→ 写入时的 sha256（patch 后）。
  var files: [String: String]

  static let fileName = ".owl-dictpack.json"

  static func load(userDir: URL) -> OwlDictPackRecord? {
    let url = userDir.appending(component: fileName, directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(OwlDictPackRecord.self, from: data)
  }

  func save(userDir: URL) throws {
    let url = userDir.appending(component: Self.fileName, directoryHint: .notDirectory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url)
  }
}

/// 设置页状态行 + 编排层用的状态机。
enum OwlDictPackStatus: Equatable {
  case notInstalled
  case downloading(progress: Double)   // 0...1，按累计字节
  case deploying
  case installed(version: Int)
  /// 完整词库已存在但不是 dict-pack 写的（无记录）——用户自备，永不覆盖。
  case userProvided
  case failed(String)
}

enum OwlDictPackPreferences {
  /// 静默自动拉取开关. Key `"OwlDictPackAutoFetch"`, default **`false`**.
  ///
  /// 默认从 true 改为 false（知情同意改版）：完整词库来自第三方开源项目，为避免版权争议不随包
  /// 分发，也不应由法墨替用户静默下载——改为弹窗说明缘由、用户点「同意并下载」后才拉。
  /// 打开此开关＝用户显式授权免提示自动拉取（高级用法，无 UI，`defaults write` 可设）。
  static var autoFetch: Bool {
    get { OwlDefaults.standard.bool(forKey: "OwlDictPackAutoFetch") }
    set { OwlDefaults.standard.set(newValue, forKey: "OwlDictPackAutoFetch") }
  }

  /// 首启知情同意弹窗是否已呈现过. Key `"OwlDictPackPromptShown"`, default `false`.
  /// 对齐 OwlUpdateLogoutPrompt 的 A1 教训：**处置后才记录**——弹窗未被处置就被进程杀掉时
  /// 下次启动重弹（有限重弹 > 永久静默）。引导里的词库步骤是同一条同意线的另一个呈现面，
  /// 用户在那里作出选择同样置真（见 `OwlOnboardingView` 的 dict 步骤）。
  static var promptShown: Bool {
    get { OwlDefaults.standard.bool(forKey: "OwlDictPackPromptShown") }
    set { OwlDefaults.standard.set(newValue, forKey: "OwlDictPackPromptShown") }
  }

  /// 下载镜像前缀. Key `"OwlDictPackMirror"`, default 空。
  /// 形如 `https://mirror.example.com` —— raw 同构主机，其后仍接 `/<repo>/<ref>/<path>`。
  /// 设了则排在下载源链首位（其后仍有 raw 直连 + 内置兜底自动接力，见
  /// `OwlDictPackFetcher.sources()`）；测试用 file:// 前缀 override 走同一条路径。
  static var mirror: String {
    get { OwlDefaults.standard.string(forKey: "OwlDictPackMirror") ?? "" }
    set { OwlDefaults.standard.set(newValue, forKey: "OwlDictPackMirror") }
  }
}
