import XCTest
@testable import Owltype

@MainActor
final class OwlTemplateTemporalTests: XCTestCase {
  private func entry(_ body: String) -> OwlTemplateEntry {
    var entry = OwlTemplateEntry(title: "合成日期模板", body: body)
    entry.bodyType = .template
    return entry
  }

  private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

  private func temporal(_ iso: String = "2024-01-30T23:45:06Z", zone: String = "UTC",
                        locale: String = "en_US_POSIX", identifier: Calendar.Identifier = .gregorian,
                        firstWeekday: Int = 2, minimumDays: Int = 4) -> OwlTemplateEngine.Temporal {
    var calendar = Calendar(identifier: identifier)
    calendar.firstWeekday = firstWeekday
    calendar.minimumDaysInFirstWeek = minimumDays
    return .init(date: date(iso), timeZone: TimeZone(identifier: zone)!,
                 locale: Locale(identifier: locale), calendar: calendar)
  }

  private func render(_ body: String, _ snapshot: OwlTemplateEngine.Temporal? = nil) -> OwlTemplateEngine.Evaluation {
    OwlTemplateEngine.render(OwlTemplateEngine.parse(entry(body)), values: [:],
                             context: .init(temporal: snapshot ?? temporal()))
  }

  private func field(_ format: String = "yyyy-MM-dd HH:mm", offset: String? = nil, kind: String = "datetime") -> String {
    "{" + kind + " format=" + OwlTemplateEngine.quoted(format)
      + (offset.map { " offset=" + OwlTemplateEngine.quoted($0) } ?? "") + "}"
  }

  private func invocation(_ template: OwlTemplateEntry,
                          capture: @escaping (Set<OwlTemplateEngine.Requirement>) -> OwlTemplateEngine.FrozenContext,
                          deliver: @escaping (String) -> Void = { _ in }) -> OwlTemplateInvocation {
    OwlTemplateInvocation(content: .template(template), broker: OwlPanelInsertionBroker(
      captureFrontmost: { nil }, pasteboardWrite: { _ in XCTFail("must not write clipboard"); return false }),
      deliver: { deliver($0.text); return .confirmed }, captureContext: capture)
  }

  func testThreeFieldKindsUseExplicitFormatsAndSameBaseDate() {
    let body = field("yyyy-MM-dd", kind: "date") + "/" + field("HH:mm:ss", kind: "time")
      + "/" + field("yyyy-MM-dd'T'HH:mm:ssXXX")
    XCTAssertEqual(render(body).readyText, "2024-01-30/23:45:06/2024-01-30T23:45:06Z")
    // Kind selects only the default format; custom patterns may mix date and time.
    XCTAssertEqual(render(field("yyyy-MM-dd HH:mm", kind: "time")).readyText, "2024-01-30 23:45")
  }

  func testCommonUnicodePatternsAndQuotedLiteralsAreNotRejected() {
    let cases = [
      ("EEEE, MMM d, yyyy", "Tuesday, Jan 30, 2024"), ("LLLL", "January"),
      ("QQQQ", "1st quarter"), ("yyyyy", "02024"), ("SSS", "000"),
      ("yyyy年M月d日 🙂", "2024年1月30日 🙂"), ("'o''clock' HH:mm", "o'clock 23:45"),
      ("'待定'", "待定"), ("'{{argument}}'", "{{argument}}"), ("''", "'"),
      ("yyyy 'at' HH:mm", "2024 at 23:45"), ("X XXX XXXXX", "Z Z Z")
    ]
    for (pattern, expected) in cases {
      let evaluation = render(field(pattern))
      XCTAssertTrue(evaluation.diagnostics.isEmpty, pattern)
      XCTAssertEqual(evaluation.readyText, expected, pattern)
    }
    for pattern in ["G y Y u U r Q q M L w W d D F g E e c a b B h H K k m s S A z Z O v V X x",
                    "MMMMM EEEEEE cc cccccc OOOO vvvv VVVV ZZZZZ xxxxx", "YYYY-'W'ww-e", "Ml"] {
      let evaluation = render(field(pattern))
      XCTAssertNotNil(evaluation.readyText, pattern)
      XCTAssertTrue(evaluation.diagnostics.isEmpty, pattern)
    }
  }

  func testInvalidPatternsBlockAndLocateOriginalUnicodeField() {
    for pattern in ["", "yyyy 'unfinished", "i", "jmm", "J", "C", "MMMMMM", "ccccccc", "OO", "XXXXXX"] {
      let token = field(pattern)
      let body = "中文🙂 " + token
      let parsed = OwlTemplateEngine.parse(entry(body))
      let errors = parsed.diagnostics.filter { $0.severity == .error }
      XCTAssertEqual(errors.count, 1, pattern)
      XCTAssertEqual(errors.first?.range, (body as NSString).range(of: token), pattern)
      XCTAssertNil(render(body).readyText, pattern)
      XCTAssertEqual(render(body).previewText, body, pattern)
      XCTAssertTrue(parsed.contextRequirements.isEmpty, "invalid syntax must not need a clock")
    }
    for body in ["{date format=yyyy format=MM}", "{date locale=en-US}", "{date offset=+1d wat=x}"] {
      XCTAssertNil(render(body).readyText, body)
    }
  }

  func testOffsetsDistinguishMinutesMonthsAndPreserveOrderAndRepetition() {
    let cases = [("+1m", "2024-01-30 23:46"), ("+1M", "2024-02-29 23:45"),
                 ("+1M +1d", "2024-03-01 23:45"), ("+1d +1M", "2024-02-29 23:45"),
                 (" +0d\t-0m ", "2024-01-30 23:45")]
    for (offset, expected) in cases { XCTAssertEqual(render(field(offset: offset)).readyText, expected, offset) }
    let end = temporal("2024-01-31T12:00:00Z")
    XCTAssertEqual(render(field(offset: "+1M +1M"), end).readyText, "2024-03-29 12:00")
    XCTAssertEqual(render(field(offset: "+2M"), end).readyText, "2024-03-31 12:00")
    XCTAssertEqual(render(field(offset: "+1d") + "/" + field()).readyText, "2024-01-31 23:45/2024-01-30 23:45")
  }

  func testLeapDaysNegativeOffsetsAndYearBoundaries() {
    let cases = [("2024-02-29T12:00:00Z", "+1y", "2025-02-28 12:00"),
                 ("2024-03-31T12:00:00Z", "-1M", "2024-02-29 12:00"),
                 ("2023-01-31T12:00:00Z", "+1M", "2023-02-28 12:00"),
                 ("2024-12-31T23:45:00Z", "+30m", "2025-01-01 00:15"),
                 ("2024-01-01T00:15:00Z", "-30m", "2023-12-31 23:45")]
    for (iso, offset, expected) in cases { XCTAssertEqual(render(field(offset: offset), temporal(iso)).readyText, expected) }
  }

  func testInvalidOffsetsAndOverflowDoNotSilentlyClampOrPartiallyExpand() {
    for offset in ["", " ", "2d", "+ 2d", "+1.5h", "+1w", "+1D", "+1m+2d", "+1d garbage", "+１d",
                   "+9223372036854775808d", "-9223372036854775808d", "+2147483648M", "-2147483649y"] {
      let body = field(offset: offset)
      let evaluation = render(body)
      XCTAssertNil(evaluation.readyText, offset)
      XCTAssertEqual(evaluation.previewText, body, offset)
      XCTAssertTrue(evaluation.diagnostics.contains { $0.severity == .error }, offset)
    }
    XCTAssertNil(render(field(offset: "+2147483647y")).readyText, "result outside Foundation calendar domain must not be rendered")
  }

  func testTimeZoneMidnightBoundaryUsesOneAbsoluteInstant() {
    for (zone, expected) in [("UTC", "2024-01-01 00:30"), ("Asia/Shanghai", "2024-01-01 08:30"),
                             ("America/Los_Angeles", "2023-12-31 16:30")] {
      XCTAssertEqual(render(field(), temporal("2024-01-01T00:30:00Z", zone: zone)).readyText, expected)
    }
  }

  func testSpringDSTCalendarDayDiffersFromTwentyFourHours() {
    let snapshot = temporal("2024-03-09T20:00:00Z", zone: "America/Los_Angeles")
    XCTAssertEqual(render(field(offset: "+1d"), snapshot).readyText, "2024-03-10 12:00")
    XCTAssertEqual(render(field(offset: "+24h"), snapshot).readyText, "2024-03-10 13:00")
    XCTAssertEqual(render(field("yyyy-MM-dd HH:mm XXX", offset: "+1h"),
                          temporal("2024-03-10T09:30:00Z", zone: "America/Los_Angeles")).readyText,
                   "2024-03-10 03:30 -07:00")
  }

  func testAutumnDSTKeepsNamedTimeZoneRulesAndRepeatedHour() {
    let snapshot = temporal("2024-11-02T19:00:00Z", zone: "America/Los_Angeles")
    XCTAssertEqual(render(field(offset: "+1d"), snapshot).readyText, "2024-11-03 12:00")
    XCTAssertEqual(render(field(offset: "+24h"), snapshot).readyText, "2024-11-03 11:00")
    XCTAssertEqual(render(field("yyyy-MM-dd HH:mm XXX", offset: "+1h"),
                          temporal("2024-11-03T08:30:00Z", zone: "America/Los_Angeles")).readyText,
                   "2024-11-03 01:30 -08:00")
  }

  func testFrozenCalendarIncludesWeekRulesAndNonGregorianYear() {
    XCTAssertEqual(render(field("yyyy YYYY-'W'ww-e"), temporal("2019-12-30T12:00:00Z")).readyText,
                   "2019 2020-W01-1")
    let buddhist = temporal("2024-01-01T12:00:00Z", identifier: .buddhist)
    XCTAssertEqual(render(field("yyyy-MM-dd"), buddhist).readyText, "2567-01-01")
    XCTAssertEqual(buddhist.calendar.firstWeekday, 2)
    XCTAssertEqual(buddhist.calendar.minimumDaysInFirstWeek, 4)
    XCTAssertEqual(buddhist.calendar.timeZone, buddhist.timeZone)
  }

  func testWeekFieldsUseFrozenCalendarRulesInsteadOfLocaleDefaults() {
    // US locale normally starts on Sunday/minimum 1; these calendar rules are ISO-like.
    let isoRules = temporal("2017-01-01T12:00:00Z")
    XCTAssertEqual(render(field("yyyy YYYY-'W'ww-e ee c cc W"), isoRules).readyText,
                   "2017 2016-W52-7 07 7 7 0")
    // Keep Monday fixed and vary only minimumDays; weekday numbering cannot detect this bug.
    let minimumOne = temporal("2017-01-01T12:00:00Z", minimumDays: 1)
    XCTAssertEqual(render(field("YYYY-'W'ww-e W"), minimumOne).readyText, "2017-W01-7 1")
    // Reverse mismatch: UK locale normally uses Monday/minimum 4, calendar says Sunday/1.
    let usRules = temporal("2017-01-01T12:00:00Z", locale: "en_GB", firstWeekday: 1, minimumDays: 1)
    XCTAssertEqual(render(field("YYYY-'W'ww-e W"), usRules).readyText, "2017-W01-1 1")
    XCTAssertEqual(render(field("YY YYYYY 'Y w e c W' 'o''clock' e"), isoRules).readyText,
                   "16 02016 Y w e c W o'clock 7")
    XCTAssertEqual(render(field("YYYY'W'ww"), isoRules).readyText, "2016W52")
    XCTAssertEqual(render(field("YYYY-'W'ww-e", offset: "+1d"), isoRules).readyText, "2017-W01-1")
    let arabicDigits = temporal("2017-01-01T12:00:00Z", locale: "en_US@numbers=arab")
    XCTAssertEqual(render(field("YYYY-'W'ww-e ee c cc W"), arabicDigits).readyText,
                   "٢٠١٦-W٥٢-٧ ٠٧ ٧ ٧ ٠")
  }

  func testWeekPatternAdapterPreservesQuotesRepeatedFieldsAndWeekdayNames() {
    let snapshot = temporal("2017-01-01T12:00:00Z")
    let cases = [("yyyy''MM", "2017'01"), ("YYYY''ww", "2016'52"), ("YYYY''''ww", "2016''52"),
                 ("'Y'YYYY''ww'ee'e", "Y2016'52ee7"), ("YYYYwwYww-e-e", "201652201652-7-7"),
                 ("e ee eee eeee eeeee eeeeee", "7 07 Sun Sunday S Su"),
                 ("c cc ccc cccc ccccc cccccc", "7 7 Sun Sunday S Su")]
    for (pattern, expected) in cases {
      XCTAssertEqual(render(field(pattern), snapshot).readyText, expected, pattern)
    }
  }

  func testDefaultsFollowCapturedLocaleCalendarAndTimeZone() {
    for locale in ["zh_CN", "en_US", "en_GB"] {
      let snapshot = temporal(locale: locale)
      for kind in OwlTemplateEngine.TemporalKind.allCases {
        let reference = DateFormatter()
        reference.locale = snapshot.locale
        reference.calendar = snapshot.calendar
        reference.timeZone = snapshot.timeZone
        reference.dateStyle = kind == .time ? .none : .medium
        reference.timeStyle = kind == .date ? .none : .short
        XCTAssertEqual(render("{\(kind.rawValue)}", snapshot).readyText, reference.string(from: snapshot.date))
      }
    }
  }

  func testMissingOrInvalidContextBlocksWithoutFallbackToRealClock() {
    let parsed = OwlTemplateEngine.parse(entry(field()))
    XCTAssertNil(OwlTemplateEngine.render(parsed, values: [:]).readyText)
    for interval in [Double.nan, Double.infinity, -Double.infinity, 15927175497601, -211845067201] {
      let base = temporal()
      let invalid = OwlTemplateEngine.Temporal(date: Date(timeIntervalSinceReferenceDate: interval),
        timeZone: base.timeZone, locale: base.locale, calendar: base.calendar)
      XCTAssertNil(render(field(), invalid).readyText)
      XCTAssertEqual(render(field(), invalid).previewText, field())
    }
  }

  func testContextProviderReadsOnlyRequestedResourcesOnce() {
    var reads = [0, 0, 0, 0, 0]
    let snapshot = temporal()
    func capture(_ requirements: Set<OwlTemplateEngine.Requirement>) -> OwlTemplateEngine.FrozenContext {
      OwlTemplateContextCapture.capture(requirements,
        readClipboard: { reads[0] += 1; return "材料" }, now: { reads[1] += 1; return snapshot.date },
        timeZone: { reads[2] += 1; return snapshot.timeZone }, locale: { reads[3] += 1; return snapshot.locale },
        calendar: { reads[4] += 1; return snapshot.calendar })
    }
    XCTAssertNil(capture([]).temporal)
    XCTAssertEqual(reads, [0, 0, 0, 0, 0])
    XCTAssertEqual(capture([.clipboard]).clipboard, .text("材料"))
    XCTAssertEqual(reads, [1, 0, 0, 0, 0])
    XCTAssertNotNil(capture([.temporal]).temporal)
    XCTAssertEqual(reads, [1, 1, 1, 1, 1])
    XCTAssertNotNil(capture([.clipboard, .temporal]).temporal)
    XCTAssertEqual(reads, [2, 2, 2, 2, 2])
  }

  func testSameInvocationFreezesClockLocaleCalendarZoneAcrossFillAndConfirm() {
    let template = entry(field("yyyy-MM-dd HH:mm") + " {date} {argument name=x}")
    var source = temporal()
    var captures = 0
    var delivered: [String] = []
    let call = invocation(template, capture: { requirements in
      captures += 1
      XCTAssertEqual(requirements, [.temporal])
      return .init(temporal: source)
    }, deliver: { delivered.append($0) })
    XCTAssertEqual(captures, 0)
    let fill = OwlPromptFillModel(template: template, invocation: call)
    XCTAssertFalse(fill.canConfirm)
    fill.values["n:x"] = "目标"
    let preview = fill.filledBody
    source = temporal("2030-06-15T09:00:00Z", zone: "Asia/Shanghai", locale: "th_TH", identifier: .buddhist)
    XCTAssertEqual(fill.filledBody, preview)
    XCTAssertTrue(call.confirm(values: fill.values))
    XCTAssertFalse(call.confirm(values: fill.values))
    XCTAssertEqual(delivered, [preview])
    XCTAssertEqual(captures, 1)
    let next = invocation(template, capture: { _ in captures += 1; return .init(temporal: source) })
    XCTAssertNotEqual(next.preview(values: fill.values).text, preview)
    XCTAssertEqual(captures, 2)
  }

  func testDateAndEmptyClipboardShareFreezeAndExplicitChoice() {
    let template = entry("{clipboard}|" + field("yyyy-MM-dd") + "|{argument name=x}")
    var snapshot = temporal()
    var clipboard: String? = nil
    var captures = 0
    var delivered: [String] = []
    let call = invocation(template, capture: { requirements in
      captures += 1
      return OwlTemplateContextCapture.capture(requirements, readClipboard: { clipboard }, now: { snapshot.date },
        timeZone: { snapshot.timeZone }, locale: { snapshot.locale }, calendar: { snapshot.calendar })
    }, deliver: { delivered.append($0) })
    let fill = OwlPromptFillModel(template: template, invocation: call)
    XCTAssertTrue(fill.evaluation.needsEmptyClipboardDecision)
    clipboard = "B"
    snapshot = temporal("2030-06-15T09:00:00Z")
    fill.continueWithEmptyClipboard()
    XCTAssertFalse(fill.canConfirm, "empty decision must not bypass required parameters")
    fill.values["n:x"] = "{date}"
    XCTAssertEqual(fill.filledBody, "|2024-01-30|{date}")
    XCTAssertTrue(delivered.isEmpty)
    XCTAssertTrue(call.confirm(values: fill.values))
    XCTAssertEqual(delivered, ["|2024-01-30|{date}"])
    XCTAssertEqual(captures, 1)
  }

  func testA3NonemptyClipboardAndDateRemainFrozenWhileFilling() {
    let template = entry("{clipboard}|" + field("yyyy-MM-dd") + "|{argument name=x}|{clipboard}")
    var snapshot = temporal()
    var clipboard = "合成 A {date}"
    var clockReads = 0
    var clipboardReads = 0
    var delivered: [String] = []
    let call = invocation(template, capture: { requirements in
      OwlTemplateContextCapture.capture(requirements,
        readClipboard: { clipboardReads += 1; return clipboard }, now: { clockReads += 1; return snapshot.date },
        timeZone: { snapshot.timeZone }, locale: { snapshot.locale }, calendar: { snapshot.calendar })
    }, deliver: { delivered.append($0) })
    let fill = OwlPromptFillModel(template: template, invocation: call)
    XCTAssertFalse(fill.evaluation.needsEmptyClipboardDecision)
    XCTAssertFalse(fill.canConfirm)
    clipboard = "合成 B"
    snapshot = temporal("2030-06-15T09:00:00Z")
    fill.values["n:x"] = "解释"
    let preview = fill.filledBody
    XCTAssertEqual(preview, "合成 A {date}|2024-01-30|解释|合成 A {date}")
    XCTAssertTrue(call.confirm(values: fill.values))
    XCTAssertEqual(delivered, [preview])
    XCTAssertEqual(clockReads, 1)
    XCTAssertEqual(clipboardReads, 1)
  }

  func testPlainLegacySearchAndCancelledCallsNeverCaptureTime() {
    var plain = entry("{date offset=broken}"); plain.bodyType = .plainText
    var legacy = entry("{date} {{date}}"); legacy.syntax = .legacyDoubleBraces
    for template in [plain, legacy, entry("{argument name=date default=A}")] {
      let call = invocation(template, capture: { _ in XCTFail("no temporal requirements"); return .init() })
      XCTAssertNotNil(call.evaluate(values: call.initialValues).readyText)
    }
    let template = entry(field())
    let call = invocation(template, capture: { _ in XCTFail("search/cancel must not capture"); return .init() })
    var picker = OwlPickerPanelModel(rows: [.template(template)])
    picker.setQuery("date")
    picker.select(0)
    XCTAssertEqual(call.content.body, template.body)
    call.cancel()
    call.prepareForResultPreview()
    XCTAssertFalse(call.confirm(values: [:]))
  }

  func testSaveReopenPickerAndCandidateUseDateOnlyAndParameterTemplates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwlTemporalTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for parameterized in [false, true] {
      var template = entry(field("yyyy-MM-dd") + (parameterized ? " {argument name=x}" : ""))
      template.trigger = "day"
      template.candidateAliases = ["vday"]
      template.invocationMode = .candidate
      try OwlTemplateStore.save(.init(entries: [template]), writer: OwlConfigWriter(rimeDir: root))
      let library = try OwlTemplateStore.load(rimeDir: root)
      XCTAssertEqual(library.entries.first?.body, template.body)
      var picker = OwlPickerPanelModel(rows: library.entries.map(OwlPickerRow.template))
      picker.setQuery("yyyy")
      let picked = try XCTUnwrap(library.entries.first { $0.id.uuidString == picker.selectedRow?.id })
      let candidate = try XCTUnwrap(OwlTemplateStore.resolveCandidate(code: "vday",
        text: OwlTemplateStore.candidateText(template), loadLibrary: { library }))
      for selected in [picked, candidate] {
        var delivered: [String] = []
        var captures = 0
        let snapshot = temporal()
        let call = invocation(selected, capture: { _ in captures += 1; return .init(temporal: snapshot) },
                              deliver: { delivered.append($0) })
        var presented = false
        call.start { _ in presented = true }
        XCTAssertEqual(presented, parameterized)
        if parameterized {
          XCTAssertTrue(delivered.isEmpty)
          XCTAssertFalse(call.confirm(values: [:]))
          XCTAssertTrue(call.confirm(values: ["n:x": "目标"]))
        }
        XCTAssertEqual(delivered, [parameterized ? "2024-01-30 目标" : "2024-01-30"])
        XCTAssertEqual(captures, 1)
      }
    }
  }
}
