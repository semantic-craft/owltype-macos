import Foundation

/// Installs only an Owltype-owned filter. A user's custom filter chain remains theirs.
enum OwlPinnedWordsDeployment {
  static let marker = "OWL MANAGED PINNED WORDS v1"
  static let filter = "lua_filter@*owltype_pinned_words"
  static var available = false

  static func apply(userDir: URL, sharedDir: URL) throws {
    available = false
    let manager = FileManager.default
    let schema = "rime_ice.schema.yaml"
    guard manager.fileExists(atPath: sharedDir.appendingPathComponent(schema).path) else { return }
    let custom = userDir.appendingPathComponent("rime_ice.custom.yaml")
    let original = manager.fileExists(atPath: custom.path) ? try String(contentsOf: custom, encoding: .utf8) : "patch:\n"
    guard original.contains("patch:") else { return }
    let removed = try OwlConfigWriter(rimeDir: userDir).renderManagedBlock(original,
      block: ManagedPatchBlock(marker: marker, yamlLinesIndentedUnderPatch: []))
    let active = removed.components(separatedBy: .newlines).map { $0.components(separatedBy: "#")[0] }.joined(separator: "\n")
    let userOwnsFilters = manager.fileExists(atPath: userDir.appendingPathComponent(schema).path)
      || active.range(of: #"engine/filters|engine/translators(?:/=)?["']?\s*:|(?m)^\s*filters\s*:|__include\s*:|__patch\s*:"#, options: .regularExpression) != nil
    let script = userDir.appendingPathComponent("lua/owltype_pinned_words.lua")
    let existingScript = try? String(contentsOf: script, encoding: .utf8)
    let userOwnsScript = existingScript != nil && !(existingScript?.hasPrefix("-- " + marker) ?? false)
    let canInstall = !userOwnsFilters && !userOwnsScript
    if canInstall {
      try OwlPrivateStorage.prepareDirectory(script.deletingLastPathComponent())
      if existingScript != lua {
        try lua.write(to: script, atomically: true, encoding: .utf8)
        try OwlPrivateStorage.hardenFile(script)
      }
    }
    let lines = canInstall ? ["  \"engine/filters/+\":", "    - \(filter)"] : []
    if canInstall || original.contains(marker) {
      try OwlConfigWriter(rimeDir: userDir).apply(fileName: "rime_ice.custom.yaml",
        block: ManagedPatchBlock(marker: marker, yamlLinesIndentedUnderPatch: lines),
        timestamp: ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
    }
    if manager.fileExists(atPath: custom.path), try String(contentsOf: custom, encoding: .utf8) != original {
      // Invalidate only the generated schema; whole-second Rime mtimes can miss rapid changes.
      let compiled = userDir.appendingPathComponent("build/rime_ice.schema.yaml")
      if manager.fileExists(atPath: compiled.path) { try manager.removeItem(at: compiled) }
    }
    available = canInstall
  }

  static let lua = #"""
  -- OWL MANAGED PINNED WORDS v1
  -- Frontend supplies local preferences via a session property; no IO during typing.
  local M = {}
  function M.init(env)
    env.packed = nil
    env.words = {}
  end
  function M.func(input, env)
    local ctx = env.engine.context
    local packed = ctx:get_property("owl_pinned_words")
    if packed ~= env.packed then
      env.packed = packed
      env.words = {}
      for code, mode, word in packed:gmatch("([^\t\n]+)\t([01])\t([^\n]+)") do
        local key = code .. "\t" .. mode
        env.words[key] = env.words[key] or {}
        table.insert(env.words[key], word)
      end
    end
    local traditional = ctx:get_option("traditionalization") or ctx:get_option("traditional")
      or ctx:get_option("transcription") or ctx:get_option("zh_trad")
    local pins = env.words[ctx.input .. "\t" .. (traditional and "1" or "0")] or {}
    local seen = {}
    local first = true
    for cand in input:iter() do
      if first then
        first = false
        if not ctx:get_option("ascii_mode") and cand.start == 0 and cand._end == #ctx.input then
          for _, word in ipairs(pins) do
            local pinned = Candidate("owl_pinned", cand.start, cand._end, word, "置顶")
            pinned.preedit = cand.preedit
            yield(pinned)
            seen[word] = true
          end
        end
      end
      if not seen[cand.text] then yield(cand) end
    end
  end
  return M
  """#
}
