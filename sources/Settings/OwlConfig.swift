//
//  OwlConfig.swift
//  Owltype
//
//  Read-only Swift adapter over the Rust YAML config API. Rime's compiled
//  `build/` tree is not involved: the shared YAML is loaded directly and the
//  user's `.custom.yaml` `patch:` map is overlaid by owl-msime-ffi.
//

import AppKit
import Foundation

final class OwlConfig {
  private let sharedSupportURL: URL
  private let userDataURL: URL
  private var config: OpaquePointer?
  private var cache: [String: Any] = [:]
  private var baseConfig: OwlConfig?

  private(set) var isOpen = false

  init(
    sharedSupportURL: URL? = Bundle.main.sharedSupportURL,
    userDataURL: URL = OwlApp.userDir
  ) {
    self.sharedSupportURL = sharedSupportURL
      ?? URL(fileURLWithPath: Bundle.main.sharedSupportPath ?? "", isDirectory: true)
    self.userDataURL = userDataURL
  }

  func openBaseConfig() -> Bool {
    open(
      base: sharedSupportURL.appendingPathComponent("owltype.yaml"),
      patch: userDataURL.appendingPathComponent("owltype.custom.yaml")
    )
  }

  func open(schemaID: String, baseConfig: OwlConfig?) -> Bool {
    close()
    guard OwlRustSchemaMap.configuration(schemaID).validConfigID else {
      return false
    }
    let opened = open(
      base: sharedSupportURL.appendingPathComponent("\(schemaID).schema.yaml"),
      patch: userDataURL.appendingPathComponent("\(schemaID).custom.yaml")
    )
    if opened {
      self.baseConfig = baseConfig
    }
    return opened
  }

  func close() {
    if let config {
      owl_msime_config_destroy(config)
      self.config = nil
    }
    cache.removeAll()
    baseConfig = nil
    isOpen = false
  }

  deinit {
    close()
  }

  func has(section: String) -> Bool {
    guard let config else { return false }
    return section.withCString { owl_msime_config_has_map(config, $0) }
  }

  func getBool(_ option: String) -> Bool? {
    if let cachedValue = cachedValue(of: Bool.self, forKey: option) {
      return cachedValue
    }
    if let config {
      var value = false
      if option.withCString({
        owl_msime_config_get_bool(config, $0, &value)
      }) {
        cache[option] = value
        return value
      }
    }
    return baseConfig?.getBool(option)
  }

  func getDouble(_ option: String) -> CGFloat? {
    if let cachedValue = cachedValue(of: Double.self, forKey: option) {
      return CGFloat(cachedValue)
    }
    if let config {
      var value = 0.0
      if option.withCString({
        owl_msime_config_get_double(config, $0, &value)
      }) {
        cache[option] = value
        return CGFloat(value)
      }
    }
    return baseConfig?.getDouble(option)
  }

  func getString(_ option: String) -> String? {
    if let cachedValue = cachedValue(of: String.self, forKey: option) {
      return cachedValue
    }
    if let config {
      let value = option.withCString {
        owl_msime_config_get_string(config, $0)
      }
      if let value {
        defer { owl_msime_string_free(value) }
        let string = String(cString: value)
        cache[option] = string
        return string
      }
    }
    return baseConfig?.getString(option)
  }

  func getAppOptions(_ appName: String) -> [String: Bool] {
    guard let config else { return [:] }
    let value = appName.withCString {
      owl_msime_config_app_options_json(config, $0)
    }
    guard let value else { return [:] }
    defer { owl_msime_string_free(value) }
    let data = Data(bytes: value, count: strlen(value))
    return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
  }
}

private extension OwlConfig {
  func open(base: URL, patch: URL) -> Bool {
    close()
    var error: UnsafeMutablePointer<CChar>?
    let opened = base.path.withCString { baseCString in
      patch.path.withCString { patchCString in
        owl_msime_config_open(baseCString, patchCString, &error)
      }
    }
    if let error {
      NSLog(
        "OwlConfig: cannot open %@ with %@: %s",
        base.path,
        patch.path,
        error
      )
      owl_msime_string_free(error)
    }
    config = opened
    isOpen = opened != nil
    return isOpen
  }

  func cachedValue<T>(of: T.Type, forKey key: String) -> T? {
    cache[key] as? T
  }
}
