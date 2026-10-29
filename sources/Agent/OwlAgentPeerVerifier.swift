//
//  OwlAgentPeerVerifier.swift
//  Owltype
//
//  Admits a bridge connection only from this user's copy of Owltype's own helper:
//  1. `getpeereid` must report this user.
//  2. The peer's code, looked up by its audit token (not its pid, which can be reused), must be
//     valid and signed by the App's own Team ID with an `owltype-mcp` identifier.
//  A development build signed ad hoc has no Team ID; it then admits only the helper inside its
//  own bundle, matched by executable path and cdhash.
//

import Darwin
import Foundation
import Security

protocol OwlAgentPeerVerifying {
  /// The peer's pid when the connection may proceed, nil to refuse it.
  func admit(_ descriptor: Int32) -> pid_t?
}

struct OwlAgentPeerVerifier: OwlAgentPeerVerifying {
  /// What a peer's signature must show.
  enum Policy: Equatable {
    /// Same Team ID as the App, identifier `owltype-mcp…`.
    case team(String)
    /// Ad hoc App: the helper at this path in the App's own bundle, by cdhash.
    case bundledHelper(path: String, cdhash: Data)
    /// No trustworthy reference (the App's own signature is unreadable): refuse everyone.
    case refuseAll
  }

  static let helperIdentifierPrefix = "owltype-mcp"

  let policy: Policy

  init(policy: Policy = OwlAgentPeerVerifier.ownPolicy()) {
    self.policy = policy
  }

  /// Derived from the running App's signature.
  static func ownPolicy(bundle: Bundle = .main) -> Policy {
    var own: SecCode?
    var staticCode: SecStaticCode?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
          SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode,
          let info = signingInformation(staticCode) else { return .refuseAll }
    if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty { return .team(team) }
    let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/owltype-mcp").resolvingSymlinksInPath().path
    guard let helperInfo = staticSigningInformation(path: helper),
          let cdhash = helperInfo[kSecCodeInfoUnique as String] as? Data else { return .refuseAll }
    return .bundledHelper(path: helper, cdhash: cdhash)
  }

  func admit(_ descriptor: Int32) -> pid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else { return nil }
    guard let token = Self.auditToken(descriptor), let code = Self.guestCode(token) else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCheckValidity(code, [], nil) == errSecSuccess,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          let info = Self.signingInformation(staticCode),
          Self.allows(policy, info: info, path: Self.path(staticCode)) else { return nil }
    return Self.pid(descriptor)
  }

  /// The decision on a peer's signing information, separate so tests can drive it.
  static func allows(_ policy: Policy, info: [String: Any], path: String?) -> Bool {
    switch policy {
    case .refuseAll:
      return false
    case .team(let team):
      guard let identifier = info[kSecCodeInfoIdentifier as String] as? String else { return false }
      return info[kSecCodeInfoTeamIdentifier as String] as? String == team && identifier.hasPrefix(helperIdentifierPrefix)
    case .bundledHelper(let helperPath, let cdhash):
      return path == helperPath && info[kSecCodeInfoUnique as String] as? Data == cdhash
    }
  }

  private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
      return nil
    }
    return info as? [String: Any]
  }

  private static func staticSigningInformation(path: String) -> [String: Any]? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
      return nil
    }
    return signingInformation(code)
  }

  private static func path(_ code: SecStaticCode) -> String? {
    var url: CFURL?
    guard SecCodeCopyPath(code, [], &url) == errSecSuccess, let url else { return nil }
    return (url as URL).resolvingSymlinksInPath().path
  }

  private static func auditToken(_ descriptor: Int32) -> Data? {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
    return withUnsafeBytes(of: &token) { Data($0) }
  }

  private static func guestCode(_ token: Data) -> SecCode? {
    var code: SecCode?
    let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
    return code
  }

  private static func pid(_ descriptor: Int32) -> pid_t? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
    return pid
  }
}
