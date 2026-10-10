// Menu-bar status icon for vpnc (macOS). Shows the flag of the country of the server in use,
// a red dot when mihomo is down or the server does not answer. The menu shows server, ping,
// mode, priority server and the live up/down speed (the same stream the web panel uses). Talks to mihomo's API only; needs no sudo:
// address/secret come from /etc/mihomo/control.json (readable by the admin group).
//
// Build:  swiftc -O -o VpncBar VpncBar.swift -framework Cocoa
// Run:    VpncBar            (menu-bar app)
//         VpncBar --once     (print the status once and exit; used by the tests)
import Cocoa
import Foundation

struct Control { var bind = "127.0.0.1:9090"; var secret = ""; var ui = false }

func loadControl() -> Control {
    var c = Control()
    if let d = FileManager.default.contents(atPath: ProcessInfo.processInfo.environment["VPNC_CONTROL_FILE"] ?? "/etc/mihomo/control.json"),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        c.bind = (j["bind"] as? String) ?? c.bind
        c.secret = (j["secret"] as? String) ?? ""
        c.ui = (j["ui"] as? Bool) ?? false
    }
    return c
}

func api(_ path: String, timeout: TimeInterval = 4) -> [String: Any]? {
    let c = loadControl()
    guard let url = URL(string: "http://\(c.bind)\(path)") else { return nil }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(c.secret)", forHTTPHeaderField: "Authorization")
    var result: [String: Any]?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200 {
            result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return result
}

func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? s }

/// First emoji flag (two regional-indicator scalars) of a server name, e.g. "🇺🇸 США N1" -> "🇺🇸".
func flag(of name: String) -> String? {
    let sc = Array(name.unicodeScalars)
    guard sc.count >= 2, (0x1F1E6...0x1F1FF).contains(sc[0].value), (0x1F1E6...0x1F1FF).contains(sc[1].value) else { return nil }
    return String(String.UnicodeScalarView([sc[0], sc[1]]))
}

struct Status {
    var up = false
    var node = ""
    var chain = ""
    var pingMs: Int? = nil
    var mode = ""
    var primary = ""
    var title: String { !up ? "🔴" : (pingMs == nil ? "🔴" : (flag(of: node) ?? "🟢")) }
}

func readStatus() -> Status {
    var s = Status()
    guard let cfg = api("/configs") else { return s }
    s.up = true
    s.mode = (cfg["mode"] as? String) ?? ""
    var node = "PROXY"; var chain = ["PROXY"]
    for _ in 0..<5 {
        guard let p = api("/proxies/\(enc(node))"), let next = p["now"] as? String, !next.isEmpty else { break }
        chain.append(next); node = next
    }
    s.node = node; s.chain = chain.joined(separator: " → ")
    if node == "DIRECT" || node == "PROXY" { s.pingMs = 0; return s }
    // No probe of our own: mihomo's groups already measure the node, and an extra probe from here
    // would add load to a flaky server. Read the history instead; red only after 3 failed in a row.
    let h = history(of: node)
    if let last = h.last(where: { $0 > 0 }), !h.suffix(3).allSatisfy({ $0 == 0 }) || h.count < 3 { s.pingMs = last }
    else if h.isEmpty { s.pingMs = 0 }
    if let pr = api("/proxies/PRIMARY"), let all = pr["all"] as? [String] {
        s.primary = all.first { $0 != "REJECT" } ?? ""
    }
    return s
}

/// Delays (ms, 0 = failed) of mihomo's recent health checks of a node, oldest first.
func history(of node: String) -> [Int] {
    // Subscription servers live in the provider; a single server is a top-level proxy.
    let p = api("/providers/proxies/sub/\(enc(node))") ?? api("/proxies/\(enc(node))")
    return (p?["history"] as? [[String: Any]])?.compactMap { $0["delay"] as? Int } ?? []
}

/// Live throughput from mihomo's /traffic stream (one JSON line per second, bytes/s) — the same
/// number the web panel shows. Always on while the app runs, so the menu has it the moment it opens.
final class TrafficStream: NSObject, URLSessionDataDelegate {
    var up = 0, down = 0, live = false
    private var buffer = Data()
    private var session: URLSession?

    func start() {
        stop()
        let c = loadControl()
        guard let url = URL(string: "http://\(c.bind)/traffic") else { return }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Bearer \(c.secret)", forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        session?.dataTask(with: req).resume()
    }

    func stop() { session?.invalidateAndCancel(); session = nil; live = false; buffer = Data() }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            up = (j["up"] as? NSNumber)?.intValue ?? 0
            down = (j["down"] as? NSNumber)?.intValue ?? 0
            live = true
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { live = false }
}

func rate(_ bytesPerSec: Int) -> String {
    let v = Double(bytesPerSec)
    return v >= 1_048_576 ? String(format: "%.1f MB/s", v / 1_048_576) : String(format: "%.0f KB/s", v / 1024)
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var status = Status()
    let traffic = TrafficStream()
    var speedItem: NSMenuItem?
    var speedTimer: Timer?
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        item.button?.title = "…"
        traffic.start()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            if !self.traffic.live { self.traffic.start() }   // mihomo was restarted or not up yet
            self.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global().async {
            let s = readStatus()
            DispatchQueue.main.async {
                self.status = s
                self.item.button?.title = s.title
                self.item.button?.toolTip = s.up ? s.chain : "mihomo не отвечает"
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ action: Selector? = nil) { menu.addItem(withTitle: t, action: action, keyEquivalent: "").target = self }
        let s = status
        if !s.up {
            add("VPN выключен или mihomo не отвечает")
        } else {
            add("Сервер: \(s.node)")
            add(s.pingMs == nil ? "Ping: таймаут" : (s.pingMs == 0 ? "Ping: —" : "Ping: \(s.pingMs!) ms"))
            add("Режим: \(s.mode)")
            add("Приоритетный: \(s.primary.isEmpty ? "нет" : s.primary)")
        }
        menu.addItem(.separator())
        speedItem = menu.addItem(withTitle: speedTitle(), action: nil, keyEquivalent: "")
        // .common mode: a timer in the default mode does not fire while the menu is open.
        speedTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in self.speedItem?.title = self.speedTitle() }
        RunLoop.main.add(t, forMode: .common)
        speedTimer = t
        if loadControl().ui { add("Открыть панель", #selector(openPanel)) }
        menu.addItem(.separator())
        add("Выход", #selector(quit))
    }

    func speedTitle() -> String {
        traffic.live ? "↓ \(rate(traffic.down))   ↑ \(rate(traffic.up))" : "Скорость: —"
    }

    func menuDidClose(_ menu: NSMenu) { speedTimer?.invalidate(); speedTimer = nil }

    @objc func openPanel() {
        if let u = URL(string: "http://\(loadControl().bind)/ui/") { NSWorkspace.shared.open(u) }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--once") {
    let s = readStatus()
    print("title=\(s.title) up=\(s.up) node=\(s.node) ping=\(s.pingMs.map(String.init) ?? "timeout") mode=\(s.mode) primary=\(s.primary)")
    exit(s.up ? 0 : 1)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
