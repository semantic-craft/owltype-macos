import Foundation
import Observation

struct OwlPinnedWord: Codable, Equatable, Identifiable {
  let code: String
  let text: String
  let traditional: Bool
  var id: String { "\(code)\t\(traditional)\t\(text)" }
}

struct OwlTraditionalPinSource: Equatable {
  let code: String
  let text: String
  let source: String
  var actionPayload: [String: String] { ["code": code, "text": text, "source": source] }
}

/// Small local library; engine properties carry a cached copy to Lua, so typing does no file IO.
@Observable
final class OwlPinnedWords {
  static let shared = OwlPinnedWords(defaults: OwlDefaults.standard)
  static let property = "owl_pinned_words"
  private static let key = "OwlPinnedWordsV1"
  private let defaults: UserDefaults
  private(set) var words: [OwlPinnedWord]
  private(set) var revision: UInt64 = 0
  private(set) var engineValue: String = ""

  init(defaults: UserDefaults) {
    self.defaults = defaults
    words = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([OwlPinnedWord].self, from: $0) } ?? []
    updateEngineValue()
  }

  @discardableResult
  func toggle(_ word: OwlPinnedWord) -> Bool {
    let exists = words.contains(word)
    words.removeAll { $0 == word }
    if !exists { words.insert(word, at: 0) }
    save()
    return !exists
  }

  func remove(_ word: OwlPinnedWord) {
    words.removeAll { $0 == word }
    save()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(words) { defaults.set(data, forKey: Self.key) }
    revision &+= 1
    updateEngineValue()
  }

  private func updateEngineValue() {
    engineValue = words.map { "\($0.code)\t\($0.traditional ? 1 : 0)\t\($0.text)" }.joined(separator: "\n")
  }

  static func hansToHant(_ text: String) -> String {
    guard let input = try? JSONEncoder().encode(text),
          let json = String(data: input, encoding: .utf8),
          let converted = json.withCString({ owl_msime_simplified_to_traditional_json($0) }) else {
      return text
    }
    defer { owl_msime_string_free(converted) }
    return (try? JSONDecoder().decode(String.self, from: Data(String(cString: converted).utf8))) ?? text
  }

  static func hantToHans(_ text: String) -> String {
    (text as NSString).applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
  }

  static func traditionalSources(engineValue: String) -> [OwlTraditionalPinSource] {
    engineValue.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
      let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3, parts[1] == "1" else { return nil }
      let text = String(parts[2])
      let source = hantToHans(text)
      guard !source.isEmpty, hansToHant(source) == text else { return nil }
      return OwlTraditionalPinSource(code: String(parts[0]), text: text, source: source)
    }
  }

  /// Require a complete, unconfirmed full-pinyin composition. Initials, completions,
  /// partially selected sentences, non-Han candidates and other schemas are excluded.
  static func target(schema: String, input: String, composition: RimeComposition,
                     candidate: String, traditional: Bool, caret: Int) -> OwlPinnedWord? {
    guard schema == "rime_ice", composition.selStart == 0, caret == input.utf8.count,
          !input.isEmpty, input.utf8.allSatisfy({ (97...122).contains($0) || $0 == 39 }),
          !candidate.isEmpty, candidate.unicodeScalars.allSatisfy({
            (0x3400...0x9FFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value)
          }) else { return nil }
    let syllables = composition.preedit.split(whereSeparator: { $0 == " " || $0 == "'" }).map { normalizedPinyin(String($0)) }
    guard syllables.count == candidate.count, syllables.allSatisfy({ fullSyllables.contains($0) }),
          syllables.joined() == normalizedPinyin(input.replacingOccurrences(of: "'", with: "")) else { return nil }
    return OwlPinnedWord(code: input, text: candidate, traditional: traditional)
  }

  /// rime_ice displays jv as ju and lue/nue as lve/nve; user preedit may display ü.
  /// Normalize only spelling for eligibility. Persist the original code so pins remain exact.
  private static func normalizedPinyin(_ value: String) -> String {
    var result = value.replacingOccurrences(of: "ü", with: "v")
    for initial in ["j", "q", "x", "y"] {
      result = result.replacingOccurrences(of: initial + "v", with: initial + "u")
    }
    for initial in ["n", "l"] {
      result = result.replacingOccurrences(of: initial + "ue", with: initial + "ve")
    }
    return result
  }

  private static let fullSyllables: Set<String> = Set("""
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
    ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
    da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
    e ei en eng er fa fan fang fei fen feng fo fou fu
    ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
    ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
    ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
    ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
    la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve
    ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
    na nai nan nang nao ne nei nen neng ng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve
    o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
    qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
    ran rang rao re ren reng ri rong rou ru ruan rui run ruo
    sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
    ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
    wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
    ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
    za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
