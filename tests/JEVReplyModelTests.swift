import XCTest
import Combine
@testable import Owltype

@MainActor
final class JEVReplyModelTests: XCTestCase {
  private func waitForIdle(_ model: JEVReplyModel, action: () -> Void) async {
    let done = expectation(description: "request completes")
    let token = model.$busy.drop(while: { !$0 }).filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
    action()
    await fulfillment(of: [done], timeout: 3)
    withExtendedLifetime(token) {}
  }

  func testMatchingReplyAppearsAndChangedInputsClearIt() async {
    let model = JEVReplyModel(text: "合成消息", source: "owltype-selection") { data in
      let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      if request["operation"] as? String == "preferences" {
        let style = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JEVStyle()))
        return try JSONSerialization.data(withJSONObject: ["version": 1, "ok": true, "reply_style": style])
      }
      return try JSONSerialization.data(withJSONObject: ["version": 1, "ok": true,
        "request_id": request["request_id"]!, "verdict": ["intent": "闲聊"],
        "candidates": [["text": "候选一"], ["text": "候选二"]]])
    }
    await waitForIdle(model) { model.load() }
    await waitForIdle(model) { model.generate() }
    XCTAssertEqual(model.candidates, ["候选一", "候选二"])
    model.invalidate()
    XCTAssertTrue(model.candidates.isEmpty)
  }

  func testWrongRequestIdentityIsRejectedWithoutPermanentSpinner() async {
    let model = JEVReplyModel(text: "合成消息", source: "pallas-selection") { _ in
      Data(#"{"version":1,"ok":true,"request_id":"other","candidates":[{"text":"旧结果"}]}"#.utf8)
    }
    model.ready = true
    await waitForIdle(model) { model.generate() }
    XCTAssertFalse(model.busy)
    XCTAssertTrue(model.candidates.isEmpty)
    XCTAssertTrue(model.status.contains("未能取得"))
  }
  func testMalformedPreferencesReportFailureWithoutCrash() async {
    for payload in [#"{"version":1,"ok":true}"#, #"{"version":1,"ok":true,"reply_style":null}"#, #"{"version":1,"ok":true,"reply_style":3}"#] {
      let model = JEVReplyModel(text: "合成消息", source: "pallas-selection") { _ in Data(payload.utf8) }
      await waitForIdle(model) { model.load() }
      XCTAssertFalse(model.ready)
      XCTAssertFalse(model.busy)
    }
  }

  func testExcessiveInstructionsAreNotSubmitted() {
    let model = JEVReplyModel(text: "合成消息", source: "pallas-selection") { _ in
      XCTFail("overlong request must not reach transport")
      throw JEVTransport.Failure.invalid
    }
    model.ready = true
    model.instructions = String(repeating: "a", count: 1001)
    model.generate()
    XCTAssertFalse(model.busy)
    XCTAssertFalse(model.canGenerate)
  }

  func testV1CompatibilityTableStatusSourceAndCandidateConstraints() async {
    // 1. status=needs_clarification with empty candidates -> actionable clarification status, no candidates
    let clarifyModel = JEVReplyModel(text: "合成消息", source: "owltype-selection") { data in
      let req = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      return try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "ok": true,
        "request_id": req["request_id"]!,
        "source": "owltype-selection",
        "status": "needs_clarification",
        "candidates": []
      ])
    }
    clarifyModel.ready = true
    clarifyModel.candidates = ["旧候选"]
    await waitForIdle(clarifyModel) { clarifyModel.generate() }
    XCTAssertTrue(clarifyModel.candidates.isEmpty)
    XCTAssertEqual(clarifyModel.status, "请补充这次想怎么回复，再重新生成候选。")

    // 2. status=ready with matching source and 3 trimmed candidates (up to 2000 scalars) succeeds
    let exact2000 = String(repeating: "好", count: 2000)
    let readyModel = JEVReplyModel(text: "合成消息", source: "owltype-selection") { data in
      let req = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      return try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "ok": true,
        "request_id": req["request_id"]!,
        "source": "owltype-selection",
        "status": "ready",
        "candidates": [
          ["text": "  候选一  \n"],
          ["text": exact2000],
          ["text": "候选三"]
        ]
      ])
    }
    readyModel.ready = true
    await waitForIdle(readyModel) { readyModel.generate() }
    XCTAssertEqual(readyModel.candidates, ["候选一", exact2000, "候选三"])

    // 3. Invalid status/source/candidate shapes reject the entire group without publishing partial candidates
    let over2000 = String(repeating: "长", count: 2001)
    let invalidPayloads: [([String: Any]) -> [String: Any]] = [
      // status is null
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "status": NSNull(), "candidates": [["text": "一"], ["text": "二"]]] },
      // status is wrong type / unknown value
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "status": "unknown", "candidates": [["text": "一"], ["text": "二"]]] },
      // needs_clarification with non-empty candidates
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "status": "needs_clarification", "candidates": [["text": "一"]]] },
      // source is null
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "source": NSNull(), "candidates": [["text": "一"], ["text": "二"]]] },
      // source is mismatched
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "source": "pallas-selection", "candidates": [["text": "一"], ["text": "二"]]] },
      // fewer than 2 candidates
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "candidates": [["text": "只有一个"]]] },
      // more than 3 candidates
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "candidates": [["text": "一"], ["text": "二"], ["text": "三"], ["text": "四"]]] },
      // duplicate after trimming
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "candidates": [["text": "相同"], ["text": " 相同 \n"]]] },
      // empty after trimming
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "candidates": [["text": "有效"], ["text": "   \n "]]] },
      // exceeds 2000 Unicode scalars after trimming
      { req in ["version": 1, "ok": true, "request_id": req["request_id"]!, "candidates": [["text": "有效"], ["text": over2000]]] }
    ]

    for makePayload in invalidPayloads {
      let model = JEVReplyModel(text: "合成消息", source: "owltype-selection") { data in
        let req = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: makePayload(req))
      }
      model.ready = true
      model.candidates = ["旧候选不应保留"]
      await waitForIdle(model) { model.generate() }
      XCTAssertTrue(model.candidates.isEmpty)
      XCTAssertTrue(model.status.contains("未能取得候选"))
    }
  }

  func testSafeFailureCodesAndLateCancelledResponseIsolation() async {
    let cases: [(String, JEVTransport.SafeReason)] = [
      ("paused", .paused),
      ("scenario_disabled", .scenarioDisabled),
      ("request_invalidated", .requestInvalidated),
      ("model_quota_exhausted", .modelQuotaExhausted),
      ("model_rate_limited", .modelRateLimited),
      ("unknown_code", .serviceUnavailable)
    ]
    for (code, reason) in cases {
      let model = JEVReplyModel(text: "待回复原文", source: "owltype-selection") { _ in
        try JSONSerialization.data(withJSONObject: [
          "version": 1,
          "ok": false,
          "code": code,
          "error": "upstream raw error"
        ])
      }
      model.ready = true
      model.instructions = "保留要求"
      model.candidates = ["之前候选"]
      await waitForIdle(model) { model.generate() }
      XCTAssertTrue(model.candidates.isEmpty)
      XCTAssertEqual(model.status, reason.message)
      XCTAssertFalse(model.status.contains("upstream raw error"))
    }

    // Late response after userEdited() is discarded and never overwrites state
    let started = expectation(description: "request started")
    let release = DispatchSemaphore(value: 0)
    let model = JEVReplyModel(text: "待回复原文", source: "owltype-selection") { data in
      let req = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      started.fulfill()
      _ = release.wait(timeout: .now() + 2)
      return try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "ok": true,
        "request_id": req["request_id"]!,
        "candidates": [["text": "迟到候选一"], ["text": "迟到候选二"]]
      ])
    }
    model.ready = true
    model.generate()
    await fulfillment(of: [started], timeout: 2)
    model.instructions = "修改后的要求"
    model.userEdited()
    XCTAssertFalse(model.busy)
    release.signal()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(model.candidates.isEmpty)
    XCTAssertEqual(model.status, "要求已修改，请重新生成候选。")
  }

}
