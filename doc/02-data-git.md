# 記念撮影｜数据格式与 Git 同步

## 1. 资料库格式 v1

应用将每个实体保存为独立的 UTF-8 JSON，笔记正文单独保存为 UTF-8 Markdown。本地活动资料库使用相同的目录结构。SQLite 仅用于重建搜索、关系和统计索引，缩略图与播放缓存同样可以重建。

```text
library.json
members/<uuid>.json
groups/<uuid>.json
entries/<uuid>/entry.json
entries/<uuid>/body.md
media/<uuid>.json
assets/sha256/<hash前两位>/<完整hash>
assets/cheki/<归属ID>_<拍摄日期>_<媒体ID>.<扩展名>
```

文件名使用小写 UUID。时间戳采用 UTC RFC 3339，按日的字段使用 YYYY-MM-DD，时区使用 IANA 标识。应用输出 LF 换行和稳定的 JSON 键顺序。数组只有在业务上无序时才按 ID 排序，以保留用户指定的封面和媒体顺序。

| 文件 | 核心字段 |
| --- | --- |
| library.json | formatVersion、libraryId、title |
| members | id、name、groupName、aliases、archived、createdAt、updatedAt、可选 avatarJPEG 与 supportColors |
| groups | id、name、createdAt |
| entry.json | id、kind、title、parentId、startDate、endDate、timeZone、location、mediaIds、coverMediaId、itinerary、createdAt、updatedAt |
| media | id、kind、memberIds、captureDate、capturedAt、captureTimeZone、groupId、note、quarterTurns、original、corrected、correction、createdAt、updatedAt |
| 资产引用 | sha256、byteLength、mimeType、originalFilename、可选 storedFilename，以及可选像素宽高与视频时长 |

`kind` 的值固定为 `memory/live/trip/journal` 或 `cheki/portrait/photo/video`。未知拍摄日期保存为 null。原始文件名仅供导出参考。新拍立得使用 storedFilename 定位，并以成员或团体 ID、拍摄日期和媒体 ID 生成文件名。其他媒体与既有拍立得继续通过哈希定位。文件名不在应用界面显示。修改拍立得归属或日期时，本机已存的文件会按新信息命名，媒体 ID 保持不变。旋转按顺时针 90° 的次数记录在 quarterTurns，显示时应用，原文件像素保持原样。保存或下载时验证素材的哈希和长度。以哈希定位的文件可由多个媒体记录共用。矫正图生成新资产引用，原记录继续引用源图。correction 保存 EXIF 方向归一化后原图的四个角点，坐标范围为 0 到 1，原点位于左下，角点顺序为左上、右上、右下、左下。

旅行行程项包含 id、date、time（可选）、title、location、note，同日无时间或时间相同时沿用数组顺序。Live 和合影依靠 parentId 归属旅行或 Live，形成可独立移动的记录。Markdown 采用 `![替代文字](media:<uuid>)` 插入图像，视频采用 `[标题](media:<uuid>)`。预览通过应用内媒体 ID 解析显示。正文独占一行的媒体引用会在预览中展示，保存时已存在的引用媒体会加入 mediaIds。缺失媒体实体或资产时保留引用，显示相应占位。

成员应援色分为两个独立的可选色位 `first` 和 `second`，使用六位 sRGB 十六进制字符串，两者可以相同。头像以小尺寸 JPEG 的 Base64 数据保存在成员记录中，随笔记和元数据一并备份。缺少这两个字段的旧成员仍可直接读取。

卡片笔记在 `entry.json` 中附带可选的 `noteCards` 数组，保存稳定的卡片 ID、类型、锁定状态和卡片内容。卡片顺序投影为 `body.md`，行程项也投影到 `itinerary` 供时间线使用。旧笔记可在首次编辑卡片时迁移。外部修改正文或行程导致投影不一致时，保留卡片与外部版本供确认。两端都有一致的卡片结构时，合并按卡片 ID 区分移动、编辑和删除。

### 本地事务与迁移

- 导入先把文件写入同卷暂存区，再以原子改名安装资产，最后发布媒体描述文件。磁盘不足或中断时，未发布的资产可由启动恢复流程回收。
- 多文件更新通过串行写入和本地操作日志完成，写入前记录操作意图，启动时按事务状态完成提交或回滚。事务完成后更新索引。打开资料库时可删除并重建损坏索引。
- 草稿保存于本机资料库的隐藏目录 `.drafts/`，同步与资料库导出应排除该目录。点击“完成”才将正文和元数据作为一个事务发布，进入同步队列。
- 迁移前保留旧版本快照，迁移在副本中完成，校验通过后切换。遇到高于应用支持的 formatVersion 时，保留本地数据并停止写入或同步该库。
- 文件夹备份按资料库格式导出。恢复前验证目录、类型、数量、文件大小、ID 和哈希，再将经验证的内容加入独立本地资料库。拒绝符号链接、目录穿越和无法识别的根结构。缺失附件允许浏览文字，损坏的已存在附件标为待重新下载。

## 2. Git 远程与凭据

每个资料库配置一个独立远程和明确分支。连接使用 Git 协议，可填写 GitHub 或自行托管 Git 服务的 SSH URL，包括自定义端口。设备生成专用密钥或导入已有密钥，显示公钥供用户配置远程仓库写入权限。私钥和可选口令放在系统凭据存储，连接和日志界面均隐藏秘密。本地另行保存主机指纹，首次连接显示供用户核对，之后遇到变化暂停同步并要求核验。

iOS 优先验证随应用编译的 libgit2 及其 SSH 后端，使用内存凭据接口读取钥匙串中的密钥。原型须验证选定构建可使用 Ed25519、加密私钥、服务器指纹校验及自定义端口。Git 引擎通过接口与业务层连接，以便换后端或为桌面端接入系统 Git。首版认证以 SSH 为验收对象。HTTPS 与令牌可作为同一接口下的后续扩展。 [libgit2 SSH 内存凭据 API](https://libgit2.org/docs/reference/main/credential/git_credential_ssh_key_memory_new.html)

内置 Git 后端使用固定提交及 SHA-256 校验值引用 libgit2、libssh2 和 OpenSSL 构建产物。已验证 iOS 工程构建和 Mac 上回环 SSH 的指纹检查、内存密钥认证、推送与拉取。iPhone 和外部 Git 服务器间的连接仍待验收。 [二进制来源](https://github.com/swift-developer-tools/swift-libgit2/tree/1.0.1/swift-libgit2-base)

## 3. 同步状态与失败恢复

1. 本地编辑立即写入活动资料库。每次同步读取一致快照并记录对应本地修订号，使用独立 Git 工作目录。快照之后的编辑留待下一次，落库时须对这些编辑再次三方合并。
2. Fetch 后校验远程库 ID、格式、分支和基础结构。当远程分支为空时，可确认后初始化。当连接已有资料库时先预览，再恢复到一个独立的本地资料库。已绑定的设备发现库 ID 变化时暂停。
3. 对比上一次同步的共同祖先、本地快照和远端提交。不同实体可合并，同一实体的独立字段可按字段合并。有序媒体列表或行程被两端重排时要求选择。Markdown 使用三方合并，正文存在重叠改动时保存双方与基线供用户查看。
4. “删除与编辑同时发生”、上级失效、合并后非法的层级关系进入冲突处理。候选结果通过结构验证后生成提交。冲突决议期间继续保有原版本，决议完成后再次校验远端头部。
5. 使用普通 push。远端已更新时重新 fetch 和合并。认证、网络或服务器拒绝均保留本地提交和待同步状态。等待重试前展示原因。推送前记录候选提交和两份资料库快照。被系统中断后，先检查候选提交是否在远端历史中。若已接收，先把前一轮结果与中断后的本机编辑合并，再进行下一轮同步。
6. 只有确认远端已接受提交并且本地成功吸收合并结果后，才更新同步锚点。索引重建完成后刷新首页与统计。在同一资料库内串行运行同步。

分支被强制改写或出现无共同历史时暂停并提示检查远端，保留本地快照。恢复预览只读取资料库文件。Git push 的更新约束参考 [Git push 文档](https://git-scm.com/docs/git-push)。

## 4. 媒体体积和隐私

首版提供两种同步范围，首次启用时由用户选择，并在设置页解释恢复效果。

| 范围 | 远端包含 | 新设备恢复 |
| --- | --- | --- |
| 仅笔记和元数据 | Markdown、成员、笔记与媒体清单 | 可恢复文字和统计，图像与视频显示附件占位 |
| 包含媒体 | 上述内容与大小符合配置的媒体资产 | 可下载已上传附件。超限项继续存在本机，界面列为待处理 |

媒体上传前检查单文件大小和预计传输量。大文件可导出备份，允许用户在同步清单中查看缺失项。缩小同步范围只影响后续上传。Git 历史中的旧附件仍可能被仓库读取者访问。日常删除不会清除已有提交中的历史副本。设置页会明确提示远程仓库能读取内容，并建议使用私有仓库。Git LFS 或外部对象存储在验证跨平台读写和服务兼容性后再纳入设计。
