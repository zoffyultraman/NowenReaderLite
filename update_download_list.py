import re

with open("Features/Downloads/DownloadListView.swift", "r") as f:
    content = f.read()

target = """        VStack(alignment: .leading, spacing: 8) {
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
                Text("\\(task.completedPages)/\\(task.totalPages) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\\(Int(task.progress * 100))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)"""

replacement = """        VStack(alignment: .leading, spacing: 8) {
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
                Text("\\(task.completedPages)/\\(task.totalPages) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\\(Int(task.progress * 100))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                DownloadManager.shared.cancel(comicId: task.comicId)
            } label: {
                Label("取消", systemImage: "xmark.circle")
            }
            .tint(.red)
        }"""

if target in content:
    with open("Features/Downloads/DownloadListView.swift", "w") as f:
        f.write(content.replace(target, replacement))
    print("Success")
else:
    print("Target not found")
