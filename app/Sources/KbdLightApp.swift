//
//  键盘背光.app
//  TongfangKbd 的图形前端 —— 通过 kern.tfkbd_* sysctl 与 kext 通信
//  纯用户态，无需 sudo（sysctl 节点带 CTLFLAG_ANYBODY）
//

import SwiftUI
import AppKit

// MARK: - 调色

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

enum C {
    static let bg      = Color(hex: 0x0D0E11)
    static let bg2     = Color(hex: 0x121419)
    static let card    = Color.white.opacity(0.055)
    static let card2   = Color.white.opacity(0.035)
    static let stroke  = Color.white.opacity(0.085)
    static let accent  = Color(hex: 0xFFB55E)
    static let accent2 = Color(hex: 0xFF7C3C)
    static let green   = Color(hex: 0x4FE08C)
    static let red     = Color(hex: 0xFF6B6B)
    static let text    = Color.white.opacity(0.94)
    static let sub     = Color.white.opacity(0.50)
}

// MARK: - 颜色

struct KbdColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let white = KbdColor(r: 1, g: 1, b: 1)

    var isWhite: Bool { r > 0.97 && g > 0.97 && b > 0.97 }

    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// 略暗的同色，用来做渐变
    var dim: Color {
        Color(.sRGB, red: r * 0.68, green: g * 0.68, blue: b * 0.68, opacity: 1)
    }

    var hexLabel: String {
        String(format: "#%02X%02X%02X",
               Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }

    init(nsColor: NSColor) {
        let ns = nsColor.usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }

    static let presets: [KbdColor] = [
        KbdColor(r: 1.00, g: 1.00, b: 1.00),   // 白
        KbdColor(r: 1.00, g: 0.82, b: 0.60),   // 暖白
        KbdColor(r: 1.00, g: 0.16, b: 0.10),   // 红
        KbdColor(r: 1.00, g: 0.45, b: 0.05),   // 橙
        KbdColor(r: 1.00, g: 0.80, b: 0.10),   // 黄
        KbdColor(r: 0.20, g: 0.95, b: 0.30),   // 绿
        KbdColor(r: 0.10, g: 0.80, b: 0.90),   // 青
        KbdColor(r: 0.15, g: 0.32, b: 1.00),   // 蓝
        KbdColor(r: 0.55, g: 0.15, b: 1.00)    // 紫
    ]
}

// MARK: - EC 通道

enum EC {
    @discardableResult
    static func set(_ name: String, _ v: Int32) -> Int32 {
        var val = v
        return sysctlbyname(name, nil, nil, &val, 4)
    }

    static func get(_ name: String) -> Int32? {
        var val: Int32 = 0
        var size = 4
        guard sysctlbyname(name, &val, &size, nil, 0) == 0 else { return nil }
        return val
    }

    /// 完整应用：RGB 电平 + 默认电平 = level，0x078C = 0x70，再触发 0x0767 = 0x20
    static func apply(level: Int) {
        set("kern.tfkbd_level", Int32(max(0, min(50, level))))
        set("kern.tfkbd_val",   0x70)
        set("kern.tfkbd_cmd",   3)
    }

    /// 按颜色 + 亮度应用：写 0x0769/6A/6B（当前）与 0x076C/6D/6E（默认），保持两处一致
    static func applyRGB(_ c: KbdColor, level: Int) {
        let lv = Double(max(1, min(50, level)))
        let r = Int((lv * c.r).rounded())
        let g = Int((lv * c.g).rounded())
        let b = Int((lv * c.b).rounded())

        for (reg, v) in [(0x0769, r), (0x076A, g), (0x076B, b),
                         (0x076C, r), (0x076D, g), (0x076E, b)] {
            set("kern.tfkbd_reg", Int32(reg))
            set("kern.tfkbd_val", Int32(v))
            set("kern.tfkbd_cmd", 1)
        }
        set("kern.tfkbd_reg", 0x078C)
        set("kern.tfkbd_val", 0x70)
        set("kern.tfkbd_cmd", 1)

        set("kern.tfkbd_reg", 0x0767)
        set("kern.tfkbd_val", 0x20)
        set("kern.tfkbd_cmd", 1)

        snapshot()
    }

    /// 关闭：0x078C = 0x00，然后触发
    static func turnOff() {
        set("kern.tfkbd_reg", 0x078C)
        set("kern.tfkbd_val", 0x00)
        set("kern.tfkbd_cmd", 1)
        set("kern.tfkbd_reg", 0x0767)
        set("kern.tfkbd_val", 0x20)
        set("kern.tfkbd_cmd", 1)
        snapshot()
    }

    static func snapshot() { set("kern.tfkbd_cmd", 5) }
    static func china(_ on: Bool) { set("kern.tfkbd_cmd", on ? 4 : 6) }

    static func rawWrite(reg: Int, val: Int) {
        set("kern.tfkbd_reg", Int32(reg))
        set("kern.tfkbd_val", Int32(val))
        set("kern.tfkbd_cmd", 1)
    }

    static func rawRead(reg: Int) {
        set("kern.tfkbd_reg", Int32(reg))
        set("kern.tfkbd_cmd", 2)
    }

    static func ioRegDump() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-c", "TongfangKbd", "-r", "-l", "-w0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 模型

@MainActor
final class Model: ObservableObject {
    @Published var level: Double = 50
    @Published var isOn: Bool = true
    @Published var regs: [String: Int] = [:]
    @Published var mode: Int = -1
    @Published var loaded: Bool = false
    @Published var advanced: Bool = false
    @Published var note: String = ""
    @Published var readBack: Int? = nil
    @Published var color: KbdColor = .white

    private var timer: Timer?
    private var didInferColor = false
    private var pendingApply: DispatchWorkItem?

    static let regOrder = ["40", "65", "66", "67", "68", "69", "6A", "6B", "6C", "6D", "6E", "8C"]

    init() {
        if let l = EC.get("kern.tfkbd_level") { level = Double(l) }
        if ProcessInfo.processInfo.environment["KBDLIGHT_EXPAND"] != nil { advanced = true }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // ---- 读状态 ----
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let dump = EC.ioRegDump()
            DispatchQueue.main.async { self.parse(dump) }
        }
    }

    private func parse(_ s: String) {
        loaded = s.contains("class TongfangKbd")
        guard loaded else { mode = -1; return }

        if let m = Self.prop(s, "TFKBD-Mode"), let v = Int(m) { mode = v }

        var snap = ""
        for key in ["TFKBD-D", "TFKBD-E", "TFKBD-C", "TFKBD-B", "TFKBD-A"] {
            if let v = Self.prop(s, key), !v.isEmpty { snap = v; break }
        }
        var r: [String: Int] = [:]
        for tok in snap.split(separator: " ") {
            let kv = tok.split(separator: "=")
            if kv.count == 2, let v = Int(kv[1], radix: 16) { r[String(kv[0])] = v }
        }
        if !r.isEmpty {
            regs = r
            isOn = (r["8C"] ?? 0) != 0
            // 只在灯亮时把滑块同步到 EC；关灯后保留上一次的档位值
            if isOn, !isDragging, let lv = EC.get("kern.tfkbd_level"), lv > 0 {
                level = Double(lv)
            }
            // 首次读到状态时，反推当前颜色（三通道不等 = 有颜色）
            if !didInferColor {
                didInferColor = true
                let cr = r["69"] ?? 0, cg = r["6A"] ?? 0, cb = r["6B"] ?? 0
                let mx = max(cr, max(cg, cb))
                if mx > 0, !(cr == cg && cg == cb) {
                    color = KbdColor(r: Double(cr) / Double(mx),
                                     g: Double(cg) / Double(mx),
                                     b: Double(cb) / Double(mx))
                }
            }
        }
    }

    static func prop(_ s: String, _ key: String) -> String? {
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\"\(key)\"") else { continue }
            guard let r = t.range(of: " = ") else { continue }
            var v = String(t[r.upperBound...])
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }
        return nil
    }

    // ---- 动作 ----
    private var isDragging = false

    func beginDrag() { isDragging = true }

    func endDrag() {
        isDragging = false
        if level <= 0 { turnOff() } else { applyCurrent() }
    }

    func applyCurrent() {
        level = max(1, min(50, level))
        let lv = Int(level)
        if color.isWhite {
            EC.apply(level: lv)
        } else {
            EC.applyRGB(color, level: lv)
        }
        note = color.isWhite
            ? "已应用 白光 · \(lv) / 50"
            : "已应用 \(color.hexLabel) · \(lv) / 50"
        afterAction()
    }

    func setColor(_ c: KbdColor, debounce: Bool = false) {
        color = c
        if !isOn || level <= 0 { level = 50 }
        if debounce {
            pendingApply?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyCurrent() }
            pendingApply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            pendingApply?.cancel()
            applyCurrent()
        }
    }

    func turnOff() {
        EC.turnOff()
        note = "已关闭背光"
        afterAction()
    }

    func setPreset(_ pct: Int) {
        if pct <= 0 { level = 0; turnOff(); return }
        level = Double(max(1, min(50, Int(Double(pct) / 2.0))))
        applyCurrent()
    }

    func doSnapshot() {
        EC.snapshot()
        note = "已抓取快照"
        afterAction()
    }

    func toggleChina(_ on: Bool) {
        EC.china(on)
        note = on ? "China Mode 已开启" : "China Mode 已关闭"
        afterAction()
    }

    func writeRaw(reg: Int, val: Int) {
        EC.rawWrite(reg: reg, val: val)
        note = String(format: "已写 %04X ← %02X", reg, val)
        afterAction()
    }

    func readRaw(reg: Int) {
        EC.rawRead(reg: reg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let dump = EC.ioRegDump()
            if let s = Self.prop(dump, "TFKBD-R"), let v = Int(s) {
                self.readBack = v
                self.note = String(format: "读 %04X = %02X", reg, v)
            } else {
                self.note = "读取失败"
            }
        }
    }

    private func afterAction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)

        // 调试：KBDLIGHT_SNAP=/tmp/x.png 时把窗口内容渲染成图片后退出
        if let out = ProcessInfo.processInfo.environment["KBDLIGHT_SNAP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.snap(to: out) }
        }
    }

    private func snap(to path: String) {
        guard let win = NSApp.windows.first, let view = win.contentView else {
            NSApp.terminate(nil); return
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSApp.terminate(nil); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct KbdLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("键盘背光") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// MARK: - 小组件

struct Card<Content: View>: View {
    var padding: CGFloat = 15
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(C.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(C.stroke, lineWidth: 1)
            )
    }
}

// MARK: - 亮度滑块（自绘，避免系统滑块在深色下的灰边）

struct BrightnessSlider: View {
    @Binding var value: Double
    var tint: KbdColor = .white
    var onEditingChanged: (Bool) -> Void

    private let knob: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let frac = CGFloat(max(0, min(50, value)) / 50)
            let travel = w - knob
            let live = tint.isWhite ? C.accent : tint.color
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 7)
                Capsule()
                    .fill(LinearGradient(colors: [tint.isWhite ? C.accent2 : tint.dim, live],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: knob / 2 + travel * frac, height: 7)
                    .shadow(color: live.opacity(value > 0 ? 0.45 : 0), radius: 7, y: 0)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .offset(x: travel * frac)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onEditingChanged(true)
                        let x = min(max(0, g.location.x - knob / 2), travel)
                        value = (Double(x / travel) * 50).rounded()
                    }
                    .onEnded { _ in onEditingChanged(false) }
            )
        }
        .frame(height: 26)
    }
}

// MARK: - 颜色色板

struct ColorSwatch: View {    let color: KbdColor
    let selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [color.color, color.dim],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                    .shadow(color: color.color.opacity(selected ? 0.65 : 0), radius: 6)
                Circle()
                    .strokeBorder(Color.white.opacity(selected ? 0.95 : (hover ? 0.35 : 0)),
                                  lineWidth: 1.5)
                    .frame(width: 28, height: 28)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 彩虹圆：点开系统调色盘
struct CustomColorSwatch: View {
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        colors: [Color(hex: 0xFF3B30), Color(hex: 0xFFCC00), Color(hex: 0x34C759),
                                 Color(hex: 0x32ADE6), Color(hex: 0x5856D6), Color(hex: 0xAF52DE),
                                 Color(hex: 0xFF3B30)],
                        center: .center))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.95))
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(hover ? 0.45 : 0), lineWidth: 1.5)
                    .frame(width: 28, height: 28)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PresetButton: View {
    let title: String
    var primary: Bool = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(primary ? Color.black.opacity(0.85) : C.text)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(primary
                              ? AnyShapeStyle(LinearGradient(colors: [C.accent, C.accent2],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.white.opacity(hover ? 0.12 : 0.07)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(primary ? 0 : 0.06), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            brightnessCard
            colorCard
            presetRow
            statusRow
            advancedCard
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            m.setColor(KbdColor(nsColor: NSColorPanel.shared.color), debounce: true)
        }
    }

    // ---- 背景 ----
    private var background: some View {
        let glow = m.color.isWhite ? C.accent : m.color.color
        return LinearGradient(colors: [C.bg, C.bg2], startPoint: .top, endPoint: .bottom)
            .overlay(
                RadialGradient(colors: [glow.opacity(m.isOn ? 0.15 : 0.03), .clear],
                               center: UnitPoint(x: 0.22, y: 0.16),
                               startRadius: 0, endRadius: 300)
            )
            .overlay(
                RadialGradient(colors: [glow.opacity(m.isOn ? 0.07 : 0.0), .clear],
                               center: UnitPoint(x: 0.95, y: 0.05),
                               startRadius: 0, endRadius: 220)
            )
            .ignoresSafeArea()
    }

    // ---- 头部 ----
    private var header: some View {
        let iconTop = m.color.isWhite ? C.accent : m.color.color
        let iconBottom = m.color.isWhite ? C.accent2 : m.color.dim
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: m.isOn ? [iconTop, iconBottom]
                                                        : [Color.white.opacity(0.16), Color.white.opacity(0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .shadow(color: iconTop.opacity(m.isOn ? 0.45 : 0), radius: 9, y: 3)
                Image(systemName: "keyboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(m.isOn ? Color.black.opacity(0.8) : C.sub)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("键盘背光")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(C.text)
                Text("Tongfang / Uniwill EC")
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.sub)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.8), radius: 4)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }
    }

    private var statusColor: Color {
        if !m.loaded { return C.red }
        return m.isOn ? C.green : C.sub
    }

    private var statusText: String {
        if !m.loaded { return "驱动未加载" }
        return m.isOn ? "已点亮" : "已关闭"
    }

    // ---- 亮度 ----
    private var brightnessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text("亮度")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(C.sub)
                    Spacer()
                    Text("\(Int(m.level / 50 * 100))")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(m.isOn ? C.text : C.sub)
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(C.sub)
                        .offset(y: -8)
                }

                BrightnessSlider(value: $m.level, tint: m.color) { editing in
                    if editing { m.beginDrag() } else { m.endDrag() }
                }

                HStack {
                    Image(systemName: "sun.min")
                    Spacer()
                    Text("EC 电平 \(Int(m.level)) / 50 · \(m.color.isWhite ? "白光" : m.color.hexLabel)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(C.sub.opacity(0.85))
                    Spacer()
                    Image(systemName: "sun.max")
                }
                .font(.system(size: 10))
                .foregroundStyle(C.sub)
            }
        }
    }

    // ---- 颜色 ----
    private var colorCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 6) {
                    Text("颜色")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(C.sub)
                    Spacer()
                    Circle()
                        .fill(m.color.color)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    Text(m.color.isWhite ? "白光" : m.color.hexLabel)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(C.sub.opacity(0.85))
                }

                HStack(spacing: 0) {
                    ForEach(Array(KbdColor.presets.enumerated()), id: \.offset) { _, c in
                        ColorSwatch(color: c, selected: sameColor(c, m.color)) {
                            m.setColor(c)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    CustomColorSwatch { NSApp.orderFrontColorPanel(nil) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func sameColor(_ a: KbdColor, _ b: KbdColor) -> Bool {
        abs(a.r - b.r) < 0.04 && abs(a.g - b.g) < 0.04 && abs(a.b - b.b) < 0.04
    }

    // ---- 快捷档位 ----
    private var presetRow: some View {
        HStack(spacing: 8) {
            PresetButton(title: "关闭") { m.setPreset(0) }
            PresetButton(title: "30%")  { m.setPreset(30) }
            PresetButton(title: "60%")  { m.setPreset(60) }
            PresetButton(title: "最大", primary: true) { m.setPreset(100) }
        }
    }

    // ---- 状态 ----
    private var statusRow: some View {
        Card(padding: 14) {
            HStack(spacing: 0) {
                stat("状态寄存器", String(format: "0x%02X", m.regs["8C"] ?? 0),
                     ok: (m.regs["8C"] ?? 0) != 0)
                divider
                stat("开机自动", m.mode >= 1 ? "已启用" : "未启用",
                     ok: m.mode >= 1)
                divider
                stat("EC 电平", "\(Int(m.level))", ok: m.isOn)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(C.stroke).frame(width: 1, height: 26)
    }

    private func stat(_ k: String, _ v: String, ok: Bool) -> some View {
        VStack(spacing: 4) {
            Text(k)
                .font(.system(size: 10))
                .foregroundStyle(C.sub)
            Text(v)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(ok ? C.text : C.sub)
        }
        .frame(maxWidth: .infinity)
    }

    // ---- 高级 ----
    private var advancedCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { m.advanced.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                        Text("高级 / 寄存器")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: m.advanced ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(C.sub)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if m.advanced {
                    VStack(alignment: .leading, spacing: 12) {
                        regGrid

                        HStack(spacing: 7) {
                            PresetButton(title: "刷新快照") { m.doSnapshot() }
                            PresetButton(title: "读 0x078C") { m.readRaw(reg: 0x078C) }
                        }

                        RawWriteRow { reg, val in
                            m.writeRaw(reg: reg, val: val)
                        }

                        if !m.note.isEmpty {
                            Text(m.note)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(C.sub)
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.bottom, 15)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var regGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(Model.regOrder, id: \.self) { k in
                let v = m.regs[k]
                VStack(spacing: 2) {
                    Text(k)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(C.sub.opacity(0.8))
                    Text(v.map { String(format: "%02X", $0) } ?? "--")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(k == "8C" && (v ?? 0) != 0 ? C.accent : C.text.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(k == "8C" ? C.accent.opacity(0.10) : C.card2))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(k == "8C" ? C.accent.opacity(0.35) : Color.white.opacity(0.04), lineWidth: 1))
            }
        }
    }

    // ---- 底栏 ----
    private var footer: some View {
        HStack(spacing: 6) {
            Text("TongfangKbd · INOU0000")
                .font(.system(size: 10, design: .monospaced))
            Spacer()
            Text("无需密码")
                .font(.system(size: 10))
        }
        .foregroundStyle(C.sub.opacity(0.55))
        .padding(.horizontal, 2)
    }
}

// MARK: - 任意寄存器写入

struct RawWriteRow: View {
    @State private var reg = "0769"
    @State private var val = "32"
    var onWrite: (Int, Int) -> Void

    var body: some View {
        HStack(spacing: 7) {
            field(placeholder: "地址", text: $reg)
            Text("←")
                .font(.system(size: 11))
                .foregroundStyle(C.sub)
            field(placeholder: "值", text: $val)
            Button {
                if let r = Int(reg, radix: 16), let v = Int(val, radix: 16) {
                    onWrite(r, v)
                }
            } label: {
                Text("写入")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(C.text)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
        }
    }

    private func field(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(C.text)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}
