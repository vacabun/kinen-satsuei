# 記念撮影 · kinen satsuei

用于整理偶像拍立得、合影、Live 与旅行回忆的离线笔记。首个实现平台为 iOS，应用目前处于离线原型阶段。

## 设计文档

- [产品与 iOS 交互设计](doc/01-product-ios.md)
- [数据格式与 Git 同步](doc/02-data-git.md)
- [跨平台架构与实施路线](doc/03-architecture-roadmap.md)

## 工作区

| 路径 | 用途 |
| --- | --- |
| `doc/` | 产品、数据协议及架构设计 |
| `apps/ios/` | iOS Xcode 工程 |
| `apps/apple-shared/` | iOS 和 macOS 共用的 Git 设置界面 |
| `apps/macos/` | macOS SwiftUI 工程 |
| `apps/android/` | Android Kotlin / Compose 工程 |
| `apps/windows/` | Windows WPF 工程及共用资料库格式测试 |
| `packages/apple/` | iOS 和 macOS 共用的 Swift Package |
| `packages/core/` | 后续跨平台业务核心 |
| `fixtures/library-v1/` | 跨端协议测试样例，仅使用虚构数据 |
| `.tmp/` | 临时扫描样例、构建和验证产物，已加入忽略规则 |

应用源码仓库与用户自行配置的回忆资料库是两个仓库。开发时使用独立的合成资料库，真实照片、视频、笔记及凭据均应存放于应用沙盒或用户独立目录。

## 运行 iOS 工程

用 Xcode 打开 `apps/ios/KinenSatsuei.xcodeproj`，选择 `KinenSatsuei` 和一个 iOS 17 或更新版本的设备。使用模拟器可查看界面和相册导入。拍立得扫描需要带后置相机的真机，真机构建需要在 Xcode 选择自己的签名团队。

当前工程支持本地建库、添加成员、扫描单张拍立得、导入照片或视频、按全库、成员或团体查看拍立得年度格子图和月度柱状图，可按拍摄日期或入库日期统计，并点选格子查看当天的拍立得，以及编写并关联媒体、Live 和旅行笔记。扫描实时显示加粗的检测边框，默认自动拍摄，也可以切换为手动。拍完可预览、重拍、手动四角校正并填写归属和日期。原图与校正图分开保存。笔记会自动保存本地草稿，从笔记列表可以继续编辑。旅行和 Live 详情可直接新建下级笔记。旅行行程支持按天添加地点、时间和备注，详情会和相关 Live、回忆按日期分组。Markdown 预览支持标题、列表、引用、分隔线、代码块和本地媒体引用。Markdown 表格仍在设计阶段。

在「设置 → 资料库」可以导出备份文件夹，或从含有 `library.json` 的文件夹恢复。恢复生成独立资料库，原资料库可以随时切回。已完成笔记、成员、团体、媒体记录和本机可用附件会进入备份，编辑草稿保留在原设备。

「设置 → Git」可生成或导入 Ed25519 密钥，并通过 SSH 检查远程分支或同步。初次连接需要核对主机指纹。默认只上传笔记和元数据，也可以同步 95 MiB 以内的附件。可预览并恢复远程资料库，冲突页面可比较双方内容并为冲突字段选择版本，再重试同步。GitHub、外部自建服务器与 iPhone 的端到端运行仍待验证。

## 运行 macOS 工程

用 Xcode 打开 `apps/macos/KinenSatsueiMac.xcodeproj`，选择 `KinenSatsueiMac` 和 **My Mac**。最低版本为 macOS 14。桌面版可浏览和编辑笔记，查看媒体与收藏统计，批量拖入照片或视频，并导出或恢复与 iOS 共用的资料库备份。按 ⌘N 新建笔记，按 ⌘I 导入媒体。macOS 与 iOS 共用 Git 设置，可生成或导入 SSH 密钥、核对指纹、同步与恢复。实际设备间的同步和拖放交互仍待实测。

## 运行 Android 工程

在 Android Studio 打开 `apps/android/`，使用 Android SDK 35 构建，最低支持 Android 10。也可从该目录运行 `./gradlew assembleDebug lintDebug`。首版可恢复 iOS 或 macOS 导出的资料库文件夹，浏览笔记、旅行行程、关联媒体以及按成员和团体查看收藏。可用 `fixtures/library-v1/` 验证，里面只有虚构记录和一张合成图片。Android 可新建或修改笔记、关联媒体，并自动保存本地草稿。底栏「添加」支持批量选取照片和视频，也可通过系统相机拍摄拍立得。SSH 同步和拍立得四角校正仍待实现。

## 运行 Windows 工程

在 Windows 安装 .NET 10 SDK 和 Go 1.27.4（确保 go 在 PATH 中）后，运行 `dotnet run --project apps/windows/Kinen.Windows/Kinen.Windows.csproj`。该版本支持恢复资料库备份、搜索和浏览笔记、行程、媒体和拍立得收藏。可运行 `dotnet run --project apps/windows/Kinen.Windows.Tests/Kinen.Windows.Tests.csproj -- fixtures/library-v1` 验证资料库格式。Windows 版可以新建和编辑笔记、自动保存草稿、关联媒体并导出备份。支持选择或拖入照片与视频，按成员或团体归档拍立得。也可以填写 SSH 仓库地址及分支、选择私钥、核对指纹，并在预览后将远端备份恢复为独立资料库。首次 Git 备份可向空分支上传笔记和元数据，并可选择包含照片和视频。可按资料库保存 SSH 连接，私钥和口令由 Windows 当前用户的 DPAPI 保护。保存连接后，可在远端分支仍指向上次备份或恢复的版本时更新备份。仅上传元数据也会保留远端仍被引用的附件。服务器指纹改变时，需核验后手动移除旧连接再重新绑定。拍摄、远端更改合并和双向 SSH 同步仍待实现。

## GitHub Actions

推送分支或提交 Pull Request 时，CI 会运行 Apple 核心测试，并编译 iOS 模拟器版本。推送 Git 标签还会生成 iOS 安装包和 Apple Silicon 模拟器包，例如：

```sh
git tag v0.1.0
git push origin v0.1.0
```

在仓库的 **Actions → iOS build and package → 对应标签的运行记录 → Artifacts** 下载 `kinen-satsuei-ios`。其中 `KinenSatsuei-unsigned.ipa` 需要 Apple 签名才能安装到普通 iPhone，`KinenSatsuei-simulator-arm64.zip` 解压后可安装到 Apple Silicon Mac 的 iOS 模拟器。
