import Foundation

// Minimal test runner — no Xcode required

var passed = 0
var failed = 0
var errors: [String] = []

func expect(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        errors.append("  FAIL \(loc): \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  ✓ \(name)")
    } catch {
        failed += 1
        errors.append("  FAIL \(name): \(error)")
        print("  ✗ \(name): \(error)")
    }
}

// MARK: - Hook helpers

let hookPath: String = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // project root
        .appendingPathComponent(".build/debug/claude-status-hook")
        .path
}()
let sessionsDir = "\(NSHomeDirectory())/.claude/live-sessions"

func runHook(type: String, json: [String: Any]) -> [String: Any]? {
    let sessionId = json["session_id"] as? String ?? json["conversation_id"] as? String ?? "test"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: hookPath)
    process.arguments = [type]
    let pipe = Pipe()
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
    do {
        try process.run()
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    } catch { return nil }
    let path = "\(sessionsDir)/\(sessionId).json"
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return r
}

func cleanup(_ sid: String) {
    try? FileManager.default.removeItem(atPath: "\(sessionsDir)/\(sid).json")
}

func sid() -> String { "test-\(Int.random(in: 100000...999999))" }

// MARK: - Update logic helpers

struct Session {
    let status: String
    let timestamp: Double
}

struct Config {
    var autoShowOnWaiting: Bool
    var autoShowOnDone: Bool
    var autoCloseWhileThinking: Bool
    var userHidden: Bool
    var dismissedAt: Double
}

enum Action: Equatable, CustomStringConvertible {
    case show, hide, noChange
    var description: String {
        switch self { case .show: "show"; case .hide: "hide"; case .noChange: "noChange" }
    }
}

func computeUpdate(sessions: [Session], config: inout Config) -> Action {
    let hasAnySessions = !sessions.isEmpty
    let hasAnyWaiting = sessions.contains { $0.status == "waiting" }
    let hasAnyDone = sessions.contains { $0.status == "completed" }
    let allThinking = hasAnySessions && sessions.allSatisfy {
        $0.status == "tool_use" || $0.status == "thinking"
    }
    let hasNewEvent = sessions.contains { $0.timestamp > config.dismissedAt }

    if hasAnyWaiting && config.autoShowOnWaiting && hasNewEvent {
        config.userHidden = false
        return .show
    } else if hasAnyDone && config.autoShowOnDone && hasNewEvent {
        config.userHidden = false
        return .show
    } else if config.userHidden {
        return .noChange
    } else if allThinking && config.autoCloseWhileThinking {
        return .hide
    } else if hasAnySessions {
        return .show
    } else {
        return .hide
    }
}

func s(_ status: String, _ ts: Double = 1000) -> Session { Session(status: status, timestamp: ts) }
func cfg(waiting: Bool = true, done: Bool = true, thinking: Bool = false,
         hidden: Bool = false, dismissed: Double = 0) -> Config {
    Config(autoShowOnWaiting: waiting, autoShowOnDone: done,
           autoCloseWhileThinking: thinking, userHidden: hidden, dismissedAt: dismissed)
}

// ============================================================
// MARK: - Hook Integration Tests
// ============================================================

print("\n── Hook Integration Tests ──")

test("start sets thinking") {
    let id = sid(); defer { cleanup(id) }
    let r = runHook(type: "start", json: ["session_id": id, "cwd": "/tmp"])
    expect(r?["status"] as? String == "thinking", "expected thinking")
    expect(r?["message"] as? String == "Starting...", "expected Starting...")
}

test("pre sets tool_use for Bash") {
    let id = sid(); defer { cleanup(id) }
    let r = runHook(type: "pre", json: [
        "session_id": id, "cwd": "/tmp",
        "tool_name": "Bash", "tool_input": ["command": "echo hello"]
    ])
    expect(r?["status"] as? String == "tool_use", "expected tool_use")
    expect(r?["tool"] as? String == "Bash", "expected Bash")
    expect(r?["message"] as? String == "$ echo hello", "expected command message")
}

test("pre sets waiting for AskUserQuestion") {
    let id = sid(); defer { cleanup(id) }
    let r = runHook(type: "pre", json: [
        "session_id": id, "cwd": "/tmp",
        "tool_name": "AskUserQuestion",
        "tool_input": ["questions": [["question": "Which approach?"]]]
    ])
    expect(r?["status"] as? String == "waiting", "expected waiting")
    expect(r?["tool"] as? String == "AskUserQuestion", "expected AskUserQuestion")
    expect(r?["last_message"] as? String == "Which approach?", "expected question text")
}

test("pre shows friendly file names") {
    let id = sid(); defer { cleanup(id) }
    let r = runHook(type: "pre", json: [
        "session_id": id, "cwd": "/tmp",
        "tool_name": "Read", "tool_input": ["file_path": "/src/main.swift"]
    ])
    expect(r?["message"] as? String == "Reading main.swift", "expected friendly name")
}

test("post always sets thinking") {
    let id = sid(); defer { cleanup(id) }
    let r = runHook(type: "post", json: [
        "session_id": id, "cwd": "/tmp",
        "tool_name": "Bash", "tool_output": "output"
    ])
    expect(r?["status"] as? String == "thinking", "expected thinking")
    expect(r?["last_message"] as? String == "output", "expected output")
}

test("post AskUserQuestion sets thinking not waiting") {
    let id = sid(); defer { cleanup(id) }
    let r = runHook(type: "post", json: [
        "session_id": id, "cwd": "/tmp",
        "tool_name": "AskUserQuestion", "tool_output": "yes"
    ])
    expect(r?["status"] as? String == "thinking", "expected thinking after answer")
}

test("stop sets completed") {
    let id = sid(); defer { cleanup(id) }
    let r = runHook(type: "stop", json: [
        "session_id": id, "cwd": "/tmp",
        "last_assistant_message": "Done."
    ])
    expect(r?["status"] as? String == "completed", "expected completed")
    expect(r?["last_message"] as? String == "Done.", "expected message")
}

test("stop always sets completed even if waiting") {
    let id = sid(); defer { cleanup(id) }
    _ = runHook(type: "pre", json: [
        "session_id": id, "cwd": "/tmp",
        "tool_name": "AskUserQuestion",
        "tool_input": ["questions": [["question": "Q?"]]]
    ])
    let r = runHook(type: "stop", json: ["session_id": id, "cwd": "/tmp"])
    expect(r?["status"] as? String == "completed", "expected completed over waiting")
}

test("notify does not overwrite completed") {
    let id = sid(); defer { cleanup(id) }
    _ = runHook(type: "stop", json: ["session_id": id, "cwd": "/tmp", "last_assistant_message": "Done"])
    let r = runHook(type: "notify", json: ["session_id": id, "cwd": "/tmp", "message": "Attention"])
    expect(r?["status"] as? String == "completed", "expected completed preserved")
}

test("notify sets waiting when not completed") {
    let id = sid(); defer { cleanup(id) }
    _ = runHook(type: "start", json: ["session_id": id, "cwd": "/tmp"])
    let r = runHook(type: "notify", json: ["session_id": id, "cwd": "/tmp", "message": "Permission"])
    expect(r?["status"] as? String == "waiting", "expected waiting")
}

test("notify preserves AskUserQuestion question text") {
    let id = sid(); defer { cleanup(id) }
    _ = runHook(type: "pre", json: [
        "session_id": id, "cwd": "/tmp",
        "tool_name": "AskUserQuestion",
        "tool_input": ["questions": [["question": "Which DB?"]]]
    ])
    let r = runHook(type: "notify", json: ["session_id": id, "cwd": "/tmp", "message": "Attention"])
    expect(r?["last_message"] as? String == "Which DB?", "expected question preserved")
}

test("session ID falls back to conversation_id") {
    let id = "conv-\(Int.random(in: 100000...999999))"; defer { cleanup(id) }
    let r = runHook(type: "start", json: ["conversation_id": id, "cwd": "/tmp"])
    expect(r?["session_id"] as? String == id, "expected conversation_id as session_id")
}

test("full lifecycle: start → tool → question → answer → stop → notify") {
    let id = sid(); defer { cleanup(id) }
    var r = runHook(type: "start", json: ["session_id": id, "cwd": "/tmp"])
    expect(r?["status"] as? String == "thinking", "1: thinking")
    r = runHook(type: "pre", json: ["session_id": id, "cwd": "/tmp", "tool_name": "Bash", "tool_input": ["command": "ls"]])
    expect(r?["status"] as? String == "tool_use", "2: tool_use")
    r = runHook(type: "post", json: ["session_id": id, "cwd": "/tmp", "tool_name": "Bash", "tool_output": "file.txt"])
    expect(r?["status"] as? String == "thinking", "3: thinking")
    r = runHook(type: "pre", json: ["session_id": id, "cwd": "/tmp", "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Continue?"]]]])
    expect(r?["status"] as? String == "waiting", "4: waiting")
    r = runHook(type: "post", json: ["session_id": id, "cwd": "/tmp", "tool_name": "AskUserQuestion", "tool_output": "Yes"])
    expect(r?["status"] as? String == "thinking", "5: thinking")
    r = runHook(type: "stop", json: ["session_id": id, "cwd": "/tmp", "last_assistant_message": "All done!"])
    expect(r?["status"] as? String == "completed", "6: completed")
    r = runHook(type: "notify", json: ["session_id": id, "cwd": "/tmp", "message": "Attention"])
    expect(r?["status"] as? String == "completed", "7: still completed")
}

// ============================================================
// MARK: - Update Logic Tests
// ============================================================

print("\n── Update Logic Tests ──")

// Auto-show on waiting
test("auto-show waiting: shows when enabled") {
    var c = cfg(hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("waiting")], config: &c) == .show, "expected show")
    expect(c.userHidden == false, "expected userHidden cleared")
}
test("auto-show waiting: no show when disabled") {
    var c = cfg(waiting: false, hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("waiting")], config: &c) == .noChange, "expected noChange")
}
test("auto-show waiting: no show for old events") {
    var c = cfg(hidden: true, dismissed: 2000)
    expect(computeUpdate(sessions: [s("waiting")], config: &c) == .noChange, "expected noChange")
}
test("auto-show waiting: shows for new event after dismiss") {
    var c = cfg(hidden: true, dismissed: 999)
    expect(computeUpdate(sessions: [s("waiting", 1000)], config: &c) == .show, "expected show")
}

// Auto-show on done
test("auto-show done: shows when enabled") {
    var c = cfg(hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("completed")], config: &c) == .show, "expected show")
    expect(c.userHidden == false, "expected userHidden cleared")
}
test("auto-show done: no show when disabled") {
    var c = cfg(done: false, hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("completed")], config: &c) == .noChange, "expected noChange")
}
test("auto-show done: no show for old events") {
    var c = cfg(hidden: true, dismissed: 2000)
    expect(computeUpdate(sessions: [s("completed")], config: &c) == .noChange, "expected noChange")
}

// Auto-close while thinking
test("auto-close: hides when all thinking") {
    var c = cfg(thinking: true)
    expect(computeUpdate(sessions: [s("thinking")], config: &c) == .hide, "expected hide")
}
test("auto-close: hides when all tool_use") {
    var c = cfg(thinking: true)
    expect(computeUpdate(sessions: [s("tool_use")], config: &c) == .hide, "expected hide")
}
test("auto-close: no hide when disabled") {
    var c = cfg(thinking: false)
    expect(computeUpdate(sessions: [s("thinking")], config: &c) == .show, "expected show")
}
test("auto-close: no hide if any waiting") {
    var c = cfg(thinking: true)
    expect(computeUpdate(sessions: [s("thinking"), s("waiting")], config: &c) == .show, "expected show")
}
test("auto-close: no hide if any completed") {
    var c = cfg(thinking: true)
    expect(computeUpdate(sessions: [s("thinking"), s("completed")], config: &c) == .show, "expected show")
}

// Multi-session
test("multi: waiting priority over thinking") {
    var c = cfg(thinking: true, hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("thinking"), s("waiting")], config: &c) == .show, "expected show")
}
test("multi: any done shows even if others working") {
    var c = cfg(hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("thinking"), s("completed")], config: &c) == .show, "expected show")
}
test("multi: all thinking hides with auto-close") {
    var c = cfg(thinking: true)
    expect(computeUpdate(sessions: [s("thinking"), s("tool_use")], config: &c) == .hide, "expected hide")
}
test("multi: waiting priority over done") {
    var c = cfg(hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("waiting"), s("completed")], config: &c) == .show, "expected show")
}

// Dismiss / hidden
test("hidden blocks show without new events") {
    var c = cfg(hidden: true, dismissed: 2000)
    expect(computeUpdate(sessions: [s("tool_use")], config: &c) == .noChange, "expected noChange")
}
test("hidden overridden by waiting") {
    var c = cfg(hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("waiting")], config: &c) == .show, "expected show")
}
test("hidden overridden by done") {
    var c = cfg(hidden: true, dismissed: 500)
    expect(computeUpdate(sessions: [s("completed")], config: &c) == .show, "expected show")
}

// Edge cases
test("no sessions hides") {
    var c = cfg()
    expect(computeUpdate(sessions: [], config: &c) == .hide, "expected hide")
}
test("idle session still shows") {
    var c = cfg()
    expect(computeUpdate(sessions: [s("idle")], config: &c) == .show, "expected show")
}
test("timestamp equality not new event") {
    var c = cfg(hidden: true, dismissed: 1000)
    expect(computeUpdate(sessions: [s("waiting", 1000)], config: &c) == .noChange, "expected noChange")
}

// ============================================================
// MARK: - Results
// ============================================================

print("\n── Results ──")
print("  \(passed) passed, \(failed) failed")
if !errors.isEmpty {
    print("\nFailures:")
    errors.forEach { print($0) }
}
exit(failed > 0 ? 1 : 0)
