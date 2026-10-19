//
//  SSHConfigImportViewModel.swift
//  macSCP
//
//  Drives the "Import from ~/.ssh/config" preview: parses the config, exposes
//  selectable rows, and hands the chosen connections back for persistence.
//

import Foundation
import Observation

@MainActor
@Observable
final class SSHConfigImportViewModel {
    struct Row: Identifiable, Sendable {
        var id: String { entry.alias }

        let entry: SSHConfigEntry
        let connection: Connection
        var isSelected: Bool
        let warnings: [String]
    }

    // MARK: - State

    private(set) var rows: [Row] = []
    private(set) var generalWarnings: [String] = []
    private(set) var state: ViewState<Void> = .idle

    // MARK: - Dependencies

    private let configURL: URL
    private let parser: SSHConfigParser
    private let defaultUsername: String

    init(
        configURL: URL,
        parser: SSHConfigParser = SSHConfigParser(),
        defaultUsername: String = NSUserName()
    ) {
        self.configURL = configURL
        self.parser = parser
        self.defaultUsername = defaultUsername
    }

    // MARK: - Derived State

    var selectedConnections: [Connection] {
        rows.filter(\.isSelected).map(\.connection)
    }

    var selectedCount: Int {
        rows.reduce(0) { $0 + ($1.isSelected ? 1 : 0) }
    }

    var allSelected: Bool {
        !rows.isEmpty && rows.allSatisfy(\.isSelected)
    }

    // MARK: - Actions

    func load() async {
        guard !state.isLoading, rows.isEmpty else { return }

        state = .loading
        do {
            let result = try parser.parse(configURL: configURL)
            let connections = SSHConfigImporter.connections(
                from: result.entries,
                defaultUsername: defaultUsername
            )

            var warningsByAlias: [String: [String]] = [:]
            for warning in result.warnings {
                guard let alias = warning.alias else { continue }
                warningsByAlias[alias, default: []].append(warning.message)
            }

            rows = zip(result.entries, connections).map { pair in
                Row(
                    entry: pair.0,
                    connection: pair.1,
                    isSelected: true,
                    warnings: warningsByAlias[pair.0.alias] ?? []
                )
            }
            generalWarnings = result.warnings.filter { $0.alias == nil }.map(\.message)
            state = .success(())
            logInfo("Parsed \(rows.count) host(s) from ssh config", category: .app)
        } catch {
            logError("Failed to parse ssh config: \(error)", category: .app)
            state = .error(AppError.from(error))
        }
    }

    func setSelected(_ isSelected: Bool, forAlias alias: String) {
        guard let index = rows.firstIndex(where: { $0.id == alias }) else { return }
        rows[index].isSelected = isSelected
    }

    func setAllSelected(_ isSelected: Bool) {
        for index in rows.indices {
            rows[index].isSelected = isSelected
        }
    }
}
