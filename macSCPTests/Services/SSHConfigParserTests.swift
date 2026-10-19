//
//  SSHConfigParserTests.swift
//  macSCPTests
//
//  Unit tests for the ssh_config importer parser (spike).
//  All tests are hermetic: file contents and existence checks are injected.
//

import XCTest
@testable import macSCP

final class SSHConfigParserTests: XCTestCase {
    private let home = "/Users/test"
    private let configPath = "/Users/test/.ssh/config"

    private var configURL: URL {
        URL(fileURLWithPath: configPath)
    }

    private func makeParser(
        files: [String: String],
        existingFiles: Set<String> = []
    ) -> SSHConfigParser {
        SSHConfigParser(
            reader: StubSSHConfigReader(files: files),
            options: SSHConfigParseOptions(homeDirectory: home),
            fileExists: { existingFiles.contains($0) }
        )
    }

    private func parse(
        _ config: String,
        existingFiles: Set<String> = []
    ) throws -> SSHConfigParseResult {
        try makeParser(files: [configPath: config], existingFiles: existingFiles)
            .parse(configURL: configURL)
    }

    // MARK: - Field Mapping

    func testParsesFullHostBlock() throws {
        let result = try parse("""
        Host lab
            HostName lab.example.com
            User deploy
            Port 1185
            IdentityFile ~/.ssh/id_rsa
        """, existingFiles: ["/Users/test/.ssh/id_rsa"])

        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.alias, "lab")
        XCTAssertEqual(entry.hostName, "lab.example.com")
        XCTAssertEqual(entry.user, "deploy")
        XCTAssertEqual(entry.port, 1185)
        XCTAssertEqual(entry.identityFiles, ["/Users/test/.ssh/id_rsa"])
        XCTAssertTrue(entry.usesKeyAuthentication)
        XCTAssertTrue(entry.unsupportedDirectives.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testDefaultsToAliasHostAndPort() throws {
        let result = try parse("Host bare")

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.hostName, "bare")
        XCTAssertNil(entry.user)
        XCTAssertEqual(entry.port, 22)
        XCTAssertTrue(entry.identityFiles.isEmpty)
        XCTAssertFalse(entry.usesKeyAuthentication)
    }

    func testTrimsTrailingWhitespaceAndStripsComments() throws {
        let result = try parse("""
        Host web   # production box
            HostName lab.example.com\u{20}\u{20}\u{20}
            User deploy
        """)

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.alias, "web")
        XCTAssertEqual(entry.hostName, "lab.example.com")
        XCTAssertEqual(entry.user, "deploy")
    }

    func testSupportsEqualsSyntax() throws {
        let result = try parse("""
        Host=db
            HostName=db.internal
            Port=2222
        """)

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.alias, "db")
        XCTAssertEqual(entry.hostName, "db.internal")
        XCTAssertEqual(entry.port, 2222)
    }

    func testSplitsMultipleAliasesIntoSeparateEntries() throws {
        let result = try parse("""
        Host alpha beta
            HostName shared.example.com
            User shared
        """)

        XCTAssertEqual(result.entries.map(\.alias), ["alpha", "beta"])
        XCTAssertTrue(result.entries.allSatisfy { $0.hostName == "shared.example.com" })
        XCTAssertTrue(result.entries.allSatisfy { $0.user == "shared" })
    }

    // MARK: - ssh Resolution Semantics

    func testGlobalDirectivesApplyToEveryHost() throws {
        let result = try parse("""
        User globaluser

        Host one
            HostName one.example.com
        """)

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.user, "globaluser")
        XCTAssertEqual(entry.hostName, "one.example.com")
    }

    func testFirstObtainedValueWins() throws {
        let result = try parse("""
        Host target
            User first
            Port 2200

        Host target
            User second
            Port 2210
        """)

        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.user, "first")
        XCTAssertEqual(entry.port, 2200)
    }

    func testStarBlockSuppliesDefaultsWithoutBecomingAnEntry() throws {
        let result = try parse("""
        Host *
            User staruser

        Host real
            HostName real.example.com
        """)

        XCTAssertEqual(result.entries.map(\.alias), ["real"])
        XCTAssertEqual(result.entries.first?.user, "staruser")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testWildcardHostIsSkippedWithWarning() throws {
        let result = try parse("""
        Host *.example.com
            User wildcard
        """)

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.warnings.contains(.wildcardHostSkipped("*.example.com")))
    }

    func testNegatedPatternDoesNotProduceEntries() throws {
        let result = try parse("""
        Host web !web-test
            HostName web.example.com
        """)

        XCTAssertEqual(result.entries.map(\.alias), ["web"])
        XCTAssertEqual(result.entries.first?.hostName, "web.example.com")
    }

    func testMatchBlockDirectivesAreIgnored() throws {
        let result = try parse("""
        Host before
            HostName before.example.com

        Match host foo
            User matchuser

        Host after
            HostName after.example.com
        """)

        XCTAssertEqual(result.entries.map(\.alias), ["before", "after"])
        XCTAssertNil(result.entries[0].user)
        XCTAssertNil(result.entries[1].user)
    }

    // MARK: - Tokens

    func testExpandsPercentTokensInIdentityFile() throws {
        let result = try parse("""
        Host token
            HostName t.example.com
            User bob
            Port 2022
            IdentityFile ~/.ssh/id_%r@%h:%p
        """)

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.identityFiles, ["/Users/test/.ssh/id_bob@t.example.com:2022"])
    }

    func testKeepsQuotedPathsWithSpaces() throws {
        let result = try parse("""
        Host spaced
            IdentityFile "~/keys/my key"
            ProxyCommand '/path/with#hash' ssh-proxy
        """, existingFiles: ["/Users/test/keys/my key"])

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.identityFiles, ["/Users/test/keys/my key"])
        XCTAssertEqual(entry.unsupportedDirectives, ["proxycommand"])
    }

    // MARK: - Include

    func testIncludeIsSkippedWithWarning() throws {
        let result = try parse("Include ~/.orbstack/ssh/config")

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.warnings.contains(.includeSkipped("~/.orbstack/ssh/config")))
        XCTAssertEqual(result.sourcePaths, [configPath])
    }

    func testIncludeDoesNotStealFollowingDirectives() throws {
        let result = try parse("""
        Include ~/.ssh/extra
        User globaluser

        Host after
            HostName after.example.com
        """)

        let after = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(after.alias, "after")
        XCTAssertEqual(after.user, "globaluser")
        XCTAssertTrue(result.warnings.contains(.includeSkipped("~/.ssh/extra")))
    }

    func testHostsInIncludedFileAreNotImported() throws {
        // Only the selected file is read; the parser must not try to open the
        // Include target even when it exists on disk.
        let result = try parse("""
        Include /Users/test/.ssh/included
        Host visible
            HostName visible.example.com
        """)

        XCTAssertEqual(result.entries.map(\.alias), ["visible"])
    }

    // MARK: - Failure Modes

    func testInvalidPortFallsBackTo22WithWarning() throws {
        let result = try parse("""
        Host broken
            Port 99999
        """)

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.port, 22)
        XCTAssertTrue(result.warnings.contains(.invalidPort(alias: "broken", value: "99999")))
    }

    func testMissingIdentityFileIsKeptWithWarning() throws {
        let result = try parse("""
        Host nokey
            IdentityFile ~/.ssh/missing
        """)

        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.identityFiles, ["/Users/test/.ssh/missing"])
        XCTAssertTrue(
            result.warnings.contains(.identityFileUnavailable(alias: "nokey", path: "/Users/test/.ssh/missing"))
        )
    }

    func testDisabledProxyDirectivesAreNotFlagged() throws {
        let result = try parse("""
        Host direct
            ProxyCommand none
            ProxyJump none
        """)

        XCTAssertTrue(result.entries.first?.unsupportedDirectives.isEmpty ?? false)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnreadableRootFileThrows() {
        let parser = makeParser(files: [:])
        XCTAssertThrowsError(try parser.parse(configURL: configURL)) { error in
            XCTAssertTrue(error is SSHConfigError)
        }
    }

    func testMalformedLineIsReportedButOtherHostsStillParse() throws {
        let result = try parse("""
        Host good
            HostName good.example.com
            HostName
        """)

        XCTAssertEqual(result.entries.map(\.alias), ["good"])
        XCTAssertTrue(
            result.warnings.contains { warning in
                if case .malformedLine = warning { return true }
                return false
            }
        )
    }

    // MARK: - ssh semantics found in review

    func testHostNameTokenExpandsToAlias() throws {
        let result = try parse("""
        Host web
            HostName %h.corp.example.com
        """)

        XCTAssertEqual(result.entries.first?.hostName, "web.corp.example.com")
    }

    func testRemoteUserTokenFallsBackToLocalUser() throws {
        let localUser = NSUserName()
        let expectedPath = "/Users/test/.ssh/id_\(localUser)"

        let result = try parse("""
        Host keyed
            IdentityFile ~/.ssh/id_%r
        """, existingFiles: [expectedPath])

        XCTAssertEqual(result.entries.first?.identityFiles, [expectedPath])
        XCTAssertTrue(result.warnings.isEmpty)
    }
}
