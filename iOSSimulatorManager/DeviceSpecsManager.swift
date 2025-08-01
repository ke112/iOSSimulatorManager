import Foundation

struct DeviceSpec: Codable {
    let screenSize: Double
    let resolution: String
    let logicalResolution: String
    let deviceType: String
}

struct DeviceSpecsConfig: Codable {
    let devices: [String: DeviceSpec]
}

class DeviceSpecsManager {
    static let shared = DeviceSpecsManager()
    private var deviceSpecs: [String: DeviceSpec] = [:]
    
    private init() {
        loadDeviceSpecs()
    }
    
    private func loadDeviceSpecs() {
        guard let url = Bundle.main.url(forResource: "DeviceSpecs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(DeviceSpecsConfig.self, from: data) else {
            print("Failed to load device specs configuration")
            return
        }
        
        self.deviceSpecs = config.devices
    }
    
    func getDeviceSpec(for deviceName: String) -> DeviceSpec? {
        // 精确匹配
        if let spec = deviceSpecs[deviceName] {
            return spec
        }
        
        // 模糊匹配 - 从最具体到最通用
        let sortedKeys = deviceSpecs.keys.sorted { $0.count > $1.count }
        
        for key in sortedKeys {
            if deviceName.contains(key) {
                return deviceSpecs[key]
            }
        }
        
        return nil
    }
    
    func getAllSpecs() -> [String: DeviceSpec] {
        return deviceSpecs
    }
}