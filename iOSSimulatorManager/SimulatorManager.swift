import Foundation
import Combine

// 设备管理类
class SimulatorManager: ObservableObject {
    @Published var devices: [SimulatorDevice] = []
    private var timer: Timer?
    private var isOperating = false
    
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
                self.devices = result.devices.flatMap { (key, value) in
                    value.map { device in
                        SimulatorDevice(
                            udid: device.udid,
                            name: device.name,
                            state: device.state,
                            runtime: key
                        )
                    }
                }
            }
        } catch {
            print("Error refreshing devices: \(error)")
        }
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
