---
title: 架构
description: Hex NFC 的 Swift 包如何划分为各个目标，以及每个目标都遵循的约定。
audience: developer
tags:
  - architecture
---

本页概要介绍 Hex NFC 的代码是如何组织的。Hex NFC 是一款面向 iOS 17 及更高版本 iPhone 的 SwiftUI 应用。日常开发所需的细节，请阅读[源代码](https://github.com/hexpro-dev/hex-nfc-ios)。

## 模块关系图

```text
HexNFCApp ─┬─> HexNFCDesign  ──> HexNFCShaders
           ├─> HexNFCStorage ──> HexNFCRecords
           ├─> HexNFCKit     ──> HexNFCRecords
           ├─> HexPromoKit   (vendored, product-less)
           └─> HexNFCTestKit ──> HexNFCKit, HexNFCRecords
HexNFCTagSim ──> HexNFCKit  (test-only)
```

### `HexNFCRecords`

值类型及其编解码器。`NDEFRecord` 枚举有 18 个成员，覆盖应用能读取或写入的每一种记录类型：文本、URI、应用链接、社交（22 个平台）、搜索、文件、邮件、vCard、电话、短信、FaceTime、地图、加密货币、蓝牙连接切换、Wi-Fi WPS、数据（一个 MIME 类型加原始载荷）、快捷指令以及原始。这个目标（target）还包含护照数据组和 Suica 交易历史的模型与解码器，以及 `StationDirectory`：它负责加载应用内置的车站和线路数据，`TransitReader` 用这些数据为车站命名。

`NDEFCodec` 在 `[NDEFRecord]`、传输层面的 `[NDEFPayload]` 和原始消息字节之间双向转换；只有 `HexNFCKit` 负责把 `NDEFPayload` 桥接到 CoreNFC。URI 前缀表（36 个 NDEF URI 标识码，从 `0x00` 到 `0x23`，其中 `0x00` 表示无前缀）也在这里，同时还有按最长前缀匹配的反向查找。

### `HexNFCKit`

NFC 抽象层。`TagSession` 是一个协议：生产代码将它接到 `CoreNFCSession`（封装了 `NFCTagReaderSession`），单元测试则将它接到 `SimulatedSession`。UI 测试以 `--useSimulatedNFC` 启动应用，这会换上 `MockTagSession`。它是 `HexNFCKit` 中的一个替身，只返回固定的记录，没有芯片模型。对这个启动参数的检查不在 `#if DEBUG` 之内，因此这个 mock 也会编译进发布版本。`ConnectedTag` 以 `TagCapability` 选项集的形式提供芯片的能力。实际贴合时，会话无法识别的标签会获得 NDEF 读取、NDEF 写入和原始收发这三项能力。`permanentLock()` 和 Type 2 密码命令只实现一次，位于 `ConnectedTag` 的一个扩展中；当芯片不具备相应能力时，它们会在发送任何帧之前抛出 `TagError.capabilityUnsupported`。生产环境的标签实现 `CoreNFCConnectedTag` 以同样的方式对内存读写做能力检查。原始 `transceive` 不做这项检查。

`TagIdentifier` 为每种 CoreNFC 标签类型选择一种探测方式，`ChipCatalog` 再把探测读到的内容解码为 `ChipProfile`，其中包含芯片的系列、能力和内存布局。NTAG213、NTAG215、NTAG216、NTAG213 TT、NTAG 210µ 和 MIFARE Ultralight EV1 通过 `GET_VERSION` 识别。NTAG210、NTAG212、NTAG213F 和 NTAG216F 也会应答 `GET_VERSION`，但解码器有意不识别它们，因为它们的内存映射还没有在实际芯片上核对过。NTAG424 DNA 通过封装在 APDU 中的 `GET_VERSION` 识别。这个解码器只检查厂商字节和硬件类型字节，因此任何报告 NTAG 4xx 硬件类型的 NXP 芯片都会被识别为 NTAG424 DNA，并获得这款芯片的档案。DESFire 通过其原生的 `GET_VERSION` 帧识别。iOS 经由 NFC Forum NDEF 应用（`D2760000850101`，声明在 eMRTD 的 AID 之后）交来的标签，会先用普通的 SELECT 和 READ BINARY 命令读取（`Type4NDEFProbe`）。以 PHD 记录开头的消息属于 NFC 健康设备：`PHDAssociation` 解析它的关联请求，`HealthDeviceMaker` 根据 OUI 给出制造商名称，其档案只带有 `.personalHealthDevice`，因此写入、擦除和控制台命令会在发出任何帧之前被拒绝。其他标签会收到 `GET_VERSION` 请求，以此识别通过这条途径到达的 NTAG424 DNA 或 DESFire（`identify(type4Version:)`），其余的标签获得通用的 `genericType4` 档案：NDEF 读取、NDEF 写入和原始命令。MIFARE Ultralight C 会拒绝 `GET_VERSION`，而这会使标签进入停止状态，因此会话会重新开始轮询，再通过读取第 0 页和第 28h 页来识别这款芯片。ISO 15693 标签根据 IC 制造商代码加上 Get System Information 的结果来确定：NXP 芯片识别为 ICODE SLIX，报告 80 个块时识别为 SLIX2，其他制造商的芯片一律获得通用的 ISO 15693 档案。护照通过选中 eMRTD 应用来识别。FeliCa 卡获得通用档案，系统代码为 `0003` 时再加上交通卡读取。`ChipCatalog` 还包含 EM Microelectronic V10、V11 和 V16 的档案和一个解码器（`identify(emSignature:)`），但生产环境的会话中没有任何代码调用这个解码器，因此应用在实际贴合时不会识别出 EM 芯片。它所匹配的第 0 页字节（`E0 10`、`E0 11` 和 `E0 16`）是 EM 模拟器自行定义的值，并不是从 EM 实际芯片上读出的值。

高级控制台的内置命令位于 `CommandPresetCatalog` 中，每条命令都标明了它所针对的芯片系列。有适用于 Type 2 芯片（其中包括 EM 芯片）、NTAG424 DNA 和 ICODE SLIX 的预设，没有适用于 DESFire、FeliCa 或护照的预设。EM 预设没有在实际芯片上测试过：V10 的加密模式命令和防拆状态读取使用的是模拟器定义的值，而每条 EM 个性化命令链写入的 Capability Container，其大小字节来自 `ChipCatalog` 中的内存布局，而不是数据手册。控制台会列出所有预设，并且不检查标签的芯片系列就运行已载入的内容，因此没有任何机制阻止把 EM 预设发送给并非 EM 芯片的标签。

这个目标还包含各芯片系列的保护驱动（有保护功能的系列各有一个）、`DESFireNDEFDriver`（它在空白的 MIFARE DESFire EV1、EV2 或 EV3 上创建和移除 NDEF 应用，并根据卡片自身的结构证明某项设置是否由本应用创建）、FeliCa 的 `TransitReader` 以及只读的护照读取器。当证件的 `EF.CardAccess` 声明了 `EPassportReader` 支持的配置时，它运行 PACE，否则运行 BAC。如果已声明的 PACE 失败，读取即告失败，不会改用 BAC 重试。如果能读取芯片的安全对象（`EF.SOD`），它会对读到的每个数据组计算哈希，并与该对象中的哈希列表比较，结果界面会将数据标注为“可能未被篡改”或“可能被篡改”。如果没有可读的安全对象，或者安全对象中没有列出任何已读取的数据组，界面上就完全不显示完整性标注。读取器不验证安全对象的签名或证书链，因此这并不是 Passive Authentication：为匹配篡改后的数据而重写的安全对象同样能通过这项检查，应用所做的任何事情都无法确认护照是真实的。

### `HexNFCStorage`

SwiftData 栈（`SwiftDataStack`），用于以下三个模型：
- `Preset`：有名称的标签映像（一组记录，以及可选的能力要求）。
- `HistoryEntry`：一条扫描历史条目，由扫描流程在每次成功读取标签或交通卡之后写入，读取护照或健康设备时从不写入。重复一次完全相同的扫描时，会更新已有那一行的时间，而不是新增一行。超出最近 50 条的未置顶条目会在每次插入后被裁剪，超过 90 天的未置顶条目会在启动时删除。
- `SavedCommandPreset`：HexNFCKit 中 `CommandPreset` 的存储形式，用于保存用户自己的控制台命令。它已经在 schema 中，但应用中还没有任何代码读写它，高级控制台也只列出内置预设。

iCloud 私有数据库镜像由应用「设置」中的开关背后的一个配置标志控制（默认关闭）。这个标志在启动时打开存储的时候读取，因此更改要等下次启动应用时才生效。如果届时无法以镜像方式打开存储，应用会改为不带镜像打开它，应用的「设置」中会显示同步未在运行。保护用的密码或密钥从不存入 SwiftData：`KeychainProtectionCredentialStore`（以预设为键）和 `KeychainTagCredentialStore`（以标签 UID 为键）将它们作为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 项存放在钥匙串中，这些项不会同步。

### `HexNFCShaders`

用于标志性的扫描、写入和控制台时刻的 Metal 着色器和 CoreHaptics 触感模式。着色器是由 SPM 的 Metal 工具链编译的 `.metal` 源文件；触感模式是 `.ahap` JSON 文件。SwiftUI 修饰符 `.hexHero(...)` 负责播放某个时刻的触感模式。这些时刻的视觉部分各由一个独立的修饰符（`hexScanReveal`、`hexWriteBurst`、`hexConsolePulse`）负责，界面在同一个触发条件上挂接它。

### `HexNFCDesign`

设计令牌（`HexTokens`）、动效预设、标志性的 `HexTransition`（把六边形标志画成三片，当它的 `state` 从 `.hidden` 变为 `.present` 时，三片以错开的弹簧动画依次进入；应用中每个使用它的地方都传入 `.present`，因此错开动画从不播放），以及基础组件：`HexCard`、`HexButton`、`HexField`、`HexBadge`、`HexRecordRow` 和 `HexConsole`。

### `HexNFCApp`

SwiftUI 界面和流程模型，以库的形式构建。Xcode 应用外壳（`HexNFC.xcodeproj`）带有授权（entitlements）和 `Info.plist`，它创建 `AppModel` 并显示 `RootView`。每个流程各有一个 `@Observable` 模型（`ScanFlowModel`、`EditFlowModel` 等）驱动界面。`RootView` 用一个 `NavigationStack` 包住 `HomeView`，并以面板的形式呈现每个流程。从扫描到编辑再到写入的循环是一条面板链（先是 `ScanSheet`，然后是 `TagEditorSheet`，再由它呈现 `WriteSheet`），因此在各步之间根导航栈从不出栈。界面中包括 `RecordEditorSheet`，它按记录种类多态呈现。

这个目标还有三个自己的 HTTP 客户端。`CostsClient` 在根视图出现时获取 Hex NFC 主屏幕上显示的开发成本数字，无需用户进行任何操作。`StationSubmissionClient` 只在用户为内置数据无法命名的交通车站提交名称时运行，它会发送这个名称，并附上车站的线路代码、车站代码和地区代码以及卡片的系统代码。它不会发送卡片的 IDm、余额或交易历史。`FeedbackClient` 只在用户在反馈表单上点按「发送」时运行，它会把用户输入的消息、可选的回复地址，以及表单上显示的应用版本、iOS 版本、设备型号和应用语言发送到 `api.hex.pro`。它不会发送从标签读取的任何内容，也不会发送历史记录中的任何内容。

护照密钥也可以来自相机。`MRZCameraView` 把画面交给设备上的 Vision 文字识别，`HexNFCRecords` 中的 `MRZLineReader` 把识别出的文字行转换为候选密钥，`MRZScanConsensus` 在多帧之间投票，然后才锁定其中一个。不会保存任何画面。

### `HexPromoKit`

主屏幕交叉推广横幅背后的客户端。`PromoManager` 从 Hex Pro 的推广 API 获取当前的推广内容，并将其连同媒体文件缓存到磁盘上；横幅本身由 `HexNFCApp` 绘制。这个目标原样复制自 Hex Pro 自己的推广 SDK，没有做任何本地修改，源代码旁的来源记录文件记下了固定的提交以及每个文件的哈希值。包中没有为它声明产品（product），因为 `HexNFCApp` 是它唯一的使用者。

### `HexNFCTestKit`

与会话无关的测试计划和运行器，通过同一条代码路径同时驱动实际 NFC 硬件和模拟器。它是一个真正链接进应用的库目标，但 `HexNFCApp` 中每个导入它的文件都只在 `#if DEBUG` 下编译，在那里由应用内的硬件测试工具针对实物标签运行这些计划。一个无界面的 XCTest（`TestKitPlanTests`）针对每个具有芯片档案的模拟器运行同样的计划。模拟器与实际芯片之间的偏差，正是通过实际运行中某一步失败、而对应的模拟器却通过来显现的，因此只有在有人用实物标签运行测试工具时，才能发现这种偏差。发布版本会链接这个目标，但没有任何界面能用到它。

### `HexNFCTagSim`（仅用于测试）

进程内的芯片模拟器，涵盖 NTAG 210µ、NTAG213/215/216、NTAG213 TT、NTAG424 DNA、MIFARE Ultralight C、MIFARE Ultralight EV1（48 字节和 128 字节）、MIFARE DESFire EV3、ICODE SLIX 和 SLIX2（同一个 ISO 15693 模拟器，28 块或 80 块）、EM Microelectronic V10/V11/V16、Suica、电子护照（eMRTD）、一枚非 NXP 的 NFC Forum Type 4 标签和一台 NFC 健康设备（`Type4NDEFSimulator`、`PHDCDeviceSimulator`），以及一个用于未识别 Type 2 芯片的后备模拟器。每个模拟器都是遵循 `ChipSimulator` 的类，其原始收发接口是 `func handle(command: Data) -> Data`。模拟器是引用类型，因此测试引起的状态变化（计数器、尝试次数上限、锁定字节）对创建它们的测试可见。测试目标通过 `SimulatedSession(chip:)` 注入模拟器。模拟标签的芯片档案取自它的模拟器，而不是来自识别过程，因此在测试中，每个带档案的模拟器都显示为已识别，EM 模拟器也不例外，尽管应用在实际贴合时并不能识别 EM 芯片。EM Microelectronic 模拟器在第 0 页的标识符、各型号的防拆状态页以及 V10 的加密模式应答上，使用的是自行定义的字节值，而不是数据手册中的值，因为这些芯片的完整命令集并未公开。它们还会以 8 个零字节应答 `GET_VERSION`，而与之最接近的 EM 芯片在已公开的命令集中根本没有 `GET_VERSION`。目前还没有任何 EM 芯片在硬件上测试过，因此 EM 模拟器测试通过并不能说明 EM 实际芯片的情况。

## 约定

- 所有 CoreNFC 访问都在 `HexNFCKit` 内部。其他目标都不导入 `CoreNFC`。
- 品牌颜色使用令牌（`HexTokens.Color.primary`），在 `HexTokens.swift` 之外绝不使用十六进制字面量。
- 面向用户的字符串通过 `Localizable.xcstrings` 提供，`Info.plist` 中的字符串（应用名称和权限提示）通过 `InfoPlist.xcstrings` 提供。
- `TagError` 是 NFC 层的错误类型，它同时带有 `userMessage: LocalizedStringResource` 和 `diagnostics: String`，以便错误报告能包含传输层面的细节。
- 唯一的第三方 Swift 包是 `pointfreeco/swift-snapshot-testing`，而且只有测试目标使用它。`HexPromoKit` 是 Hex Pro 自己的代码，以内置副本的形式纳入，而不是作为依赖拉取。应用还内置了 IBM Plex Mono 字体，采用 SIL OFL 1.1 许可。
