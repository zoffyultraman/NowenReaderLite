import SwiftUI

struct SearchView: View {
    @State private var viewModel = SearchViewModel()
    @Environment(APIClient.self) private var api

    var body: some View {
        @Bindable var viewModel = viewModel
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
                        SearchResultRow(id: comic.id, title: comic.title, author: comic.author, isNovel: comic.isNovel, isFavorite: comic.isFavorite, serverURL: api.serverURL)
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
        .onChange(of: api.selectedLibraryId) { _, _ in
            viewModel.query = ""
            viewModel.results = []
        }
    }
}

struct SearchResultRow: View {
    let id: String
    let title: String
    let author: String?
    let isNovel: Bool
    let isFavorite: Bool
    let serverURL: String

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                .frame(width: 50, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(isNovel ? "小说" : "漫画")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            if isFavorite {
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
@Observable
final class SearchViewModel {
    var query = ""
    var results: [Comic] = []
    var isLoading = false

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
