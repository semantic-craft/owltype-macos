//
//  OwlLegacyDataMigration.swift
//  Owltype
//
//  改名工程 P4（docs/rename-owltype-plan.md §5）：新 app 首次启动时，把旧「法墨」的用户数据
//  一次性接过来。
//
//  这是全仓**唯一**允许写出旧品牌标识字面量的产品代码 —— 迁移逻辑必须叫得出旧目录名、旧偏好
//  域名和旧派生文件名，否则无从寻址。`scripts/check-identity-residual.sh` 因此把本文件和它的
//  单测一并排除在残留扫描之外（同 scan 脚本自身的豁免理由）。除本文件外，产品代码里再出现
//  这些字面量都是残留，不是迁移。
//
//  三条硬约束：
//    1. **旧目录一个字节都不动。** 只读、只复制，绝不 move / 删除 / 改属性。旧目录的清理是
//       P5 装机票的事，且要用户确认。
//    2. **先复制后改名。** `owl_quick_send.json` / `owl_prompts.json` 是用户手打的快捷短语与
//       提示词库，丢了无法再生；任何「就地改名」写法一旦中途失败就是半个库，不接受。
//    3. **要么全成、要么什么都没发生。** 复制 + 改名 + yaml 标识改写全在同卷的 staging 目录里
//       完成，最后一步才 `moveItem`（同目录 rename(2)，原子）把它挂成正式目录。任何一步失败
//       都删掉 staging 原样退出：正式目录从未存在过，下次启动重跑一遍即可 —— 「半迁移」这个
//       状态在磁盘上没有对应形态，所以中断重入天然安全。
//
//  为什么改名映射比方案 §5 列的三条长：§5 点名了 `famo.custom.yaml` 和两个 `*.userdb`，但
//  快捷短语 / 提示词的 source of truth 是 `famo_quick_send.json` / `famo_prompts.json`（`.txt`
//  是派生表，`.userdb` 是 Rime 运行期的 stabledb）。只改 `.userdb` 的话，新 app 读不到那两个
//  JSON —— 验收项「迁移后快捷短语 / 提示词在新 app 内可用」直接不成立，红线也就白划了。
//
//  纯 Foundation：无 librime、无 AppKit、无单例，路径与 FileManager 全注入，测试可在临时目录里
//  跑完整链路（`tests/OwlLegacyDataMigrationTests.swift`）。
//

import Foundation
import os

/// 一次目录迁移的结果。四个分支互斥，日志与单测都靠它区分「没做」和「做完了」。
enum OwlLegacyDataMigrationOutcome: Equatable {
  /// 新目录里已有完成标记 —— 上一次已经迁完，二次启动到此为止。
  case alreadyMigrated
  /// 新目录已存在但没有标记：既有的 Owltype 安装，或用户自己建的目录。绝不覆盖。
  case currentDirectoryPresent
  /// 旧目录不存在 —— 全新安装的正常路径。
  case noLegacyData
  /// 迁完了。`renamed` 是实际改到的新名字，按 `renameMap` 顺序。
  case migrated(renamed: [String])
}

/// 迁移过程中的失败。每一支都保证：staging 已被清掉，正式目录不存在，旧目录原封不动。
enum OwlLegacyDataMigrationError: LocalizedError, Equatable {
  /// 整目录复制失败（磁盘满 / 权限 / 旧目录被占）。此时还没产生任何新名字。
  case copyFailed(reason: String)
  /// staging 内改名失败。
  case renameFailed(name: String, reason: String)
  /// staging 内托管 YAML 无法读取、改写或恢复权限。
  case yamlRewriteFailed(name: String, reason: String)
  /// staging 根目录无法加固为 0700。
  case rootPermissionsFailed(name: String, reason: String)
  /// 最后一步「挂成正式目录」失败。
  case publishFailed(reason: String)

  var errorDescription: String? {
    switch self {
    case .copyFailed(let reason):
      return "复制旧用户数据目录失败：\(reason)"
    case .renameFailed(let name, let reason):
      return "改名 \(name) 失败：\(reason)"
    case .yamlRewriteFailed(let name, let reason):
      return "改写配置 \(name) 失败：\(reason)"
    case .rootPermissionsFailed(let name, let reason):
      return "加固迁移目录 \(name) 权限失败：\(reason)"
    case .publishFailed(let reason):
      return "启用迁移后的用户数据目录失败：\(reason)"
    }
  }
}

/// 迁移完成标记的内容。写进新目录根，既是幂等判据也是事后排障的收据。
struct OwlLegacyDataMigrationReceipt: Codable, Equatable {
  /// 标记格式版本；将来若要重跑一次不同形状的迁移，靠它区分。
  let version: Int
  /// 数据是从哪来的（旧目录绝对路径）。
  let source: String
  /// 实际改到的新文件名。
  let renamed: [String]
  /// 迁移时刻（调用方注入，便于测试固定）。
  let migratedAt: String
}

enum OwlLegacyDataMigration {
  /// 旧数据根的目录名，与新目录同在 `~/Library/Application Support/`。
  static let legacyDirectoryName = "Famo"
  /// 旧偏好域。整域导入新域（`OwlDefaults.standard`）。
  static let legacyDefaultsDomain = "im.famo.inputmethod.Famo"
  /// 完成标记文件名（新目录根）。
  static let markerFileName = ".owl-migrated-from-legacy-v1"
  /// 新域里的偏好导入标记。与目录标记分开：两件事各自幂等，一个失败不拖累另一个。
  static let defaultsImportedKey = "owl.migration.legacyDefaultsImported.v1"
  static let receiptVersion = 1

  static let log = Logger(subsystem: "im.owltype.inputmethod.Owltype", category: "migration")

  /// 复制完成后在**新目录内**执行的改名映射（旧名 → 新名），按此顺序。
  ///
  /// 只列名字变了的；`rime_ice.userdb`、`wubi86_jidian.userdb`、`sync/`、`projects/`、
  /// `providers.json`、`clipboard-history.json`、`installation.yaml`、`user.yaml` 等两代同名，
  /// 整目录复制已经带过来了，不需要也不应该动。`build/` 里的陈旧产物由下一次 deploy 重建。
  static let renameMap: [(legacy: String, current: String)] = [
    // Rime 基础配置：baseConfig 由 famo 改为 owltype，自定义补丁文件随之改名。
    ("famo.custom.yaml", "owltype.custom.yaml"),
    // 快捷短语：`.json` 是 source of truth（不可再生），`.txt` 是派生表，`.userdb` 是 Rime
    // 运行期的 stabledb。三件一起改，新 app 的 user_dict 名（owl_quick_send）才接得上。
    ("famo_quick_send.json", "owl_quick_send.json"),
    ("famo_quick_send.txt", "owl_quick_send.txt"),
    ("famo_quick_send.userdb", "owl_quick_send.userdb"),
    // 提示词：同上，`owl_prompts.json` 存正文，丢了无法再生。
    ("famo_prompts.json", "owl_prompts.json"),
    ("famo_prompts.txt", "owl_prompts.txt"),
    ("famo_prompts.userdb", "owl_prompts.userdb"),
    // dict-pack 按知情同意拉下来的法学词库（随 pack 命名）。
    ("famo_law_terms_pinyin.dict.yaml", "owl_law_terms_pinyin.dict.yaml"),
    ("famo_law_terms_wubi86.dict.yaml", "owl_law_terms_wubi86.dict.yaml"),
    // 种子标记：不改的话新 app 会以为没种过，把 _user_seed 再铺一遍（现有文件不会被覆盖，
    // 所以只是白跑一趟，但状态会对不上）。
    (".famo-seed-v2", ".owl-seed-v2"),
    // dict-pack 装机记录 + 断点续传 staging：不改则新 app 认为词库没装过，重新弹知情同意。
    (".famo-dictpack.json", ".owl-dictpack.json"),
    (".famo-dictpack-staging", ".owl-dictpack-staging"),
    // 配置写入层的备份根与回滚 manifest 目录。备份**内容**保持旧名不动 —— 它们是旧世界的
    // 快照，改名反而会让 manifest 里记的相对路径对不上；代价是迁移后回滚只能还原出旧名文件，
    // 属可接受的历史包袱（回滚是排障手段，不是数据通路）。
    (".famo-backup", ".owl-backup"),
    ("famo", "owltype")
  ]

  /// 复制后对新目录里 `*.custom.yaml` 做的标识改写（旧 → 新）。
  ///
  /// 为什么非做不可：托管块靠 marker 定位（`# >>> FAMO MANAGED …`）。原样搬过来的话，新 app
  /// 认不出旧 marker，会在**同一个 `patch:` 映射里**另起一套 `OWL MANAGED` 块 —— 于是
  /// `engine/translators/+` 和短语表在一个 mapping 里各出现两次（YAML 重复键），旧块还指着
  /// 已经改了名的 `famo_quick_send` 表。改 marker + 改块内标识，新 app 就直接认领这些块并按新
  /// 名幂等重写。
  ///
  /// 四个 token 两两不重叠，替换顺序无关。
  static let managedTokenMap: [(legacy: String, current: String)] = [
    ("FAMO MANAGED", "OWL MANAGED"),
    ("FAMO_CUSTOM", "OWLTYPE_CUSTOM"),
    ("famo_quick_send", "owl_quick_send"),
    ("famo_prompts", "owl_prompts")
  ]

  // MARK: - 目录迁移

  /// staging 目录名：与正式目录同父（同卷，保证最后一步是 rename(2)），点开头且带用途后缀，
  /// 谁看见都知道是残骸而不是数据。
  static func stagingDirectory(for currentDir: URL) -> URL {
    currentDir
      .deletingLastPathComponent()
      .appendingPathComponent(".\(currentDir.lastPathComponent)-migration-staging", isDirectory: true)
  }

  /// 旧目录存在且新目录不存在时，整目录复制 → staging 内改名 + 标识改写 → 写标记 → 原子挂载。
  ///
  /// 抛错即代表「什么都没发生」：staging 已清、正式目录不存在、旧目录原样。调用方可以选择
  /// 让 app 起在出厂默认上（见 `runIfNeeded`），下次启动会再试一次。
  @discardableResult
  static func migrateUserDirectoryIfNeeded(
    legacyDir: URL,
    currentDir: URL,
    timestamp: String,
    fileManager fm: FileManager = .default,
    managedYAMLWriter: @escaping (String, URL) throws -> Void = { contents, url in
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
  ) throws -> OwlLegacyDataMigrationOutcome {
    let marker = currentDir.appendingPathComponent(markerFileName)
    if fm.fileExists(atPath: marker.path) { return .alreadyMigrated }
    if fm.fileExists(atPath: currentDir.path) { return .currentDirectoryPresent }

    var legacyIsDirectory: ObjCBool = false
    guard fm.fileExists(atPath: legacyDir.path, isDirectory: &legacyIsDirectory),
          legacyIsDirectory.boolValue else {
      return .noLegacyData
    }

    let staging = stagingDirectory(for: currentDir)
    // 上一次跑到一半被打断（掉电 / 注销杀进程）留下的残骸。它按定义是不完整的，直接丢掉重来。
    try? fm.removeItem(at: staging)
    try? fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)

    do {
      try fm.copyItem(at: legacyDir, to: staging)
    } catch {
      try? fm.removeItem(at: staging)
      throw OwlLegacyDataMigrationError.copyFailed(reason: error.localizedDescription)
    }

    do {
      let renamed = try applyRenames(in: staging, fileManager: fm)
      try rewriteManagedTokens(in: staging, fileManager: fm, writer: managedYAMLWriter)
      let receipt = OwlLegacyDataMigrationReceipt(
        version: receiptVersion,
        source: legacyDir.path,
        renamed: renamed,
        migratedAt: timestamp
      )
      try writeReceipt(receipt, to: staging.appendingPathComponent(markerFileName), fileManager: fm)
      // 数据根与新目录同规格（0700）；copyItem 保留的是旧目录的位，旧目录本就是 0700，这里
      // 只是把「新目录必须私有」这条不变量写死，不依赖旧目录当时是什么。
      do {
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
      } catch {
        throw OwlLegacyDataMigrationError.rootPermissionsFailed(
          name: staging.lastPathComponent,
          reason: error.localizedDescription
        )
      }
      do {
        try fm.moveItem(at: staging, to: currentDir)
      } catch {
        throw OwlLegacyDataMigrationError.publishFailed(reason: error.localizedDescription)
      }
      return .migrated(renamed: renamed)
    } catch {
      try? fm.removeItem(at: staging)
      throw error
    }
  }

  /// staging 内按 `renameMap` 改名。旧名与新名同时存在说明源树有冲突；整批回滚，绝不猜哪份更新。
  private static func applyRenames(in root: URL, fileManager fm: FileManager) throws -> [String] {
    var renamed: [String] = []
    for pair in renameMap {
      let from = root.appendingPathComponent(pair.legacy)
      let target = root.appendingPathComponent(pair.current)
      guard fm.fileExists(atPath: from.path) else { continue }
      guard !fm.fileExists(atPath: target.path) else {
        throw OwlLegacyDataMigrationError.renameFailed(
          name: pair.legacy,
          reason: "目标 \(pair.current) 已存在，无法判定应保留哪一份"
        )
      }
      do {
        try fm.moveItem(at: from, to: target)
      } catch {
        throw OwlLegacyDataMigrationError.renameFailed(
          name: pair.legacy,
          reason: error.localizedDescription
        )
      }
      renamed.append(pair.current)
    }
    return renamed
  }

  /// 根目录下每个 `*.custom.yaml` 做 token 替换。任何读写或权限恢复失败都回滚整批；否则收据会
  /// 永久掩盖一棵仍引用旧文件名的配置树，后续启动也不会重试。
  static func rewriteManagedTokens(
    in root: URL,
    fileManager fm: FileManager = .default,
    writer: (String, URL) throws -> Void = { contents, url in
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
  ) throws {
    let entries: [URL]
    do {
      entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    } catch {
      throw OwlLegacyDataMigrationError.yamlRewriteFailed(
        name: root.lastPathComponent,
        reason: error.localizedDescription
      )
    }
    for url in entries where url.lastPathComponent.hasSuffix(".custom.yaml") {
      let text: String
      do {
        text = try String(contentsOf: url, encoding: .utf8)
      } catch {
        throw OwlLegacyDataMigrationError.yamlRewriteFailed(
          name: url.lastPathComponent,
          reason: error.localizedDescription
        )
      }
      let rewritten = rewritingManagedTokens(text)
      guard rewritten != text else { continue }
      let mode: Any?
      do {
        mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
        try writer(rewritten, url)
      } catch {
        throw OwlLegacyDataMigrationError.yamlRewriteFailed(
          name: url.lastPathComponent,
          reason: error.localizedDescription
        )
      }
      // 原子写换的是新 inode，权限位不跟着走；`famo.custom.yaml` 本是 0600，别写成 0644。
      if let mode {
        do {
          try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
          throw OwlLegacyDataMigrationError.yamlRewriteFailed(
            name: url.lastPathComponent,
            reason: error.localizedDescription
          )
        }
      }
    }
  }

  /// 纯函数版的 token 替换，便于单测直接断言。
  static func rewritingManagedTokens(_ text: String) -> String {
    managedTokenMap.reduce(text) { $0.replacingOccurrences(of: $1.legacy, with: $1.current) }
  }

  private static func writeReceipt(
    _ receipt: OwlLegacyDataMigrationReceipt,
    to url: URL,
    fileManager fm: FileManager
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: url, options: .atomic)
    try? OwlPrivateStorage.hardenFile(url, fileManager: fm)
  }

  /// 读回完成标记（排障 / 单测用）。不存在或解不开都返回 nil。
  static func receipt(in currentDir: URL) -> OwlLegacyDataMigrationReceipt? {
    let url = currentDir.appendingPathComponent(markerFileName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(OwlLegacyDataMigrationReceipt.self, from: data)
  }

  // MARK: - 偏好整域导入

  /// 读旧偏好域的整域快照。域不存在 → nil（全新安装的正常路径）。
  static func legacyDefaultsSnapshot(
    domain: String = legacyDefaultsDomain,
    reader: UserDefaults = .standard
  ) -> [String: Any]? {
    reader.persistentDomain(forName: domain)
  }

  /// 整域导入新域。返回实际写入的键数。
  ///
  /// 三条规则：**已有值不覆盖**（新 app 自己写过的赢，对齐「幂等：不覆盖新数据」）；**永不抛**
  /// （方案 §5.3：偏好导入失败就接受回落出厂默认，不阻塞启动）；**跑一次就落标记**，包括旧域
  /// 压根不存在的情形 —— 否则每次启动都去翻一遍不存在的域。
  @discardableResult
  static func importLegacyDefaults(
    from snapshot: [String: Any]?,
    into defaults: UserDefaults,
    markerKey: String = defaultsImportedKey
  ) -> Int {
    guard !defaults.bool(forKey: markerKey) else { return 0 }
    var imported = 0
    for (key, value) in snapshot ?? [:] where key != markerKey {
      guard defaults.object(forKey: key) == nil else { continue }
      defaults.set(value, forKey: key)
      imported += 1
    }
    defaults.set(true, forKey: markerKey)
    return imported
  }

  // MARK: - 启动期入口

  /// 启动期调用，早于新目录被创建（`setupRime()` 第一句 / `--build` 建目录之前）。
  ///
  /// 永不抛：目录迁移失败只记 fault 级日志，app 照常起在出厂默认上 —— 旧目录一个字节没动，
  /// 用户数据仍在磁盘上，下次启动还会再试一次。偏好导入与目录迁移互不阻塞。
  ///
  /// `legacyDir` 为 nil（`OWL_TEST_USER_DIR` 覆盖了数据根）时整个迁移不跑：那是开发 / 测试
  /// 沙箱，不该把真实旧数据搬进去，也不该动真实偏好域。
  static func runIfNeeded(
    legacyDir: URL? = OwlApp.legacyUserDir,
    currentDir: URL = OwlApp.userDir,
    defaults: UserDefaults = OwlDefaults.standard,
    timestamp: String = ISO8601DateFormatter().string(from: Date())
  ) {
    guard let legacyDir else { return }

    do {
      switch try migrateUserDirectoryIfNeeded(
        legacyDir: legacyDir,
        currentDir: currentDir,
        timestamp: timestamp
      ) {
      case .migrated(let renamed):
        log.notice("""
          migrated legacy user data → \(currentDir.path, privacy: .public) \
          (renamed \(renamed.count, privacy: .public) item(s); legacy tree left untouched)
          """)
      case .currentDirectoryPresent where FileManager.default.fileExists(atPath: legacyDir.path):
        // P5 顺序事故的唯一可观测面（plan §6 第 0/5 步）：旧卸载器会把迁移源一起删掉，
        // 用户若在恢复备份**之前**先启动过一次新 app，数据根就已经被 setupRime 建好并种上
        // 出厂种子 —— 此后迁移永远不再命中（新目录已存在，且「不覆盖新数据」是硬约束）。
        // 这里不擅自合并，只把现场喊出来，让 P5 第 8 步的验证能定位到而不是归因成「数据丢了」。
        log.error("""
          legacy data root still present at \(legacyDir.path, privacy: .public) but \
          \(currentDir.path, privacy: .public) already exists without a migration receipt — \
          first launch happened before the legacy tree was restored, so the one-shot migration \
          will never run. Recover by moving the current data root aside and relaunching.
          """)
      case .alreadyMigrated, .currentDirectoryPresent, .noLegacyData:
        break
      }
    } catch {
      let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      log.fault("""
        legacy user-data migration failed: \(reason, privacy: .public) — \
        starting on factory defaults; legacy tree at \(legacyDir.path, privacy: .public) is intact \
        and the migration will be retried on the next launch
        """)
    }

    let imported = importLegacyDefaults(from: legacyDefaultsSnapshot(), into: defaults)
    if imported > 0 {
      log.notice("imported \(imported, privacy: .public) legacy preference key(s) into the current domain")
    }
  }
}
