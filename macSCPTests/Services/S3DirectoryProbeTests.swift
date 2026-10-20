import XCTest

@testable import macSCP

final class S3DirectoryProbeTests: XCTestCase {
    func testDirectoryProbePrefixRequiresTrailingSlash() {
        XCTAssertEqual(S3Session.directoryProbePrefix("/fixed/report"), "fixed/report/")
        XCTAssertEqual(S3Session.directoryProbePrefix("fixed/report"), "fixed/report/")
        XCTAssertEqual(S3Session.directoryProbePrefix("/fixed/report/"), "fixed/report/")
    }

    func testDirectoryProbePrefixDoesNotMatchSiblingKeys() {
        let prefix = S3Session.directoryProbePrefix("/fixed/report")
        XCTAssertTrue("fixed/report/file.txt".hasPrefix(prefix))
        XCTAssertFalse("fixed/report.pdf".hasPrefix(prefix))
        XCTAssertFalse("fixed/reports/x".hasPrefix(prefix))
    }

    func testRootAndEmptyPathsStayEmpty() {
        XCTAssertEqual(S3Session.directoryProbePrefix("/"), "")
        XCTAssertEqual(S3Session.directoryProbePrefix(""), "")
    }
}
