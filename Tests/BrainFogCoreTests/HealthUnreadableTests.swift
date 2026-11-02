import Foundation
import Testing
@testable import BrainFogCore

/// Files an agent silently reads nothing from should show up in Health.
@Suite struct HealthUnreadableTests {
    @Test func truncatedMcpJsonIsReported() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", "{ \"mcpServers\": ", in: s.project)
        let issues = HealthCheck.unreadable(project: s.project, environment: s.env())
        #expect(issues.map(\.title) == [".mcp.json can’t be read"])
        #expect(issues.first?.agents.contains(.claudeCode) == true)
    }

    @Test func emptyAndValidConfigsAreNotReported() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", "", in: s.project)
        try s.write(".cursor/mcp.json", "{\r\n  // ok\r\n  \"mcpServers\": {}\r\n}\r\n", in: s.project)
        #expect(HealthCheck.unreadable(project: s.project, environment: s.env()).isEmpty)
    }

    @Test func brokenInstructionLinkIsReported() throws {
        let s = try Sandbox()
        try FileManager.default.createSymbolicLink(atPath: s.project.appendingPathComponent("CLAUDE.md").path,
                                                   withDestinationPath: "nowhere.md")
        let issues = HealthCheck.unreadable(project: s.project, environment: s.env())
        #expect(issues.map(\.title) == ["CLAUDE.md links to a missing file"])
    }
}
