import AppKit
import SwiftUI

// MARK: - Shell plumbing

struct ShellResult {
    let out: String
    let code: Int32
}

@discardableResult
func runShell(_ argv: [String]) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch {
        return ShellResult(out: error.localizedDescription, code: -1)
    }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return ShellResult(out: String(data: data, encoding: .utf8) ?? "", code: p.terminationStatus)
}

// Privileged commands go through macOS's own GUI password prompt.
@discardableResult
func runAdmin(_ command: String) -> ShellResult {
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return runShell(["/usr/bin/osascript", "-e",
                     "do shell script \"\(escaped)\" with administrator privileges"])
}

func resourcePath(_ name: String) -> String {
    Bundle.main.path(forResource: name, ofType: "sh") ?? name
}

func newReportPath(_ prefix: String) -> String {
    let dir = NSHomeDirectory() + "/.macpulse/reports"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    return dir + "/\(prefix)-\(fmt.string(from: Date())).txt"
}

// MARK: - Model

final class PulseModel: ObservableObject {
    @Published var batteryPct: Int = 100
    @Published var onBattery = false
    @Published var charging = false
    @Published var watts: Double = 0
    @Published var healthPct: Int? = nil
    @Published var etaMinutes: Int? = nil
    @Published var freeMemPct: Int = 100
    @Published var hog: String? = nil
    @Published var lowPower = false
    @Published var guardOn = false
    @Published var loginOn = false
    @Published var busy: String? = nil
    @Published var toast: String? = nil
    @Published var expanded = false
    @Published var consRuntimeMin: Int? = nil

    // Thermal governor mirror (fed by /Library/Application Support/MacPulse/thermal.json)
    @Published var thermCpuC: Double = 0
    @Published var thermFanRpm: Int = 0
    @Published var thermBand: Int = 0            // 0 COOL · 1 WARM · 2 HOT · 3 CRIT
    @Published var thermBandName: String = "—"
    @Published var thermThrottling = false
    @Published var thermSpeedLimit: Int = 100
    @Published var thermHog: String = ""
    @Published var thermAdvice: String = ""
    @Published var fanControlAvailable = false
    @Published var fanControlReason: String = ""

    // Render self-limit: drop the live desktop blur when hot (band ≥ 2) or on
    // battery. This is the app's own contribution to cooling the machine.
    var cheapGlass: Bool { thermBand >= 2 || onBattery }

    var expandRequest: ((Bool) -> Void)?

    // Kalman filter (local linear trend) mirroring the guard daemon:
    // state [level, trend], covariance P, measurement noise R adapted online
    private var kL: Double? = nil
    private var kT: Double = 0
    private var kP11: Double = 25
    private var kP12: Double = 0
    private var kP22: Double = 1
    private var kR: Double = 4

    // Leak sentinel: RSS baselines per process name over a 10-min window
    private var rssBaseline: [String: (rss: Double, t: Date)] = [:]
    private var leakWarned: [String: Date] = [:]

    private var toastGen = 0
    private var hoverWork: DispatchWorkItem?
    private let loginAgent = NSHomeDirectory() + "/Library/LaunchAgents/com.macpulse.login.plist"

    static func signed64(_ s: String) -> Int64 {
        if let i = Int64(s) { return i }
        if let u = UInt64(s) { return Int64(bitPattern: u) }
        return 0
    }

    // Decoded shape of thermal.json written by the root governor (thermal.sh).
    private struct ThermalJSON: Decodable {
        struct Hog: Decodable { let name: String; let cpu: Double }
        let cpu_c: Double; let fan_rpm: Double
        let speed_limit: Int; let throttling: Bool
        let band: Int; let band_name: String
        let fan_control: Bool; let fan_reason: String
        let hog: Hog; let advice: String
    }

    // Read the governor's latest sample (cheap: a small local file). Publishes
    // on the main thread. Silent no-op until the governor is installed.
    func readThermal() {
        let path = "/Library/Application Support/MacPulse/thermal.json"
        guard let data = FileManager.default.contents(atPath: path),
              let t = try? JSONDecoder().decode(ThermalJSON.self, from: data) else { return }
        DispatchQueue.main.async {
            self.thermCpuC = t.cpu_c
            self.thermFanRpm = Int(t.fan_rpm.rounded())
            self.thermSpeedLimit = t.speed_limit
            self.thermThrottling = t.throttling
            self.thermBand = t.band
            self.thermBandName = t.band_name
            self.thermHog = t.hog.cpu > 0 ? "\(t.hog.name) \(Int(t.hog.cpu))%" : t.hog.name
            self.thermAdvice = t.advice
            self.fanControlAvailable = t.fan_control
            self.fanControlReason = t.fan_reason
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let batt = runShell(["/usr/bin/pmset", "-g", "batt"]).out
            var pct = 100
            if let r = batt.range(of: "[0-9]+%", options: .regularExpression) {
                pct = Int(batt[r].dropLast()) ?? 100
            }

            var lpm = false
            let live = runShell(["/usr/bin/pmset", "-g"]).out
            for lineSub in live.split(separator: "\n") where lineSub.contains("lowpowermode") {
                lpm = lineSub.trimmingCharacters(in: .whitespaces).hasSuffix("1")
            }

            let mem = runShell(["/usr/bin/memory_pressure"]).out
            var free = 100
            if let r = mem.range(of: "free percentage: [0-9]+%", options: .regularExpression) {
                free = Int(mem[r].filter { $0.isNumber }) ?? 100
            }

            // Battery gauge: only top-level keys (nested dicts repeat names)
            let io = runShell(["/usr/sbin/ioreg", "-rn", "AppleSmartBattery"]).out
            var amp: Int64 = 0, volt: Int64 = 0
            var extConn = true, isChg = false
            var maxCap = 0.0, designCap = 0.0, curCap = 0.0
            var timeRem = -1
            for raw in io.split(separator: "\n") {
                let t = raw.trimmingCharacters(in: .whitespaces)
                func val(_ key: String) -> String? {
                    let p = "\"\(key)\" = "
                    return t.hasPrefix(p) ? String(t.dropFirst(p.count)) : nil
                }
                if let v = val("InstantAmperage") { amp = Self.signed64(v) }
                if let v = val("Voltage") { volt = Self.signed64(v) }
                if let v = val("ExternalConnected") { extConn = (v == "Yes") }
                if let v = val("IsCharging") { isChg = (v == "Yes") }
                if let v = val("MaxCapacity") { maxCap = Double(v) ?? 0 }
                if let v = val("DesignCapacity") { designCap = Double(v) ?? 0 }
                if let v = val("CurrentCapacity") { curCap = Double(v) ?? 0 }
                if let v = val("TimeRemaining"), let i = Int(v) { timeRem = i }
            }
            let rawW = Double(abs(amp)) * Double(volt) / 1_000_000.0
            let energyWh = curCap * Double(volt) / 1_000_000.0
            let health: Int? = designCap > 0 ? Int((maxCap / designCap * 100).rounded()) : nil
            let eta: Int? = (!extConn && timeRem > 0 && timeRem < 3000) ? timeRem : nil

            // Top RAM residents for the leak sentinel
            let topRss = runShell(["/bin/zsh", "-c", "ps axo rss,comm | sort -rn | head -8"]).out

            // Top energy consumer (CPU share as attribution proxy)
            let ps = runShell(["/bin/zsh", "-c", "ps axo %cpu,comm | sort -rn | head -1"]).out
            var hogText: String? = nil
            let parts = ps.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1)
            if parts.count == 2, let cpu = Double(parts[0]) {
                let name = String(parts[1]).split(separator: "/").last.map(String.init) ?? String(parts[1])
                hogText = "\(name) \(Int(cpu))%"
            }

            // Thermal (non-root): band from kernel thermal-pressure level, throttle
            // from pmset -g therm. These need no daemon — the governor's thermal.json
            // only *enriches* this with real °C/RPM when installed.
            let levelStr = runShell(["/usr/sbin/sysctl", "-n", "machdep.xcpm.cpu_thermal_level"]).out
            let thermLevel = Int(levelStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let thermOut = runShell(["/usr/bin/pmset", "-g", "therm"]).out
            var speedLimit = 100
            if let r = thermOut.range(of: "CPU_Speed_Limit[^0-9]*[0-9]+", options: .regularExpression) {
                speedLimit = Int(thermOut[r].filter { $0.isNumber }) ?? 100
            }
            let uBand = thermLevel >= 118 ? 3 : thermLevel >= 108 ? 2 : thermLevel >= 95 ? 1 : 0

            let g = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.macpulse.guard.plist")
            let l = FileManager.default.fileExists(atPath: self.loginAgent)

            DispatchQueue.main.async {
                // Base thermal state from live non-root signals (always available).
                let names = ["COOL", "WARM", "HOT", "CRIT"]
                self.thermSpeedLimit = speedLimit
                self.thermThrottling = speedLimit < 100
                self.thermBand = uBand
                self.thermBandName = names[uBand]
                self.thermHog = hogText ?? ""
                switch uBand {
                case 0: self.thermAdvice = "Thermals nominal."
                case 1: self.thermAdvice = "Warming. MacPulse is easing its own render."
                case 2: self.thermAdvice = "Hot — compositing load high. Top source: \(hogText ?? "—"). Close heavy GPU tabs."
                default: self.thermAdvice = "CRITICAL — at throttle threshold. Biggest source: \(hogText ?? "—"). Quit or pause it."
                }
                // Chance-constrained runtime bound (same math as the daemon):
                // 60E / (P_forecast + 1.645 sigma), sigma from Kalman covariance
                var cons: Int? = nil
                if !extConn {
                    if self.kL == nil {
                        self.kL = rawW; self.kT = 0
                        self.kP11 = 25; self.kP12 = 0; self.kP22 = 1; self.kR = 4
                    }
                    let lp = self.kL! + self.kT
                    let a11 = self.kP11 + 2 * self.kP12 + self.kP22 + 0.5
                    let a12 = self.kP12 + self.kP22
                    let a22 = self.kP22 + 0.05
                    let y = rawW - lp
                    let s = a11 + self.kR
                    let k1 = a11 / s, k2 = a12 / s
                    self.kL = lp + k1 * y
                    self.kT = self.kT + k2 * y
                    self.kP11 = (1 - k1) * a11
                    self.kP12 = (1 - k1) * a12
                    self.kP22 = a22 - k2 * a12
                    self.kR = max(0.9 * self.kR + 0.1 * (y * y - a11), 0.25)
                    var p = self.kL! + 5 * self.kT
                    if p < self.kL! { p = self.kL! }
                    if p < 3 { p = 3 }
                    let varF = max(self.kP11 + 10 * self.kP12 + 25 * self.kP22 + self.kR, 0.01)
                    if energyWh > 0 {
                        cons = Int(60 * energyWh / (p + 1.645 * varF.squareRoot()))
                    }
                } else {
                    self.kL = nil
                }

                // Leak sentinel: flag processes growing >300 MB across >=10 min
                let now = Date()
                for lineSub in topRss.split(separator: "\n") {
                    let parts2 = lineSub.trimmingCharacters(in: .whitespaces)
                        .split(separator: " ", maxSplits: 1)
                    guard parts2.count == 2, let kb = Double(parts2[0]) else { continue }
                    let mb = kb / 1024
                    let name = String(parts2[1]).split(separator: "/").last.map(String.init) ?? String(parts2[1])
                    if let base = self.rssBaseline[name] {
                        let dt = now.timeIntervalSince(base.t)
                        if dt >= 600 {
                            let grew = mb - base.rss
                            let lastWarn = self.leakWarned[name] ?? .distantPast
                            if grew > 300, now.timeIntervalSince(lastWarn) > 1800 {
                                self.leakWarned[name] = now
                                self.flash("⚠︎ \(name) grew \(Int(grew)) MB in \(Int(dt / 60)) min")
                            }
                            self.rssBaseline[name] = (mb, now)
                        }
                    } else {
                        self.rssBaseline[name] = (mb, now)
                    }
                }

                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
                    self.consRuntimeMin = cons
                    self.batteryPct = pct
                    self.onBattery = !extConn
                    self.charging = isChg
                    self.watts = self.watts == 0 ? rawW : (0.55 * self.watts + 0.45 * rawW)
                    self.healthPct = health
                    self.etaMinutes = eta
                    self.freeMemPct = free
                    self.hog = hogText
                    self.lowPower = lpm
                    self.guardOn = g
                    self.loginOn = l
                }
                // Enrich with the governor's real °C/RPM when the daemon is installed;
                // otherwise the non-root band above stands on its own.
                self.readThermal()
            }
        }
    }

    // MARK: hover intent (expand on hover, collapse when the cursor leaves)

    func pillHover(_ inside: Bool) {
        hoverWork?.cancel()
        guard !expanded, inside else { return }
        let w = DispatchWorkItem { [weak self] in self?.expandRequest?(true) }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func panelHover(_ inside: Bool) {
        hoverWork?.cancel()
        guard expanded, !inside else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.expanded, self.busy == nil else { return }
            self.expandRequest?(false)
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // MARK: toast + actions

    func flash(_ msg: String) {
        DispatchQueue.main.async {
            self.toastGen += 1
            let gen = self.toastGen
            withAnimation { self.toast = msg }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.toastGen == gen {
                    withAnimation { self.toast = nil }
                }
            }
        }
    }

    private func run(_ label: String, work: @escaping () -> Void) {
        guard busy == nil else { return }
        busy = label
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { self.busy = nil }
            self.refresh()
        }
    }

    // MARK: password-free agent (root daemon watching the spool dir)

    private let spool = "/Library/Application Support/MacPulse/spool"

    private func agentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.macpulse.agent.plist")
            && FileManager.default.isWritableFile(atPath: spool)
    }

    // Drop a bare-verb request file; the root agent answers via done-<id>.
    private func agentRequest(_ verb: String, timeout: TimeInterval) -> String? {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let done = "\(spool)/done-\(id)"
        do {
            try verb.write(toFile: "\(spool)/req-\(id)", atomically: true, encoding: .utf8)
        } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? String(contentsOfFile: done, encoding: .utf8) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return nil
    }

    // MARK: thermal governor (real °C/RPM daemon; band works without it)

    func thermalInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.macpulse.thermal.plist")
    }

    // One OS admin prompt installs the °C-sensor daemon. The band/throttle/hog
    // readout already works from non-root signals; this just adds real °C + RPM.
    func installThermal() {
        run("Enabling °C sensor…") {
            let core = resourcePath("macpulse-core")
            let thermal = resourcePath("thermal")
            let smc = Bundle.main.path(forResource: "smc", ofType: nil) ?? "\(self.spool)/../smc"
            let r = runAdmin("/bin/zsh '\(core)' thermal-install '\(thermal)' '\(smc)'")
            self.flash(r.code == 0 ? "Live °C sensor enabled" : "Sensor install canceled")
        }
    }

    func audit() {
        run("Auditing…") {
            let rpt = newReportPath("audit")
            let core = resourcePath("macpulse-core")
            runShell(["/bin/zsh", "-c", "/bin/zsh '\(core)' audit > '\(rpt)' 2>&1"])
            runShell(["/usr/bin/open", "-e", rpt])
            self.flash("Audit report opened")
        }
    }

    func deepScan() {
        run("Deep scanning…") {
            if self.agentInstalled() {
                if let path = self.agentRequest("deep", timeout: 90), path.hasPrefix("/") {
                    runShell(["/usr/bin/open", "-e", path])
                    self.flash("Deep scan complete — no password")
                } else {
                    self.flash("Agent didn't answer — re-toggle Guard")
                }
                return
            }
            // No agent yet: install the engine AND run the scan in one
            // prompt, so this is the last password the app ever asks for.
            let rpt = newReportPath("deepscan")
            let core = resourcePath("macpulse-core")
            let src = resourcePath("guard-root")
            let agentSrc = resourcePath("agent-root")
            let r = runAdmin("/bin/zsh '\(core)' guard-install '\(src)' '\(agentSrc)' && /bin/zsh '\(core)' deep '\(rpt)'")
            if r.code == 0 {
                runShell(["/usr/bin/open", "-e", rpt])
                self.flash("Done — that was the last password")
            } else {
                self.flash("Deep scan canceled")
            }
        }
    }

    func tune() {
        run("Tuning…") {
            if self.agentInstalled() {
                if self.agentRequest("tune", timeout: 30) == "ok" {
                    self.flash("Optimizations applied — no password")
                } else {
                    self.flash("Agent didn't answer — re-toggle Guard")
                }
                return
            }
            // No agent yet: install the engine AND tune in one prompt,
            // so this is the last password the app ever asks for.
            let core = resourcePath("macpulse-core")
            let src = resourcePath("guard-root")
            let agentSrc = resourcePath("agent-root")
            let r = runAdmin("/bin/zsh '\(core)' guard-install '\(src)' '\(agentSrc)' && /bin/zsh '\(core)' tune")
            self.flash(r.code == 0 ? "Applied — that was the last password" : "Tune canceled")
        }
    }

    func toggleGuard() {
        let installed = guardOn
        run(installed ? "Removing Guard…" : "Installing Guard…") {
            let core = resourcePath("macpulse-core")
            if installed {
                let r = runAdmin("/bin/zsh '\(core)' guard-remove")
                self.flash(r.code == 0 ? "Guard removed" : "Canceled")
            } else {
                let src = resourcePath("guard-root")
                let agentSrc = resourcePath("agent-root")
                let r = runAdmin("/bin/zsh '\(core)' guard-install '\(src)' '\(agentSrc)'")
                self.flash(r.code == 0 ? "Engine on — predictive governor, no more passwords" : "Canceled")
            }
        }
    }

    func setLogin(_ on: Bool) {
        if on {
            let dir = NSHomeDirectory() + "/Library/LaunchAgents"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.macpulse.login</string>
              <key>ProgramArguments</key>
              <array><string>/usr/bin/open</string><string>-a</string><string>\(Bundle.main.bundlePath)</string></array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            do {
                try plist.write(toFile: loginAgent, atomically: true, encoding: .utf8)
                flash("Launch at login enabled")
            } catch {
                flash("Could not write login item")
            }
        } else {
            runShell(["/bin/launchctl", "bootout", "gui/\(getuid())/com.macpulse.login"])
            try? FileManager.default.removeItem(atPath: loginAgent)
            flash("Launch at login disabled")
        }
        refresh()
    }

    func openLog() {
        let log = "/Library/Application Support/MacPulse/macpulse.log"
        if FileManager.default.fileExists(atPath: log) {
            runShell(["/usr/bin/open", "-e", log])
        } else {
            flash("No guard activity logged yet")
        }
    }
}

// MARK: - Reusable views

// Behind-window vibrancy. SwiftUI's `.ultraThinMaterial` inside a borderless
// panel only blends within-window, which renders as a flat card; an
// NSVisualEffectView with .behindWindow is what actually samples the desktop.
struct GlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    // Thermal self-limit: `.active` continuously re-samples the desktop behind
    // the panel every frame — that live blur is what pins the iGPU and inflates
    // WindowServer. When the machine is hot or on battery we switch to
    // `.inactive`, which freezes sampling (the glass stops chasing the desktop)
    // and costs almost nothing. The app thus stops being its own heat source
    // exactly when heat matters.
    var cheap: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        apply(v)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        apply(v)
    }

    // Cheap mode keeps compositing ACTIVE (so nothing ghosts) but blends
    // within-window instead of behind-window — that drops the continuous
    // desktop sampling that pins the iGPU, which was the real heat cost.
    private func apply(_ v: NSVisualEffectView) {
        v.material = cheap ? .windowBackground : material
        v.blendingMode = cheap ? .withinWindow : .behindWindow
        v.state = .active
        v.isEmphasized = !cheap
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.92))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                // macOS 27 kit button anatomy: #444 glass plate at 60% + white
                // lift + specular ring + y8 soft shadow (values read from the kit)
                Capsule()
                    .fill(Color.primary.opacity(hovering ? 0.16 : 0.09))
                    .overlay(Capsule().fill(Color.primary.opacity(hovering ? 0.06 : 0.03)))
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.38), Color.primary.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.13)) { hovering = h }
        }
    }
}

struct StatCell: View {
    let value: String
    let unit: String
    let title: String
    let tint: Color
    var sub: String? = nil

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 25, weight: .semibold).monospacedDigit())
                    .foregroundColor(tint)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint.opacity(0.7))
            }
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.1)
                .foregroundColor(.primary.opacity(0.5))
            Text(sub ?? " ")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.primary.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.32), Color.primary.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                )
        )
    }
}

// macOS 27 kit switch, metrics read from the kit's component: 54×24 capsule
// track (black 85% off / tint on), 32×20 white pill knob, y3 soft shadow
struct KitSwitch: View {
    let on: Bool
    let tint: Color

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? tint.opacity(0.9) : Color.black.opacity(0.85))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            Capsule()
                .fill(Color.white)
                .frame(width: 32, height: 20)
                .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 3)
                .padding(2)
        }
        .frame(width: 54, height: 24)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: on)
    }
}

struct ToggleCell: View {
    let symbol: String
    let label: String
    let on: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(on ? tint : .primary.opacity(0.45))
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.primary.opacity(0.92))
            Spacer(minLength: 4)
            KitSwitch(on: on, tint: tint)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            Capsule()
                .fill(Color.primary.opacity(hovering ? 0.18 : 0.08))
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
        )
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.13)) { hovering = h }
        }
    }
}

// MARK: - Island

struct IslandView: View {
    @ObservedObject var model: PulseModel
    var setExpanded: (Bool) -> Void
    @State private var pillHovering = false
    @State private var lightsHover = false
    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.colorScheme) private var scheme

    private let memBlue = Color(red: 0.55, green: 0.75, blue: 1.0)

    private var batterySymbol: String {
        if !model.onBattery { return "bolt.fill" }
        switch model.batteryPct {
        case ..<20: return "battery.25"
        case ..<55: return "battery.50"
        case ..<85: return "battery.75"
        default:    return "battery.100"
        }
    }

    private var batteryColor: Color {
        if model.lowPower { return .yellow }
        if !model.onBattery { return .green }
        switch model.batteryPct {
        case ..<20: return .red
        case ..<50: return .yellow
        default:    return .green
        }
    }

    private var wattColor: Color {
        if !model.onBattery { return .green }
        switch model.watts {
        case ..<12: return .green
        case ..<25: return .orange
        default:    return .red
        }
    }

    private var glow: Color {
        if model.lowPower { return .yellow.opacity(0.20) }
        if model.guardOn { return .green.opacity(0.12) }
        return .clear
    }

    var body: some View {
        VStack(spacing: 0) {
            islandBody
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var cornerRadius: CGFloat { model.expanded ? 34 : 24 }

    // macOS window controls, kit colors: FF5F57 / FEBC2E / 28C840
    private func trafficLight(_ color: Color, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
                if lightsHover {
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .heavy))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var islandBody: some View {
        VStack(spacing: 0) {
            if model.expanded { expandedView } else { compactView }
        }
        .background(
            ZStack {
                // 1. real behind-window blur — samples the desktop underneath.
                //    Freezes to a cheap static blur when hot/on battery so the
                //    island stops driving the iGPU it's meant to protect.
                GlassBackdrop(cheap: model.cheapGlass)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // 2. adaptive tint: smoked in dark, luminous frost in light
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: scheme == .dark
                                ? [Color.white.opacity(0.10), Color.black.opacity(0.14)]
                                : [Color.white.opacity(0.34), Color.white.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                // 3. specular band along the top edge
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.30), location: 0),
                                .init(color: Color.clear, location: 0.34)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                // 4. counter-light: real glass catches light on its lower edge too
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.clear, location: 0.80),
                                .init(color: Color.white.opacity(0.13), location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                // 5. specular that follows the cursor — what makes glass feel liquid
                if let p = hoverPoint {
                    RadialGradient(
                        colors: [Color.white.opacity(0.20), Color.clear],
                        center: UnitPoint(x: p.x, y: p.y),
                        startRadius: 0, endRadius: 190
                    )
                    .blendMode(.plusLighter)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.70), Color.white.opacity(0.12)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1.2
                    )
            )
            // Layered like Apple's: a tight contact shadow plus a wide, very
            // faint ambient one. A single heavy blur reads as a grey smudge
            // over light backgrounds, so both scale with the appearance.
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.28 : 0.10),
                    radius: 3, x: 0, y: 1)
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.26 : 0.09),
                    radius: 14, x: 0, y: 8)
            .shadow(color: scheme == .dark ? glow : .clear, radius: 16, x: 0, y: 0)
        )
        .scaleEffect(pillHovering && !model.expanded ? 1.045 : 1.0)
        .padding(.top, 3)
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                let w: CGFloat = model.expanded ? 444 : 300
                let h: CGFloat = model.expanded ? 430 : 110
                hoverPoint = CGPoint(x: loc.x / w, y: loc.y / h)
            case .ended:
                hoverPoint = nil
            }
        }
    }

    // MARK: compact pill

    private var compactView: some View {
        HStack(spacing: 9) {
            Image(systemName: batterySymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(batteryColor)
            Text("\(model.batteryPct)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.primary)
                .contentTransition(.numericText())
            dot
            if model.onBattery {
                Text(String(format: "%.1f W", model.watts))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(wattColor)
                    .contentTransition(.numericText())
            } else {
                Text(model.charging ? "AC ⌁" : "AC")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.green.opacity(0.9))
            }
            dot
            Image(systemName: "memorychip")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(memBlue)
            Text("\(model.freeMemPct)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.primary)
                .contentTransition(.numericText())
            if model.guardOn {
                Image(systemName: "shield.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color.green.opacity(0.9))
            }
            if model.thermBand >= 1 || model.thermThrottling {
                dot
                Image(systemName: model.thermThrottling ? "flame.fill" : "thermometer.medium")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(bandColor)
                if model.thermCpuC > 0 {
                    Text("\(Int(model.thermCpuC))°")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(bandColor)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { setExpanded(true) }
        .onHover { h in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pillHovering = h }
            model.pillHover(h)
        }
    }

    private var dot: some View {
        Circle()
            .fill(Color.white.opacity(0.25))
            .frame(width: 3.5, height: 3.5)
    }

    // Thermal band → colour. 0 cool green · 1 warm yellow · 2 hot orange · 3 crit red.
    private var bandColor: Color {
        switch model.thermBand {
        case 3: return Color(red: 1.0, green: 0.30, blue: 0.28)
        case 2: return Color(red: 1.0, green: 0.55, blue: 0.15)
        case 1: return Color(red: 1.0, green: 0.80, blue: 0.25)
        default: return Color(red: 0.30, green: 0.80, blue: 0.45)
        }
    }

    // Multi-band thermal readout — the governor's live state, T2-honest.
    private var thermalCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: model.thermThrottling ? "flame.fill" : "thermometer.medium")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(bandColor)
                Text("THERMAL")
                    .font(.system(size: 10, weight: .heavy)).tracking(1.4)
                    .foregroundColor(.secondary)
                Text(model.thermBandName)
                    .font(.system(size: 10, weight: .heavy)).tracking(1)
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(bandColor.opacity(0.95)))
                Spacer()
                if model.thermThrottling {
                    Text("THROTTLING \(model.thermSpeedLimit)%")
                        .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                        .foregroundColor(Color(red: 1.0, green: 0.30, blue: 0.28))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                bandStat(model.thermCpuC > 0 ? "\(Int(model.thermCpuC))°" : "—", "CPU DIE")
                bandStat(model.thermFanRpm > 0 ? "\(model.thermFanRpm)" : "—", "FAN RPM")
                bandStat("\(model.thermSpeedLimit)%", "CPU SPEED")
                Spacer()
            }
            if !model.thermAdvice.isEmpty {
                Text(model.thermAdvice)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.thermCpuC == 0 {
                Button { model.installThermal() } label: {
                    Label("Enable live °C + fan sensor (one prompt)", systemImage: "thermometer.medium")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(bandColor)
                }
                .buttonStyle(.plain)
                .disabled(model.busy != nil)
            }
            Label("Fans on Apple's curve — direct control blocked by the T2 on this model",
                  systemImage: "lock.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
                .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(bandColor.opacity(model.thermBand >= 2 ? 0.12 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(bandColor.opacity(0.30), lineWidth: 1))
        )
    }

    private func bandStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundColor(.primary)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 8, weight: .heavy)).tracking(0.8)
                .foregroundColor(.secondary)
        }
    }

    // MARK: expanded panel

    private var expandedView: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 7) {
                    trafficLight(Color(red: 1.0, green: 0.373, blue: 0.341), "xmark",
                                 help: "Quit MacPulse") { NSApp.terminate(nil) }
                    trafficLight(Color(red: 1.0, green: 0.737, blue: 0.180), "minus",
                                 help: "Hide island (menu-bar bolt brings it back)") {
                        NSApp.windows.first { $0 is IslandPanel }?.orderOut(nil)
                    }
                    trafficLight(Color(red: 0.157, green: 0.784, blue: 0.251),
                                 "arrow.down.right.and.arrow.up.left",
                                 help: "Collapse to pill") { setExpanded(false) }
                }
                .onHover { h in
                    withAnimation(.easeOut(duration: 0.12)) { lightsHover = h }
                }
                Text("MacPulse")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(.leading, 2)
                if model.lowPower {
                    Text("LOW POWER")
                        .font(.system(size: 8, weight: .heavy))
                        .tracking(1)
                        .foregroundColor(.black.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.yellow.opacity(0.9)))
                }
                Spacer()
            }

            HStack(spacing: 10) {
                StatCell(
                    value: "\(model.batteryPct)", unit: "%",
                    title: model.charging ? "CHARGING" : (model.onBattery ? "BATTERY" : "AC POWER"),
                    tint: batteryColor,
                    sub: model.healthPct.map { "health \($0)%" }
                )
                StatCell(
                    value: String(format: "%.1f", model.watts), unit: "W",
                    title: model.onBattery ? "DRAIN" : "INPUT",
                    tint: wattColor,
                    sub: model.consRuntimeMin.map { String(format: "≥%d:%02d @ 95%%", $0 / 60, $0 % 60) }
                        ?? model.etaMinutes.map { String(format: "%d:%02d left", $0 / 60, $0 % 60) }
                )
                StatCell(
                    value: "\(model.freeMemPct)", unit: "%",
                    title: "RAM FREE",
                    tint: memBlue,
                    sub: model.hog
                )
            }

            thermalCard

            HStack(spacing: 10) {
                ActionButton(title: "Audit", symbol: "waveform.path.ecg") { model.audit() }
                ActionButton(title: "Deep Scan", symbol: "cpu", tint: memBlue) { model.deepScan() }
                ActionButton(title: "Tune", symbol: "slider.horizontal.3", tint: .orange) { model.tune() }
                ActionButton(title: "Log", symbol: "doc.text", tint: .white.opacity(0.7)) { model.openLog() }
            }

            HStack(spacing: 10) {
                ToggleCell(
                    symbol: "shield.fill", label: "Guard",
                    on: model.guardOn, tint: .green
                ) { model.toggleGuard() }
                ToggleCell(
                    symbol: "sunrise.fill", label: "Login",
                    on: model.loginOn, tint: memBlue
                ) { model.setLogin(!model.loginOn) }
            }

            HStack {
                if let busy = model.busy {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)

                        Text(busy)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary.opacity(0.7))
                    }
                } else if let toast = model.toast {
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary.opacity(0.7))
                        .transition(.opacity)
                }
                Spacer()
                Text("esc closes")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.primary.opacity(0.28))
            }
            .frame(height: 18)
        }
        .padding(16)
        .frame(width: 430)
        .disabled(model.busy != nil)
        .onHover { h in model.panelHover(h) }
    }
}

// MARK: - Window

final class IslandPanel: NSPanel {
    var onEsc: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEsc?() } else { super.keyDown(with: event) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PulseModel()
    var panel: IslandPanel!
    var statusItem: NSStatusItem!
    var timer: Timer?

    private func windowSize(expanded: Bool) -> NSSize {
        expanded ? NSSize(width: 480, height: 500) : NSSize(width: 360, height: 105)
    }

    private func initialFrame() -> NSRect {
        let size = windowSize(expanded: false)
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height,
            width: size.width, height: size.height
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "MacPulse")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide Island", action: #selector(toggleIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MacPulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        panel = IslandPanel(
            contentRect: initialFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEsc = { [weak self] in self?.escapePressed() }

        model.expandRequest = { [weak self] expanded in
            self?.setExpanded(expanded)
        }
        let root = IslandView(model: model) { [weak self] expanded in
            self?.setExpanded(expanded)
        }
        panel.contentView = NSHostingView(rootView: root)
        panel.makeKeyAndOrderFront(nil)

        // --expanded opens the panel at launch (used for documentation captures)
        if CommandLine.arguments.contains("--expanded") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setExpanded(true)
            }
        }

        model.refresh()
        rearmTimer()
    }

    // Adaptive cadence: poll briskly while the panel is open, lazily while it's
    // a pill. Fewer shell spawns/re-renders when idle = less periodic heat.
    private func rearmTimer() {
        timer?.invalidate()
        let interval: TimeInterval = model.expanded ? 5 : 14
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }
        if expanded { model.refresh() }   // fresh numbers the instant it opens
        defer { rearmTimer() }            // follow the new cadence
        let current = panel.frame
        let size = windowSize(expanded: expanded)
        let newFrame = NSRect(
            x: current.midX - size.width / 2,
            y: current.maxY - size.height,
            width: size.width, height: size.height
        )
        if expanded {
            panel.setFrame(newFrame, display: true)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.expanded = true
            }
        } else {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                model.expanded = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.model.expanded else { return }
                self.panel.setFrame(newFrame, display: true)
            }
        }
    }

    private func escapePressed() {
        if model.expanded {
            setExpanded(false)
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func toggleIsland() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            model.refresh()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
