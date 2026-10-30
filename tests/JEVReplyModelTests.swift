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
        return try JSONSerialization.data(withJSONObject: ["ok": true, "reply_style": style])
      }
      return try JSONSerialization.data(withJSONObject: ["ok": true,
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
      Data(#"{"ok":true,"request_id":"other","candidates":[{"text":"旧结果"}]}"#.utf8)
    }
    model.ready = true
    await waitForIdle(model) { model.generate() }
    XCTAssertFalse(model.busy)
    XCTAssertTrue(model.candidates.isEmpty)
    XCTAssertTrue(model.status.contains("未能取得"))
  }
}
