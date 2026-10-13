# 二代眼镜热点与 OTA：对齐 Android 等待策略

## 问题与范围

9 月 23 日提供的 OTA 失败均在 `connectingWifi`，尚未上传或烧写。旧 iOS 实现要求在系统热点配置返回后的 12 秒内拿到 IPv4 并通过 TCP 80 探测；每次探测最多 3 秒。实际 HTTP 请求另有 2 秒网络等待限制。热点切换期间可能在业务请求开始前被过早终止。

Android `DeviceWifiManager` 在网络请求后最多轮询约 30 秒，不做前置 TCP 探测；OTA 用获得的 Wi-Fi `Network.openConnection` 发请求。PUT 连接超时 10 秒、读取超时 30 秒，完整写出后遇到部分 socket 断连会继续升级。

本次修改共享的 iOS 二代热点和眼镜 HTTP 通道，同时作用于 OTA、相册和录音导入。一代蓝牙升级协议不变。

## 修改后的行为

- `DeviceWifiManager`：系统接受配置后，每秒检查热点身份和有效 Wi-Fi IPv4，最长 30 秒；不再增加独立 TCP 探测作为前提。SSID 已知但不同仍拒绝；只有已完成的 SSID 读取返回不可用，才允许 `192.168.0.*` 子网兜底。每轮身份判断使用本轮完成的样本。SSID 回调迟迟不返不会阻塞截止时间和取消。
- 实际 GET/PUT 仍设置 `requiredInterfaceType=.wifi`，禁止蜂窝。iOS 不直接使用 Android 的 Network API。
- HTTP 连接最多等待 10 秒；不再因为 `.waiting` 持续 2 秒就提前失败。PUT 完成本地发送后最多等 30 秒响应，并保留原有整请求超时保护。GET 原有总时限和文件大小校验继续保留。
- PUT 累计分片状态行，跳过中间 1xx 响应，处理最终 HTTP 状态。同一回调同时给出状态和 reset 时，HTTP 状态优先，4xx/5xx 仍失败。
- 仅非空包完整本地发送成功、没有收到任何响应内容、且收到 `ECONNRESET`、`ECONNABORTED` 或 `EPIPE` 时允许兼容继续。取消、超时、发送未完成、截断/畸形响应都不能转成兼容成功。正常 EOF 没有状态也失败。
- 兼容继续不伪造 HTTP 200；日志记录 `HTTPResponseVerified=false`、`deviceAcceptanceVerified=false`。最终 OTA 完成仍依赖眼镜 BLE 进度；DLL 安装仍有后续设备应答。
- GET/PUT 支持任务取消并主动关连接。串行完成状态防止错误、超时、取消重复完成；热点取消先保留现场再清理配置。

## 日志与验证

热点日志明确只通过身份/IP 校验，`TCPVerified=false HTTPResponseVerified=false`。实际 HTTP 新增 `httpDiagnosticVersion=3`、每请求 `requestID`，记录接口/IP、当前 Wi-Fi 路径、路径/可用性变化和原始 NWError。移除前置探测后，仍能看到真正请求失败时的网络现场。

自动检查通过：`Tests/run-glasses-http-tests.sh` 524 项断言，覆盖分片、1xx、明确拒绝、reset 白名单、未完成发送和取消；Wi-Fi 诊断 86 项、二代 OTA 恢复 82 项，共 692 项。iPhoneOS Debug 无签名构建通过。新增 HTTP 测试已接入蓝牙回归脚本。

待真机复测：热点第 12 秒后才拿到 IP、网络等待超过 2 秒后恢复、HTTP 服务未启动、上传回包 reset、HTTP 500、切换期间取消，以及主固件/蓝牙固件各一轮升级和媒体导入。本次代码对齐不能单独证明真实升级成功率提高；责任端仍需配合眼镜 AP/DHCP/TCP 监听日志确认。
