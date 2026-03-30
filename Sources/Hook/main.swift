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
var transcriptPath = ""
var lastAssistantMessage = ""
var cwd = ""

if let json = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] {
    toolName = json["tool_name"] as? String ?? ""
    sessionId = json["session_id"] as? String ?? ""
    transcriptPath = json["transcript_path"] as? String ?? ""
    cwd = json["cwd"] as? String ?? ""

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

// Use session_id for the filename, fallback to "default"
let safeId = sessionId.isEmpty ? "default" : sessionId
let statusPath = "\(sessionsDir)/\(safeId).json"

// Ensure directory exists
try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

// Build status JSON
var status: [String: Any] = ["timestamp": timestamp, "session_id": safeId]

if !transcriptPath.isEmpty { status["transcript_path"] = transcriptPath }
if !cwd.isEmpty { status["cwd"] = cwd }

// Capture TTY by walking process tree (unique per Terminal tab)
func findTTY() -> String? {
    var pid = getpid()
    for _ in 0..<10 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        if dev != 0 && dev != UInt32.max, let name = devname(dev, S_IFCHR) {
            return "/dev/\(String(cString: name))"
        }
        let ppid = info.kp_eproc.e_ppid
        if ppid <= 1 { return nil }
        pid = ppid
    }
    return nil
}
if let tty = findTTY() { status["tty"] = tty }

switch hookType {
case "pre":
    status["status"] = "tool_use"
    status["tool"] = toolName
    status["message"] = message

case "post":
    status["status"] = "idle"

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
