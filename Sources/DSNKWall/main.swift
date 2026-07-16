import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var metalView: MTKView!
    var renderer: Renderer!
    var audioBeat: AudioBeat!
    private var isFullscreen = false
    private var cameraMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let size = NSSize(width: min(1280, screen.width), height: min(720, screen.height))
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )

        window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]

        metalView = MTKView(frame: window.contentView!.bounds)
        metalView.autoresizingMask = [.width, .height]
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        window.contentView = metalView

        audioBeat = AudioBeat()
        guard let r = Renderer(metalView: metalView, audioBeat: audioBeat) else {
            fatalError("Failed to create Metal renderer")
        }
        renderer = r
        audioBeat.start()
        renderer.cameraCapture.onDevicesChanged = { [weak self] in
            self?.rebuildCameraMenu()
        }
        rebuildCameraMenu()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return event
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DSNK Wall", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DSNK Wall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Camera menu (Continuity Camera / iPhone preferred)
        let cameraItem = NSMenuItem()
        cameraItem.title = "Camera"
        let camMenu = NSMenu(title: "Camera")
        cameraItem.submenu = camMenu
        mainMenu.addItem(cameraItem)
        cameraMenu = camMenu

        // View menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(toggleFullscreenAction(_:)), keyEquivalent: "f")
        fs.target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    private func rebuildCameraMenu() {
        guard let menu = cameraMenu else { return }
        menu.removeAllItems()
        let devices = renderer?.cameraCapture.availableDevices() ?? []
        if devices.isEmpty {
            let none = NSMenuItem(title: "No Cameras", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        let current = renderer?.cameraCapture.currentDeviceID
        for (i, device) in devices.enumerated() {
            let item = NSMenuItem(
                title: device.localizedName,
                action: #selector(selectCamera(_:)),
                keyEquivalent: i < 9 ? "\(i + 1)" : ""
            )
            if i < 9 {
                item.keyEquivalentModifierMask = [.command, .option]
            }
            item.target = self
            item.representedObject = device.uniqueID
            item.state = (device.uniqueID == current) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        renderer?.cameraCapture.selectDevice(uniqueID: id)
        rebuildCameraMenu()
    }

    @objc private func toggleFullscreenAction(_ sender: Any?) {
        toggleFullscreen()
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 {
            NSApp.terminate(nil)
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "f" {
            toggleFullscreen()
        }
    }

    private func toggleFullscreen() {
        window.toggleFullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        NSCursor.hide()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        NSCursor.unhide()
    }
}

let args = CommandLine.arguments
if args.contains("--dump-frames") {
    let outIdx = args.firstIndex(of: "--out").map { $0 + 1 }
    let outPath = outIdx.flatMap { $0 < args.count ? args[$0] : nil }
        ?? FileManager.default.currentDirectoryPath + "/frames"
    let count: Int = {
        guard let i = args.firstIndex(of: "--count"), i + 1 < args.count else { return 4 }
        return Int(args[i + 1]) ?? 4
    }()
    FrameDump.run(
        outputDir: URL(fileURLWithPath: outPath),
        width: 1280,
        height: 720,
        count: count,
        hideLogo: !args.contains("--with-logo")
    )
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
