import Foundation

struct DeviceSpec: Codable {
  let screenSize: Double
  let resolution: String
  let logicalResolution: String
  let deviceType: String
  // 动态扩展字段（可选，保持与旧 JSON 向后兼容）
  let scale: Double?
  let ppi: Double?
  let widthPixels: Int?
  let heightPixels: Int?
  let widthPoints: Int?
  let heightPoints: Int?
  let diagonalInches: Double?
  let source: String?
}

struct DeviceSpecsConfig: Codable {
  let devices: [String: DeviceSpec]
}

class DeviceSpecsManager {
  static let shared = DeviceSpecsManager()
  private var deviceSpecs: [String: DeviceSpec] = [:]
  private var deviceSpecsByIdentifier: [String: DeviceSpec] = [:]
  private var normalizedDeviceSpecs: [String: DeviceSpec] = [:]

  private init() {
    loadAllSpecs()
  }

  // MARK: - Public

  /// 通过设备名称查询（优先精确，后模糊）
  func getDeviceSpec(for deviceName: String) -> DeviceSpec? {
    // 精确匹配
    if let spec = deviceSpecs[deviceName] {
      return spec
    }

    let normalizedName = normalizeDeviceName(deviceName)
    if let spec = normalizedDeviceSpecs[normalizedName] {
      return spec
    }

    // 模糊匹配 - 从最具体到最通用
    let sortedKeys = normalizedDeviceSpecs.keys.sorted { $0.count > $1.count }

    for key in sortedKeys {
      if normalizedName.contains(key) || key.contains(normalizedName) {
        return normalizedDeviceSpecs[key]
      }
    }

    return nil
  }

  /// 通过 UDID 查询（解析 CoreSimulator 设备类型标识符，再映射到动态规格）
  func getDeviceSpec(forUDID udid: String) -> DeviceSpec? {
    guard let identifier = readDeviceTypeIdentifierFromUDID(udid) else { return nil }
    if let spec = deviceSpecsByIdentifier[identifier] {
      return spec
    }
    return nil
  }

  func getAllSpecs() -> [String: DeviceSpec] {
    return deviceSpecs
  }

  /// 刷新动态规格（重新扫描 devicetypes 并更新本地缓存）
  func refreshDynamicSpecs() {
    loadAllSpecs()
  }

  // MARK: - Loaders

  private func loadAllSpecs() {
    let cachedSpecs = loadCachedDeviceSpecs()
    let dynamic = buildDynamicSpecs()

    // 合并优先级：动态 > 本地缓存
    var merged: [String: DeviceSpec] = cachedSpecs
    for (name, spec) in dynamic.byName {
      merged[name] = spec
    }

    if !dynamic.byName.isEmpty {
      saveCachedDeviceSpecs(dynamic.byName)
    }

    self.deviceSpecs = merged
    self.normalizedDeviceSpecs = buildNormalizedSpecs(from: merged)
    self.deviceSpecsByIdentifier = dynamic.byIdentifier
  }

  private func loadCachedDeviceSpecs() -> [String: DeviceSpec] {
    guard let cacheURL = deviceSpecsCacheURL(),
      let data = try? Data(contentsOf: cacheURL),
      let config = try? JSONDecoder().decode(DeviceSpecsConfig.self, from: data)
    else {
      return [:]
    }
    return config.devices
  }

  private func saveCachedDeviceSpecs(_ specs: [String: DeviceSpec]) {
    guard let cacheURL = deviceSpecsCacheURL() else { return }

    do {
      let folderURL = cacheURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: folderURL, withIntermediateDirectories: true, attributes: nil)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(DeviceSpecsConfig(devices: specs))
      try data.write(to: cacheURL, options: .atomic)
    } catch {
      print("[DeviceSpecs] Failed to write cached specs: \(error)")
    }
  }

  private func buildDynamicSpecs() -> (
    byName: [String: DeviceSpec], byIdentifier: [String: DeviceSpec]
  ) {
    var byName: [String: DeviceSpec] = [:]
    var byIdentifier: [String: DeviceSpec] = [:]

    guard let deviceTypes = loadDevicetypes() else {
      return (byName, byIdentifier)
    }

    for entry in deviceTypes {
      guard let metrics = readDeviceTypeMetrics(bundlePath: entry.bundlePath) else { continue }
      let spec = computeSpec(from: metrics, name: entry.name, productFamily: entry.productFamily)
      byName[entry.name] = spec
      byIdentifier[entry.identifier] = spec
    }

    return (byName, byIdentifier)
  }

  // MARK: - Devicetypes parsing

  private struct SimctlDeviceTypesResponse: Codable {
    let devicetypes: [SimctlDeviceType]
  }

  private struct SimctlDeviceType: Codable {
    let productFamily: String?
    let bundlePath: String
    let identifier: String
    let name: String
  }

  private struct DevicetypeEntry {
    let name: String
    let identifier: String
    let bundlePath: String
    let productFamily: String?
  }

  private func loadDevicetypes() -> [DevicetypeEntry]? {
    guard
      let data = runProcessCaptureOutput(
        executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devicetypes", "-j"])
    else {
      print("[DeviceSpecs] Failed to run simctl list devicetypes -j")
      return nil
    }
    do {
      let decoder = JSONDecoder()
      let decoded = try decoder.decode(SimctlDeviceTypesResponse.self, from: data)
      return decoded.devicetypes.map {
        DevicetypeEntry(
          name: $0.name, identifier: $0.identifier, bundlePath: $0.bundlePath,
          productFamily: $0.productFamily)
      }
    } catch {
      print("[DeviceSpecs] Failed to decode devicetypes JSON: \(error)")
      return nil
    }
  }

  private struct DynamicDisplayMetrics {
    let widthPx: Int
    let heightPx: Int
    let scale: Double
    let ppi: Double?
  }

  private func readDeviceTypeMetrics(bundlePath: String) -> DynamicDisplayMetrics? {
    let profilePath = (bundlePath as NSString).appendingPathComponent(
      "Contents/Resources/profile.plist")
    let capabilitiesPath = (bundlePath as NSString).appendingPathComponent(
      "Contents/Resources/capabilities.plist")

    var width: Int? = nil
    var height: Int? = nil
    var scale: Double? = nil
    var ppi: Double? = nil

    // 先读 capabilities（优先）
    if let cap = readPlist(at: capabilitiesPath) as? [String: Any],
      let caps = cap["capabilities"] as? [String: Any],
      let screen = caps["ScreenDimensionsCapability"] as? [String: Any]
    {
      if let w = screen["main-screen-width"] as? NSNumber { width = w.intValue }
      if let h = screen["main-screen-height"] as? NSNumber { height = h.intValue }
      if let s = screen["main-screen-scale"] as? NSNumber { scale = s.doubleValue }
      if let pitch = screen["main-screen-pitch"] as? NSNumber { ppi = pitch.doubleValue }
    }

    // 再读 profile 作为补齐
    if let prof = readPlist(at: profilePath) as? [String: Any] {
      if width == nil, let w = prof["mainScreenWidth"] as? NSNumber { width = w.intValue }
      if height == nil, let h = prof["mainScreenHeight"] as? NSNumber { height = h.intValue }
      if scale == nil, let s = prof["mainScreenScale"] as? NSNumber { scale = s.doubleValue }
      if ppi == nil {
        // 取任一 DPI 值作为 PPI（iPhone/iPad 通常宽高 DPI 一致）
        if let wDPI = prof["mainScreenWidthDPI"] as? NSNumber {
          ppi = wDPI.doubleValue
        } else if let hDPI = prof["mainScreenHeightDPI"] as? NSNumber {
          ppi = hDPI.doubleValue
        }
      }
    }

    guard let widthPx = width, let heightPx = height, let sc = scale else {
      return nil
    }
    return DynamicDisplayMetrics(widthPx: widthPx, heightPx: heightPx, scale: sc, ppi: ppi)
  }

  private func computeSpec(
    from metrics: DynamicDisplayMetrics, name: String, productFamily: String?
  ) -> DeviceSpec {
    let widthPt = Int(Double(metrics.widthPx) / metrics.scale)
    let heightPt = Int(Double(metrics.heightPx) / metrics.scale)
    let resolution = "\(metrics.widthPx)*\(metrics.heightPx)"
    let logical = "\(widthPt)*\(heightPt)"

    var diagonal: Double = 0
    if let ppi = metrics.ppi, ppi > 0 {
      let wInch = Double(metrics.widthPx) / ppi
      let hInch = Double(metrics.heightPx) / ppi
      diagonal = (wInch * wInch + hInch * hInch).squareRoot()
      diagonal = (diagonal * 10).rounded() / 10  // 一位小数
    }

    let type: String
    if let pf = productFamily {
      type = pf
    } else if name.contains("iPad") {
      type = "iPad"
    } else if name.contains("iPhone") {
      type = "iPhone"
    } else {
      type = "other"
    }

    return DeviceSpec(
      screenSize: diagonal,
      resolution: resolution,
      logicalResolution: logical,
      deviceType: type,
      scale: metrics.scale,
      ppi: metrics.ppi,
      widthPixels: metrics.widthPx,
      heightPixels: metrics.heightPx,
      widthPoints: widthPt,
      heightPoints: heightPt,
      diagonalInches: diagonal,
      source: "dynamic"
    )
  }

  // MARK: - Helpers

  private func deviceSpecsCacheURL() -> URL? {
    do {
      let appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true)
      return appSupport
        .appendingPathComponent("iOSSimulatorManager", isDirectory: true)
        .appendingPathComponent("DeviceSpecsCache.json")
    } catch {
      print("[DeviceSpecs] Failed to resolve cache directory: \(error)")
      return nil
    }
  }

  private func normalizeDeviceName(_ name: String) -> String {
    let withoutCapacity = name.replacingOccurrences(
      of: #"\s*\((?:8|16)GB\)"#,
      with: "",
      options: .regularExpression)
    let cleaned = withoutCapacity.replacingOccurrences(
      of: #"[^a-zA-Z0-9]+"#,
      with: " ",
      options: .regularExpression)
    return cleaned
      .lowercased()
      .split(separator: " ")
      .joined(separator: " ")
  }

  private func buildNormalizedSpecs(
    from specs: [String: DeviceSpec]
  ) -> [String: DeviceSpec] {
    var normalized: [String: DeviceSpec] = [:]

    for key in specs.keys.sorted() {
      let normalizedKey = normalizeDeviceName(key)
      if normalized[normalizedKey] == nil, let spec = specs[key] {
        normalized[normalizedKey] = spec
      }
    }

    return normalized
  }

  private func runProcessCaptureOutput(executable: String, arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
      return pipe.fileHandleForReading.readDataToEndOfFile()
    } catch {
      print("[DeviceSpecs] Process failed: \(error)")
      return nil
    }
  }

  private func readPlist(at path: String) -> Any? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
      print("[DeviceSpecs] Failed to read plist at \(path): \(error)")
      return nil
    }
  }

  private func readDeviceTypeIdentifierFromUDID(_ udid: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let plistPath = "\(home)/Library/Developer/CoreSimulator/Devices/\(udid)/device.plist"
    guard let plist = readPlist(at: plistPath) as? [String: Any] else { return nil }
    // 常见两种结构：字符串或字典包含 identifier
    if let idStr = plist["deviceType"] as? String {
      return idStr
    }
    if let dict = plist["deviceType"] as? [String: Any], let idStr = dict["identifier"] as? String {
      return idStr
    }
    if let idStr = plist["deviceTypeIdentifier"] as? String {
      return idStr
    }
    return nil
  }

  // 旧位置的查询接口已上移到 Public 区域，避免重复
}
