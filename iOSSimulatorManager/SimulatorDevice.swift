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
    let resolution: String // 物理分辨率
    let logicalResolution: String // 屏幕点(逻辑分辨率)
    
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
            self.resolution = Self.extractResolution(from: name)
            self.logicalResolution = Self.extractLogicalResolution(from: name)
        } else if name.contains("iPad") {
            self.deviceType = .iPad
            self.screenSize = Self.extractScreenSize(from: name)
            self.resolution = Self.extractResolution(from: name)
            self.logicalResolution = Self.extractLogicalResolution(from: name)
        } else {
            self.deviceType = .other
            self.screenSize = 0
            self.resolution = ""
            self.logicalResolution = ""
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
    
    /// 从设备名称中提取分辨率信息
    private static func extractResolution(from deviceName: String) -> String {
        // iPhone 16系列分辨率
        if deviceName.contains("iPhone 16 Pro Max") {
            return "1320*2868"
        } else if deviceName.contains("iPhone 16 Pro") {
            return "1206*2622"
        } else if deviceName.contains("iPhone 16 Plus") {
            return "1290*2796"
        } else if deviceName.contains("iPhone 16") && !deviceName.contains("Pro") && !deviceName.contains("Plus") {
            return "1179*2556"
        }
        
        // 常见的iPhone分辨率
        if deviceName.contains("iPhone 15 Pro Max") || deviceName.contains("iPhone 14 Pro Max") {
            return "1290*2796"
        } else if deviceName.contains("iPhone 15 Pro") || deviceName.contains("iPhone 14 Pro") {
            return "1179*2556"
        } else if deviceName.contains("iPhone 15 Plus") || deviceName.contains("iPhone 14 Plus") {
            return "1290*2796"
        } else if deviceName.contains("iPhone 15") || deviceName.contains("iPhone 14") {
            return "1170*2532"
        } else if deviceName.contains("iPhone 13 Pro Max") || deviceName.contains("iPhone 12 Pro Max") {
            return "1284*2778"
        } else if deviceName.contains("iPhone 13 Pro") || deviceName.contains("iPhone 12 Pro") {
            return "1170*2532"
        } else if deviceName.contains("iPhone 13") || deviceName.contains("iPhone 12") {
            return "1170*2532"
        } else if deviceName.contains("iPhone 13 mini") || deviceName.contains("iPhone 12 mini") {
            return "1080*2340"
        } else if deviceName.contains("iPhone SE") {
            return "750*1334"
        }
        
        // 常见的iPad分辨率
        if deviceName.contains("iPad Pro") && deviceName.contains("12.9") {
            return "2048*2732"
        } else if deviceName.contains("iPad Pro") && deviceName.contains("11") {
            return "1668*2388"
        } else if deviceName.contains("iPad Air") {
            return "1640*2360"
        } else if deviceName.contains("iPad mini") {
            return "1488*2266"
        } else if deviceName.contains("iPad") {
            return "1620*2160" // 标准iPad
        }
        
        // 如果无法识别，返回默认值
        return ""
    }
    
    /// 从设备名称中提取逻辑分辨率（屏幕点）信息
    private static func extractLogicalResolution(from deviceName: String) -> String {
        // iPhone 16系列逻辑分辨率
        if deviceName.contains("iPhone 16 Pro Max") {
            return "430*932"
        } else if deviceName.contains("iPhone 16 Pro") {
            return "393*852"
        } else if deviceName.contains("iPhone 16 Plus") {
            return "428*926"
        } else if deviceName.contains("iPhone 16") && !deviceName.contains("Pro") && !deviceName.contains("Plus") {
            return "393*852"
        }
        
        // 常见的iPhone逻辑分辨率
        if deviceName.contains("iPhone 15 Pro Max") || deviceName.contains("iPhone 14 Pro Max") {
            return "430*932"
        } else if deviceName.contains("iPhone 15 Pro") || deviceName.contains("iPhone 14 Pro") {
            return "393*852"
        } else if deviceName.contains("iPhone 15 Plus") || deviceName.contains("iPhone 14 Plus") {
            return "428*926"
        } else if deviceName.contains("iPhone 15") || deviceName.contains("iPhone 14") {
            return "390*844"
        } else if deviceName.contains("iPhone 13 Pro Max") || deviceName.contains("iPhone 12 Pro Max") {
            return "428*926"
        } else if deviceName.contains("iPhone 13 Pro") || deviceName.contains("iPhone 12 Pro") {
            return "390*844"
        } else if deviceName.contains("iPhone 13") || deviceName.contains("iPhone 12") {
            return "390*844"
        } else if deviceName.contains("iPhone 13 mini") || deviceName.contains("iPhone 12 mini") {
            return "375*812"
        } else if deviceName.contains("iPhone SE") {
            return "375*667"
        }
        
        // 常见的iPad逻辑分辨率
        if deviceName.contains("iPad Pro") && deviceName.contains("12.9") {
            return "1024*1366"
        } else if deviceName.contains("iPad Pro") && deviceName.contains("11") {
            return "834*1194"
        } else if deviceName.contains("iPad Air") {
            return "820*1180"
        } else if deviceName.contains("iPad mini") {
            return "744*1133"
        } else if deviceName.contains("iPad") {
            return "810*1080" // 标准iPad
        }
        
        // 如果无法识别，返回默认值
        return ""
    }
}
