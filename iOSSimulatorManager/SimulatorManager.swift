import AppKit
import Combine
import Foundation

// 设备管理类
class SimulatorManager: ObservableObject, ErrorHandler {
    // 分组后的设备列表
    @Published var deviceGroups: [DeviceGroup] = []
    // 保持原有设备列表属性，保证兼容性
    @Published var devices: [SimulatorDevice] = []
    // 加载状态
    @Published var isLoading: Bool = true
    // 是否初次加载完成
    @Published var hasInitialLoadCompleted: Bool = false
    // 连续刷新失败次数（用于兜底保护）
    private var consecutiveFailures: Int = 0
    // 是否暂停自动刷新（当连续失败过多时）
    @Published private(set) var isAutoRefreshPaused: Bool = false

    private var timer: Timer?
    @Published private(set) var isOperating = false
    private var isRefreshing = false
    private var refreshTask: DispatchWorkItem?
    private var deviceCache: [SimulatorDevice] = []
    private var runtimeCache: Set<String> = []  // 已安装 Runtime 缓存
    private var renderedSnapshot: [DeviceGroupSnapshot] = []
    private var lastRefreshTime: Date = Date.distantPast
    private let refreshInterval: TimeInterval = 5.0 // 增加到5秒
    private let cacheValidTime: TimeInterval = 2.0 // 缓存有效期2秒
    private let maxConsecutiveFailures: Int = 3  // 连续失败阈值，超过后暂停自动刷新

    // 错误处理
    @Published var lastError: String? = nil
    @Published var hasError: Bool = false
    @Published var deletingRuntimeIdentifier: String? = nil
    @Published var deletingRuntimeIncludesRuntime: Bool = false
    @Published var operatingDeviceUDID: String? = nil
    @Published var operatingDeviceAction: DeviceOperationKind? = nil

    /// 设备分组模型
    struct DeviceGroup: Identifiable {
        var id: String { runtime }
        let runtime: String
        let displayName: String
        var devices: [SimulatorDevice]
    }

    private struct DeviceSnapshot: Equatable {
        let udid: String
        let name: String
        let state: String
        let runtime: String
        let screenSize: Double
        let resolution: String
        let logicalResolution: String
    }

    private struct DeviceGroupSnapshot: Equatable {
        let runtime: String
        let displayName: String
        let devices: [DeviceSnapshot]
    }

    enum DeviceOperationKind {
        case booting
        case shuttingDown
        case resetting
        case deleting

        var progressText: String {
            switch self {
            case .booting:
                return "正在启动..."
            case .shuttingDown:
                return "正在关闭..."
            case .resetting:
                return "正在重置..."
            case .deleting:
                return "正在删除..."
            }
        }
    }

    init() {
        // 异步执行初始化操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.cleanUnavailableDevices()

            DispatchQueue.main.async {
                self?.refreshDevices()

                // 创建定时器，实时更新 - 使用更长间隔
                self?.timer = Timer.scheduledTimer(withTimeInterval: self?.refreshInterval ?? 5.0, repeats: true) {
                    [weak self] _ in
                    guard let self = self, !self.isOperating else { return }
                    self.refreshDevicesWithDebounce()
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// 清理不可用的模拟器（带超时保护）
    private func cleanUnavailableDevices() {
        let process = Process()
        let pipe = Pipe()
        let timeoutSeconds: Double = 5.0

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "delete", "unavailable"]
        process.standardOutput = pipe
        process.standardError = pipe

        var didTimeout = false

        // 设置超时
        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, process.isRunning else { return }
            didTimeout = true
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)

        do {
            try process.run()
            process.waitUntilExit()
            timeoutWorkItem.cancel()

            if didTimeout {
                print("清理超时：清理命令执行超过\(Int(timeoutSeconds))秒")
                return
            }

            if process.terminationStatus == 0 {
                print("清理完成：已删除不可用的模拟器")
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let error = String(data: data, encoding: .utf8), !error.isEmpty {
                    print("清理失败：\(error)")
                }
            }
        } catch {
            print("清理执行失败：\(error.localizedDescription)")
        }
    }

    /// 带防抖的刷新设备列表（定时器驱动）
    private func refreshDevicesWithDebounce() {
        // 如果自动刷新已暂停，不执行自动刷新
        guard !isAutoRefreshPaused else { return }

        // 取消之前的刷新任务
        refreshTask?.cancel()

        // 创建新的刷新任务
        refreshTask = DispatchWorkItem { [weak self] in
            self?.refreshDevices()
        }

        // 延迟执行，防抖
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: refreshTask!)
    }

    /// 手动刷新时重置失败计数并恢复自动刷新
    func manualResumeAutoRefresh() {
        consecutiveFailures = 0
        isAutoRefreshPaused = false
        refreshDevices()
    }
    
    /// 刷新设备列表
    func refreshDevices() {
        guard !isOperating, !isRefreshing else { return }
        isRefreshing = true

        PerformanceMonitor.shared.startOperation("refreshDevices")

        // 检查缓存是否有效
        let now = Date()
        if now.timeIntervalSince(lastRefreshTime) < cacheValidTime && !deviceCache.isEmpty {
            PerformanceMonitor.shared.logDebug(
                "refreshDevices: 命中缓存，未执行 simctl 查询，也未触发 UI reload")
            DispatchQueue.main.async {
                self.isRefreshing = false
                // 命中缓存时重置失败计数
                self.consecutiveFailures = 0
                if !self.hasInitialLoadCompleted {
                    self.hasInitialLoadCompleted = true
                    self.isLoading = false
                }
            }
            PerformanceMonitor.shared.endOperation("refreshDevices")
            return
        }

        // 如果是初次加载，显示loading状态
        if !hasInitialLoadCompleted {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 使用带超时的执行方式
            let success = self.executeRefreshWithTimeout()

            DispatchQueue.main.async {
                self.isRefreshing = false

                // 处理失败计数
                if success {
                    self.consecutiveFailures = 0
                    // 成功后恢复自动刷新（如果之前因失败而暂停）
                    if self.isAutoRefreshPaused {
                        self.isAutoRefreshPaused = false
                        PerformanceMonitor.shared.logInfo("检测到 CoreSimulator 恢复正常，已恢复自动刷新")
                    }
                } else {
                    self.consecutiveFailures += 1
                    PerformanceMonitor.shared.logDebug(
                        "refreshDevices: 刷新失败，当前连续失败次数: \(self.consecutiveFailures)")

                    // 连续失败超过阈值时暂停自动刷新
                    if self.consecutiveFailures >= self.maxConsecutiveFailures && !self.isAutoRefreshPaused {
                        self.isAutoRefreshPaused = true
                        PerformanceMonitor.shared.logInfo(
                            "连续失败次数超过 \(self.maxConsecutiveFailures) 次，已暂停自动刷新，请手动刷新或重启 Xcode")
                        self.handleError(SimulatorError.commandExecutionFailed(
                            "检测到 CoreSimulator 可能异常，已暂停自动刷新。请手动刷新或重启 Xcode 后再试。"))
                    }
                }

                if !self.hasInitialLoadCompleted {
                    self.hasInitialLoadCompleted = true
                    self.isLoading = false
                }
                PerformanceMonitor.shared.endOperation("refreshDevices")
            }
        }
    }

    /// 带超时的刷新执行
    /// 策略：优先使用 JSON 格式（快），超时后使用普通文本格式（兼容性好）
    private func executeRefreshWithTimeout() -> Bool {
        // 首先尝试 JSON 格式（更快、更结构化）
        let (jsonSuccess, devicesFromJson) = tryRefreshWithJsonFormat(timeoutSeconds: 10.0)

        var allDevices: [SimulatorDevice] = []
        var installedRuntimes: Set<String> = []

        if jsonSuccess, let devices = devicesFromJson {
            allDevices = devices
            installedRuntimes = Set(getInstalledRuntimes())
            PerformanceMonitor.shared.logInfo("使用 JSON 格式刷新成功，获取到 \(allDevices.count) 台设备")
        } else {
            // JSON 格式失败，尝试普通文本格式作为备选
            PerformanceMonitor.shared.logInfo("JSON 格式超时/失败，尝试使用普通文本格式作为备选...")
            let (textSuccess, devicesFromText) = tryRefreshWithTextFormat(timeoutSeconds: 15.0)

            if textSuccess, let devices = devicesFromText {
                allDevices = devices
                installedRuntimes = Set(getInstalledRuntimes())
                PerformanceMonitor.shared.logInfo("使用文本格式刷新成功，获取到 \(allDevices.count) 台设备")
            } else {
                // 文本格式也失败，检查是否有缓存数据
                if !deviceCache.isEmpty {
                    PerformanceMonitor.shared.logInfo("刷新失败，保留缓存数据（\(deviceCache.count) 台设备）")
                    // 更新 lastRefreshTime 避免立即重试
                    DispatchQueue.main.async { [weak self] in
                        self?.lastRefreshTime = Date()
                    }
                    // 不返回 false，避免触发失败计数增加
                    return true
                }
                return false
            }
        }

        // 记录 installedRuntimes 用于调试
        PerformanceMonitor.shared.logDebug("文本解析后 installedRuntimes: \(installedRuntimes)")

        let nextGroups = buildSortedDeviceGroups(from: allDevices, installedRuntimes: installedRuntimes)
        PerformanceMonitor.shared.logDebug("文本解析后生成分组: \(nextGroups.count) 个")
        for group in nextGroups {
            PerformanceMonitor.shared.logDebug("  分组 '\(group.displayName)': \(group.devices.count) 台设备")
        }

        let nextSnapshot = makeSnapshot(from: nextGroups)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runtimeCache = installedRuntimes
            self.deviceCache = allDevices
            self.lastRefreshTime = Date()

            if nextSnapshot != self.renderedSnapshot {
                self.renderedSnapshot = nextSnapshot
                self.devices = allDevices
                self.deviceGroups = nextGroups
                PerformanceMonitor.shared.logInfo(
                    "refreshDevices: 已执行刷新并触发 UI reload，分组 \(nextGroups.count) 个，设备 \(allDevices.count) 台")
            } else {
                PerformanceMonitor.shared.logDebug(
                    "refreshDevices: 已执行 simctl 刷新，但最终渲染快照无变化，未触发 UI reload")
            }
        }
        return true
    }

    /// 使用 JSON 格式刷新设备列表
    private func tryRefreshWithJsonFormat(timeoutSeconds: Double) -> (Bool, [SimulatorDevice]?) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        process.standardOutput = pipe
        process.standardError = pipe

        var didTimeout = false
        var terminationOccurred = false

        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, !terminationOccurred else { return }
            didTimeout = true
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)

        do {
            try process.run()
            process.waitUntilExit()
            terminationOccurred = true
            timeoutWorkItem.cancel()

            if didTimeout {
                PerformanceMonitor.shared.logDebug("JSON 格式刷新超时（\(Int(timeoutSeconds))秒）")
                return (false, nil)
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            if data.isEmpty {
                PerformanceMonitor.shared.logDebug("JSON 格式返回空数据")
                return (false, nil)
            }

            let decoder = JSONDecoder()
            let result = try decoder.decode(SimctlListResponse.self, from: data)
            let allDevices = buildSortedDevices(from: result)
            return (true, allDevices)
        } catch {
            terminationOccurred = true
            timeoutWorkItem.cancel()
            PerformanceMonitor.shared.logDebug("JSON 格式解析失败: \(error.localizedDescription)")
            return (false, nil)
        }
    }

    /// 使用普通文本格式刷新设备列表（备选方案，当 JSON 格式失败时使用）
    private func tryRefreshWithTextFormat(timeoutSeconds: Double) -> (Bool, [SimulatorDevice]?) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices"]
        process.standardOutput = pipe
        process.standardError = pipe

        var didTimeout = false
        var terminationOccurred = false

        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, !terminationOccurred else { return }
            didTimeout = true
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)

        do {
            try process.run()
            process.waitUntilExit()
            terminationOccurred = true
            timeoutWorkItem.cancel()

            if didTimeout {
                PerformanceMonitor.shared.logDebug("文本格式刷新超时（\(Int(timeoutSeconds))秒）")
                return (false, nil)
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else {
                PerformanceMonitor.shared.logDebug("文本格式返回空数据")
                return (false, nil)
            }

            // 解析文本格式的设备列表
            let allDevices = parseTextFormatDevices(output)
            return (true, allDevices)
        } catch {
            terminationOccurred = true
            timeoutWorkItem.cancel()
            PerformanceMonitor.shared.logDebug("文本格式执行失败: \(error.localizedDescription)")
            return (false, nil)
        }
    }

    /// 解析普通文本格式的 simctl list devices 输出
    private func parseTextFormatDevices(_ output: String) -> [SimulatorDevice] {
        var devices: [SimulatorDevice] = []
        var currentRuntime: String = ""

        // 构建现有设备的查找表（名称+运行时 -> 设备），用于保留真实 UDID
        var existingDevicesMap: [String: SimulatorDevice] = [:]
        for device in deviceCache {
            let key = "\(device.name)|\(device.runtime)"
            existingDevicesMap[key] = device
        }

        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 检测 Runtime 分组头，如 "-- iOS 18.6 --"
            if trimmed.hasPrefix("--") && trimmed.hasSuffix("--") {
                currentRuntime = trimmed
                    .replacingOccurrences(of: "--", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // 转换为标准格式
                let converted = convertToRuntimeIdentifier(currentRuntime)
                PerformanceMonitor.shared.logDebug("文本解析: 发现 runtime header '\(currentRuntime)' -> '\(converted)'")
                currentRuntime = converted
                continue
            }

            // 跳过 "== Runtimes ==" 和 "== Devices ==" 等标题行
            if trimmed.hasPrefix("==") && trimmed.hasSuffix("==") {
                continue
            }

            // 检测设备行，如 "iPhone 16 Pro (UDID) (Shutdown)"
            if trimmed.contains("(") && trimmed.contains(")") && !trimmed.hasPrefix("--") {
                if currentRuntime.isEmpty {
                    PerformanceMonitor.shared.logDebug("文本解析: 跳过设备行（无 runtime）: \(trimmed.prefix(50))")
                    continue
                }
                if let device = parseTextDeviceLine(trimmed, runtime: currentRuntime, existingDevicesMap: existingDevicesMap) {
                    devices.append(device)
                }
            }
        }

        PerformanceMonitor.shared.logDebug("文本解析: 共解析出 \(devices.count) 台设备")
        return devices
    }

    /// 将文本格式的 runtime 名称转换为标识符格式
    private func convertToRuntimeIdentifier(_ displayName: String) -> String {
        // "iOS 18.3" -> "com.apple.CoreSimulator.SimRuntime.iOS-18-3"
        if displayName.hasPrefix("iOS ") {
            let version = displayName.replacingOccurrences(of: "iOS ", with: "")
            let parts = version.components(separatedBy: ".")
            if parts.count == 2 {
                return "com.apple.CoreSimulator.SimRuntime.iOS-\(parts[0])-\(parts[1])"
            } else if parts.count == 1 {
                return "com.apple.CoreSimulator.SimRuntime.iOS-\(parts[0])-0"
            }
        }
        return displayName
    }

    /// 解析单行设备信息
    private func parseTextDeviceLine(_ line: String, runtime: String, existingDevicesMap: [String: SimulatorDevice]) -> SimulatorDevice? {
        // 格式: "iPhone 16 Pro (UDID) (Shutdown)" 或 "iPhone SE (3rd generation) (UDID) (Booted)"
        // 最后两个括号分别是 UDID 和状态（名称中间可能有括号）

        // 从右往左找：最后一个左括号是状态的开始
        guard let lastOpenParen = line.lastIndex(of: "("),
              let lastCloseParen = line.lastIndex(of: ")") else {
            return nil
        }

        // 提取状态
        let stateStr = String(line[line.index(after: lastOpenParen)..<lastCloseParen])
            .trimmingCharacters(in: .whitespaces)

        // 从右往左找：倒数第二个左括号是 UDID 的开始
        // 位置在 lastOpenParen 之前
        let beforeLastOpen = String(line[..<lastOpenParen])
        guard let secondLastOpenParen = beforeLastOpen.lastIndex(of: "(") else {
            return nil
        }

        // 提取 UDID：找到 UDID 左括号对应的右括号
        guard let udidCloseParen = beforeLastOpen[beforeLastOpen.index(after: secondLastOpenParen)...].firstIndex(of: ")") else {
            return nil
        }
        let udid = String(beforeLastOpen[beforeLastOpen.index(after: secondLastOpenParen)..<udidCloseParen])
            .trimmingCharacters(in: .whitespaces)

        // 提取名称（从行首到 UDID 左括号之前）
        let name = String(line[..<secondLastOpenParen]).trimmingCharacters(in: .whitespaces)

        // 确定设备状态
        let state: String
        if stateStr.contains("Booted") && !stateStr.contains("Shutting") {
            state = "Booted"
        } else if stateStr.contains("Shutting") {
            state = "Shutting Down"
        } else {
            state = "Shutdown"
        }

        // 验证 UDID 格式是否有效（应该是类似 UUID 的格式：8-4-4-4-12）
        let isValidUDID = udid.count == 36 && udid.filter { $0 == "-" }.count == 4

        if isValidUDID {
            // 使用真实 UDID
            return SimulatorDevice(
                udid: udid,
                name: name,
                state: state,
                runtime: runtime,
                deviceTypeIdentifier: nil,
                isPlaceholder: false  // 真实设备
            )
        }

        // UDID 无效，尝试从缓存匹配
        let lookupKey = "\(name)|\(runtime)"
        if let existingDevice = existingDevicesMap[lookupKey] {
            // 使用现有设备的 UDID，但更新状态
            return SimulatorDevice(
                udid: existingDevice.udid,
                name: name,
                state: state,
                runtime: runtime,
                deviceTypeIdentifier: nil,
                isPlaceholder: false  // 真实设备
            )
        }

        // 无法获取有效 UDID，生成伪 UDID（标记为占位设备）
        let pseudoUDID = generatePseudoUDID(name: name, runtime: runtime)

        return SimulatorDevice(
            udid: pseudoUDID,
            name: name,
            state: state,
            runtime: runtime,
            deviceTypeIdentifier: nil,
            isPlaceholder: true  // 占位设备
        )
    }

    /// 为文本格式生成伪 UDID（因为文本格式不包含 UDID）
    private func generatePseudoUDID(name: String, runtime: String) -> String {
        let input = "\(name)-\(runtime)"
        var hash: UInt64 = 5381
        for char in input.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }

        // 生成类似真实 UDID 的格式
        let hex = String(hash, radix: 16).uppercased()
        let padded = String(repeating: "0", count: max(0, 24 - hex.count)) + hex
        return "\(padded.prefix(8))-\(padded.dropFirst(8).prefix(4))-\(padded.dropFirst(12).prefix(4))-\(padded.dropFirst(16).prefix(4))-\(padded.dropFirst(20))"
    }

    /// 检查设备列表是否有变化
    private func hasDevicesChanged(newDevices: [SimulatorDevice]) -> Bool {
        // 如果设备数量不同，肯定有变化
        guard newDevices.count == devices.count else {
            return true
        }

        // 创建当前设备的查找字典，键为设备ID
        let currentDevicesDict = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0) })

        // 检查每个新设备是否与当前设备有差异
        for newDevice in newDevices {
            if let currentDevice = currentDevicesDict[newDevice.udid] {
                // 比较关键属性
                if newDevice.state != currentDevice.state || newDevice.name != currentDevice.name
                    || newDevice.runtime != currentDevice.runtime
                {
                    return true  // 发现差异
                }
            } else {
                return true  // 新设备不在当前设备列表中
            }
        }

        // 没有发现差异
        return false
    }

    private func buildSortedDevices(from result: SimctlListResponse) -> [SimulatorDevice] {
        var allDevices = result.devices.flatMap { key, value in
            value.map { device in
                SimulatorDevice(
                    udid: device.udid,
                    name: device.name,
                    state: device.state,
                    runtime: key,
                    deviceTypeIdentifier: device.deviceTypeIdentifier
                )
            }
        }
        sortDevices(&allDevices)
        return allDevices
    }

    private func buildSortedDeviceGroups(
        from devices: [SimulatorDevice],
        installedRuntimes: Set<String>
    ) -> [DeviceGroup] {
        var groups: [String: DeviceGroup] = [:]

        for runtime in installedRuntimes {
            let displayName = formatRuntimeName(runtime)
            groups[runtime] = DeviceGroup(
                runtime: runtime,
                displayName: displayName,
                devices: []
            )
        }

        for device in devices {
            let runtimeKey = device.runtime
            let displayName = formatRuntimeName(runtimeKey)

            if groups[runtimeKey] == nil {
                groups[runtimeKey] = DeviceGroup(
                    runtime: runtimeKey,
                    displayName: displayName,
                    devices: []
                )
            }

            groups[runtimeKey]?.devices.append(device)
        }

        for key in groups.keys {
            groups[key]?.devices.sort { shouldSortDevice($0, before: $1) }
        }

        let sortedGroupKeys = groups.keys.sorted { key1, key2 in
            let version1 = extractVersionNumber(from: key1)
            let version2 = extractVersionNumber(from: key2)
            return version1 > version2
        }

        return sortedGroupKeys.compactMap { groups[$0] }
    }

    private func sortDevices(_ devices: inout [SimulatorDevice]) {
        devices.sort { shouldSortDevice($0, before: $1) }
    }

    private func shouldSortDevice(
        _ device1: SimulatorDevice,
        before device2: SimulatorDevice
    ) -> Bool {
        let version1 = extractVersionNumber(from: device1.runtime)
        let version2 = extractVersionNumber(from: device2.runtime)

        if version1 != version2 {
            return version1 > version2
        }

        if device1.deviceType != device2.deviceType {
            if device1.deviceType == .iPhone && device2.deviceType == .iPad {
                return true
            }
            if device1.deviceType == .iPad && device2.deviceType == .iPhone {
                return false
            }
        }

        if device1.screenSize != device2.screenSize {
            return device1.screenSize > device2.screenSize
        }

        return device1.name < device2.name
    }

    private func makeSnapshot(from groups: [DeviceGroup]) -> [DeviceGroupSnapshot] {
        groups.map { group in
            DeviceGroupSnapshot(
                runtime: group.runtime,
                displayName: group.displayName,
                devices: group.devices.map { device in
                    DeviceSnapshot(
                        udid: device.udid,
                        name: device.name,
                        state: device.state,
                        runtime: device.runtime,
                        screenSize: device.screenSize,
                        resolution: device.resolution,
                        logicalResolution: device.logicalResolution
                    )
                }
            )
        }
    }

    /// 格式化运行时名称，便于显示
    /// 例如从 "com.apple.CoreSimulator.SimRuntime.iOS-17-5" 提取出 "iOS 17.5"
    private func formatRuntimeName(_ runtime: String) -> String {
        if let match = runtime.range(of: "iOS-(\\d+)-(\\d+)", options: .regularExpression) {
            let matched = runtime[match]
            let formatted =
                matched
                .replacingOccurrences(of: "iOS-", with: "iOS ")
                .replacingOccurrences(of: "-", with: ".")
            return formatted
        }
        return runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
    }

    /// 从runtime字符串中提取版本号，用于排序
    /// 例如从 "com.apple.CoreSimulator.SimRuntime.iOS-17-5" 提取出 17.5
    private func extractVersionNumber(from runtime: String) -> Double {
        // 查找形如 "iOS-17-5" 的模式
        let pattern = "iOS-(\\d+)-(\\d+)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        if let match = regex?.firstMatch(
            in: runtime, options: [], range: NSRange(runtime.startIndex..., in: runtime))
        {
            // 提取主版本号和次版本号
            if let majorRange = Range(match.range(at: 1), in: runtime),
                let minorRange = Range(match.range(at: 2), in: runtime)
            {
                let major = runtime[majorRange]
                let minor = runtime[minorRange]

                // 转换为浮点数形式 (例如：17.5)
                if let majorNum = Double(major), let minorNum = Double(minor) {
                    return majorNum + minorNum / 10.0
                }
            }
        }

        // 如果无法解析，返回默认较低优先级
        return 0.0
    }
    
    /// 获取所有已安装的 iOS Runtime 标识符列表（带超时保护）
    /// - Returns: Runtime 标识符数组，如 ["com.apple.CoreSimulator.SimRuntime.iOS-17-5", ...]
    private func getInstalledRuntimes() -> [String] {
        let process = Process()
        let pipe = Pipe()
        let timeoutSeconds: Double = 8.0

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "runtimes", "-j"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        var didTimeout = false

        // 设置超时
        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, process.isRunning else { return }
            didTimeout = true
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)

        do {
            try process.run()
            process.waitUntilExit()
            timeoutWorkItem.cancel()

            if didTimeout {
                print("获取 Runtime 超时：命令执行超过\(Int(timeoutSeconds))秒")
                return []
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            // 解析 JSON
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let runtimes = json["runtimes"] as? [[String: Any]] {

                var runtimeIdentifiers: [String] = []
                for runtimeInfo in runtimes {
                    // 只获取 iOS runtime，且为可用状态
                    if let identifier = runtimeInfo["identifier"] as? String,
                       let isAvailable = runtimeInfo["isAvailable"] as? Bool,
                       identifier.contains("iOS"),
                       isAvailable {
                        runtimeIdentifiers.append(identifier)
                    }
                }
                return runtimeIdentifiers
            }
        } catch {
            print("获取已安装 Runtime 失败: \(error.localizedDescription)")
        }
        return []
    }

    /// 开启设备
    func bootDevice(udid: String) {
        // 检查是否为占位设备（伪 UDID）
        if let device = devices.first(where: { $0.udid == udid }), device.isPlaceholder {
            handleError(SimulatorError.commandExecutionFailed("无法启动：该设备信息不完整，请刷新后重试"))
            return
        }

        isOperating = true
        operatingDeviceUDID = udid
        operatingDeviceAction = .booting

        // 立即更新本地状态
        updateDeviceState(udid: udid, to: "Booted")

        // 执行实际操作
        executeSimctlCommand(arguments: ["boot", udid])

        // 等待启动完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.openSimulatorApp()
            self.refreshDevices()
            self.isOperating = false
            self.operatingDeviceUDID = nil
            self.operatingDeviceAction = nil
        }
    }

    /// 关闭设备
    func shutdownDevice(udid: String) {
        // 检查是否为占位设备（伪 UDID）
        if let device = devices.first(where: { $0.udid == udid }), device.isPlaceholder {
            handleError(SimulatorError.commandExecutionFailed("无法关闭：该设备信息不完整，请刷新后重试"))
            return
        }

        isOperating = true
        operatingDeviceUDID = udid
        operatingDeviceAction = .shuttingDown

        // 立即更新本地状态
        updateDeviceState(udid: udid, to: "Shutdown")

        // 执行实际操作
        executeSimctlCommand(arguments: ["shutdown", udid])

        // 等待关闭完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.refreshDevices()
            self.isOperating = false
            self.operatingDeviceUDID = nil
            self.operatingDeviceAction = nil
        }
    }

    func eraseDevice(
        udid: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        // 检查是否为占位设备（伪 UDID）
        if let device = devices.first(where: { $0.udid == udid }), device.isPlaceholder {
            handleError(SimulatorError.commandExecutionFailed("无法重置：该设备信息不完整，请刷新后重试"))
            completion?(false)
            return
        }

        isOperating = true
        operatingDeviceUDID = udid
        operatingDeviceAction = .resetting

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let currentState = self?.devices.first(where: { $0.udid == udid })?.state
            var succeeded = true

            if currentState == "Booted" {
                if self?.executeSimctlCommand(arguments: ["shutdown", udid]) == false {
                    succeeded = false
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            if self?.executeSimctlCommand(arguments: ["erase", udid]) == false {
                succeeded = false
            }

            DispatchQueue.main.async {
                self?.isOperating = false
                self?.operatingDeviceUDID = nil
                self?.operatingDeviceAction = nil
                self?.forceRefresh()
                completion?(succeeded)
            }
        }
    }

    func deleteDevice(
        udid: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        // 检查是否为占位设备（伪 UDID）
        if let device = devices.first(where: { $0.udid == udid }), device.isPlaceholder {
            handleError(SimulatorError.commandExecutionFailed("无法删除：该设备信息不完整，请刷新后重试"))
            completion?(false)
            return
        }

        isOperating = true
        operatingDeviceUDID = udid
        operatingDeviceAction = .deleting

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let currentState = self?.devices.first(where: { $0.udid == udid })?.state
            var succeeded = true

            if currentState == "Booted" {
                if self?.executeSimctlCommand(arguments: ["shutdown", udid]) == false {
                    succeeded = false
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            if self?.executeSimctlCommand(arguments: ["delete", udid]) == false {
                succeeded = false
            }

            DispatchQueue.main.async {
                self?.isOperating = false
                self?.operatingDeviceUDID = nil
                self?.operatingDeviceAction = nil
                self?.forceRefresh()
                completion?(succeeded)
            }
        }
    }

    /// 更新设备状态（本地）
    private func updateDeviceState(udid: String, to newState: String) {
        DispatchQueue.main.async {
            // 更新原始设备列表
            self.devices = self.devices.map { device in
                if device.udid == udid {
                    return SimulatorDevice(copying: device, state: newState)
                }
                return device
            }

            // 更新分组设备列表
            for i in 0..<self.deviceGroups.count {
                for j in 0..<self.deviceGroups[i].devices.count {
                    if self.deviceGroups[i].devices[j].udid == udid {
                        self.deviceGroups[i].devices[j] = SimulatorDevice(
                            copying: self.deviceGroups[i].devices[j],
                            state: newState)
                    }
                }
            }
        }
    }

    /// 打开设备
    private func openSimulatorApp() {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Simulator"]
            try process.run()
        } catch {
            handleError(SimulatorError.commandExecutionFailed("无法打开模拟器应用: \(error.localizedDescription)"))
        }
    }

    /// 执行xc命令（带超时保护）
    @discardableResult
    private func executeSimctlCommand(arguments: [String], timeoutSeconds: Double = 30.0) -> Bool {
        let process = Process()
        let timeout: Double = timeoutSeconds

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments

        var didTimeout = false
        var terminationOccurred = false

        // 设置超时
        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, !terminationOccurred else { return }
            didTimeout = true
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        do {
            try process.run()
            process.waitUntilExit()
            terminationOccurred = true
            timeoutWorkItem.cancel()

            if didTimeout {
                handleError(SimulatorError.commandExecutionFailed("命令执行超时（\(Int(timeout))秒）"))
                return false
            }

            return process.terminationStatus == 0
        } catch {
            terminationOccurred = true
            timeoutWorkItem.cancel()
            handleError(SimulatorError.commandExecutionFailed("命令执行失败: \(error.localizedDescription)"))
            return false
        }
    }

    /// 手动刷新设备列表，显示loading状态
    func manualRefresh() {
        DispatchQueue.main.async {
            self.isLoading = true
        }

        // 延迟一点时间确保UI更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.refreshDevices()

            // 确保在一段时间后结束loading状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.isLoading {
                    self.isLoading = false
                }
            }
        }
    }
    
    // MARK: - ErrorHandler
    func handleError(_ error: Error) {
        PerformanceMonitor.shared.logError(error)
        
        DispatchQueue.main.async {
            self.lastError = error.localizedDescription
            self.hasError = true
            
            // 3秒后自动清除错误
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.hasError = false
                self.lastError = nil
            }
        }
        
        // 仍然打印到控制台用于调试
        print("SimulatorManager Error: \(error.localizedDescription)")
    }
    
    /// 清除错误状态
    func clearError() {
        DispatchQueue.main.async {
            self.hasError = false
            self.lastError = nil
        }
    }
    
    /// 强制刷新（忽略缓存）
    func forceRefresh() {
        lastRefreshTime = Date.distantPast
        deviceCache.removeAll()
        refreshDevices()
    }
    
    /// 删除指定 runtime 版本的所有模拟器
    /// - Parameters:
    ///   - runtime: runtime 标识符，如 "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    ///   - deleteRuntime: 是否同时删除 iOS Runtime 镜像（彻底删除）
    func deleteDevicesForRuntime(
        _ runtime: String,
        deleteRuntime: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        PerformanceMonitor.shared.logInfo("开始删除 runtime: \(runtime), deleteRuntime: \(deleteRuntime)")

        isOperating = true
        deletingRuntimeIdentifier = runtime
        deletingRuntimeIncludesRuntime = deleteRuntime

        // 在后台线程执行删除操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var deletionSucceeded = true

            // 1. 直接从系统获取该 runtime 下的所有真实设备（不依赖缓存）
            let devicesToDelete = self.getDevicesForRuntime(runtime)

            if devicesToDelete.isEmpty {
                PerformanceMonitor.shared.logInfo("未找到 runtime \(runtime) 对应的任何设备")
            } else {
                PerformanceMonitor.shared.logInfo("找到 \(devicesToDelete.count) 台设备需要删除")
            }

            // 2. 过滤掉占位设备（无真实 UDID 的设备无法删除）
            let realDevices = devicesToDelete.filter { !$0.isPlaceholder }
            if realDevices.count < devicesToDelete.count {
                let skipped = devicesToDelete.count - realDevices.count
                PerformanceMonitor.shared.logInfo("跳过 \(skipped) 台占位设备（无真实 UDID，无法删除）")
                if realDevices.isEmpty {
                    PerformanceMonitor.shared.logInfo("所有设备均为占位设备，无法执行删除。请尝试重启 Xcode 后重试。")
                    deletionSucceeded = false
                }
            }

            // 3. 删除所有真实设备
            for device in realDevices {
                PerformanceMonitor.shared.logInfo("正在删除设备: \(device.name) (UDID: \(device.udid), State: \(device.state))")

                // 如果设备正在运行，先关闭
                if device.state == "Booted" {
                    PerformanceMonitor.shared.logInfo("设备正在运行，先关闭: \(device.udid)")
                    if self.executeSimctlCommand(arguments: ["shutdown", device.udid]) == false {
                        PerformanceMonitor.shared.logInfo("关闭设备失败: \(device.udid)")
                        // 关闭失败不标记 deletionSucceeded = false，继续尝试删除
                    }
                    // 等待关闭完成
                    Thread.sleep(forTimeInterval: 0.5)
                }

                // 删除设备
                PerformanceMonitor.shared.logInfo("执行删除: \(device.udid)")
                if self.executeSimctlCommand(arguments: ["delete", device.udid]) == false {
                    PerformanceMonitor.shared.logInfo("删除设备失败: \(device.udid)")
                    deletionSucceeded = false
                } else {
                    PerformanceMonitor.shared.logInfo("删除设备成功: \(device.udid)")
                }
            }

            // 4. 如果需要，删除 Runtime 镜像
            if deleteRuntime {
                // 等待设备删除完成
                Thread.sleep(forTimeInterval: 1.0)

                // 获取 Runtime UUID 并删除
                if let runtimeUUID = self.getRuntimeUUID(for: runtime) {
                    PerformanceMonitor.shared.logInfo("删除 Runtime UUID: \(runtimeUUID)")
                    if self.deleteRuntimeWithPrivileges(uuid: runtimeUUID) == false {
                        deletionSucceeded = false
                    }
                } else {
                    PerformanceMonitor.shared.logInfo("获取 Runtime UUID 失败")
                    deletionSucceeded = false
                }
            }

            PerformanceMonitor.shared.logInfo("删除操作完成，结果: \(deletionSucceeded)")

            // 完成后刷新设备列表
            DispatchQueue.main.async {
                self.isOperating = false
                self.deletingRuntimeIdentifier = nil
                self.deletingRuntimeIncludesRuntime = false
                self.forceRefresh()
                completion?(deletionSucceeded)
            }
        }
    }

    /// 直接从系统获取指定 runtime 的所有设备（不依赖缓存）
    private func getDevicesForRuntime(_ runtime: String) -> [SimulatorDevice] {
        PerformanceMonitor.shared.logInfo("getDevicesForRuntime: 开始获取 runtime=\(runtime) 的设备")

        // 优先尝试 JSON 格式
        if let devices = tryGetDevicesJsonFormat(timeoutSeconds: 8.0) {
            let filtered = devices.filter { $0.runtime == runtime }
            PerformanceMonitor.shared.logInfo("getDevicesForRuntime: JSON 成功，获取到 \(devices.count) 台设备，过滤后 \(filtered.count) 台属于 \(runtime)")
            return filtered
        }

        // JSON 失败，尝试文本格式
        PerformanceMonitor.shared.logInfo("getDevicesForRuntime: JSON 失败，尝试文本格式...")
        if let devices = tryGetDevicesTextFormat(timeoutSeconds: 15.0) {
            let filtered = devices.filter { $0.runtime == runtime }
            PerformanceMonitor.shared.logInfo("getDevicesForRuntime: 文本成功，获取到 \(devices.count) 台设备，过滤后 \(filtered.count) 台属于 \(runtime)")
            // 打印前几台设备的信息用于调试
            for (index, device) in filtered.prefix(3).enumerated() {
                PerformanceMonitor.shared.logInfo("  设备\(index): name=\(device.name), udid=\(device.udid), state=\(device.state), isPlaceholder=\(device.isPlaceholder)")
            }
            return filtered
        }

        PerformanceMonitor.shared.logInfo("getDevicesForRuntime: JSON 和文本格式都失败，返回空数组")
        return []
    }

    /// 尝试用 JSON 格式获取设备列表
    private func tryGetDevicesJsonFormat(timeoutSeconds: Double) -> [SimulatorDevice]? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        process.standardOutput = pipe
        process.standardError = pipe

        var didTimeout = false
        var terminationOccurred = false

        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, !terminationOccurred else { return }
            didTimeout = true
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)

        do {
            try process.run()
            process.waitUntilExit()
            terminationOccurred = true
            timeoutWorkItem.cancel()

            if didTimeout {
                PerformanceMonitor.shared.logInfo("getDevices: JSON 格式超时（\(Int(timeoutSeconds))秒）")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            if data.isEmpty {
                PerformanceMonitor.shared.logInfo("getDevices: JSON 格式返回空数据")
                return nil
            }

            PerformanceMonitor.shared.logInfo("getDevices: JSON 格式成功，获取到 \(data.count) 字节")

            let decoder = JSONDecoder()
            let result = try decoder.decode(SimctlListResponse.self, from: data)
            let devices = buildSortedDevices(from: result)
            PerformanceMonitor.shared.logInfo("getDevices: JSON 解析出 \(devices.count) 台设备")
            return devices
        } catch {
            terminationOccurred = true
            timeoutWorkItem.cancel()
            PerformanceMonitor.shared.logInfo("getDevices: JSON 格式失败 - \(error.localizedDescription)")
            return nil
        }
    }

    /// 尝试用文本格式获取设备列表
    private func tryGetDevicesTextFormat(timeoutSeconds: Double) -> [SimulatorDevice]? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices"]
        process.standardOutput = pipe
        process.standardError = pipe

        var didTimeout = false
        var terminationOccurred = false

        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, !terminationOccurred else { return }
            didTimeout = true
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)

        do {
            try process.run()
            process.waitUntilExit()
            terminationOccurred = true
            timeoutWorkItem.cancel()

            if didTimeout {
                PerformanceMonitor.shared.logInfo("getDevices: 文本格式超时（\(Int(timeoutSeconds))秒）")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else {
                PerformanceMonitor.shared.logInfo("getDevices: 文本格式返回空数据")
                return nil
            }

            PerformanceMonitor.shared.logInfo("getDevices: 文本格式成功，获取到 \(output.count) 字符")

            // 使用空的缓存构建设备列表（因为我们需要真实 UDID）
            let originalCache = self.deviceCache
            self.deviceCache = []  // 临时清空，确保生成真实 UDID
            let devices = parseTextFormatDevices(output)
            self.deviceCache = originalCache  // 恢复缓存

            PerformanceMonitor.shared.logInfo("getDevices: 文本格式解析出 \(devices.count) 台设备")
            return devices
        } catch {
            terminationOccurred = true
            timeoutWorkItem.cancel()
            PerformanceMonitor.shared.logDebug("getDevices: 文本格式失败 - \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 获取 Runtime 的 UUID
    /// - Parameter runtimeIdentifier: runtime 标识符，如 "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    /// - Returns: Runtime 的 UUID，如 "1F27DC46-D37C-4CC2-A186-BE0931583640"
    private func getRuntimeUUID(for runtimeIdentifier: String) -> String? {
        do {
            let process = Process()
            let pipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "runtime", "list", "-j"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            // 解析 JSON 获取 UUID
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
                for (uuid, info) in json {
                    if let identifier = info["runtimeIdentifier"] as? String,
                       identifier == runtimeIdentifier {
                        return uuid
                    }
                }
            }
        } catch {
            print("获取 Runtime UUID 失败: \(error.localizedDescription)")
        }
        return nil
    }
    
    /// 使用管理员权限删除 Runtime
    /// - Parameter uuid: Runtime 的 UUID
    private func deleteRuntimeWithPrivileges(uuid: String) -> Bool {
        // 使用 AppleScript 请求管理员权限执行删除命令
        let script = """
        do shell script "xcrun simctl runtime delete \(uuid)" with administrator privileges
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            
            if let error = error {
                print("删除 Runtime 失败: \(error)")
                DispatchQueue.main.async {
                    self.handleError(SimulatorError.commandExecutionFailed("删除 Runtime 失败，可能需要手动执行: sudo xcrun simctl runtime delete \(uuid)"))
                }
                return false
            } else {
                print("Runtime \(uuid) 删除成功")
                return true
            }
        }
        return false
    }

    /// 在 Finder 中显示当前 Runtime 下的模拟器设备目录
    /// - Parameter runtimeIdentifier: runtime 标识符，如 "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    func showSimulatorsInFinder(for runtimeIdentifier: String) {
        guard let group = deviceGroups.first(where: { $0.runtime == runtimeIdentifier }) else {
            handleError(SimulatorError.commandExecutionFailed("未找到该版本的模拟器分组"))
            return
        }

        guard !group.devices.isEmpty else {
            handleError(SimulatorError.commandExecutionFailed("该版本当前还没有模拟器目录"))
            return
        }

        let simulatorRoot = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let fileManager = FileManager.default
        let urls = group.devices.compactMap { device -> URL? in
            let path = (simulatorRoot as NSString).appendingPathComponent(device.udid)
            guard fileManager.fileExists(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }

        guard !urls.isEmpty else {
            handleError(SimulatorError.commandExecutionFailed("未找到该版本对应的模拟器目录"))
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    
    /// 模拟器批量创建模式
    enum DeviceCreationMode {
        case popular
        case all
    }

    /// 为指定 Runtime 创建模拟器设备
    /// - Parameters:
    ///   - runtime: runtime 标识符，如 "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    ///   - mode: 创建设备范围
    func createDevices(for runtime: String, mode: DeviceCreationMode) {
        isOperating = true
        
        // 获取当前已存在的设备名称
        let existingDeviceNames = Set(deviceGroups
            .first(where: { $0.runtime == runtime })?
            .devices.map { $0.name } ?? [])
        
        // 在后台线程执行创建操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. 获取该 runtime 支持的所有设备类型
            let supportedDeviceTypes = self?.getSupportedDeviceTypes(for: runtime) ?? []
            let targetDeviceTypes = self?.filterDeviceTypes(
                supportedDeviceTypes, for: mode) ?? []
            
            if supportedDeviceTypes.isEmpty {
                print("未找到 runtime \(runtime) 支持的设备类型")
                DispatchQueue.main.async {
                    self?.isOperating = false
                    self?.handleError(SimulatorError.commandExecutionFailed("未找到该 Runtime 支持的设备类型"))
                }
                return
            }
            
            var createdCount = 0
            
            // 2. 创建选中的设备
            for deviceType in targetDeviceTypes {
                // 跳过已存在的设备
                if existingDeviceNames.contains(deviceType.name) {
                    continue
                }
                
                if self?.createSimulatorDevice(name: deviceType.name, deviceType: deviceType.identifier, runtime: runtime) == true {
                    createdCount += 1
                }
            }
            
            // 完成后刷新设备列表
            DispatchQueue.main.async {
                self?.isOperating = false
                self?.forceRefresh()
                print("成功创建 \(createdCount) 个模拟器设备")
            }
        }
    }
    
    /// 获取指定 runtime 支持的设备类型列表
    /// - Parameter runtime: runtime 标识符
    /// - Returns: 支持的设备类型数组
    private func getSupportedDeviceTypes(for runtime: String) -> [SupportedDeviceType] {
        do {
            let process = Process()
            let pipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "list", "runtimes", "-j"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            // 解析 JSON
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let runtimes = json["runtimes"] as? [[String: Any]] {
                
                // 查找匹配的 runtime
                for runtimeInfo in runtimes {
                    guard let identifier = runtimeInfo["identifier"] as? String,
                          identifier == runtime,
                          let supportedTypes = runtimeInfo["supportedDeviceTypes"] as? [[String: Any]] else {
                        continue
                    }
                    
                    // 解析支持的设备类型
                    var deviceTypes: [SupportedDeviceType] = []
                    for typeInfo in supportedTypes {
                        if let name = typeInfo["name"] as? String,
                           let typeIdentifier = typeInfo["identifier"] as? String,
                           let productFamily = typeInfo["productFamily"] as? String {
                            // 只添加 iPhone 和 iPad
                            if productFamily == "iPhone" || productFamily == "iPad" {
                                deviceTypes.append(SupportedDeviceType(
                                    name: name,
                                    identifier: typeIdentifier,
                                    productFamily: productFamily
                                ))
                            }
                        }
                    }
                    
                    let iPhones = deviceTypes.filter { $0.productFamily == "iPhone" }
                    let iPads = deviceTypes.filter { $0.productFamily == "iPad" }
                    return iPhones + iPads
                }
            }
        } catch {
            print("获取支持的设备类型失败: \(error.localizedDescription)")
        }
        return []
    }

    private func filterDeviceTypes(
        _ deviceTypes: [SupportedDeviceType], for mode: DeviceCreationMode
    ) -> [SupportedDeviceType] {
        switch mode {
        case .all:
            return deviceTypes
        case .popular:
            return getPopularDeviceTypes(from: deviceTypes)
        }
    }

    private func getPopularDeviceTypes(
        from deviceTypes: [SupportedDeviceType]
    ) -> [SupportedDeviceType] {
        var selected: [SupportedDeviceType] = []
        var selectedIdentifiers = Set<String>()

        func appendFirstMatch(
            preferNonCapacityVariant: Bool = false,
            where predicate: (SupportedDeviceType) -> Bool
        ) {
            let primaryCandidates = deviceTypes.filter {
                predicate($0)
                    && !selectedIdentifiers.contains($0.identifier)
                    && (!preferNonCapacityVariant || !isCapacityVariant($0.name))
            }

            if let match = primaryCandidates.first {
                selected.append(match)
                selectedIdentifiers.insert(match.identifier)
                return
            }

            if let fallback = deviceTypes.first(where: {
                predicate($0) && !selectedIdentifiers.contains($0.identifier)
            }) {
                selected.append(fallback)
                selectedIdentifiers.insert(fallback.identifier)
            }
        }

        func appendLatestSE() {
            let candidates = deviceTypes.filter {
                $0.productFamily == "iPhone"
                    && $0.name.contains("SE")
                    && !selectedIdentifiers.contains($0.identifier)
            }
            let sortedCandidates = candidates.sorted {
                seGeneration(of: $0.name) > seGeneration(of: $1.name)
            }

            if let match = sortedCandidates.first {
                selected.append(match)
                selectedIdentifiers.insert(match.identifier)
            }
        }

        appendFirstMatch { $0.productFamily == "iPhone" && isStandardIPhone($0.name) }
        appendFirstMatch { $0.productFamily == "iPhone" && $0.name.contains("Pro Max") }
        appendFirstMatch {
            $0.productFamily == "iPhone"
                && $0.name.contains("Pro")
                && !$0.name.contains("Max")
        }
        appendLatestSE()
        appendFirstMatch { $0.productFamily == "iPhone" && isAlternativeIPhone($0.name) }
        appendFirstMatch(preferNonCapacityVariant: true) {
            $0.productFamily == "iPad" && $0.name.contains("iPad Pro")
        }
        appendFirstMatch(preferNonCapacityVariant: true) {
            $0.productFamily == "iPad"
                && ($0.name.contains("iPad Air") || isStandardIPad($0.name))
        }

        if selected.isEmpty {
            return Array(deviceTypes.prefix(6))
        }

        return selected
    }

    private func isStandardIPhone(_ name: String) -> Bool {
        guard name.hasPrefix("iPhone ") else { return false }
        return !name.contains("Pro")
            && !name.contains("Plus")
            && !name.contains("mini")
            && !name.contains("SE")
            && !name.contains("Air")
            && !matchesPattern("^iPhone \\d+e$", in: name)
    }

    private func isAlternativeIPhone(_ name: String) -> Bool {
        name.contains("Plus")
            || name.contains("mini")
            || name.contains("SE")
            || name.contains("Air")
            || matchesPattern("^iPhone \\d+e$", in: name)
    }

    private func isStandardIPad(_ name: String) -> Bool {
        name.hasPrefix("iPad ")
            && !name.contains("Pro")
            && !name.contains("Air")
            && !name.contains("mini")
    }

    private func isCapacityVariant(_ name: String) -> Bool {
        name.contains("(16GB)") || name.contains("(8GB)")
    }

    private func matchesPattern(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func seGeneration(of name: String) -> Int {
        let pattern = #"iPhone SE \((\d+)(?:st|nd|rd|th) generation\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }

        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, options: [], range: range),
              let generationRange = Range(match.range(at: 1), in: name) else {
            return 0
        }

        return Int(name[generationRange]) ?? 0
    }
    
    /// 支持的设备类型结构
    private struct SupportedDeviceType {
        let name: String
        let identifier: String
        let productFamily: String
    }
    
    /// 创建单个模拟器设备
    /// - Parameters:
    ///   - name: 设备名称
    ///   - deviceType: 设备类型标识符
    ///   - runtime: runtime 标识符
    /// - Returns: 是否创建成功
    private func createSimulatorDevice(name: String, deviceType: String, runtime: String) -> Bool {
        do {
            let process = Process()
            let pipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "create", name, deviceType, runtime]
            process.standardOutput = pipe
            process.standardError = pipe
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                print("创建成功: \(name)")
                return true
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let error = String(data: data, encoding: .utf8) {
                    print("创建失败 \(name): \(error)")
                }
                return false
            }
        } catch {
            print("创建执行失败 \(name): \(error.localizedDescription)")
            return false
        }
    }
}

// Response models for JSON decoding
struct SimctlListResponse: Codable {
    let devices: [String: [DeviceInfo]]
}

struct DeviceInfo: Codable {
    let udid: String
    let name: String
    let state: String
    let deviceTypeIdentifier: String?
}
