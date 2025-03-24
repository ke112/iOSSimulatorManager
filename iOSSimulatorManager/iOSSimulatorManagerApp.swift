//
//  iOSSimulatorManagerApp.swift
//  iOSSimulatorManager
//
//  Created by ke on 1/10/25.
//

import SwiftUI

// 程序启动入口
@main
struct iOSSimulatorManagerApp: App {
    var body: some Scene {
        Window("iOS模拟器管理", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        // 添加菜单
        .commands {
            // 添加关于菜单
            CommandGroup(replacing: .appInfo) {
                Button("关于 iOS模拟器管理") {
                    NSApplication.shared.orderFrontStandardAboutPanel()
                }
            }

            // 添加帮助菜单
            CommandGroup(replacing: .help) {
                Button("帮助") {
                    if let url = URL(string: "https://github.com/ke112") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
