import Foundation
import Testing
@testable import SweepCore

@Suite("Full Disk Access detection")
struct PermissionsTests {

    @Test("A readable probe means granted")
    func readableIsGranted() {
        let f = Fixture()
        f.file("probe.db", bytes: 16)
        #expect(FullDiskAccess.status(probes: [f.root + "/probe.db"]) == .granted)
    }

    @Test("A missing probe proves nothing and must not read as denied")
    func missingIsIndeterminate() {
        #expect(FullDiskAccess.status(probes: ["/nonexistent/never/here.db"]) == .indeterminate)
    }

    @Test("A denied read is denied")
    func unreadableIsDenied() {
        let f = Fixture()
        f.file("locked.db", bytes: 16)
        let path = f.root + "/locked.db"
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        // Root bypasses file modes, so the denial can only be asserted as a non-root user.
        try? #require(getuid() != 0)
        #expect(FullDiskAccess.status(probes: [path]) == .denied)
    }

    @Test("One readable probe outweighs missing ones, in any order")
    func oneGrantWins() {
        let f = Fixture()
        f.file("probe.db", bytes: 16)
        #expect(FullDiskAccess.status(probes: ["/nonexistent/x", f.root + "/probe.db"]) == .granted)
    }
}
