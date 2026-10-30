import Foundation
import Testing
@testable import BrainFogCore

struct TimelineTests {
    @Test func changesListEveryEditButNotTheFirstSightingOrBeforeCopies() throws {
        let box = try Sandbox()
        let history = box.history
        let file = box.project.appendingPathComponent("CLAUDE.md")
        try box.write("CLAUDE.md", "one\n", in: box.project)
        history.observe(file)                                    // first seen: not a change
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        history.observe(file)                                    // an agent's edit
        try FileWriter.write("three\n", to: file, history: history)  // BrainFog's save

        let changes = history.changes(to: [file])
        #expect(changes.map(\.version.origin) == [.brainFog, .observed])
        #expect(changes.map { history.text(of: $0.previous) } == ["two\n", "one\n"])
    }

    @Test func undoPutsBackTheTextBeforeTheChange() throws {
        let box = try Sandbox()
        let history = box.history
        let file = box.project.appendingPathComponent("AGENTS.md")
        try box.write("AGENTS.md", "keep\n", in: box.project)
        history.observe(file)
        try "agent wrote this\n".write(to: file, atomically: true, encoding: .utf8)
        history.observe(file)

        let change = try #require(history.changes(to: [file]).first)
        let undo = try #require(history.undo(change))
        try undo.apply(history: history)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep\n")
        // Nothing left to undo once the file is back.
        #expect(history.undo(change) == nil)
    }
}
