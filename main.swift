import AppKit
import CryptoKit
import UserNotifications

let home = FileManager.default.homeDirectoryForCurrentUser.path
let zshrc = home + "/.zshrc"
let beginMark = "# >>> claude accounts >>>"
let endMark = "# <<< claude accounts <<<"

// MARK: Profiles — zsh aliases that start claude with their own CLAUDE_CONFIG_DIR.

struct Profile {
    let alias: String
    let dir: String
    var isDefault = false
    var displayName: String? { (UserDefaults.standard.dictionary(forKey: "displayNames") as? [String: String])?[dir] }
    var name: String { displayName ?? (isDefault ? "claude (default)" : alias) }
    // The default profile keeps its account file at ~/.claude.json, outside ~/.claude.
    var accountFile: String { isDefault ? home + "/.claude.json" : dir + "/.claude.json" }
    // The signed-in account as Claude Code recorded it in the account file.
    var account: [String: Any]? {
        guard let data = FileManager.default.contents(atPath: accountFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["oauthAccount"] as? [String: Any]
    }
    var email: String? { account?["emailAddress"] as? String }
    // Plan name such as "Max" or "Ultra". The keychain login can't tell Ultra from Max, so this is the signal.
    var plan: String? { account?["planDisplayName"] as? String }
}

// Plans whose accounts have no session limit, so the menu never shows one for them.
let sessionlessPlans: Set<String> = ["Ultra"]

// Real sign-in state from `claude auth status --json`: whether Claude Code considers the profile logged in,
// and whose login it is.
enum SignIn {
    case unknown                                    // the check itself failed
    case signedOut
    case signedIn(email: String?, planTier: String?, subscriptionType: String?)
}

// A login shell puts `claude` on PATH, which a menu bar app doesn't get by default.
func claudeProcess(_ p: Profile, _ args: String) -> Process {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    let config = p.isDefault ? "unset CLAUDE_CONFIG_DIR; " : "CLAUDE_CONFIG_DIR=\(shellQuote(p.dir)) "
    task.arguments = ["-lc", config + "command claude " + args]
    task.standardInput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    return task
}

// Asks Claude Code whether the profile is signed in. This only reads, it doesn't refresh anything.
func checkSignIn(_ p: Profile) -> SignIn {
    let task = claudeProcess(p, "auth status --json")
    let pipe = Pipe()
    task.standardOutput = pipe
    guard (try? task.run()) != nil else { return .unknown }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let loggedIn = json["loggedIn"] as? Bool else { return .unknown }
    guard loggedIn else { return .signedOut }
    return .signedIn(email: json["email"] as? String, planTier: json["planTier"] as? String,
                     subscriptionType: json["subscriptionType"] as? String)
}

func fetchSignIn(_ p: Profile, done: @escaping (SignIn) -> Void) {
    DispatchQueue.global().async { done(checkSignIn(p)) }
}

// Renews an expired login. Claude Code refreshes its token on its next request, and `/usage` is answered
// without a model call, so this costs no tokens. Its output is discarded; the new token is read afterwards.
func renewLogin(_ p: Profile) {
    let task = claudeProcess(p, "-p '/usage' --output-format json --no-session-persistence")
    task.standardOutput = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return }
    task.waitUntilExit()
}

// The plan name: Claude Code's own name from the account file (e.g. "Ultra"), else the tier (e.g. "Max 20x")
// or the subscription (e.g. "Team").
func planName(_ p: Profile, _ sign: SignIn?) -> String? {
    if let name = p.plan { return name }
    guard case .signedIn(_, let tier, let subscription)? = sign else { return nil }
    if let tier, tier.hasPrefix("max_"), tier.hasSuffix("x") {
        return "Max " + String(tier.dropFirst(4).dropLast()) + "x"
    }
    return subscription.map { $0.capitalized }
}

func loadProfiles() -> [Profile] {
    guard let text = try? String(contentsOfFile: zshrc, encoding: .utf8) else { return [] }
    let regex = try! NSRegularExpression(pattern: "^alias ([A-Za-z0-9_-]+)='CLAUDE_CONFIG_DIR=([^ ]+) claude'", options: .anchorsMatchLines)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        Profile(alias: String(text[Range($0.range(at: 1), in: text)!]),
                dir: String(text[Range($0.range(at: 2), in: text)!]))
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

let defaultProfile = Profile(alias: "claude", dir: home + "/.claude", isDefault: true)
let hideDefaultKey = "hideDefaultProfile"
// Listed until removed from the menu, and only while ~/.claude still exists.
var showsDefault: Bool {
    !UserDefaults.standard.bool(forKey: hideDefaultKey) && FileManager.default.fileExists(atPath: defaultProfile.dir)
}

// Signs the default profile out; its folder holds settings and memory, so it is never deleted.
func logOutDefault() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-lc", "unset CLAUDE_CONFIG_DIR; command claude auth logout"]
    do { try task.run(); task.waitUntilExit() } catch { return error.localizedDescription }
    return task.terminationStatus == 0 ? nil : "claude auth logout failed (exit \(task.terminationStatus))."
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func removeProfile(_ p: Profile, deleteFolder: Bool) -> String? {
    guard let text = try? String(contentsOfFile: zshrc, encoding: .utf8) else { return "Couldn't read ~/.zshrc." }
    let kept = text.components(separatedBy: "\n").filter { !$0.hasPrefix("alias \(p.alias)=") }
    do { try kept.joined(separator: "\n").write(toFile: zshrc, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
    if deleteFolder {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: p.dir), resultingItemURL: nil)
        deleteKeychainLogin(p)
    }
    return nil
}

func deleteKeychainLogin(_ p: Profile) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["delete-generic-password", "-s", keychainService(p)]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
}

func setDisplayName(_ name: String, for dir: String) {
    var names = UserDefaults.standard.dictionary(forKey: "displayNames") as? [String: String] ?? [:]
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    names[dir] = trimmed.isEmpty ? nil : trimmed
    UserDefaults.standard.set(names, forKey: "displayNames")
}

// Returns the cleaned alias, or an error message.
func validateAlias(_ raw: String, excluding current: String? = nil) -> Result<String, String> {
    let alias = raw.trimmingCharacters(in: .whitespaces)
    guard alias.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
        return .failure("Alias: use only letters, digits, dashes and underscores.")
    }
    // claude-profiler would map to ~/.claude-profiler, where this app's source may live.
    if ["claude", "claude-accounts", "claude-profiler", "profiler"].contains(alias) { return .failure("\(alias) is reserved.") }
    if alias != current, loadProfiles().contains(where: { $0.alias == alias }) { return .failure("\(alias) already exists.") }
    return .success(alias)
}

// Renames only the alias in ~/.zshrc; the config dir stays put so the login, history and keychain entry keep working.
func renameAlias(_ p: Profile, to new: String) -> String? {
    guard let text = try? String(contentsOfFile: zshrc, encoding: .utf8) else { return "Couldn't read ~/.zshrc." }
    let old = "alias \(p.alias)='CLAUDE_CONFIG_DIR="
    let lines = text.components(separatedBy: "\n").map {
        $0.hasPrefix(old) ? "alias \(new)='CLAUDE_CONFIG_DIR=" + $0.dropFirst(old.count) : $0
    }
    do { try lines.joined(separator: "\n").write(toFile: zshrc, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
    return nil
}

func addProfile(alias raw: String, displayName: String) -> String? {
    let alias: String
    switch validateAlias(raw) {
    case .success(let a): alias = a
    case .failure(let msg): return msg
    }
    let dir = home + "/." + (alias.hasPrefix("claude-") ? alias : "claude-" + alias)
    if FileManager.default.fileExists(atPath: dir + "/.claude.json") { return "\(dir) is already used by another profile." }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // New profiles start from the default profile's instructions and settings, but never its login or history.
    let template = home + "/.claude/"
    let shared = ((try? fm.contentsOfDirectory(atPath: template)) ?? []).filter {
        $0.hasSuffix(".md") || ["settings.json", "skills", "agents", "commands"].contains($0)
    }
    for item in shared where !fm.fileExists(atPath: dir + "/" + item) {
        try? fm.copyItem(atPath: template + item, toPath: dir + "/" + item)
    }
    // First profile: create ~/.zshrc and the block Claude Profiler manages if they aren't there yet.
    var text = (try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? ""
    if text.range(of: endMark) == nil {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n\(beginMark)\n\(endMark)\n"
    }
    let end = text.range(of: endMark)!
    let line = "alias \(alias)='CLAUDE_CONFIG_DIR=\(dir) claude'\n"
    // Keep the claude-accounts helper last in the block.
    if let helper = text.range(of: "alias claude-accounts=", range: text.startIndex..<end.lowerBound) {
        text.insert(contentsOf: line, at: text[..<helper.lowerBound].endIndex)
    } else {
        text.insert(contentsOf: line, at: end.lowerBound)
    }
    do { try text.write(toFile: zshrc, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
    setDisplayName(displayName, for: dir)
    return nil
}

// MARK: Usage — the same plan limits /usage shows, fetched with each profile's own login.

struct Limit { let label: String; let percent: Int; let severity: String; let resetsAt: Date? }
// signedOut: the account file names a user but the keychain login is gone or was revoked.
enum UsageState { case loaded([Limit]), failed(String), signedOut }

// Claude Code keeps each profile's OAuth login in the keychain, keyed by a hash of its config dir.
func keychainService(_ p: Profile) -> String {
    if p.isDefault { return "Claude Code-credentials" }
    let hex = SHA256.hash(data: Data(p.dir.utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-" + hex.prefix(8)
}

let expiredMessage = "access token expired"
let signedOutMessage = "signed out"
let rateLimitedMessage = "rate limited"

func accessToken(_ p: Profile) -> Result<String, String> {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", keychainService(p), "-w"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return .failure("Keychain unavailable") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return .failure(signedOutMessage) }
    // This app never refreshes the token itself; renewLogin asks Claude Code to do it.
    if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
        return .failure(expiredMessage)
    }
    return .success(token)
}

extension String: @retroactive Error {}

let isoDate: (Any?) -> Date? = { v in
    guard let s = v as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

func parseLimits(_ json: [String: Any]) -> [Limit] {
    if let limits = json["limits"] as? [[String: Any]] {
        return limits.compactMap { l in
            guard let kind = l["kind"] as? String else { return nil }
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let label = switch kind {
                case "session": "Session"
                case "weekly_all": "Weekly"
                case "weekly_scoped": "Weekly · " + (model ?? "scoped")
                default: kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            return Limit(label: label, percent: (l["percent"] as? NSNumber)?.intValue ?? 0,
                         severity: l["severity"] as? String ?? "normal", resetsAt: isoDate(l["resets_at"]))
        }
    }
    // Older response shape.
    return [("five_hour", "Session"), ("seven_day", "Weekly")].compactMap { key, label in
        guard let w = json[key] as? [String: Any], let u = w["utilization"] as? NSNumber else { return nil }
        let pct = u.intValue
        return Limit(label: label, percent: pct, severity: pct >= 90 ? "critical" : pct >= 75 ? "warning" : "normal",
                     resetsAt: isoDate(w["resets_at"]))
    }
}

func fetchUsage(_ p: Profile, done: @escaping (UsageState) -> Void) {
    DispatchQueue.global().async {
        let token: String
        switch accessToken(p) {
        case .success(let t): token = t
        case .failure(expiredMessage):
            renewLogin(p)
            switch accessToken(p) {
            case .success(let t): token = t
            case .failure:
                // Still no valid token. Only a login Claude Code reports as gone counts as signed out;
                // otherwise keep the last numbers and try again on the next round.
                if case .signedOut = checkSignIn(p) { return done(.signedOut) }
                return done(.failed("sign-in not renewed yet, retrying"))
            }
        case .failure(let msg): return done(msg == signedOutMessage ? .signedOut : .failed(msg))
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return done(.failed(err.localizedDescription)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return done(.signedOut) }
            if code == 429 { return done(.failed(rateLimitedMessage)) }
            guard code == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return done(.failed("Usage unavailable (HTTP \(code))"))
            }
            done(.loaded(parseLimits(json)))
        }.resume()
    }
}

func severityColor(_ s: String) -> NSColor {
    switch s {
    case "normal": .systemGreen
    case "warning": .systemOrange
    default: .systemRed
    }
}

// "resets Thu 12 Nov 14:00" in this Mac's time zone, or "resetting" once the time has passed.
func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    if d.timeIntervalSinceNow <= 0 { return "resetting" }
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM HH:mm"
    return "resets " + f.string(from: d)
}

// "in 2h 15m" for a reset within the next day, so the submenu can show the clock time and the countdown.
func countdownText(_ d: Date?) -> String {
    guard let d else { return "" }
    let secs = Int(d.timeIntervalSinceNow)
    guard secs > 0, secs < 86400 else { return "" }
    let h = secs / 3600, m = secs % 3600 / 60
    return "in " + (h > 0 ? "\(h)h \(m)m" : "\(m)m")
}

// Short name for a limit in the menu: "Week", "Sess", "Week · Opus".
func shortLabel(_ l: Limit) -> String {
    l.label.replacingOccurrences(of: "Weekly", with: "Week").replacingOccurrences(of: "Session", with: "Sess")
}

// "Session  ▰▰▰▱▱▱▱▱▱▱  26%  resets in 24m", with the bar and percent in the severity colour.
func limitTitle(_ l: Limit) -> NSAttributedString {
    let color = severityColor(l.severity)
    let filled = min(10, max(0, Int((Double(l.percent) / 10).rounded())))
    let font = NSFont.menuFont(ofSize: 0), mono = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
    let out = NSMutableAttributedString(string: l.label.padding(toLength: 18, withPad: " ", startingAt: 0),
                                        attributes: [.font: mono])
    out.append(NSAttributedString(string: String(repeating: "▰", count: filled), attributes: [.font: mono, .foregroundColor: color]))
    out.append(NSAttributedString(string: String(repeating: "▱", count: 10 - filled), attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
    out.append(NSAttributedString(string: String(format: " %3d%%", l.percent), attributes: [.font: mono, .foregroundColor: color]))
    let reset = [resetText(l.resetsAt), countdownText(l.resetsAt)].filter { !$0.isEmpty }.joined(separator: " · ")
    out.append(NSAttributedString(string: "  " + reset, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    return out
}

func dot(_ color: NSColor, symbol: String = "circle.fill") -> NSImage? {
    NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [color]))
}

// MARK: Terminal, notifications and settings

func runInTerminal(_ command: String, title: String) {
    if FileManager.default.fileExists(atPath: "/Applications/Warp.app") {
        let dir = home + "/.warp/launch_configurations"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let yaml = """
        ---
        name: claude-profiler-login
        windows:
          - tabs:
              - title: "\(title.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'"))"
                layout:
                  cwd: \(home)
                  commands:
                    - exec: \(command)
        """
        try? yaml.write(toFile: dir + "/claude-profiler-login.yaml", atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(URL(string: "warp://launch/claude-profiler-login.yaml")!)
    } else {
        let script = "tell application \"Terminal\" to do script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\"\nactivate application \"Terminal\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

func loginCommand(_ p: Profile) -> String {
    (p.isDefault ? "unset CLAUDE_CONFIG_DIR; " : "CLAUDE_CONFIG_DIR=\(shellQuote(p.dir)) ") + "claude auth login"
}

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    c.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

// The Claude logo (claude.svg in the bundle), as a template image so it matches the menu bar.
func claudeIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "claude", withExtension: "svg"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.size = NSSize(width: 16, height: 16)
    img.isTemplate = true
    return img
}

// MARK: App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var usage: [String: UsageState] = [:]   // keyed by profile dir
    var auth: [String: SignIn] = [:]        // keyed by profile dir; missing until first checked
    var nextAuth: [String: Date] = [:]
    // Per-profile schedule. The usage endpoint rate-limits per account (and Claude Code's own /usage
    // shares that budget), so each profile is checked every 5 minutes and backs off after a 429.
    var nextFetch: [String: Date] = [:]
    var backoff: [String: TimeInterval] = [:]
    let interval: TimeInterval = 300
    var menuOpen = false
    // Live rows while the menu is open, so a refresh updates them in place instead of rebuilding
    // the menu (which would close any submenu under the pointer).
    var rows: [String: (row: NSMenuItem, profile: Profile)] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        item.button?.image = claudeIcon()
        item.autosaveName = "ClaudeProfiler"
        item.behavior = []
        menu.delegate = self
        item.menu = menu
        refreshUsage()
        // .common so it keeps ticking while the menu is open.
        RunLoop.main.add(Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshUsage() }, forMode: .common)
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func allProfiles() -> [Profile] { (showsDefault ? [defaultProfile] : []) + loadProfiles() }

    // Runs every minute; checks sign-in and fetches usage only for the profiles that are due.
    func refreshUsage() {
        let profiles = allProfiles()
        let live = Set(profiles.map(\.dir))
        usage = usage.filter { live.contains($0.key) }
        auth = auth.filter { live.contains($0.key) }
        let now = Date()
        for p in profiles where (nextAuth[p.dir] ?? .distantPast) <= now {
            nextAuth[p.dir] = now + interval
            fetchSignIn(p) { state in DispatchQueue.main.async { self.applySignIn(state, to: p) } }
        }
        for p in profiles where p.email != nil && (nextFetch[p.dir] ?? .distantPast) <= now {
            nextFetch[p.dir] = now + interval
            fetchUsage(p) { state in
                DispatchQueue.main.async { self.apply(state, to: p) }
            }
        }
    }

    func applySignIn(_ state: SignIn, to p: Profile) {
        auth[p.dir] = state
        if case .signedOut = state { checkAlerts(p, .signedOut) }
        if case .signedIn = state { announceSignedIn(p) }
        if menuOpen, let live = rows[p.dir] { fill(live.row, live.profile) }
    }

    func apply(_ state: UsageState, to p: Profile) {
        var state = state
        // Plans without a session limit never show one, even if the usage endpoint sends it.
        if case .loaded(let limits) = state, sessionlessPlans.contains(p.plan ?? "") {
            state = .loaded(limits.filter { $0.label != "Session" })
        }
        if case .failed(rateLimitedMessage) = state {
            let wait = min((backoff[p.dir] ?? interval) * 2, 1800)
            backoff[p.dir] = wait
            nextFetch[p.dir] = Date() + wait
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            state = .failed("usage paused, retrying at " + f.string(from: Date() + wait))
        } else if case .loaded = state {
            backoff[p.dir] = nil
        }
        // A failed refresh keeps the last good numbers instead of wiping them.
        if case .failed = state, case .loaded? = usage[p.dir] { return }
        checkAlerts(p, state)
        usage[p.dir] = state
        if menuOpen, let live = rows[p.dir] {
            fill(live.row, live.profile)
        }
    }

    // MARK: Notifications — approaching 80%, hitting a limit, a limit resetting, logging out, logging back in.
    // Last-seen values persist so a restart neither repeats nor misses an alert.

    // Who an alert is about: the login and plan, so alerts from several accounts can be told apart.
    func accountLine(_ p: Profile) -> String {
        [p.email, planName(p, auth[p.dir])].compactMap { $0 }.joined(separator: " · ")
    }

    // "Resets Thu 12 Nov 14:00", capitalised for the start of a sentence.
    func resetSentence(_ l: Limit) -> String {
        let text = resetText(l.resetsAt)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // A profile that was logged out and is logged in again says so, once.
    func announceSignedIn(_ p: Profile) {
        let d = UserDefaults.standard
        var out = Set(d.stringArray(forKey: "signedOutNotified") ?? [])
        guard out.remove(p.dir) != nil else { return }
        d.set(Array(out), forKey: "signedOutNotified")
        notifyLoggedIn(p)
    }

    func notifyLoggedIn(_ p: Profile) {
        notify("\(p.name) is logged in", "\(accountLine(p)). Usage is tracked again.")
    }

    func checkAlerts(_ p: Profile, _ state: UsageState) {
        let d = UserDefaults.standard
        var seen = d.dictionary(forKey: "seenPercent") as? [String: Int] ?? [:]
        var out = Set(d.stringArray(forKey: "signedOutNotified") ?? [])
        let name = p.name
        let account = accountLine(p)
        switch state {
        case .signedOut:
            if out.insert(p.dir).inserted {
                notify("\(name) is logged out", "\(account). Choose Log In from the menu to sign in again.")
            }
        case .loaded(let limits):
            // Usage arriving means the login works again, so a profile that was logged out is back.
            if out.remove(p.dir) != nil { notifyLoggedIn(p) }
            for l in limits {
                let key = p.dir + "|" + l.label
                defer { seen[key] = l.percent }
                guard let prev = seen[key] else { continue }
                let short = shortLabel(l)
                if prev < 100 && l.percent >= 100 {
                    notify("\(name): \(short) limit reached", "\(account). \(resetSentence(l)).")
                } else if prev < 80 && l.percent >= 80 {
                    notify("\(name): \(short) at \(l.percent)%", "Approaching the limit. \(account). \(resetSentence(l)).")
                } else if prev >= 80 && l.percent < 80 && l.percent < prev {
                    notify("\(name): \(short) limit reset", "Now at \(l.percent)%. \(account). \(resetSentence(l)).")
                }
            }
        case .failed:
            break
        }
        d.set(seen, forKey: "seenPercent")
        d.set(Array(out), forKey: "signedOutNotified")
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        // Check sign-in again on every open, so the rows show what is true now.
        nextAuth = [:]
        refreshUsage()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) { build(menu) }

    func build(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(action("Add Profile", #selector(add), nil))
        insertRows()
    }

    // Profile rows sit above the first separator, so a usage refresh can swap just them without
    // closing an open submenu.
    func insertRows() {
        for (row, _) in rows.values where menu.index(of: row) >= 0 { menu.removeItem(row) }
        rows = [:]
        var index = 0
        let visible = allProfiles()
        if visible.isEmpty {
            let empty = NSMenuItem(title: "No profiles yet", action: nil, keyEquivalent: "")
            empty.subtitle = "Add a profile to sign in to another Claude account"
            empty.image = NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: nil)
            empty.isEnabled = false
            rows["empty"] = (empty, defaultProfile)
            menu.insertItem(empty, at: index)
        }
        for p in visible {
            let row = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
            row.submenu = NSMenu()
            row.submenu?.autoenablesItems = false
            fill(row, p)
            rows[p.dir] = (row, p)
            menu.insertItem(row, at: index)
            index += 1
        }
        menu.insertItem(.separator(), at: index)
    }

    // Sets a row's lines and dot, and refills its submenu (the same NSMenu, so an open one stays open).
    // The subtitle reads login · plan · usage. A login that isn't valid shows Not logged in or Login expired, with a Log In action.
    func fill(_ row: NSMenuItem, _ p: Profile) {
        let sub = row.submenu!
        sub.removeAllItems()
        // The alias is the command you type. The row shows the display name, so the alias goes here.
        let aliasLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        aliasLine.attributedTitle = NSAttributedString(string: "alias " + p.alias, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        aliasLine.isEnabled = false
        sub.addItem(aliasLine)
        sub.addItem(.separator())
        var needsLogin = false
        var login: String?
        var plan: String?
        var status: [String] = []
        var error: String?
        switch auth[p.dir] {
        case nil:
            status = ["checking sign-in…"]
            row.image = dot(.systemGray)
        case .unknown?:
            status = ["couldn't check sign-in"]
            row.image = dot(.systemOrange, symbol: "exclamationmark.circle.fill")
        case .signedOut?:
            error = "Not logged in"
            row.image = dot(.systemRed, symbol: "xmark.circle.fill")
            needsLogin = true
        case .signedIn(let email, _, _)?:
            login = email ?? p.email
            plan = planName(p, auth[p.dir])
            switch usage[p.dir] {
            case .signedOut?:
                error = "Login expired"
                row.image = dot(.systemRed, symbol: "xmark.circle.fill")
                needsLogin = true
            case .loaded(let limits)?:
                // The dot is about the account, not how full the limits are; the bars below show that.
                row.image = dot(.systemGreen)
                // The description line carries the usage: "Week 85% · Sess 21%".
                status = limits.filter { !$0.label.hasPrefix("Weekly · ") || $0.percent > 0 }
                    .map { "\(shortLabel($0)) \($0.percent)%" }
                for l in limits {
                    let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    info.attributedTitle = limitTitle(l)
                    sub.addItem(info)
                }
                sub.addItem(.separator())
            case .failed(let msg)?:
                status = [msg]
                row.image = dot(.systemOrange, symbol: "exclamationmark.circle.fill")
            case nil:
                status = ["loading usage"]
                row.image = dot(.systemGray)
            }
        }
        let parts = [login, plan].compactMap { $0 } + (error.map { [$0] } ?? status)
        let line = parts.joined(separator: " · ")
        row.subtitle = line.isEmpty ? nil : line
        if needsLogin { sub.addItem(action("Log In", #selector(logIn), p)) }
        sub.addItem(action("Copy", #selector(copyAlias), p))
        sub.addItem(action("Edit", #selector(edit), p))
        sub.addItem(action("Remove", p.isDefault ? #selector(logOut) : #selector(remove), p))
    }

    func action(_ title: String, _ sel: Selector, _ obj: Any?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = obj
        return i
    }

    func fail(_ msg: String) { let e = NSAlert(); e.messageText = "Claude Profiler"; e.informativeText = msg; e.runModal() }

    @objc func copyAlias(_ s: NSMenuItem) {
        copyToClipboard((s.representedObject as! Profile).alias + " --dangerously-skip-permissions")
    }

    @objc func logIn(_ s: NSMenuItem) {
        let p = s.representedObject as! Profile
        runInTerminal(loginCommand(p), title: "Log in · " + p.name)
    }
    @objc func logOut(_ s: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Remove the default claude profile?"
        alert.informativeText = "Signs \((s.representedObject as! Profile).email ?? "it") out of plain claude and hides it from this menu (to bring it back: defaults write com.azwedo.claude-profiler hideDefaultProfile -bool NO). Claude Code itself stays installed.\n\nTick the box to also move ~/.claude and ~/.claude.json (settings, skills, memory, history — the template new profiles copy from) to the Trash."
        let box = NSButton(checkboxWithTitle: "Also move ~/.claude to Trash", target: nil, action: nil)
        alert.accessoryView = box
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let p = s.representedObject as! Profile
        UserDefaults.standard.set(true, forKey: hideDefaultKey)
        if p.email != nil, let err = logOutDefault() { fail(err) }
        if box.state == .on {
            deleteKeychainLogin(p)
            for path in [home + "/.claude", home + "/.claude.json"] {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
        }
    }

    @objc func remove(_ s: NSMenuItem) {
        let p = s.representedObject as! Profile
        let alert = NSAlert()
        alert.messageText = "Remove \(p.name)?"
        alert.informativeText = "Removes the alias from ~/.zshrc. Tick the box to also move \(p.dir) (its login and history) to the Trash."
        let box = NSButton(checkboxWithTitle: "Also move config folder to Trash", target: nil, action: nil)
        alert.accessoryView = box
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let err = removeProfile(p, deleteFolder: box.state == .on) { fail(err) }
    }

    // A two-field dialog: display name (free text, optional) and alias (what you type in the terminal).
    func askNames(title: String, info: String, button: String, display: String, alias: String?) -> (display: String, alias: String?)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        func field(_ value: String, _ placeholder: String) -> NSTextField {
            let f = NSTextField(string: value)
            f.placeholderString = placeholder
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return f
        }
        func labelled(_ text: String, _ f: NSTextField) -> NSStackView {
            let s = NSStackView(views: [NSTextField(labelWithString: text), f])
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 4
            return s
        }
        let displayField = field(display, "e.g. Work · Acme")
        let aliasField = alias.map { field($0, "e.g. claude-az-sales") }
        let stack = NSStackView(views: [labelled("Display name", displayField)] + (aliasField.map { [labelled("Alias", $0)] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = aliasField ?? displayField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (displayField.stringValue, aliasField?.stringValue)
    }

    @objc func edit(_ s: NSMenuItem) {
        let p = s.representedObject as! Profile
        guard let names = askNames(
            title: "Edit \(p.name)",
            info: p.isDefault ? "The default profile's alias is always claude; you can set how it's shown here."
                              : "The display name is only shown in this menu. The alias is the command you type; its folder (\(p.dir)) and login stay the same.",
            button: "Save", display: p.displayName ?? "", alias: p.isDefault ? nil : p.alias) else { return }
        if let raw = names.alias, raw.trimmingCharacters(in: .whitespaces) != p.alias {
            switch validateAlias(raw, excluding: p.alias) {
            case .failure(let msg): return fail(msg)
            case .success(let new):
                if let err = renameAlias(p, to: new) { return fail(err) }
                fail("Alias is now \(new). Open a new terminal tab (or run: source ~/.zshrc) to use it.")
            }
        }
        setDisplayName(names.display, for: p.dir)
    }

    @objc func add(_ s: NSMenuItem) {
        guard let names = askNames(title: "New Claude profile",
                                   info: "The alias is the command you type, e.g. claude-az-sales. The display name is optional and only shown in this menu.",
                                   button: "Create", display: "", alias: "claude-") else { return }
        if let err = addProfile(alias: names.alias ?? "", displayName: names.display) { fail(err) }
        else { fail("Added. Open a new terminal tab, run the alias, then /login — or use Log In in this menu.") }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
