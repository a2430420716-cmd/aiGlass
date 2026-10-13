# iOS 蓝牙、语音唤醒与翻译回归修复

## 现场证据与范围

2026-09-16 的 1.1.6（124）日志显示：自动重连在通知订阅开始约 2 秒后耗尽整轮计时，随后进入手动重试状态。迟到的通知状态回调被丢弃；20:48 至 21:51 仍收到电量等数据，但 App 没有恢复 READY。21:55:25 手动重建连接，21:55:30 READY，返回首页发生在恢复之后。

原日志记录了 `getwakeup0` 的发送。旧代码在 `wakeuprsp0`、`trslatests` 等分支提前返回，没有将这些确认帧写入导出的 BLE 日志。因此不能用日志缺少这些帧来证明设备没有回复。没有本次翻译问题的专用日志，以下为已确认的代码差异修复，仍需真机复测。

## 安卓对齐与 iOS 适配

| 路径 | 实现 |
| --- | --- |
| 蓝牙通知 | 按 Android `BleManager.extractNotificationFrames` 的 10 字节命令头、LE16 长度拆分一次通知中的多帧，逐帧派发唤醒、翻译状态和音频；保留 iOS 截断长包的特征补读，读回包不与旧包拼接。 |
| 语音唤醒 | 对齐 `GlassesSettingActivity` 查询顺序、800 毫秒唤醒查询延迟、220 毫秒发送失败重试一次、设置 5 秒超时后延迟 250 毫秒查询。回包中的 enabled 为设备当前状态；不根据失败码臆测成功。未取得状态时显示读取中或重试，不能把未知当关闭后直接设置。 |
| 对话翻译 | 对齐 `ConversationTranslationActivity`：等待 WebSocket 就绪 20 秒、设备启动 3 秒；就绪事件只触发一次开启；二代启动超时不直接发关闭命令；一代停止后等待尾包，空闲 5 秒或总计 45 秒结束。进入页面仅禁用本地 AI 捕获，避免额外 AI 停止指令与翻译启动竞争。 |
| 翻译音频 | 会话代次隔离旧 WebSocket 回调；重复 ready 保留正在录音的输入状态；停止前发送剩余 PCM；手机录音期间播放译文保持 playAndRecord，避免改变音频会话导致采集停止。有效二代 Opus 数据也可确认设备启动。 |
| 重连 | 服务、特征发现与通知订阅各自计时；计时器带阶段及代次。失败后按当前 central、外设、服务、特征对象和完整订阅状态核验迟到成功结果；一代必须两路通知均成功。失败后继续被动核验，按 30/60/120/240/300 秒退避重新初始化，保留手动硬重建入口。 |
| 生命周期 | 解绑、切设备、OTA 独占、配对重试、蓝牙关闭会使旧连接上下文失效；旧特征回调和重复服务回调不能推进新连接。 |

重连保留 iOS 的系统连接证据门禁；不会仅凭缓存 UUID 连接设备，也不会根据电量包直接标记 READY。CoreBluetooth 没有 Android `BluetoothGatt.close()` 的相同生命周期，因此接口适配保持平台实现。

主要代码：

- [蓝牙管理器](../AIGlass/Bluetooth/AstraA1/AstraA1BleManager.swift)
- [通知拆帧](../AIGlass/Bluetooth/AstraA1/AstraNotificationFramer.swift)
- [语音唤醒设置](../AIGlass/GlassesSettingsView.swift)
- [对话翻译](../AIGlass/ConversationTranslationController.swift)
- [实时翻译服务](../AIGlass/Network/RealtimeTranslationManager.swift)

## 验证

Debug iOS 真机目标整包编译通过（关闭签名）。自动化断言：重连 98、通知拆帧 63、唤醒状态 47、翻译状态 45；原一代协议/适配/OTA 285，合计 538。

```sh
bash Tests/run-bluetooth-regression-tests.sh
bash Tests/run-gen1-tests.sh
```

真机复测：远离后返回且不切页面；设备唤醒预先开启后进入设置；查询中快速操作；对话翻译启动、持续说话、重复启动/停止与切换录音侧；同传边录边播放；一代双通知与停止尾包；恢复过程中解绑或进行 OTA。
