import WidgetKit
import SwiftUI

// MARK: - Models

struct WidgetEvent: Codable, Hashable {
    let type: String     // "text" or "tool"
    let text: String
    let timestamp: Double

    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(text)
        hasher.combine(timestamp)
    }
}

struct WidgetData: Codable {
    let status: String
    let tool: String?
    let message: String?
    let timestamp: Double
    let events: [WidgetEvent]

    static var empty: WidgetData {
        WidgetData(status: "idle", tool: nil, message: nil,
                   timestamp: Date().timeIntervalSince1970, events: [])
    }

    var isStale: Bool { Date().timeIntervalSince1970 - timestamp > 60 }
    var isActive: Bool { (status == "tool_use" || status == "waiting") && !isStale }

    var statusLabel: String {
        switch status {
        case "tool_use": return "Working"
        case "waiting": return "Waiting"
        case "completed": return "Done"
        default: return "Idle"
        }
    }

    var statusColor: Color {
        switch status {
        case "tool_use": return .blue
        case "waiting": return .orange
        case "completed": return .green
        default: return .secondary
        }
    }
}

// MARK: - Timeline

struct StatusEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), data: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), data: readData()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let current = readData()

        if current.isActive {
            var entries: [StatusEntry] = []
            for i in 0..<6 {
                entries.append(StatusEntry(
                    date: Date().addingTimeInterval(Double(i) * 5),
                    data: current
                ))
            }
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(30))))
        } else {
            completion(Timeline(
                entries: [StatusEntry(date: Date(), data: current)],
                policy: .after(Date().addingTimeInterval(30))
            ))
        }
    }

    private func readData() -> WidgetData {
        let path = "\(NSHomeDirectory())/.claude/live-widget.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let widget = try? JSONDecoder().decode(WidgetData.self, from: data)
        else { return .empty }
        return widget.isStale && !widget.isActive ? .empty : widget
    }
}

// MARK: - Views

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: StatusEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumView(data: entry.data)
        case .systemLarge:
            LargeView(data: entry.data)
        default:
            SmallView(data: entry.data)
        }
    }
}

// Small: latest message + status
struct SmallView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(data.statusColor)
                Text("Claude")
                    .font(.headline)
                Spacer()
                Text(data.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(data.statusColor)
            }

            Spacer(minLength: 2)

            // Latest message
            if let lastText = data.events.last(where: { $0.type == "text" }) {
                Text(lastText.text)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }

            // Current tool
            if let msg = data.message, data.status == "tool_use" {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(msg)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

// Medium: message feed + current status
struct MediumView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(data.statusColor)
                Text("Claude Code")
                    .font(.headline)
                Spacer()
                if data.isActive {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(data.statusColor)
                            .frame(width: 6, height: 6)
                        Text(data.statusLabel)
                            .font(.caption)
                            .foregroundStyle(data.statusColor)
                    }
                }
            }

            Divider()

            // Event feed (last 4)
            let recent = Array(data.events.suffix(4))
            if recent.isEmpty {
                Text("No recent activity")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recent, id: \.self) { event in
                        EventRow(event: event)
                    }
                }
            }

            Spacer(minLength: 0)

            // Current tool at bottom
            if let msg = data.message, data.status == "tool_use" {
                HStack(spacing: 3) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(msg)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

// Large: full message feed
struct LargeView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(data.statusColor)
                Text("Claude Code")
                    .font(.headline)
                Spacer()
                if data.isActive {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(data.statusColor)
                            .frame(width: 6, height: 6)
                        Text(data.statusLabel)
                            .font(.caption)
                            .foregroundStyle(data.statusColor)
                    }
                }
            }

            Divider()

            // Event feed (last 10)
            let recent = Array(data.events.suffix(10))
            if recent.isEmpty {
                Spacer()
                Text("No recent activity")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(recent, id: \.self) { event in
                        EventRow(event: event)
                    }
                }
            }

            Spacer(minLength: 0)

            // Current tool at bottom
            if let msg = data.message, data.status == "tool_use" {
                Divider()
                HStack(spacing: 3) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(msg)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

// Single event row
struct EventRow: View {
    let event: WidgetEvent

    var body: some View {
        if event.type == "text" {
            Text(event.text)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
        } else {
            HStack(spacing: 3) {
                Image(systemName: toolIcon(event.text))
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text(toolLabel(event.text))
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toolIcon(_ tool: String) -> String {
        switch tool {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "Agent": return "brain"
        case "WebSearch": return "globe"
        default: return "bolt"
        }
    }

    private func toolLabel(_ tool: String) -> String {
        switch tool {
        case "Read": return "Read file"
        case "Edit": return "Edit file"
        case "Write": return "Write file"
        case "Bash": return "Run command"
        case "Grep": return "Search code"
        case "Glob": return "Find files"
        case "Agent": return "Sub-agent"
        case "WebSearch": return "Web search"
        default: return tool
        }
    }
}

// MARK: - Widget

@main
struct ClaudeStatusWidget: Widget {
    let kind = "ClaudeStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            if #available(macOS 14.0, *) {
                WidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                WidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("Claude Status")
        .description("Live feed of Claude Code activity and messages")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
