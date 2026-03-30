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
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case status, tool, message, timestamp, cwd, tty
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case lastMessage = "last_message"
    }

    static var idle: ClaudeStatus {
        ClaudeStatus(status: "idle", tool: nil, message: nil, sessionId: nil,
                     transcriptPath: nil, lastMessage: nil, cwd: nil, tty: nil,
                     timestamp: Date().timeIntervalSince1970)
    }

    var isStale: Bool { Date().timeIntervalSince1970 - timestamp > 600 }  // 10 minutes
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
    private var fileOffset: UInt64 = 0
    private var fileSource: DispatchSourceFileSystemObject?
    private(set) var events: [WidgetEvent] = []
    private let maxEvents = 20
    let sessionId: String
    var onChange: (() -> Void)?

    init(sessionId: String) { self.sessionId = sessionId }

    func setTranscript(path: String?) {
        guard let path = path, !path.isEmpty, path != currentPath else {
            if currentPath != nil { readNewLines() }
            return
        }
        currentPath = path
        events.removeAll()
        fileSource?.cancel()
        fileSource = nil
        if let handle = FileHandle(forReadingAtPath: path) {
            let fileSize = handle.seekToEndOfFile()
            let startFrom = fileSize > 5000 ? fileSize - 5000 : 0
            handle.seek(toFileOffset: startFrom)
            let data = handle.readDataToEndOfFile()
            fileOffset = handle.offsetInFile
            handle.closeFile()
            if let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: "\n")
                let startIdx = startFrom > 0 ? 1 : 0
                for i in startIdx..<lines.count { parseLine(lines[i]) }
            }
        }
        watchTranscript()
    }

    private func watchTranscript() {
        guard let path = currentPath else { return }
        fileSource?.cancel()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        fileSource?.setEventHandler { [weak self] in self?.readNewLines() }
        fileSource?.setCancelHandler { close(fd) }
        fileSource?.resume()
    }

    func readNewLines() {
        guard let path = currentPath,
              let handle = FileHandle(forReadingAtPath: path) else { return }
        handle.seek(toFileOffset: fileOffset)
        let data = handle.readDataToEndOfFile()
        let newOffset = handle.offsetInFile
        handle.closeFile()
        guard newOffset > fileOffset else { return }
        fileOffset = newOffset
        guard let text = String(data: data, encoding: .utf8) else { return }
        var didAdd = false
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            if parseLine(line) { didAdd = true }
        }
        if didAdd { onChange?() }
    }

    @discardableResult
    private func parseLine(_ line: String) -> Bool {
        guard !line.isEmpty,
              let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]]
        else { return false }
        var added = false
        for item in content {
            guard let itemType = item["type"] as? String else { continue }
            if itemType == "text", let text = item["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                events.append(WidgetEvent(type: "text", text: String(trimmed.prefix(200)),
                                          timestamp: Date().timeIntervalSince1970, sessionId: sessionId))
                added = true
            } else if itemType == "tool_use", let name = item["name"] as? String {
                events.append(WidgetEvent(type: "tool", text: name,
                                          timestamp: Date().timeIntervalSince1970, sessionId: sessionId))
                added = true
            }
        }
        while events.count > maxEvents { events.removeFirst() }
        return added
    }

    func stop() { fileSource?.cancel(); fileSource = nil }
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

    func events(for sessionId: String) -> [WidgetEvent] { tailers[sessionId]?.events ?? [] }
    func lastMessage(for sessionId: String) -> String? {
        tailers[sessionId]?.events.last(where: { $0.type == "text" })?.text
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

// MARK: - View Model

struct SessionInfo: Identifiable {
    let id: String
    var status: ClaudeStatus
    var lastMessage: String?
}

class LiveActivityViewModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var selectedId: String?
    weak var window: NSPanel?
    var onClose: (() -> Void)?

    var selected: SessionInfo? { sessions.first { $0.id == selectedId } }

    func updateSessions(_ active: [(String, ClaudeStatus)], lastMessageFor: (String) -> String?) {
        // Update existing, add new
        var newSessions: [SessionInfo] = []
        for (id, status) in active {
            newSessions.append(SessionInfo(id: id, status: status, lastMessage: lastMessageFor(id)))
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
            runOsascript("tell application \"Terminal\" to activate")
            return
        }

        let ttyPath = session.status.tty ?? ""
        guard !ttyPath.isEmpty else {
            runOsascript("tell application \"Terminal\" to activate")
            return
        }

        let safeTty = ttyPath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
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
        """
        runOsascript(script)
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
                    let isWorking = s.status.status == "tool_use" || s.status.status == "thinking"
                    HStack(spacing: 8) {
                        Circle()
                            .fill(s.status.statusColor)
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

                        Text(s.status.displayText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(s.status.isActive ? .white : .white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Text(s.lastMessage ?? " ")
                        .font(.system(size: 11.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(s.lastMessage != nil ? 0.4 : 0))
                        .lineLimit(2)
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
            .frame(width: 340, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                flash()
                model.focusTerminal()
            }

            // Bottom tabs — always visible
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
        .frame(width: 340)
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

// MARK: - Custom Hosting View (accepts first mouse for immediate click response)

class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

        // Resize to fit content
        if let hostingView = panel.contentView as? FirstMouseHostingView<LiveActivityView> {
            let size = hostingView.fittingSize
            let oldFrame = panel.frame
            let newFrame = NSRect(
                x: oldFrame.origin.x + (oldFrame.width - size.width),
                y: oldFrame.origin.y + (oldFrame.height - size.height),
                width: size.width,
                height: size.height
            )
            panel.setFrame(newFrame, display: true, animate: panel.isVisible)
        }

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
        let size = hostingView.fittingSize

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = hostingView
        p.alphaValue = 0

        viewModel.window = p
        panel = p
        restorePosition()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification, object: p
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
        guard let panel = panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: "pillX")
        UserDefaults.standard.set(panel.frame.origin.y, forKey: "pillY")
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var dirSource: DispatchSourceFileSystemObject?
    private var staleTimer: Timer?
    private let sessionManager = SessionManager()
    private let floatingWindow = FloatingWindow()

    private let sessionsDir = "\(NSHomeDirectory())/.claude/live-sessions"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenuBarIcon()
        statusItem.button?.action = #selector(togglePill)
        statusItem.button?.target = self

        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

        floatingWindow.viewModel.onClose = { [weak self] in self?.togglePill() }
        sessionManager.onChange = { [weak self] in self?.updateAll() }

        watchSessionsDirectory()
        scanAllSessions()

        staleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let removed = self.sessionManager.cleanupStale()
            if !removed.isEmpty { self.updateAll() }
        }
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
        // Update floating window view model
        floatingWindow.viewModel.updateSessions(
            sessionManager.activeSessions,
            lastMessageFor: { [weak self] id in self?.sessionManager.lastMessage(for: id) }
        )
        floatingWindow.update()
        writeWidgetData()
    }

    // MARK: - Menu Bar

    @objc private func togglePill() {
        floatingWindow.toggle()
        updateMenuBarState()
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
                        cwd: st.cwd, timestamp: st.timestamp, events: sessionManager.events(for: id))
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
