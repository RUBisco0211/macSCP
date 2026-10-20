//
//  ConnectionListColumn.swift
//  macSCP
//
//  List view displaying connections for the middle column (Apple Notes style)
//

import SwiftUI

struct ConnectionListColumn: View {
    @Bindable var viewModel: ConnectionListViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                LoadingView(message: "Loading connections...")

            case .success:
                if viewModel.filteredConnections.isEmpty {
                    emptyStateView
                } else {
                    connectionList
                }

            case .error(let error):
                ErrorView(error: error) {
                    Task {
                        await viewModel.refresh()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(listTitle)
        .navigationSubtitle("\(viewModel.filteredConnections.count) connections")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.isShowingNewConnectionSheet = true
                } label: {
                    Label("New Connection", systemImage: "square.and.pencil")
                }
                .help("New Connection")

                Button {
                    Task {
                        await viewModel.importSSHConfig()
                    }
                } label: {
                    Label("Import", systemImage: "doc.badge.plus")
                }
                .help("Import hosts from an ssh_config file")
            }
        }
    }

    private var listTitle: String {
        switch viewModel.selectedSidebarItem {
        case .allConnections:
            return String(localized: "All Connections")
        case .folder(let id):
            return viewModel.folders.first { $0.id == id }?.name ?? String(localized: "Folder")
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        if viewModel.searchText.isEmpty {
            switch viewModel.selectedSidebarItem {
            case .allConnections:
                EmptyStateView(
                    icon: "server.rack",
                    title: "No Connections",
                    message:
                        "Add a new SSH connection to get started\nwith remote file management.",
                    actionTitle: "Add Connection"
                ) {
                    viewModel.isShowingNewConnectionSheet = true
                }
            case .folder:
                EmptyStateView(
                    icon: "folder",
                    title: "Empty Folder",
                    message:
                        "This folder has no connections.\nDrag connections here or create a new one.",
                    actionTitle: "Add Connection"
                ) {
                    viewModel.isShowingNewConnectionSheet = true
                }
            }
        } else {
            EmptyStateView.noSearchResults
        }
    }

    private var connectionList: some View {
        List(viewModel.filteredConnections, selection: $viewModel.selectedConnectionId) {
            connection in
            ConnectionRowView(connection: connection)
                .draggable(connection)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await viewModel.deleteConnection(connection) }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        viewModel.connectToServer(connection)
                    } label: {
                        Label("Open File Browser", systemImage: "folder")
                    }

                    Button {
                        viewModel.requestTerminal(for: connection)
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                    }
                    .disabled(connection.connectionType != .sftp)

                    Divider()

                    Button {
                        viewModel.editConnection(connection)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button {
                        Task {
                            await viewModel.duplicateConnection(connection)
                        }
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task {
                            await viewModel.deleteConnection(connection)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .tag(connection.id)
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            if let connection = viewModel.selectedConnection {
                viewModel.connectToServer(connection)
                return .handled
            }
            return .ignored
        }
        .onDeleteCommand {
            if let connection = viewModel.selectedConnection {
                Task { await viewModel.deleteConnection(connection) }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ConnectionListColumn(viewModel: DependencyContainer.shared.makeConnectionListViewModel())
}
