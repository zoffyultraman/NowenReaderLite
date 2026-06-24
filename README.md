<p align="center">
  <img src="logo.png" width="120" alt="NowenReader Lite Logo">
</p>

<h1 align="center">NowenReader Lite</h1>

<p align="center">
  基于 <a href="https://github.com/cropflre/nowen-reader">NowenReader</a> 的轻量级 iOS 原生客户端
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2017.0+-blue" alt="iOS 17.0+">
  <img src="https://img.shields.io/badge/language-Swift-orange" alt="Swift">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0">
</p>

---

## 功能特性

| 分类 | 功能 |
|------|------|
| 📚 多书库 | 自动获取可访问书库、下拉菜单选择器、按书库类型自动筛选内容 |
| 📖 漫画阅读 | UIPageViewController 翻页、点击翻页（左/中/右三区域）、缩放、预加载、AI 超分 |
| 📕 小说阅读 | 分页渲染、字号调节、自动记忆阅读位置、无缝章节切换 |
| 📄 PDF 阅读 | PDFKit 渲染、缩放浏览 |
| 📁 合集管理 | 漫画/小说合集、合集与散本混合排序、已分组内容自动去重 |
| 🔍 全文搜索 | 关键词搜索、按书库范围筛选 |
| ❤️ 收藏 | 一键收藏/取消 |
| 📊 阅读统计 | 阅读时长、进度追踪、年度报告、阅读目标 |
| 🏷 阅读状态 | 想看/在读/已读/搁置，详情页选择 + 卡片/列表标记 |
| 🔄 进度同步 | 跨设备阅读进度同步 |
| 🌗 深色模式 | 自动跟随系统切换 |
| 📱 iPad 适配 | 全设备尺寸适配、自适应网格列数 |
| 🖥 多服务器 | 服务器列表管理、快速切换、多账号管理、站点名称/Logo 展示 |
| 📥 离线下载 | 漫画批量下载、断点续传、存储管理、下载时写入缓存 |
| 📡 离线模式 | 断网自动检测与切换、已下载内容阅读、合集离线浏览、进度离线暂存与联网自动同步、收藏/统计离线守卫 |
| 🤖 AI 超分辨率 | Anime4K / RealESRGAN 模型、实时超分、Tile 分块处理 |

## 技术栈

| 组件 | 技术选型 |
|------|----------|
| UI 框架 | SwiftUI + UIKit 桥接 |
| 架构模式 | MVVM（@Observable + @Environment） |
| 网络层 | URLSession + async/await + Codable |
| 图片加载 | AuthenticatedImage（Cookie 认证） |
| 本地存储 | SwiftData（版本化迁移） |
| 密钥管理 | Keychain |
| 漫画阅读器 | UIPageViewController (.pageCurl / .scroll) |
| PDF 阅读器 | PDFKit |
| 离线存储 | OfflineFileManager（文件系统 + JSON 元数据） |
| 网络监控 | NWPathMonitor + 服务器可达性测试 |
| AI 超分 | Core ML（Anime4K / RealESRGAN） |
| 最低版本 | iOS 17.0 |

## 项目结构

```
NowenReaderLite/
├── App/                        # 入口、路由、TabBar
│   ├── NowenReaderLiteApp.swift
│   ├── RootRouter.swift
│   └── MainTabView.swift
├── Core/
│   ├── Network/                # API 客户端、图片加载
│   │   ├── APIClient.swift
│   │   └── AuthenticatedImage.swift
│   ├── Services/               # 业务服务
│   │   ├── DownloadManager.swift    # 下载管理器
│   │   ├── OfflineFileManager.swift # 离线文件管理
│   │   ├── ImageCache.swift         # 图片缓存
│   │   ├── ChapterCache.swift       # 小说章节缓存
│   │   ├── ImageUpscaler.swift      # AI 超分辨率
│   │   └── PaginationService.swift  # 分页服务
│   ├── Storage/                # SwiftData、Keychain、阅读记录
│   │   ├── SwiftDataSchema.swift
│   │   ├── KeychainHelper.swift
│   │   ├── ReadingRecordManager.swift
│   │   └── PendingProgressManager.swift  # 离线进度暂存
│   └── Extensions/             # 工具扩展
├── Features/
│   ├── Auth/                   # 服务器配置、登录/注册、服务器列表、账号管理
│   ├── Library/                # 书架首页、书库选择器、继续观看、内容列表
│   ├── Detail/                 # 漫画详情、合集详情
│   ├── Reader/                 # 漫画/小说/PDF 阅读器
│   ├── Search/                 # 全文搜索
│   ├── Favorites/              # 收藏管理
│   ├── Downloads/              # 下载列表管理
│   ├── Stats/                  # 阅读统计、年度报告、阅读目标
│   └── Settings/               # 应用设置、AI 超分配置
├── Models/                     # Codable 数据模型
│   ├── Comic.swift             # 漫画/小说、标签、分类、章节
│   ├── ComicGroup.swift        # 合集模型
│   ├── Library.swift           # 书库模型
│   ├── AuthUser.swift          # 用户认证模型
│   └── ReadingStats.swift      # 统计、目标、年度报告
├── Assets.xcassets/            # 图片、图标资源
├── anime4k-4x-a-hq.mlpackage   # Anime4K 超分模型
├── RealESRGAN_x4plus_Anime.mlpackage  # RealESRGAN 超分模型
├── Info.plist
└── NowenReaderLite.xcodeproj/
```

## 快速开始

### 环境要求

- macOS + Xcode 15+
- iOS 17.0+ 模拟器或真机
- 一个运行中的 [NowenReader](https://github.com/cropflre/nowen-reader) 服务端

### 运行步骤

1. 用 Xcode 打开 `NowenReaderLite.xcodeproj`
2. 配置你的**签名证书**
3. 选择模拟器或真机，点击 **Run**
4. 首次启动输入 NowenReader 服务器地址
5. 注册 / 登录后即可使用

## 首页布局

```
┌──────────────────────────────────────┐
│           [🟠] 站点名称       [☰] [↕] │  ← 导航栏：站点 Logo + 名称
├──────────────────────────────────────┤
│  🔍 搜索漫画或小说...                 │  ← 搜索栏
│  ┌──────────────────────────────┐    │
│  │ 📚 全部书库               ▼  │    │  ← 书库下拉选择器
│  └──────────────────────────────┘    │
│  📖 继续观看                          │
│  ┌──────┐ ┌──────┐ ┌──────┐         │  ← Hero 横向卡片
│  └──────┘ └──────┘ └──────┘         │
│  📚 全部书库                          │  ← 书库名称标题
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐        │  ← 网格/列表内容
│  └────┘ └────┘ └────┘ └────┘        │
└──────────────────────────────────────┘
```

## 架构设计

```
┌─────────────────────────┐
│    iOS SwiftUI App      │
├─────────────────────────┤
│  UI / 阅读器 / 缓存层   │
│  ViewModel (@Observable) │
│  @Environment 注入       │
│  API Client             │
└───────────┬─────────────┘
            │ RESTful API
┌───────────▼─────────────┐
│   NowenReader Server    │
├─────────────────────────┤
│  用户系统 / 多书库 / 章节│
│  合集 / 标签 / 分类      │
│  图片 / EPUB / 数据管理  │
└─────────────────────────┘
```

**设计原则：**
- **API 驱动** — iOS 端不做任何解析逻辑，完全依赖服务端
- **强缓存** — SwiftData 本地缓存，提升加载体验
- **原生优先** — 纯 SwiftUI + UIKit，不复用 Web UI
- **UI 与数据解耦** — MVVM 分层，@Observable 按属性粒度追踪，@Environment 统一依赖注入
- **离线优先** — 断网时自动切换离线模式，已下载内容（含合集）可正常阅读，进度离线暂存、联网自动同步
- **自动恢复** — NWPathMonitor 持续监听网络变化，`.satisfied` 时自动重连、校验认证、刷新数据
- **多书库感知** — 自动获取用户可访问书库，列表 API 按书库范围筛选，合集过滤由服务端处理

## API 对接

<details>
<summary>点击查看完整 API 端点列表</summary>

| 模块 | 端点 |
|------|------|
| 认证 | `POST /api/auth/login` · `POST /api/auth/register` · `GET /api/auth/me` · `POST /api/auth/logout` |
| 站点 | `GET /api/site-settings` · `GET /api/site-settings/icon` |
| 书库 | `GET /api/libraries/accessible` |
| 书架 | `GET /api/comics`（分页/排序/筛选/excludeGrouped/libraryId） |
| 详情 | `GET /api/comics/:id` |
| 漫画 | `GET /api/comics/:id/pages` · `GET /api/comics/:id/page/:index` |
| 小说 | `GET /api/comics/:id/chapter/:index` |
| PDF | `GET /api/comics/:id/pdf` |
| 缩略图 | `GET /api/comics/:id/thumbnail` |
| 搜索 | `GET /api/comics?search=` |
| 收藏 | `PUT /api/comics/:id/favorite` |
| 评分 | `PUT /api/comics/:id/rating` |
| 阅读状态 | `PUT /api/comics/:id/reading-status` |
| 合集 | `GET /api/groups` · `GET /api/groups/:id` · `GET /api/groups/comic-map` |
| 统计 | `GET /api/stats` · `GET /api/stats/enhanced` · `GET /api/stats/yearly` |
| 目标 | `GET /api/goals` · `POST /api/goals` · `DELETE /api/goals` |
| 会话 | `POST /api/stats/session` · `PUT /api/stats/session` |
| 进度 | `PUT /api/comics/:id/progress` |
| 标签 | `GET /api/tags` |
| 分类 | `GET /api/categories` |
| 健康检查 | `GET /api/health` |

</details>

## 设计规范

| 项目 | 规范 |
|------|------|
| 页面水平 padding | 16pt |
| Section 间距 | 24pt |
| 卡片间距 | 12pt |
| 卡片圆角 | 12pt |
| 卡片阴影 | `shadow(color: .black.opacity(0.08), radius: 4, y: 2)` |
| 封面比例 | 3:4（宽:高） |
| 进度条 | 3pt 高度，低干扰样式 |
| 书库选择器 | iOS Menu 下拉，搜索框同款样式 |
| Tab Bar | ultraThinMaterial 玻璃态 |

## 修改记录

详见 [CHANGES.md](CHANGES.md)

## License

[GPL-3.0](LICENSE)
