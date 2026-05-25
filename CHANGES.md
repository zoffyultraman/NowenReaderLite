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