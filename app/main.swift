//  Espresso — ARM-native menu-bar supervisor for a Steam library on Apple
//  Silicon: native Mac Steam, or Windows Steam under x86_64 Wine + D3DMetal.
//
//  Games are launched from Steam (D3D11/D3D12 via GPTK). Star Wars Zero
//  Company is a DX12 test title only, not the product scope.
//
//  Build: sh build.sh

import SwiftUI
import Foundation
import AppKit

// MARK: - Layout

struct Layout {
    static let engineName = "WS12WineSikarugir10.0_8"

    let base: URL
    let engine: URL
    let external: URL
    let gptk: URL
    let prefix: URL
    let logs: URL
    let wine: URL
    let wineserver: URL
    let engineTag: URL
    let d3dmetal: URL
    let libd3dshared: URL

    static func live() -> Layout {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Espresso")
        let engine = base.appendingPathComponent("Engines").appendingPathComponent(engineName)
        let external = engine.appendingPathComponent("lib").appendingPathComponent("external")
        return Layout(
            base: base,
            engine: engine,
            external: external,
            gptk: base.appendingPathComponent("GPTK").appendingPathComponent("current"),
            prefix: base.appendingPathComponent("Steam"),
            logs: base.appendingPathComponent("Logs"),
            wine: engine.appendingPathComponent("bin").appendingPathComponent("wine"),
            wineserver: engine.appendingPathComponent("bin").appendingPathComponent("wineserver"),
            engineTag: base.appendingPathComponent("Engines")
                .appendingPathComponent(engineName + ".engine-tag"),
            d3dmetal: external.appendingPathComponent("D3DMetal.framework")
                .appendingPathComponent("Versions").appendingPathComponent("A")
                .appendingPathComponent("D3DMetal"),
            libd3dshared: external.appendingPathComponent("libd3dshared.dylib")
        )
    }

    /// DX12 test title (UE5). Informational doctor check only — Espresso is
    /// a Steam-library supervisor, not a single-game launcher.
    static let dx12TestWindowsPath =
        "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Star Wars Zero Company" +
        "\\SWZeroCompany\\Binaries\\Win64\\SWZeroCompany.exe"

    func dx12TestPOSIXPath() -> String {
        prefix.path + "/drive_c/Program Files (x86)/Steam/steamapps/common/" +
        "Star Wars Zero Company/SWZeroCompany/Binaries/Win64/SWZeroCompany.exe"
    }
}

// MARK: - Doctor check

struct Check: Identifiable {
    let id = UUID()
    let name: String
    let ok: Bool
    let detail: String
}

// MARK: - Supervisor

final class Supervisor: ObservableObject {

    static let shared = Supervisor()

    let layout = Layout.live()

    @Published var checks: [Check] = []
    @Published var doctorPassed = false
    @Published var doctorRan = false
    /// Transient one-line message under the title. Empty means nothing to say.
    @Published var status = ""
    /// "Windows 11" / "Windows 10", as the prefix reports it.
    @Published var windowsVersion = "Windows"
    /// "Wine 10.0 r8 · GPTK 4.0b3" for the pinned engine and overlay.
    @Published var runtimeVersions = ""
    /// Informational: DX12 test title installed in the prefix (not product scope).
    @Published var dx12TestPresent = false
    @Published var isLaunching = false
    @Published var sessionAlive = false
    @Published var macSessionAlive = false

    static let macSteamBundleID = "com.valvesoftware.steam"
    static let macSteamApp = URL(fileURLWithPath: "/Applications/Steam.app")

    private let fm = FileManager.default
    private var wineJobs: [Process] = []
    private var sessionTimer: DispatchSourceTimer?
    private var launchWaitTicks = 0

    // MARK: Environment (Wine + GPTK D3DMetal)

    func wineEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let ext = layout.external.path
        let engLib = layout.engine.appendingPathComponent("lib").path

        env["WINEPREFIX"] = layout.prefix.path
        env["WINEARCH"] = "win64"
        env["WINEDLLOVERRIDES"] = "pdh=n,b;mscoree,mshtml="

        // Item 2: prepend, never replace. The dyld defaults must survive.
        // Must include both external/ (for libd3dshared → D3DMetal) and
        // engine lib/ (for x86_64 libgnutls.30.dylib + libgmp). Without the
        // latter Wine's crypt32/secur32 dlopen fails and Steam's TLS breaks
        // (manifest fetches time out, CM cert checks fail 0x8).
        let existing = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        let add = "\(ext):\(engLib)"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = existing.isEmpty ? add : add + ":" + existing
        // Also set DYLD_LIBRARY_PATH — some Wine dlopens only consult it.
        let existingLib = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = existingLib.isEmpty ? add : add + ":" + existingLib

        // Item 3: absolute override for the D3DMetal dlopen.
        env["D3DMETAL_FRAMEWORK_PATH"] = layout.d3dmetal.path

        // Item 7: keep DXMT/DXVK from replacing d3d12.dll / dxgi.dll.
        env["DXMT_ENABLE"] = "0"
        env["DXVK_ENABLE"] = "0"

        // Item 8: proven load-bearing in 004 section 8. Without it CPUID
        // reports no AVX and UE5 titles refuse to start.
        env["ROSETTA_ADVERTISE_AVX"] = "1"

        env["WINEMSYNC"] = "1"

        var path = env["PATH"] ?? ""
        if !path.contains("/usr/bin") {
            path = "/usr/bin:/bin:/usr/sbin:/sbin" + (path.isEmpty ? "" : ":" + path)
        }
        env["PATH"] = path
        return env
    }

    /// Command line that runs an x86_64 Wine binary under Rosetta with the engine's
    /// library search path intact.
    ///
    /// `/usr/bin/arch` is SIP-protected, so dyld strips every `DYLD_*` variable at that
    /// exec. Newer Sikarugir engines (10.0_7+) ship no `LC_RPATH`, so their wine,
    /// wineserver and unix `.so` files resolve libinotify, FreeType and gnutls only
    /// through `DYLD_FALLBACK_LIBRARY_PATH`. `/usr/bin/env` re-sets it after `arch`
    /// has run, where dyld no longer strips it.
    func archWine(_ exe: String, _ args: [String]) -> (exe: String, args: [String]) {
        let fallback = wineEnvironment()["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        return ("/usr/bin/arch",
                ["-x86_64", "/usr/bin/env", "DYLD_FALLBACK_LIBRARY_PATH=\(fallback)", exe] + args)
    }

    // MARK: Shell helper

    func shell(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        // System helpers (lipo, otool, pgrep) must not inherit Wine DYLD vars — the
        // x86_64 engine lib would poison arm64 tool dyld search.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH")
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func shellWine(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = wineEnvironment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func archs(of url: URL) -> String {
        guard fm.fileExists(atPath: url.path) else { return "" }
        let r = shell("/usr/bin/lipo", ["-archs", url.path])
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Doctor

    func runDoctor() {
        var out: [Check] = []
        let L = layout

        // 1. Engine pin
        let tag = (try? String(contentsOf: L.engineTag, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        out.append(Check(name: "Engine pin",
                         ok: tag == Layout.engineName,
                         detail: tag.isEmpty ? "no tag file at Engines/" : tag))

        // 2. Wine binary present
        let wineOK = fm.fileExists(atPath: L.wine.path)
        out.append(Check(name: "Wine binary",
                         ok: wineOK,
                         detail: wineOK ? Layout.engineName : "missing bin/wine"))

        // 3. D3DMetal.framework exists and is x86_64
        let dmArch = archs(of: L.d3dmetal)
        let dmOK = dmArch.contains("x86_64")
        out.append(Check(name: "D3DMetal.framework",
                         ok: dmOK,
                         detail: dmArch.isEmpty ? "not found in external/" : dmArch))

        // 4. libd3dshared.dylib sits beside the framework and is x86_64.
        //    Section 9: the two MUST share a directory.
        let sharedArch = archs(of: L.libd3dshared)
        let sharedOK = sharedArch.contains("x86_64")
        out.append(Check(name: "libd3dshared.dylib",
                         ok: sharedOK,
                         detail: sharedArch.isEmpty ? "not found in external/" : sharedArch))

        // 5. GPTK overlay in the engine tree: dxgi.so must record
        //    @rpath/libd3dshared.dylib
        let dxgiSo = L.engine.appendingPathComponent("lib/wine/x86_64-unix/dxgi.so")
        var overlayOK = false
        var overlayDetail = "dxgi.so missing"
        if fm.fileExists(atPath: dxgiSo.path) {
            let r = shell("/usr/bin/otool", ["-L", dxgiSo.path])
            overlayOK = r.out.contains("libd3dshared.dylib")
            overlayDetail = overlayOK ? "dxgi.so -> @rpath/libd3dshared.dylib"
                                      : "dxgi.so does not reference libd3dshared"
        }
        out.append(Check(name: "GPTK overlay", ok: overlayOK, detail: overlayDetail))

        // 6. Environment we are about to hand to Wine
        let env = wineEnvironment()
        let dyld = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        let engLib = L.engine.appendingPathComponent("lib").path
        let dyldOK = dyld.contains(L.external.path) && dyld.contains(engLib)
        out.append(Check(name: "DYLD_FALLBACK_LIBRARY_PATH",
                         ok: dyldOK,
                         detail: dyldOK ? "external/ + engine lib/ on path"
                                        : "external/ or engine lib/ missing from DYLD path"))

        let fwPath = env["D3DMETAL_FRAMEWORK_PATH"] ?? ""
        let fwOK = fwPath == L.d3dmetal.path && fm.fileExists(atPath: fwPath)
        out.append(Check(name: "D3DMETAL_FRAMEWORK_PATH",
                         ok: fwOK,
                         detail: fwOK ? "points at bundled framework" : "wrong or missing"))

        // 7. ROSETTA_ADVERTISE_AVX — added after 004 section 8 proved it is
        //    required rather than cosmetic.
        let avxOK = env["ROSETTA_ADVERTISE_AVX"] == "1"
        out.append(Check(name: "ROSETTA_ADVERTISE_AVX",
                         ok: avxOK,
                         detail: avxOK ? "1 (AVX/AVX2 advertised)" : "not set, AVX will be absent"))

        // 8. libinotify — the pinned engine does not ship it and wineserver
        //    links it non-weakly (004 section 3.5).
        let inotify = L.engine.appendingPathComponent("lib/libinotify.0.dylib")
        let inotifyOK = fm.fileExists(atPath: inotify.path)
        out.append(Check(name: "libinotify.0.dylib",
                         ok: inotifyOK,
                         detail: inotifyOK ? "present in engine lib/" : "missing, wineserver will not start"))

        // 8b. TLS stack — x86_64 gnutls + gmp (005 §2). Missing = Steam WebSocket/cert 0x8 + manifest timeout.
        let gnutls = L.engine.appendingPathComponent("lib/libgnutls.30.dylib")
        let gnutlsOK = archs(of: gnutls).contains("x86_64")
        out.append(Check(name: "libgnutls.30.dylib",
                         ok: gnutlsOK,
                         detail: gnutlsOK ? "x86_64 present in engine lib/" : "missing x86_64 — Steam TLS will fail (005)"))
        let gmp = L.engine.appendingPathComponent("lib/libgmp.10.dylib")
        let gmpOK = fm.fileExists(atPath: gmp.path)
        out.append(Check(name: "libgmp.10.dylib",
                         ok: gmpOK,
                         detail: gmpOK ? "present in engine lib/" : "missing — libgnutls will not load"))

        // pdh stub — UE5 crashes 0x80000100 at 0s without it (found on the DX12 test title).
        let pdh = L.prefix.appendingPathComponent("drive_c/windows/system32/pdh.dll")
        let pdhOK = fm.fileExists(atPath: pdh.path)
        out.append(Check(name: "pdh stub",
                         ok: pdhOK,
                         detail: pdhOK ? "native stub in system32/ — UE5 will not crash on PdhOpenQuery" : "missing — UE5 titles crash 0x80000100 on PdhOpenQuery"))
        if !pdhOK {
            // Also check registry override is set — otherwise builtin pdh still used.
            let cmd = archWine(L.wine.path, ["reg", "query", "HKCU\\Software\\Wine\\DllOverrides", "/v", "pdh"])
            let r = shellWine(cmd.exe, cmd.args)
            let hasOverride = r.out.localizedCaseInsensitiveContains("native")
            if !hasOverride {
                out[out.count - 1] = Check(name: "pdh stub",
                                           ok: false,
                                           detail: "missing and no HKCU pdh=native override — builtin pdh crashes UE5")
            }
        }

        // 9. Prefix exists and is win64
        let sysreg = L.prefix.appendingPathComponent("system.reg")
        var prefixOK = false
        var prefixDetail = "no prefix"
        if let head = try? String(contentsOf: sysreg, encoding: .utf8).prefix(4096) {
            if let line = head.split(separator: "\n").first(where: { $0.hasPrefix("#arch=") }) {
                let v = line.replacingOccurrences(of: "#arch=", with: "")
                prefixOK = (v == "win64")
                prefixDetail = String(v)
            } else {
                prefixDetail = "no #arch line"
            }
        }
        out.append(Check(name: "Prefix arch", ok: prefixOK, detail: prefixDetail))

        // wineserver must be ours, not CrossOver's
        let ps = shell("/usr/bin/pgrep", ["-fl", "wineserver"])
        let foreign = ps.out.split(separator: "\n").filter {
            $0.localizedCaseInsensitiveContains("CrossOver")
        }
        out.append(Check(name: "No foreign wineserver",
                         ok: foreign.isEmpty,
                         detail: foreign.isEmpty ? "only Espresso wineserver"
                                                 : "CrossOver wineserver running"))

        // DX12 test title present (informational; does not block Steam)
        let present = fm.fileExists(atPath: L.dx12TestPOSIXPath())
        let passed = out.allSatisfy { $0.ok }

        // Always called on the main actor, so publish directly.
        checks = out
        doctorPassed = passed
        doctorRan = true
        dx12TestPresent = present
        windowsVersion = RuntimeInfo.windowsVersion(prefix: L.prefix)
        runtimeVersions = RuntimeInfo.summary(engine: L.engine, external: L.external)
    }

    // MARK: Launch

    /// True when *this* prefix has a live Wine session. Do not use a bare
    /// `pgrep -f steam.exe` — wow64 Steam often has no steam.exe in argv,
    /// and the wine wrapper may still be running before wineserver shows up.
    /// Wine-spawned wineserver often has argv0 "wineserver" with no full path,
    /// so path-matching `pgrep -lf` misses it.
    func prefixSessionAlive() -> Bool {
        if wineJobs.contains(where: { $0.isRunning }) { return true }
        return winePrefixBusy()
    }

    /// Wine* processes (wine, wine64, wineserver, wine-preloader) holding our prefix.
    private func winePrefixBusy() -> Bool {
        let r = shell("/usr/sbin/lsof", ["-c", "wine", "-Fn"])
        return r.status == 0 && r.out.contains(layout.prefix.path)
    }

    private func hideSteamHostDylib() -> URL? {
        if let u = Bundle.main.url(forResource: "hide-steam-host", withExtension: "dylib"),
           fm.fileExists(atPath: u.path) {
            return u
        }
        let helper = layout.base.appendingPathComponent("Helpers/hide-steam-host.dylib")
        return fm.fileExists(atPath: helper.path) ? helper : nil
    }

    func steamLogCount() -> Int {
        (try? fm.contentsOfDirectory(atPath: layout.logs.path))?
            .filter { $0.hasPrefix("steam-") && $0.hasSuffix(".log") }.count ?? 0
    }

    func startSessionWatch() {
        guard sessionTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.refreshSession()
        }
        t.resume()
        sessionTimer = t
    }

    func refreshSession() {
        let alive = prefixSessionAlive()
        sessionAlive = alive
        if alive {
            launchWaitTicks = 0
            if isLaunching {
                isLaunching = false
            }
        } else if isLaunching && !macSteamRunning() {
            launchWaitTicks += 1
            if launchWaitTicks >= 30 {
                isLaunching = false
                status = "Steam failed to start (no wineserver)"
            }
        }
        macSessionAlive = macSteamRunning()
        if macSessionAlive && isLaunching {
            isLaunching = false
        }
    }

    @discardableResult
    private func launchWine(_ args: [String], label: String) -> Bool {
        guard fm.fileExists(atPath: layout.wine.path) else {
            DispatchQueue.main.async { self.status = "No Wine binary" }
            return false
        }
        do {
            try fm.createDirectory(at: layout.logs, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { self.status = "Cannot create log dir: \(error)" }
            return false
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let logURL = layout.logs
            .appendingPathComponent("\(label.lowercased())-\(stamp).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: logURL.path) else {
            DispatchQueue.main.async { self.status = "Cannot open log file" }
            return false
        }

        let p = Process()
        let cmd = archWine(layout.wine.path, args)
        p.executableURL = URL(fileURLWithPath: cmd.exe)
        p.arguments = cmd.args
        var env = wineEnvironment()
        // steam.exe is a Wine GUI process with no real window; steamwebhelper
        // owns the Library. Without this, Cmd+Tab shows two "Wine" tiles.
        if label == "Steam", let dylib = hideSteamHostDylib() {
            env["DYLD_INSERT_LIBRARIES"] = dylib.path
        }
        p.environment = env
        p.currentDirectoryURL = layout.engine

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let fh = pipe.fileHandleForReading
        fh.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { try? handle.write(contentsOf: d) }
        }

        p.terminationHandler = { [weak self] proc in
            fh.readabilityHandler = nil
            try? handle.close()
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.wineJobs.removeAll { $0 === proc }
                let alive = self.prefixSessionAlive()
                self.sessionAlive = alive
                if alive {
                    // Wine wrapper exited; Steam continues under wineserver.
                    self.isLaunching = false
                    self.status = "\(label) running"
                } else {
                    self.isLaunching = false
                    self.status = "\(label) exited with \(code)"
                }
            }
        }

        do {
            try p.run()
            wineJobs.append(p)
            DispatchQueue.main.async {
                self.status = "\(label) running, pid \(p.processIdentifier)"
            }
            return true
        } catch {
            fh.readabilityHandler = nil
            try? handle.close()
            DispatchQueue.main.async {
                self.status = "Failed to start \(label): \(error.localizedDescription)"
                self.isLaunching = false
                self.sessionAlive = self.prefixSessionAlive()
            }
            return false
        }
    }

    private func isRunning(_ name: String) -> Bool {
        shell("/usr/bin/pgrep", ["-f", name]).status == 0
    }

    func macSteamInstalled() -> Bool {
        fm.fileExists(atPath: Self.macSteamApp.path)
    }

    func macSteamRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.macSteamBundleID).isEmpty
    }

    func stopMacSteamSync() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.macSteamBundleID)
        apps.forEach { $0.terminate() }
        for _ in 0..<25 {
            if !macSteamRunning() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if macSteamRunning() {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.macSteamBundleID)
                .forEach { $0.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    func startMacSteam() {
        if isLaunching || macSteamRunning() {
            DispatchQueue.main.async {
                self.macSessionAlive = true
                self.status = "Mac Steam already running"
            }
            return
        }
        guard macSteamInstalled() else {
            DispatchQueue.main.async { self.status = "No Steam.app in /Applications" }
            return
        }
        isLaunching = true
        launchWaitTicks = 0
        startSessionWatch()
        if prefixSessionAlive() {
            status = "Stopping Windows Steam…"
            stopSync()
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: Self.macSteamApp, configuration: cfg) { [weak self] _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLaunching = false
                self.macSessionAlive = self.macSteamRunning()
                if let err {
                    self.status = "Failed to start Mac Steam: \(err.localizedDescription)"
                } else {
                    self.status = "Mac Steam running"
                }
            }
        }
    }

    func startSteam() {
        if isLaunching || prefixSessionAlive() {
            DispatchQueue.main.async {
                self.sessionAlive = true
                self.status = "Windows Steam already running"
            }
            return
        }
        isLaunching = true
        launchWaitTicks = 0
        startSessionWatch()
        if macSteamRunning() {
            status = "Stopping Mac Steam…"
            stopMacSteamSync()
            macSessionAlive = false
        }
        // Steam: -no-cef-sandbox. Never -cef-force-32bit (removed from current Steam).
        if launchWine(["C:\\Program Files (x86)\\Steam\\steam.exe", "-no-cef-sandbox"],
                      label: "Steam") {
            sessionAlive = true
        } else {
            isLaunching = false
            sessionAlive = prefixSessionAlive()
        }
    }

    /// Launch the DX12 test title (shipping exe, not the Unreal bootstrapper).
    func startDx12TestTitle() {
        if isLaunching || isRunning(Layout.dx12TestWindowsPath) || isRunning("SWZeroCompany.exe") {
            DispatchQueue.main.async { self.status = "DX12 test title already running" }
            return
        }
        isLaunching = true
        if !launchWine([Layout.dx12TestWindowsPath], label: "dx12-test") {
            isLaunching = false
        }
    }

    /// True for the process names Wine gives its own processes: its binaries
    /// (`wine`, `wine-preloader`, `wineserver`, ...) and, because Wine retitles every
    /// Windows program to its Windows path, names such as `C:\\...\\steam.exe`.
    static func isWineProcessName(_ comm: String) -> Bool {
        if comm.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil { return true }
        return URL(fileURLWithPath: comm).lastPathComponent.hasPrefix("wine")
    }

    /// Wine processes that hold a file or directory under this prefix. Selected by
    /// identity first (`isWineProcessName`), then attributed to the prefix by their
    /// open files and cwd, so that unrelated processes are never returned.
    func prefixWineProcessIDs() -> [pid_t] {
        var candidates: [pid_t] = []
        for line in shell("/bin/ps", ["-axo", "pid=,comm="]).out.split(separator: "\n") {
            let f = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            if f.count == 2, let pid = pid_t(f[0]), Self.isWineProcessName(String(f[1])) {
                candidates.append(pid)
            }
        }
        guard !candidates.isEmpty else { return [] }
        // `-F pn`: a "p<pid>" line, then one "n<path>" line per open file.
        let out = shell("/usr/sbin/lsof",
                        ["-a", "-p", candidates.map(String.init).joined(separator: ","), "-Fpn"]).out
        var holders: [pid_t] = [], current: pid_t?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current, !holders.contains(pid),
                    line.dropFirst().hasPrefix(layout.prefix.path) {
                holders.append(pid)
            }
        }
        return holders
    }

    /// Synchronous stop for use on quit; do not dispatch to main.
    func stopSync() {
        let p = Process()
        let cmd = archWine(layout.wineserver.path, ["-k"])
        p.executableURL = URL(fileURLWithPath: cmd.exe)
        p.arguments = cmd.args
        p.environment = wineEnvironment()
        try? p.run()
        p.waitUntilExit()
        // Always sweep, but only Wine processes that belong to *this* prefix, so a
        // second Wine (CrossOver) and unrelated programs (a shell or Finder window
        // that merely has the prefix as cwd) are never touched.
        let holders = prefixWineProcessIDs()
        if !holders.isEmpty || winePrefixBusy() {
            for pid in holders { kill(pid, SIGKILL) }
            _ = shell("/bin/sh", ["-c",
                "pkill -9 -f '\(NSRegularExpression.escapedPattern(for: layout.wineserver.path))' 2>/dev/null; " +
                "pkill -9 -f '\(NSRegularExpression.escapedPattern(for: layout.prefix.path))/.*winedevice' 2>/dev/null"
            ])
        }
        for job in wineJobs {
            if job.isRunning {
                job.terminate()
                job.waitUntilExit()
            }
        }
        wineJobs.removeAll()
        for _ in 0..<30 {
            if !winePrefixBusy() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func stop() {
        stopMacSteamSync()
        stopSync()
        DispatchQueue.main.async {
            self.isLaunching = false
            self.sessionAlive = self.prefixSessionAlive()
            self.macSessionAlive = self.macSteamRunning()
            self.status = "Stopped Steam"
        }
    }

    func openPrefix() {
        NSWorkspace.shared.open(layout.prefix)
    }

    func openMacSteamFolder() {
        let url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam")
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else if macSteamInstalled() {
            NSWorkspace.shared.open(Self.macSteamApp.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { self.status = "No Mac Steam folder" }
        }
    }

    func openLogs() {
        try? fm.createDirectory(at: layout.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(layout.logs)
    }
}

// MARK: - Version

enum AppVersion {
    static var line: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short)  build \(build)"
    }
}

// MARK: - Runtime versions

/// What the menu shows under the Windows row. Everything is read from files
/// on disk, so it describes what Wine will actually load.
enum RuntimeInfo {
    /// "Windows 11" or "Windows 10", from the version Wine records in the prefix.
    /// Wine keeps writing the product name "Windows 10 Pro" for Windows 11 and
    /// only raises the build number, so the build decides (22000 and up is 11).
    static func windowsVersion(prefix: URL) -> String {
        guard let reg = try? String(contentsOf: prefix.appendingPathComponent("system.reg"),
                                    encoding: .utf8) else { return "Windows" }
        let header = "[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion]"
        var inSection = false
        var build: Int?
        var product: String?
        for line in reg.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("[") {
                if inSection { break }
                inSection = line.hasPrefix(header)
            } else if inSection {
                if let v = stringValue(line, key: "CurrentBuildNumber") { build = Int(v) }
                else if let v = stringValue(line, key: "ProductName") { product = v }
            }
        }
        if let build, build >= 22000 { return "Windows 11" }
        // "Windows 10 Pro" -> "Windows 10"
        if let product, product.hasPrefix("Windows ") {
            return product.split(separator: " ").prefix(2).joined(separator: " ")
        }
        return "Windows"
    }

    /// `"Key"="value"` -> `value`
    private static func stringValue(_ line: Substring, key: String) -> String? {
        let prefix = "\"\(key)\"=\""
        guard line.hasPrefix(prefix), line.hasSuffix("\"") else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }

    /// "Wine 10.0 r8" from the engine's `version` file ("wine sikarugir 10.0 (revision 8)").
    static func wineVersion(engine: URL) -> String {
        guard let text = try? String(contentsOf: engine.appendingPathComponent("version"),
                                     encoding: .utf8) else { return "Wine" }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, words[0] == "wine" else { return "Wine" }
        var s = "Wine \(words[2])"
        if words.count >= 5, words[3] == "(revision" { s += " r\(words[4].dropLast())" }
        return s
    }

    /// "4.0b3" from the overlaid D3DMetal framework.
    static func gptkVersion(external: URL) -> String? {
        let plist = external.appendingPathComponent(
            "D3DMetal.framework/Versions/A/Resources/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
    }

    /// "Wine 10.0 r8 · GPTK 4.0b3"
    static func summary(engine: URL, external: URL) -> String {
        var parts = [wineVersion(engine: engine)]
        if let g = gptkVersion(external: external) { parts.append("GPTK \(g)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Marks

struct WindowsMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let gap = max(1, s * 0.12)
            let cell = (s - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Rectangle().fill(Color.primary)
                    Rectangle().fill(Color.primary)
                }
                HStack(spacing: gap) {
                    Rectangle().fill(Color.primary)
                    Rectangle().fill(Color.primary)
                }
            }
            .frame(width: cell * 2 + gap, height: cell * 2 + gap)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Windows")
    }
}

struct SteamMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let o = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: o.x + s * x, y: o.y + s * y)
            }
            func oval(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: o.x + s * x, y: o.y + s * y, width: s * d, height: s * d))
            }

            context.stroke(oval(0.06, 0.06, 0.88), with: .color(.primary), lineWidth: max(1, s * 0.09))

            var arm = Path()
            arm.move(to: pt(0.34, 0.66))
            arm.addLine(to: pt(0.66, 0.36))
            context.stroke(arm, with: .color(.primary),
                           style: StrokeStyle(lineWidth: max(1.2, s * 0.11), lineCap: .round))

            context.fill(oval(0.20, 0.52, 0.30), with: .color(.primary))
            context.stroke(oval(0.54, 0.24, 0.26), with: .color(.primary), lineWidth: max(1, s * 0.08))
        }
        .accessibilityLabel("Steam")
    }
}

struct SteamRow: View {
    let title: String
    let detail: String
    let running: Bool
    let disabled: Bool
    let action: () -> Void
    let openFolder: () -> Void
    let folderDisabled: Bool
    let icon: AnyView
    /// Replace the detail line with "Running" while the session is up. Off for
    /// the Windows row, where the detail line carries the Wine and GPTK versions.
    var showsRunningLabel = true

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        icon
                            .frame(width: 16, height: 16)
                        SteamMark()
                            .frame(width: 16, height: 16)
                    }
                    .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(running && showsRunningLabel ? "Running" : detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if running {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            Button(action: openFolder) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(folderDisabled)
            .help("Open folder")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Menu

struct MenuView: View {
    @ObservedObject var sup = Supervisor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text("Espresso")
                    .font(.headline)
                Spacer()
                Text(AppVersion.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            if !sup.status.isEmpty {
                Text(sup.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }

            SteamRow(
                title: "Mac",
                detail: sup.macSteamInstalled() ? "Native Steam" : "Steam.app not installed",
                running: sup.macSessionAlive,
                disabled: sup.isLaunching || !sup.macSteamInstalled() || sup.macSessionAlive,
                action: { sup.startMacSteam() },
                openFolder: { sup.openMacSteamFolder() },
                folderDisabled: false,
                icon: AnyView(Image(systemName: "apple.logo").font(.system(size: 15)))
            )
            Divider()
            SteamRow(
                title: sup.windowsVersion,
                detail: sup.doctorPassed ? sup.runtimeVersions : "Doctor must pass",
                running: sup.sessionAlive,
                disabled: sup.isLaunching || !sup.doctorPassed || sup.sessionAlive,
                action: { sup.startSteam() },
                openFolder: { sup.openPrefix() },
                folderDisabled: false,
                icon: AnyView(WindowsMark().frame(width: 15, height: 15)),
                showsRunningLabel: false
            )

            Divider()
                .padding(.vertical, 8)

            HStack {
                Button("Stop") { sup.stop() }
                    .disabled(sup.isLaunching || (!sup.sessionAlive && !sup.macSessionAlive))
                Button(sup.doctorRan ? (sup.doctorPassed ? "Doctor ✓" : "Doctor ❌") : "Doctor") {
                    sup.runDoctor()
                }
                .keyboardShortcut("d")
                Spacer()
                Button("Logs") { sup.openLogs() }
                Button("Quit") {
                    sup.stopSync()
                    NSApplication.shared.terminate(nil)
                }
            }
            .controlSize(.small)

            if sup.doctorRan && !sup.doctorPassed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sup.checks.filter { !$0.ok }) { c in
                            Text("\(c.name) — \(c.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 64)
                .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { sup.refreshSession() }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let sup = Supervisor.shared

        // Headless doctor, so the checks can be run and scripted from a
        // terminal without trusting the menu. Exits 1 on failure.
        if CommandLine.arguments.contains("--doctor") {
            print("Espresso doctor — \(Layout.engineName)")
            sup.runDoctor()
            for c in sup.checks {
                print("  \(c.ok ? "PASS" : "FAIL")  \(c.name) — \(c.detail)")
            }
            print(sup.doctorPassed ? "RESULT: PASS" : "RESULT: FAIL")
            exit(sup.doctorPassed ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test") {
            exit(Self.runSteamLaunchSelfTest(sup) ? 0 : 1)
        }

        sup.runDoctor()
        sup.startSessionWatch()
        sup.refreshSession()
    }

    /// Start Steam, refuse a second start, stop. Repeat. Catches the double-launch
    /// path where a second wine steam.exe is spawned into a live prefix.
    private static func runSteamLaunchSelfTest(_ sup: Supervisor) -> Bool {
        print("Espresso self-test — Steam start/stop, no double launch")
        sup.runDoctor()
        guard sup.doctorPassed else {
            print("FAIL doctor did not pass")
            return false
        }

        func wait(_ seconds: TimeInterval, until pred: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if pred() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            }
            return pred()
        }

        let cycles = 3
        for i in 1...cycles {
            print("cycle \(i)/\(cycles): stop")
            sup.stopSync()
            sup.isLaunching = false
            sup.sessionAlive = false
            guard wait(5, until: { !sup.prefixSessionAlive() }) else {
                print("FAIL cycle \(i): wineserver still alive after stop")
                return false
            }

            let logsBefore = sup.steamLogCount()
            print("cycle \(i)/\(cycles): start")
            sup.startSteam()
            guard wait(20, until: { sup.prefixSessionAlive() }) else {
                print("FAIL cycle \(i): wineserver did not start (\(sup.status))")
                sup.stopSync()
                return false
            }

            print("cycle \(i)/\(cycles): second start must no-op")
            sup.startSteam()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2))
            let logsAfter = sup.steamLogCount()
            let spawned = logsAfter - logsBefore
            if spawned != 1 {
                print("FAIL cycle \(i): expected 1 steam log, got \(spawned) (before=\(logsBefore) after=\(logsAfter))")
                sup.stopSync()
                return false
            }
            if !sup.prefixSessionAlive() {
                print("FAIL cycle \(i): session died after second start")
                return false
            }

            print("cycle \(i)/\(cycles): stop")
            sup.stopSync()
            sup.isLaunching = false
            sup.sessionAlive = false
            guard wait(5, until: { !sup.prefixSessionAlive() }) else {
                print("FAIL cycle \(i): wineserver still alive after final stop")
                return false
            }
            print("cycle \(i)/\(cycles): PASS")
        }
        print("RESULT: PASS")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Supervisor.shared.stopSync()
    }
}

@main
struct EspressoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var supervisor = Supervisor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(sup: supervisor)
        } label: {
            Image(systemName: supervisor.doctorPassed
                  ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
        .menuBarExtraStyle(.window)
    }
}
