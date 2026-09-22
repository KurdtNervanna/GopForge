// GopForge.swift — native single-window front-end for gopforge.sh
//
// A real AppKit app: action buttons, native file pickers, and a colored,
// streaming log pane — all in one window (Rom Dump-style). It changes NONE of
// GopForge's logic: it runs the bundled, unchanged gopforge.sh and streams its
// output. Colors are applied here from the ✓ ✗ ! » markers gopforge already
// prints, so the script needs no ANSI/tty tricks.
//
// Built by build-app.command with:  swiftc -O -o GopForge GopForge.swift -framework AppKit
// SPDX-License-Identifier: MIT

import AppKit

final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var romLabel: NSTextField!
    var variant: NSSegmentedControl!
    var selectBtn, inspectBtn, prepareBtn, fetchBtn, romDumpBtn, revealBtn: NSButton!
    var spinner: NSProgressIndicator!
    var statusLabel: NSTextField!

    var romURL: URL?
    var lastOutput: URL?
    var running = false
    var lineBuf = ""

    let mono = NSFont(name: "Menlo", size: 12) ?? NSFont.userFixedPitchFont(ofSize: 12)!

    var toolsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("GopForge/tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var gopforge: URL? { Bundle.main.url(forResource: "gopforge", withExtension: "sh") }

    // MARK: launch
    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        appendLine("GopForge — select a dumped MacPro4,1/5,1 BootROM, then Inspect or Prepare.", .secondaryLabelColor)
        if gopforge == nil { appendLine("✗ gopforge.sh is missing from the app bundle.", .systemRed) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "Quit GopForge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "GopForge"
        window.center()
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content

        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        selectBtn = button("Select ROM…", #selector(selectROM))
        inspectBtn = button("Inspect", #selector(inspect))
        prepareBtn = button("Prepare", #selector(prepare))
        fetchBtn = button("Download Tools", #selector(fetch))
        romDumpBtn = button("Get Rom Dump", #selector(openRomDump))
        revealBtn = button("Reveal Output", #selector(reveal)); revealBtn.isEnabled = false

        romLabel = NSTextField(labelWithString: "No ROM selected")
        romLabel.textColor = .secondaryLabelColor
        romLabel.lineBreakMode = .byTruncatingMiddle
        romLabel.translatesAutoresizingMaskIntoConstraints = false

        variant = NSSegmentedControl(labels: ["Standard", "Direct"], trackingMode: .selectOne, target: nil, action: nil)
        variant.selectedSegment = 0
        variant.translatesAutoresizingMaskIntoConstraints = false

        let variantCaption = NSTextField(labelWithString: "Variant:")
        variantCaption.textColor = .secondaryLabelColor
        variantCaption.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // log text view in a scroll view
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = mono
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        for v in [selectBtn!, romLabel!, variantCaption, variant!, inspectBtn!, prepareBtn!, fetchBtn!, romDumpBtn!, revealBtn!, spinner!, statusLabel!, scroll] {
            content.addSubview(v)
        }

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            // row 1
            selectBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            selectBtn.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            romLabel.leadingAnchor.constraint(equalTo: selectBtn.trailingAnchor, constant: 10),
            romLabel.centerYAnchor.constraint(equalTo: selectBtn.centerYAnchor),
            variantCaption.centerYAnchor.constraint(equalTo: selectBtn.centerYAnchor),
            variant.leadingAnchor.constraint(equalTo: variantCaption.trailingAnchor, constant: 6),
            variant.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            variant.centerYAnchor.constraint(equalTo: selectBtn.centerYAnchor),
            romLabel.trailingAnchor.constraint(lessThanOrEqualTo: variantCaption.leadingAnchor, constant: -10),
            // row 2
            inspectBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            inspectBtn.topAnchor.constraint(equalTo: selectBtn.bottomAnchor, constant: 10),
            prepareBtn.leadingAnchor.constraint(equalTo: inspectBtn.trailingAnchor, constant: 8),
            prepareBtn.centerYAnchor.constraint(equalTo: inspectBtn.centerYAnchor),
            fetchBtn.leadingAnchor.constraint(equalTo: prepareBtn.trailingAnchor, constant: 8),
            fetchBtn.centerYAnchor.constraint(equalTo: inspectBtn.centerYAnchor),
            romDumpBtn.leadingAnchor.constraint(equalTo: fetchBtn.trailingAnchor, constant: 8),
            romDumpBtn.centerYAnchor.constraint(equalTo: inspectBtn.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: romDumpBtn.trailingAnchor, constant: 12),
            spinner.centerYAnchor.constraint(equalTo: inspectBtn.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: inspectBtn.centerYAnchor),
            revealBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            revealBtn.centerYAnchor.constraint(equalTo: inspectBtn.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: revealBtn.leadingAnchor, constant: -8),
            // log
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            scroll.topAnchor.constraint(equalTo: inspectBtn.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: actions
    @objc func selectROM() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Select your dumped MacPro4,1/5,1 BootROM (.rom or .bin)"
        if panel.runModal() == .OK, let u = panel.url {
            romURL = u
            romLabel.stringValue = u.lastPathComponent
            romLabel.textColor = .labelColor
            revealBtn.isEnabled = false
        }
    }

    @objc func inspect() {
        guard let rom = romURL else { alert("Select a ROM first."); return }
        appendLine("── Inspecting \(rom.lastPathComponent) ──", .secondaryLabelColor)
        run(["--check", rom.path]) { _ in }
    }

    @objc func fetch() {
        appendLine("── Downloading EnableGop.ffs + DXEInject ──", .secondaryLabelColor)
        run(["--fetch"]) { code in
            if code == 0 { self.appendLine("Tools cached in: \(self.toolsDir.path)", .secondaryLabelColor) }
        }
    }

    @objc func prepare() {
        guard let rom = romURL else { alert("Select a ROM first."); return }
        let direct = variant.selectedSegment == 1
        let save = NSSavePanel()
        save.nameFieldStringValue = rom.deletingPathExtension().lastPathComponent + "-enablegop.rom"
        save.directoryURL = rom.deletingLastPathComponent()
        save.message = "Save the prepared ROM as:"
        guard save.runModal() == .OK, let out = save.url else { return }

        let warn = NSAlert()
        warn.alertStyle = .warning
        warn.messageText = "Prepare a boot ROM with EnableGop?"
        warn.informativeText = """
        Input:   \(rom.lastPathComponent)
        Variant: \(direct ? "Direct (EnableGopDirect)" : "Standard")
        Output:  \(out.lastPathComponent)

        This writes a NEW file and never touches your input. It does NOT flash your \
        hardware — you still flash the result with Macschrauber's Rom Dump, and only \
        if GopForge reports success. Keep an untouched backup and a hardware recovery \
        path before flashing.
        """
        warn.addButton(withTitle: "Prepare")
        warn.addButton(withTitle: "Cancel")
        guard warn.runModal() == .alertFirstButtonReturn else { return }

        lastOutput = out
        revealBtn.isEnabled = false
        appendLine("── Preparing \(rom.lastPathComponent)  (\(direct ? "Direct" : "Standard")) ──", .secondaryLabelColor)
        var args = ["--inject", rom.path, "-o", out.path, "--force", "-y"]
        if direct { args.append("--direct") }
        run(args) { code in
            if code == 0 {
                self.revealBtn.isEnabled = true
                self.appendLine("✓ Ready: \(out.path)", .systemGreen)
                self.appendLine("Next: inspect in UEFITool 0.25.1, then flash with Rom Dump.", .secondaryLabelColor)
            } else {
                self.appendLine("✗ GopForge did not produce a valid ROM — do not flash. See the log above.", .systemRed)
            }
        }
    }

    @objc func reveal() {
        if let o = lastOutput { NSWorkspace.shared.activateFileViewerSelecting([o]) }
    }

    @objc func openRomDump() {
        // GopForge prepares a ROM; the actual dump + flash are done with
        // Macschrauber's Rom Dump. Open its official releases page.
        if let u = URL(string: "https://github.com/Macschrauber/Macschrauber-s-Rom-Dump/releases") {
            NSWorkspace.shared.open(u)
            appendLine("» Opening Macschrauber's Rom Dump releases page (for dumping + flashing)…", .systemBlue)
        }
    }

    // MARK: run gopforge.sh
    func run(_ args: [String], done: @escaping (Int32) -> Void) {
        if running { return }
        guard let gop = gopforge else { appendLine("✗ gopforge.sh not found in bundle.", .systemRed); return }
        setRunning(true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [gop.path, "--tools-dir", toolsDir.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { return }
            let s = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.feed(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.flush()
                self?.setRunning(false)
                done(proc.terminationStatus)
            }
        }
        do { try p.run() } catch {
            setRunning(false)
            appendLine("✗ failed to launch gopforge.sh: \(error.localizedDescription)", .systemRed)
        }
    }

    func setRunning(_ on: Bool) {
        running = on
        if on { spinner.startAnimation(nil); statusLabel.stringValue = "Working…" }
        else { spinner.stopAnimation(nil); statusLabel.stringValue = "" }
        for b in [selectBtn, inspectBtn, prepareBtn, fetchBtn] { b?.isEnabled = !on }
    }

    // MARK: log rendering
    func feed(_ s: String) {
        lineBuf += s
        while let r = lineBuf.range(of: "\n") {
            let line = String(lineBuf[..<r.lowerBound])
            lineBuf = String(lineBuf[r.upperBound...])
            appendLine(line, color(for: line))
        }
    }
    func flush() {
        if !lineBuf.isEmpty { appendLine(lineBuf, color(for: lineBuf)); lineBuf = "" }
    }
    func color(for line: String) -> NSColor {
        let t = line.trimmingCharacters(in: .whitespaces)
        // --check status lines have no leading marker — color them by content
        if t.hasPrefix("enablegop:") {
            if t.contains("PRESENT") { return .systemGreen }      // a GOP driver is in the ROM
            if t.contains("not present") { return .systemOrange } // clean dump (no GOP yet)
        }
        if t.hasPrefix("instances:") { return .systemRed }        // duplicate EnableGop
        if t.hasPrefix("model") {
            if t.contains("NOT") { return .systemRed }            // not a 4,1/5,1 BootROM
            if t.contains("MacPro4,1/5,1") { return .systemGreen }
        }
        // marker-prefixed lines
        if t.hasPrefix("✓") { return .systemGreen }
        if t.hasPrefix("✗") { return .systemRed }
        if t.hasPrefix("!") { return .systemYellow }
        if t.hasPrefix("»") { return .systemBlue }
        if t.hasPrefix("─") { return .tertiaryLabelColor }
        return .labelColor
    }
    func appendLine(_ line: String, _ col: NSColor) {
        let attr = NSAttributedString(string: line + "\n", attributes: [.foregroundColor: col, .font: mono])
        textView.textStorage?.append(attr)
        textView.scrollToEndOfDocument(nil)
    }

    func alert(_ msg: String) {
        let a = NSAlert(); a.messageText = msg; a.addButton(withTitle: "OK"); a.runModal()
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
