//
//  OwlAgentAccess.swift
//  Owltype
//
//  Agent access (#208): the switch, off by default, and the service behind OwlAgentBridge. The
//  bridge listens only while the switch is on; turning it off closes the socket and every open
//  connection. Started from Main.swift, never from the controller or engine.
//

import AppKit
import Foundation

enum OwlAgentAccessPreferences {
  static let enabledKey = "OwlAgentAccessEnabled"

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

  static func setEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: enabledKey) }
}

/// The redacted state `owltype_status` reports, gathered on the main thread.
struct OwlAgentInputSnapshot: Equatable {
  var schemaID: String
  var asciiMode: Bool
}

final class OwlAgentAccess: NSObject, OwlAgentBridgeService {
  typealias Wire = OwlAgentBridgeProtocol

  static let shared = OwlAgentAccess()

  private let defaults: UserDefaults
  private let bundle: Bundle
  /// Reads the input state; called on the main thread.
  var inputSnapshot: () -> OwlAgentInputSnapshot = {
    let controller = NSApp.owlAppDelegate.runtime.activatedInputController
    let schema = controller.map(\.schemaId).flatMap { $0.isEmpty ? nil : $0 } ?? OwlKeyboardPreferences.preferredSchemaID
    return OwlAgentInputSnapshot(schemaID: schema, asciiMode: controller?.engineSession?.option(.asciiMode) ?? false)
  }
  /// The active dictionary resource generation; called on the bridge queue.
  var resourceGeneration: () -> String = {
    (try? OwlRustResourceEnvironment.production().activeState()?.current.generationId) ?? "bundled"
  }
  /// The template library, read on the bridge queue; a library not yet migrated reads as empty.
  var loadLibrary: () throws -> OwlTemplateLibrary = {
    OwlTemplateStore.mode() == .unified ? try OwlTemplateStore.load() : OwlTemplateLibrary()
  }
  private(set) var bridge: OwlAgentBridge?
  private var makeBridge: (OwlAgentAccess) -> OwlAgentBridge = {
    OwlAgentBridge(verifier: OwlAgentPeerVerifier(), service: $0)
  }

  init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
    self.defaults = defaults
    self.bundle = bundle
    super.init()
  }

  /// Follows the switch from now on; `bridgeFactory` replaces the production socket in tests.
  func start(bridgeFactory: ((OwlAgentAccess) -> OwlAgentBridge)? = nil) {
    if let bridgeFactory { makeBridge = bridgeFactory }
    defaults.addObserver(self, forKeyPath: OwlAgentAccessPreferences.enabledKey, options: [.new], context: nil)
    apply()
  }

  func stopFollowing() {
    defaults.removeObserver(self, forKeyPath: OwlAgentAccessPreferences.enabledKey)
    bridge?.stop()
    bridge = nil
  }

  // swiftlint:disable:next block_based_kvo
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                             context: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async { self.apply() }
  }

  private func apply() {
    let enabled = OwlAgentAccessPreferences.isEnabled(defaults)
    if enabled, bridge == nil {
      let bridge = makeBridge(self)
      do {
        try bridge.start()
        self.bridge = bridge
      } catch {
        NSLog("Owltype agent bridge did not start: \(error)")
      }
    } else if !enabled, let bridge {
      bridge.stop()
      self.bridge = nil
    }
  }

  // MARK: OwlAgentBridgeService

  var appBuild: Wire.AppBuild {
    Wire.AppBuild(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
               build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
  }

  func handle(_ call: Wire.Call, from client: OwlAgentBridgeClient, cancellation: OwlAgentBridgeCancellation,
              reply: @escaping (OwlAgentBridgeReply) -> Void) {
    guard OwlAgentAccessPreferences.isEnabled(defaults) else {
      return reply(.failure(.init(code: .agentAccessDisabled, message: "Agent access is turned off in Owltype settings")))
    }
    switch call {
    case .owltypeStatus:
      let generation = resourceGeneration()
      let exposedCount = (try? OwlAgentTemplates.exposed(loadLibrary()).count) ?? 0
      DispatchQueue.main.async {
        let snapshot = self.inputSnapshot()
        let name = OwlRustSchemaMap.supportedSchemas.first { $0.id == snapshot.schemaID }?.name ?? snapshot.schemaID
        let status = Wire.Status(appVersion: self.appBuild.version, appBuild: self.appBuild.build,
                              resourceGeneration: generation,
                              inputSchema: Wire.InputSchema(id: snapshot.schemaID, name: name),
                              inputMode: snapshot.asciiMode ? .english : .chinese,
                              exposedTemplateCount: exposedCount)
        reply(.success(OwlJSONValue(encoding: status)))
      }
    case .templatesList, .templateGet, .templateRender:
      reply(answerTemplates(call))
    case .hello, .deliverText:
      reply(.failure(.init(code: .methodNotFound, message: "Not available in this Owltype build")))
    }
  }

  private func answerTemplates(_ call: Wire.Call) -> OwlAgentBridgeReply {
    let library: OwlTemplateLibrary
    do { library = try loadLibrary() } catch {
      return .failure(.init(code: .internalError, message: "The template library could not be read"))
    }
    let notFound = Wire.ErrorObject(code: .templateNotFound, message: "Template not found")
    switch call {
    case .templatesList:
      return .success(OwlJSONValue(encoding: Wire.TemplateList(templates: OwlAgentTemplates.exposed(library).map(OwlAgentTemplates.summary))))
    case .templateGet(let ref):
      guard let entry = OwlAgentTemplates.find(ref.id, in: library) else { return .failure(notFound) }
      return .success(OwlJSONValue(encoding: Wire.TemplateDetail(template: OwlAgentTemplates.detail(entry))))
    case .templateRender(let params):
      guard let entry = OwlAgentTemplates.find(params.id, in: library) else { return .failure(notFound) }
      return OwlAgentTemplates.render(entry, arguments: params.arguments ?? [:]).map { OwlJSONValue(encoding: $0) }
    default:
      return .failure(.init(code: .methodNotFound, message: "Method not found"))
    }
  }
}
