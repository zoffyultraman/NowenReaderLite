import re

with open("Features/Detail/ComicDetailView.swift", "r") as f:
    content = f.read()

target = """        } else if downloadManager.wouldExceedLimit(pageCount: comic.pageCount) {"""

replacement = """        } else if task?.state == .failed {
            HStack(spacing: 8) {
                Button {
                    downloadManager.download(
                        comicId: comic.id,
                        title: comic.title,
                        pageCount: comic.pageCount,
                        fileSize: comic.fileSize,
                        isNovel: comic.isNovel
                    )
                } label: {
                    HStack(spacing: 6) {
                        Label("重新下载", systemImage: "arrow.clockwise.circle.fill")
                            .font(.subheadline.weight(.medium))
                        if let t = task {
                            Text("\\(t.completedPages)/\\(t.totalPages)")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.1))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                Button {
                    downloadManager.cancel(comicId: comic.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(Color.gray.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        } else if downloadManager.wouldExceedLimit(pageCount: comic.pageCount) {"""

if target in content:
    with open("Features/Detail/ComicDetailView.swift", "w") as f:
        f.write(content.replace(target, replacement))
    print("Success")
else:
    print("target not found")
