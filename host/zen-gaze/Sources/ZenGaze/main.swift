import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tracker = GazeTracker()
    private let link = KeyboardLink()
    private var classifier = GazeClassifier()
    private var reconnectTimer: Timer?

    private var lastPose: HeadPose?
    private var keyboardState: KeyboardLink.State?
    private var cameraError: String?

    private var calibrating: Target?
    private var calibrationSamples: [HeadPose] = []

    private let defaults = UserDefaults.standard

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// BLE profile the other computer is paired on (the keymap's BT_SEL index).
    private var profile: Int {
        get { defaults.object(forKey: "profile") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "profile") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        classifier.macPose = loadPose("macPose")
        classifier.otherPose = loadPose("otherPose")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tracker.onPose = { [weak self] pose in self?.handle(pose) }
        link.onChange = { [weak self] connected, state in
            self?.keyboardState = connected ? state : nil
            self?.refreshIcon()
        }
        // Adopt whatever the keyboard is doing now; gaze + dwell make the next change.
        link.onConnect = { [weak self] state in
            self?.classifier.force(state.usb ? .mac : .other)
            self?.refreshIcon()
        }
        link.onError = { [weak self] message in self?.alert(message) }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reconnect()
        }
        reconnect()
        applyEnabled()
        refreshIcon()
    }

    // MARK: - Flow

    private func reconnect() {
        link.connectInBackground()
    }

    private var calibrated: Bool { classifier.macPose != nil && classifier.otherPose != nil }

    /// Auto-switching only runs once both directions are calibrated: without
    /// them, looking down at the keyboard could read as "looking away".
    private var autoSwitching: Bool { enabled && calibrated }

    private func applyEnabled() {
        guard autoSwitching || calibrating != nil else {
            tracker.stop()
            lastPose = nil
            refreshIcon()
            return
        }
        GazeTracker.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.cameraError = "카메라 권한이 없어요 (시스템 설정 > 개인정보 보호 및 보안 > 카메라)"
                self.refreshIcon()
                return
            }
            do {
                try self.tracker.start()
                self.cameraError = nil
            } catch {
                self.cameraError = error.localizedDescription
            }
            self.refreshIcon()
        }
    }

    private func handle(_ pose: HeadPose?) {
        lastPose = pose

        if calibrating != nil {
            if calibrationCollecting, let pose { calibrationSamples.append(pose) }
            return
        }
        guard autoSwitching else { return }

        if let target = classifier.feed(pose) {
            send(target)
        }
        refreshIcon()
    }

    private func send(_ target: Target) {
        guard keyboardState != nil else { return }
        link.select(usb: target == .mac, profile: profile)
    }

    private func switchManually(to target: Target) {
        classifier.force(target)
        send(target)
        refreshIcon()
    }

    // MARK: - Calibration

    private var calibrationCollecting = false

    private func calibrate(_ target: Target) {
        calibrating = target
        calibrationCollecting = false
        calibrationSamples = []
        applyEnabled()
        refreshIcon()

        // You clicked while facing the Mac: allow 3 s to turn toward the target,
        // then sample for 1.5 s. Sounds mark the start and the end.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            NSSound(named: "Tink")?.play()
            self?.calibrationSamples = []
            self?.calibrationCollecting = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            NSSound(named: "Glass")?.play()
            self?.finishCalibration()
        }
    }

    private func finishCalibration() {
        guard let target = calibrating else { return }
        calibrating = nil
        calibrationCollecting = false
        defer { applyEnabled(); refreshIcon() }

        guard calibrationSamples.count >= 5 else {
            alert("얼굴을 충분히 인식하지 못했어요. 밝은 곳에서 다시 해 주세요.")
            return
        }
        let pose = HeadPose(yaw: median(calibrationSamples.map(\.yaw)),
                            pitch: median(calibrationSamples.map(\.pitch)))
        switch target {
        case .mac: classifier.macPose = pose; savePose(pose, "macPose")
        case .other: classifier.otherPose = pose; savePose(pose, "otherPose")
        }
        if let mac = classifier.macPose, let other = classifier.otherPose, mac.distance(to: other) < 12 {
            alert("두 방향의 차이가 \(Int(mac.distance(to: other)))°밖에 안 돼서 구분이 불안정할 수 있어요. 고개를 조금 더 돌려서 다시 맞춰 보세요.")
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func savePose(_ pose: HeadPose, _ key: String) {
        defaults.set([pose.yaw, pose.pitch], forKey: key)
    }

    private func loadPose(_ key: String) -> HeadPose? {
        guard let v = defaults.array(forKey: key) as? [Double], v.count == 2 else { return nil }
        return HeadPose(yaw: v[0], pitch: v[1])
    }

    // MARK: - UI

    private func refreshIcon() {
        let symbol: String
        if calibrating != nil { symbol = "scope" }
        else if keyboardState == nil { symbol = "keyboard.badge.exclamationmark" }
        else if !autoSwitching { symbol = "pause.circle" }
        else { symbol = classifier.current == .mac ? "laptopcomputer" : "desktopcomputer" }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ZenGaze")
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ZenGaze")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func info(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ key: String = "", _ block: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, block)
            menu.addItem(item)
            return item
        }

        if let state = keyboardState {
            let out = state.usb ? "USB (이 맥)" : "BLE 프로필 \(state.profile)" + (state.bleConnected ? "" : " · 연결 안 됨")
            info("키보드: \(out)")
        } else {
            info("키보드: 찾는 중… (오른쪽 반쪽을 USB로 연결)")
        }
        if let calibrating {
            info(calibrating == .mac ? "띵 소리가 나면 맥북 화면을 바라보세요…" : "띵 소리가 나면 다른 컴퓨터 화면을 바라보세요…")
        } else if let cameraError {
            info(cameraError)
        } else if enabled && !calibrated {
            info("자동 전환은 아래 보정 두 가지를 마친 뒤 켜져요")
        } else if autoSwitching {
            info(lastPose.map { String(format: "얼굴: 좌우 %.0f° · 상하 %.0f°", $0.yaw, $0.pitch) } ?? "얼굴: 인식 안 됨 (현재 상태 유지)")
        }
        menu.addItem(.separator())

        action("시선으로 자동 전환") { [weak self] in
            guard let self else { return }
            self.enabled.toggle()
            self.applyEnabled()
        }.state = enabled ? .on : .off

        _ = action("지금 이 맥으로") { [weak self] in self?.switchManually(to: .mac) }
        _ = action("지금 다른 컴퓨터로") { [weak self] in self?.switchManually(to: .other) }
        menu.addItem(.separator())

        info("방향 보정: " + [classifier.macPose != nil ? "맥 ✓" : "맥 –",
                               classifier.otherPose != nil ? "다른 컴퓨터 ✓" : "다른 컴퓨터 –"].joined(separator: " · "))
        _ = action("보정: 맥북 화면 보면서 클릭") { [weak self] in self?.calibrate(.mac) }
        _ = action("보정: 다른 컴퓨터 보면서 클릭") { [weak self] in self?.calibrate(.other) }
        if classifier.macPose != nil || classifier.otherPose != nil {
            _ = action("보정 초기화") { [weak self] in
                guard let self else { return }
                self.classifier.macPose = nil
                self.classifier.otherPose = nil
                self.defaults.removeObject(forKey: "macPose")
                self.defaults.removeObject(forKey: "otherPose")
                self.applyEnabled()
                self.refreshIcon()
            }
        }
        menu.addItem(.separator())

        let profileItem = NSMenuItem(title: "다른 컴퓨터의 BLE 프로필", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // ZEN central: BT_MAX_PAIRED 5 minus one slot for the left half = profiles 0–3.
        for n in 0..<4 {
            let item = ClosureMenuItem(title: "프로필 \(n)", keyEquivalent: "") { [weak self] in
                self?.profile = n
                if self?.classifier.current == .other { self?.send(.other) }
            }
            item.state = n == profile ? .on : .off
            sub.addItem(item)
        }
        profileItem.submenu = sub
        menu.addItem(profileItem)
        menu.addItem(.separator())

        _ = action("종료", "q") { NSApp.terminate(nil) }
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "ZenGaze"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let block: () -> Void

    init(title: String, keyEquivalent: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { block() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
