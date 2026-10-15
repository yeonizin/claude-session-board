// Claude Sessions for macOS. Run with: swift session-board.swift
import Foundation
#if canImport(AppKit)
import AppKit
import SwiftUI
#elseif canImport(Glibc)
import Glibc
#endif

let root: URL = {
    if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { return URL(fileURLWithPath: dir) }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
}()

struct Row: Identifiable {
    let id: String
    let cwd: String?
    let title: String
    let starred: Bool
    let status: String?
    let tokens: Int
    let elapsed: TimeInterval
    let ctxPct: Double
    let last: Date
}

final class Transcript {
    var offset: UInt64 = 0
    var cwd: String?
    var title: String?
    var prompt: String?
    var first: Date?
    var last: Date?
    var usage: [String: Int] = [:]
    var ctx = 0
    var maxCtx = 0
}

final class Board {
    private var cache: [String: Transcript] = [:]
    private let starFile = root.appendingPathComponent("session-board.json")
    private(set) var starred: Set<String> = []
    private(set) var hidden: Set<String> = []
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    init() {
        if let data = try? Data(contentsOf: starFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            starred = Set(obj["starred"] as? [String] ?? [])
            hidden = Set(obj["hidden"] as? [String] ?? [])
        }
    }

    func toggleStar(_ id: String) {
        if starred.remove(id) == nil { starred.insert(id) }
        save()
    }

    func toggleHidden(_ id: String) {
        if hidden.remove(id) == nil { hidden.insert(id); starred.remove(id) }
        save()
    }

    private func save() {
        if let data = try? JSONSerialization.data(withJSONObject: ["starred": Array(starred), "hidden": Array(hidden)]) {
            try? data.write(to: starFile)
        }
    }

    // Transcripts are append-only and can reach several MB, so only the bytes added since the last poll are parsed.
    private func update(_ url: URL, size: UInt64) -> Transcript {
        var t = cache[url.path] ?? Transcript()
        if size < t.offset { t = Transcript() }
        cache[url.path] = t
        guard size > t.offset, let h = try? FileHandle(forReadingFrom: url) else { return t }
        defer { try? h.close() }
        try? h.seek(toOffset: t.offset)
        let data = h.readData(ofLength: Int(size - t.offset))
        guard let end = data.lastIndex(of: 10) else { return t }
        t.offset += UInt64(end - data.startIndex + 1)
        for line in data[data.startIndex...end].split(separator: 10) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { apply(obj, to: t) }
        }
        return t
    }

    private func apply(_ obj: [String: Any], to t: Transcript) {
        if let ts = obj["timestamp"] as? String, let d = isoFrac.date(from: ts) ?? iso.date(from: ts) {
            if t.first == nil { t.first = d }
            t.last = d
        }
        if t.cwd == nil, let c = obj["cwd"] as? String { t.cwd = c }
        let msg = obj["message"] as? [String: Any]
        switch obj["type"] as? String {
        case "ai-title":
            if let s = obj["aiTitle"] as? String { t.title = s }
        case "user":
            guard t.prompt == nil, let content = msg?["content"] else { break }
            let text = (content as? String)
                ?? ((content as? [[String: Any]])?.first.flatMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil })
            if let text = text, !text.hasPrefix("<") { t.prompt = text }
        case "assistant":
            // One response is written as one line per content block, each repeating the same usage.
            guard let id = msg?["id"] as? String, let u = msg?["usage"] as? [String: Any] else { break }
            func n(_ k: String) -> Int { (u[k] as? Int) ?? 0 }
            t.usage[id] = n("input_tokens") + n("cache_creation_input_tokens") + n("output_tokens")
            t.ctx = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            t.maxCtx = max(t.maxCtx, t.ctx)
        default:
            break
        }
    }

    private func liveSessions() -> [String: String] {
        var live: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = o["pid"] as? Int, let id = o["sessionId"] as? String,
                  kill(pid_t(pid), 0) == 0 || errno == EPERM else { continue }
            live[id] = (o["status"] as? String) ?? "idle"
        }
        return live
    }

    func rows(day: Date, showHidden: Bool = false) -> [Row] {
        let fm = FileManager.default
        let from = Calendar.current.startOfDay(for: day)
        let to = Calendar.current.date(byAdding: .day, value: 1, to: from)!
        let live = liveSessions()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var rows: [Row] = []
        let dirs = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("projects"), includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            where f.pathExtension == "jsonl" && hidden.contains(f.deletingPathExtension().lastPathComponent) == showHidden {
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let mod = v.contentModificationDate, mod >= from, let size = v.fileSize else { continue }
                let t = update(f, size: UInt64(size))
                guard let first = t.first, let last = t.last, first < to, last >= from else { continue }
                let id = f.deletingPathExtension().lastPathComponent
                let status = live[id]
                // Transcripts don't record the context window size; anything that ever exceeded 200k is assumed 1M.
                let window = t.maxCtx > 200_000 ? 1_000_000.0 : 200_000.0
                let title = t.title ?? t.prompt ?? dir.lastPathComponent
                rows.append(Row(
                    id: id, cwd: t.cwd,
                    title: title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "),
                    starred: starred.contains(id), status: status,
                    tokens: t.usage.values.reduce(0, +),
                    elapsed: (status == "busy" ? Date() : last).timeIntervalSince(first),
                    ctxPct: min(100, 100 * Double(t.ctx) / window), last: last))
            }
        }
        return rows.sorted { $0.starred != $1.starred ? $0.starred : $0.last > $1.last }
    }
}

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
    if n >= 1_000 { return "\(n / 1_000)k" }
    return "\(n)"
}

func formatSpan(_ s: TimeInterval) -> String {
    let m = Int(s / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

#if canImport(AppKit)
let korean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
let L = korean
    ? (today: "오늘", empty: "이 날짜의 세션이 없습니다", pin: "중요 표시", hide: "목록에서 지우기", restore: "목록에 되돌리기",
       showHidden: "지운 세션 보기", noHidden: "이 날짜에 지운 세션이 없습니다", day: "M월 d일 (E)", locale: "ko_KR")
    : (today: "Today", empty: "No sessions on this day", pin: "Pin to top", hide: "Remove from list", restore: "Restore to list",
       showHidden: "Show removed sessions", noHidden: "No removed sessions on this day", day: "MMM d (E)", locale: "en_US")

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let fg = Color(hex: 0xDFE1E5)
    static let sub = Color(hex: 0xA8ADBD)
    static let meta = Color(hex: 0x868A91)
    static let dim = Color(hex: 0x6F737A)
    static let accent = Color(hex: 0x3574F0)
    static let gold = Color(hex: 0xF2C55C)
}

final class Model: ObservableObject {
    let board = Board()
    var onResize: (() -> Void)?
    @Published var rows: [Row] = []
    @Published var day = Calendar.current.startOfDay(for: Date()) {
        didSet {
            let d = Calendar.current.startOfDay(for: day)
            if d != day { day = d }
            refresh()
        }
    }
    @Published var showHidden = false {
        didSet { refresh() }
    }

    func refresh() {
        rows = board.rows(day: day, showHidden: showHidden)
        DispatchQueue.main.async { self.onResize?() }
    }

    func toggle(_ id: String) {
        board.toggleStar(id)
        refresh()
    }

    func toggleHidden(_ id: String) {
        board.toggleHidden(id)
        refresh()
    }

    func open(_ row: Row) {
        guard UUID(uuidString: row.id) != nil,
              let url = URL(string: "vscode://anthropic.claude-code/open?session=\(row.id)") else { return }
        var isDir: ObjCBool = false
        guard let cwd = row.cwd, cwd.hasPrefix("/"),
              FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            NSWorkspace.shared.open(url)
            return
        }
        // The extension's URI is handled by whichever VS Code window was focused last, so the session's folder is focused first.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", "com.microsoft.VSCode", cwd]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSWorkspace.shared.open(url) }
    }
}

struct FlatButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration) }

    struct Body: View {
        let configuration: ButtonStyle.Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Color(hex: 0x43454A) : .clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

struct RowView: View {
    let row: Row
    let model: Model
    @State private var hover = false

    @ViewBuilder var icon: some View {
        switch row.status {
        case "busy": Image(systemName: "circle.fill").font(.system(size: 8)).foregroundColor(.accent)
        case "idle": Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: 0x5FB865))
        case "waiting": Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.gold)
        default: Image(systemName: "circle").font(.system(size: 9)).foregroundColor(.dim)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            icon.frame(width: 20, alignment: .leading).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13)).foregroundColor(.fg).lineLimit(1).truncationMode(.tail).help(row.title)
                HStack {
                    Text("\(formatTokens(row.tokens)) tok · \(formatSpan(row.elapsed))")
                    Spacer()
                    Text("\(Int(row.ctxPct))%")
                }
                .font(.system(size: 11)).foregroundColor(.meta)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(hex: 0x393B40))
                        Rectangle().fill(Color.accent).frame(width: g.size.width * row.ctxPct / 100)
                    }
                }
                .frame(height: 2).padding(.top, 3)
            }
            Button { model.toggle(row.id) } label: {
                Image(systemName: row.starred ? "star.fill" : "star").font(.system(size: 11)).foregroundColor(row.starred ? .gold : .dim)
            }
            .buttonStyle(FlatButton()).help(L.pin).padding(.leading, 6)
            Button { model.toggleHidden(row.id) } label: {
                Image(systemName: model.showHidden ? "arrow.uturn.backward" : "xmark").font(.system(size: 10)).foregroundColor(.dim)
            }
            .buttonStyle(FlatButton()).help(model.showHidden ? L.restore : L.hide).padding(.leading, 2)
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 8, trailing: 8))
        .frame(height: 54)
        .background(hover ? Color(hex: 0x35373B) : .clear)
        .opacity(row.status == nil ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.open(row) }
    }
}

struct BoardView: View {
    @ObservedObject var model: Model
    @State private var showCal = false

    var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.locale)
        f.dateFormat = L.day
        let s = f.string(from: model.day)
        return Calendar.current.isDateInToday(model.day) ? "\(L.today) · \(s)" : s
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Claude Sessions").fontWeight(.semibold).foregroundColor(.fg)
                Text("\(model.rows.count)").font(.system(size: 11)).foregroundColor(.sub)
                    .padding(.horizontal, 6).background(Capsule().fill(Color(hex: 0x393B40)))
                Spacer()
                Button { model.showHidden.toggle() } label: {
                    Image(systemName: "eye").foregroundColor(model.showHidden ? Color(hex: 0x548AF7) : .sub)
                }
                .buttonStyle(FlatButton()).help(L.showHidden)
                Button { showCal.toggle() } label: {
                    HStack(spacing: 6) { Image(systemName: "calendar"); Text(dateLabel) }.foregroundColor(.sub)
                }
                .buttonStyle(FlatButton())
                .popover(isPresented: $showCal, arrowEdge: .top) {
                    VStack(alignment: .trailing, spacing: 4) {
                        DatePicker("", selection: $model.day, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden()
                            .environment(\.locale, Locale(identifier: L.locale))
                        Button(L.today) { model.day = Date() }.buttonStyle(FlatButton()).foregroundColor(Color(hex: 0x548AF7))
                    }
                    .padding(10)
                }
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(.sub)
                }
                .buttonStyle(FlatButton())
            }
            .font(.system(size: 12))
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            Rectangle().fill(Color(hex: 0x1E1F22)).frame(height: 1)
            if model.rows.isEmpty {
                Text(model.showHidden ? L.noHidden : L.empty).font(.system(size: 12)).foregroundColor(.dim).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) { ForEach(model.rows) { RowView(row: $0, model: model) } }
                }
                .frame(height: min(CGFloat(model.rows.count) * 54, 460))
                .padding(.vertical, 4)
            }
        }
        .frame(width: 360)
        .background(Color(hex: 0x2B2D30))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x43454A)))
        .onChange(of: model.day) { _ in showCal = false }
    }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = Model()
let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .floating
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.appearance = NSAppearance(named: .darkAqua)
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let host = NSHostingView(rootView: BoardView(model: model))
panel.contentView = host

// The panel hugs its content, so it is re-anchored to the bottom-right whenever the list grows or shrinks.
model.onResize = {
    let size = host.fittingSize
    guard let area = NSScreen.main?.visibleFrame else { return }
    panel.setFrame(NSRect(x: area.maxX - size.width - 8, y: area.minY + 8, width: size.width, height: size.height), display: true)
}
model.refresh()
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in model.refresh() }
panel.orderFrontRegardless()
app.run()
#else
// Without AppKit (e.g. Linux CI) this prints today's rows, which exercises everything except the UI.
for r in Board().rows(day: Date()) {
    print(r.status ?? "-", "|", r.title, "|", formatTokens(r.tokens), "tok ·", formatSpan(r.elapsed), "|", "\(Int(r.ctxPct))%", "|", r.starred ? "pinned" : "")
}
#endif
