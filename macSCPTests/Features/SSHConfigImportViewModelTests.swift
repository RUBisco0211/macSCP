//
//  SSHConfigImportViewModelTests.swift
//  macSCPTests
//
//  Unit tests for the ssh config import preview.
//

import XCTest
@testable import macSCP

@MainActor
final class SSHConfigImportViewModelTests: XCTestCase {
    private let home = "/Users/test"

    private var configURL: URL {
        URL(fileURLWithPath: "/Users/test/.ssh/config")
    }

    private func makeViewModel(
        config: String?,
        existingFiles: Set<String> = []
    ) -> SSHConfigImportViewModel {
        let files = config.map { [configURL.path: $0] } ?? [:]
        let parser = SSHConfigParser(
            reader: StubSSHConfigReader(files: files),
            options: SSHConfigParseOptions(homeDirectory: home),
            fileExists: { existingFiles.contains($0) }
        )
        return SSHConfigImportViewModel(
            configURL: configURL,
            parser: parser,
            defaultUsername: "fallback"
        )
    }

    func testLoadsEveryHostSelectedByDefault() async throws {
        let viewModel = makeViewModel(config: """
        Host alpha
            HostName alpha.example.com
            User alice

        Host beta
            HostName beta.example.com
            Port 2222
        """)

        await viewModel.load()

        XCTAssertTrue(viewModel.state.isSuccess)
        XCTAssertEqual(viewModel.rows.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(viewModel.selectedCount, 2)
        XCTAssertTrue(viewModel.allSelected)
        XCTAssertEqual(viewModel.selectedConnections.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(viewModel.selectedConnections.first?.username, "alice")
        XCTAssertEqual(viewModel.selectedConnections.last?.username, "fallback")
        XCTAssertEqual(viewModel.selectedConnections.last?.port, 2222)
    }

    func testSelectionCanBeToggled() async {
        let viewModel = makeViewModel(config: """
        Host alpha
        Host beta
        """)
        await viewModel.load()

        viewModel.setSelected(false, forAlias: "alpha")
        XCTAssertEqual(viewModel.selectedCount, 1)
        XCTAssertFalse(viewModel.allSelected)
        XCTAssertEqual(viewModel.selectedConnections.map(\.name), ["beta"])

        viewModel.setAllSelected(false)
        XCTAssertEqual(viewModel.selectedCount, 0)
        XCTAssertTrue(viewModel.selectedConnections.isEmpty)

        viewModel.setAllSelected(true)
        XCTAssertEqual(viewModel.selectedCount, 2)
    }

    func testWarningsAreAttachedToTheirAlias() async throws {
        let viewModel = makeViewModel(config: """
        Host withkey
            IdentityFile ~/.ssh/missing

        Host nokey
            HostName nokey.example.com
        """)

        await viewModel.load()

        let withKey = try XCTUnwrap(viewModel.rows.first { $0.id == "withkey" })
        XCTAssertEqual(withKey.warnings.count, 1)
        let warning = try XCTUnwrap(withKey.warnings.first)
        XCTAssertTrue(warning.contains("could not be read"))

        let noKey = try XCTUnwrap(viewModel.rows.first { $0.id == "nokey" })
        XCTAssertTrue(noKey.warnings.isEmpty)
        XCTAssertTrue(viewModel.generalWarnings.isEmpty)
    }

    func testFileWideWarningsGoToGeneralWarnings() async {
        let viewModel = makeViewModel(config: """
        Host *.example.com
            User anyone
        """)

        await viewModel.load()

        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertEqual(viewModel.generalWarnings.count, 1)
        XCTAssertTrue(viewModel.generalWarnings[0].contains("wildcard"))
    }

    func testUnreadableConfigSurfacesError() async {
        let viewModel = makeViewModel(config: nil)

        await viewModel.load()

        XCTAssertTrue(viewModel.state.isError)
        XCTAssertNotNil(viewModel.state.error)
        XCTAssertTrue(viewModel.rows.isEmpty)
    }

    func testLoadingTwiceDoesNotDuplicateRows() async {
        let viewModel = makeViewModel(config: "Host alpha")
        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(viewModel.rows.count, 1)
    }
}
