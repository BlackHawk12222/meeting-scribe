// AboutView.swift
// About + licenses. Open-source licenses (MIT, Apache, CC-BY) say: if you use
// someone's work, keep their copyright notice and give credit. This screen does that.

import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading) {
                        Text("Scribe").font(.title2.bold())
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · made by BlackHawk12222")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Dictation and meeting notes that run 100% on your Mac. Free, no account, nothing uploaded.")
                    .font(.callout)

                Text("Credits & licenses").font(.headline).padding(.top, 6)
                ForEach(Credits.all, id: \.name) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.name).font(.subheadline.bold())
                        Text(c.what).font(.caption).foregroundStyle(.secondary)
                        Text(c.license).font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
        }
    }
}

enum Credits {
    struct Credit { var name: String; var what: String; var license: String }

    static let all: [Credit] = [
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
        Credit(name: "Apple Foundation Models",
               what: "Optional on-device clean-up and meeting notes on macOS 26 with Apple Intelligence.",
               license: "Part of macOS. Used under Apple's macOS license; nothing leaves the Mac."),
        Credit(name: "Self-test audio",
               what: "LibriSpeech (dictation test clip) and the AMI Meeting Corpus (meeting test), used only by `Scribe --selftest`.",
               license: "CC-BY-4.0 — LibriSpeech: Panayotov et al.; AMI: University of Edinburgh and partners."),
    ]
}
