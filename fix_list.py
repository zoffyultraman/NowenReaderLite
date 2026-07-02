import re

with open("Features/Downloads/DownloadListView.swift", "r") as f:
    content = f.read()

target = """    private var activeTasks: [DownloadTask] {
        downloadManager.tasks.values
            .filter { $0.state == .downloading || $0.state == .waiting || $0.state == .paused }
            .sorted { $0.title < $1.title }
    }"""

replacement = """    private var activeTasks: [DownloadTask] {
        downloadManager.tasks.values
            .filter { $0.state != .completed }
            .sorted { $0.title < $1.title }
    }"""

if target in content:
    content = content.replace(target, replacement)
else:
    print("target activeTasks not found")

target_state = """    @ViewBuilder
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
    }"""

replacement_state = """    @ViewBuilder
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
        case .failed:
            Button {
                DownloadManager.shared.download(
                    comicId: task.comicId,
                    title: task.title,
                    pageCount: task.totalPages,
                    fileSize: nil,
                    isNovel: task.isNovel
                )
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }"""

if target_state in content:
    content = content.replace(target_state, replacement_state)
else:
    print("target_state not found")

with open("Features/Downloads/DownloadListView.swift", "w") as f:
    f.write(content)
print("Success")
