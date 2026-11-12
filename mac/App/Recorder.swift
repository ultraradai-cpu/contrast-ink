import AppKit
import ContrastInkPC

/// The line to OBS's built-in remote control (obs-websocket 5, OBS 28 and later) on this Mac. OBS keeps doing the
/// recording; this only asks it to start, pause and stop, and listens for what it reports. On the main thread.
final class ObsLink {
    private var task: URLSessionWebSocketTask?
    private var connecting: [((String?) -> Void)] = []
    private var pending: [String: ([String: Any]?) -> Void] = [:]
    private let session = URLSession(configuration: .ephemeral)

    /// OBS reported a change in recording: (state, file path when it stopped).
    var recordState: ((String, String?) -> Void)?
    /// The line to OBS dropped (OBS closed or crashed).
    var lost: (() -> Void)?

    var connected: Bool { task != nil }

    /// Connects if not connected; calls back with nil on success, otherwise what the presenter should do about it.
    func connect(_ done: @escaping (String?) -> Void) {
        if task != nil { done(nil); return }
        connecting.append(done)
        if connecting.count > 1 { return }   // one attempt at a time
        let finish: (String?) -> Void = { [weak self] why in
            guard let self else { return }
            let waiting = self.connecting
            self.connecting = []
            waiting.forEach { $0(why) }
        }
        guard let cfg = Obs.readConfig(folder: Obs.folder()) else {
            finish("OBS isn't set up on this Mac yet. Install OBS Studio 28 or newer and open it once.")
            return
        }
        guard cfg.enabled else {
            finish("In OBS, open Tools → WebSocket Server Settings and tick Enable WebSocket Server. Then press ⏺ again.")
            return
        }
        guard let url = URL(string: "ws://127.0.0.1:\(cfg.port)") else { finish("OBS's port isn't valid."); return }
        let t = session.webSocketTask(with: url, protocols: ["obswebsocket.json"])
        t.resume()
        var settled = false
        let unreachable = "Can't reach OBS. Open OBS (and in Tools → WebSocket Server Settings, Enable WebSocket Server on port \(cfg.port)), then press ⏺ again."
        let fail: (String?) -> Void = { why in
            guard !settled else { return }
            settled = true
            // obs-websocket's AuthenticationFailed (4009): OBS closes the line instead of answering
            let refused = t.closeCode.rawValue == 4009
            t.cancel(with: .normalClosure, reason: nil)
            finish(refused ? "OBS refused the password it saved. In OBS, open Tools → WebSocket Server Settings, press Apply, and press ⏺ again." : why ?? unreachable)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { fail(nil) }
        receive(t) { [weak self] hello in
            guard let self, !settled else { return }
            guard let hello, hello["op"] as? Int == 0 else { fail(nil); return }
            self.sendJSON(t, Obs.identify(hello: hello, password: cfg.password))
            self.receive(t) { identified in
                guard !settled else { return }
                guard let identified, identified["op"] as? Int == 2 else {
                    fail("OBS didn't accept Contrast Ink's connection. Restart OBS and press ⏺ again.")
                    return
                }
                settled = true
                self.task = t
                self.readLoop(t)
                finish(nil)
            }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ done: @escaping ([String: Any]?) -> Void) {
        t.receive { result in
            var json: [String: Any]?
            if case .success(let m) = result {
                switch m {
                case .string(let s): json = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
                case .data(let d): json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                @unknown default: break
                }
            }
            DispatchQueue.main.async { done(json) }
        }
    }

    private func sendJSON(_ t: URLSessionWebSocketTask, _ object: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: object), let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    private func readLoop(_ t: URLSessionWebSocketTask) {
        receive(t) { [weak self] m in
            guard let self, self.task === t else { return }
            guard let m else {
                // an old, replaced line closing is not OBS going away
                self.task = nil
                let waiting = self.pending
                self.pending = [:]
                waiting.values.forEach { $0(nil) }
                self.lost?()
                return
            }
            let d = m["d"] as? [String: Any]
            let op = m["op"] as? Int ?? -1
            if op == 7, let id = d?["requestId"] as? String, let reply = self.pending.removeValue(forKey: id) {
                let ok = (d?["requestStatus"] as? [String: Any])?["result"] as? Bool == true
                reply(ok ? (d?["responseData"] as? [String: Any] ?? [:]) : nil)
            } else if op == 5, d?["eventType"] as? String == "RecordStateChanged" {
                let ev = d?["eventData"] as? [String: Any]
                self.recordState?(ev?["outputState"] as? String ?? "", ev?["outputPath"] as? String)
            }
            self.readLoop(t)
        }
    }

    /// Asks OBS for something; nil when OBS said no or didn't answer in 5 seconds.
    func request(_ type: String, _ data: [String: Any]? = nil, _ done: @escaping ([String: Any]?) -> Void) {
        guard let t = task else { done(nil); return }
        let id = UUID().uuidString
        pending[id] = done
        var d: [String: Any] = ["requestType": type, "requestId": id]
        if let data { d["requestData"] = data }
        sendJSON(t, ["op": 6, "d": d])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if let r = self?.pending.removeValue(forKey: id) { r(nil) }
        }
    }
}

/// Recording from the toolbar: ⏺ / ⏹, ⏸ / ▶, a timer, and a message on the toolbar when OBS stops by itself, the
/// line to OBS drops, the disk is filling up, or the scene has no screen capture. The same as the Windows Recorder,
/// without chapters (on the Mac there is no PowerPoint slide watcher yet).
final class Recorder {
    private let obs = ObsLink()
    private unowned let toolbar: Toolbar
    private var state = Toolbar.RecState.idle
    private var stopAsked = false
    private var elapsed = 0.0
    private var ticks = 0
    private var ticking = false
    private var diskWarned = false
    private var connectNotice = false
    private var timer: Timer?

    var active: Bool { state == .recording || state == .paused || state == .stopping }

    init(toolbar: Toolbar) {
        self.toolbar = toolbar
        obs.recordState = { [weak self] s, path in self?.recordStateChanged(s, path) }
        obs.lost = { [weak self] in self?.lostContact() }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        show()
    }

    private func show() { toolbar.showRecording(state, connected: obs.connected, elapsed: elapsed) }

    /// ⏺ / ⏹ pressed.
    func recordClicked() {
        if state == .recording || state == .paused { stop(); return }
        guard state == .idle else { return }
        state = .starting; show()
        obs.connect { [weak self] problem in
            guard let self else { return }
            if let problem { self.state = .idle; self.toolbar.notice(problem); self.connectNotice = true; self.show(); return }
            self.toolbar.notice(nil); self.connectNotice = false
            self.sceneProblem { scene in
                self.obs.request("GetRecordStatus") { status in
                    if status?["outputActive"] as? Bool == true {
                        // already recording (started in OBS itself): take it over rather than start a second one
                        self.state = status?["outputPaused"] as? Bool == true ? .paused : .recording
                        self.began(scene)
                        return
                    }
                    self.obs.request("StartRecord") { r in
                        guard r != nil else {
                            self.state = .idle
                            self.toolbar.notice("OBS didn't start recording. Look at OBS for the reason (often the recording folder or the disk).")
                            self.show()
                            return
                        }
                        self.state = .recording
                        self.began(scene)
                    }
                }
            }
        }
    }

    private func began(_ scene: String?) {
        stopAsked = false
        diskWarned = false
        elapsed = 0
        if let scene { toolbar.notice(scene) }
        show()
        checkDisk()
    }

    /// ⏸ / ▶ pressed.
    func pauseClicked() {
        if state == .recording {
            obs.request("PauseRecord") { [weak self] r in if r != nil { self?.state = .paused }; self?.show() }
        } else if state == .paused {
            obs.request("ResumeRecord") { [weak self] r in if r != nil { self?.state = .recording }; self?.show() }
        }
    }

    private func stop() {
        state = .stopping; stopAsked = true; show()
        obs.request("StopRecord") { [weak self] r in
            guard let self else { return }
            guard r != nil else { self.state = .recording; self.toolbar.notice("OBS didn't stop. Stop it in OBS itself."); self.show(); return }
            self.finished()
        }
    }

    private func finished() {
        guard state != .idle else { return }   // the reply and OBS's event both say so
        state = .idle
        show()
    }

    private func recordStateChanged(_ s: String, _ path: String?) {
        switch s {
        case "OBS_WEBSOCKET_OUTPUT_STARTED":
            // started from OBS itself: follow it, so ⏹ and the timer work too
            if state == .idle { state = .recording; began(nil) }
        case "OBS_WEBSOCKET_OUTPUT_STOPPED":
            guard state != .idle else { return }
            if !stopAsked {
                toolbar.notice("OBS stopped recording by itself. What was recorded is saved" + (path.map { ": " + $0 } ?? "") + ". Press ⏺ to record again.")
            }
            finished()
        case "OBS_WEBSOCKET_OUTPUT_PAUSED": if state == .recording { state = .paused; show() }
        case "OBS_WEBSOCKET_OUTPUT_RESUMED": if state == .paused { state = .recording; show() }
        default: break
        }
    }

    private func lostContact() {
        if active {
            toolbar.notice("Lost contact with OBS while recording. Check OBS: if it closed, what was recorded so far is in its recording folder.")
        }
        state = .idle
        show()
    }

    private func tick() {
        guard !ticking else { return }
        if state == .recording || state == .paused {
            ticking = true
            obs.request("GetRecordStatus") { [weak self] status in
                guard let self else { return }
                self.ticking = false
                if let ms = status?["outputDuration"] as? Double { self.elapsed = ms / 1000 }
                self.ticks += 1
                if self.ticks % 15 == 0 { self.checkDisk() }
                self.show()
            }
        } else if !obs.connected {
            ticks += 1
            // quietly, every 5 s, so ⏺ shows whether OBS is ready
            guard ticks % 5 == 0, Obs.readConfig(folder: Obs.folder())?.enabled == true else { return }
            ticking = true
            obs.connect { [weak self] problem in
                guard let self else { return }
                guard problem == nil else { self.ticking = false; return }
                if self.connectNotice { self.toolbar.notice(nil); self.connectNotice = false }
                // OBS may already be recording (started before Contrast Ink): follow it
                self.obs.request("GetRecordStatus") { status in
                    self.ticking = false
                    if self.state == .idle, status?["outputActive"] as? Bool == true {
                        self.state = status?["outputPaused"] as? Bool == true ? .paused : .recording
                        self.began(nil)
                    }
                    self.show()
                }
            }
        }
    }

    private func checkDisk() {
        obs.request("GetStats") { [weak self] stats in
            guard let self, !self.diskWarned, let mb = stats?["availableDiskSpace"] as? Double, mb < Obs.lowDiskMB else { return }
            self.diskWarned = true
            self.toolbar.notice(String(format: "Only %.1f GB left on the recording disk. Free some space, or stop soon.", mb / 1024))
        }
    }

    /// A warning if the scene being recorded has no screen capture (then the marks aren't in the video).
    private func sceneProblem(_ done: @escaping (String?) -> Void) {
        obs.request("GetCurrentProgramScene") { [weak self] scene in
            guard let self, let name = (scene?["sceneName"] ?? scene?["currentProgramSceneName"]) as? String else { done(nil); return }
            self.hasScreen("GetSceneItemList", name, depth: 0) { has in
                done(has ? nil : "OBS's scene \"\(name)\" has no screen capture, so your marks won't be in the video. In OBS: Sources, +, macOS Screen Capture.")
            }
        }
    }

    private func hasScreen(_ request: String, _ name: String, depth: Int, _ done: @escaping (Bool) -> Void) {
        obs.request(request, ["sceneName": name]) { [weak self] r in
            guard let self, let items = r?["sceneItems"] as? [[String: Any]] else { done(true); return }   // couldn't tell
            var nested: [(String, String)] = []
            for item in items {
                if item["sceneItemEnabled"] as? Bool == false { continue }
                if let kind = item["inputKind"] as? String, Obs.screenKinds.contains(kind) { done(true); return }
                guard let source = item["sourceName"] as? String, depth < 3 else { continue }
                if item["isGroup"] as? Bool == true { nested.append(("GetGroupSceneItemList", source)) }
                else if item["sourceType"] as? String == "OBS_SOURCE_TYPE_SCENE" { nested.append(("GetSceneItemList", source)) }
            }
            self.anyScreen(nested, depth: depth + 1, done)
        }
    }

    private func anyScreen(_ list: [(String, String)], depth: Int, _ done: @escaping (Bool) -> Void) {
        guard let first = list.first else { done(false); return }
        hasScreen(first.0, first.1, depth: depth) { [weak self] has in
            if has { done(true) } else { self?.anyScreen(Array(list.dropFirst()), depth: depth, done) ?? done(false) }
        }
    }
}
