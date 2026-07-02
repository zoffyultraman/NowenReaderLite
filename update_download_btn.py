import re

with open("Features/Detail/ComicDetailView.swift", "r") as f:
    content = f.read()

target = """        if isDownloaded {
            Button {} label: {
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.1))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else if isDownloading {
            Button {
                downloadManager.pause(comicId: comic.id)
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("\\(Int((task?.progress ?? 0) * 100))%")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.1))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else if isPaused {
            Button {
                downloadManager.resume(comicId: comic.id)
            } label: {
                Label("继续", systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else if downloadManager.wouldExceedLimit(pageCount: comic.pageCount) {"""

replacement = """        if isDownloaded {
            Button {} label: {
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.1))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else if isDownloading || isPaused {
            HStack(spacing: 8) {
                Button {
                    if isDownloading {
                        downloadManager.pause(comicId: comic.id)
                    } else {
                        downloadManager.resume(comicId: comic.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isDownloading {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("\\(Int((task?.progress ?? 0) * 100))%")
                                .font(.subheadline.weight(.medium))
                        } else {
                            Label("继续", systemImage: "play.circle.fill")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                Button {
                    downloadManager.cancel(comicId: comic.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(Color.red.opacity(0.1))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        } else if downloadManager.wouldExceedLimit(pageCount: comic.pageCount) {"""

if target in content:
    with open("Features/Detail/ComicDetailView.swift", "w") as f:
        f.write(content.replace(target, replacement))
    print("Success")
else:
    print("Target not found")
