import Combine
import Foundation

// 设备管理类
class SimulatorManager: ObservableObject {
    // 分组后的设备列表
    @Published var deviceGroups: [DeviceGroup] = []
    // 保持原有设备列表属性，保证兼容性
    @Published var devices: [SimulatorDevice] = []
    
    private var timer: Timer?
    private var isOperating = false
    
    /// 设备分组模型
    struct DeviceGroup: Identifiable {
        var id: String { runtime }
        let runtime: String
        let displayName: String
        var devices: [SimulatorDevice]
    }

    init() {
        // 异步执行初始化操作
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.cleanUnavailableDevices()

            DispatchQueue.main.async {
                self?.refreshDevices()

                // 创建定时器，实时更新
                self?.timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    guard let self = self, !self.isOperating else { return }
                    self.refreshDevices()
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// 清理不可用的模拟器
    private func cleanUnavailableDevices() {
        do {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "delete", "unavailable"]
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                print("清理完成：已删除不可用的模拟器")
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let error = String(data: data, encoding: .utf8) {
                    print("清理失败：\(error)")
                }
            }
        } catch {
            print("清理执行失败：\(error.localizedDescription)")
        }
    }

    /// 刷新设备列表
    func refreshDevices() {
        guard !isOperating else { return }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "list", "devices", "-j"]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let decoder = JSONDecoder()
            let result = try decoder.decode(SimctlListResponse.self, from: data)

            DispatchQueue.main.async {
                // 创建所有设备的列表
                var allDevices = result.devices.flatMap { key, value in
                    value.map { device in
                        SimulatorDevice(
                            udid: device.udid,
                            name: device.name,
                            state: device.state,
                            runtime: key
                        )
                    }
                }
                
                // 检查数据是否有变化，如果没有变化则不更新UI
                if self.hasDevicesChanged(newDevices: allDevices) {
                    // 数据有变化，执行更新
                    
                    // 按版本号排序所有设备
                    allDevices.sort { (device1, device2) -> Bool in
                        let version1 = self.extractVersionNumber(from: device1.runtime)
                        let version2 = self.extractVersionNumber(from: device2.runtime)
                        
                        // 首先按版本号排序（高版本在前）
                        if version1 != version2 {
                            return version1 > version2
                        }
                        
                        // 如果版本相同，按设备类型排序（iPhone在前）
                        if device1.deviceType != device2.deviceType {
                            if device1.deviceType == .iPhone && device2.deviceType == .iPad {
                                return true
                            }
                            if device1.deviceType == .iPad && device2.deviceType == .iPhone {
                                return false
                            }
                        }
                        
                        // 如果设备类型相同，按屏幕尺寸排序（大屏幕在前）
                        if device1.screenSize != device2.screenSize {
                            return device1.screenSize > device2.screenSize
                        }
                        
                        // 最后按名称字母顺序排序
                        return device1.name < device2.name
                    }
                    
                    // 更新原有的设备列表（保持兼容）
                    self.devices = allDevices
                    
                    // 按运行时版本分组设备
                    var groups: [String: DeviceGroup] = [:]
                    
                    for device in allDevices {
                        let runtimeKey = device.runtime
                        let displayName = self.formatRuntimeName(runtimeKey)
                        
                        if groups[runtimeKey] == nil {
                            groups[runtimeKey] = DeviceGroup(
                                runtime: runtimeKey,
                                displayName: displayName,
                                devices: []
                            )
                        }
                        
                        groups[runtimeKey]?.devices.append(device)
                    }
                    
                    // 对每个组内的设备进行排序
                    for key in groups.keys {
                        groups[key]?.devices.sort { (device1, device2) -> Bool in
                            // 首先按设备类型排序（iPhone在前）
                            if device1.deviceType != device2.deviceType {
                                if device1.deviceType == .iPhone && device2.deviceType == .iPad {
                                    return true
                                }
                                if device1.deviceType == .iPad && device2.deviceType == .iPhone {
                                    return false
                                }
                            }
                            
                            // 同类设备按屏幕尺寸排序（大屏幕在前）
                            if device1.screenSize != device2.screenSize {
                                return device1.screenSize > device2.screenSize
                            }
                            
                            // 最后按名称字母顺序排序
                            return device1.name < device2.name
                        }
                    }
                    
                    // 将分组转换为数组并按版本号排序
                    let sortedGroupKeys = groups.keys.sorted { key1, key2 in
                        let version1 = self.extractVersionNumber(from: key1)
                        let version2 = self.extractVersionNumber(from: key2)
                        return version1 > version2
                    }
                    
                    // 创建最终排序的分组数组
                    self.deviceGroups = sortedGroupKeys.compactMap { groups[$0] }
                }
            }
        } catch {
            print("Error refreshing devices: \(error)")
        }
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
                if newDevice.state != currentDevice.state ||
                   newDevice.name != currentDevice.name ||
                   newDevice.runtime != currentDevice.runtime {
                    return true // 发现差异
                }
            } else {
                return true // 新设备不在当前设备列表中
            }
        }
        
        // 没有发现差异
        return false
    }
    
    /// 格式化运行时名称，便于显示
    /// 例如从 "com.apple.CoreSimulator.SimRuntime.iOS-17-5" 提取出 "iOS 17.5"
    private func formatRuntimeName(_ runtime: String) -> String {
        if let match = runtime.range(of: "iOS-(\\d+)-(\\d+)", options: .regularExpression) {
            let matched = runtime[match]
            let formatted = matched
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
        
        if let match = regex?.firstMatch(in: runtime, options: [], range: NSRange(runtime.startIndex..., in: runtime)) {
            // 提取主版本号和次版本号
            if let majorRange = Range(match.range(at: 1), in: runtime),
               let minorRange = Range(match.range(at: 2), in: runtime) {
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

    /// 开启设备
    func bootDevice(udid: String) {
        isOperating = true

        // 立即更新本地状态
        updateDeviceState(udid: udid, to: "Booted")

        // 执行实际操作
        executeSimctlCommand(arguments: ["boot", udid])

        // 等待启动完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.openSimulatorApp()
            self.refreshDevices()
            self.isOperating = false
        }
    }

    /// 关闭设备
    func shutdownDevice(udid: String) {
        isOperating = true

        // 立即更新本地状态
        updateDeviceState(udid: udid, to: "Shutdown")

        // 执行实际操作
        executeSimctlCommand(arguments: ["shutdown", udid])

        // 等待关闭完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.refreshDevices()
            self.isOperating = false
        }
    }

    /// 更新设备状态（本地）
    private func updateDeviceState(udid: String, to newState: String) {
        DispatchQueue.main.async {
            // 更新原始设备列表
            self.devices = self.devices.map { device in
                if device.udid == udid {
                    return SimulatorDevice(
                        udid: device.udid,
                        name: device.name,
                        state: newState,
                        runtime: device.runtime
                    )
                }
                return device
            }
            
            // 更新分组设备列表
            for i in 0..<self.deviceGroups.count {
                for j in 0..<self.deviceGroups[i].devices.count {
                    if self.deviceGroups[i].devices[j].udid == udid {
                        self.deviceGroups[i].devices[j] = SimulatorDevice(
                            udid: self.deviceGroups[i].devices[j].udid,
                            name: self.deviceGroups[i].devices[j].name,
                            state: newState,
                            runtime: self.deviceGroups[i].devices[j].runtime
                        )
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
            print("Error opening Simulator app: \(error)")
        }
    }

    /// 执行xc命令
    private func executeSimctlCommand(arguments: [String]) {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl"] + arguments
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Error executing simctl command: \(error)")
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
}
