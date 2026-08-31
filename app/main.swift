//  Espresso — ARM-native menu-bar supervisor for one Steam prefix running
//  under x86_64 Wine with Apple D3DMetal.
//
//  Implements design-doc 001: sections 1 (what Espresso is), 5 (layout),
//  9 (the D3DMetal load path and doctor checks), 11 (process model) and
//  13 (v0 scope).
//
//  Build: sh build.sh

import SwiftUI
import Foundation
import AppKit

// MARK: - Layout

struct Layout {
    static let engineName = "WS12WineSikarugir10.0_6"

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

    /// Windows-side path of the shipping exe, per 001 section 10.2.
    static let gameWindowsPath =
        "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Star Wars Zero Company" +
        "\\SWZeroCompany\\Binaries\\Win64\\SWZeroCompany.exe"

    /// POSIX path of that same exe inside the prefix, for existence checks.
    func gamePOSIXPath() -> String {
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
    @Published var status = "Idle"
    @Published var gamePresent = false
    @Published var isLaunching = false

    private let fm = FileManager.default

    // MARK: Environment (001 section 9, items 1-8)

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

    // MARK: Doctor (001 section 9)

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

        // 8c. pdh stub — UE5 SWZeroCompany crashes 0x80000100 at 0s without it.
        let pdh = L.prefix.appendingPathComponent("drive_c/windows/system32/pdh.dll")
        let pdhOK = fm.fileExists(atPath: pdh.path)
        out.append(Check(name: "pdh stub",
                         ok: pdhOK,
                         detail: pdhOK ? "native stub in system32/ — UE5 will not crash on PdhOpenQuery" : "missing — SWZeroCompany will crash 0x80000100"))
        if !pdhOK {
            // Also check registry override is set — otherwise builtin pdh still used.
            let r = shellWine("/usr/bin/arch", ["-x86_64", L.wine.path, "reg", "query", "HKCU\\Software\\Wine\\DllOverrides", "/v", "pdh"])
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

        // 10. wineserver must be ours, not CrossOver's (001 section 11)
        let ps = shell("/usr/bin/pgrep", ["-fl", "wineserver"])
        let foreign = ps.out.split(separator: "\n").filter {
            $0.localizedCaseInsensitiveContains("CrossOver")
        }
        out.append(Check(name: "No foreign wineserver",
                         ok: foreign.isEmpty,
                         detail: foreign.isEmpty ? "only Espresso wineserver"
                                                 : "CrossOver wineserver running"))

        // 11. Game exe present (informational; does not block Steam)
        let present = fm.fileExists(atPath: L.gamePOSIXPath())
        let passed = out.allSatisfy { $0.ok }
        let okCount = out.filter { $0.ok }.count

        // Always called on the main actor, so publish directly.
        checks = out
        doctorPassed = passed
        doctorRan = true
        gamePresent = present
        status = passed ? "Doctor passed (\(okCount)/\(out.count))"
                        : "Doctor FAILED (\(okCount)/\(out.count))"
    }

    // MARK: Launch

    private func launchWine(_ args: [String], label: String) {
        guard fm.fileExists(atPath: layout.wine.path) else {
            DispatchQueue.main.async { self.status = "No Wine binary" }
            return
        }
        do {
            try fm.createDirectory(at: layout.logs, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { self.status = "Cannot create log dir: \(error)" }
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let logURL = layout.logs
            .appendingPathComponent("\(label.lowercased())-\(stamp).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: logURL.path) else {
            DispatchQueue.main.async { self.status = "Cannot open log file" }
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", layout.wine.path] + args
        p.environment = wineEnvironment()
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
                self?.status = "\(label) exited with \(code)"
                self?.isLaunching = false
            }
        }

        do {
            try p.run()
            DispatchQueue.main.async {
                self.status = "\(label) running, pid \(p.processIdentifier)"
            }
        } catch {
            fh.readabilityHandler = nil
            try? handle.close()
            DispatchQueue.main.async {
                self.status = "Failed to start \(label): \(error.localizedDescription)"
                self.isLaunching = false
            }
        }
    }

    private func isRunning(_ name: String) -> Bool {
        shell("/usr/bin/pgrep", ["-f", name]).status == 0
    }

    func startSteam() {
        if isLaunching || isRunning("steam.exe") {
            DispatchQueue.main.async { self.status = "Steam already running" }
            return
        }
        isLaunching = true
        if isRunning("wineserver") && !isRunning("steam.exe") {
            // Stale wineserver from previous session — kill before fresh launch
            stopSync()
        }
        // 001 section 10.1: -no-cef-sandbox. Never -cef-force-32bit, it is gone.
        launchWine(["C:\\Program Files (x86)\\Steam\\steam.exe", "-no-cef-sandbox"],
                   label: "Steam")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.isLaunching = false }
    }

    func startGame() {
        if isLaunching || isRunning(Layout.gameWindowsPath) || isRunning("SWZeroCompany.exe") {
            DispatchQueue.main.async { self.status = "Game already running" }
            return
        }
        isLaunching = true
        // 001 section 10.2: launch the shipping exe, not the Unreal bootstrapper.
        launchWine([Layout.gameWindowsPath], label: "ZeroCompany")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.isLaunching = false }
    }

    /// Synchronous stop for use on quit; do not dispatch to main.
    func stopSync() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", layout.wineserver.path, "-k"]
        p.environment = wineEnvironment()
        try? p.run()
        p.waitUntilExit()
        // Always sweep, but scope to Espresso's prefix/engine to avoid killing CrossOver if the user runs it.
        // lsof +D on the prefix is the authority — pkill -f is broad, so filter by lsof first.
        let holders = shell("/usr/sbin/lsof", ["+D", layout.prefix.path]).out
        let hasHolders = holders.contains("wineserver") || holders.contains("steam") || holders.contains("winedevice")
        if hasHolders || shell("/usr/bin/pgrep", ["-f", layout.wineserver.path]).status == 0 {
            _ = shell("/bin/sh", ["-c",
                "lsof +D '\(layout.prefix.path)' 2>/dev/null | awk 'NR>1{print $2}' | xargs -I {} kill -9 {} 2>/dev/null; " +
                "pkill -9 -f '\(NSRegularExpression.escapedPattern(for: layout.wineserver.path))' 2>/dev/null; " +
                "pkill -9 -f '\(NSRegularExpression.escapedPattern(for: layout.prefix.path))/.*winedevice' 2>/dev/null"
            ])
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    func stop() {
        stopSync()
        DispatchQueue.main.async {
            self.status = "Stopped wineserver"
        }
    }

    func openPrefix() {
        NSWorkspace.shared.open(layout.prefix)
    }

    func openLogs() {
        try? fm.createDirectory(at: layout.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(layout.logs)
    }
}

// MARK: - Menu

struct MenuView: View {
    @ObservedObject var sup = Supervisor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sup.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            Divider()

            Button("Run doctor") { sup.runDoctor() }
                .keyboardShortcut("d")

            if sup.doctorRan {
                Menu("Doctor results (\(sup.checks.filter(\.ok).count)/\(sup.checks.count))") {
                    ForEach(sup.checks) { c in
                        Label("\(c.name) — \(c.detail)",
                              systemImage: c.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    }
                }
            }

            Divider()

            Button("Start Steam") { sup.startSteam() }
                .disabled(!sup.doctorPassed || sup.isLaunching)

            if !sup.doctorPassed {
                Text("Doctor must pass before launch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            Button("Stop Steam") { sup.stop() }

            Divider()

            Button("Open Steam Folder") { sup.openPrefix() }
            Button("Open logs") { sup.openLogs() }

            Divider()

            Button("Quit Espresso") {
                sup.stopSync()
                NSApplication.shared.terminate(nil)
            }
        }
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

        sup.runDoctor()
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
        .menuBarExtraStyle(.menu)
    }
}
