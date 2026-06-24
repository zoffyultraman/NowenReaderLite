# NowenReaderLite 修改记录

## 1. NavigationLink 蓝色字体修复

**问题**：列表/网格视图中，NavigationLink 内的标题文字和百分比显示为蓝色（accent color），应为白色（暗色模式）/黑色（亮色模式）。

**修复方案**：对所有 NavigationLink label 内的文字添加 `.foregroundStyle(.primary)`，并对列表视图中的 NavigationLink 添加 `.buttonStyle(.plain)`。

> `.buttonStyle(.plain)` 阻止 SwiftUI 对 NavigationLink 应用默认的 accent tint，`.foregroundStyle(.primary)` 确保文字使用语义颜色（暗色模式→白色，亮色模式→黑色）。

### 修改文件及位置

| 文件 | 修改内容 |
|------|----------|
| `Features/Library/HomeView.swift` | ContinueReadingCard 标题添加 `.foregroundStyle(.primary)`；GroupCardView 标题添加 `.foregroundStyle(.primary)`；GroupListRowView 标题添加 `.foregroundStyle(.primary)`；LibraryContent listView 中 NavigationLink 添加 `.buttonStyle(.plain)` + `.contentShape(Rectangle())` |
| `Features/Library/LibraryView.swift` | ComicCardView 标题添加 `.foregroundStyle(.primary)`；ComicListRowView 标题添加 `.foregroundStyle(.primary)`；LibraryView listView 中 NavigationLink 添加 `.buttonStyle(.plain)` + `.contentShape(Rectangle())` |
| `Features/Detail/GroupDetailView.swift` | VolumeCardView 标题添加 `.foregroundStyle(.primary)`；VolumeListRowView 标题添加 `.foregroundStyle(.primary)`；LazyVStack 中 NavigationLink 添加 `.buttonStyle(.plain)` + `.contentShape(Rectangle())` |
| `Features/Search/SearchView.swift` | SearchResultRow 标题添加 `.foregroundStyle(.primary)`；搜索结果 List 中 NavigationLink 添加 `.buttonStyle(.plain)` + `.contentShape(Rectangle())` |

---

## 2. 登录页添加切换服务器功能

**问题**：LoginView 没有切换服务器的入口。

**修复方案**：在 LoginView 中添加 `@State private var navigateToServerConfig`，添加"切换服务器"按钮跳转至 ServerConfigView，使用 `.navigationDestination` 推入导航栈。

### 修改文件

- **`Features/Auth/LoginView.swift`**
  - 添加 `@State private var navigateToServerConfig = false`
  - 在表单下方添加"切换服务器"按钮
  - 在服务器地址旁添加可点击的 NavigationLink
  - 添加 `.navigationDestination(isPresented: $navigateToServerConfig)` 跳转到 `ServerConfigView(onConnected:, embedsInOwnStack: false)`

---

## 3. ServerConfigView 修复与重构

**问题**：从 LoginView 或 SettingsView 推入 ServerConfigView 时：
1. "连接并继续"按钮点击后无反应（不返回上一页）
2. ServerConfigView 自带 NavigationStack，导致嵌套导航栈

**修复方案**：

- 添加 `@Environment(\.dismiss) private var dismiss`
- 添加 `embedsInOwnStack: Bool = true` 参数
- `connectAndContinue()` 中添加 `dismiss()` 调用
- 用 `View.if` 条件修饰符控制是否包裹 NavigationStack
  - `embedsInOwnStack = true`（默认，从 RootRouter 使用）：包裹 NavigationStack
  - `embedsInOwnStack = false`（从 LoginView/SettingsView 推入）：不包裹 NavigationStack，改用 `.navigationTitle("切换服务器")`

### 修改文件

- **`Features/Auth/ServerConfigView.swift`**
  - 新增 `dismiss` 环境变量
  - 新增 `embedsInOwnStack` 参数
  - `connectAndContinue()` 方法添加 `dismiss()` 调用
  - body 使用 `.if(embedsInOwnStack)` 条件包裹 NavigationStack
  - 新增 `View.if` 扩展（`@ViewBuilder`，条件为 false 时添加 `navigationTitle`）

---

## 4. 设置页添加切换服务器入口

**问题**：SettingsView 需要切换服务器功能。

**修复方案**：将服务器地址行从静态展示改为 NavigationLink，推入 ServerConfigView。

### 修改文件

- **`Features/Settings/SettingsView.swift`**
  - 添加 `@State private var navigateToServerConfig = false`
  - 服务器 Section 中的 `LabeledContent("地址", value: api.serverURL)` 改为 `NavigationLink` 推入 `ServerConfigView(onConnected:, embedsInOwnStack: false)`
  - NavigationLink label 内的 `Label("地址", systemImage: "server.rack")` 添加 `.foregroundStyle(.primary)`
  - 右侧 `Text(api.serverURL)` 添加 `.foregroundStyle(.secondary)`

---

## 注意事项

1. **`View.if` 扩展**：使用了 `@ViewBuilder`，两个分支返回不同类型。SwiftUI 通常能处理这种情况，但如果出现类型系统编译错误，可改为不使用泛型的 `Group { if ... } else { ... }` 写法。

2. **切换服务器后登录状态**：从设置页切换服务器后，`checkAuth()` 会向新服务器验证，若新服务器未登录则 `isLoggedIn` 变为 `false`，RootRouter 会自动跳转到 LoginView。这是正确行为。

3. **编译验证**：由于沙盒限制无法在命令行运行 xcodebuild，请在 Xcode 中手动编译验证。

4. **`.contentShape(Rectangle())`**：`.buttonStyle(.plain)` 会将 NavigationLink 的点击区域限制为可见内容，导致列表行中空白区域无法点击。添加 `.contentShape(Rectangle())` 让整行响应点击。

---

## 5. 漫画阅读器点击翻页

**问题**：漫画阅读时只能滑动翻页，点击右侧无法翻到下一页。

**修复方案**：修改 `PageViewControllerImpl` 的 `handleTap` 方法，将屏幕分为左/中/右三个区域：
- 点击左侧 1/3 → 上一页
- 点击中间 1/3 → 切换覆盖层（工具栏）
- 点击右侧 1/3 → 下一页

上一页/下一页时调用 `setViewControllers(_:direction:animated:)` 实现动画翻页，并在边界触发跨卷切换回调。

### 修改文件

- **`Features/Reader/ComicReaderView.swift`**
  - `PageViewControllerImpl.handleTap(_:)` 从原来只调用 `onToggleOverlay()` 改为根据点击位置分三个区域处理

---

## 6. 服务器列表（服务器记录与快速切换）

**问题**：用户每次切换服务器需要重新输入完整 URL，无法保存和快速切换。

**修复方案**：新建 `ServerListView` 展示所有已保存的服务器记录，支持点击直接切换、左滑删除、+ 按钮添加新服务器。修改 `ServerConfigView` 在连接成功后自动保存/更新服务器记录到 SwiftData。

### 修改文件及位置

| 文件 | 修改内容 |
|------|----------|
| `Features/Auth/ServerListView.swift` | **新建** — 服务器列表页面：`@Query` 查询 `ServerRecord`（按 `lastUsed` 降序），点击切换服务器，滑动删除（当前活跃服务器不可删），+ 按钮推入 `ServerConfigView` 添加新服务器 |
| `Features/Auth/ServerConfigView.swift` | 添加 `import SwiftData`，添加 `@Environment(\.modelContext)`，`connectAndContinue()` 中连接成功后保存/更新 `ServerRecord` 到 SwiftData |
| `Features/Settings/SettingsView.swift` | "地址" → 改为 "服务器"，NavigationLink 指向 `ServerListView()`（替代 `ServerConfigView`），移除 `navigateToServerConfig` state |
| `Features/Auth/LoginView.swift` | `.navigationDestination` 目标从 `ServerConfigView` 改为 `ServerListView()` |

---

## 7. PDF 阅读器

**新增**：独立的 PDF 阅读页面，基于 PDFKit 实现。

**实现方案**：
- `PDFKitView`（`UIViewRepresentable`）桥接 `PDFView`
- 通过 `APIClient.authenticatedRequest` 带 Cookie 认证下载 PDF 数据
- 支持加载状态指示、加载失败提示、重试按钮
- 单页水平滚动模式，黑色背景

### 新增文件

- **`Features/Reader/PDFReaderView.swift`** — PDF 阅读页面 + `PDFKitView` UIKit 桥接

---

## 8. 账号管理系统

**新增**：多账号保存与管理，支持快速切换登录。

**实现方案**：
- 新建 `SavedAccount` SwiftData 模型，存储别名、用户名
- 密码通过 Keychain 安全存储（`KeychainHelper`）
- `AccountManagerView` 展示已保存账号列表，支持添加/编辑/删除
- `AccountEditSheet` 编辑表单，支持密码显隐切换
- `APIClient.quickLogin(account:)` 使用保存的凭据快速登录

### 新增文件

| 文件 | 修改内容 |
|------|----------|
| `Features/Auth/AccountManagerView.swift` | **新建** — 账号管理页面 + `AccountEditSheet` 编辑表单 |
| `Core/Storage/SwiftDataSchema.swift` | **新增** `SavedAccount` 模型（`@Attribute(.unique) var id`，`alias`，`username`，`lastUsed`，`@Relationship var boundServers`） |
| `Core/Network/APIClient.swift` | **新增** `createAccount`、`updateAccount`、`deleteAccount`、`fetchAllAccounts`、`quickLogin` 方法 |
| `Features/Settings/SettingsView.swift` | 服务器 Section 新增"账号管理"导航入口 |

---

## 9. 服务器绑定账号 + 切换超时处理

**问题**：切换服务器后需要手动登录；网络不佳时切换无反馈。

**修复方案**：
- `ServerRecord` 通过 `@Relationship` 关联 `SavedAccount`，实现服务器-账号绑定
- 服务器列表新增长按上下文菜单"绑定账号"，弹出 `ServerBindAccountSheet` 选择绑定
- 切换服务器时自动尝试用绑定账号 `quickLogin`，失败则 `checkAuth`
- 添加 5 秒超时机制（`withTimeout`），超时自动回退到之前的服务器并弹出提示
- 服务器列表展示 HTTPS 锁图标、绑定账号信息、当前活跃标记

### 修改文件

| 文件 | 修改内容 |
|------|----------|
| `Features/Auth/ServerListView.swift` | **重写** — 新增 `ServerBindAccountSheet`、超时回退逻辑、上下文菜单、HTTPS 图标、绑定账号展示 |
| `Core/Storage/SwiftDataSchema.swift` | `ServerRecord` 新增 `@Relationship var boundAccount: SavedAccount?` 和计算属性 `boundAccountId` |
| `Core/Network/APIClient.swift` | **新增** `quickLogin` 方法，支持用保存的账号凭据自动登录 |

---

## 10. HTTP 安全警告 + 缓存管理

**新增**：
- 设置页检测 HTTP 明文连接，显示橙色安全警告
- 缓存 Section 显示当前漫画缓存大小
- "清空缓存"按钮，释放本地 SwiftData 缓存空间

### 修改文件

- **`Features/Settings/SettingsView.swift`**
  - 服务器地址旁新增 HTTPS/HTTP 锁图标
  - HTTP 连接时显示"当前使用 HTTP 明文连接，数据（含密码）可能被截获"警告
  - 新增"缓存"Section：显示缓存大小 + 清空按钮
  - 版本号更新为 `1.0.2`

---

## 11. 阅读目标与增强统计

**新增**：
- 阅读目标设置（按分钟/本数）
- 增强统计数据（更丰富的阅读分析）
- 阅读状态管理（标记阅读状态）

### 修改文件

- **`Core/Network/APIClient.swift`**
  - **新增** `fetchEnhancedStats()` — 增强统计接口
  - **新增** `fetchGoals()` / `setGoal()` / `deleteGoal()` — 阅读目标 CRUD
  - **新增** `updateReadingStatus(comicId:status:)` — 更新阅读状态
  - **新增** `fetchTags()` / `fetchCategories()` — 标签与分类接口
  - **新增** `fetchComicGroupMap()` — 漫画合集映射

---

## 12. 漫画阅读器跨卷切换

**问题**：合集中多卷漫画阅读时，翻到最后一页无法自动进入下一卷。

**修复方案**：
- `ComicReaderView` 新增 `onReachEnd` 回调，到达末尾自动加载下一卷（`groupContext.nextVolumeId`）
- 新增 `onSwipeToPrev` 回调，从第一页向前滑动时加载上一卷末尾
- `ComicReaderViewModel.loadVolume()` 支持指定初始页码

### 修改文件

- **`Features/Reader/ComicReaderView.swift`**
  - `PageViewController` 新增 `onReachEnd` 和 `onSwipeToPrev` 回调参数
  - 到达末尾 → 获取下一卷 ID → `loadVolume(nextId, initialPage: 0)`
  - 滑回开头 → 获取上一卷页数 → `loadVolume(prevId, initialPage: lastPage)`

---

## 13. 标签与分类系统

**新增**：数据模型层面支持标签和分类。

### 修改文件

- **`Models/Comic.swift`**
  - **新增** `TagItem` 结构体（`id`、`name`、`color`）
  - **新增** `CategoryItem` 结构体（`id`、`name`、`slug`）
  - `Comic` 新增 `tags: [TagItem]?`、`categories: [CategoryItem]?`、`coverAspectRatio`、`publisher`、`sortOrder`、`filename` 字段

---

## 14. 小说阅读器章节预加载

**问题**：小说翻章时才发起网络请求，每次切换章节都有明显卡顿。

**修复方案**：内存预缓存 + 后台预加载。

- 新增 `chapterCache: [Int: ChapterContent]` 字典，缓存当前章节 ±2 共 5 章
- `load()` / `loadVolume()` 加载成功后，后台并发预加载相邻 4 章
- `nextChapter()` / `prevChapter()` 优先从缓存读取，命中则零延迟翻页；未命中回退到网络请求
- 缓存淘汰策略：按距离当前章节的远近排序，超出容量时淘汰最远的
- 卷切换时清空缓存，避免跨卷数据污染

### 修改文件

- **`Features/Reader/NovelReaderViewModel`**（`NovelReaderView.swift` 内）
  - **新增** `chapterCache` 字典 + `cacheCapacity = 5`
  - **新增** `applyFromCache(chapter:fontSize:)` — 从缓存应用章节内容
  - **新增** `preloadAdjacentChapters(fontSize:)` — 后台预加载 ±2 章
  - **新增** `evictCache(keeping:)` — 淘汰最远缓存
  - **新增** `clearCache()` — 清空缓存
  - **修改** `load()` — 先查缓存，命中直接渲染并预加载；未命中走网络，成功后缓存并预加载
  - **修改** `loadVolume()` — 切卷时清空缓存，加载后缓存当前章节并预加载
  - **修改** `nextChapter()` / `prevChapter()` — 优先从缓存读取
  - **新增** `Notification.Name.novelChapterCacheClear` 通知名
  - **新增** `init` 中注册通知观察者，监听清缓存事件
  - **新增** `deinit` 中移除观察者

### 设置页联动

- **`Features/Settings/SettingsView.swift`**
  - `clearCache()` 方法末尾新增 `NotificationCenter.default.post(name: .novelChapterCacheClear, object: nil)`，清空 SwiftData 缓存时同步清空小说章节内存缓存
  - 缓存 Section 新增"小说章节缓存"行，显示 `NovelReaderViewModel.totalNovelCacheBytes`
  - "清空缓存"按钮禁用条件改为 `cacheSize == 0 && novelCacheSize == 0`
  - 清空确认弹窗显示两种缓存的总大小
  - `loadCacheSize()` 同时读取小说章节缓存大小

### 小说缓存字节追踪

- **`Features/Reader/NovelReaderView.swift`**（`NovelReaderViewModel` 内）
  - **新增** `chapterCacheBytes` 实例变量 + `totalNovelCacheBytes` 静态变量
  - **新增** `cacheChapter(_:for:)` — 统一缓存写入，自动更新字节计数
  - **新增** `chapterByteSize(_:)` — 估算章节内容 UTF-8 字节数
  - **修改** `evictCache()` / `clearCache()` — 淘汰或清空时同步更新字节计数
  - **修改** `load()` / `loadVolume()` / `preloadAdjacentChapters()` — 改用 `cacheChapter()` 统一入口

---

## 15. 小说阅读器目录功能

**新增**：小说阅读页面底部工具栏新增"目录"按钮，点击弹出章节目录列表，支持快速跳转。

### 修改文件

- **`Features/Reader/NovelReaderView.swift`**
  - `NovelReaderView` 新增 `@State private var showChapterList`
  - 底部工具栏"上一章"与"下一章"之间新增 `Label("目录", systemImage: "list.bullet")` 按钮
  - 新增 `.sheet(isPresented: $showChapterList)` 弹出 `ChapterListView`
  - **新增** `ChapterListView` 组件 — 展示章节目录列表，当前章节高亮 + checkmark 标记，点击跳转到对应章节
  - **新增** `@Published var totalChapters` — 可靠的章节数，优先从 `ChapterContent.totalChapters` 获取，为 nil 时通过 `fetchPages` 兜底
  - **新增** `@Published var chapterTitles` — 章节标题字典，从 `fetchPages` 一次性获取
  - **新增** `extractTitles(from:)` — 从 `PageList.pages` 提取所有章节标题
  - **修改** `load()` — 加载章节后通过 `fetchPages` 获取章节数和标题
  - **修改** `loadVolume()` — 切卷时获取章节数和标题
  - **修改** `nextChapter()` / `preloadAdjacentChapters()` — 使用 `totalChapters` 替代 `chapterContent?.totalChapters`
- **`Models/Comic.swift`**
  - **新增** `PageEntry` 结构体（`index`、`name`、`title`）
  - **修改** `PageList` — 新增 `pages: [PageEntry]?` 字段

---

## 16. 小说章节无缝翻页

**问题**：小说切换章节时页面直接刷新，没有翻页动画，体验割裂。

**修复方案**：利用已预加载的下一章内容，将其页面追加到当前 `pages` 数组，UIPageViewController 的 data source 自动提供下一页，翻页特效自然过渡。翻入新章节后裁剪掉旧章节的页面。

- 阅读接近章节末尾（剩余 2 页）时，自动追加下一章的分页内容
- UIPageViewController 检测到追加模式时，只添加新 VC 不重置位置，翻页特效连续
- 用户翻入新章节后，裁剪旧章节页面、更新当前章节、刷新偏移量
- 若追加未完成用户已到末尾，`onReachEnd` 兜底走原有切章逻辑
- 顶部覆盖层显示相对页码（当前章节内的页码/总页数）
- 阅读记录保存使用相对页码

### 修改文件

- **`Features/Reader/NovelReaderView.swift`**
  - `NovelPager.updateUIViewController` — 新增追加检测：新页面以旧页面开头时只 append VC，不重置位置
  - `NovelReaderViewModel` 新增 `chapterPageOffsets`、`nextChapterAppended` 属性
  - **新增** `tryAppendNextChapter(currentPage:fontSize:)` — 接近末尾时追加下一章页面
  - **新增** `advanceToNextChapter(currentPage:fontSize:)` — 翻入新章节时裁剪旧页面
  - **新增** `relativePageInChapter(_:)` — 获取当前页在章节内的相对页码
  - **新增** `currentChapterPageCount()` — 获取当前章节总页数
  - **新增** `paginateFromContent(_:fontSize:)` — 从 ChapterContent 分页（不更新状态）
  - **修改** `repaginate()` — 重置 `chapterPageOffsets` 和 `nextChapterAppended`
  - **修改** `onPageChanged` — 保存相对页码、触发追加、检测章节切换
  - **修改** `onReachEnd` — 兜底逻辑：追加未完成时手动切章
  - **修改** 顶部覆盖层 — 显示相对页码
  - **修改** 底部"下一章"按钮 — 基于当前章节末尾判断
  - **修改** `saveRecord()` — 使用相对页码保存

---

## v1.0.8 离线模式全面优化

### 17. 离线检测与网络恢复优化

**改动**：统一 `startNetworkRecovery()` 和启动时的 NWPathMonitor 逻辑，pathMonitor 永不取消持续监听。新增 `retryConnection()` 方法供离线提示按钮手动重试。API 超时缩短（request 15s→5s，resource 60s→30s）。新增 `fetchComicGroupMapFull()` 返回完整 comicId→groupIds 映射。

**修改文件**：`Core/Network/APIClient.swift`

---

### 18. 离线合集支持

**改动**：OfflineFileManager 新增 `OfflineGroupMeta` 结构体和 `groups.json` 读写方法。DownloadManager 下载时自动检查并保存漫画所属合集信息。LibraryViewModel 离线时从 groups.json 加载本地合集和重建 groupedComicIds。GroupDetailViewModel 离线时从本地加载合集详情，只显示已下载的卷。

**修改文件**：`Core/Services/OfflineFileManager.swift` · `Core/Services/DownloadManager.swift` · `Features/Library/LibraryView.swift` · `Features/Detail/GroupDetailView.swift`

---

### 19. 下载进度显示修复

**改动**：下载按钮优先看 task 状态，没有 task 才检查磁盘文件。新增 `downloadVersion` @Published 计数器驱动 SwiftUI 刷新。新增 `observeTask()` 通过 Combine 转发 DownloadTask.objectWillChange，`taskCancellables` 字典管理订阅生命周期。

**修改文件**：`Features/Detail/ComicDetailView.swift` · `Core/Services/DownloadManager.swift`

---

### 20. 下载写入缓存

**改动**：新增 `syncComicToCache()` 下载时写入 CachedComic 到 SwiftData，确保离线模式能显示漫画名称和封面。

**修改文件**：`Core/Services/DownloadManager.swift`

---

### 21. 离线进度联网自动同步

**改动**：新增 `onReceive(api.$networkRecovered)` 联网后自动调用 `syncPendingProgress()`，离线阅读进度暂存 PendingProgressManager，联网后逐条同步服务端。

**修改文件**：`App/MainTabView.swift`

---

### 22. 收藏和统计离线守卫

**改动**：离线守卫移到 `isLoading = true` 之前，`onChange(of: isOfflineMode)` 清空数据和加载态。

**修改文件**：`Features/Favorites/FavoritesView.swift` · `Features/Stats/StatsView.swift`

---

### 23. 书架离线刷新

**改动**：LibraryContentView 新增 `@ObservedObject api = APIClient.shared`，`onChange(of: api.isOfflineMode)` 触发 `loadAll(refresh: true)`。loadAll 离线+有数据时不显示加载动画。

**修改文件**：`Features/Library/HomeView.swift` · `Features/Library/LibraryView.swift`

---

### 24. 移除顶部下载进度条

**改动**：移除 MainTabView 中的 `safeAreaInset` + `downloadProgressOverlay` + `downloadProgressText`，简化顶部 UI。

**修改文件**：`App/MainTabView.swift`

---

## v1.1.2 SwiftUI 最佳实践审查

### 25. APIClient 环境注入

**问题**：大量视图在 body 中直接访问 `APIClient.shared` 单例，任何属性变化都会使所有读取该单例的视图失效。

**修复方案**：在 `NowenReaderLiteApp` 根视图注入 `.environment(APIClient.shared)`，所有子视图改用 `@Environment(APIClient.self) private var api` 读取，利用 @Observable 按属性粒度追踪依赖。

**修改文件**：`NowenReaderLiteApp.swift` · `RootRouter.swift` · `MainTabView.swift` · `HomeView.swift` · `FavoritesView.swift` · `SettingsView.swift` · `LoginView.swift` · `ServerListView.swift` · `PDFReaderView.swift` · `ComicDetailView.swift` · `GroupDetailView.swift` · `SearchView.swift` · `StatsView.swift`

---

### 26. Comic 移除 Hashable

**问题**：`Comic` 结构体（20+ 字段）遵循 `Hashable`，`ForEach` 差异比较时会对整个结构体哈希，开销大。实际只需 `Identifiable` 的 `id` 字段。

**修复**：移除 `Hashable` 遵循，保留 `Identifiable`。

**修改文件**：`Models/Comic.swift`

---

### 27. UIScreen.main 缓存修复

**问题**：`NovelReaderViewModel.pageSize` 每次访问都遍历 `UIScreen.main`（iOS 16+ 已弃用）和 `connectedScenes`。

**修复**：改为 `cachedPageSize` 缓存模式，首次访问计算一次，后续返回缓存。使用 `UIWindowScene` + `UIWindow` 替代 `UIScreen.main`。

**修改文件**：`Features/Reader/NovelReaderView.swift`

---

### 28. ChapterContent 新增 mimeType

**改动**：API 端点 `GET /api/comics/:id/chapter/:index` 新增 `mimeType` 字段，`ChapterContent` 模型添加可选 `mimeType` 属性。

**修改文件**：`Models/Comic.swift`

---

### 29. ReadingStats 双格式兼容

**问题**：API `GET /api/stats` 响应结构从扁平格式改为嵌套 `summary` 格式。

**修复**：自定义 `init(from decoder:)` 优先尝试嵌套 `Summary` 格式，回退到扁平格式。添加 `encode(to:)` 输出扁平格式。

**修改文件**：`Models/ReadingStats.swift`

---

### 30. ReadingStatusRequest 字段修正

**问题**：`ReadingStatusRequest` 使用 `readingStatus` 字段名，但 API 期望 `status`。

**修复**：字段名改为 `status`，同步更新 `updateReadingStatus()` 调用。

**修改文件**：`Models/ReadingStats.swift` · `Core/Network/APIClient.swift`

---

### 31. 新增 API 方法

**改动**：
- `fetchComics` 新增 `excludeGrouped`、`libraryId` 参数
- `fetchGroups` / `fetchComicGroupMap` / `fetchComicGroupMapFull` 自动传递 `libraryId`
- 新增 `fetchYearlyStats(year:)` — 年度阅读报告
- 新增 `fetchAccessibleLibraries()` — 用户可访问书库列表

**修改文件**：`Core/Network/APIClient.swift`

---

### 32. 闭包模式优化

**问题**：`ComicDetailContent` 的 `onToggleFavorite` 闭包在父视图每次 body 求值时重建。

**修复**：改为直接传递 `DetailViewModel` 引用，子视图调用 `viewModel.toggleFavorite()`。轻量闭包（ReaderOverlay、NovelOverlay）添加文档注释说明可接受原因。

**修改文件**：`Features/Detail/ComicDetailView.swift` · `Features/Reader/ComicReaderView.swift` · `Features/Reader/NovelReaderView.swift` · `Features/Library/HomeView.swift`

---

## v1.1.3 多书库支持 + API 适配 + UI 重构

### 33. 多书库支持

**改动**：
- 新增 `Library` 模型（`Models/Library.swift`），支持 `id`、`name`、`type`（comic/novel/mixed）、`enabled`、`defaultAccess`、`comicCount`
- `APIClient` 新增 `accessibleLibraries` 属性和 `selectedLibraryId`（UserDefaults 持久化）
- `fetchComics` / `fetchGroups` / `fetchComicGroupMap` 自动传递 `libraryId`
- 应用启动时和网络恢复时自动加载可访问书库列表
- 书库选择器 UI（Capsule Chips，带类型图标，水平滚动）
- 移除漫画/小说 Segmented Tab，内容类型由选中书库自动派生
- 合集逻辑统一应用于漫画、小说和全部模式
- `LibraryViewModel.loadGroups()` 在"全部"模式下分别加载漫画和小说合集

**修改文件**：`Models/Library.swift`（新建）· `Core/Network/APIClient.swift` · `Features/Library/HomeView.swift` · `Features/Library/LibraryView.swift` · `Features/Favorites/FavoritesView.swift` · `Features/Search/SearchView.swift` · `App/MainTabView.swift`

---

### 34. 服务端合集过滤

**改动**：`loadComics()` 使用 `excludeGrouped: true` 参数，让服务端直接过滤已分组漫画，移除冗余的客户端 `groupedComicIds` 过滤和 `loadGroupMap()` 方法。

**修改文件**：`Features/Library/LibraryView.swift`

---

### 35. UI 重构 — 产品级书架体验

**改动**：
- 继续观看提升为 Hero 横向卡片区域（240×140pt，封面+信息+进度条）
- 书库网格卡片统一 3:4 比例、12pt 圆角、`shadow(.black.opacity(0.08), radius: 4, y: 2)`
- 书库选择器改为 iOS 17 风格 Capsule Chips
- 间距规范化：页面 padding 16pt、Section 间距 24pt、卡片间距 12pt
- 底部 Tab Bar 添加 `.toolbarBackground(.ultraThinMaterial, for: .tabBar)` 玻璃态
- 进度条改为低干扰 3pt 样式（`.black.opacity(0.2)` 底色）
- 列表行水平 padding 统一 16pt
- Grid NavigationLink 添加 `.contentShape(Rectangle())`
- LibraryPickerView section header 字体从 `.caption` 升级为 `.subheadline`

**修改文件**：`Features/Library/HomeView.swift` · `Features/Library/LibraryView.swift` · `App/MainTabView.swift`

---

### 36. 版本号升级

**改动**：`CFBundleShortVersionString`、`CURRENT_PROJECT_VERSION`、`MARKETING_VERSION` 从 1.1.2 升级至 1.1.3。

**修改文件**：`Info.plist` · `NowenReaderLite.xcodeproj/project.pbxproj`

---

### 37. 阅读状态 UI

**新增**：阅读状态功能（想看/在读/已读/搁置）完整 UI 实现。

**改动**：
- 详情页新增 `ReadingStatusSection`（Capsule Chips 选择器，点击切换，再次点击取消）
- `DetailViewModel` 新增 `updateReadingStatus`、`syncReadingStatusToCache`
- `Comic` 新增 `withReadingStatus` 扩展
- `ComicCardView` 封面底部显示彩色状态标签（黑色半透明底 + 彩色圆点）
- `ComicListRowView` 作者下方显示彩色状态文字
- 提取 `ReadingStatus` 枚举统一 `label(for:)` / `color(for:)` 方法
- `CachedComic` 新增 `readingStatus` 属性，`from()` / `toComic()` 同步映射

**修改文件**：`Features/Detail/ComicDetailView.swift` · `Features/Library/LibraryView.swift` · `Features/Library/HomeView.swift` · `Features/Favorites/FavoritesView.swift` · `Core/Storage/SwiftDataSchema.swift`

---

### 38. 阅读状态 UI 对齐设计规范

**修复**：阅读状态相关 UI 元素与应用设计规范对齐。

**改动**：
- `ReadingStatusSection` 芯片样式与 `LibraryChip` 统一（padding 14/7、spacing 5、边框、无障碍）
- 状态标签 section padding 16→20pt 匹配详情页兄弟节点
- 卡片状态标签字号 8→9pt，与"小说"标签统一
- 状态标签与进度条合并为单一 VStack 消除重叠
- 状态标签样式统一：黑色半透明底 + 彩色圆点指示器
- 提取 `ReadingStatus` 枚举消除重复的 `statusLabel` / `statusColor`

**修改文件**：`Features/Library/LibraryView.swift` · `Features/Detail/ComicDetailView.swift`

---

### 39. 书库选择器重构

**改动**：书库选择器从水平 Capsule Chips 改为 iOS Menu 下拉菜单。

**改动**：
- 水平滚动 Capsule Chips 替换为 Menu + 全宽选择器（搜索框同款样式：`RoundedRectangle(cornerRadius: 12)`、`systemGray6`、`padding(12)`）
- 节省约 40pt 垂直空间
- 菜单项带类型图标（`photo.stack` / `text.book.closed` / `rectangle.stack`）
- 移除不再使用的 `LibraryChip` 组件
- 选择器移至继续观看上方
- 提取 `selectedLibraryName`、`selectedLibraryIcon`、`libraryIcon(for:)` 到 `APIClient` 消除重复

**修改文件**：`Features/Library/HomeView.swift` · `Core/Network/APIClient.swift`

---

### 40. 导航栏站点名称与 Logo

**改动**：导航栏居中显示服务器站点名称和 Logo。

**改动**：
- `APIClient` 新增 `siteName` 属性（按 serverURL 缓存到 UserDefaults）
- 新增 `fetchSiteSettings()` 方法，登录/认证成功后调用 `GET /api/site-settings` 获取站点名称
- `siteIconURL` 指向固定端点 `{serverURL}/api/site-settings/icon`
- 导航栏 `.principal` 位置显示站点 Logo（22×22，4pt 圆角）+ 站点名称（`.headline`，`.primary`）
- 无缓存时回退到服务器域名
- 移除原"书架"导航标题

**修改文件**：`Core/Network/APIClient.swift` · `Features/Library/HomeView.swift`

---

### 41. 书架视图布局优化

**改动**：
- 导航栏显示站点 Logo + 名称（居中）+ 视图切换/排序按钮（右侧）
- 内容区上方显示当前书库名称标题（`books.vertical` 图标 + `title3.weight(.bold)`）
- 书库下拉选择器位于搜索栏下方、继续观看上方
- 服务器域名作为导航栏标题回退方案

**修改文件**：`Features/Library/HomeView.swift`