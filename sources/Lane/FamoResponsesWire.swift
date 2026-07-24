//
//  FamoResponsesWire.swift
//  法墨输入法 (Famo) — OpenAI/火山方舟 `/responses` 端点的请求 wire format
//
//  豆包(火山方舟)与 OpenAI 的联网搜索只在 `/responses` 上：`/chat/completions` 上塞多少
//  `tools:[{web_search}]` 都搜不到。这里是那条端点的请求构造，被两个调用方共用 ——
//  非流式的 来源核验 (`FamoSelectionPolish.makeResponsesSearchRequest`) 与流式的 任意提问
//  (`FamoResponsesStreamingClient`) —— 单一真相，两边不会漂移。
//
//  Pure value logic: builds a URL and a JSON-serializable dictionary. No network, no preferences.
//

import Foundation

enum FamoResponsesWire {
  /// Rewrite a profile's chat endpoint to its `/responses` sibling.
  ///
  /// Profiles store the `/chat/completions` URL (that's what every other lane uses), so the
  /// suffix is swapped rather than assumed; an endpoint already pointing at `/responses`, or a
  /// bare base URL, both land on the same place. Query/fragment are dropped — neither endpoint
  /// takes any, and carrying a stale one over would 400.
  static func url(from endpoint: URL) -> URL? {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
    var path = components.path
    if path.hasSuffix("/chat/completions") {
      path.removeLast("/chat/completions".count)
      path += "/responses"
    } else if !path.hasSuffix("/responses") {
      path += path.hasSuffix("/") ? "responses" : "/responses"
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    return components.url
  }

  /// One `input` item. EVERY role — assistant history included — must go as an `input_text`
  /// EasyInputMessage. Tagging an assistant turn `output_text` instead makes 方舟 parse it as a
  /// full *output* message, which then requires `id`+`status`+`type` we don't carry → HTTP 400
  /// `MissingParameter: input.status` on the SECOND turn (追问 — the first request that carries
  /// assistant history). Famo's `FamoAIContextAssembler.assemble` is single-turn today so nothing
  /// triggers it yet; the day 追问 lands, this is the line that keeps it working.
  static func inputMessage(role: String, text: String) -> [String: Any] {
    [
      "role": role,
      "content": [
        ["type": "input_text", "text": text],
      ],
    ]
  }

  /// The web-search `/responses` body. `stream` picks 流式(任意提问)/非流式(来源核验); `isOpenAI`
  /// picks the dialect — OpenAI's tool is a bare `{type: web_search}` and it has no `thinking`
  /// field, while 方舟 caps parallel searches (`max_keyword`) and results per search (`limit`) and
  /// needs thinking off for the search plugin to fire.
  static func searchBody(
    model: String,
    input: [[String: Any]],
    stream: Bool,
    isOpenAI: Bool
  ) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "input": input,
      "stream": stream,
      "tools": [isOpenAI
        ? ["type": "web_search"]
        : ["type": "web_search", "max_keyword": 2, "limit": 3]],
    ]
    if !isOpenAI {
      body["thinking"] = ["type": "disabled"]
      body["max_tool_calls"] = 3
    }
    return body
  }
}
