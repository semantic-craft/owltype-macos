//
//  OwlPolishStyle.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  Defines the 4 polish styles ("原意保真", "精炼书面", "得体商务", "口语转书面"),
//  their UI metadata (icons, subtitles, temperature), and prompt catalog
//  guaranteeing exactly 2 differentiated candidates in XML tags.
//

import Foundation

// MARK: - Polish Styles

enum OwlPolishStyle: String, CaseIterable, Identifiable, Codable, Sendable {
  case faithful = "原意保真"
  case conciseWritten = "精炼书面"
  case properBusiness = "得体商务"
  case spokenToWritten = "口语转书面"

  var id: String { rawValue }
  var title: String { rawValue }

  var subtitle: String {
    switch self {
    case .faithful:
      return "纠正错字病句 · 严格保真原意"
    case .conciseWritten:
      return "删繁就简提炼 · 凝练规范书面语"
    case .properBusiness:
      return "得体稳重得礼 · 协作建设性语态"
    case .spokenToWritten:
      return "清口语填充词 · 语法重组规范化"
    }
  }

  var iconName: String {
    switch self {
    case .faithful:
      return "checkmark.shield"
    case .conciseWritten:
      return "doc.text.magnifyingglass"
    case .properBusiness:
      return "briefcase"
    case .spokenToWritten:
      return "waveform.and.person.filled"
    }
  }

  var temperature: Double {
    switch self {
    case .faithful:
      return 0.2
    case .conciseWritten:
      return 0.3
    case .properBusiness:
      return 0.3
    case .spokenToWritten:
      return 0.3
    }
  }

  var promptDescription: String {
    switch self {
    case .faithful:
      return """
      原意保真：极简改动，纠正错别字、缺失标点与硬伤语病。最大限度保留作者原有措辞习惯、专业术语与事实，绝不改变论述基调。
      差异化输出：
      - <candidate_1>：最保守基础校正版。仅修错别字、标点与硬伤语病，完全保留其余所有字词与句式。
      - <candidate_2>：流畅保真润色版。在严格遵循原意与专业术语的前提下，微调连接词或呼吸停顿，使语意表达更为通畅连贯。
      """
    case .conciseWritten:
      return """
      精炼书面：高信息密度，剔除冗余修饰与套话废话。将口语化或松散表述替换为规范、凝炼的书面中文词汇，重构紧凑句式。
      差异化输出：
      - <candidate_1>：均衡精炼版。适度精简冗余用词，保持完整的叙述脉络，适合通用书面报告与正式文案。
      - <candidate_2>：极致凝练版。深度压缩篇幅，使用干练有力的短语与紧凑结构，直奔要点，适合摘要或结论。
      """
    case .properBusiness:
      return """
      得体商务：语言客气、庄重、沉稳、诚恳，体现专业素养与合作诚意。弱化急躁或尖锐情绪，转换为建设性、解决方案导向的职业商务语态。
      差异化输出：
      - <candidate_1>：规范正式商务版。语气沉稳庄重、措辞严谨规范，适合正式邮件、对外联络、公函呈报与高层汇报。
      - <candidate_2>：敏捷协作商务版。语气积极高效、亲和务实，强调跨部门协同与快速推动推进，适合工作即时沟通与日常业务对接。
      """
    case .spokenToWritten:
      return """
      口语转书面：坚决剔除无意义口头禅、停顿填充词（如“那个”、“就是说”、“然后呢”、“呃”、“啊”）、口吃碎语及倒装碎片，整理为条理清晰的书面句式。
      差异化输出：
      - <candidate_1>：自然成文版。平实自然的书面语，流畅通顺，保留说话人的叙事逻辑与清晰脉络。
      - <candidate_2>：结构提炼版。更具条理的书面语，强化分句层次与条理性，使表达具备正式书面语的权威感。
      """
    }
  }
}

// MARK: - Prompt Catalog

enum OwlDualPolishPromptCatalog {
  static func buildSystemPrompt(style: OwlPolishStyle) -> String {
    """
    你是一名精通中文表达的高级文字编辑与润色专家。
    请针对用户给出的原文本，按照指定风格【\(style.rawValue)】生成恰好 2 个截然不同、各有千秋的高质量润色候选版本。

    风格指导与差异化要求：
    \(style.promptDescription)

    输出格式必须严格遵守以下 XML 标签结构，不得输出任何前言、解释、分析、Markdown 代码块或多余符号：
    <candidate_1>
    候选版本一的具体文字
    </candidate_1>
    <candidate_2>
    候选版本二的具体文字
    </candidate_2>

    硬性要求：
    1. 必须输出 <candidate_1> 和 <candidate_2> 两组标签。
    2. 两条候选的用词、句型或切入角度必须具有可感知的差异度，供用户二选一。
    3. 严禁改变原文关键事实与主张。
    4. 标签外部严禁包含任何多余文字或符号。
    """
  }

  static func buildUserPrompt(text: String) -> String {
    "请润色以下文本：\n\(text)"
  }
}
