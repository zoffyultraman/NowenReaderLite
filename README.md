# NowenReaderLite

基于 [NowenReader](https://github.com/cropflre/nowen-reader) 的轻量级 iOS 原生客户端。

## 功能

- 📚 书架浏览（网格 / 列表视图切换）
- 📖 漫画阅读（UIPageViewController 翻页 + 缩放）
- 📕 小说阅读（分页 + 字号调节 + 自动记忆位置）
- 📁 合集管理（分组浏览、网格/列表切换）
- 🔍 全文搜索
- ❤️ 收藏
- 📊 阅读统计
- 🔄 阅读进度同步
- 🌗 深色模式自适应
- 📱 iPad 适配

## 技术栈

| 组件 | 技术 |
|------|------|
| UI | SwiftUI + UIKit 桥接 |
| 架构 | MVVM |
| 网络 | URLSession + async/await + Codable |
| 图片 | AuthenticatedImage（Cookie 认证加载） |
| 本地存储 | SwiftData |
| 阅读器 | UIPageViewController (.pageCurl) |
| PDF | PDFKit |
| 最低版本 | iOS 17.0 |

## 项目结构

```
NowenReaderLite/
├── App/                    # 入口、路由、TabBar
├── Core/
│   ├── Network/            # API 客户端、图片加载
│   └── Storage/            # SwiftData 缓存模型
├── Features/
│   ├── Auth/               # 服务器配置、登录/注册
│   ├── Library/            # 书架、继续观看
│   ├── Detail/             # 详情页、合集详情
│   ├── Reader/             # 漫画/小说/PDF 阅读器
│   ├── Search/             # 搜索
│   ├── Favorites/          # 收藏
│   ├── Stats/              # 阅读统计
│   └── Settings/           # 设置
├── Models/                 # Codable 数据模型
├── Assets.xcassets/        # 图片、图标资源
├── Info.plist
└── NowenReaderLite.xcodeproj/
```

## 使用方式

1. 在 Mac 上用 Xcode 打开 `NowenReaderLite.xcodeproj`
2. 配置签名证书
3. 选择模拟器或真机运行
4. 首次启动输入 NowenReader 服务器地址
5. 登册/登录后即可使用

## API 对接

| 模块 | 端点 |
|------|------|
| 认证 | `/api/auth/login`, `/api/auth/register`, `/api/auth/me` |
| 书架 | `/api/comics`（分页/排序/筛选） |
| 详情 | `/api/comics/:id` |
| 漫画阅读 | `/api/comics/:id/pages`, `/api/comics/:id/page/:index` |
| 小说阅读 | `/api/comics/:id/chapter/:index` |
| PDF | `/api/comics/:id/pdf` |
| 搜索 | `/api/comics?search=` |
| 收藏 | `/api/comics/:id/favorite` |
| 合集 | `/api/groups`, `/api/groups/:id` |
| 统计 | `/api/stats` |
| 进度 | `/api/comics/:id/progress`, `/api/stats/session` |

## License

GPL-3.0
