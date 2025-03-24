import Foundation

/// 设备Model
struct SimulatorDevice: Identifiable {
    let id: String
    let udid: String
    let name: String
    let state: String
    let runtime: String

    init(udid: String, name: String, state: String, runtime: String) {
        id = udid
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
    }
}
