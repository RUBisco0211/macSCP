//
//  StubSSHConfigReader.swift
//  macSCPTests
//
//  In-memory SSHConfigReading implementation for tests.
//

import Foundation
@testable import macSCP

struct StubSSHConfigReader: SSHConfigReading {
    let files: [String: String]

    func read(contentsOf url: URL) throws -> String {
        guard let text = files[url.path] else {
            throw SSHConfigError.unreadableFile(path: url.path, reason: "not present in stub fixture")
        }
        return text
    }
}
