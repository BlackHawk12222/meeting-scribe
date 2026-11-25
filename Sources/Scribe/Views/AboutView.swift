// AboutView.swift
// About + licenses. Open-source licenses (MIT, Apache, CC-BY) say: if you use
// someone's work, keep their copyright notice and give credit. 0.7.3.1: the credits come from
// Resources/Licenses/licenses.json (see CreditsView.swift), with the full texts bundled.

import SwiftUI

struct AboutView: View {
    /// Inside the Settings page (no own scroll view or background).
    var embedded = false
    /// 0.7.3.1: inside Settings the credits live on their own page (Settings › General ›
    /// Credits & licenses); without this the list shows inline.
    var openCredits: (() -> Void)? = nil

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

            if let openCredits {
                SettingsCard {
                    SettingRow(title: "Credits & licenses", detail: "Speech models, open-source code and fonts, with their licenses") {
                        Button("Open") { openCredits() }.buttonStyle(.nightSecondary)
                    }
                }
            } else {
                CreditsList(entries: LicenseCatalog.entries(), pins: LicenseCatalog.resolvedPins())
            }
        }
    }
}

