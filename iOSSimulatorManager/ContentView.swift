import SwiftUI

// 主界面布局UI
struct ContentView: View {
    @StateObject private var simulatorManager = SimulatorManager()

    var body: some View {
        /// 设备列表
        List(simulatorManager.devices) { device in
            HStack(spacing: 12) {
                // 左侧设备信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("Runtime: \(device.runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("State: \(device.state)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // 右侧开关
                Toggle("", isOn: Binding(
                    get: { device.state == "Booted" },
                    set: { newValue in
                        if newValue {
                            simulatorManager.bootDevice(udid: device.udid)
                        } else {
                            simulatorManager.shutdownDevice(udid: device.udid)
                        }
                    }
                ))
                .toggleStyle(.switch)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 500, height: 500)
    }
}

#Preview {
    ContentView()
}
