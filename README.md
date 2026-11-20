# 記念撮影 · kinen satsuei

用于整理偶像拍立得、合影、Live 与旅行回忆的离线手帐。首个实现平台为 iOS，应用目前处于离线原型阶段。

## 设计文档

- [产品与 iOS 交互设计](doc/01-product-ios.md)
- [数据格式与 Git 同步](doc/02-data-git.md)
- [跨平台架构与实施路线](doc/03-architecture-roadmap.md)

## 工作区

| 路径 | 用途 |
| --- | --- |
| `doc/` | 产品、数据协议及架构设计 |
| `apps/ios/` | iOS Xcode 工程 |
| `apps/macos/` | 后续 macOS 工程 |
| `apps/android/` | 后续 Android 工程 |
| `apps/windows/` | 后续 Windows 工程 |
| `packages/apple/` | iOS 和 macOS 共用的 Swift Package |
| `packages/core/` | 后续跨平台业务核心 |
| `fixtures/library-v1/` | 跨端协议测试样例，仅使用虚构数据 |
| `.tmp/` | 临时扫描样例、构建和验证产物，已加入忽略规则 |

应用源码仓库与用户自行配置的回忆资料库是两个仓库。开发时使用独立的合成资料库，真实照片、视频、手帐及凭据均应存放于应用沙盒或用户独立目录。

## 运行 iOS 工程

用 Xcode 打开 `apps/ios/KinenSatsuei.xcodeproj`，选择 `KinenSatsuei` 和一个 iOS 17 或更新版本的设备。使用模拟器可查看界面和相册导入。系统文稿相机需要支持该功能的真机，真机构建需要在 Xcode 选择自己的签名团队。

当前工程支持本地建库、添加成员、扫描单张拍立得、导入照片或视频、按成员统计拍立得，以及编写并关联媒体、Live 和旅行手帐。扫描使用系统文稿相机的矫正结果。Git 同步、手动四角编辑、自动保存草稿和完整 Markdown 排版仍在设计阶段。
