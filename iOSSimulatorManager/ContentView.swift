import SwiftUI

// 简单的吐司通知视图
struct ToastView: View {
    let message: String
    @Binding var isShowing: Bool
    
    var body: some View {
        VStack {
            Text(message)
                .padding()
                .background(Color.black.opacity(0.7))
                .foregroundColor(Color.white)
                .cornerRadius(10)
                .padding(.horizontal, 20)
        }
        .onAppear {
            // 2秒后自动隐藏
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation {
                    isShowing = false
                }
            }
        }
    }
}

// 主界面布局UI
struct ContentView: View {
    @StateObject private var simulatorManager = SimulatorManager()
    @State private var showingToast = false
    @State private var toastMessage = ""

    var body: some View {
        /// 设备列表（分组显示）
        ZStack {
            List {
                ForEach(simulatorManager.deviceGroups) { group in
                    Section(header: Text(group.displayName).font(.headline)) {
                        ForEach(group.devices) { device in
                            DeviceRow(device: device, 
                                    simulatorManager: simulatorManager,
                                    showToast: { message in
                                        toastMessage = message
                                        withAnimation {
                                            showingToast = true
                                        }
                                    })
                        }
                    }
                }
            }
            .frame(width: 600, height: 500) // 增加宽度以容纳更多内容
            
            // 显示吐司提示
            if showingToast {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage, isShowing: $showingToast)
                    Spacer().frame(height: 50)
                }
            }
        }
    }
}

// 设备行视图组件
struct DeviceRow: View {
    let device: SimulatorDevice
    let simulatorManager: SimulatorManager
    let showToast: (String) -> Void
    
    var body: some View {
        let backColor = Color.clear
        HStack(spacing: 12) {
            // 左侧设备信息
            VStack(alignment: .leading, spacing: 4) {
                // 设备名称行 - 使用更紧凑的布局并增加最大宽度
                HStack(spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail) // 如果文本太长，在末尾截断
                        .frame(maxWidth: 180, alignment: .leading) // 设置最大宽度，避免挤压屏幕尺寸信息
                        .background(backColor)
                    
                    // 显示设备类型和尺寸信息
                    if device.screenSize > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", device.screenSize))\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: 30, alignment: .leading) // 设置最大宽度，占位对齐
                            .background(backColor)
                        
                        // 显示分辨率信息
                        if !device.resolution.isEmpty {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(device.resolution)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: 60, alignment: .leading) // 调整最大宽度，容纳新格式
                                .background(backColor)
                            
                            // 显示逻辑分辨率（屏幕点）
                            if !device.logicalResolution.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(device.logicalResolution)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: 50, alignment: .leading) // 设置最大宽度
                                    .background(backColor)
                            }
                        }
                    }
                }
                
                // 设备状态行
                Text("State: \(device.state)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle()) // 确保整个区域可点击
            .onTapGesture {
                copyDeviceInfoToClipboard()
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
    
    // 复制设备信息到剪贴板
    private func copyDeviceInfoToClipboard() {
        // 构建设备信息字符串
        var infoString = "设备• \(device.name)"
        
        if device.screenSize > 0 {
            infoString += "\n尺寸• \(String(format: "%.1f", device.screenSize))\""
        }
        
        if !device.resolution.isEmpty {
            infoString += "\n分辨率• \(device.resolution)"
        }
        
        if !device.logicalResolution.isEmpty {
            infoString += "\n屏幕点• \(device.logicalResolution)"
        }
        
        // 复制到剪贴板
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(infoString, forType: .string)
        
        // 显示吐司提示
        showToast("已复制")
    }
}

#Preview {
    ContentView()
}
