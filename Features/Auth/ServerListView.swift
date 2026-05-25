import SwiftUI
import SwiftData

struct ServerListView: View {
    @Query(sort: [SortDescriptor(\ServerRecord.lastUsed, order: .reverse)])
    private var servers: [ServerRecord]

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var api = APIClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAddServer = false
    @State private var isSwitching = false
    @State private var switchingServerId: String? = nil

    var body: some View {
        List {
            if servers.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("暂无保存的服务器")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("点击右上角 + 添加服务器")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                Section {
                    ForEach(servers) { server in
                        Button {
                            switchToServer(server)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack")
                                    .font(.title3)
                                    .foregroundStyle(api.serverURL == server.url ? Color.accentColor : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.url)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let username = server.username, !username.isEmpty {
                                        Text(username)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if isSwitching && switchingServerId == server.url {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else if api.serverURL == server.url {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .disabled(isSwitching)
                    }
                    .onDelete(perform: deleteServers)
                }
            }
        }
        .navigationTitle("服务器列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showAddServer) {
            ServerConfigView(onConnected: {
                // After adding a server, it will be saved to SwiftData by ServerConfigView
            }, embedsInOwnStack: false)
        }
    }

    private func switchToServer(_ record: ServerRecord) {
        guard !isSwitching else { return }
        // Don't switch if already on this server
        guard api.serverURL != record.url else { return }

        isSwitching = true
        switchingServerId = record.url
        record.lastUsed = Date()

        api.setServerURL(record.url)
        Task {
            await api.checkAuth()
            isSwitching = false
            switchingServerId = nil
            // Update username after auth check
            record.username = api.currentUser?.username
            try? modelContext.save()
        }
    }

    private func deleteServers(at offsets: IndexSet) {
        for index in offsets {
            let server = servers[index]
            // Don't delete the currently active server
            if server.url == api.serverURL {
                continue
            }
            modelContext.delete(server)
        }
        try? modelContext.save()
    }
}