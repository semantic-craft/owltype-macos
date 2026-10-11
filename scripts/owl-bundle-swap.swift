import Foundation
import Darwin

/// Standalone driver compiled with installer/Shared/OwlBundleSwap.swift.
/// Does not register, enable, select, launch, terminate, or delete anything.
@main
enum OwlBundleSwapTool {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      switch arguments.first {
      case "exchange" where arguments.count == 2:
        let result = try OwlBundleSwap.exchangeContents(in: URL(fileURLWithPath: arguments[1]))
        print("exchanged: installed=\(result.installedContents.path) retired=\(result.retiredContents.path)")
      case "install" where arguments.count == 3:
        try OwlBundleSwap.publishFirstInstall(
          from: URL(fileURLWithPath: arguments[1]), to: URL(fileURLWithPath: arguments[2]))
        print("installed: \(arguments[2])")
      default:
        fputs("usage: owl-bundle-swap exchange APP | install STAGED_APP DESTINATION_APP\n", stderr)
        exit(64)
      }
    } catch {
      let error = error as NSError
      fputs("bundle swap failed: domain=\(error.domain) code=\(error.code) path=\(error.userInfo[NSFilePathErrorKey] ?? "")\n", stderr)
      exit(1)
    }
  }
}
