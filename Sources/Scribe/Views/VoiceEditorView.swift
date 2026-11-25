// VoiceEditorView.swift
// 0.7.3 "Name voices": an audio editor for one meeting (Meeting › Name voices…).
//  • Waveform timeline with the speakers as colored bands (names on them), a time ruler to scrub,
//    a playhead. Space plays/pauses (unless you're typing in a field). Click the waveform to seek.
//  • Drag on the waveform to select; drag the selection's edges (or the ± buttons, 0.1 s) to trim.
//    Zoom 1–8×.
//  • Assign the selection to a person (chips) or a new name; "Assign all to…" for the whole file.
//    The transcript below updates at once. Undo (⌘Z) steps back; nothing is saved until Save.
//  • Save: lines get the new speakers, confirmed audio teaches each person's voiceprint, typed
//    names go into Vocabulary (Store+VoiceEdit.swift). The speech model is not retrained.
// Dictations don't keep audio, so this is for meetings only.

import SwiftUI
import AppKit
import AVFoundation

/// Space = play/pause, only when no text field is being edited and no modifier key is held.
enum VoiceEditorKeys {
    static let spaceKeyCode: UInt16 = 49

    static func togglesPlayback(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?) -> Bool {
        guard keyCode == spaceKeyCode else { return false }
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        if firstResponder is NSText || firstResponder is NSTextView || firstResponder is NSTextField { return false }
        return true
    }
}

@MainActor
final class VoiceEditorModel: ObservableObject {
    enum Target: Hashable { case person(UUID), name(String) }

    private struct Snapshot {
        var draft: Meeting
        var newNames: [String: String]
        var ranges: [String: [ClosedRange<Double>]]
        var typed: [String]
    }

    let meetingID: UUID
    @Published var draft: Meeting
    @Published var newNames: [String: String] = [:]
    @Published var ranges: [String: [ClosedRange<Double>]] = [:]
    @Published var typedNames: [String] = []
    @Published var selection: ClosedRange<Double>?
    @Published var time: Double = 0
    @Published var playing = false
    @Published var zoom: Double = 1
    @Published var peaks: [Float] = []
    @Published var saving = false
    @Published private var history: [Snapshot] = []
    let duration: Double
    private var player: AVAudioPlayer?
    private var keyMonitor: Any?
    private let audioURL: URL?
    /// Snapshot/self-test: no audio file, no key monitor.
    let isPreview: Bool

    init(meeting: Meeting, audioURL: URL?, preview: Bool = false) {
        meetingID = meeting.id
        draft = meeting
        self.audioURL = audioURL
        isPreview = preview
        duration = max(meeting.duration, meeting.utterances.map(\.end).max() ?? 0, 1)
    }

    var canUndo: Bool { !history.isEmpty }
    var changed: Bool { !history.isEmpty }

    // MARK: Audio

    func load() {
        guard !isPreview, let url = audioURL else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        let bins = min(6000, max(800, Int(duration * 25)))
        Task.detached(priority: .userInitiated) {
            let p = VoiceEditorModel.readPeaks(url: url, bins: bins)
            await MainActor.run { self.peaks = p }
        }
    }

    /// Max level per bin, 0…1 (AVAudioFile, read in chunks so long meetings stay light).
    nonisolated static func readPeaks(url: URL, bins: Int) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0, bins > 0 else { return [] }
        let total = f.length
        let per = max(1, Int64(total) / Int64(bins))
        var out = [Float](repeating: 0, count: bins)
        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) else { return [] }
        var pos: Int64 = 0
        while pos < total {
            do { try f.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            if let ch = buf.floatChannelData?[0] {
                for j in 0..<n {
                    let b = min(bins - 1, Int((pos + Int64(j)) / per))
                    let v = abs(ch[j])
                    if v > out[b] { out[b] = v }
                }
            }
            pos += Int64(n)
        }
        let mx = out.max() ?? 0
        return mx > 0 ? out.map { $0 / mx } : out
    }

    func togglePlay() {
        if isPreview { playing.toggle(); return }
        guard let p = player else { return }
        if p.isPlaying { p.pause(); playing = false }
        else {
            if let s = selection, time < s.lowerBound || time >= s.upperBound { seek(s.lowerBound) }
            p.currentTime = time
            p.play(); playing = true
        }
    }

    /// Sets the selection from two times (any order), kept inside the recording and ≥ 0.1 s.
    func setSelection(_ a: Double, _ b: Double) {
        var lo = max(0, min(a, b)), hi = min(duration, max(a, b))
        if hi - lo < 0.1 { if lo + 0.1 <= duration { hi = lo + 0.1 } else { lo = max(0, hi - 0.1) } }
        selection = lo...hi
    }

    func seek(_ t: Double) {
        time = min(max(0, t), duration)
        player?.currentTime = time
    }

    func tick() {
        guard let p = player, playing else { return }
        time = p.currentTime
        if !p.isPlaying { playing = false }
    }

    func stop() {
        player?.stop()
        playing = false
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Space bar → play/pause (see VoiceEditorKeys).
    func installKeys() {
        guard keyMonitor == nil, !isPreview else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard VoiceEditorKeys.togglesPlayback(keyCode: e.keyCode, modifiers: e.modifierFlags,
                                                  firstResponder: e.window?.firstResponder) else { return e }
            MainActor.assumeIsolated { self?.togglePlay() }
            return nil
        }
    }
    var keysInstalled: Bool { keyMonitor != nil }

    // MARK: Editing

    private func push() { history.append(Snapshot(draft: draft, newNames: newNames, ranges: ranges, typed: typedNames)) }

    func undo() {
        guard let s = history.popLast() else { return }
        draft = s.draft; newNames = s.newNames; ranges = s.ranges; typedNames = s.typed
    }

    /// Assign `range` (default: the selection) to a person or a typed name. Returns the speaker key.
    @discardableResult
    func assign(_ target: Target, range: ClosedRange<Double>? = nil, people: [Person]) -> String? {
        guard let r = range ?? selection, r.upperBound - r.lowerBound >= 0.05 else { return nil }
        push()
        var m = draft
        let key: String
        switch target {
        case .person(let id):
            key = VoiceEdit.ensureCluster(&m, personID: id)
        case .name(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { history.removeLast(); return nil }
            if !typedNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { typedNames.append(name) }
            if let p = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                key = VoiceEdit.ensureCluster(&m, personID: p.id)
            } else {
                let existing = newNames.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }?.key
                key = VoiceEdit.ensureCluster(&m, personID: nil, existingDraftKey: existing)
                newNames[key] = name
            }
        }
        draft = VoiceEdit.assign(m, range: r, toKey: key)
        ranges[key, default: []].append(r)
        // Drop names whose speaker vanished (fully overwritten).
        let alive = Set(draft.clusters.map(\.key))
        newNames = newNames.filter { alive.contains($0.key) }
        return key
    }

    func assignAll(_ target: Target, people: [Person]) {
        assign(target, range: 0...duration, people: people)
    }

    /// The commit for Store.commitVoiceEdit (embeddings filled in by `save`).
    func commit(embeddings: [String: [[Float]]]) -> VoiceEditCommit {
        VoiceEditCommit(draft: draft, newNames: newNames, embeddings: embeddings, typedNames: typedNames,
                        confirmedKeys: Set(ranges.keys))
    }

    func save(store: Store) async {
        saving = true
        stop()
        // One pass through the voice model for every confirmed range, then split per speaker.
        let keys = ranges.keys.sorted()
        let all = keys.flatMap { ranges[$0] ?? [] }
        var embeddings: [String: [[Float]]] = [:]
        if !all.isEmpty {
            let vecs = await store.embedRanges(meetingID: meetingID, all)
            let counts = keys.map { VoiceEdit.embeddingSpans(ranges[$0] ?? []).count }
            if vecs.count == counts.reduce(0, +) {
                var at = 0
                for (k, n) in zip(keys, counts) { embeddings[k] = Array(vecs[at..<at + n]); at += n }
            }
        }
        store.commitVoiceEdit(meetingID: meetingID, commit(embeddings: embeddings))
        saving = false
    }

    // MARK: Looks

    func name(_ key: String, store: Store) -> String {
        if let n = newNames[key] { return n }
        return store.displayName(draft, key: key)
    }

    func color(_ key: String, store: Store) -> Color {
        if let n = newNames[key] {
            let i = (newNames.values.sorted().firstIndex(of: n) ?? 0) + store.people.count
            return Palette.color(i)
        }
        if let p = store.person(draft.clusters.first(where: { $0.key == key })?.personID) { return Palette.color(p.colorIndex) }
        return Night.unnamed
    }
}

struct VoiceEditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VoiceEditorModel
    @State private var newName = ""
    @State private var drag: DragMode?
    static let size = CGSize(width: 1040, height: 720)

    private enum DragMode { case pending(Double), select(Double), trimStart, trimEnd, scrub }
    private let rulerH: CGFloat = 22, bandH: CGFloat = 30, waveH: CGFloat = 150

    init(meeting: Meeting, audioURL: URL?, preview: VoiceEditorModel? = nil) {
        _model = StateObject(wrappedValue: preview ?? VoiceEditorModel(meeting: meeting, audioURL: audioURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            NightDivider()
            VStack(alignment: .leading, spacing: 14) {
                transport
                timeline
                selectionBar
                assignBar
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            NightDivider().padding(.top, 16)
            transcript
            NightDivider()
            footer
        }
        .frame(minWidth: 900, idealWidth: Self.size.width, minHeight: 640, idealHeight: Self.size.height)
        .background(Night.canvas)
        .foregroundStyle(Night.text)
        .onAppear { model.load(); model.installKeys() }
        .onDisappear { model.stop() }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in model.tick() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Name voices").font(.nightTitle)
                Text(model.draft.title.isEmpty ? "Untitled meeting" : model.draft.title)
                    .font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(1)
            }
            Spacer()
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.nightSecondary)
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!model.canUndo)
            Button("Cancel") { model.stop(); dismiss() }.buttonStyle(.nightGhost)
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await model.save(store: store); dismiss() }
            } label: { Text(model.saving ? "Saving…" : "Save") }
                .buttonStyle(.nightPrimary)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.changed || model.saving)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
    }

    private var footer: some View {
        Text("Save teaches each person's voiceprint from the parts you confirmed and adds new names to Vocabulary so they're spelled right. The speech model itself isn't retrained.")
            .font(.nightMeta).foregroundStyle(Night.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Night.onPrimary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Night.primary))
            }
            .buttonStyle(.plain)
            .help("Play / pause (Space)")
            .accessibilityLabel(model.playing ? "Pause" : "Play")
            Text("\(Self.stamp(model.time)) / \(Self.stamp(model.duration))")
                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Night.text2)
            Text("Space plays · click to jump · drag to select · drag the edges to trim")
                .font(.nightMeta).foregroundStyle(Night.text3).lineLimit(1)
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(Night.text3)
            Slider(value: $model.zoom, in: 1...8).frame(width: 120).tint(Night.accent)
                .accessibilityLabel("Zoom")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(Night.text3)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, geo.size.width * model.zoom)
            ScrollView(.horizontal) {
                timelineCanvas(width: width)
                    .frame(width: width, height: rulerH + bandH + waveH)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in dragChanged(g, width: width) }
                        .onEnded { g in dragEnded(g, width: width) })
            }
            .scrollIndicators(model.zoom > 1 ? .visible : .never)
        }
        .frame(height: rulerH + bandH + waveH + 4)
        .background(RoundedRectangle(cornerRadius: Night.rCard, style: .continuous).fill(Night.well))
        .overlay(RoundedRectangle(cornerRadius: Night.rCard, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Night.rCard, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording timeline")
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / model.duration) * w }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { min(max(0, Double(x / max(w, 1)) * model.duration), model.duration) }

    private func timelineCanvas(width: CGFloat) -> some View {
        let lines = model.draft.utterances
        let names = Dictionary(uniqueKeysWithValues: Set(lines.map(\.speakerKey)).map { ($0, model.name($0, store: store)) })
        let colors = Dictionary(uniqueKeysWithValues: Set(lines.map(\.speakerKey)).map { ($0, model.color($0, store: store)) })
        let peaks = model.peaks.isEmpty ? Self.flatPeaks(lines, duration: model.duration) : model.peaks
        return Canvas { ctx, size in
            let w = size.width
            // Ruler: a tick every 10 s (5 s when zoomed in), labels every minute or 30 s.
            let step: Double = model.duration / Double(max(1, w / 90)) > 30 ? 60 : (model.zoom > 3 ? 5 : 10)
            var s = 0.0
            while s <= model.duration {
                let px = x(s, w)
                ctx.fill(Path(CGRect(x: px, y: rulerH - 6, width: 1, height: 6)), with: .color(Night.line2))
                if Int(s) % Int(step * 3) == 0 {
                    ctx.draw(Text(Self.stamp(s, tenths: false)).font(.system(size: 10.5)).foregroundColor(Night.text3),
                             at: CGPoint(x: px + 3, y: 3), anchor: .topLeading)
                }
                s += step
            }
            // Speaker bands with names.
            for u in lines {
                let a = x(u.start, w), b = max(a + 2, x(u.end, w))
                let r = CGRect(x: a, y: rulerH + 3, width: b - a, height: bandH - 8)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(colors[u.speakerKey] ?? Night.unnamed))
                if b - a > 46, let n = names[u.speakerKey] {
                    var c = ctx
                    c.clip(to: Path(r))
                    c.draw(Text(n).font(.system(size: 11, weight: .semibold)).foregroundColor(.white),
                           at: CGPoint(x: a + 6, y: r.midY), anchor: .leading)
                }
            }
            // Waveform: one bar per pixel column, colored by who speaks there.
            let top = rulerH + bandH, mid = top + waveH / 2
            let cols = Int(w / 2)
            let sorted = lines.sorted { $0.start < $1.start }
            var li = 0
            for c in 0..<max(cols, 1) {
                let t0 = Double(c) / Double(max(cols, 1)) * model.duration
                let pi = min(peaks.count - 1, Int(Double(c) / Double(max(cols, 1)) * Double(peaks.count)))
                let v = peaks.isEmpty ? 0 : CGFloat(max(0.04, peaks[max(0, pi)]))
                let h = v * (waveH / 2 - 8)
                while li < sorted.count && sorted[li].end <= t0 { li += 1 }
                let who: Utterance? = (li < sorted.count && sorted[li].start <= t0) ? sorted[li] : nil
                let color = who.flatMap { colors[$0.speakerKey] } ?? Night.text3
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(c) * 2, y: mid - h, width: 1.4, height: h * 2), cornerRadius: 0.7),
                         with: .color(color.opacity(who == nil ? 0.45 : 0.9)))
            }
            // Selection with edge handles.
            if let sel = model.selection {
                let a = x(sel.lowerBound, w), b = x(sel.upperBound, w)
                ctx.fill(Path(CGRect(x: a, y: rulerH, width: b - a, height: size.height - rulerH)), with: .color(Night.accent.opacity(0.16)))
                for e in [a, b] {
                    ctx.fill(Path(CGRect(x: e - 1, y: rulerH, width: 2, height: size.height - rulerH)), with: .color(Night.accent))
                    ctx.fill(Path(roundedRect: CGRect(x: e - 5, y: top + waveH / 2 - 14, width: 10, height: 28), cornerRadius: 3),
                             with: .color(Night.accent))
                }
            }
            // Playhead.
            let p = x(model.time, w)
            ctx.fill(Path(CGRect(x: p - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Night.live))
            ctx.fill(Path(ellipseIn: CGRect(x: p - 4, y: rulerH - 8, width: 8, height: 8)), with: .color(Night.live))
        }
    }

    /// Before the file is read (and in previews): a flat line where people talk.
    static func flatPeaks(_ lines: [Utterance], duration: Double, bins: Int = 600) -> [Float] {
        (0..<bins).map { i in
            let t = Double(i) / Double(bins) * duration
            guard lines.contains(where: { t >= $0.start && t < $0.end }) else { return 0.05 }
            let v = abs(sin(Double(i) * 0.37) * 0.6 + sin(Double(i) * 1.7) * 0.3)
            return Float(0.25 + v * 0.75)
        }
    }

    private func dragChanged(_ g: DragGesture.Value, width w: CGFloat) {
        let now = t(g.location.x, w)
        if drag == nil {
            let sx = g.startLocation.x
            if g.startLocation.y < rulerH { drag = .scrub }
            else if let s = model.selection, abs(sx - x(s.lowerBound, w)) <= 7 { drag = .trimStart }
            else if let s = model.selection, abs(sx - x(s.upperBound, w)) <= 7 { drag = .trimEnd }
            else { drag = .pending(t(sx, w)) }
        }
        switch drag {
        case .scrub?: model.seek(now)
        case .trimStart?: if let s = model.selection { model.setSelection(min(now, s.upperBound - 0.1), s.upperBound) }
        case .trimEnd?: if let s = model.selection { model.setSelection(s.lowerBound, max(now, s.lowerBound + 0.1)) }
        case .pending(let a)?:
            if abs(g.translation.width) > 3 { drag = .select(a); model.setSelection(a, now) }
        case .select(let a)?: model.setSelection(a, now)
        case nil: break
        }
    }

    private func dragEnded(_ g: DragGesture.Value, width w: CGFloat) {
        if case .pending(let a)? = drag {
            // A click: jump there; a click outside the selection clears it.
            if let s = model.selection, !s.contains(a) { model.selection = nil }
            model.seek(a)
        }
        drag = nil
    }

    // MARK: Selection + assign

    private var selectionBar: some View {
        HStack(spacing: 10) {
            if let s = model.selection {
                Text("Selection").font(.nightLabel).foregroundStyle(Night.text2)
                nudge("Start", s.lowerBound) { d in model.setSelection(min(s.lowerBound + d, s.upperBound - 0.1), s.upperBound) }
                nudge("End", s.upperBound) { d in model.setSelection(s.lowerBound, max(s.upperBound + d, s.lowerBound + 0.1)) }
                Text(String(format: "%.1f s", s.upperBound - s.lowerBound)).font(.nightSecondary).monospacedDigit()
                    .foregroundStyle(Night.text3)
                Button { model.seek(s.lowerBound); if !model.playing { model.togglePlay() } } label: {
                    Label("Play selection", systemImage: "play")
                }.buttonStyle(.nightSecondary)
                Button("Clear") { model.selection = nil }.buttonStyle(.nightGhost)
            } else {
                Text("Drag across the waveform to pick who's talking there, or use “Assign all to…”.")
                    .font(.nightSecondary).foregroundStyle(Night.text3)
            }
            Spacer()
        }
        .frame(height: Night.controlHeight)
    }

    private func nudge(_ label: String, _ value: Double, _ by: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.nightSecondary).foregroundStyle(Night.text3)
            Button { by(-0.1) } label: { Image(systemName: "minus") }.buttonStyle(NightIconButtonStyle(size: 22))
                .accessibilityLabel("\(label) earlier")
            Text(Self.stamp(value)).font(.system(size: 13, weight: .medium)).monospacedDigit().frame(minWidth: 56)
            Button { by(0.1) } label: { Image(systemName: "plus") }.buttonStyle(NightIconButtonStyle(size: 22))
                .accessibilityLabel("\(label) later")
        }
    }

    private var targets: [(VoiceEditorModel.Target, String, Color)] {
        var out: [(VoiceEditorModel.Target, String, Color)] = []
        let inMeeting = Set(model.draft.clusters.compactMap(\.personID))
        let ordered = store.people.sorted { (inMeeting.contains($0.id) ? 0 : 1, $0.name) < (inMeeting.contains($1.id) ? 0 : 1, $1.name) }
        for p in ordered { out.append((.person(p.id), p.name, Palette.color(p.colorIndex))) }
        for (k, n) in model.newNames.sorted(by: { $0.value < $1.value }) { out.append((.name(n), n, model.color(k, store: store))) }
        return out
    }

    private var assignBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Assign to").font(.nightLabel).foregroundStyle(Night.text2)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(targets.enumerated()), id: \.offset) { _, t in
                        Button { model.assign(t.0, people: store.people) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(t.2).frame(width: 8, height: 8)
                                Text(t.1).font(.nightSecondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).frame(height: Night.controlHeight)
                            .background(Capsule().fill(Night.surface))
                            .overlay(Capsule().strokeBorder(Night.line2, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.selection == nil)
                        .opacity(model.selection == nil ? 0.5 : 1)
                    }
                }
            }
            .scrollIndicators(.never)
            NightField(placeholder: "New name", text: $newName, onSubmit: assignTyped).frame(width: 160)
            Button("Assign", action: assignTyped).buttonStyle(.nightPrimary)
                .disabled(model.selection == nil || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Menu {
                ForEach(Array(targets.enumerated()), id: \.offset) { _, t in
                    Button(t.1) { model.assignAll(t.0, people: store.people) }
                }
                let typed = newName.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty {
                    Divider()
                    Button("“\(typed)” (new)") { model.assignAll(.name(typed), people: store.people); newName = "" }
                }
            } label: { Text("Assign all to…").font(.nightButton) }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
    }

    private func assignTyped() {
        guard model.selection != nil else { return }
        if model.assign(.name(newName), people: store.people) != nil { newName = "" }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.draft.utterances) { u in
                    let inSel = model.selection.map { u.start < $0.upperBound && u.end > $0.lowerBound } ?? false
                    let playingHere = model.time >= u.start && model.time < u.end
                    Button {
                        model.selection = u.start...u.end
                        model.seek(u.start)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Self.stamp(u.start, tenths: false)).font(.nightMeta).monospacedDigit()
                                .foregroundStyle(Night.text3).frame(width: 44, alignment: .leading)
                            HStack(spacing: 6) {
                                Circle().fill(model.color(u.speakerKey, store: store)).frame(width: 8, height: 8)
                                Text(model.name(u.speakerKey, store: store)).font(.nightSmallStrong).lineLimit(1)
                            }
                            .frame(width: 130, alignment: .leading)
                            Text(u.text).font(.nightBody).foregroundStyle(Night.text).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 24).padding(.vertical, 7)
                        .background(inSel ? Night.accentSoft : (playingHere ? Night.hover : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    // MARK: Format

    /// "1:02.4" (or "1:02" without tenths).
    static func stamp(_ t: Double, tenths: Bool = true) -> String {
        let v = max(0, t)
        let m = Int(v) / 60, s = Int(v) % 60
        if !tenths { return String(format: "%d:%02d", m, s) }
        return String(format: "%d:%02d.%d", m, s, Int((v - floor(v)) * 10))
    }
}
