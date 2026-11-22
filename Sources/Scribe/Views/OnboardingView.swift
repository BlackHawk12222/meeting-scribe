// OnboardingView.swift
// First launch: permissions, the one-time model download, and a place to try dictation.

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var permissions: Permissions
    @AppStorage("onboarded") private var onboarded = false
    @State private var tryText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Scribe").font(.largeTitle.bold())
                Text("Talk instead of type, in any app. Everything runs on this Mac.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Permissions")
                    PermissionRows()
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    step(2, "Speech models (one-time download)")
                    if store.engineReady {
                        Label("Ready — works offline from now on", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let e = store.engineError {
                        Text(e).foregroundStyle(.orange).font(.caption)
                        Button("Retry") { Task { await store.prepareEngine() } }
                    } else {
                        ProgressView(value: store.modelProgress ?? 0)
                        Text(store.engineStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    step(3, "Try it")
                    Text("Click in the box, then hold \(DictationSettings.holdKey.title) (or press \(DictationSettings.toggleShortcut?.label ?? "your shortcut")), say something, and let go.")
                        .font(.callout)
                    TextField("Your words appear here…", text: $tryText, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(6)
            }

            HStack {
                Text("Tip: Scribe lives in the menu bar (the waveform icon). Closing this window keeps it running.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onboarded = true }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20)
                .background(Color.primary, in: Circle()).foregroundStyle(Color(nsColor: .windowBackgroundColor))
            Text(title).font(.headline)
        }
    }
}
