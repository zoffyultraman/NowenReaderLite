import SwiftUI

struct StatsView: View {
    @StateObject private var viewModel = StatsViewModel()

    var body: some View {
        ScrollView {
            if let stats = viewModel.stats {
                VStack(spacing: 20) {
                    // 概览卡片
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: 12) {
                        StatCard(
                            icon: "clock.fill",
                            title: "阅读时长",
                            value: formatDuration(stats.totalReadTime),
                            color: .blue
                        )
                        StatCard(
                            icon: "book.fill",
                            title: "已读书籍",
                            value: "\(stats.totalComicsRead)",
                            color: .green
                        )
                        StatCard(
                            icon: "arrow.clockwise",
                            title: "阅读会话",
                            value: "\(stats.totalSessions)",
                            color: .orange
                        )
                        if let pages = stats.totalPagesRead {
                            StatCard(
                                icon: "doc.text.fill",
                                title: "阅读页数",
                                value: "\(pages)",
                                color: .purple
                            )
                        }
                    }
                    .padding(.horizontal, 16)

                    // 最近阅读
                    if let sessions = stats.recentSessions, !sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("最近阅读")
                                .font(.headline)
                                .padding(.horizontal, 20)

                            ForEach(sessions.prefix(10), id: \.idValue) { session in
                                HStack(spacing: 12) {
                                    Image(systemName: "book.closed.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.comicTitle ?? "未知")
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)

                                        if let dur = session.duration {
                                            Text(formatDuration(dur))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if let started = session.startedAt {
                                        Text(formatDate(started))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            } else if viewModel.isLoading {
                ProgressView()
                    .padding(.top, 100)
            }
        }
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.loadStats()
        }
        .refreshable {
            await viewModel.loadStats()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)时\(m)分" }
        return "\(m)分"
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return "" }
        let display = DateFormatter()
        display.dateFormat = "MM/dd HH:mm"
        return display.string(from: date)
    }
}

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)

            Text(value)
                .font(.title2.weight(.bold))

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var stats: ReadingStats?
    @Published var isLoading = false

    func loadStats() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            stats = try await APIClient.shared.fetchStats()
        } catch {
            print("加载统计失败: \(error)")
        }
        isLoading = false
    }
}
