import SwiftUI
import SwiftData

struct AccountManagerView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var accounts: [SavedAccount] = []
    @State private var showAddSheet = false
    @State private var editingAccount: SavedAccount? = nil

    var body: some View {
        List {
            if accounts.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("暂无保存的账号")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("点击右上角 + 添加账号")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                Section {
                    ForEach(accounts) { account in
                        Button {
                            editingAccount = account
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 40, height: 40)
                                    Text(String(account.alias.prefix(1)).uppercased())
                                        .font(.headline)
                                        .foregroundStyle(Color.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.alias)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(account.username)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onDelete(perform: deleteAccounts)
                }
            }
        }
        .navigationTitle("账号管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AccountEditSheet(mode: .add) { alias, username, password in
                _ = APIClient.shared.createAccount(alias: alias, username: username, password: password, context: modelContext)
                loadAccounts()
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountEditSheet(mode: .edit(account)) { alias, username, password in
                APIClient.shared.updateAccount(account, alias: alias, username: username, password: password, context: modelContext)
                loadAccounts()
            }
        }
        .onAppear {
            loadAccounts()
        }
    }

    private func loadAccounts() {
        accounts = APIClient.shared.fetchAllAccounts(context: modelContext)
    }

    private func deleteAccounts(at offsets: IndexSet) {
        for index in offsets {
            APIClient.shared.deleteAccount(accounts[index], context: modelContext)
        }
        loadAccounts()
    }
}

// MARK: - 账号编辑 Sheet

enum AccountEditMode: Equatable {
    case add
    case edit(SavedAccount)

    static func == (lhs: AccountEditMode, rhs: AccountEditMode) -> Bool {
        switch (lhs, rhs) {
        case (.add, .add): return true
        case (.edit(let a), .edit(let b)): return a.id == b.id
        default: return false
        }
    }
}

struct AccountEditSheet: View {
    let mode: AccountEditMode
    let onSave: (String, String, String) -> Void  // alias, username, password

    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    HStack(spacing: 12) {
                        Image(systemName: "tag")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField("别名（如：工作账号、个人账号）", text: $alias)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "person")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField("用户名", text: $username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        if showPassword {
                            TextField("密码", text: $password)
                        } else {
                            SecureField("密码", text: $password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .edit = mode {
                    Section {
                        Text("留空密码表示不修改")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isAdd ? "添加账号" : "编辑账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(alias, username, password)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if case .edit(let account) = mode {
                    alias = account.alias
                    username = account.username
                }
            }
            .onDisappear {
                password = ""
            }
        }
    }

    private var isAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    private var canSave: Bool {
        if isAdd {
            return !alias.isEmpty && !username.isEmpty && !password.isEmpty
        }
        return !alias.isEmpty && !username.isEmpty
    }
}
