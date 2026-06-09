import SwiftUI

struct StatsView: View {
    @StateObject private var viewModel = StatsViewModel()
    @State private var showGoalSheet = false
    @ObservedObject private var api = APIClient.shared

    var body: some View {
        if api.isOfflineMode {
            offlineUnavailableView
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        ScrollView {
            if let stats = viewModel.enhancedStats {
                VStack(spacing: 20) {
                    // 目标进度
                    goalSection(goals: viewModel.goals)

                    // 今日 + 本周概览
                    overviewCards(stats: stats)

                    // 连续阅读
                    streakCard(current: stats.currentStreak, longest: stats.longestStreak)

                    // 每日阅读柱状图
                    dailyChartCard(dailyStats: stats.dailyStats)

                    // 类型偏好
                    if !stats.genreStats.isEmpty {
                        genreSection(genreStats: stats.genreStats)
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
            await viewModel.loadAll()
        }
        .onChange(of: api.isOfflineMode) { _, isOffline in
            if isOffline {
                viewModel.isLoading = false
                viewModel.enhancedStats = nil
                viewModel.goals = []
            }
        }
        .refreshable {
            await viewModel.loadAll()
        }
        .sheet(isPresented: $showGoalSheet) {
            GoalSettingSheet(
                goals: viewModel.goals,
                onSave: { type, mins, books in
                    await viewModel.setGoal(goalType: type, targetMins: mins, targetBooks: books)
                },
                onDelete: { type in
                    await viewModel.deleteGoal(goalType: type)
                }
            )
        }
    }

    private var offlineUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("离线模式不可用")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("统计功能需要连接服务器")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 目标进度

    @ViewBuilder
    private func goalSection(goals: [ReadingGoalProgress]) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("阅读目标")
                    .font(.headline)
                Spacer()
                Button {
                    showGoalSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 20)

            if goals.isEmpty {
                Button {
                    showGoalSheet = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("设定阅读目标")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("追踪每日或每周阅读进度")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(goals) { goal in
                            GoalProgressCard(progress: goal)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - 概览卡片

    private func overviewCards(stats: EnhancedReadingStats) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
        ], spacing: 12) {
            StatCard(
                icon: "hourglass",
                title: "今日",
                value: formatDuration(stats.todayReadTime),
                color: .blue
            )
            StatCard(
                icon: "calendar",
                title: "本周",
                value: formatDuration(stats.weekReadTime),
                color: .green
            )
            StatCard(
                icon: "book.fill",
                title: "已读书籍",
                value: "\(stats.totalComicsRead)",
                color: .orange
            )
            StatCard(
                icon: "clock.fill",
                title: "总时长",
                value: formatDuration(stats.totalReadTime),
                color: .purple
            )
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 连续阅读

    private func streakCard(current: Int, longest: Int) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("\(current)")
                    .font(.title.weight(.bold))
                Text("当前连续")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 40)

            VStack(spacing: 6) {
                Text("\(longest)")
                    .font(.title.weight(.bold))
                Text("最长连续")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    // MARK: - 每日阅读柱状图

    private func dailyChartCard(dailyStats: [EnhancedDailyStat]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每日阅读")
                .font(.headline)
                .padding(.horizontal, 20)

            if dailyStats.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                DailyBarChart(dailyStats: dailyStats)
                    .frame(height: 140)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    // MARK: - 类型偏好

    private func genreSection(genreStats: [GenreStat]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("类型偏好")
                .font(.headline)
                .padding(.horizontal, 20)

            let maxTime = genreStats.map(\.totalTime).max() ?? 1

            ForEach(genreStats.prefix(5)) { genre in
                HStack(spacing: 10) {
                    Text(genre.genre)
                        .font(.caption.weight(.medium))
                        .frame(width: 56, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        let ratio = CGFloat(genre.totalTime) / CGFloat(maxTime)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: geo.size.width * ratio, height: 14)
                    }
                    .frame(height: 14)

                    Text(formatDuration(genre.totalTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    // MARK: - 格式化

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)时\(m)分" }
        if m > 0 { return "\(m)分" }
        return "\(seconds)秒"
    }
}

// MARK: - 目标进度卡片

struct GoalProgressCard: View {
    let progress: ReadingGoalProgress

    var body: some View {
        VStack(spacing: 10) {
            ProgressRingView(
                progress: Double(progress.progressPct) / 100.0,
                lineWidth: 6,
                color: progress.achieved ? .green : Color.accentColor
            )
            .frame(width: 64, height: 64)
            .overlay {
                VStack(spacing: 0) {
                    Text("\(progress.progressPct)%")
                        .font(.caption.weight(.bold))
                    if progress.goal.targetBooks > 0 {
                        Text("\(progress.currentBooks)/\(progress.goal.targetBooks)本")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(progress.goal.goalType == "daily" ? "每日目标" : "每周目标")
                .font(.caption.weight(.medium))

            Text("\(progress.currentMins) / \(progress.goal.targetMins) 分钟")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if progress.achieved {
                Text("已达成!")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .frame(minWidth: 140)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 进度环

struct ProgressRingView: View {
    let progress: Double
    var lineWidth: CGFloat = 8
    var color: Color = .accentColor

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - 每日柱状图

struct DailyBarChart: View {
    let dailyStats: [EnhancedDailyStat]

    var body: some View {
        let recentStats = Array(dailyStats.suffix(30))
        let maxDuration = recentStats.map(\.duration).max() ?? 1

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(recentStats) { stat in
                    VStack {
                        Spacer()
                        let height = max(CGFloat(stat.duration) / CGFloat(maxDuration) * 90, stat.duration > 0 ? 4 : 2)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(stat.duration > 0 ? Color.accentColor : Color(.systemGray4))
                            .frame(width: 8, height: height)
                        Text(formatDay(stat.date))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20)
                    }
                    .frame(height: 120)
                }
            }
        }
    }

    private func formatDay(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count >= 3 else { return iso }
        return String(parts[2])
    }
}

// MARK: - 目标设定弹窗

struct GoalSettingSheet: View {
    let goals: [ReadingGoalProgress]
    let onSave: (String, Int, Int) async -> Void
    let onDelete: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedType = "daily"
    @State private var targetMins = 30
    @State private var targetBooks = 0
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("目标类型") {
                    Picker("类型", selection: $selectedType) {
                        Text("每日目标").tag("daily")
                        Text("每周目标").tag("weekly")
                    }
                    .pickerStyle(.segmented)
                }

                Section("时长目标") {
                    Stepper("\(targetMins) 分钟", value: $targetMins, in: 5...480, step: 5)
                }

                Section("书籍数量（可选）") {
                    Stepper(targetBooks == 0 ? "不限" : "\(targetBooks) 本", value: $targetBooks, in: 0...50, step: 1)
                }

                if goals.contains(where: { $0.goal.goalType == selectedType }) {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await onDelete(selectedType)
                                dismiss()
                            }
                        } label: {
                            Text("删除\(selectedType == "daily" ? "每日" : "每周")目标")
                        }
                    }
                }
            }
            .navigationTitle("设定阅读目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            isSaving = true
                            await onSave(selectedType, targetMins, targetBooks)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear {
                if let existingGoal = goals.first(where: { $0.goal.goalType == selectedType }) {
                    targetMins = existingGoal.goal.targetMins
                    targetBooks = existingGoal.goal.targetBooks
                }
            }
            .onChange(of: selectedType) { _, newValue in
                if let existingGoal = goals.first(where: { $0.goal.goalType == newValue }) {
                    targetMins = existingGoal.goal.targetMins
                    targetBooks = existingGoal.goal.targetBooks
                } else {
                    targetMins = newValue == "daily" ? 30 : 120
                    targetBooks = 0
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var enhancedStats: EnhancedReadingStats?
    @Published var goals: [ReadingGoalProgress] = []
    @Published var isLoading = false

    func loadAll() async {
        // 离线或网络不可达：立即返回，不挂起等超时
        guard !APIClient.shared.isOfflineMode, APIClient.shared.isNetworkReachable else {
            isLoading = false
            return
        }
        guard !isLoading else { return }
        isLoading = true
        async let statsTask = APIClient.shared.fetchEnhancedStats()
        async let goalsTask = APIClient.shared.fetchGoals()
        do {
            let (stats, fetchedGoals) = try await (statsTask, goalsTask)
            self.enhancedStats = stats
            self.goals = fetchedGoals
        } catch {
            AppLogger.error("加载统计数据失败: \(error)")
            if APIClient.shared.isOfflineMode {
                enhancedStats = nil
                goals = []
            }
        }
        isLoading = false
    }

    func setGoal(goalType: String, targetMins: Int, targetBooks: Int) async {
        do {
            _ = try await APIClient.shared.setGoal(goalType: goalType, targetMins: targetMins, targetBooks: targetBooks)
            await reloadGoals()
        } catch {
            AppLogger.error("设定目标失败: \(error)")
        }
    }

    func deleteGoal(goalType: String) async {
        do {
            try await APIClient.shared.deleteGoal(goalType: goalType)
            await reloadGoals()
        } catch {
            AppLogger.error("删除目标失败: \(error)")
        }
    }

    private func reloadGoals() async {
        do {
            goals = try await APIClient.shared.fetchGoals()
        } catch {
            AppLogger.error("刷新目标失败: \(error)")
        }
    }
}

// MARK: - 统计卡片

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}