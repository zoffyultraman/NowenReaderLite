import SwiftUI
import SwiftData

/// 已下载漫画管理页面
struct DownloadListView: View {
    private let downloadManager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var showClearAlert = false

    private var activeTasks: [DownloadTask] {
        downloadManager.tasks.values
            .filter { $0.state == .downloading || $0.state == .waiting || $0.state == .paused }
            .sorted { $0.title < $1.title }
    }

    private var completedTasks: [DownloadTask] {
        downloadManager.tasks.values
            .filter { $0.state == .completed }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        List {
            if !activeTasks.isEmpty {
                Section("下载中") {
                    ForEach(activeTasks) { task in
                        DownloadTaskRow(task: task)
                    }
                }
            }

            if !completedTasks.isEmpty {
                Section("已下载 (\(completedTasks.count))") {
                    ForEach(completedTasks) { task in
                        CompletedDownloadRow(task: task)
                    }
                }
            }

            // 空状态
            if activeTasks.isEmpty && completedTasks.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("暂无已下载漫画")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("在漫画详情页点击「下载」按钮")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }

            // 存储管理
            if !completedTasks.isEmpty {
                Section {
                    HStack {
                        Label("已用空间", systemImage: "internaldrive")
                        Spacer()
                        Text(formatFileSize(OfflineFileManager.shared.totalDiskSize))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showClearAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("清除全部下载")
                                .fontWeight(.medium)
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle("已下载")
        .task {
            downloadManager.setModelContext(modelContext)
            downloadManager.restoreFromStore(context: modelContext)
        }
        .alert("清除全部下载", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                for task in downloadManager.tasks.values where task.state == .completed {
                    downloadManager.deleteDownload(comicId: task.comicId)
                }
            }
        } message: {
            Text("将删除所有已下载的漫画文件，此操作不可恢复。")
        }
    }
}

// MARK: - 下载中的任务行

struct DownloadTaskRow: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                stateLabel
            }

            ProgressView(value: task.progress)
                .tint(.accentColor)

            HStack {
                Text("\(task.completedPages)/\(task.totalPages) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(task.progress * 100))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch task.state {
        case .downloading:
            Button {
                DownloadManager.shared.pause(comicId: task.comicId)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
        case .paused:
            Button {
                DownloadManager.shared.resume(comicId: task.comicId)
            } label: {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.green)
            }
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

// MARK: - 已完成的任务行

struct CompletedDownloadRow: View {
    let task: DownloadTask

    var body: some View {
        NavigationLink {
            ComicDetailView(comicId: task.comicId)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("\(task.totalPages) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                DownloadManager.shared.deleteDownload(comicId: task.comicId)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
        }
    }
}
