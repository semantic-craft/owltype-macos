import Foundation

/// Installs full-pinyin short-code priority and explicit pins in one owned filter.
/// A user's custom filter chain remains theirs.
enum OwlPinyinCandidateDeployment {
  // Retain the deployed marker/module name so upgrades replace the existing managed block.
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
  -- Mixed English follows Metasequoia IME's rule: English never competes with pinyin by
  -- weight. A word equal to input that is not whole pinyin syllables leads; otherwise one
  -- English row takes a seat behind the Chinese rows and the rest follow every Chinese row.
  -- No IO during typing.
  local M = {}
  local LOOKAHEAD = 64
  local syllables = {}
  for s in ([[
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biang biao bie bin bing bo bong bu
    ca cai can cang cao ce cei cen ceng cha chai chan chang chao che chen cheng chi chong chou
    chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang
    dao de den deng di dia dian diao die din ding diu dong dou du duan dui dun duo e ei en eng
    er fa fan fang fei fen feng fiao fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu
    gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai
    huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai
    kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang
    lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo lv
    lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan
    nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nun nuo
    nv nve o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia
    qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou
    ru rua ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei
    shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun
    suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai
    wan wang wei wen weng wo wong wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue
    xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei
    zen zeng zha zhai zhan zhang zhao zhe zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang
    zhui zhun zhuo zi zong zou zu zuan zui zun zuo
  ]]):gmatch("%a+") do syllables[s] = true end

  function M.init(env)
    env.packed = nil
    env.words = {}
  end
  local function has_han(text)
    for _, cp in utf8.codes(text) do
      if (cp >= 0x3400 and cp <= 0x9fff) or (cp >= 0xf900 and cp <= 0xfaff)
        or (cp >= 0x20000 and cp <= 0x323af) then return true end
    end
    return false
  end
  -- Latin words without Han; mixed rows such as "X光" rank as Chinese. Explicit custom
  -- phrases/templates keep their place, including ASCII text.
  local function is_english(cand)
    return cand.type ~= "user_table" and cand.text:find("%a") ~= nil and not has_han(cand.text)
  end
  local function whole_syllables(code)
    local reach = { [0] = true }
    for i = 1, #code do
      for length = 1, math.min(6, i) do
        if reach[i - length] and syllables[code:sub(i - length + 1, i)] then
          reach[i] = true
          break
        end
      end
    end
    return reach[#code] == true
  end

  -- Whole-syllable input seats only the English word equal to it, after the first page of
  -- Chinese; other input seats its first English row after one Chinese row (three for
  -- one- and two-letter codes). The stream is consumed once and its tail stays lazy.
  local function mixed_candidates(input, code, page_size)
    return coroutine.wrap(function()
      if not code then
        for cand in input:iter() do coroutine.yield(cand) end
        return
      end
      local whole = #code < 2 or whole_syllables(code)
      local slot = whole and page_size or 1
      if #code <= 2 and slot < 3 then slot = 3 end
      local english, main, seated = {}, 0, false
      -- Look ahead a bounded distance for the first English row, which leads when it equals
      -- the input and otherwise takes the seat.
      local held = not whole and {} or nil
      local function seats(cand) return not whole or cand.text:lower() == code end
      local function take_seat()
        for i, cand in ipairs(english) do
          if seats(cand) then
            seated = true
            coroutine.yield(table.remove(english, i))
            return
          end
        end
      end
      local function place(cand)
        if not is_english(cand) then
          coroutine.yield(cand)
          main = main + 1
          if main == slot and not seated then take_seat() end
        elseif not seated and main >= slot and seats(cand) then
          seated = true
          coroutine.yield(cand)
        else
          english[#english + 1] = cand
        end
      end
      local function release()
        for _, cand in ipairs(held) do
          if is_english(cand) then english[#english + 1] = cand end
        end
        for _, cand in ipairs(held) do
          if not is_english(cand) then place(cand) end
        end
        held = nil
      end
      for cand in input:iter() do
        if held == nil then
          place(cand)
        elseif is_english(cand) then
          if cand.text:lower() == code then
            seated = true
            coroutine.yield(cand)
          else
            held[#held + 1] = cand
          end
          release()
        else
          held[#held + 1] = cand
          if #held == LOOKAHEAD then release() end
        end
      end
      if held then release() end
      if not seated then take_seat() end
      for _, cand in ipairs(english) do coroutine.yield(cand) end
    end)
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
    local code = ctx.input
    if not ctx.composition:empty() then
      local segment = ctx.composition:back()
      code = code:sub(segment.start + 1, segment._end)
    end
    local mixed = not ctx:get_option("ascii_mode") and code:match("^[a-z]+$") ~= nil
    for cand in mixed_candidates(input, mixed and code, env.engine.schema.page_size) do
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
