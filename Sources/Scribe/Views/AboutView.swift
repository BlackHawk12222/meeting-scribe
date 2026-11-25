// AboutView.swift
// About + licenses. Open-source licenses (MIT, Apache, CC-BY) say: if you use
// someone's work, keep their copyright notice and give credit. This screen does that.

import SwiftUI

struct AboutView: View {
    /// Inside the Settings page (no own scroll view or background).
    var embedded = false

    var body: some View {
        if embedded {
            content
        } else {
            ScrollView { content.padding(24) }
                .background(Night.canvas)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                AppIconView(size: 96)
                Text("Scribe").font(.nightDisplay).foregroundStyle(Night.text)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.nightMeta).foregroundStyle(Night.text3).monospacedDigit()
                Text("Dictation and meeting notes that run entirely on your Mac.\nFree, no account, nothing uploaded.")
                    .font(.nightSecondary).foregroundStyle(Night.text2).multilineTextAlignment(.center)
                Text("Made by BlackHawk12222").font(.nightMeta).foregroundStyle(Night.text3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(NightCardBackground())

            SectionLabel(title: "Credits & licenses").padding(.top, 4)
            ForEach(Credits.all, id: \.name) { c in
                VStack(alignment: .leading, spacing: 5) {
                    Text(c.name).font(.nightHeadline).foregroundStyle(Night.text)
                    Text(c.what).font(.nightSecondary).foregroundStyle(Night.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(c.license).font(.system(size: 11, design: .monospaced)).foregroundStyle(Night.text3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nightCard(padding: 16)
            }
        }
    }
}

enum Credits {
    struct Credit { var name: String; var what: String; var license: String }

    /// Manrope's license text from the bundle (falls back to the notice if the file is missing).
    static var manropeLicense: String {
        let urls = [Bundle.main.url(forResource: "OFL", withExtension: "txt", subdirectory: "Fonts"),
                    Bundle.main.url(forResource: "OFL", withExtension: "txt")]
        for case let url? in urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return "Manrope, SIL Open Font License 1.1 — Copyright 2018 The Manrope Project Authors (https://github.com/googlefonts/manrope). scripts.sil.org/OFL"
    }

    static var all: [Credit] { [
        Credit(name: "Handy — github.com/cjpais/Handy",
               what: "Scribe's dictation design follows Handy: hold-to-talk + toggle hotkeys, Silero VAD to trim silence, Parakeet models, paste via the clipboard and restore it afterwards, filler-word list and the 300 ms tap threshold. Scribe's code is a new Swift implementation.",
               license: """
               MIT License

               Copyright (c) 2025 CJ Pais

               Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

               The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

               THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
               """),
        Credit(name: "FluidAudio — github.com/FluidInference/FluidAudio",
               what: "Runs every speech model on Core ML (speech-to-text, voice detection, speaker diarization).",
               license: "Apache License 2.0 — Copyright FluidInference. Full text: apache.org/licenses/LICENSE-2.0"),
        Credit(name: "NVIDIA Parakeet TDT 0.6B v2 and v3",
               what: "Speech-to-text models (Core ML conversions by FluidInference).",
               license: "CC-BY-4.0 — © NVIDIA. creativecommons.org/licenses/by/4.0"),
        Credit(name: "Silero VAD",
               what: "Voice activity detection: finds where you're talking (Core ML conversion by FluidInference).",
               license: "MIT License — Copyright (c) 2020-present Silero Team"),
        Credit(name: "pyannote speaker-diarization-community-1 + WeSpeaker",
               what: "Who-spoke-when segmentation and voice fingerprints for meetings (Core ML conversion by FluidInference).",
               license: "CC-BY-4.0 — pyannote.audio contributors / WeSpeaker. creativecommons.org/licenses/by/4.0"),
        Credit(name: "Scribe app icon",
               what: "A lavender sound wave of rounded capsule bars with four-point sparkles on a near-black tile, drawn in code (vector math, scripts/make_icon.py) for Scribe.",
               license: "Part of Scribe."),
        Credit(name: "Manrope, SIL Open Font License 1.1 — github.com/googlefonts/manrope",
               what: "The typeface used throughout Scribe (by Mikhail Sharanda and The Manrope Project Authors). Bundled in the app; the license ships next to it (Contents/Resources/Fonts/OFL.txt).",
               license: Credits.manropeLicense),
        Credit(name: "Apple Foundation Models",
               what: "Optional on-device clean-up and meeting notes on macOS 26 with Apple Intelligence.",
               license: "Part of macOS. Used under Apple's macOS license; nothing leaves the Mac."),
        Credit(name: "Self-test audio",
               what: "LibriSpeech (dictation test clip) and the AMI Meeting Corpus (meeting test), used only by `Scribe --selftest`.",
               license: "CC-BY-4.0 — LibriSpeech: Panayotov et al.; AMI: University of Edinburgh and partners."),
    ] }
}
