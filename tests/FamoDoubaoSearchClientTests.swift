//
//  FamoDoubaoSearchClientTests.swift
//  FamoTests — 豆包搜索 Global 版检索传输
//
//  这条链路最危险的失败不是崩，而是**静默地假联网**：检索被拒（HTTP 200 + 业务错误码）或一条结果都
//  没搜到时，如果照常往下走，主模型就会凭训练知识作答，而 AI 窗的署名 chip 仍写着「联网 · 豆包搜索」。
//  下面的断言就是钉住「失败必须是失败」，以及失败到底该顺位还是该报错。
//
//  No socket: `dataProvider` 注入脚本化的 (Data, HTTPURLResponse)。
//

import Foundation
import XCTest
@testable import Famo

final class FamoDoubaoSearchClientTests: XCTestCase {

  // MARK: - Fixtures

  private let endpoint = URL(string: "https://open.feedcoopapi.com/search_api/global_search")!

  private var routing: FamoCloudRouting {
    FamoSearchCredential.doubaoSearch.routing
  }

  /// 官方文档的正常响应示例，裁到我们真读的字段（含一个 image 片段——必须被丢掉）。
  private let okBody = """
    {
      "ResponseMetadata": { "RequestId": "20260622120000A1B2C3D4E5F6" },
      "Result": {
        "TotalDocCount": 20,
        "Documents": [
          {
            "Rank": 0,
            "Url": "https://m.baike.com/wiki/x",
            "Title": "天安门",
            "Snippet": [
              { "Type": "text", "Text": "天安门是紫禁城的重要建筑" },
              { "Type": "image", "Image": { "Width": 1136, "Height": 565, "ImageUrl": "https://img/x.jpg" } },
              { "Type": "text", "Text": "始建于明永乐十五年" }
            ],
            "DocumentInfo": { "Filetype": "webpage", "PublishTime": "2026-06-01" },
            "HostInfo": { "Hostname": "抖音百科" }
          }
        ],
        "ErrorCode": 0,
        "ErrorMsg": ""
      }
    }
    """

  private func makeClient(
    status: Int = 200,
    body: String,
    onRequest: (@Sendable (URLRequest) -> Void)? = nil
  ) -> FamoDoubaoSearchClient {
    let url = endpoint
    return FamoDoubaoSearchClient(dataProvider: { request in
      onRequest?(request)
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (Data(body.utf8), response)
    })
  }

  // MARK: - 解析

  func testDecodeKeepsTextSnippetsAndDropsImages() throws {
    let documents = try FamoDoubaoSearchClient.decode(Data(okBody.utf8))

    XCTAssertEqual(documents.count, 1)
    let doc = documents[0]
    XCTAssertEqual(doc.title, "天安门")
    XCTAssertEqual(doc.url, "https://m.baike.com/wiki/x")
    XCTAssertEqual(doc.hostname, "抖音百科")
    XCTAssertEqual(doc.publishTime, "2026-06-01")
    XCTAssertEqual(
      doc.snippet, "天安门是紫禁城的重要建筑\n始建于明永乐十五年",
      "文本片段按序拼接；图片片段对一段文字答案没用，必须丢掉")
  }

  /// 业务错误可以带着 HTTP 200 回来 —— 只看状态码就会把失败当成「搜到 0 条」。
  func testDecodeSurfacesMetadataErrorDespiteHTTP200() {
    let body = """
      {
        "ResponseMetadata": {
          "RequestId": "r1",
          "Error": { "CodeN": 10403, "Code": "10403", "Message": "account not authorized" }
        },
        "Result": null
      }
      """
    XCTAssertThrowsError(try FamoDoubaoSearchClient.decode(Data(body.utf8))) { error in
      XCTAssertEqual(
        error as? FamoWebRetrievalError,
        .apiError(code: 10403, message: "account not authorized"))
      XCTAssertEqual(
        (error as? FamoWebRetrievalError)?.isRouteUnusable, true,
        "账号/权限错误换一家才有戏，必须顺位")
    }
  }

  func testDecodeSurfacesResultErrorCode() {
    let body = """
      { "ResponseMetadata": { "RequestId": "r1" },
        "Result": { "TotalDocCount": 0, "Documents": [], "ErrorCode": 10412, "ErrorMsg": "quota exhausted" } }
      """
    XCTAssertThrowsError(try FamoDoubaoSearchClient.decode(Data(body.utf8))) { error in
      XCTAssertEqual(
        error as? FamoWebRetrievalError,
        .apiError(code: 10412, message: "quota exhausted"),
        "额度不足写在 Result.ErrorCode 里，也要当失败")
    }
  }

  func testDecodeTreatsZeroDocumentsAsFailure() {
    let body = """
      { "ResponseMetadata": { "RequestId": "r1" },
        "Result": { "TotalDocCount": 0, "Documents": [], "ErrorCode": 0, "ErrorMsg": "" } }
      """
    XCTAssertThrowsError(try FamoDoubaoSearchClient.decode(Data(body.utf8))) { error in
      XCTAssertEqual(error as? FamoWebRetrievalError, .emptyResults,
                     "0 条结果注入空资料 = 让主模型凭记忆作答却署名联网，必须当失败")
    }
  }

  func testDecodeRejectsNonJSONBody() {
    XCTAssertThrowsError(try FamoDoubaoSearchClient.decode(Data("<html>502</html>".utf8))) { error in
      XCTAssertEqual(error as? FamoWebRetrievalError, .malformedResponse)
    }
  }

  /// 内部错误 / 限流是**暂时**的：顺位到别家只会把一个错误变成好几个。
  func testTransientAPICodesDoNotTriggerFailover() {
    for code in [10500, 10501, 700429] {
      let error = FamoWebRetrievalError.apiError(code: code, message: "later")
      XCTAssertFalse(error.isRouteUnusable, "\(code) 是暂时错误，不该顺位")
      XCTAssertFalse(
        FamoAskSearchFailover.shouldTryNextProvider(after: error),
        "\(code) 必须如实上报给用户")
    }
  }

  // MARK: - 请求构造

  func testRetrieveSendsBearerKeyAndBoundedRequestBody() async throws {
    let box = RequestRecorder()
    let client = makeClient(body: okBody, onRequest: { box.record($0) })
    _ = try await client.retrieve(query: "北京周边游玩景点推荐", routing: routing, apiKey: "pplx-not-used")

    let request = box.request
    XCTAssertEqual(request?.url, endpoint)
    XCTAssertEqual(request?.httpMethod, "POST")
    XCTAssertEqual(
      request?.value(forHTTPHeaderField: "Authorization"), "Bearer pplx-not-used",
      "豆包搜索只认 Bearer <联网搜索控制台 API Key>")
    guard let body = request?.httpBody,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return XCTFail("请求体必须是 JSON 对象")
    }
    XCTAssertEqual(object["Query"] as? String, "北京周边游玩景点推荐")
    XCTAssertEqual(object["DocCount"] as? Int, FamoDoubaoSearchClient.documentCount)
    XCTAssertEqual(object["MaxSnippetLength"] as? Int, FamoDoubaoSearchClient.maxSnippetLength)
  }

  func testRetrieveMapsNon2xxToBadHTTPStatus() async {
    let client = makeClient(status: 401, body: "{}")
    do {
      _ = try await client.retrieve(query: "q", routing: routing, apiKey: "bad")
      XCTFail("401 必须 throw")
    } catch {
      XCTAssertEqual(error as? FamoWebRetrievalError, .badHTTPStatus(401))
      XCTAssertTrue(
        FamoAskSearchFailover.shouldTryNextProvider(after: error),
        "Key 失效要顺位到下一家，而不是让这一问失败")
    }
  }

  // MARK: - query 归一化

  func testQueryCollapsesWhitespaceAndClampsToEndpointLimit() {
    XCTAssertEqual(
      FamoWebRetrievalPrompt.query(from: "  合同  解除\n的\t条件 "), "合同 解除 的 条件",
      "多行/连续空白原样发过去等于多词搜索，端点不支持")

    let long = String(repeating: "长", count: 250)
    XCTAssertEqual(
      FamoWebRetrievalPrompt.query(from: long).count, FamoWebRetrievalPrompt.maxQueryLength,
      "端点上限 100 字符，自己先截干净")
  }

  // MARK: - 注入 prompt

  func testAugmentPrependsTheBlockToTheLastUserMessageOnly() throws {
    let documents = try FamoDoubaoSearchClient.decode(Data(okBody.utf8))
    let messages = [
      FamoDeepSeekMessage(role: "system", content: "系统提示"),
      FamoDeepSeekMessage(role: "user", content: "第一问"),
      FamoDeepSeekMessage(role: "assistant", content: "第一答"),
      FamoDeepSeekMessage(role: "user", content: "天安门什么时候建的？"),
    ]

    let augmented = FamoWebRetrievalPrompt.augment(
      messages: messages, documents: documents, sourceName: "豆包搜索")

    XCTAssertEqual(augmented.count, messages.count, "只改写最后一问，不新增消息")
    XCTAssertEqual(augmented.map(\.role), messages.map(\.role), "角色序列不能变")
    XCTAssertEqual(augmented[0].content, "系统提示", "system 消息不受影响")
    XCTAssertEqual(augmented[1].content, "第一问", "历史轮不受影响")
    let last = augmented[3].content
    XCTAssertTrue(last.contains("豆包搜索"), "资料块要写明检索来源")
    XCTAssertTrue(last.contains("天安门是紫禁城的重要建筑"), "摘要必须真的进 prompt")
    XCTAssertTrue(last.contains("https://m.baike.com/wiki/x"), "URL 要在，答案才能标引用")
    XCTAssertTrue(last.hasSuffix("天安门什么时候建的？"), "用户原话仍在最后，资料在前")
  }

  func testAugmentWithoutDocumentsLeavesMessagesUntouched() {
    let messages = [FamoDeepSeekMessage(role: "user", content: "q")]
    XCTAssertEqual(
      FamoWebRetrievalPrompt.augment(messages: messages, documents: [], sourceName: "豆包搜索"),
      messages)
  }
}

/// Carries the captured `URLRequest` out of the (`@Sendable`) data provider closure.
private final class RequestRecorder: @unchecked Sendable {
  private(set) var request: URLRequest?
  func record(_ request: URLRequest) { self.request = request }
}
