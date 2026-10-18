//
//  Claude RC — macOS menü çubuğu uygulaması
//  `claude remote-control` sürecini menü çubuğundan başlatır/durdurur.
//

import Cocoa
import IOKit.pwr_mgt
import SwiftUI

// MARK: - Ayar anahtarları

enum Keys {
    static let workDir       = "workDir"
    static let recentDirs    = "recentDirs"
    static let autoStart     = "autoStartOnLaunch"
    static let keepAwake     = "keepAwake"
    static let autoRestart   = "autoRestart"
    static let sessionName   = "sessionName"
    static let settingsExpanded = "settingsExpanded"
}

let agentLabel = "com.safepluspay.claude-rc"

// MARK: - Yardımcılar

/// Tek tırnakla kabuk için güvenli hale getirir.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// ANSI kaçış dizilerini (renk, imleç, OSC bağlantı) temizler.
func stripANSI(_ s: String) -> String {
    var out = s
    let patterns = [
        "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",  // OSC (köprü vb.)
        "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",                   // CSI (renk/imleç)
        "\u{1B}[@-Z\\\\-_]"                               // tekil kaçışlar
    ]
    for p in patterns {
        if let re = try? NSRegularExpression(pattern: p) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
    }
    return out
}

/// "Jane’s Mac mini" -> "janes-mac-mini".
/// claude'un kendi urettigi oturum adlari katı slug ([a-z0-9-]); ozel ad
/// verilecekse ayni bicime uymalı, yoksa telefondaki listeyle eslesmiyor.
func slugify(_ s: String) -> String {
    // Kesme isareti kelimeyi BOLMEZ: "Jane’s" -> "janes" (jane-s degil).
    let noApostrophe = s.replacingOccurrences(of: "[’‘'`´ʼ]", with: "",
                                              options: .regularExpression)
    let folded = noApostrophe.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX")).lowercased()
    var out = ""
    var lastDash = true
    for ch in folded.unicodeScalars {
        if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
            out.unicodeScalars.append(ch); lastDash = false
        } else if !lastDash {
            out.append("-"); lastDash = true
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

/// Ayni dizinde baska sunucu bulundugunda kullanicinin karari.
enum DuplicateChoice { case stopOthers, proceed, cancel }

func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > group,
          let r = Range(m.range(at: group), in: text) else { return nil }
    return String(text[r])
}

// MARK: - Durum

enum RCState {
    case stopped, starting, connected, failed

    var symbol: String {
        switch self {
        case .stopped:   return "antenna.radiowaves.left.and.right.slash"
        case .starting:  return "antenna.radiowaves.left.and.right"
        case .connected: return "antenna.radiowaves.left.and.right"
        case .failed:    return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .stopped:   return "Kapalı"
        case .starting:  return "Bağlanıyor…"
        case .connected: return "Bağlı"
        case .failed:    return "Hata"
        }
    }
}

// MARK: - Süreç yöneticisi

final class RCController: ObservableObject {

    static let shared = RCController()

    private(set) var state: RCState = .stopped
    private(set) var attached = 0
    private(set) var capacity = 0
    private(set) var envURL: String?
    private(set) var lastError: String?
    private(set) var startedAt: Date?

    var onChange: (() -> Void)?

    private var process: Process?
    private var outPipe: Pipe?
    private var sleepAssertion: IOPMAssertionID = 0
    private var userStopped = false
    private var restartAttempts = 0
    private var lineBuffer = ""
    private var logHandle: FileHandle?
    private let logQueue = DispatchQueue(label: "com.safepluspay.claude-rc.log")
    private var recentLines: [String] = []
    private var bytesWritten: UInt64 = 0
    private let maxLogBytes: UInt64 = 512_000
    private let keepOnRotate: UInt64 = 64_000

    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeRC.log")

    var isRunning: Bool { process?.isRunning ?? false }

    var workDir: String {
        get { UserDefaults.standard.string(forKey: Keys.workDir) ?? NSHomeDirectory() + "/www" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.workDir) }
    }

    /// Ozel oturum adi. BOS ise `--name` hic gecilmez ve claude, terminalde
    /// `claude rc` yazildigindaki adin aynisini uretir. Doldurulursa slug'a
    /// cevrilir. Varsayilan: bos.
    var customName: String {
        slugify(UserDefaults.standard.string(forKey: Keys.sessionName) ?? "")
    }

    /// Sunucunun bildirdigi oturum adi (telefonda bunu ararsiniz).
    private(set) var sessionLabel: String?

    /// Ayni dizinde baska sunucu bulunursa AppDelegate'e sorulur.
    var confirmDuplicates: ((Int, String) -> DuplicateChoice)?

    // MARK: claude yolunu bul

    private var cachedClaude: String?

    func resolveClaude() -> String? {
        if let c = cachedClaude { return c }
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.bun/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            cachedClaude = c; return c
        }
        // Son çare: login shell'e sor (nvm/asdf gibi kurulumlar için)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !s.isEmpty { cachedClaude = s; return s }
        return nil
    }

    // MARK: Oksuz surec korumasi
    //
    // Uygulama zorla oldurulurse (pkill, cokme, oturum kapanmasi) macOS
    // applicationWillTerminate'i CALISTIRMAZ; baslattigimiz `claude rc` sahipsiz
    // kalip sonsuza kadar yasar ve telefondaki listede hayalet ortam birakir.
    // Cozum: cocugun PID'ini diske yaz, acilista kalmis olani temizle.

    private var pidFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeRC/child.pid")
    }

    private func writePidFile(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: pidFileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? String(pid).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func clearPidFile() { try? FileManager.default.removeItem(at: pidFileURL) }

    /// PID gercekten bizim baslattigimiz turden bir surec mi?
    /// (PID geri donusumu yuzunden alakasiz bir sureci oldurmemek icin sart.)
    private func looksLikeRCServer(_ pid: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let cmd = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return cmd.contains("claude") && (cmd.contains("remote-control") || cmd.contains(" rc"))
    }

    /// Onceki calismadan kalmis oksuz sunucuyu kapatir.
    @discardableResult
    func reapOrphan() -> Bool {
        defer { clearPidFile() }
        guard let raw = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0, looksLikeRCServer(pid) else { return false }
        kill(pid, SIGTERM)
        logDirect("\n=== \(stamp()) · önceki çalışmadan kalan öksüz sunucu kapatıldı (pid \(pid)) ===\n")
        return true
    }

    /// Sinyal geldiginde cagrilir: cocugu oldurup DONER (async degil).
    func stopSync() {
        userStopped = true
        releaseSleepAssertion()
        if let p = process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        clearPidFile()
    }

    // MARK: Ayni dizindeki diger sunucular

    /// Ayni calisma dizininde calisan diger `claude rc` sunucularinin PID'leri.
    /// Surecin cwd'sini `lsof` ile okur; kendi surecimizi haric tutar.
    func otherServers(inDir dir: String) -> [Int32] {
        let mine = process?.processIdentifier ?? -1
        let script = """
        for p in $(pgrep -f 'claude (rc|remote-control)' 2>/dev/null); do
          d=$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
          [ "$d" = \(shq(dir)) ] && echo $p
        done
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != mine && $0 != getpid() }
    }

    // MARK: Başlat / Durdur

    func start(interactive: Bool = false) {
        guard !isRunning else { return }
        guard let claude = resolveClaude() else {
            fail("`claude` komutu bulunamadı. Homebrew ile kurulu mu?")
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workDir, isDirectory: &isDir), isDir.boolValue else {
            // Ilk acilista (ozellikle baska bir makinede) kayitli dizin
            // bulunmayabilir; kullaniciya ne yapacagini soyle.
            fail("Çalışma dizini yok. Panelden “Çalışma dizini › Klasör Seç…” ile bir proje klasörü seçin.")
            return
        }

        // Ayni dizindeki her rc sunucusu telefonda AYRI bir ortam olarak gorunur.
        // Ust uste binince hangisinin hangisi oldugu ayirt edilemez hale gelir.
        var dupWarning: String?
        let others = otherServers(inDir: workDir)
        if !others.isEmpty {
            if interactive, let ask = confirmDuplicates {
                switch ask(others.count, workDir) {
                case .stopOthers: for pid in others { kill(pid, SIGTERM) }
                case .proceed:    dupWarning = "Bu dizinde \(others.count) sunucu daha çalışıyor."
                case .cancel:     return
                }
            } else {
                dupWarning = "Bu dizinde \(others.count) sunucu daha çalışıyor."
            }
        }

        userStopped = false
        lastError = nil
        envURL = nil
        attached = 0
        capacity = 0
        lineBuffer = ""
        sessionLabel = nil
        state = .starting
        startedAt = Date()

        openLog()
        appendLog("\n=== \(stamp()) · başlatılıyor · \(workDir) ===\n")
        if let w = dupWarning {
            lastError = w
            appendLog("\(stamp())  UYARI: \(w)\n")
        }

        // `--name` SADECE slug bicimde gecilir. Once "Jane’s Mac mini" (bosluk,
        // buyuk harf, U+2019 kesme isareti) geciliyordu; claude'un kendi urettigi
        // adlar ise kati [a-z0-9-] slug. Ad bos birakilirsa bayrak hic gecilmez ve
        // claude terminaldekiyle ayni rastgele adi uretir.
        var cmd = "cd \(shq(workDir)) && exec \(shq(claude)) remote-control"
        if !customName.isEmpty { cmd += " --name \(shq(customName))" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_RC_MENUBAR"] = "1"
        // TTY olmadigi icin TUI dar bir genislik varsayip oturum adini "…" ile
        // kesiyordu; kesik ad telefondaki adla eslestirilemez.
        env["COLUMNS"] = "200"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        outPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { fh.readabilityHandler = nil; return }
            self?.ingest(data)
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleExit(status: proc.terminationStatus) }
        }

        do {
            try p.run()
            process = p
            writePidFile(p.processIdentifier)
            if UserDefaults.standard.bool(forKey: Keys.keepAwake) { acquireSleepAssertion() }
        } catch {
            fail("Başlatılamadı: \(error.localizedDescription)")
            return
        }
        notifyChange()
    }

    func stop() {
        userStopped = true
        restartAttempts = 0
        releaseSleepAssertion()
        if let p = process, p.isRunning {
            appendLog("\n=== \(stamp()) · durduruluyor ===\n")
            p.terminate()
            // 3 sn içinde kapanmazsa zorla
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak p] in
                if let p = p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        } else {
            state = .stopped
            notifyChange()
        }
    }

    func restart() {
        if isRunning {
            userStopped = true
            process?.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.start() }
        } else {
            start()
        }
    }

    // MARK: Çıktı işleme

    private func ingest(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        let clean = stripANSI(chunk)
        logFiltered(clean)
        DispatchQueue.main.async { [weak self] in self?.parse(clean) }
    }

    private func parse(_ text: String) {
        lineBuffer += text
        if lineBuffer.count > 8000 { lineBuffer = String(lineBuffer.suffix(4000)) }

        var changed = false

        if let cap = firstMatch(#"Capacity:\s*(\d+)\s*/\s*(\d+)"#, in: lineBuffer, group: 1),
           let tot = firstMatch(#"Capacity:\s*(\d+)\s*/\s*(\d+)"#, in: lineBuffer, group: 2),
           let a = Int(cap), let t = Int(tot) {
            if a != attached || t != capacity { attached = a; capacity = t; changed = true }
        }

        if let url = firstMatch(#"(https://claude\.ai/code\?environment=[A-Za-z0-9_\-]+)"#, in: lineBuffer),
           url != envURL {
            envURL = url; changed = true
        }

        // Sunucunun urettigi oturum adi: tamami kucuk harf, 3+ parcali slug.
        if let name = firstMatch(#"(?m)^[ \t]*([a-z0-9]+(?:-[a-z0-9]+){2,})[ \t]*$"#, in: lineBuffer),
           name != sessionLabel {
            sessionLabel = name; changed = true
        }

        if lineBuffer.contains("Connected") && state != .connected {
            state = .connected; lastError = nil; restartAttempts = 0; changed = true
        } else if lineBuffer.contains("Connecting") && state == .stopped {
            state = .starting; changed = true
        }

        let lower = lineBuffer.lowercased()
        for needle in ["not logged in", "log in", "unauthorized", "subscription", "trust"] {
            if lower.contains(needle), state != .connected {
                lastError = "Oturum/izin sorunu olabilir — logu kontrol edin."
                changed = true
                break
            }
        }

        if changed { notifyChange() }
    }

    private func handleExit(status: Int32) {
        process = nil
        clearPidFile()
        outPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        releaseSleepAssertion()
        appendLog("\n=== \(stamp()) · süreç sonlandı (kod \(status)) ===\n")
        closeLog()

        if userStopped {
            state = .stopped
            attached = 0; capacity = 0; envURL = nil
            notifyChange()
            return
        }

        // Beklenmedik çıkış
        if UserDefaults.standard.bool(forKey: Keys.autoRestart), restartAttempts < 5 {
            restartAttempts += 1
            state = .starting
            lastError = "Beklenmedik çıkış, yeniden deneniyor (\(restartAttempts)/5)…"
            notifyChange()
            let delay = Double(restartAttempts) * 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.userStopped else { return }
                self.start()
            }
        } else {
            state = .failed
            lastError = "Süreç sonlandı (kod \(status)). Logu kontrol edin."
            attached = 0; capacity = 0; envURL = nil
            notifyChange()
        }
    }

    private func fail(_ msg: String) {
        state = .failed
        lastError = msg
        appendLog("\(stamp())  HATA: \(msg)\n")
        notifyChange()
    }

    private func notifyChange() {
        if Thread.isMainThread { onChange?() }
        else { DispatchQueue.main.async { [weak self] in self?.onChange?() } }
    }

    // MARK: Uyku engelleme

    func acquireSleepAssertion() {
        guard sleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Claude RC bağlı" as CFString,
                                    &sleepAssertion)
    }

    func releaseSleepAssertion() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }

    func refreshSleepSetting() {
        if UserDefaults.standard.bool(forKey: Keys.keepAwake) && isRunning { acquireSleepAssertion() }
        else { releaseSleepAssertion() }
    }

    // MARK: Log
    //
    // `claude rc` bir TUI: ekrani silip ayni 5-6 satiri saniyede bir yeniden cizer.
    // Ham dokseydik log gunde ~29 MB buyurdu. Iki kademe koruyor:
    //   1) Yakin gecmiste gorulmus satiri hic yazma -> duragan halde yazma olmaz
    //   2) Yine de buyurse yazma aninda kirp -> dosya asla tavani gecmez

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func stamp() -> String { RCController.stampFmt.string(from: Date()) }

    private func openLog() {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: self.logURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !fm.fileExists(atPath: self.logURL.path) {
                fm.createFile(atPath: self.logURL.path, contents: nil)
            }
            self.logHandle = try? FileHandle(forWritingTo: self.logURL)
            self.bytesWritten = (try? self.logHandle?.seekToEnd()) ?? 0
            self.recentLines.removeAll()
            if self.bytesWritten > self.maxLogBytes { self.rotateLog() }
        }
    }

    private func closeLog() {
        logQueue.async { [weak self] in
            try? self?.logHandle?.close()
            self?.logHandle = nil
        }
    }

    /// Yakin zamanda yazilmis satirlari eleyip zaman damgasiyla loglar.
    private func logFiltered(_ clean: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            var out = ""
            for raw in clean.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if self.recentLines.contains(line) { continue }
                self.recentLines.append(line)
                if self.recentLines.count > 16 { self.recentLines.removeFirst() }
                out += self.stamp() + "  " + line + "\n"
            }
            if !out.isEmpty { self.writeRaw(Data(out.utf8)) }
        }
    }

    /// Log dosyasi acik olmasa da tek seferlik satir ekler.
    private func logDirect(_ s: String) {
        logQueue.async { [weak self] in
            guard let self = self, self.logHandle == nil else {
                self?.writeRaw(Data(s.utf8)); return
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: self.logURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !fm.fileExists(atPath: self.logURL.path) {
                fm.createFile(atPath: self.logURL.path, contents: nil)
            }
            if let h = try? FileHandle(forWritingTo: self.logURL) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(s.utf8))
                try? h.close()
            }
        }
    }

    private func appendLog(_ s: String) {
        logQueue.async { [weak self] in self?.writeRaw(Data(s.utf8)) }
    }

    /// Yalnizca logQueue uzerinde cagrilir.
    private func writeRaw(_ d: Data) {
        guard let h = logHandle else { return }
        try? h.write(contentsOf: d)
        bytesWritten += UInt64(d.count)
        if bytesWritten > maxLogBytes { rotateLog() }
    }

    /// Yalnizca logQueue uzerinde cagrilir. Son `keepOnRotate` bayti korur.
    private func rotateLog() {
        try? logHandle?.close()
        logHandle = nil
        var tail = Data()
        if let fh = try? FileHandle(forReadingFrom: logURL) {
            let size = (try? fh.seekToEnd()) ?? 0
            if size > keepOnRotate { try? fh.seek(toOffset: size - keepOnRotate) }
            tail = (try? fh.readToEnd()) ?? Data()
            try? fh.close()
        }
        let header = Data("=== \(stamp()) · log kirpildi (tavan \(maxLogBytes / 1024) KB) ===\n".utf8)
        try? (header + tail).write(to: logURL)
        logHandle = try? FileHandle(forWritingTo: logURL)
        bytesWritten = (try? logHandle?.seekToEnd()) ?? 0
    }
}

// MARK: - Girişte otomatik başlatma (LaunchAgent)

enum LoginItem {

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Plist'te kayıtlı yol ile uygulamanın gerçek yolu uyuşuyor mu?
    static var registeredPath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let args = obj["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    static func set(_ enabled: Bool) {
        let fm = FileManager.default
        let uid = getuid()
        if enabled {
            guard let exec = Bundle.main.executablePath else { return }
            let dict: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [exec],
                "RunAtLoad": true,
                "KeepAlive": false,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
            launchctl(["bootout", "gui/\(uid)/\(agentLabel)"])
            launchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        } else {
            launchctl(["bootout", "gui/\(uid)/\(agentLabel)"])
            try? fm.removeItem(at: plistURL)
        }
    }

    /// Uygulama taşındıysa kaydı tazele.
    static func repairIfMoved() {
        guard isEnabled, let exec = Bundle.main.executablePath else { return }
        if registeredPath != exec { set(true) }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    let rc = RCController.shared
    private var signalSources: [DispatchSourceSignal] = []
    private lazy var popover = makePopover()

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Tek örnek garantisi (launchd + elle açma çakışmasın).
        // ONEMLI: bir onceki kopya KAPANMAKTA olabilir -- temiz kapanis, cocugu
        // beklerken 2 sn'ye kadar surer. Hemen pes edersek guncelleme sirasinda
        // (eski kopya pkill'lenir, yenisi hemen acilir) yeni kopya kendini
        // oldurur ve ortada hic uygulama kalmaz. O yuzden bekleyip tekrar bak.
        if otherInstanceAlive() {
            Thread.sleep(forTimeInterval: 3.0)
            if otherInstanceAlive() { NSApp.terminate(nil); return }
        }

        UserDefaults.standard.register(defaults: [
            Keys.autoStart: true,
            Keys.keepAwake: true,
            Keys.autoRestart: true,
            Keys.workDir: NSHomeDirectory() + "/www",
            Keys.sessionName: slugify(Host.current().localizedName ?? "mac"),
        ])

        LoginItem.repairIfMoved()
        installSignalHandlers()

        // Uygulama gecen sefer zorla kapatildiysa `claude rc` cocugu sag kalmis
        // olabilir; telefondaki listede hayalet ortam birakmasin diye kapat.
        rc.reapOrphan()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        rc.onChange = { [weak self] in self?.updateUI() }
        rc.confirmDuplicates = { [weak self] count, dir in
            self?.askAboutDuplicates(count: count, dir: dir) ?? .proceed
        }
        updateUI()

        if UserDefaults.standard.bool(forKey: Keys.autoStart) {
            // Girişte ağ hazır olmayabilir; kısa bir nefes payı bırak
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.rc.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        rc.stopSync()
    }

    /// Baska bir (kapanmakta olmayan) kopya calisiyor mu?
    private func otherInstanceAlive() -> Bool {
        let me = Bundle.main.bundleIdentifier ?? agentLabel
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: me)
            .contains { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// SIGTERM/SIGINT/SIGHUP varsayilan olarak sureci ANINDA oldurur ve
    /// applicationWillTerminate calismaz -> cocuk oksuz kalir. Sinyalleri
    /// yok sayip kendi elimizle temiz kapaniyoruz.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.rc.stopSync()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Görünüm

    func updateUI() {
        rc.objectWillChange.send()
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(systemSymbolName: rc.state.symbol, accessibilityDescription: "Claude RC")?
            .withSymbolConfiguration(cfg)
        button.image?.isTemplate = true

        switch rc.state {
        case .connected:
            button.title = rc.attached > 0 ? " \(rc.attached)" : ""
            button.alphaValue = 1.0
        case .starting:
            button.title = " …"
            button.alphaValue = 0.65
        case .stopped:
            button.title = ""
            button.alphaValue = 0.55
        case .failed:
            button.title = ""
            button.alphaValue = 1.0
        }

        button.toolTip = "Claude RC — \(rc.state.label) · \((rc.workDir as NSString).lastPathComponent)"
    }

    private func makePopover() -> NSPopover {
        let host = NSHostingController(rootView: PanelView(app: self, rc: rc))
        host.sizingOptions = [.preferredContentSize]
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = host
        return p
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }
        guard let button = statusItem.button else { return }
        rc.objectWillChange.send()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePanel() {
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: Eylemler

    func toggleRC() { rc.isRunning ? rc.stop() : rc.start(interactive: true) }

    func restartRC() { rc.restart() }

    /// Ayni dizinde baska sunucular varken ne yapilacagini sorar.
    func askAboutDuplicates(count: Int, dir: String) -> DuplicateChoice {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Bu dizinde zaten \(count) RC sunucusu çalışıyor"
        a.informativeText = """
        Her sunucu telefonda ayrı bir ortam olarak görünür; üst üste binince \
        hangisinin hangisi olduğunu ayırt etmek zorlaşır.

        \(dir)
        """
        a.addButton(withTitle: "Diğerlerini kapat, başlat")
        a.addButton(withTitle: "Yine de başlat")
        a.addButton(withTitle: "Vazgeç")
        switch a.runModal() {
        case .alertFirstButtonReturn:  return .stopOthers
        case .alertSecondButtonReturn: return .proceed
        default:                       return .cancel
        }
    }

    func chooseDir() {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rc.workDir)
        panel.prompt = "Seç"
        panel.message = "Claude RC'nin çalışacağı klasörü seçin"
        if panel.runModal() == .OK, let url = panel.url { setWorkDir(url.path) }
    }

    func setWorkDir(_ path: String) {
        guard path != rc.workDir || !rc.isRunning else { return }
        let wasRunning = rc.isRunning
        rc.workDir = path
        var dirs = UserDefaults.standard.stringArray(forKey: Keys.recentDirs) ?? []
        dirs.removeAll { $0 == path }
        dirs.insert(path, at: 0)
        UserDefaults.standard.set(Array(dirs.prefix(8)), forKey: Keys.recentDirs)
        if wasRunning { rc.restart() } else { updateUI() }
    }

    func saveSessionName(_ name: String) {
        UserDefaults.standard.set(slugify(name), forKey: Keys.sessionName)
        if rc.isRunning { rc.restart() } else { updateUI() }
    }

    func copySessionName() {
        if let label = rc.sessionLabel { copyToPasteboard(label) }
    }

    func openEnv() {
        if let u = rc.envURL, let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }

    func copyEnv() {
        if let u = rc.envURL { copyToPasteboard(u) }
    }

    func setLoginItem(_ enabled: Bool) {
        LoginItem.set(enabled)
        updateUI()
    }

    func setFlag(_ key: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
        if key == Keys.keepAwake { rc.refreshSleepSetting() }
        updateUI()
    }

    func showLog() {
        closePanel()
        NSWorkspace.shared.open(rc.logURL)
    }

    func showAbout() {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Claude RC"
        let claudePath = rc.resolveClaude() ?? "bulunamadı"
        a.informativeText = """
        Menü çubuğundan `claude remote-control` sürecini yönetir. \
        Süreç açıkken telefondan veya claude.ai/code üzerinden bu Mac'e bağlanabilirsiniz.

        Dizin: \(rc.workDir)
        Oturum adı: \(rc.sessionLabel ?? (rc.customName.isEmpty ? "otomatik (claude üretir)" : rc.customName))
        claude: \(claudePath)
        Log: \(rc.logURL.path)
        Giriş öğesi: \(LoginItem.isEnabled ? LoginItem.plistURL.path : "kapalı")
        """
        a.addButton(withTitle: "Tamam")
        a.runModal()
    }

    func quit() { NSApp.terminate(nil) }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

enum Theme {
    static let accent     = Color(hex: 0xD97757)
    static let accentDeep = Color(hex: 0xAD715D)
    static let success    = Color(hex: 0x10B981)
    static let warning    = Color(hex: 0xF59E0B)
    static let danger     = Color(hex: 0xEF4444)
    static let idle       = Color(hex: 0x9CA3AF)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16

    static let radius: CGFloat = 8
    static let radiusLarge: CGFloat = 12

    static let fast = 0.15
    static let panelWidth: CGFloat = 320
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension RCState {
    var tint: Color {
        switch self {
        case .stopped:   return Theme.idle
        case .starting:  return Theme.warning
        case .connected: return Theme.success
        case .failed:    return Theme.danger
        }
    }
}

struct PanelView: View {
    let app: AppDelegate
    @ObservedObject var rc: RCController
    @AppStorage(Keys.settingsExpanded) private var settingsExpanded = false
    @State private var nameDraft = UserDefaults.standard.string(forKey: Keys.sessionName) ?? ""
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            header
            statusCard
            if rc.state != .failed, let warning = rc.lastError { banner(warning) }
            controls
            Divider()
            workspace
            Divider()
            settings
            Divider()
            footer
        }
        .padding(Theme.space4)
        .frame(width: Theme.panelWidth)
    }

    private var header: some View {
        HStack(spacing: Theme.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude RC").font(.system(size: 14, weight: .semibold))
                Text("Remote Control").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(state: rc.state)
        }
    }

    private var statusCard: some View {
        Group {
            switch rc.state {
            case .connected:
                connectedInfo
            case .starting:
                placeholder(icon: nil, title: "Bağlanıyor…",
                            detail: "claude remote-control başlatılıyor.")
            case .stopped:
                placeholder(icon: "antenna.radiowaves.left.and.right.slash", title: "Remote Control kapalı",
                            detail: "Başlatınca telefondan veya claude.ai/code'dan bu Mac'e bağlanabilirsiniz.")
            case .failed:
                placeholder(icon: "exclamationmark.triangle", title: "Bağlantı kurulamadı",
                            detail: rc.lastError ?? "Ayrıntılar logda. Tekrar denemek için Başlat'a basın.")
            }
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface(cornerRadius: Theme.radiusLarge))
    }

    private var connectedInfo: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                fieldTitle("Oturum")
                Spacer()
                if let started = rc.startedAt {
                    Label { Text(started, style: .timer).monospacedDigit() } icon: { Image(systemName: "clock") }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Theme.space2) {
                Text(rc.sessionLabel ?? (rc.customName.isEmpty ? "otomatik" : rc.customName))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if rc.sessionLabel != nil {
                    Button { app.copySessionName(); flash("session") } label: {
                        Image(systemName: copied == "session" ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Oturum adını kopyala")
                }
            }
            if rc.capacity > 0 {
                CapacityBar(value: rc.attached, total: rc.capacity)
                Text("\(rc.attached) / \(rc.capacity) oturum bağlı")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let url = rc.envURL {
                HStack(spacing: Theme.space1) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(url.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { app.copyEnv(); flash("link") } label: {
                        Image(systemName: copied == "link" ? "checkmark" : "doc.on.doc")
                    }
                    .help("Linki kopyala")
                    Button(action: app.openEnv) { Image(systemName: "arrow.up.right.square") }
                        .help("Tarayıcıda aç")
                }
                .buttonStyle(GhostButtonStyle())
                .padding(.leading, Theme.space2)
                .padding(.trailing, 2)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.radius - 2, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func placeholder(icon: String?, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space3) {
            Group {
                if let icon {
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(rc.state.tint)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(message)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.space3)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.warning.opacity(0.12)))
    }

    private var controls: some View {
        HStack(spacing: Theme.space2) {
            Button(action: app.toggleRC) {
                Label(rc.isRunning ? "Durdur" : "Başlat", systemImage: rc.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SoftButtonStyle(tint: rc.isRunning ? Theme.danger : Theme.accent, prominent: !rc.isRunning))
            .keyboardShortcut("s")

            Button(action: app.restartRC) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(SoftButtonStyle(tint: .primary))
                .disabled(!rc.isRunning)
                .keyboardShortcut("r")
                .help("Yeniden başlat")
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            fieldTitle("Çalışma dizini")
            Menu {
                ForEach(recentDirs, id: \.self) { dir in
                    Toggle(abbreviate(dir), isOn: Binding(get: { dir == rc.workDir },
                                                          set: { _ in app.setWorkDir(dir) }))
                }
                Divider()
                Button("Klasör Seç…", action: app.chooseDir)
            } label: {
                Label(abbreviate(rc.workDir), systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12))
            .padding(.horizontal, Theme.space3)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(surface(cornerRadius: Theme.radius))

            fieldTitle("Oturum adı")
            HStack(spacing: Theme.space2) {
                TextField("otomatik", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(commitName)
                if nameChanged {
                    Button("Kaydet", action: commitName)
                        .buttonStyle(SoftButtonStyle(tint: Theme.accent, prominent: true, height: 22))
                }
            }
            .padding(.leading, Theme.space3)
            .padding(.trailing, nameChanged ? Theme.space1 : Theme.space3)
            .frame(height: 30)
            .background(surface(cornerRadius: Theme.radius))
            Text(nameHint)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Button {
                withAnimation(.easeOut(duration: Theme.fast)) { settingsExpanded.toggle() }
            } label: {
                HStack {
                    fieldTitle("Ayarlar")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if settingsExpanded {
                settingRow("Girişte otomatik başlat", "Mac açıldığında uygulama da açılır",
                           isOn: Binding(get: { LoginItem.isEnabled }, set: app.setLoginItem))
                settingRow("Açılınca RC'yi başlat", "Uygulama açıldıktan 3 sn sonra",
                           isOn: flag(Keys.autoStart))
                settingRow("Mac boşta uyumasın", "Yalnızca RC çalışırken",
                           isOn: flag(Keys.keepAwake))
                settingRow("Çökerse yeniden dene", "Artan gecikmeyle 5 deneme",
                           isOn: flag(Keys.autoRestart))
            }
        }
    }

    private func settingRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Theme.space2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.space1) {
            Button(action: app.showLog) { Label("Log", systemImage: "doc.text") }
                .keyboardShortcut("l")
                .disabled(!FileManager.default.fileExists(atPath: rc.logURL.path))
            Button(action: app.showAbout) { Label("Hakkında", systemImage: "info.circle") }
            Spacer()
            Button(action: app.quit) { Label("Çıkış", systemImage: "power") }
                .keyboardShortcut("q")
        }
        .buttonStyle(GhostButtonStyle())
        .labelStyle(.titleAndIcon)
    }

    private func fieldTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func surface(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
    }

    private var recentDirs: [String] {
        var dirs = UserDefaults.standard.stringArray(forKey: Keys.recentDirs) ?? []
        if !dirs.contains(rc.workDir) { dirs.insert(rc.workDir, at: 0) }
        return Array(dirs.prefix(8))
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private var nameChanged: Bool { slugify(nameDraft) != rc.customName }

    private var nameHint: String {
        let slug = slugify(nameDraft)
        if slug.isEmpty { return "Boş bırakılırsa claude rastgele bir ad üretir." }
        if slug != nameDraft { return "Kaydedilecek ad: \(slug)" }
        return "claude.ai/code ve telefonda bu adla görünür."
    }

    private func commitName() {
        let changed = nameChanged
        nameDraft = slugify(nameDraft)
        if changed { app.saveSessionName(nameDraft) }
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: key) }, set: { app.setFlag(key, $0) })
    }

    private func flash(_ key: String) {
        copied = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if copied == key { copied = nil } }
    }
}

struct StatusPill: View {
    let state: RCState

    var body: some View {
        HStack(spacing: 5) {
            if state == .starting {
                TimelineView(.animation) { context in
                    dot.opacity(0.35 + 0.65 * abs(sin(context.date.timeIntervalSinceReferenceDate * 3)))
                }
            } else {
                dot
            }
            Text(state.label).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, 3)
        .background(Capsule().fill(state.tint.opacity(0.15)))
    }

    private var dot: some View {
        Circle().fill(state.tint).frame(width: 7, height: 7)
    }
}

struct CapacityBar: View {
    let value: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Theme.accent)
                    .frame(width: geo.size.width * min(1, CGFloat(value) / CGFloat(max(total, 1))))
            }
        }
        .frame(height: 5)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color
    var prominent = false
    var height: CGFloat = 30

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, prominent: prominent, height: height)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let prominent: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, Theme.space3)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(hovering ? 0.16 : 0.1)))
                .brightness(prominent && hovering ? 0.06 : 0)
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: Theme.fast), value: hovering)
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        GhostLabel(configuration: configuration)
    }

    private struct GhostLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .frame(minWidth: 24, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.35))
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: Theme.fast), value: hovering)
        }
    }
}

// MARK: - Giriş noktası

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
