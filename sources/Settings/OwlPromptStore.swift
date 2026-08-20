//
//  OwlPromptStore.swift
//  法墨输入法 (Owltype) — 提示词（prompt）存储 + 校验 + 变量引擎（R2 无关的纯逻辑地基）
//
//  提示词是「快捷短语」的 sibling 特性：同样用触发码调出，但正文长 / 多行 / 可含 `{{变量}}`，
//  放不进单行的 Rime 候选条，所以正文走**独立的 JSON 存储**（source of truth），不与 quick-send
//  代码纠缠。本文件覆盖 R1（存储 / 模型 / 派生 Rime 表与 patch 生成）+ R2 的纯逻辑（提交拦截的
//  决策函数 `resolvePromptCommit` + 注入端口 `PromptResolving` 的活实现 `OwlPromptResolver`）+
//  R3（变量引擎）。控制器侧的 IMK 拦截接线与填空 sheet 在 `OwlInputController+RimeUpdate.swift`
//  / `OwlPromptFillSheet.swift`。
//
//  存储边界（spec `famo-rime-config-law.md` 写入层 / `state-management.md` 单源单向）：
//  `save` 一次性原子写三件（经 `OwlConfigWriter`：备份 + manifest + 回滚，与 quick-send 同路）：
//    1. `famo_prompts.json` —— source of truth（code·title·body·category）。`load` 只读它。
//    2. `famo_prompts.txt`  —— 从 entries **派生**的 Rime 表（`📝title \t code \t score` + 防撞
//       `v{code}` 变体）。正文绝不进此表；它只让打 code 时把带 📝 的标题调成候选。
//    3. `rime_ice.custom.yaml` patch —— 注册 `table_translator@famo_prompts`。
//  绝不直接写 `~/Library/Rime`。
//
//  📝 候选标记（R2）：派生表里标题前缀一个 `📝`，既让候选条视觉上可辨，又给控制器一个**廉价
//  闸门**——普通拼音提交不带 📝，提交拦截首步就 `hasPrefix(📝)` 短路返回，不读盘查 store。
//
//  并发：存储 / 校验 / 变量引擎纯值类型、非 `@MainActor`；只有活端口 `OwlPromptResolver` 与
//  决策函数 `resolvePromptCommit` 标 `@MainActor`（与其余注入端口一致，控制器在主线程经
//  `MainActor.assumeIsolated` 调用）。
//

import Foundation

// MARK: - 数据模型

/// 一条提示词。`code` 触发码（与快捷短语共享命名空间、同规则 `^[a-z][a-z0-9]{0,31}$`）；
/// `title` 单行，作为 Rime 候选显示；`body` 长 / 多行正文，被插入光标处，可含 `{{变量}}`；
/// `category` 可空（`""` = 未分类），用于分组 / 筛选。`variables` 从 `body` 派生（去重、保序），
/// **不持久化**（计算属性，Codable 不会编码它）。
struct OwlPromptEntry: Identifiable, Equatable, Sendable, Codable {
  let code: String
  let title: String
  let body: String
  var category: String

  var id: String { code }

  /// 从 `body` 抽取的 `{{变量}}` 名（去重、保留首现顺序）。派生属性，不进 JSON。
  var variables: [String] { OwlPromptVariables.extract(from: body) }

  init(code: String, title: String, body: String, category: String = "") {
    self.code = code
    self.title = title
    self.body = body
    self.category = category
  }
}

/// 提示词存储 / 校验错误。镜像 `OwlQuickSendError` 的形态（typed、`LocalizedError`）。
enum OwlPromptError: LocalizedError, Equatable {
  case invalidTitle
  case invalidBody
  case invalidCode
  /// 触发码与另一条提示词或某条快捷短语重复（共享触发命名空间）。
  case duplicateCode(String)

  var errorDescription: String? {
    switch self {
    case .invalidTitle: return "标题不能为空，且不能包含换行或 Tab。"
    case .invalidBody: return "正文不能为空。"
    case .invalidCode: return "触发码只能是小写字母开头的字母或数字。"
    case .duplicateCode(let code):
      return "触发码「\(code)」已被占用（提示词或快捷短语），请改用其他触发码。"
    }
  }
}

// MARK: - 变量引擎（R3，纯函数）

/// `{{变量}}` 抽取与替换。纯函数、零 IO，便于单测。
///
/// **未填变量规则**：`substitute` 对 `values` 里**没有**该变量名的占位符**保留原文 `{{名}}`**
/// （而非清空），让用户看到尚未填写的位置、不丢信息；而 `values` 里**存在**该名（哪怕值是空串）
/// 则按其值替换。同名变量出现多次都会被替换。
enum OwlPromptVariables {
  // `.*?` 非贪婪、不跨行：变量名不应跨越换行。相邻 `{{a}}{{b}}` 会被拆成两个独立匹配。
  private static let regex = try! NSRegularExpression(pattern: "\\{\\{(.*?)\\}\\}")

  private struct Token {
    let range: NSRange   // 整个 `{{...}}` 的范围
    let name: String     // 去掉两端空白后的变量名（可能为空 → `{{}}`）
  }

  private static func tokens(in body: String) -> [Token] {
    let ns = body as NSString
    let full = NSRange(location: 0, length: ns.length)
    return regex.matches(in: body, range: full).map { match in
      let nameRange = match.range(at: 1)
      let raw = nameRange.location == NSNotFound ? "" : ns.substring(with: nameRange)
      return Token(range: match.range, name: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// 抽取 `body` 里所有 `{{名}}` 的名字，去重、保留首现顺序。空名占位符 `{{}}` 忽略。
  static func extract(from body: String) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for token in tokens(in: body) where !token.name.isEmpty {
      if seen.insert(token.name).inserted { out.append(token.name) }
    }
    return out
  }

  /// 用 `values` 替换 `body` 里的 `{{名}}`。未填（或空名）占位符保留原文，见类型文档的「未填变量规则」。
  static func substitute(_ body: String, values: [String: String]) -> String {
    let ns = body as NSString
    var result = ""
    var cursor = 0
    for token in tokens(in: body) {
      // 追加占位符之前的原文。
      if token.range.location > cursor {
        result += ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
      }
      if !token.name.isEmpty, let value = values[token.name] {
        result += value
      } else {
        // 未填 / 空名 → 保留原占位符文本。
        result += ns.substring(with: token.range)
      }
      cursor = token.range.location + token.range.length
    }
    if cursor < ns.length {
      result += ns.substring(from: cursor)
    }
    return result
  }
}

// MARK: - 存储

/// `famo_prompts.json`（source of truth）的读 / 写 / 归一 + 触发码校验。镜像 `OwlQuickSendStore`
/// 的 idiom：`load` 容错（丢非法条目）、`save` 严格（非法即抛）、`normalized` 按 code 去重 + 排序。
/// 写入经 `OwlConfigWriter`（原子、可回滚），与 quick-send 同路。
enum OwlPromptStore {
  static let fileName = "famo_prompts.json"
  /// 派生的 Rime 表文件名（`📝title \t code \t score`）。`load` 不读它——它只是 JSON 的投影。
  static let dictFileName = "famo_prompts.txt"

  /// 候选标题前缀的 📝 标记。同时是「视觉可辨」与提交拦截的廉价闸门（见文件头注）。
  static let candidateMarker = "📝"

  // MARK: 读

  /// 读 `rimeDir/famo_prompts.json`。文件缺失 / 解码失败 → `[]`；个别非法条目被丢弃（容错）。
  static func load(rimeDir: URL = OwlApp.userDir) -> [OwlPromptEntry] {
    let url = rimeDir.appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([OwlPromptEntry].self, from: data) else {
      return []
    }
    let valid = decoded.compactMap {
      try? entry(code: $0.code, title: $0.title, body: $0.body, category: $0.category)
    }
    return (try? normalized(valid)) ?? valid
  }

  // MARK: 校验

  /// 校验并归一**单条** entry：触发码（格式）、标题（单行、非空）、正文（非空）。非法即抛。
  static func entry(
    code rawCode: String,
    title rawTitle: String,
    body rawBody: String,
    category rawCategory: String = ""
  ) throws -> OwlPromptEntry {
    let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
    let category = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !title.contains("\n"), !title.contains("\t") else {
      throw OwlPromptError.invalidTitle
    }
    guard !body.isEmpty else { throw OwlPromptError.invalidBody }
    guard code.range(of: #"^[a-z][a-z0-9]{0,31}$"#, options: .regularExpression) != nil else {
      throw OwlPromptError.invalidCode
    }
    return OwlPromptEntry(code: code, title: title, body: body, category: category)
  }

  /// 跨特性重码校验：提示码不得与任何快捷短语码重复（共享触发命名空间）。注入 `quickSendCodes`
  /// 便于单测；默认从 `OwlQuickSendStore.load()` 读现有快捷短语码。命中即抛 `.duplicateCode`。
  static func assertNoQuickSendCollision(
    code rawCode: String,
    quickSendCodes: Set<String>
  ) throws {
    let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if quickSendCodes.contains(code) {
      throw OwlPromptError.duplicateCode(code)
    }
  }

  /// 校验单条 entry（格式）**并**做跨特性重码校验。UI 新建 / 编辑保存时用。
  static func validatedEntry(
    code: String,
    title: String,
    body: String,
    category: String = "",
    quickSendCodes: Set<String>
  ) throws -> OwlPromptEntry {
    let clean = try entry(code: code, title: title, body: body, category: category)
    try assertNoQuickSendCollision(code: clean.code, quickSendCodes: quickSendCodes)
    return clean
  }

  /// 现有快捷短语码集合（跨特性重码校验的默认数据源）。
  static func quickSendCodes(rimeDir: URL = OwlApp.userDir) -> Set<String> {
    Set(OwlQuickSendStore.load(rimeDir: rimeDir).map(\.code))
  }

  // MARK: 写

  /// 原子写三件（经 `OwlConfigWriter`：备份 + manifest + 回滚），镜像 `OwlQuickSendStore.save`：
  ///   1. `famo_prompts.json` —— source of truth（先严格归一，非法即抛，再编码 JSON）。
  ///   2. `famo_prompts.txt`  —— 从同一批 entries 派生的 Rime 表（每次保存全量重生成）。
  ///   3. `rime_ice.custom.yaml` patch —— 注册 `table_translator@famo_prompts`。
  /// 三者同一 `timestamp`（同一回滚批次，rollback 会一起还原）。
  static func save(
    _ entries: [OwlPromptEntry],
    writer: OwlConfigWriter = OwlConfigWriter(),
    timestamp: String? = nil
  ) throws {
    let ts = timestamp ?? timestampNow()
    let clean = try normalized(entries)
    try writer.applyTextFile(
      fileName: fileName,
      contents: try render(clean),
      marker: OwlManagedMarker.promptsFile,
      timestamp: ts
    )
    try writer.applyTextFile(
      fileName: dictFileName,
      contents: renderDict(clean),
      marker: OwlManagedMarker.promptsDictFile,
      timestamp: ts
    )
    try writer.apply(fileName: "rime_ice.custom.yaml", block: rimeIcePatchBlock, timestamp: ts)
  }

  /// `rime_ice.custom.yaml` 托管块：把 `famo_prompts` 注册成一个 Owltype-owned `table_translator`。
  /// 与快捷短语用**不同 marker**，两块在同一文件里各自独立、互不覆盖。候选只显示 📝 标题，正文
  /// 由控制器在提交拦截时换入——所以这里照常是个普通短码表，无需任何特殊 Rime 配置。
  static var rimeIcePatchBlock: ManagedPatchBlock {
    ManagedPatchBlock(
      marker: OwlManagedMarker.promptsRimeIce,
      yamlLinesIndentedUnderPatch: [
        "  # 提示词：Owltype-owned table_translator，候选只显示 📝 标题；正文由控制器拦截插入",
        "  \"engine/translators/+\":",
        "    - table_translator@famo_prompts",
        "  famo_prompts:",
        "    dictionary: \"\"",
        "    user_dict: famo_prompts",
        "    db_class: stabledb",
        "    enable_completion: false",
        "    enable_sentence: false",
        "    initial_quality: 100",
      ]
    )
  }

  /// 从（已归一的）entries 派生 Rime 表文本。每条出两行：`📝title \t code \t 100000` 与防撞
  /// `📝title \t v{code} \t 100000`（镜像快捷短语 `render`）。`title` 已被 `entry` 校验过无
  /// 换行 / 无 Tab，对 Tab 分隔安全。正文（`body`）**绝不**进此文件。
  static func renderDict(_ entries: [OwlPromptEntry]) -> String {
    var lines = [
      "# Rime table",
      "# coding: utf-8",
      "#@/db_name famo_prompts",
      "#@/db_type tabledb",
      "# Owltype prompt titles. Body lives in famo_prompts.json; selecting a 📝 row inserts the body.",
      "",
    ]
    for entry in entries {
      let marked = candidateMarker + entry.title
      lines.append("\(marked)\t\(entry.code)\t100000")
      lines.append("\(marked)\tv\(entry.code)\t100000")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: 归一 / 渲染

  /// 严格归一（保存路径）：逐条校验（非法即抛）、按 code 去重（后出现者覆盖）、按 code 升序排序。
  static func normalized(_ entries: [OwlPromptEntry]) throws -> [OwlPromptEntry] {
    var out: [OwlPromptEntry] = []
    for item in entries {
      let clean = try entry(code: item.code, title: item.title, body: item.body, category: item.category)
      if let existing = out.firstIndex(where: { $0.code == clean.code }) {
        out[existing] = clean
      } else {
        out.append(clean)
      }
    }
    return out.sorted { $0.code < $1.code }
  }

  /// 编码为稳定（排序键 + 美化）JSON 文本，末尾补换行。
  private static func render(_ entries: [OwlPromptEntry]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(entries)
    return (String(data: data, encoding: .utf8) ?? "[]") + "\n"
  }

  private static func timestampNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
  }

  // MARK: 提交拦截支持（R2，纯逻辑）

  /// 去掉提交字符串开头的 📝 标记（及紧随空白），还原存在 JSON 里的干净标题。无标记则原样返回。
  static func strippingMarker(_ committed: String) -> String {
    guard committed.hasPrefix(candidateMarker) else { return committed }
    let afterMarker = committed.dropFirst(candidateMarker.count)
    return String(afterMarker.drop { $0 == " " || $0 == "\u{3000}" })
  }

  /// 按 (触发码, 干净标题) 在 `entries` 里找匹配提示词。纯函数，便于单测。先按标题缩小候选，再
  /// 在其中匹配触发码：精确 `entry.code == code` 优先；否则若 `code` 是防撞 `v{...}` 形态，剥掉
  /// 前导 `v` 再比。标题不唯一（store 以 code 为键），故必须 code+title 双匹配。无命中返回 nil。
  static func matchEntry(code rawCode: String, title: String, in entries: [OwlPromptEntry]) -> OwlPromptEntry? {
    let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !code.isEmpty else { return nil }
    let sameTitle = entries.filter { $0.title == title }
    if let exact = sameTitle.first(where: { $0.code == code }) { return exact }
    if code.hasPrefix("v") {
      let stripped = String(code.dropFirst())
      if let viaCollision = sameTitle.first(where: { $0.code == stripped }) { return viaCollision }
    }
    return nil
  }
}

// MARK: - 提交拦截决策（R2，纯函数 + 注入端口活实现）

/// 在统一提交 chokepoint 上，对一次候选提交要做什么。`resolvePromptCommit` 的纯输出，便于在没有
/// IMK / librime 的情况下单测分支逻辑（拦截与否、是否带变量）。
enum OwlPromptCommitAction: Equatable {
  /// 不是提示词候选 —— 照常走正常 Rime 提交。
  case passThrough
  /// 命中提示词、正文无 `{{变量}}` —— 直接把 `body` 插入光标处。
  case insert(String)
  /// 命中提示词、正文含 `{{变量}}` —— 弹填空 sheet，收集值后再插入。
  case fillIn(OwlPromptEntry)
}

/// 提交拦截的**纯决策**：给定源触发码（提交时 `rime.input()` 已清空，须取自前一合成 snapshot 的
/// `rawInput`）与提交的候选文本，返回该怎么处理。
///
/// 廉价闸门优先：只有 Owltype 自己的提示词候选带 📝 前缀，普通拼音提交首步 `hasPrefix(📝)` 即短路
/// 返回 `.passThrough`，**不读盘查 store**——把 store 查询挡在普通提交路径之外。带 📝 才剥标记 +
/// 经注入端口 `store` 做 (code,title) 查找；命中再按是否有变量分支。
///
/// `@MainActor`：`store.entry` 是 `@MainActor`（与其余注入端口一致）；控制器在主线程经
/// `MainActor.assumeIsolated` 调用本函数。注入 `store`（活实现 / 测试 fake）即可无 librime 单测。
@MainActor
func resolvePromptCommit(
  code: String?,
  committedTitle: String,
  store: PromptResolving
) -> OwlPromptCommitAction {
  guard committedTitle.hasPrefix(OwlPromptStore.candidateMarker) else { return .passThrough }
  let title = OwlPromptStore.strippingMarker(committedTitle)
  guard let code, let entry = store.entry(forCode: code, title: title) else { return .passThrough }
  return entry.variables.isEmpty ? .insert(entry.body) : .fillIn(entry)
}

/// 活提示词解析器：`PromptResolving` 注入端口的生产实现（镜像 `OwlSelectionPolishService` 之于
/// `SelectionPolishing`）。按需读 `famo_prompts.json` —— 只有提交了 📝 候选才会走到这（`resolve
/// PromptCommit` 的廉价闸门把普通提交挡在外面），故这次读盘罕见、不在按键热路径上。
@MainActor
final class OwlPromptResolver {
  static let shared = OwlPromptResolver()
  private init() {}

  /// (触发码, 干净标题) → 匹配的提示词；不是提示词则 nil。读当前 `famo_prompts.json`，委托纯函数
  /// `OwlPromptStore.matchEntry` 做匹配（含防撞 `v{code}` 处理）。
  func entry(forCode code: String, title: String) -> OwlPromptEntry? {
    OwlPromptStore.matchEntry(code: code, title: title, in: OwlPromptStore.load())
  }
}

// MARK: - 官方 XML 模板包（A1）

/// 一组开箱即用的 XML 标签提示词骨架，依据 Anthropic《Prompting best practices》的
/// 「Structure prompts with XML tags」：用成对标签区分指令 / 背景 / 输入，有层级就嵌套。
/// 都是提示词条目（触发码 + 标题 + 含 `{{变量}}` 的正文），复用 `OwlPromptStore` 整条存储 / 派生表 /
/// 填空管线——本枚举只提供**内容**与一个**只增不改**的合并函数，不碰存储与 UI。
enum OwlPromptPresets {
  /// 内置模板统一归到这个分类（07-21 机主拍板：叫「模板」，作为系统内置一直保留），和用户自建条目在列表里分得开。
  static let category = "模板"

  /// 五条通用骨架（法律领域模板按用户 2026-07-21 决定不收）。触发码可被用户改名；标签风格
  /// 用官方标准英文标签，同一条内保持一致。
  static let templates: [OwlPromptEntry] = [
    OwlPromptEntry(
      code: "four",
      title: "四要素提示词骨架",
      body: """
        <context>{{背景：为谁做、产出拿来干什么}}</context>
        <goal>{{目标：要达成什么、怎样算做完}}</goal>
        <constraints>{{约束：该做 / 不该做、边界}}</constraints>
        <input>{{待处理的内容}}</input>
        <output_format>{{产出形态：形式、篇幅、给谁读}}</output_format>
        """,
      category: category),
    OwlPromptEntry(
      code: "icx",
      title: "指令·背景·输入",
      body: """
        <instructions>{{要它做什么}}</instructions>
        <context>{{背景信息}}</context>
        <input>{{待处理内容}}</input>
        """,
      category: category),
    OwlPromptEntry(
      code: "fewshot",
      title: "少样例 few-shot",
      body: """
        <instructions>{{任务说明}}</instructions>
        <examples>
          <example>
            <input>{{示例输入1}}</input>
            <output>{{示例输出1}}</output>
          </example>
          <example>
            <input>{{示例输入2}}</input>
            <output>{{示例输出2}}</output>
          </example>
        </examples>
        <input>{{真正要处理的输入}}</input>
        """,
      category: category),
    OwlPromptEntry(
      code: "docs",
      title: "多文档嵌套",
      body: """
        <documents>
          <document index="1">
            <source>{{来源1，如文件名}}</source>
            <document_content>{{文档1正文}}</document_content>
          </document>
          <document index="2">
            <source>{{来源2}}</source>
            <document_content>{{文档2正文}}</document_content>
          </document>
        </documents>
        <instructions>{{基于以上文档做什么}}</instructions>
        """,
      category: category),
    OwlPromptEntry(
      code: "role",
      title: "角色·任务·输入",
      body: """
        <role>{{你是谁，如：某领域资深专家}}</role>
        <task>{{要完成的任务}}</task>
        <input>{{待处理内容}}</input>
        """,
      category: category),
  ]

  /// 合并结果：合并后的完整条目集（拿去 `save`）+ 实际导入的码 + 因撞码跳过的码。
  struct MergeResult: Equatable {
    let merged: [OwlPromptEntry]
    let added: [String]
    let skipped: [String]
  }

  /// 只增不改地把官方模板并入 `existing`：预置码若已被现有提示词或某条快捷短语占用（共享触发
  /// 命名空间）就**跳过**、绝不覆盖用户条目。纯函数、零 IO，便于单测；实际落盘由页面调 `save`。
  static func merge(
    into existing: [OwlPromptEntry],
    quickSendCodes: Set<String>
  ) -> MergeResult {
    let taken = Set(existing.map(\.code)).union(quickSendCodes)
    var merged = existing
    var added: [String] = []
    var skipped: [String] = []
    for template in templates {
      if taken.contains(template.code) {
        skipped.append(template.code)
      } else {
        merged.append(template)
        added.append(template.code)
      }
    }
    return MergeResult(merged: merged, added: added, skipped: skipped)
  }
}
