import Foundation
import Testing
@testable import Clip_Builder

struct OnDeviceAgreementTests {
    @Test func acceptanceAndReport() throws {
        var report = OnDeviceAgreement.Report(item: "images", cases: [])
        #expect(!report.passed)
        report.cases = (0..<10).map { .init(id: String($0), local: "a", model: $0 == 9 ? "b" : "a", agrees: $0 < 9) }
        #expect(report.percentage == 90)
        #expect(report.passed)
        report.errors.append("Failed case")
        #expect(!report.passed)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try OnDeviceAgreement.save(report, root: root)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
    }
}
