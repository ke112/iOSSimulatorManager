import SwiftUI

// 主界面布局UI
struct ContentView: View {
    @StateObject private var simulatorManager = SimulatorManager()

    var body: some View {
        /// 设备列表（分组显示）
        List {
            ForEach(simulatorManager.deviceGroups) { group in
                Section(header: Text(group.displayName).font(.headline)) {
                    ForEach(group.devices) { device in
                        DeviceRow(device: device, simulatorManager: simulatorManager)
                    }
                }
            }
        }
        .frame(width: 550, height: 500) // 增加宽度以容纳更多内容
    }
}

// 设备行视图组件
struct DeviceRow: View {
    let device: SimulatorDevice
    let simulatorManager: SimulatorManager
    
    var body: some View {
        HStack(spacing: 12) {
            // 左侧设备信息
            VStack(alignment: .leading, spacing: 4) {
                // 设备名称行 - 使用更紧凑的布局并增加最大宽度
                HStack(spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail) // 如果文本太长，在末尾截断
                        .frame(maxWidth: 200, alignment: .leading) // 设置最大宽度，避免挤压屏幕尺寸信息
                    
                    // 显示设备类型和尺寸信息
                    if device.screenSize > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", device.screenSize))\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize() // 确保尺寸标签不会被压缩
                    }
                }
                
                // 设备状态行
                Text("State: \(device.state)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 20) // 确保总是有足够的空间给开关

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
            .fixedSize() // 确保开关不会被压缩
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
