import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索漫画或小说...", text: $viewModel.query)
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        viewModel.search()
                    }
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                        viewModel.results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 结果
            if viewModel.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if viewModel.results.isEmpty && !viewModel.query.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("没有找到结果")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(viewModel.results) { comic in
                    NavigationLink(value: comic.id) {
                        SearchResultRow(comic: comic)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: String.self) { comicId in
            ComicDetailView(comicId: comicId)
        }
    }
}

struct SearchResultRow: View {
    let comic: Comic

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: APIClient.shared.serverURL, comicId: comic.id, thumbnail: true)
                .frame(width: 50, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(comic.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let author = comic.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(comic.isNovel ? "小说" : "漫画")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            if comic.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

}

// MARK: - ViewModel

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Comic] = []
    @Published var isLoading = false

    private let api = APIClient.shared
    private var searchTask: Task<Void, Never>?

    func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            return
        }

        searchTask = Task {
            isLoading = true
            // debounce 300ms
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let resp = try await api.fetchComics(page: 1, pageSize: 50, search: q)
                if !Task.isCancelled {
                    results = resp.comics
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.error("搜索失败: \(error)")
                }
            }
            isLoading = false
        }
    }
}
