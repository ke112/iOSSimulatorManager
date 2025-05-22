import Foundation

/// 设备Model
struct SimulatorDevice: Identifiable {
    let id: String
    let udid: String
    let name: String
    let state: String
    let runtime: String
    let deviceType: DeviceType
    let screenSize: Double
    
    /// 设备类型: iPhone或iPad
    enum DeviceType {
        case iPhone
        case iPad
        case other
    }

    init(udid: String, name: String, state: String, runtime: String) {
        id = udid
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        
        // 自动检测设备类型和屏幕尺寸
        if name.contains("iPhone") {
            self.deviceType = .iPhone
            // 从名称中提取尺寸信息
            self.screenSize = Self.extractScreenSize(from: name)
        } else if name.contains("iPad") {
            self.deviceType = .iPad
            self.screenSize = Self.extractScreenSize(from: name)
        } else {
            self.deviceType = .other
            self.screenSize = 0
        }
    }
    
    /// 从设备名称中提取屏幕尺寸信息
    private static func extractScreenSize(from deviceName: String) -> Double {
        // iPhone 16系列尺寸
        if deviceName.contains("iPhone 16 Pro Max") {
            return 6.9 // iPhone 16 Pro Max 使用6.9英寸屏幕
        } else if deviceName.contains("iPhone 16 Pro") {
            return 6.3 // iPhone 16 Pro 使用6.3英寸屏幕
        } else if deviceName.contains("iPhone 16 Plus") {
            return 6.7 // iPhone 16 Plus 使用6.7英寸屏幕
        } else if deviceName.contains("iPhone 16") && !deviceName.contains("Pro") && !deviceName.contains("Plus") {
            return 6.1 // 标准iPhone 16 使用6.1英寸屏幕
        }
        
        // 常见的iPhone尺寸
        if deviceName.contains("iPhone 15 Pro Max") || deviceName.contains("iPhone 14 Pro Max") {
            return 6.7
        } else if deviceName.contains("iPhone 15 Pro") || deviceName.contains("iPhone 14 Pro") {
            return 6.1
        } else if deviceName.contains("iPhone 15 Plus") || deviceName.contains("iPhone 14 Plus") {
            return 6.7
        } else if deviceName.contains("iPhone 15") || deviceName.contains("iPhone 14") {
            return 6.1
        } else if deviceName.contains("iPhone 13 Pro Max") || deviceName.contains("iPhone 12 Pro Max") {
            return 6.7
        } else if deviceName.contains("iPhone 13 Pro") || deviceName.contains("iPhone 12 Pro") {
            return 6.1
        } else if deviceName.contains("iPhone 13") || deviceName.contains("iPhone 12") {
            return 6.1
        } else if deviceName.contains("iPhone 13 mini") || deviceName.contains("iPhone 12 mini") {
            return 5.4
        } else if deviceName.contains("iPhone SE") {
            return 4.7
        }
        
        // 常见的iPad尺寸
        if deviceName.contains("iPad Pro") && deviceName.contains("12.9") {
            return 12.9
        } else if deviceName.contains("iPad Pro") && deviceName.contains("11") {
            return 11.0
        } else if deviceName.contains("iPad Air") {
            return 10.9
        } else if deviceName.contains("iPad mini") {
            return 8.3
        } else if deviceName.contains("iPad") {
            return 10.2 // 标准iPad
        }
        
        // 如果无法识别，返回默认值
        return 0.0
    }
}
