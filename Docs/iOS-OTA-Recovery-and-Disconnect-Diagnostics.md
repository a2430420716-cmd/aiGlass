# 二代 OTA 失败清理与蓝牙掉线诊断

## 2026-09-23 Android 版本读取对照

以下依据仓库当前 `app/` Android 源码，仅讨论本次二代眼镜，不代表已确认现场 Android 安装包行为。

| 环节 | Android 当前实现 | iOS 当前实现 |
| --- | --- | --- |
| 协议 | `getdevinfo + type0`；`0x05` 查询 `ver28` 蓝牙版本，`0x06` 查询 `ver63` 固件版本 | 相同 |
| 升级页刷新 | `BleForegroundService.queryVersionInfo()` 立即查蓝牙版本，3 秒后查固件版本；不等待前项回包 | 串行补缺 SN，再 `storage → ver28 → ver63`，回包或超时后延迟 3 秒推进 |
| 初连查询 | 服务连接回调不主动全量查询版本；配对、关于、升级页各有查询入口 | 连接就绪后每 3 秒查询基础信息及版本 |
| MTU | CCCD 就绪后先宣布命令通道可用，再请求 MTU 512；版本查询不以协商成功为前提 | 本次接收日志不足以确定实际通知 MTU |
| 截断处理 | 仅拆分单次通知内的完整帧；截断尾包丢弃，没有跨通知拼包或特征补读 | 截断时尝试特征补读；现场收到 ATT `requestNotSupported` 后禁用该会话补读 |
| 升级页失败 | 新版本 fresh 标志控制显示与升级入口；30 秒超时固定 `QUERY_FAILED`，不会因版本缺失无限补查 | 本轮已增加失败门控，固定显示读取失败并允许显式重试 |

Android 入口见 `app/src/main/java/com/mocoviso/glasses/utils/blue/BleForegroundService.kt` 的 `queryVersionInfo`，传输见同目录 `BleManager.kt` 的 `markCommandChannelReady`、`onMtuChanged`、`extractNotificationFrames`，页面见 `ui/activitys/FirmwareUpdateActivity.kt`。全量信息查询的 45 秒超时、关于页的 8 秒缓存回退与升级页 30 秒超时是不同逻辑，不能混用。

按后续要求，iOS 二代初连、关于页及升级页的 `getdevinfo` 间隔由 200ms 改为 3 秒；串行查询仍等待当前回包或超时后再计间隔。一代初连 350ms、串行 200ms 保持原值。页面刷新等待初连队列结束后推进，取消查询时同时取消未执行的下一步，避免多轮队列叠发。初连的蓝牙/固件版本分别约在第 12/15 秒发出，约第 18 秒结束队列；此时补做身份检查，避免原 2.5 秒检查早于 SN 返回。

升级页和关于页没有额外整体截止时间，单项响应超时仍从实际发送时开始；配对身份等待为 60 秒。调整间隔不代表已确认或修复 20/37 字节截断根因，Android 若收到相同截断包也无法解析完整版本。

## 2026-09-23 补充 Wi-Fi 失败现场日志

每次 `DeviceWifiManager.connect` 生成独立 `diagnosticID`，OTA 调用附带升级类型及目标外设 UUID。加入配置、SSID 读取、网络快照、每次 TCP 探测和超时使用同一编号；记录单调时钟及实际耗时，避免把不同重试拼成一次故障。

- 凭据对照：记录设备 `wificonfig` 的原始 SSID/口令字段字节与转义文本、解析后值，以及实际提交 `NEHotspotConfiguration` 的口令和 UTF-8 字节数。空白与 NUL 保留在原始证据中；超长字段只预览前 128 字节并明确 `omittedBytes`，截断字段不标为完整凭据。
- 接口快照：记录接口名、UP/RUNNING/LOOPBACK 标志、IPv4/IPv6、被过滤的 `169.254.*`、地址转换错误及 `getifaddrs` 错误。保留原先选择第一个符合条件的 `en*` IPv4 的逻辑。
- 网络路径：分别观察系统默认路径和限定 Wi-Fi 的路径，记录状态、不可用原因、接口、IPv4/IPv6 支持、蜂窝/Wi-Fi 路由及昂贵/受限标志。路径可用不等于已关联目标眼镜。
- 系统状态：记录 active/inactive/background、受保护数据可用性及生命周期事件；记录 SSID 回调耗时、最后采样年龄与未返回回调。SSID 返回 nil 时标记“系统不暴露具体原因”，不推断设备未连接或权限被拒绝。
- TCP：记录每次尝试的开始、等待、失败、取消、成功和超时，以及 `NWError` 类型、域、代码、原始代码、描述和连接路径。TCP ready 不代表已收到 HTTP 响应。
- 终态：先强制保存 `timeout-before-cleanup` 快照及探测次数，再删除热点配置。`probeAttempts=0` 明确表示尚未执行 TCP 探测；不把它误报为 HTTP 服务故障。

`observedStage` 是证据分类，不是底层原因结论：

| 值 | 当前观察 |
| --- | --- |
| `interfaceEnumerationFailed` | 接口枚举失败，查看错误码 |
| `noWiFiInterface` | 没有发现原判定所用的 `en*` 接口 |
| `wifiInterfaceDown` | 候选接口均未 UP |
| `linkLocalIPv4Only` | 仅观察到被业务过滤的 `169.254.*` IPv4 |
| `noUsableWiFiIPv4` | 没有符合既有规则的 IPv4，可能只有 IPv6 |
| `differentNetwork` | 已知 SSID 不匹配，或 SSID 不可读且地址不在兜底网段 |
| `readyForTCP` | 满足原 TCP 探测前置条件，不代表 TCP 已成功 |

同一现场无变化时每 3 秒留一条快照，变化及终态立即记录；本次等待结束后停止路径和生命周期观察，避免旧任务继续写入。原 12 秒等待窗口、网络判定和升级流程不变；未改手动签名所需的 entitlements/provisioning profile。读取 SSID 的 `wifi-info` 能力仍须由实际签名配置满足，日志不会假装验证过该权限。

复现后立即通过 D 浮窗导出 **Wi-Fi、蓝牙、连接** 三份日志，先看“热点等待超时诊断”，再按 `diagnosticID` 回查接口快照、凭据对照与 TCP 错误。仍需眼镜端关联/DHCP 日志才能确定热点端内部原因。

新增日志测试 `bash Tests/run-wifi-diagnostics-tests.sh`：86 项断言通过，覆盖现场无 IP、接口筛选、网络身份、节流、原始口令和畸形/截断 TLV；真机 SDK Debug 无签名构建通过。尚未进行眼镜硬件复测。

## 2026-09-22 21:37 版本读取失败与页面闪烁

本次 1.1.6 (126) 日志从恢复系统蓝牙会话开始，未覆盖用户描述的首次升级失败及眼镜重启，不能据此确定首次失败原因。

- 21:33:38，App 恢复已有 peripheral 和通知订阅，进入 READY；21:33:39，通知特征 read 回退返回 `CBATTErrorDomain code=6`，本会话禁用补读。
- 21:37 至 21:39，`ver28` / `ver63` 原始回调只有 20 字节，协议声明总长 37 字节，缺少 17 字节。RAW 日志位于拆帧之前，`omittedBytes=0`；可见回调没有对应续包，不能靠解析器补出版本。通知特征不支持 read 不等于不支持 `getdevinfo`。
- 视频两行版本文字在“加载中...”和“—”之间切换。查询失败完成后，页面重新计算升级状态；协调器发现版本缺失，又延迟 2 秒补查，形成约 3 秒的无限循环。
- 21:39 用户断开并重新配对后，版本回包恢复完整 37 字节：蓝牙 `V01.01.01.29-beta1`，固件 `V02.01.01.06-beta1`。
- 21:40 的另一次升级失败发生于热点连接：12 秒内未观察到有效 Wi-Fi IPv4，没有执行 TCP 探测，也没有进入固件上传；清理后收到新 STANDBY，已确认退出准备。

本轮 App 修复：每次连接最多一次自动版本补查，延迟查询去重并隔离旧会话；显式刷新仍可重试，失败不重新开启自动补查。查询结束仍缺版本时固定显示“读取失败”、重连提示与重试按钮，并禁用升级入口及详情页的升级操作；保留已有导航节点，避免失败时把详情页弹回。OTA 开始取消待执行补查，重建连接后允许新一轮查询。

此修复消除无限查询和闪烁，不宣称修复底层长通知缺失。现场可先重新连接；本次日志明确验证有效的是重新配对。发送方向的 `maxWriteWithoutResponse=509` 不能证明接收方向的通知长度，也不能据 20 字节现象锁定 MTU、固件或 iOS 的责任。

新增 `Tests/run-device-version-query-tests.sh` 覆盖重复查询、失败预算、显式重试、OTA 取消及同设备新会话的旧回调隔离。真机需复测：长包缺失后页面稳定失败；点击重试仅发一轮；重新连接后完整版本恢复；OTA 进行中无延迟补查插入。

本轮验证：蓝牙总回归与一代协议回归共 939 项断言通过，其中新增查询门控 27 项；真机 SDK 的 Debug 无签名构建成功。模拟器 Swift 编译通过，但 x86_64 链接被现有 `VideoStabilizeProcessorGL` 的 `PixSmartVsPv*` 缺失符号阻止。尚未进行眼镜硬件复测。

### 21:40 热点连接失败的证据边界

`DeviceWifiManager.waitUntilReady` 只有在获得有效 Wi-Fi IPv4 并通过目标网络校验后才调用 TCP 探测。现场始终停留在 `no-ip`；“无法访问眼镜文件服务”是公共错误文案，不能据此认定 HTTP 服务异常。`toopenwifi` 已获接受、107 字节配置完整、等待期间仍收到 BLE 电量通知；关闭热点与 `otacancel0` 都发生在超时之后，属于失败清理。

`NEHotspotConfigurationManager.apply` 成功只说明配置已应用，不保证已关联或完成 TCP/IP 配置，见 [Apple apply 文档](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager/apply(_:completionhandler:))。当前工程 entitlements 未包含 `com.apple.developer.networking.wifi-info`；[Apple fetchCurrent 文档](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:)) 要求此权限，否则返回 nil。因此 `currentSSID=unavailable` 单独不能证明没有连接，缺少该权限也不能解释 IPv4 缺失。

IPv4 查询把未关联、DHCP 未完成、仅有被过滤的 `169.254.*` 地址、接口枚举失败都折叠为 nil；固定 12 秒后终止不能区分这些原因。下次现场需要热点端关联/DHCP 日志以及手机接口状态快照；不能仅凭本次记录断言密码错误、热点启动失败或延长等待必定成功。本轮未改热点连接策略或签名权限。

## 2026-09-22 现场证据

17:48 的蓝牙固件升级完成，版本从 V01.01.01.28-beta1 变为 V01.01.01.29-beta1。主固件升级没有进入烧写：首次手机连接眼镜热点超时；第二次 17:51:39.199 热点 HTTP 服务已可达，但 GATT 尚未恢复，获取 OTA 路径立即报“设备未连接”，17:51:44.015 才重新 READY。

后续 `toopenwifi` 返回失败，`actionrsp0` 为 `[08,01,06]`，表示升级动作被忙碌状态拒绝。此前失败路径只关闭热点，没有 Android `OtaUpgradeManager` 的 `otacancel0` 退出准备操作。界面 42% 是“打开热点”阶段的固定进度，不表示固件已烧写 42%。

日志还包含 7 条 12 字节 `closewifi` 回执：`63 6C 6F 73 65 77 69 66 69 01 00 01`。该固件使用 9 字节命令头，原解析要求 10 字节，真实成功回执被丢弃后报超时。

## 修复范围

- 仅在帧边界识别精确的 `closewifi(9B) + 01 00 + status(0/1)`，归一化后交给现有状态处理器；保留标准回执、合包、截断补读及完整二进制载荷行为。
- 切换热点后，BLE 操作等待原绑定 UUID 的二代眼镜恢复 READY，默认最长 30 秒；绑定变化或连接到另一副眼镜立即停止。
- 本次 `toopenwifi` 成功回执确认准备已获接受后，准备阶段失败才有权关闭热点并发送无载荷 `otacancel0`。收到忙碌拒绝不自动取消设备原有任务。
- 已发送 `otaupload0/1`，或观察到有效烧写进度，不再自动取消。DLL 安装发送后也受保护；超时保留保护，已知终态回执才解除，BUSY/未知状态不作为写入结束证据。
- 清理期间保持升级流程活动，防止再次点击升级与旧取消流程交错。进度回调不得把已结束的阶段切回去。
- 取消命令排队成功不等于设备已退出。发送后查询状态，最多等待 6 秒，只有新收到的 STANDBY 上报才确认退出；App 本地状态重置不能充当确认。断线无法恢复或未收到状态时明确提示“尚未确认”。

## 掉线日志

每次当前 central 的 `didDisconnectPeripheral` 记录 `disconnect evidence snapshot`，随后约 1 秒复查一次；后台调度可能使实际间隔更长，日志记录实际 elapsedSeconds。D 浮窗导出“连接”日志即可查看。

| assessment | 含义 |
| --- | --- |
| `systemBLEPresentAppSessionDisconnected` | 本次回调确认 App GATT 掉线，实时系统服务查询仍找到目标 BLE 连接 |
| `systemBLENotObserved` | 实时系统 BLE 查询未找到目标，不能据此断言所有硬件蓝牙链路均断开 |
| `queryUnavailable` | 手机蓝牙未就绪，无法执行系统查询 |
| `appGATTRecovered` | 掉线后已观察到同一设备重新 READY |
| `superseded` | 已换设备、central 或新连接会话，旧诊断不应用到新会话 |

同一 incident 关联即时与延迟快照。字段包括回调时间、错误 domain/code、外设 UUID/状态、App 前后台状态、App GATT 状态、实时系统查询及服务过滤、最近 peer 事件及年龄、历史连接标记和音频路由。历史 READY/peerConnected/连接标记不作为实时系统 BLE 存在证据。音频路由独立列出，可能属于其他蓝牙设备；查询命中也不能证明掉线前后物理链路连续。

该修改只增加诊断，不调整重连策略，不能仅靠 iOS 公开接口绝对判定眼镜所有经典蓝牙/物理链路状态。

## 验证与真机复测

```sh
bash Tests/run-bluetooth-regression-tests.sh
bash Tests/run-gen1-tests.sh
```

回归覆盖现场短回执、标准/合并回执、二进制载荷、OTA 准备所有权、烧写和 DLL 保护、同设备重连与目标切换，以及掉线分类中的旧 READY、历史事件、独立音频、查询不可用和后续恢复。

真机需复测：热点连接期间 BLE 中断后能等待恢复；准备阶段失败后能退出并重试；收到烧写进度后不发送取消；系统 BLE 仍连接但 App GATT 断开、眼镜关机/远离、手机关闭蓝牙分别导出快照。当前现场日志不足以确认最初 BLE 掉线的底层原因，新增日志用于继续定位。
