//
//  OwlLiveKeys.swift
//  OwltypeTests — 实盘测试读 Key 的唯一入口
//
//  Key 只从测试进程环境读，不读仓库外的 Key 文件或钥匙串。命令行用
//  `bash scripts/live-test.sh <测试名>`：它经 direnv 按项目 .envrc 的 `use secrets` 取 Key，
//  加 `TEST_RUNNER_` 前缀交给 xcodebuild（进测试进程时前缀被去掉）。IDE 里在 scheme 设同名变量。
//  scripts/live-test.sh 从下面的 case 读名字；新增 Key 只改这里，再把名字加进 .envrc。
//

import Foundation
import XCTest

enum OwlLiveKey: String, CaseIterable {
  case deepSeek = "DEEPSEEK_API_KEY"
  case doubaoSearch = "DOUBAO_SEARCH_API_KEY"
  case dashScope = "DASHSCOPE_API_KEY"
  case ark = "ARK_API_KEY"

  /// 缺 Key 时跳过；经 scripts/live-test.sh 点名运行时，跳过会让整次运行失败。
  func value() throws -> String {
    guard let key = ProcessInfo.processInfo.environment[rawValue]?
      .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
      throw XCTSkip("无 \(rawValue)，跳过实盘。用 bash scripts/live-test.sh <测试名> 运行")
    }
    return key
  }
}
