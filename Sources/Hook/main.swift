import Foundation

// Fast CLI tool that reads Claude Code hook JSON from stdin
// and writes per-session status to ~/.claude/live-sessions/<session_id>.json

let sessionsDir = "\(NSHomeDirectory())/.claude/live-sessions"
let timestamp = Int(Date().timeIntervalSince1970)

let hookType: String
if CommandLine.arguments.count > 1 {
    hookType = CommandLine.arguments[1]
} else {
    hookType = "pre"
}

let inputData = FileHandle.standardInput.readDataToEndOfFile()

var toolName = ""
var message = ""
var sessionId = ""
var conversationId = ""
var transcriptPath = ""
var lastAssistantMessage = ""
var cwd = ""

if let json = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] {
    toolName = json["tool_name"] as? String ?? ""
    sessionId = json["session_id"] as? String ?? ""
    conversationId = json["conversation_id"] as? String ?? ""
    transcriptPath = json["transcript_path"] as? String ?? ""
    cwd = json["cwd"] as? String ?? ""

    // Use workspace_roots for cwd when cwd is not provided
    if cwd.isEmpty, let roots = json["workspace_roots"] as? [String], let first = roots.first {
        cwd = first
    }

    if let input = json["tool_input"] as? [String: Any] {
        if let filePath = input["file_path"] as? String {
            let fileName = (filePath as NSString).lastPathComponent
            switch toolName {
            case "Read": message = "Reading \(fileName)"
            case "Edit": message = "Editing \(fileName)"
            case "Write": message = "Writing \(fileName)"
            default: message = fileName
            }
        } else if let command = input["command"] as? String {
            let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "$ \(String(clean.prefix(40)))"
        } else if let pattern = input["pattern"] as? String {
            let short = String(pattern.prefix(30))
            message = toolName == "Grep" ? "Searching: \(short)" : "Finding: \(short)"
        } else if let prompt = input["prompt"] as? String {
            message = "Agent: \(String(prompt.prefix(30)))"
        } else if let description = input["description"] as? String {
            message = String(description.prefix(30))
        }
    }

    if let notifMessage = json["message"] as? String {
        message = String(notifMessage.prefix(80))
    }

    if let lastMsg = json["last_assistant_message"] as? String {
        lastAssistantMessage = String(lastMsg.prefix(500))
    }
}

// Fallback cwd from the hook's own working directory
if cwd.isEmpty {
    cwd = FileManager.default.currentDirectoryPath
}

// Determine session ID: session_id (CLI) > conversation_id (Cursor) > cwd-based fallback
let safeId: String
if !sessionId.isEmpty {
    safeId = sessionId
} else if !conversationId.isEmpty {
    safeId = conversationId
} else {
    safeId = cwd.replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}
let statusPath = "\(sessionsDir)/\(safeId).json"

// Ensure directory exists
try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

// Build status JSON
var status: [String: Any] = ["timestamp": timestamp, "session_id": safeId]

if !transcriptPath.isEmpty { status["transcript_path"] = transcriptPath }
if !cwd.isEmpty { status["cwd"] = cwd }

// Walk process tree to find TTY and parent .app bundle
func walkProcessTree() -> (tty: String?, app: String?) {
    var pid = getpid()
    var tty: String?
    var app: String?
    for _ in 0..<20 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }

        if tty == nil {
            let dev = info.kp_eproc.e_tdev
            if dev != 0 && dev != UInt32.max, let name = devname(dev, S_IFCHR) {
                tty = "/dev/\(String(cString: name))"
            }
        }

        let ppid = info.kp_eproc.e_ppid
        if ppid <= 1 { break }
        pid = ppid

        if app == nil {
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let ret = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            if ret > 0 {
                let path = String(cString: pathBuf)
                if let dotApp = path.range(of: ".app/") {
                    let before = path[..<dotApp.lowerBound]
                    if let slash = before.lastIndex(of: "/") {
                        app = String(before[before.index(after: slash)...])
                    }
                }
            }
        }

        if tty != nil && app != nil { break }
    }
    return (tty, app)
}
let procInfo = walkProcessTree()
if let tty = procInfo.tty { status["tty"] = tty }
if let app = procInfo.app { status["terminal_app"] = app }

switch hookType {
case "pre":
    status["status"] = "tool_use"
    status["tool"] = toolName
    status["message"] = message

case "post":
    status["status"] = "thinking"
    status["message"] = "Thinking..."

case "notify":
    status["status"] = "waiting"
    status["message"] = message.isEmpty ? "Needs attention" : message

case "stop":
    status["status"] = "completed"
    if !lastAssistantMessage.isEmpty {
        status["last_message"] = lastAssistantMessage
    }

default:
    status["status"] = "idle"
}

if let data = try? JSONSerialization.data(withJSONObject: status),
   let str = String(data: data, encoding: .utf8) {
    try? str.write(toFile: statusPath, atomically: true, encoding: .utf8)
}
