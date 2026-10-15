# GitHub 云打包

Actions 工作流 `iOS IPA` 手动运行，使用明确的 `macos-26-intel` 构建机器，避开 `macos-latest` 当前指向的 ARM64 资源池；使用 CocoaPods 1.17.0、归档 Release、签名导出 IPA。当前版本 1.1.6，Build 139。证书/描述文件不进入源码或构建产物。

仓库 Settings → Secrets and variables → Actions 添加：

| Secret | 内容 |
| --- | --- |
| IOS_CERTIFICATE_BASE64 | 含私钥的 .p12 文件 Base64 |
| IOS_CERTIFICATE_PASSWORD | .p12 导出密码；无密码则留空 |
| IOS_PROFILE_BASE64 | .mobileprovision 文件 Base64 |

Windows 可用以下命令将 Base64 放入剪贴板，随后粘贴到对应 Secret：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('D:\签名\证书.p12')) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes('D:\签名\描述文件.mobileprovision')) | Set-Clipboard
```

描述文件须匹配 `uni.app.UNI03B27DD`，包含工程需要的热点配置、Wi-Fi 信息、关联域及 Apple 登录权限；证书有效且与该描述文件匹配。

Actions → iOS IPA → Run workflow → main，按描述文件选择：

- `release-testing`：Ad Hoc，直接安装测试，测试 iPhone UDID 必须已加入描述文件。
- `debugging`：开发签名，手机须已加入开发描述文件。
- `app-store-connect`：App Store 包，需再上传 App Store Connect/TestFlight，不能直接侧载安装。
- `enterprise`：企业签名，仅适用于对应企业计划。

完成后在该运行的 Artifacts 下载 IPA 压缩包；失败时下载构建日志。产物保留 7 天。此工作流不自动上传 App Store、不自动增加 Build，也不上传 .p12、描述文件或完整归档。

初次工作流尚需云端运行验证；本地 Windows 不能验证 Xcode 编译/导出。若 runner 默认 Xcode 不兼容工程，应从云端日志确定并选择 runner 提供的兼容 Xcode。
