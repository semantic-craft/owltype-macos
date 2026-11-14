//
//  OwlReplyTemplate.swift
//  Owltype — AI Writing Auxiliary Subsystem (Milestone M7 / Issue #397)
//
//  Defines the 5 quick reply templates ("认同赞成", "委婉拒绝", "进一步询问", "感谢致意", "推进催办"),
//  their UI metadata (icons, subtitles, candidate perspectives), and prompt catalog
//  guaranteeing exactly 3 differentiated reply candidates.
//

import Foundation

// MARK: - Reply Templates

enum OwlReplyTemplate: String, CaseIterable, Identifiable, Codable, Sendable {
  case agree = "认同赞成"
  case decline = "委婉拒绝"
  case inquiry = "进一步询问"
  case gratitude = "感谢致意"
  case followUp = "推进催办"

  var id: String { rawValue }
  var title: String { rawValue }

  var subtitle: String {
    switch self {
    case .agree:
      return "表达积极认同 · 确认承诺推进"
    case .decline:
      return "客气礼貌回绝 · 说明客观受限"
    case .inquiry:
      return "追问关键细节 · 明确时间范围"
    case .gratitude:
      return "诚挚感谢协助 · 维护良好合作"
    case .followUp:
      return "温和跟进进度 · 提醒关键节点"
    }
  }

  var iconName: String {
    switch self {
    case .agree:
      return "hand.thumbsup"
    case .decline:
      return "hand.raised"
    case .inquiry:
      return "questionmark.circle"
    case .gratitude:
      return "heart.fill"
    case .followUp:
      return "arrow.forward.circle"
    }
  }

  var promptDescription: String {
    switch self {
    case .agree:
      return "认同赞成：表达充分赞同与支持，态度积极主动，承诺按此推进。"
    case .decline:
      return "委婉拒绝：表示感谢但客气说明客观原因/排期受限，委婉礼貌地回绝，保留后续合作空间。"
    case .inquiry:
      return "进一步询问：礼貌跟进，针对时间节点、技术细节、依赖事项或背景信息提出具体明确的询问。"
    case .gratitude:
      return "感谢致意：真诚感谢对方的协助、支持或快速反馈，言辞诚挚得体、亲和专业。"
    case .followUp:
      return "推进催办：温和跟进进度，提醒关键节点并主动询问是否需要协作支持，不生硬刺耳。"
    }
  }

  var candidatePerspectives: (first: String, second: String, third: String) {
    (first: "精炼直接", second: "专业周全", third: "积极推进")
  }
}

// MARK: - Reply Prompt Catalog

enum OwlReplyPromptCatalog {
  static func buildSystemPrompt(template: OwlReplyTemplate) -> String {
    """
    你是一名专业高效的沟通秘书与文字表达顾问。
    请阅读用户给出的前文沟通内容，按照回复意图【\(template.rawValue)】生成恰好 3 个得体、自然的候选回复。

    意图指导：
    \(template.promptDescription)

    3 条候选的具体差异度要求（供用户在不同场景下选用）：
    - <candidate_1>（精炼直接）：1-2 句短句，开门见山，适合即时通讯（飞书/企业微信/微信/钉钉）快速回复。
    - <candidate_2>（专业周全）：格式规范，言辞严谨礼貌，上下文完整，适合正式邮件或公函呈报。
    - <candidate_3>（积极推进）：富有建设性与主动性，提供下一步建议或备选方案，展现良好的协作态度。

    输出格式必须严格遵守以下 XML 标签结构，不得输出任何前言、解释说明、Markdown 代码块或多余符号：
    <candidate_1>
    回复候选一
    </candidate_1>
    <candidate_2>
    回复候选二
    </candidate_2>
    <candidate_3>
    回复候选三
    </candidate_3>

    硬性要求：
    1. 必须且仅能输出 <candidate_1>、<candidate_2>、<candidate_3> 三个标签。
    2. 标签内容不得包含多余的引号或外层包裹符号。
    3. 标签外部严禁包含任何多余文字。
    """
  }

  static func buildUserPrompt(contextText: String) -> String {
    "沟通上下文：\n\(contextText)"
  }
}
