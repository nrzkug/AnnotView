# AnnotView

<!-- impeccable:product-schema 1 -->

## Platform

macos

原生 macOS 桌面应用，当前最低支持 macOS 26。此处按实际平台记录；不是 Web 或 iOS 应用。

## Users

主要用户是阅读、处理导师论文批注的论文作者。典型情境是导师使用 Adobe Acrobat 审阅 PDF，作者使用 AnnotView 阅读原文、定位批注并逐条处理意见。

## Product Purpose

提供轻量、专注的原生 PDF 阅读与论文批注审阅体验。成功意味着用户能清楚理解批注对应的原文、快速定位意见，并顺畅地处理审阅状态。

用户已确认继续沿用现有产品定位与功能范围；当前关注现有应用的 UI/UX 改进。

## Positioning

聚焦 Acrobat 批注的论文审阅工作流。README 说明项目起因是 Acrobat 对这一阅读场景过重，而 Preview 对部分 Acrobat 文本标记的渲染不够可靠。产品定位是小而专注的阅读器，而非完整 PDF 编辑器。

## Operating Context

- 使用本地 PDF 文档进行论文阅读与审阅。
- 现有界面由页面导航侧栏、PDF 阅读区和批注侧栏组成，支持搜索与批注定位。
- 审阅涉及 Acrobat 生成的文本标记、注释和审阅状态；后续 UI/UX 工作应以这一实际流程为依据。

## Capabilities and Constraints

以下现有能力来自 README 与代码：

- 显示高亮、下划线、删除线、文本注释和插入文本标记。
- 创建、编辑 Acrobat 兼容的高亮、下划线、删除线、便笺和插入文本标记。
- 支持 Accepted、Rejected、Cancelled、Completed 审阅状态。
- 提供 PDF 搜索、缩略图与大纲导航、最近文档和批注状态筛选。
- 实现采用 Swift、SwiftUI、AppKit、PDFKit 与 MuPDF。

本次初始化只记录产品上下文，不改变功能或界面。后续工作聚焦现有应用的 UI/UX；落地页和展示页面不在当前范围内。用户未提出新增平台、功能或专项无障碍标准，不将这些内容视为已确认需求。

## Brand Commitments

保留现有产品名称 AnnotView。本次未提出品牌更换或新增视觉方向。

## Evidence on Hand

- `README.md`：产品起因、定位、功能、系统要求及构建说明。
- `Package.swift`：原生 macOS 平台要求与现有技术依赖。
- `Sources/AnnotView/`：当前功能与界面的实现依据。
- `docs/samples/annotview-review-demo.pdf`：现有审阅示例文档。
- `docs/images/annot_preview.png` 与 `docs/images/annotview-preview.jpg`：已有界面截图；评估当前 UI 时应对照实际实现确认时效。
- `AppBundle/AppIcon.svg` 与 `AppBundle/AppIcon.png`：现有应用图标。

## Product Principles

- 以论文作者阅读和处理导师批注的流程为中心。
- 保持轻量、专注的产品定位。
- UI/UX 改进应帮助用户理解原文与批注的关系、定位意见和辨认处理状态。
- 在现有功能范围内改善体验，不将界面优化自行扩展为产品功能重构。
