//
//  FamoConfig.swift
//  Famo
//
//  Created by Leo Liu on 5/9/24.
//

import AppKit

final class FamoConfig {
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private(set) var isOpen = false

  private var cache: [String: Any] = [:]
  private var config: RimeConfig = .init()
  private var baseConfig: FamoConfig?

  func openBaseConfig() -> Bool {
    close()
    isOpen = rimeAPI.config_open(FamoRimeIdentity.baseConfig, &config)
    return isOpen
  }

  func open(schemaID: String, baseConfig: FamoConfig?) -> Bool {
    close()
    isOpen = rimeAPI.schema_open(schemaID, &config)
    if isOpen {
      self.baseConfig = baseConfig
    }
    return isOpen
  }

  func close() {
    if isOpen {
      _ = rimeAPI.config_close(&config)
      baseConfig = nil
      isOpen = false
    }
  }

  deinit {
    close()
  }

  func has(section: String) -> Bool {
    if isOpen {
      var iterator: RimeConfigIterator = .init()
      if rimeAPI.config_begin_map(&iterator, &config, section) {
        rimeAPI.config_end(&iterator)
        return true
      }
    }
    return false
  }

  func getBool(_ option: String) -> Bool? {
    if let cachedValue = cachedValue(of: Bool.self, forKey: option) {
      return cachedValue
    }
    var value = false
    if isOpen && rimeAPI.config_get_bool(&config, option, &value) {
      cache[option] = value
      return value
    }
    return baseConfig?.getBool(option)
  }

  func getDouble(_ option: String) -> CGFloat? {
    if let cachedValue = cachedValue(of: Double.self, forKey: option) {
      return cachedValue
    }
    var value: Double = 0
    if isOpen && rimeAPI.config_get_double(&config, option, &value) {
      cache[option] = value
      return value
    }
    return baseConfig?.getDouble(option)
  }

  func getString(_ option: String) -> String? {
    if let cachedValue = cachedValue(of: String.self, forKey: option) {
      return cachedValue
    }
    if isOpen, let value = rimeAPI.config_get_cstring(&config, option) {
      cache[option] = String(cString: value)
      return String(cString: value)
    }
    return baseConfig?.getString(option)
  }

  func getAppOptions(_ appName: String) -> [String: Bool] {
    let rootKey = "app_options/\(appName)"
    var appOptions = [String: Bool]()
    var iterator = RimeConfigIterator()
    _ = rimeAPI.config_begin_map(&iterator, &config, rootKey)
    while rimeAPI.config_next(&iterator) {
      // print("[DEBUG] option[\(iterator.index)]: \(String(cString: iterator.key)), path: (\(String(cString: iterator.path))")
      if let key = iterator.key, let path = iterator.path, let value = getBool(String(cString: path)) {
        appOptions[String(cString: key)] = value
      }
    }
    rimeAPI.config_end(&iterator)
    return appOptions
  }
}

private extension FamoConfig {
  func cachedValue<T>(of: T.Type, forKey key: String) -> T? {
    return cache[key] as? T
  }
}
