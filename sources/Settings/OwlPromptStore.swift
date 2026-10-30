//
//  OwlPromptStore.swift
//  猫头鹰输入法 (Owltype) — 提示词（prompt）存储 + 校验 + 变量引擎（R2 无关的纯逻辑地基）
//
//  提示词是「快捷短语」的 sibling 特性：同样用触发码调出，但正文长 / 多行 / 可含 `{{变量}}`，
//  放不进单行的 Rime 候选条，所以正文走**独立的 JSON 存储**（source of truth），不与 quick-send
//  代码纠缠。本文件覆盖 R1（存储 / 模型 / 派生 Rime 表与 patch 生成）+ R2 的纯逻辑（提交拦截的
//  决策函数 `resolvePromptCommit` + 注入端口 `PromptResolving` 的活实现 `OwlPromptResolver`）+
//  R3（变量引擎）。控制器侧的 IMK 拦截接线与填空 sheet 在 `OwlInputController+EngineUpdate.swift`
//  / `OwlPromptFillSheet.swift`。
//
//  存储边界（spec `owl-rime-config-law.md` 写入层 / `state-management.md` 单源单向）：
//  `save` 一次性原子写三件（经 `OwlConfigWriter`：备份 + manifest + 回滚，与 quick-send 同路）：
//    1. `owl_prompts.json` —— source of truth（code·title·body·category）。`load` 只读它。
//    2. `owl_prompts.txt`  —— 从 entries **派生**的 Rime 表（`📝title \t code \t score` + 防撞
//       `v{code}` 变体）。正文绝不进此表；它只让打 code 时把带 📝 的标题调成候选。
//    3. `rime_ice.custom.yaml` patch —— 注册 `table_translator@owl_prompts`。
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
  static func extract(from body: String) -> [String] {
    OwlTemplateEngine.parse(body: body, syntax: .legacyDoubleBraces).parameters.map(\.name)
  }

  static func substitute(_ body: String, values: [String: String]) -> String {
    let parsed = OwlTemplateEngine.parse(body: body, syntax: .legacyDoubleBraces)
    let keyed = Dictionary(uniqueKeysWithValues: values.map { ("n:" + $0.key, $0.value) })
    return OwlTemplateEngine.render(parsed, values: keyed).previewText
  }
}

// MARK: - 存储

/// `owl_prompts.json`（source of truth）的读 / 写 / 归一 + 触发码校验。镜像 `OwlQuickSendStore`
/// 的 idiom：`load` 容错（丢非法条目）、`save` 严格（非法即抛）、`normalized` 按 code 去重 + 排序。
/// 写入经 `OwlConfigWriter`（原子、可回滚），与 quick-send 同路。
enum OwlPromptStore {
  static let fileName = "owl_prompts.json"
  static let dictFileName = "owl_prompts.txt"
  static let candidateMarker = "📝"
  static func load(dataDir: URL = OwlApp.userDir) -> [OwlPromptEntry] {
    (try? OwlStorageHost(dataDir: dataDir).call("prompt_load")) ?? []
  }
  static func entry(code: String, title: String, body: String, category: String = "") throws -> OwlPromptEntry {
    try OwlStorageHost(dataDir: URL(fileURLWithPath: "/")).call("prompt_entry", ["entry": OwlAppCore.payload(OwlPromptEntry(code: code, title: title, body: body, category: category))])
  }
  static func assertNoQuickSendCollision(code: String, quickSendCodes: Set<String>) throws {
    let _: Bool = try OwlStorageHost(dataDir: URL(fileURLWithPath: "/")).call("prompt_collision", ["code": code, "codes": Array(quickSendCodes)])
  }
  static func validatedEntry(code: String, title: String, body: String, category: String = "", quickSendCodes: Set<String>) throws -> OwlPromptEntry {
    try OwlStorageHost(dataDir: URL(fileURLWithPath: "/")).call("prompt_entry", ["entry": OwlAppCore.payload(OwlPromptEntry(code: code, title: title, body: body, category: category)), "codes": Array(quickSendCodes)])
  }
  static func quickSendCodes(dataDir: URL = OwlApp.userDir) -> Set<String> { Set(OwlQuickSendStore.load(dataDir: dataDir).map(\.code)) }
  static func save(_ entries: [OwlPromptEntry], writer: OwlConfigWriter = OwlConfigWriter(), timestamp: String? = nil) throws {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
    let _: Bool = try OwlStorageHost(dataDir: writer.dataDir, writerCheckpoint: writer.writeCheckpoint).call("prompt_save", ["entries": OwlAppCore.payload(entries), "timestamp": timestamp ?? f.string(from: Date())])
  }
  static var rimeIcePatchBlock: ManagedPatchBlock { OwlTemplateStore.core("prompt_patch") }
  static func renderDict(_ entries: [OwlPromptEntry]) -> String { OwlTemplateStore.core("prompt_projection", ["entries": OwlAppCore.payload(entries)]) }
  static func normalized(_ entries: [OwlPromptEntry]) throws -> [OwlPromptEntry] {
    try OwlStorageHost(dataDir: URL(fileURLWithPath: "/")).call("prompt_normalized", ["entries": OwlAppCore.payload(entries)])
  }
  static func strippingMarker(_ committed: String) -> String { OwlTemplateStore.core("prompt_strip", ["text": committed]) }
  static func matchEntry(code: String, title: String, in entries: [OwlPromptEntry]) -> OwlPromptEntry? {
    struct Result: Decodable { let entry: OwlPromptEntry? }
    let result: Result = OwlTemplateStore.core("prompt_match", ["code": code, "title": title, "entries": OwlAppCore.payload(entries)])
    return result.entry
  }
}

// MARK: - 提交拦截决策（R2，纯函数 + 注入端口活实现）

/// 在统一提交 chokepoint 上，对一次候选提交要做什么。`resolvePromptCommit` 的纯输出，便于在没有
/// IMK / 引擎 的情况下单测分支逻辑（拦截与否、是否带变量）。
enum OwlPromptCommitAction: Equatable {
  /// 不是提示词候选 —— 照常走正常 Rime 提交。
  case passThrough
  /// Preserve the selected entry snapshot; the shared invocation decides whether filling is needed.
  case invoke(OwlPromptEntry)
}

/// 提交拦截的**纯决策**：给定源触发码（提交时 `engineSession.input()` 已清空，须取自前一合成 snapshot 的
/// `rawInput`）与提交的候选文本，返回该怎么处理。
///
/// 廉价闸门优先：只有 Owltype 自己的提示词候选带 📝 前缀，普通拼音提交首步 `hasPrefix(📝)` 即短路
/// 返回 `.passThrough`，**不读盘查 store**——把 store 查询挡在普通提交路径之外。带 📝 才剥标记 +
/// 经注入端口 `store` 做 (code,title) 查找；命中再按是否有变量分支。
///
/// `@MainActor`：`store.entry` 是 `@MainActor`（与其余注入端口一致）；控制器在主线程经
/// `MainActor.assumeIsolated` 调用本函数。注入 `store`（活实现 / 测试 fake）即可无引擎 单测。
@MainActor
func resolvePromptCommit(
  code: String?,
  committedTitle: String,
  store: PromptResolving
) -> OwlPromptCommitAction {
  guard committedTitle.hasPrefix(OwlPromptStore.candidateMarker) else { return .passThrough }
  let title = OwlPromptStore.strippingMarker(committedTitle)
  guard let rawCode = code else { return .passThrough }
  let code = rawCode.hasPrefix("K") ? String(rawCode.dropFirst()) : rawCode
  guard let entry = store.entry(forCode: code, title: title) else { return .passThrough }
  return .invoke(entry)
}

/// 活提示词解析器：`PromptResolving` 注入端口的生产实现（镜像 `OwlSelectionPolishService` 之于
/// `SelectionPolishing`）。按需读 `owl_prompts.json` —— 只有提交了 📝 候选才会走到这（`resolve
/// PromptCommit` 的廉价闸门把普通提交挡在外面），故这次读盘罕见、不在按键热路径上。
@MainActor
final class OwlPromptResolver {
  static let shared = OwlPromptResolver()
  private init() {}

  /// (触发码, 干净标题) → 匹配的提示词；不是提示词则 nil。读当前 `owl_prompts.json`，委托纯函数
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
  struct MergeResult: Equatable, Decodable {
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
    OwlTemplateStore.core("prompt_presets", ["entries": OwlAppCore.payload(existing), "codes": Array(quickSendCodes), "presets": OwlAppCore.payload(templates)])
  }
}
