import AppKit
import SwiftUI
import Combine

enum Session: String, CaseIterable {
    case focus = "专注", short = "短休息", long = "长休息"
    var hint: String { self == .focus ? "留一点时间，给眼前这一件事。" : "放松一下，让思绪慢慢回来。" }
}

enum PanelOpacity {
    static let minimum = 0.35
    static let maximum = 1.0
    static let fallback = 0.70
    static func clamp(_ value: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

final class ClockModel: ObservableObject {
    @Published var mode: Session = .focus
    @Published var remaining: TimeInterval = 1500
    @Published var running = false
    @Published var completed = false
    @Published var task = "" { didSet { save() } }
    @Published var durations = [25, 5, 15]
    @Published var sound = true
    @Published var pinned = true
    @Published var opacity = PanelOpacity.fallback { didSet { save() } }
    @Published var today = 0
    private var day = ""
    private var deadline: Date?
    private var total: TimeInterval = 1500
    private(set) var customSeconds: Int?
    var configuredSeconds: Int { customSeconds ?? durations[index] * 60 }
    private var timer: AnyCancellable?
    var onTick: (() -> Void)?
    private let defaults: UserDefaults
    var index: Int { Session.allCases.firstIndex(of: mode)! }
    var label: String {
        let seconds = max(0, Int(ceil(remaining)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var progress: Double { min(1, max(0, 1 - remaining / max(1, total))) }
    static func dateKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.dictionary(forKey: "clock") {
            mode = Session(rawValue: data["mode"] as? String ?? "") ?? .focus
            if let values = data["durations"] as? [Int], values.count == 3, values.allSatisfy({ (1...120).contains($0) }) { durations = values }
            task = data["task"] as? String ?? ""
            sound = data["sound"] as? Bool ?? true
            day = data["day"] as? String ?? ""
            today = data["today"] as? Int ?? 0
            if let value = data["customSeconds"] as? Int, (1...59999).contains(value) { customSeconds = value }
            total = data["total"] as? Double ?? Double(durations[index] * 60)
            remaining = data["remaining"] as? Double ?? total
            completed = data["completed"] as? Bool ?? false
            if let end = data["deadline"] as? Double { deadline = Date(timeIntervalSince1970: end); running = true }
            if let value = data["opacity"] as? Double { opacity = PanelOpacity.clamp(value) }
        }
        refreshDay()
        tick()
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
    }
    func refreshDay() {
        let current = Self.dateKey()
        if day != current { day = current; today = 0 }
    }
    func tick() {
        refreshDay()
        if running, let end = deadline {
            remaining = max(0, end.timeIntervalSinceNow)
            if remaining <= 0 {
                running = false; deadline = nil; completed = true
                if mode == .focus { today += 1 }
                if sound { NSSound(named: "Glass")?.play() }
                NSApp.requestUserAttention(.informationalRequest)
                save()
            }
        }
        onTick?()
    }
    func toggle() {
        if running { tick(); if completed { return }; running = false; deadline = nil }
        else {
            if completed { reset() }
            running = true; deadline = Date().addingTimeInterval(remaining)
        }
        save(); onTick?()
    }
    func reset() {
        running = false; deadline = nil; completed = false
        total = Double(configuredSeconds); remaining = total; save(); onTick?()
    }
    func select(_ next: Session) { guard next != mode else { return }; mode = next; customSeconds = nil; reset() }
    func next() { mode = mode == .focus ? (today % 4 == 0 ? .long : .short) : .focus; customSeconds = nil; reset() }
    static func parseDuration(minutes: String, seconds: String) -> Int? {
        let m = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = seconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !s.isEmpty,
              m.allSatisfy({ $0.isASCII && $0.isNumber }), s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let minutes = Int(m), let seconds = Int(s),
              (0...999).contains(minutes), (0...59).contains(seconds), minutes * 60 + seconds > 0 else { return nil }
        return minutes * 60 + seconds
    }
    func startCustom(seconds: Int) {
        guard (1...59999).contains(seconds) else { return }
        customSeconds = seconds
        reset()
        toggle()
    }
    func save() {
        var data: [String: Any] = ["mode": mode.rawValue, "remaining": remaining, "total": total, "completed": completed, "task": task, "durations": durations, "sound": sound, "opacity": opacity, "day": day, "today": today]
        if let seconds = customSeconds { data["customSeconds"] = seconds }
        if let end = deadline { data["deadline"] = end.timeIntervalSince1970 }
        defaults.set(data, forKey: "clock")
    }
}

struct TimerView: View {
    @ObservedObject var clock: ClockModel
    @State private var settings = false
    @State private var editingDuration = false
    @State private var minutesInput = "25"
    @State private var secondsInput = "00"
    @State private var confirmReset = false
    @State private var pendingMode: Session?
    private let ink = Color(red: 0.24, green: 0.29, blue: 0.26)
    private let muted = Color(red: 0.48, green: 0.51, blue: 0.47)
    private let accent = Color(red: 0.43, green: 0.52, blue: 0.42)
    var body: some View {
        Group {
            if clock.pinned { compactView } else { fullView }
        }
        .background { Color(red: 0.97, green: 0.965, blue: 0.945).opacity(clock.opacity).ignoresSafeArea() }
        .preferredColorScheme(.light)
        .alert("结束当前这一段计时？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) { pendingMode = nil }
            Button("重新开始", role: .destructive) { if let next = pendingMode { clock.select(next) } else { clock.reset() }; pendingMode = nil }
        } message: { Text("未完成的专注不会计入今日次数。") }
    }
    func timeButton(size: CGFloat) -> some View {
        Button {
            minutesInput = String(clock.configuredSeconds / 60)
            secondsInput = String(format: "%02d", clock.configuredSeconds % 60)
            editingDuration = true
        } label: {
            VStack(spacing: 2) {
                Text(clock.label).font(.system(size: size, weight: .light, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1).foregroundStyle(ink)
                Label("设置时长", systemImage: "pencil").font(.system(size: 9)).foregroundStyle(muted)
            }
        }.buttonStyle(.plain).help("输入时长并开始倒计时")
            .accessibilityLabel("设置倒计时时长，剩余 " + clock.label)
            .popover(isPresented: $editingDuration) { durationEditor }
    }
    var durationEditor: some View {
        let parsed = ClockModel.parseDuration(minutes: minutesInput, seconds: secondsInput)
        let replacing = !clock.completed && (clock.running || clock.progress > 0)
        return VStack(alignment: .leading, spacing: 16) {
            Text("这次，需要多久？").font(.system(size: 14, weight: .medium))
            HStack(spacing: 10) {
                TextField("分钟", text: $minutesInput).accessibilityLabel("分钟")
                    .frame(width: 74)
                Text("分")
                TextField("秒", text: $secondsInput).accessibilityLabel("秒")
                    .frame(width: 54)
                Text("秒")
            }.textFieldStyle(.roundedBorder).font(.system(size: 20, design: .rounded))
            Text(parsed == nil ? "请输入 0–999 分、0–59 秒，总时长至少 1 秒。" : replacing ? "开始后将替换当前计时；取消则继续原计时。" : "输入时长，按自己的节奏开始。")
                .font(.system(size: 11)).foregroundStyle(parsed == nil ? Color.red : muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { editingDuration = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(replacing ? "替换并开始" : "开始倒计时") {
                    guard let seconds = parsed else { return }
                    clock.startCustom(seconds: seconds)
                    editingDuration = false
                }.buttonStyle(.borderedProminent).tint(ink).disabled(parsed == nil)
            }
        }.padding(20).frame(width: 290).foregroundStyle(ink)
    }
    var compactView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text(clock.mode.rawValue + (clock.completed ? " · 已完成" : clock.running ? "" : " · 已暂停"))
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                    .help("设置").popover(isPresented: $settings) { settingsView }
                Button { clock.pinned = false } label: { Image(systemName: "pin.fill").frame(width: 24, height: 24) }
                    .help("取消置顶，展开完整窗口")
            }.foregroundStyle(muted)
            timeButton(size: 48)
            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.15))
                        Capsule().fill(accent).frame(width: geo.size.width * clock.progress)
                    }
                }.frame(height: 3)
                Button { if clock.completed { clock.next() } else { clock.toggle() } } label: {
                    Image(systemName: clock.completed ? "arrow.right" : clock.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .medium)).frame(width: 30, height: 28)
                        .background(ink, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
                }.help(clock.completed ? "进入下一段" : clock.running ? "暂停" : "开始或继续")
                Button {
                    if clock.running || (clock.progress > 0 && !clock.completed) { pendingMode = nil; confirmReset = true } else { clock.reset() }
                } label: { Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 28) }
                    .foregroundStyle(muted).help("重新计时")
            }
        }.buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16).frame(width: 224)
    }
    var fullView: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) { Circle().fill(accent).frame(width: 7, height: 7); Text("静时").font(.system(size: 14, weight: .medium)) }
                Spacer()
                Button { clock.pinned.toggle() } label: { Image(systemName: clock.pinned ? "pin.fill" : "pin") }
                    .help(clock.pinned ? "取消窗口置顶" : "窗口置顶")
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }.help("设置")
                    .popover(isPresented: $settings) { settingsView }
            }.buttonStyle(.plain).foregroundStyle(muted).padding(.bottom, 32)
            HStack(spacing: 4) {
                ForEach(Session.allCases, id: \.self) { mode in
                    Button {
                        if clock.mode != mode && (clock.running || clock.progress > 0) && !clock.completed { pendingMode = mode; confirmReset = true }
                        else { clock.select(mode) }
                    } label: {
                        Text(mode.rawValue).font(.system(size: 12, weight: clock.mode == mode ? .medium : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(clock.mode == mode ? Color.white.opacity(0.9) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).foregroundStyle(clock.mode == mode ? ink : muted)
                }
            }.padding(4).background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            ZStack {
                Circle().stroke(accent.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: clock.progress).stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 9) {
                    Text(clock.completed ? "已完成" : clock.running ? "正在\(clock.mode.rawValue)" : clock.progress > 0 ? "已暂停" : "准备好就开始")
                        .font(.system(size: 11)).tracking(2).foregroundStyle(muted)
                    timeButton(size: 57)
                    Text(clock.mode == .focus ? "一次，只做一件事" : "呼吸 · 伸展 · 喝点水").font(.system(size: 11)).foregroundStyle(muted)
                }
            }.frame(width: 232, height: 232).padding(.top, 27).padding(.bottom, 24)
            TextField("这一刻，想专注什么？", text: $clock.task)
                .textFieldStyle(.plain).font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(ink)
                .padding(.horizontal, 8).padding(.bottom, 23)
            HStack(spacing: 12) {
                Button {
                    if clock.completed { clock.next() } else { clock.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: clock.completed ? "arrow.right" : clock.running ? "pause.fill" : "play.fill").font(.system(size: 10))
                        Text(clock.completed ? (clock.mode == .focus ? "去休息" : "回到专注") : clock.running ? "暂停" : clock.progress > 0 ? "继续" : "开始专注".replacingOccurrences(of: "专注", with: clock.mode == .focus ? "专注" : "休息"))
                    }.font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 43)
                        .background(ink, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: [])
                Button {
                    if clock.running || (clock.progress > 0 && !clock.completed) { pendingMode = nil; confirmReset = true } else { clock.reset() }
                } label: { Image(systemName: "arrow.counterclockwise").frame(width: 43, height: 43).background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)) }
                    .buttonStyle(.plain).help("重新计时").foregroundStyle(muted)
            }
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in Circle().fill(i < (clock.today == 0 ? 0 : (clock.today - 1) % 4 + 1) ? accent : accent.opacity(0.18)).frame(width: 5, height: 5) }
                Text("今天已完成 \(clock.today) 次专注").font(.system(size: 10)).padding(.leading, 4)
            }.foregroundStyle(muted).padding(.top, 25)
            Text(clock.completed ? "做得很好。下一段时间，由你决定。" : clock.mode.hint).font(.system(size: 10)).foregroundStyle(muted.opacity(0.8)).padding(.top, 12)
        }.padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 24)
            .frame(width: 360)
            .background {
                Color(red: 0.97, green: 0.965, blue: 0.945).opacity(clock.opacity).ignoresSafeArea()
            }
            .preferredColorScheme(.light)

    }
    var settingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("按自己的节奏来").font(.system(size: 14, weight: .medium))
            ForEach(Array(Session.allCases.enumerated()), id: \.offset) { index, mode in
                Stepper(value: $clock.durations[index], in: 1...120) { Text("\(mode.rawValue)　\(clock.durations[index]) 分钟").font(.system(size: 12)) }
            }
            Toggle("结束时播放轻提示音", isOn: $clock.sound).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("窗口不透明度").font(.system(size: 12))
                    Spacer()
                    Text("\(Int((clock.opacity * 100).rounded()))%").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Slider(value: $clock.opacity, in: PanelOpacity.minimum...PanelOpacity.maximum)
            }
            Text("时长调整从下一段计时生效。\n调低不透明度后可以看到后面的页面，数字和按钮保持清晰。\n关闭窗口后，仍会在菜单栏计时。\n电脑睡眠时无法响铃，唤醒后会更新。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(22).frame(width: 280)
            .onDisappear { clock.save(); if !clock.running && clock.progress == 0 { clock.reset() } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let clock = ClockModel()
    var window: NSWindow!
    var status: NSStatusItem!
    var pinObserver: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = TimerView(clock: clock)
        let host = ClearHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 590), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarSeparatorStyle = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        window = panel
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "静时"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.contentView = host
        window.setContentSize(host.fittingSize); window.center(); window.setFrameAutosaveName("QuietTimerWindow")
        panel.isMovableByWindowBackground = true
        applyPresentation()
        pinObserver = clock.$pinned.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyPresentation() }
        }
        window.makeKeyAndOrderFront(nil)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "打开静时", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "开始 / 暂停", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出静时", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; status.menu = menu
        clock.onTick = { [weak self] in
            guard let self = self else { return }
            self.status.button?.title = self.clock.running ? "◷ \(self.clock.label)" : self.clock.completed ? "✓ 静时" : "◷"
            self.status.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            self.status.button?.toolTip = "静时 · \(self.clock.mode.rawValue) \(self.clock.label)"
        }
        clock.tick(); NSApp.activate(ignoringOtherApps: true)
    }
    func applyPresentation() {
        let top = window.frame.maxY
        let left = window.frame.minX
        window.level = clock.pinned ? .floating : .normal
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = clock.pinned
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let size = clock.pinned ? NSSize(width: 224, height: 184) : NSSize(width: 360, height: 594)
        window.setContentSize(size)
        var frame = window.frame
        frame.origin = NSPoint(x: left, y: top - frame.height)
        if let screen = window.screen {
            let bounds = screen.visibleFrame
            frame.origin.x = max(bounds.minX, min(frame.origin.x, bounds.maxX - frame.width))
            frame.origin.y = max(bounds.minY, min(frame.origin.y, bounds.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggle() { clock.toggle() }
    @objc func quit() { clock.save(); NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) { clock.save() }
}

final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
