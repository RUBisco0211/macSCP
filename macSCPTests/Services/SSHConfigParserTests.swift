//
//  SSHConfigParserTests.swift
//  macSCPTests
//
//  Unit tests for the ssh_config parser.
//  All tests are hermetic: file contents are injected.
//

import XCTest
@testable import macSCP

final class SSHConfigParserTests: XCTestCase {
    private let home = "/Users/test"
    private let configPath = "/Users/test/.ssh/config"

    private var configURL: URL {
        URL(fileURLWithPath: configPath)
    }

    private func makeParser(files: [String: String]) -> SSHConfigParser {
        SSHConfigParser(
            reader: StubSSHConfigReader(files: files),
            homeDirectory: home
        )
    }

    private func parse(_ config: String) throws -> [SSHConfigEntry] {
        try makeParser(files: [configPath: config]).parse(configURL: configURL)
    }

    // MARK: - Field Mapping

    func testParsesFullHostBlock() throws {
        let entries = try parse("""
        Host lab
            HostName lab.example.com
            User deploy
            Port 1185
            IdentityFile ~/.ssh/id_rsa
        """)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.alias, "lab")
        XCTAssertEqual(entry.hostName, "lab.example.com")
        XCTAssertEqual(entry.user, "deploy")
        XCTAssertEqual(entry.port, 1185)
        XCTAssertEqual(entry.identityFile, "/Users/test/.ssh/id_rsa")
        XCTAssertTrue(entry.usesKeyAuthentication)
    }

    func testDefaultsToAliasAndPort22() throws {
        let entries = try parse("Host bare")

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.hostName, "bare")
        XCTAssertNil(entry.user)
        XCTAssertEqual(entry.port, 22)
        XCTAssertNil(entry.identityFile)
        XCTAssertFalse(entry.usesKeyAuthentication)
    }

    func testTrimsTrailingWhitespaceAndStripsComments() throws {
        let entries = try parse("""
        Host web   # production box
            HostName lab.example.com\u{20}\u{20}\u{20}
            User deploy
        """)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.alias, "web")
        XCTAssertEqual(entry.hostName, "lab.example.com")
        XCTAssertEqual(entry.user, "deploy")
    }

    func testSupportsEqualsSyntax() throws {
        let entries = try parse("""
        Host=db
            HostName=db.internal
            Port=2222
        """)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.alias, "db")
        XCTAssertEqual(entry.hostName, "db.internal")
        XCTAssertEqual(entry.port, 2222)
    }

    func testSplitsMultipleAliasesIntoSeparateEntries() throws {
        let entries = try parse("""
        Host alpha beta
            HostName shared.example.com
            User shared
        """)

        XCTAssertEqual(entries.map(\.alias), ["alpha", "beta"])
        XCTAssertTrue(entries.allSatisfy { $0.hostName == "shared.example.com" })
        XCTAssertTrue(entries.allSatisfy { $0.user == "shared" })
    }

    // MARK: - ssh Resolution Semantics

    func testGlobalDirectivesApplyToEveryHost() throws {
        let entries = try parse("""
        User globaluser

        Host one
            HostName one.example.com
        """)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.user, "globaluser")
        XCTAssertEqual(entry.hostName, "one.example.com")
    }

    func testFirstObtainedValueWins() throws {
        let entries = try parse("""
        Host target
            User first
            Port 2200

        Host target
            User second
            Port 2210
        """)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.user, "first")
        XCTAssertEqual(entry.port, 2200)
    }

    func testStarBlockSuppliesDefaultsWithoutBecomingAnEntry() throws {
        let entries = try parse("""
        Host *
            User staruser

        Host real
            HostName real.example.com
        """)

        XCTAssertEqual(entries.map(\.alias), ["real"])
        XCTAssertEqual(entries.first?.user, "staruser")
    }

    func testWildcardHostIsSkipped() throws {
        let entries = try parse("""
        Host *.example.com
            User wildcard
        """)

        XCTAssertTrue(entries.isEmpty)
    }

    func testNegatedPatternDoesNotProduceEntries() throws {
        let entries = try parse("""
        Host web !web-test
            HostName web.example.com
        """)

        XCTAssertEqual(entries.map(\.alias), ["web"])
        XCTAssertEqual(entries.first?.hostName, "web.example.com")
    }

    func testMatchBlockDirectivesAreIgnored() throws {
        let entries = try parse("""
        Host before
            HostName before.example.com

        Match host foo
            User matchuser

        Host after
            HostName after.example.com
        """)

        XCTAssertEqual(entries.map(\.alias), ["before", "after"])
        XCTAssertNil(entries[0].user)
        XCTAssertNil(entries[1].user)
    }

    // MARK: - Tokens

    func testHostNameTokenExpandsToAlias() throws {
        let entries = try parse("""
        Host web
            HostName %h.corp.example.com
        """)

        XCTAssertEqual(entries.first?.hostName, "web.corp.example.com")
    }

    func testRemoteUserTokenFallsBackToLocalUser() throws {
        let entries = try parse("""
        Host keyed
            IdentityFile ~/.ssh/id_%r
        """)

        XCTAssertEqual(entries.first?.identityFile, "/Users/test/.ssh/id_\(NSUserName())")
    }

    func testIdentityFilePercentTokensUseResolvedValues() throws {
        let entries = try parse("""
        Host token
            HostName t.example.com
            User bob
            Port 2022
            IdentityFile ~/.ssh/id_%r@%h:%p
        """)

        XCTAssertEqual(entries.first?.identityFile, "/Users/test/.ssh/id_bob@t.example.com:2022")
    }

    func testKeepsQuotedPathsWithSpaces() throws {
        let entries = try parse("""
        Host spaced
            IdentityFile "~/keys/my key"
        """)

        XCTAssertEqual(entries.first?.identityFile, "/Users/test/keys/my key")
    }

    // MARK: - Identity file paths

    func testRelativeIdentityFilePathIsResolvedAgainstConfigDirectory() throws {
        let entries = try parse("""
        Host relative
            IdentityFile keys/id_ed25519
        """)

        XCTAssertEqual(entries.first?.identityFile, "/Users/test/.ssh/keys/id_ed25519")
    }

    func testAbsoluteIdentityFilePathIsKept() throws {
        let entries = try parse("""
        Host absolute
            IdentityFile /opt/keys/id_rsa
        """)

        XCTAssertEqual(entries.first?.identityFile, "/opt/keys/id_rsa")
    }

    func testTildeIdentityFilePathUsesHomeDirectory() throws {
        let entries = try parse("""
        Host home
            IdentityFile ~/.ssh/custom_key
        """)

        XCTAssertEqual(entries.first?.identityFile, "/Users/test/.ssh/custom_key")
    }

    // MARK: - Ignored Content

    func testIncludeTargetsAreNotRead() throws {
        let entries = try parse("""
        Include /Users/test/.ssh/included
        Host visible
            HostName visible.example.com
        """)

        XCTAssertEqual(entries.map(\.alias), ["visible"])
    }

    func testUnsupportedDirectivesAreIgnored() throws {
        let entries = try parse("""
        Host proxied
            HostName proxied.example.com
            ProxyCommand none
            ProxyJump bastion
            RemoteForward 127.0.0.1:7890 127.0.0.1:7890
            SetEnv FOO=bar
        """)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.hostName, "proxied.example.com")
    }

    func testInvalidPortFallsBackTo22() throws {
        let entries = try parse("""
        Host broken
            Port 99999
        """)

        XCTAssertEqual(entries.first?.port, 22)
    }

    func testUnreadableFileThrows() {
        let parser = makeParser(files: [:])

        XCTAssertThrowsError(try parser.parse(configURL: configURL)) { error in
            XCTAssertTrue(error is SSHConfigError)
        }
    }
}
