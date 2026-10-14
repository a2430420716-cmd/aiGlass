# L1 协议服务未找到

现场：`aiglass_connect_log_20261014_224821.txt`、`aiglass_http_log_20261014_224850.txt`，App 1.1.6 (124)，L1 0243。

三次 BLE 连接均成功，服务发现后提示“未找到眼镜协议服务”，随后 App 主动断开。后台型号接口已返回 L1 与 Astra A1，尚未发送绑定请求。本提示由 CoreBluetooth 服务识别产生，不能通过后台添加同名型号解决。

当前支持一代服务 AE3A 和二代服务 04000400-0000-1000-8000-009078563412。旧导出日志未包含实际服务列表，无法判断目标未开放协议服务、iOS 缓存还是另一版设备协议。

本轮仅补充诊断：

- 服务发现请求注明查询全部服务。
- `protocol service discovery evidence` 同时写入 Connect 与 BLE 导出日志，包含外设名称/UUID、完整服务 UUID 列表和 primary 标记、期望服务、匹配服务、错误、当前 GATT 阶段与查询次数。
- 缓存服务恢复入口单独标注 `cached-services-before-recovery`，不作为新发现结果。
- `protocol service missing` 明确失败在服务发现，尚未进入设备身份查询。

保持 Build 134，不放宽协议服务校验，不将未知服务当作眼镜命令通道。Windows 仅做静态检查，尚未 Xcode 编译或真机验证。

验证：安装包含此修改的新包，连接 L1 0243，错误出现后导出 Connect 与 BLE 日志；重点查上述两个事件。若服务列表无 AE3A，可对照 nRF Connect 读取的服务列表及设备固件端 GATT 配置；若包含 AE3A，则结合阶段和错误判断 App 回调处理路径。后台 HTTP 日志不是本次服务发现定位的必要材料。
