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
        
        // 使用配置管理器获取设备信息
        if let spec = DeviceSpecsManager.shared.getDeviceSpec(for: name) {
            self.screenSize = spec.screenSize
            self.resolution = spec.resolution
            self.logicalResolution = spec.logicalResolution
            
            switch spec.deviceType {
            case "iPhone":
                self.deviceType = .iPhone
            case "iPad":
                self.deviceType = .iPad
            default:
                self.deviceType = .other
            }
        } else {
            // 回退到基本检测
            if name.contains("iPhone") {
                self.deviceType = .iPhone
            } else if name.contains("iPad") {
                self.deviceType = .iPad
            } else {
                self.deviceType = .other
            }
            
            self.screenSize = 0
            self.resolution = ""
            self.logicalResolution = ""
        }
    }
}
