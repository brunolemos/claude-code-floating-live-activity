import Cocoa
import SwiftUI
import WidgetKit

// MARK: - Models

struct ClaudeStatus: Codable {
    let status: String
    let tool: String?
    let message: String?
    let sessionId: String?
    let transcriptPath: String?
    let lastMessage: String?
    let cwd: String?
    let tty: String?
    let terminalApp: String?
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case status, tool, message, timestamp, cwd, tty
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case lastMessage = "last_message"
        case terminalApp = "terminal_app"
    }

    static var idle: ClaudeStatus {
        ClaudeStatus(status: "idle", tool: nil, message: nil, sessionId: nil,
                     transcriptPath: nil, lastMessage: nil, cwd: nil, tty: nil,
                     terminalApp: nil, timestamp: Date().timeIntervalSince1970)
    }

    var isStale: Bool {
        let age = Date().timeIntervalSince1970 - timestamp
        switch status {
        case "thinking": return age > 120   // 2 min — transient state, dead if no update
        case "completed": return age > 300  // 5 min — show "Done" briefly then clean up
        default: return age > 600           // 10 min — tool_use, waiting, idle
        }
    }
    var isActive: Bool { (status == "tool_use" || status == "waiting" || status == "thinking") && !isStale }

    var displayText: String {
        switch status {
        case "tool_use":
            if let msg = message, !msg.isEmpty { return truncate(msg, max: 42) }
            if let tool = tool { return friendlyToolName(tool) }
            return "Working..."
        case "thinking": return "Thinking..."
        case "waiting": return message ?? "Waiting..."
        case "completed": return "Done"
        default: return "Idle"
        }
    }

    var shortCwd: String {
        guard let cwd = cwd else { return "" }
        return (cwd as NSString).lastPathComponent
    }

    var statusColor: Color {
        switch status {
        case "tool_use": return .blue
        case "thinking": return .purple
        case "waiting": return .orange
        case "completed": return .green
        default: return Color(white: 0.4)
        }
    }

    private func friendlyToolName(_ tool: String) -> String {
        switch tool {
        case "Read": return "Reading file..."
        case "Edit": return "Editing code..."
        case "Write": return "Writing file..."
        case "Bash": return "Running command..."
        case "Grep": return "Searching code..."
        case "Glob": return "Finding files..."
        case "Agent": return "Researching..."
        case "WebSearch": return "Searching web..."
        case "WebFetch": return "Fetching page..."
        default: return "Working..."
        }
    }

    private func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}

struct WidgetEvent: Codable {
    let type: String
    let text: String
    let timestamp: Double
    let sessionId: String?
}

// MARK: - Transcript Tailer

class TranscriptTailer {
    private var currentPath: String?
    private var pollTimer: Timer?
    private(set) var lastText: String?
    private(set) var isThinking = false
    let sessionId: String
    var onChange: (() -> Void)?

    init(sessionId: String) { self.sessionId = sessionId }

    func setTranscript(path: String?) {
        guard let path = path, !path.isEmpty else { return }
        if path != currentPath {
            currentPath = path
            lastText = nil
            isThinking = false
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        guard let path = currentPath else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let tailBytes = 20000
        let slice = data.count > tailBytes ? data.suffix(tailBytes) : data
        guard let text = String(data: slice, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        var changed = false

        // Check if the last entry is a user message → Claude is thinking
        var newThinking = false
        if let lastLine = lines.last,
           let lineData = lastLine.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
            let role = obj["type"] as? String ?? obj["role"] as? String ?? ""
            newThinking = (role == "user")
        }
        if newThinking != isThinking { isThinking = newThinking; changed = true }

        // Find the last assistant text message (scan backward)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String == "assistant" || obj["role"] as? String == "assistant"),
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]]
            else { continue }

            for item in content.reversed() {
                if item["type"] as? String == "text",
                   let itemText = item["text"] as? String {
                    let trimmed = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let newText = String(trimmed.prefix(500))
                        if newText != lastText { lastText = newText; changed = true }
                        if changed { onChange?() }
                        return
                    }
                }
            }
        }
        if changed { onChange?() }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
    }
}

// MARK: - Session Manager

class SessionManager {
    private(set) var sessions: [String: ClaudeStatus] = [:]
    private var tailers: [String: TranscriptTailer] = [:]
    var onChange: (() -> Void)?

    var activeSessions: [(String, ClaudeStatus)] {
        sessions.filter { !$0.value.isStale }
            .sorted { $0.value.timestamp > $1.value.timestamp }
    }

    var activeCount: Int { activeSessions.filter { $0.1.isActive }.count }

    func update(sessionId: String, status: ClaudeStatus) {
        sessions[sessionId] = status
        if tailers[sessionId] == nil {
            let tailer = TranscriptTailer(sessionId: sessionId)
            tailer.onChange = { [weak self] in self?.onChange?() }
            tailers[sessionId] = tailer
        }
        tailers[sessionId]?.setTranscript(path: status.transcriptPath)
        onChange?()
    }

    func lastMessage(for sessionId: String) -> String? {
        // When waiting for input, prefer the session's last_message (contains the question)
        if sessions[sessionId]?.status == "waiting",
           let msg = sessions[sessionId]?.lastMessage, !msg.isEmpty {
            return msg
        }
        return tailers[sessionId]?.lastText
            ?? sessions[sessionId]?.lastMessage
    }

    func isThinking(for sessionId: String) -> Bool {
        tailers[sessionId]?.isThinking ?? false
    }

    func cleanupStale() -> [String] {
        let staleIds = sessions.filter { $0.value.isStale }.map { $0.key }
        for id in staleIds {
            sessions.removeValue(forKey: id)
            tailers[id]?.stop()
            tailers.removeValue(forKey: id)
            let path = "\(NSHomeDirectory())/.claude/live-sessions/\(id).json"
            try? FileManager.default.removeItem(atPath: path)
        }
        return staleIds
    }
}

// MARK: - Update Checker

class UpdateChecker {
    private let repo = "brunolemos/claude-code-floating-live-activity"
    private var installedHash: String?
    private var sourceDir: String?
    private var installedFingerprint: String?
    private var checkTimer: Timer?
    var onUpdateAvailable: ((Bool) -> Void)?

    var isLocalDev: Bool {
        guard let dir = sourceDir, !dir.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: "\(dir)/.git")
    }

    func start() {
        loadInstalledVersion()
        check()
        let interval: TimeInterval = isLocalDev ? 10 : 6 * 3600
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    private func loadInstalledVersion() {
        let resources = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources")
        installedHash = readFile("\(resources)/version.txt")
        sourceDir = readFile("\(resources)/source-dir.txt")
        installedFingerprint = readFile("\(resources)/source-fingerprint.txt")
    }

    private func readFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func check() {
        guard let hash = installedHash, !hash.isEmpty, hash != "unknown" else { return }
        if isLocalDev {
            checkLocal()
        } else {
            checkRemote(installedHash: hash)
        }
    }

    private func checkLocal() {
        guard let dir = sourceDir else { return }
        let safe = escaped(dir)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let currentHead = self.shell("git -C '\(safe)' rev-parse HEAD")
            let currentFP = self.shell(
                "cd '\(safe)' && { git diff HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | shasum -a 256 | cut -d' ' -f1"
            )
            let headChanged = currentHead != nil && currentHead != self.installedHash
            let fpChanged = currentFP != nil && currentFP != self.installedFingerprint
            DispatchQueue.main.async {
                self.onUpdateAvailable?(headChanged || fpChanged)
            }
        }
    }

    private func checkRemote(installedHash: String) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/commits/main") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String
            else { return }
            let available = !sha.hasPrefix(installedHash) && !installedHash.hasPrefix(sha)
            DispatchQueue.main.async {
                self?.onUpdateAvailable?(available)
            }
        }.resume()
    }

    private func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func shell(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func performUpdate() {
        let script: String
        if isLocalDev, let dir = sourceDir {
            script = """
            #!/bin/bash
            set -e
            cd '\(escaped(dir))'
            bash install.sh
            """
        } else {
            script = """
            #!/bin/bash
            set -e
            TEMP=$(mktemp -d)
            git clone https://github.com/\(repo).git "$TEMP/repo" 2>/dev/null
            cd "$TEMP/repo"
            bash install.sh
            rm -rf "$TEMP"
            """
        }

        let tempScript = NSTemporaryDirectory() + "claude-live-update.sh"
        try? script.write(toFile: tempScript, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup /bin/bash '\(tempScript)' > /tmp/claude-live-update.log 2>&1 &"]
        try? process.run()
    }
}

// MARK: - Launch at Login

class LaunchAtLoginManager {
    private static let plistName = "org.brunolemos.claude-live-activity"

    private static var plistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/\(plistName).plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            let dir = "\(NSHomeDirectory())/Library/LaunchAgents"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let appPath = Bundle.main.executablePath
                ?? "\(NSHomeDirectory())/Applications/ClaudeLiveActivity.app/Contents/MacOS/ClaudeLiveActivity"

            let plist: [String: Any] = [
                "Label": plistName,
                "ProgramArguments": [appPath],
                "RunAtLoad": true,
                "KeepAlive": true
            ]

            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: URL(fileURLWithPath: plistPath))
            }
        } else {
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - View Model

struct SessionInfo: Identifiable {
    let id: String
    var status: ClaudeStatus
    var lastMessage: String?
    var transcriptThinking: Bool = false
}

class LiveActivityViewModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var selectedId: String?
    @Published var updateAvailable = false
    @Published var isUpdating = false
    var isLocalDev = false
    weak var window: NSPanel?
    var onClose: (() -> Void)?
    var onUpdate: (() -> Void)?

    var selected: SessionInfo? { sessions.first { $0.id == selectedId } }

    func updateSessions(_ active: [(String, ClaudeStatus)],
                         lastMessageFor: (String) -> String?,
                         isThinkingFor: (String) -> Bool) {
        var newSessions: [SessionInfo] = []
        for (id, status) in active {
            newSessions.append(SessionInfo(id: id, status: status,
                                           lastMessage: lastMessageFor(id),
                                           transcriptThinking: isThinkingFor(id)))
        }
        sessions = newSessions

        // Auto-select if nothing selected or selected was removed
        if selectedId == nil || !sessions.contains(where: { $0.id == selectedId }) {
            selectedId = sessions.first?.id
        }
    }

    func select(_ id: String) {
        selectedId = id
    }

    func focusTerminal(for sessionId: String? = nil) {
        let id = sessionId ?? selectedId
        guard let session = sessions.first(where: { $0.id == id }) else {
            activateApp("Terminal")
            return
        }

        let app = session.status.terminalApp
        let tty = session.status.tty ?? ""

        switch app {
        case "Terminal":
            focusTerminalAppByTTY(tty)
        case "iTerm", "iTerm2":
            focusiTermByTTY(tty)
        case .some(let name) where !name.isEmpty:
            activateApp(name)
        default:
            activateApp("Terminal")
        }
    }

    private func focusTerminalAppByTTY(_ tty: String) {
        guard !tty.isEmpty else {
            activateApp("Terminal")
            return
        }
        let safeTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
        runOsascript("""
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with i from 1 to count of tabs of w
                    if tty of tab i of w is "\(safeTty)" then
                        set selected tab of w to tab i of w
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    private func focusiTermByTTY(_ tty: String) {
        guard !tty.isEmpty else {
            activateApp("iTerm")
            return
        }
        let safeTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
        runOsascript("""
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(safeTty)" then
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """)
    }

    private func activateApp(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name]
            process.standardOutput = nil
            process.standardError = nil
            try? process.run()
        }
    }

    private func runOsascript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = nil
            process.standardError = nil
            try? process.run()
        }
    }
}

// MARK: - SwiftUI Views

struct LiveActivityView: View {
    @ObservedObject var model: LiveActivityViewModel
    @State private var isPulsing = false
    @State private var flashOpacity: Double = 0

    private var showLabels: Bool { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main content — fixed height
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Claude Code")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    if !model.isLocalDev {
                        if model.isUpdating {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.7)
                                Text("Updating…")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(.white.opacity(0.5))
                        } else if model.updateAvailable {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 10))
                                Text("Update")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .contentShape(Capsule())
                            .onTapGesture { model.onUpdate?() }
                        }
                    }
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.06)))
                        .contentShape(Circle())
                        .onTapGesture { model.onClose?() }
                        .onHover { h in }
                }

                // Status
                if let s = model.selected {
                    let thinking = s.transcriptThinking && s.status.status == "completed"
                    let isWorking = s.status.status == "tool_use" || s.status.status == "thinking" || thinking
                    let dotColor = thinking ? Color.purple : s.status.statusColor
                    let statusText = thinking ? "Thinking..." : s.status.displayText
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 8, height: 8)
                            .scaleEffect(isWorking && isPulsing ? 1.4 : 1.0)
                            .opacity(isWorking && isPulsing ? 1.0 : (isWorking ? 0.7 : 1.0))
                            .animation(
                                isWorking
                                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                    : .default,
                                value: isPulsing && isWorking
                            )
                            .onAppear { isPulsing = true }

                        Text(statusText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(isWorking || s.status.isActive ? .white : .white.opacity(0.5))
                            .lineLimit(1)
                    }

                    if !thinking, let msg = s.lastMessage {
                        Text(msg)
                            .font(.system(size: 11.5, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                } else {
                    Text("No active sessions")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(" ")
                        .font(.system(size: 11.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture {
                flash()
                model.focusTerminal()
            }

            // Bottom tabs — pinned at bottom
            if !model.sessions.isEmpty {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            SessionTabView(
                                index: index + 1,
                                label: showLabels ? session.status.shortCwd : nil,
                                statusColor: session.status.statusColor,
                                isActive: session.status.isActive,
                                isSelected: session.id == model.selectedId
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                flash()
                                model.select(session.id)
                                model.focusTerminal(for: session.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 200, maxWidth: 1200, minHeight: 150, maxHeight: 250, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(flashOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func flash() {
        withAnimation(.easeOut(duration: 0.06)) { flashOpacity = 0.03 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeIn(duration: 0.15)) { flashOpacity = 0 }
        }
    }
}

struct SessionTabView: View {
    let index: Int
    let label: String?
    let statusColor: Color
    let isActive: Bool
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
            Text("\(index)")
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.4))
            if let label = label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(isSelected ? 0.6 : 0.3))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.12 : (isHovered ? 0.06 : 0)))
        )
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
    }
}

// MARK: - Custom Panel & Hosting View

class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

// MARK: - Floating Window

class FloatingWindow {
    private var panel: NSPanel?
    let viewModel = LiveActivityViewModel()
    private var hideTimer: Timer?
    private var userHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "pillHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "pillHidden") }
    }

    private(set) var isShown = false

    func toggle() {
        if panel == nil { createPanel() }
        if isShown {
            userHidden = true
            isShown = false
            hide()
        } else {
            userHidden = false
            isShown = true
            show()
        }
    }

    func update() {
        guard !userHidden else { return }
        let shouldShow = !viewModel.sessions.isEmpty
        let hasAnyActive = viewModel.sessions.contains { $0.status.isActive }

        if shouldShow {
            show()
            hideTimer?.invalidate()
            if !hasAnyActive {
                hideTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in  // 5 min
                    self?.hide()
                }
            }
        } else {
            hide()
        }
    }

    private func show() {
        if panel == nil { createPanel() }
        guard let panel = panel else { return }

        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { restorePosition() }
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard let panel = panel, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }
    }

    private func createPanel() {
        let view = LiveActivityView(model: viewModel)
        let hostingView = FirstMouseHostingView(rootView: view)

        let defaults = UserDefaults.standard
        let w = defaults.object(forKey: "pillWidth") != nil ? defaults.double(forKey: "pillWidth") : 340
        let h = defaults.object(forKey: "pillHeight") != nil ? defaults.double(forKey: "pillHeight") : hostingView.fittingSize.height

        let p = NonKeyPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: w, height: h)),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.title = ""
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = hostingView
        p.alphaValue = 0
        p.minSize = NSSize(width: 200, height: 150)
        p.maxSize = NSSize(width: 1200, height: 250)
        p.contentMinSize = NSSize(width: 200, height: 120)
        p.contentMaxSize = NSSize(width: 1200, height: 250)

        viewModel.window = p
        panel = p
        restorePosition()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification, object: p
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification, object: p
        )
    }

    private func restorePosition() {
        guard let panel = panel else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pillX") != nil {
            let x = defaults.double(forKey: "pillX")
            let y = defaults.double(forKey: "pillY")
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            // Default: top-right
            guard let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width + 4,
                y: visible.maxY - size.height + 4
            ))
        }
    }

    @objc private func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    private func saveFrame() {
        guard let panel = panel else { return }
        let defaults = UserDefaults.standard
        defaults.set(panel.frame.origin.x, forKey: "pillX")
        defaults.set(panel.frame.origin.y, forKey: "pillY")
        defaults.set(panel.frame.size.width, forKey: "pillWidth")
        defaults.set(panel.frame.size.height, forKey: "pillHeight")
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var dirSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var staleTimer: Timer?
    private var updateChecker: UpdateChecker?
    private let sessionManager = SessionManager()
    private let floatingWindow = FloatingWindow()

    private let sessionsDir = "\(NSHomeDirectory())/.claude/live-sessions"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenuBarIcon()
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self

        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

        floatingWindow.viewModel.onClose = { [weak self] in self?.togglePill() }
        sessionManager.onChange = { [weak self] in self?.updateAll() }

        watchSessionsDirectory()
        scanAllSessions()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.scanAllSessions()
        }

        staleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let removed = self.sessionManager.cleanupStale()
            if !removed.isEmpty { self.updateAll() }
        }

        let checker = UpdateChecker()
        updateChecker = checker
        checker.onUpdateAvailable = { [weak self] available in
            self?.floatingWindow.viewModel.updateAvailable = available
        }
        floatingWindow.viewModel.onUpdate = { [weak self] in
            self?.floatingWindow.viewModel.isUpdating = true
            self?.updateChecker?.performUpdate()
        }
        checker.start()
        floatingWindow.viewModel.isLocalDev = checker.isLocalDev
    }

    private func watchSessionsDirectory() {
        let fd = open(sessionsDir, O_EVTONLY)
        guard fd >= 0 else { return }
        dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        dirSource?.setEventHandler { [weak self] in self?.scanAllSessions() }
        dirSource?.setCancelHandler { close(fd) }
        dirSource?.resume()
    }

    private func scanAllSessions() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return }
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let status = try? JSONDecoder().decode(ClaudeStatus.self, from: data)
            else { continue }
            let sessionId = status.sessionId ?? String(file.dropLast(5))
            sessionManager.update(sessionId: sessionId, status: status)
        }
    }

    private func updateAll() {
        floatingWindow.viewModel.updateSessions(
            sessionManager.activeSessions,
            lastMessageFor: { [weak self] id in self?.sessionManager.lastMessage(for: id) },
            isThinkingFor: { [weak self] id in self?.sessionManager.isThinking(for: id) ?? false }
        )
        floatingWindow.update()
        writeWidgetData()
    }

    // MARK: - Menu Bar

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePill()
        }
    }

    @objc private func togglePill() {
        floatingWindow.toggle()
        updateMenuBarState()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        if floatingWindow.viewModel.isUpdating {
            let item = NSMenuItem(title: "Updating…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if floatingWindow.viewModel.updateAvailable {
            let item = NSMenuItem(title: "Update Available — Install Now", action: #selector(checkForUpdates), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Up to Date", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleStartAtLogin() {
        LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
    }

    @objc private func checkForUpdates() {
        floatingWindow.viewModel.isUpdating = true
        updateChecker?.performUpdate()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func updateMenuBarState() {
        statusItem.button?.appearsDisabled = !floatingWindow.isShown
    }

    private func setupMenuBarIcon() {
        let button = statusItem.button!
        if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = " ✦"
        }
    }

    private func writeWidgetData() {
        struct SessionData: Codable {
            let sessionId, status: String
            let tool, message, cwd: String?
            let timestamp: Double
            let events: [WidgetEvent]
        }
        struct WData: Codable { let sessions: [SessionData]; let timestamp: Double }

        let data = sessionManager.activeSessions.map { (id, st) in
            SessionData(sessionId: id, status: st.status, tool: st.tool, message: st.message,
                        cwd: st.cwd, timestamp: st.timestamp, events: [])
        }
        let wd = WData(sessions: data, timestamp: Date().timeIntervalSince1970)
        let path = "\(NSHomeDirectory())/.claude/live-widget.json"
        if let d = try? JSONEncoder().encode(wd), let s = String(data: d, encoding: .utf8) {
            try? s.write(toFile: path, atomically: true, encoding: .utf8)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudeStatus")
    }
}


// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
