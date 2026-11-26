// SelfTest075.swift
// Targeted checks for 0.7.5 (run inside `--suite targeted`, see SelfTest072.run). The CI runner is
// a virtual Mac: it can't click macOS permission prompts or play real audio through devices, so
// these check everything around them:
//   identity   – the running app's designated requirement (what macOS keys permissions to):
//                identifier com.blackhawk12222.Scribe, and certificate leaf (never a cdhash) when the
//                build was signed with the stable certificate; Info.plist usage strings + URL scheme
//   audio      – SourceMonitor (10 s of digital silence is flagged, room noise isn't), 16 kHz mono
//                conversion from 48 kHz stereo (interleaved and not), the mic + Mac-sound mixer with
//                a positive and a negative start offset, the gap filler after a mic restart, the
//                problem banners point at the right Settings pages
//   signin     – the sign-in link: scribe://auth-callback parsing (PKCE ?code=, implicit
//                #access_token=, error/expired), the PKCE S256 challenge, the /otp request carries
//                redirect_to + code_challenge; against a local stub server (no real inbox): link →
//                code exchange with this Mac's verifier → signed in (recovery key), implicit link →
//                /user → signed in, the 6-digit code still works, an expired link and a link from
//                another Mac explain themselves, and with no backend nothing happens at all
// All names and data are invented.

import Foundation
import AVFoundation
import CoreAudio

enum SelfTest075 {
    static func log(_ s: String) { SelfTest.log(s) }

    @MainActor static func run() async -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let i = identityCheck(); r["identity"] = i.0; fail += i.1
        let a = audioCheck(); r["audio"] = a.0; fail += a.1
        let s = await signInCheck(); r["signin"] = s.0; fail += s.1
        return (r, fail)
    }

    // MARK: Identity + Info.plist

    static func identityCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let id = Permissions.codeIdentity()
        let dr = id.designatedRequirement ?? ""
        r["designated_requirement"] = dr
        r["ad_hoc"] = id.adHoc
        r["certificate_leaf"] = id.certificateLeaf
        if dr.isEmpty { fail.append("identity: couldn't read the app's designated requirement") }
        else if !id.adHoc {
            if !dr.contains("identifier \"com.blackhawk12222.Scribe\"") { fail.append("identity: requirement lacks the bundle identifier: \(dr)") }
            if dr.contains("cdhash") { fail.append("identity: certificate-signed build pinned to a cdhash: \(dr)") }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        for k in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"] where (info[k] as? String ?? "").isEmpty {
            fail.append("identity: Info.plist has no \(k)")
        }
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        r["url_schemes"] = schemes
        if !schemes.contains("scribe") { fail.append("identity: scribe:// URL scheme not registered (CFBundleURLTypes)") }
        r["system_audio_permission"] = Permissions.systemAudioStatus().rawValue
        r["microphone_permission"] = Permissions.micName(AVCaptureDevice.authorizationStatus(for: .audio))
        if #available(macOS 14.4, *) {
            r["own_process_objects"] = SystemAudioTap.ownProcessObjects().count
            r["default_output"] = (try? SystemAudioTap.defaultOutputUID()) != nil ? "found" : "none (virtual Mac)"
        }
        return (r, fail)
    }

    // MARK: Audio helpers

    static func audioCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        // Silence monitor.
        let m = SourceMonitor(name: "mic")
        let t0 = Date()
        for k in 0..<110 { m.feed(peak: 0, duration: 0.1, now: t0.addingTimeInterval(Double(k) * 0.1)) }
        let silent = m.snapshot(now: t0.addingTimeInterval(11))
        r["silent_run_after_11s_zeros"] = silent.silentRun
        if silent.silentRun <= 10 { fail.append("audio: 11 s of zeros not flagged as silence (\(silent.silentRun))") }
        m.feed(peak: 0.003, duration: 0.1)      // a quiet room (≈ -50 dBFS) is not silence
        if m.snapshot().silentRun != 0 { fail.append("audio: room noise didn't end the silent run") }
        if m.snapshot(now: Date().addingTimeInterval(4)).sinceLastBuffer < 3.9 { fail.append("audio: time since last buffer wrong") }
        // 48 kHz stereo → 16 kHz mono (non-interleaved, then interleaved).
        for interleaved in [false, true] {
            guard let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved),
                  let conv = To16kMono(inFormat: f48, mix: .average),
                  let b = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 4800) else { fail.append("audio: converter setup (interleaved=\(interleaved))"); continue }
            b.frameLength = 4800
            let p = b.floatChannelData!
            for i in 0..<4800 {
                if interleaved { p[0][2 * i] = 0.2; p[0][2 * i + 1] = 0.4 } else { p[0][i] = 0.2; p[1][i] = 0.4 }
            }
            guard let (mono, peak) = conv.mono(b), let out = conv.convert(mono) else { fail.append("audio: conversion failed (interleaved=\(interleaved))"); continue }
            r["convert_\(interleaved ? "interleaved" : "planar")"] = ["frames": Int(out.frameLength), "peak": Double(peak)] as [String: Any]
            if abs(peak - 0.3) > 0.001 { fail.append("audio: stereo average wrong (\(peak), interleaved=\(interleaved))") }
            if out.frameLength < 1400 || out.frameLength > 1700 { fail.append("audio: 0.1 s at 48 kHz → \(out.frameLength) frames at 16 kHz") }
        }
        // Mixer: mic 2 s of 0.1; Mac sound 1 s of 0.2 starting 0.5 s later → 0.3 in [0.5, 1.5).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st075-mix-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, seconds: Double, value: Float) -> URL {
            let u = dir.appendingPathComponent(name)
            let f = try! AVAudioFile(forWriting: u, settings: MeetingMixer.wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let n = AVAudioFrameCount(seconds * 16_000)
            let b = AVAudioPCMBuffer(pcmFormat: To16kMono.out16k, frameCapacity: n)!
            b.frameLength = n
            for i in 0..<Int(n) { b.floatChannelData![0][i] = value }
            try! f.write(from: b)
            return u
        }
        func read(_ u: URL) -> [Float] {
            guard let f = try? AVAudioFile(forReading: u, commonFormat: .pcmFormatFloat32, interleaved: false),
                  let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                  (try? f.read(into: b)) != nil else { return [] }
            return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        }
        let mic = write("mic.wav", seconds: 2, value: 0.1)
        let sys = write("sys.wav", seconds: 1, value: 0.2)
        for (offset, probes) in [(0.5, [(0.25, 0.1), (1.0, 0.3), (1.75, 0.1)]), (-0.5, [(0.25, 0.3), (0.75, 0.1)])] {
            let out = dir.appendingPathComponent("mixed\(offset).wav")
            do {
                let res = try MeetingMixer.mix(mic: mic, system: sys, systemOffset: offset, out: out)
                let s = read(out)
                guard !s.isEmpty else { fail.append("audio: mixed file empty (offset \(offset))"); continue }
                var got: [String: Double] = [:]
                for (t, want) in probes {
                    let v = Double(s[min(s.count - 1, Int(t * 16_000))])
                    got[String(t)] = (v * 1000).rounded() / 1000
                    if abs(v - want) > 0.01 { fail.append("audio: mix offset \(offset) at \(t) s = \(v), want \(want)") }
                }
                r["mix_offset_\(offset)"] = ["seconds": Double(res.frames) / 16_000, "samples": got] as [String: Any]
                if res.frames != 32_000 { fail.append("audio: mix offset \(offset) length \(res.frames), want 32000") }
            } catch { fail.append("audio: mix threw \(error.localizedDescription)") }
        }
        // Gap filler: 1 s chunks, then a 2 s pause (mic restart) → 2 s of silence first.
        let c = RecordingClock()
        let s0 = Date()
        _ = c.micGap(adding: 16_000, now: s0)
        let g1 = c.micGap(adding: 16_000, now: s0.addingTimeInterval(1))
        let g2 = c.micGap(adding: 16_000, now: s0.addingTimeInterval(4))
        r["gap_frames"] = [g1, g2]
        if g1 != 0 || abs(g2 - 32_000) > 100 { fail.append("audio: gap filler gave \(g1), \(g2) (want 0, 32000)") }
        // Microphone choice: Automatic picks the built-in mic when the default input is a Bluetooth
        // headset (AirPods stay in music mode), otherwise the default; a chosen device wins; an
        // unplugged one falls back to Automatic.
        let builtIn = MicDevice(id: 11, uid: "BuiltInMicrophoneDevice", name: "MacBook Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
        let pods = MicDevice(id: 22, uid: "AA-BB-CC:input", name: "Sample AirPods", transport: kAudioDeviceTransportTypeBluetooth)
        let usb = MicDevice(id: 33, uid: "usb-mic-1", name: "Sample USB Mic", transport: kAudioDeviceTransportTypeUSB)
        let all = [builtIn, pods, usb]
        let rules: [(AudioDeviceID?, String, AudioDeviceID?)] = [(22, "auto", 11), (33, "auto", 33), (11, "auto", 11), (22, "system", 22),
                                                                (22, "usb-mic-1", 33), (22, "gone-device", 11), (nil, "auto", 11)]
        for (def, setting, want) in rules {
            let got = MicDevices.choose(all, defaultID: def, setting: setting)?.id
            if got != want { fail.append("audio: mic choice default=\(def.map(String.init) ?? "nil") setting=\(setting) → \(got.map(String.init) ?? "nil"), want \(want.map(String.init) ?? "nil")") }
        }
        if MicDevices.choose([pods], defaultID: 22, setting: "auto")?.id != 22 { fail.append("audio: only a headset mic → should still use it") }
        r["mic_inputs_on_this_mac"] = MicDevices.inputs().count
        r["mic_current"] = MicDevices.current().map { $0.isBluetooth ? "bluetooth" : $0.isBuiltIn ? "built-in" : "other" } ?? "none"
        // Banners open the right Settings pages.
        let panes: [(Recorder.AudioProblem, Permissions.Pane?)] = [(.micSilent, .microphone), (.micDenied, .microphone),
                                                                    (.systemSilent, .systemAudio), (.systemFailed("x"), .systemAudio), (.micNoAudio, nil)]
        for (p, want) in panes where p.pane != want { fail.append("audio: \(p) opens \(String(describing: p.pane))") }
        if !Recorder.AudioProblem.systemSilent.title.contains("can't hear") { fail.append("audio: system-silent banner title") }
        return (r, fail)
    }

    // MARK: Sign-in link (stub server, no real inbox)

    @MainActor static func signInCheck() async -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        // Parsing.
        typealias CB = SupabaseClient.Callback
        let cases: [(String, CB?)] = [
            ("scribe://auth-callback?code=abc-123", .pkce(code: "abc-123")),
            ("scribe://auth-callback#access_token=AT9&expires_at=1&expires_in=3600&refresh_token=RT9&token_type=bearer&type=magiclink",
             .implicit(accessToken: "AT9", refreshToken: "RT9", expiresIn: 3600)),
            ("scribe://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired",
             .failure("Email link is invalid or has expired")),
            ("scribe://auth-callback/?code=xyz", .pkce(code: "xyz")),
            ("scribe://somewhere-else?code=abc", nil),
            ("https://stub.supabase.invalid/auth-callback?code=abc", nil),
        ]
        var parsed = 0
        for (s, want) in cases {
            let got = SupabaseClient.parseCallback(URL(string: s)!)
            if got != want { fail.append("signin: parse \(s.prefix(40))… → \(String(describing: got)), want \(String(describing: want))") } else { parsed += 1 }
        }
        r["parse_cases_ok"] = "\(parsed)/\(cases.count)"
        // PKCE S256 (value computed independently with Python's hashlib).
        let ch = SupabaseClient.challenge(for: "scribe-selftest-verifier-0000000000000000000000")
        if ch != "kiLx_5TfQcugbLt58g1B1KOH7O7rgWfJBHhhsfRqiHQ" { fail.append("signin: S256 challenge \(ch)") }
        let v = SupabaseClient.newVerifier()
        if v.count < 43 || v.count > 128 || v.contains("=") || v.contains("+") || v.contains("/") { fail.append("signin: verifier format (\(v.count) chars)") }
        if SupabaseClient.otpPath != "/auth/v1/otp?redirect_to=scribe%3A%2F%2Fauth-callback" { fail.append("signin: otp path \(SupabaseClient.otpPath)") }
        r["otp_path"] = SupabaseClient.otpPath

        // Stub server flows.
        let cfg = AccountConfig.parse(url: "https://stub.supabase.invalid", key: "stub-anon-key-not-real-0000000000")!
        let sc = URLSessionConfiguration.ephemeral
        sc.protocolClasses = [StubAuthServer.self]
        let session = URLSession(configuration: sc)
        let user = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        func sessionJSON(_ at: String) -> [String: Any] {
            ["access_token": at, "refresh_token": "RT-" + at, "expires_in": 3600, "token_type": "bearer",
             "user": ["id": user, "email": "robin@sample.invalid"]]
        }
        StubAuthServer.reset([
            "POST /auth/v1/otp": (200, [String: Any]()),
            "POST /auth/v1/token": (200, sessionJSON("AT-PKCE")),
            "POST /auth/v1/verify": (200, sessionJSON("AT-CODE")),
            "GET /auth/v1/user": (200, ["id": user, "email": "robin@sample.invalid"]),
            "GET /rest/v1/sync_keys": (200, [[String: Any]]()),
            "POST /rest/v1/sync_keys": (201, [[String: Any]]()),
        ])

        // 1. Link (PKCE): send → the request carries redirect_to + the challenge of the stored verifier.
        let sec1 = MemorySecretStore()
        let m1 = AccountModel(config: cfg, secrets: sec1, defaults: SelfTest0732.suite("st075-pkce"), urlSession: session)
        await m1.sendCode(email: "Robin@Sample.invalid ")
        let otp = StubAuthServer.requests.first { $0.key == "POST /auth/v1/otp" }
        let stored = sec1.data(for: AccountModel.verifierName).flatMap { String(data: $0, encoding: .utf8) }
        if otp == nil { fail.append("signin: no /otp request") }
        if otp?.query.contains("redirect_to=scribe%3A%2F%2Fauth-callback") != true { fail.append("signin: /otp without redirect_to (\(otp?.query ?? ""))") }
        if let st = stored, otp?.body["code_challenge"] as? String != SupabaseClient.challenge(for: st) { fail.append("signin: /otp code_challenge doesn't match the stored verifier") }
        if otp?.body["code_challenge_method"] as? String != "s256" { fail.append("signin: code_challenge_method") }
        if stored == nil { fail.append("signin: no verifier kept for the link") }
        if m1.phase != .codeSent(email: "robin@sample.invalid") { fail.append("signin: after send phase \(m1.phase)") }
        r["notice_after_send"] = m1.notice ?? ""
        let handled = await m1.handleCallback(URL(string: "scribe://auth-callback?code=stub-auth-code")!)
        let tok = StubAuthServer.requests.first { $0.key == "POST /auth/v1/token" }
        if !handled { fail.append("signin: link not handled") }
        if tok?.query != "grant_type=pkce" { fail.append("signin: exchange used \(tok?.query ?? "no request")") }
        if tok?.body["auth_code"] as? String != "stub-auth-code" || tok?.body["code_verifier"] as? String != stored {
            fail.append("signin: exchange didn't send the code + this Mac's verifier")
        }
        if case .showRecoveryKey(let e, _) = m1.phase, e == "robin@sample.invalid" {} else { fail.append("signin: PKCE link → \(m1.phase) (\(m1.error ?? ""))") }
        if sec1.data(for: AccountModel.verifierName) != nil { fail.append("signin: verifier not cleared after use") }
        if sec1.data(for: "session") == nil { fail.append("signin: session not saved after the link") }
        r["pkce_phase"] = "\(m1.phase)".components(separatedBy: "recoveryKey").first ?? ""

        // 2. Implicit link (#access_token=…) → /user → signed in.
        StubAuthServer.clearRequests()
        let sec2 = MemorySecretStore()
        let m2 = AccountModel(config: cfg, secrets: sec2, defaults: SelfTest0732.suite("st075-impl"), urlSession: session)
        await m2.handleCallback(URL(string: "scribe://auth-callback#access_token=AT-IMPL&expires_in=3600&refresh_token=RT-IMPL&token_type=bearer&type=magiclink")!)
        let u = StubAuthServer.requests.first { $0.key == "GET /auth/v1/user" }
        if u?.authorization != "Bearer AT-IMPL" { fail.append("signin: implicit link didn't ask /user with its token") }
        if case .showRecoveryKey = m2.phase {} else { fail.append("signin: implicit link → \(m2.phase) (\(m2.error ?? ""))") }

        // 3. The 6-digit code still works.
        StubAuthServer.clearRequests()
        let m3 = AccountModel(config: cfg, secrets: MemorySecretStore(), defaults: SelfTest0732.suite("st075-code"), urlSession: session)
        await m3.sendCode(email: "robin@sample.invalid")
        await m3.verify(code: "123 456")
        let ver = StubAuthServer.requests.first { $0.key == "POST /auth/v1/verify" }
        if ver?.body["token"] as? String != "123456" || ver?.body["type"] as? String != "email" { fail.append("signin: code verify request wrong") }
        if case .showRecoveryKey = m3.phase {} else { fail.append("signin: code path → \(m3.phase) (\(m3.error ?? ""))") }

        // 4. Expired link / a link from another Mac: explained, nothing sent.
        StubAuthServer.clearRequests()
        let m4 = AccountModel(config: cfg, secrets: MemorySecretStore(), defaults: SelfTest0732.suite("st075-err"), urlSession: session)
        await m4.handleCallback(URL(string: "scribe://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!)
        if m4.error?.contains("expired") != true || m4.phase != .signedOut { fail.append("signin: expired link → \(m4.phase), \(m4.error ?? "no error")") }
        r["expired_message"] = m4.error ?? ""
        await m4.handleCallback(URL(string: "scribe://auth-callback?code=from-another-mac")!)
        if m4.error?.contains("another Mac") != true || m4.phase != .signedOut { fail.append("signin: link without a verifier → \(m4.error ?? "no error")") }
        if !StubAuthServer.requests.isEmpty { fail.append("signin: bad links still called the server (\(StubAuthServer.requests.map(\.key)))") }
        if await m4.handleCallback(URL(string: "https://sample.invalid/x")!) { fail.append("signin: a non-Scribe URL was treated as a sign-in link") }

        // 5. No backend (signed-out use): a link does nothing — no network, no Keychain.
        let sec5 = MemorySecretStore()
        let m5 = AccountModel(config: nil, secrets: sec5, defaults: SelfTest0732.suite("st075-none"), urlSession: session)
        await m5.handleCallback(URL(string: "scribe://auth-callback?code=abc")!)
        if m5.phase != .unavailable || !sec5.names.isEmpty || !StubAuthServer.requests.isEmpty { fail.append("signin: link changed something with no backend") }
        r["stub_requests_total"] = StubAuthServer.total
        // The build's own Supabase.plist (never print the key).
        r["bundled_config"] = AccountConfig.load(bundle: .main, environment: [:]) == nil ? "not configured" : "configured"
        return (r, fail)
    }
}

/// A tiny in-process Supabase stand-in (host stub.supabase.invalid) for the self-test.
final class StubAuthServer: URLProtocol {
    struct Request { var key: String; var query: String; var body: [String: Any]; var authorization: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (Int, Any)] = [:]
    nonisolated(unsafe) private static var recorded: [Request] = []
    nonisolated(unsafe) private(set) static var total = 0

    static func reset(_ r: [String: (Int, Any)]) { lock.lock(); routes = r; recorded = []; lock.unlock() }
    static func clearRequests() { lock.lock(); recorded = []; lock.unlock() }
    static var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.supabase.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var data = request.httpBody
        if data == nil, let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); data = d
        }
        let body = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        Self.lock.lock()
        Self.recorded.append(Request(key: key, query: url.query ?? "", body: body,
                                     authorization: request.value(forHTTPHeaderField: "Authorization")))
        Self.total += 1
        let route = Self.routes[key] ?? (404, ["msg": "no stub for \(key)"])
        Self.lock.unlock()
        let out = (try? JSONSerialization.data(withJSONObject: route.1)) ?? Data()
        let resp = HTTPURLResponse(url: url, statusCode: route.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: out)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
