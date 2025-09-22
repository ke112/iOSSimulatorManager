import SwiftUI

// Loading状态视图
struct LoadingView: View {
    @State private var animationOffset: Int = 0

    var body: some View {
        VStack(spacing: 20) {
            // iOS风格菊花loading - 固定位置，透明度变化
            ZStack {
                ForEach(0..<12, id: \.self) { index in
                    Rectangle()
                        .fill(Color.primary.opacity(self.opacityForLine(at: index)))
                        .frame(width: 3, height: 12)
                        .cornerRadius(1.5)
                        .offset(y: -20)
                        .rotationEffect(.degrees(Double(index) * 30))
                }
            }
            .frame(width: 50, height: 50)
            .onAppear {
                startAnimation()
            }

            VStack(spacing: 8) {
                Text("正在加载模拟器设备...")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("初次启动可能需要几秒钟时间")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(40)
    }

    // 开始动画
    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            withAnimation(.linear(duration: 0.1)) {
                animationOffset = (animationOffset + 1) % 12
            }
        }
    }

    // 计算每个条形的透明度，创建波浪效果
    private func opacityForLine(at index: Int) -> Double {
        let adjustedIndex = (index - animationOffset + 12) % 12
        let baseOpacity = 0.15
        let maxOpacity = 1.0
        
        // 创建渐变效果，最亮的条逐渐变暗
        if adjustedIndex == 0 {
            return maxOpacity
        } else if adjustedIndex <= 3 {
            return maxOpacity - Double(adjustedIndex) * 0.25
        } else {
            return baseOpacity
        }
    }
}

// 空状态视图
struct EmptyStateView: View {
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // 空状态图标
            VStack(spacing: 16) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 60))
                    .foregroundColor(.gray.opacity(0.6))

                VStack(spacing: 8) {
                    Text("暂无可用的模拟器设备")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text("请在 Xcode 中创建 iOS 模拟器设备，\n或点击刷新重新检测设备")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }

            // 操作按钮
            HStack(spacing: 12) {
                // 刷新按钮
                Button(action: onRefresh) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // 打开Xcode按钮
                Button(action: {
                    // 打开Xcode
                    if let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.apple.dt.Xcode")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("打开 Xcode")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
    }
}

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
            // 主内容区域
            if simulatorManager.isLoading {
                // Loading状态
                LoadingView()
            } else if simulatorManager.deviceGroups.isEmpty {
                // 空状态
                EmptyStateView(onRefresh: {
                    simulatorManager.forceRefresh()
                })
            } else {
                // 设备列表
                List {
                    ForEach(simulatorManager.deviceGroups) { group in
                        Section(header: Text(group.displayName).font(.headline)) {
                            ForEach(group.devices) { device in
                                DeviceRow(
                                    device: device,
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
            }

            // 显示错误提示
            if simulatorManager.hasError, let errorMessage = simulatorManager.lastError {
                VStack {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                        
                        Spacer()
                        
                        Button("关闭") {
                            simulatorManager.clearError()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    
                    Spacer()
                }
            }
            
            // 显示吐司提示
            if showingToast {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage, isShowing: $showingToast)
                    Spacer().frame(height: 50)
                }
            }
        }
        .frame(width: 600, height: 500)  // 增加宽度以容纳更多内容
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
                        .truncationMode(.tail)  // 如果文本太长，在末尾截断
                        .frame(maxWidth: 180, alignment: .leading)  // 设置最大宽度，避免挤压屏幕尺寸信息
                        .background(backColor)

                    // 显示设备类型和尺寸信息
                    if device.screenSize > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", device.screenSize))\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: 30, alignment: .leading)  // 设置最大宽度，占位对齐
                            .background(backColor)

                        // 显示分辨率信息
                        if !device.resolution.isEmpty {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(device.resolution)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: 60, alignment: .leading)  // 调整最大宽度，容纳新格式
                                .background(backColor)

                            // 显示逻辑分辨率（屏幕点）
                            if !device.logicalResolution.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(device.logicalResolution)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: 60, alignment: .leading)  // 设置最大宽度
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
            .contentShape(Rectangle())  // 确保整个区域可点击
            .onTapGesture {
                copyDeviceInfoToClipboard()
            }

            Spacer(minLength: 20)  // 确保总是有足够的空间给开关

            // 右侧开关
            Toggle(
                "",
                isOn: Binding(
                    get: { device.state == "Booted" },
                    set: { newValue in
                        if newValue {
                            simulatorManager.bootDevice(udid: device.udid)
                        } else {
                            simulatorManager.shutdownDevice(udid: device.udid)
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .fixedSize()  // 确保开关不会被压缩
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
