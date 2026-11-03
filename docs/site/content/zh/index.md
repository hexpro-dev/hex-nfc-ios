---
title: Hex NFC 文档
description: 从这里进入 Hex NFC 使用手册、工程文档、获取帮助的途径，以及应用的法律页面和安全联系方式。
audience: both
---

本站收录 Hex NFC 的文档。Hex NFC 是 Hex Pro 推出的一款免费应用，可以在 iPhone 上读取和写入 NFC 标签。使用手册面向使用这款应用的人，工程文档面向阅读或修改其代码的人。

## 使用手册

[Hex NFC 使用手册](guide/index.md)介绍应用能做什么、需要什么，每项任务都有单独的一页：读取标签、写入标签、保护标签，以及标签不应答时该怎么办。请从[读取你的第一枚标签](guide/quick-start.md)开始。

## 工程文档

[架构](developer/architecture.md)面向参与开发这款应用的开发者。它逐个目标（target）讲解 Swift 包，包括如何识别芯片、芯片模拟器如何在测试中代替实物标签，最后介绍代码遵循的约定。

在购买要配合这款应用使用的标签之前，或者标签的表现与预期不符时，请阅读[芯片支持矩阵](developer/chip-support-matrix.md)。每个标签系列都有自己的表格。FeliCa 表格只涉及读取和写入；其他表格还包括密码保护、永久锁定和内存转储。该页面会说明其中哪些结果已在实物标签上得到确认，哪些尚未确认。

## 获取帮助 {#get-help}

标签无法扫描或写入时，[标签无法扫描或写入时](guide/troubleshooting.md)逐条说明应用显示的每一条提示以及该怎么做。[常见问题](guide/faq.md)介绍应用的费用和可以运行它的 iPhone 机型。

在应用中，点按主屏幕上的齿轮按钮，然后点按**发送反馈**。消息会直接发送给 Hex Pro，表单会在发送前列出随消息一起发送的内容（应用版本、iOS 版本、设备型号和语言）。你也可以发邮件到 [support@hex.pro](mailto:support@hex.pro)，或使用 [hex.pro 上的联系表单](https://hex.pro/zh/contact?topic=support)。欢迎在 [GitHub 上提交 issue](https://github.com/hexpro-dev/hex-nfc-ios/issues) 报告问题或请求支持新的芯片，[帮助页面](https://apps.hex.pro/zh/hex-nfc/support)汇总了联系 Hex Pro 的所有途径。

## 隐私政策和条款

Hex NFC 的[隐私政策](https://apps.hex.pro/hex-nfc/privacy)和[条款与条件](https://apps.hex.pro/hex-nfc/terms)发布在 apps.hex.pro 上。对其中任何一份有疑问，请发送至 [support@hex.pro](mailto:support@hex.pro)。

## 报告安全问题

请通过 [security@hex.pro](mailto:security@hex.pro) 私下报告漏洞，不要发布在公开论坛或问题跟踪系统中。Hex Pro 会在 72 小时内确认收到报告，随后与报告者合作修复问题，并商定公开披露的日期。问题会在修复发布后公开，或在报告满 90 天时公开，以较早者为准。除非报告者不希望署名，否则会在致谢中列出报告者。
