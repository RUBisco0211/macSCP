//
//  SSHConfigImportSheet.swift
//  macSCP
//
//  Preview sheet for importing hosts from ~/.ssh/config.
//

import SwiftUI

struct SSHConfigImportSheet: View {
    @Bindable var viewModel: SSHConfigImportViewModel
    let onImport: ([Connection]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 620, height: 540)
        .task {
            await viewModel.load()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 2) {
            Text("Import from ~/.ssh/config")
                .font(.headline)
            Text("Choose the hosts you want to add to macSCP.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Reading ~/.ssh/config…")

        case .error(let error):
            ContentUnavailableView {
                Label("Could not read ssh config", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }

        case .success:
            if viewModel.rows.isEmpty {
                noHostsView
            } else {
                hostList
            }
        }
    }

    /// The empty state has to explain *why* nothing was imported: a failed
    /// Include or a wildcard-only config produces warnings but no rows.
    private var noHostsView: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("No Hosts Found", systemImage: "server.rack")
            } description: {
                Text(viewModel.generalWarnings.isEmpty
                     ? "~/.ssh/config does not contain any host entries."
                     : "No entries in ~/.ssh/config could be imported.")
            }

            if !viewModel.generalWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.generalWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
    }

    private var hostList: some View {
        List {
            Section {
                ForEach(viewModel.rows) { row in
                    rowView(row)
                }
            }

            if !viewModel.generalWarnings.isEmpty {
                Section("Notes") {
                    ForEach(viewModel.generalWarnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(viewModel.selectedCount) of \(viewModel.rows.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(viewModel.allSelected ? "Deselect All" : "Select All") {
                viewModel.setAllSelected(!viewModel.allSelected)
            }
            .disabled(viewModel.rows.isEmpty)

            Spacer()

            Button("Cancel", role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button("Import") {
                onImport(viewModel.selectedConnections)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.selectedCount == 0)
        }
        .padding(12)
    }

    // MARK: - Rows

    private func rowView(_ row: SSHConfigImportViewModel.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { row.isSelected },
                set: { viewModel.setSelected($0, forAlias: row.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.entry.alias)
                        .font(.headline)
                    authBadge(isKey: row.entry.usesKeyAuthentication)
                }

                Text("\(row.connection.username)@\(row.connection.displayHost)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(row.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func authBadge(isKey: Bool) -> some View {
        Label(isKey ? "Key" : "Password", systemImage: isKey ? "key.fill" : "asterisk")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

#Preview {
    SSHConfigImportSheet(
        viewModel: SSHConfigImportViewModel(),
        onImport: { _ in },
        onCancel: {}
    )
}
