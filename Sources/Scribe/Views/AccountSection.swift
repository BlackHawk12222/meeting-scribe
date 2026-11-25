// AccountSection.swift
// 0.7.3.2 Profile › Account (optional; Scribe works fully signed out). Poster style: a hairline
// header, then one hairline card that changes with the account state:
//   coming soon (no backend configured) · email · 6-digit code · recovery key (shown once / typed
//   on another Mac) · signed in (email, last synced, Sync now, the two opt-in switches, Sign out,
//   Delete account and cloud data).

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AccountSection: View {
    @EnvironmentObject var store: Store
    @ObservedObject var account: AccountModel
    @State private var email = ""
    @State private var code = ""
    @State private var recovery = ""
    @State private var savedIt = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HairlineHeader(title: "Account").padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NightCardBackground())
            if let e = account.error {
                Label(e, systemImage: "exclamationmark.circle").font(.nightSecondary).foregroundStyle(Night.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let n = account.notice {
                Label(n, systemImage: "checkmark.circle").font(.nightSecondary).foregroundStyle(Night.ok)
            }
        }
        .alert("Delete your account and cloud data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await account.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your synced backup and your sign-in are deleted from the server. Everything on this Mac stays.")
        }
    }

    @ViewBuilder private var content: some View {
        switch account.phase {
        case .unavailable: comingSoon
        case .signedOut: signIn
        case .codeSent(let e): codeStep(e)
        case .needsRecoveryKey(let e): enterRecovery(e)
        case .showRecoveryKey(_, let key): showRecovery(key)
        case .signedIn(let e): signedIn(e)
        }
    }

    private static let why = "Back up and sync your Dictionary, Vocabulary, learned fixes, Styles and settings across your Macs, and get them back after a reinstall or on a new Mac. Encrypted on this Mac before upload; only you can read it. Audio never leaves your Mac."

    // MARK: States

    private var comingSoon: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Accounts coming soon", detail: Self.why) {
                Button("Create account / Sign in") {}
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                    .disabled(true)
            }
            NightDivider()
            CardNote(text: "Optional. Scribe works fully without an account; everything stays on this Mac.")
        }
        .accessibilityElement(children: .contain)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardNote(text: Self.why + " Later, your account also unlocks Scribe Pro.")
            NightDivider()
            HStack(spacing: 10) {
                NightField(placeholder: "Email", text: $email, height: 32, font: .nightBody) { send() }
                    .frame(maxWidth: 300)
                    .accessibilityLabel("Email")
                Button { send() } label: { Text("Create account / Sign in") }
                    .buttonStyle(NightButtonStyle(kind: .primary, height: 32))
                    .disabled(account.busy || email.isEmpty)
                if account.busy { CapsuleSpinner() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            NightDivider()
            CardNote(text: "No password: we email you a 6-digit code. Optional; Scribe works fully without an account.")
        }
    }

    private func codeStep(_ e: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardNote(text: "Type the 6-digit code we sent to \(e).")
            NightDivider()
            HStack(spacing: 10) {
                NightField(placeholder: "123456", text: $code, height: 32, font: .system(size: 15, weight: .semibold, design: .monospaced)) { verify() }
                    .frame(width: 140)
                    .accessibilityLabel("6-digit code")
                Button("Verify") { verify() }
                    .buttonStyle(NightButtonStyle(kind: .primary, height: 32))
                    .disabled(account.busy || code.filter(\.isNumber).count < 6)
                if account.busy { CapsuleSpinner() }
                Spacer(minLength: 0)
                Button("Use a different email") { code = ""; account.useDifferentEmail() }
                    .buttonStyle(NightButtonStyle(kind: .ghost, height: 28))
                Button("Send again") { Task { await account.sendCode(email: e) } }
                    .buttonStyle(NightButtonStyle(kind: .ghost, height: 28))
                    .disabled(account.busy)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }

    private func showRecovery(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardNote(text: "Save your recovery key. Your backup is encrypted with it, and Scribe can't reset it: another Mac (or this one after a reinstall) needs it to read your data. Keep it in a password manager or print it.")
            NightDivider()
            HStack(spacing: 12) {
                Text(key)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Night.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Recovery key")
                Spacer(minLength: 8)
                Button { copy(key) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
                Button { saveFile(key) } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            NightDivider()
            HStack(spacing: 10) {
                Toggle("I saved my recovery key", isOn: $savedIt).toggleStyle(.checkbox).font(.nightSecondary)
                Spacer()
                Button("Continue") { Task { await account.recoveryKeySaved(store: store) } }
                    .buttonStyle(NightButtonStyle(kind: .primary, height: 32))
                    .disabled(!savedIt || account.busy)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func enterRecovery(_ e: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardNote(text: "Signed in as \(e). This Mac needs your recovery key to read your backup (it's the key you saved when you made the account).")
            NightDivider()
            HStack(spacing: 10) {
                NightField(placeholder: "XXXX-XXXX-XXXX-…", text: $recovery, height: 32,
                           font: .system(size: 13, weight: .medium, design: .monospaced)) { unlock() }
                    .accessibilityLabel("Recovery key")
                Button("Unlock") { unlock() }
                    .buttonStyle(NightButtonStyle(kind: .primary, height: 32))
                    .disabled(account.busy || recovery.isEmpty)
                if account.busy { CapsuleSpinner() }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            NightDivider()
            HStack {
                Spacer()
                Button("Sign out") { Task { await account.signOut() } }.buttonStyle(NightButtonStyle(kind: .ghost, height: 28))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private func signedIn(_ e: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Night.posterGreen.opacity(0.14))
                    Image(systemName: "checkmark.icloud").font(.system(size: 15, weight: .medium)).foregroundStyle(Night.posterGreen)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(e).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Night.text).lineLimit(1)
                    Text(syncedText).font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(1)
                }
                Spacer(minLength: 10)
                if account.busy { CapsuleSpinner() }
                Button { Task { await account.syncNow(store: store) } } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(NightButtonStyle(kind: .primary, height: 32))
                    .disabled(account.busy)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            NightDivider()
            CardNote(text: "Synced: Dictionary, Vocabulary, learned fixes, Styles and settings. End-to-end encrypted. Audio, meetings and transcripts stay on this Mac.")
            NightDivider()
            ToggleRow(title: "Sync People", detail: "The names in your voice library.", isOn: $account.syncPeople)
            NightDivider()
            ToggleRow(title: "Sync voice profiles",
                      detail: "Voiceprints are biometric data; they're encrypted and only you can read them.",
                      isOn: $account.syncVoiceprints)
            NightDivider()
            HStack(spacing: 8) {
                Button("Sign out") { Task { await account.signOut() } }
                    .buttonStyle(NightButtonStyle(kind: .ghost, height: 28))
                Spacer()
                Button("Delete account and cloud data") { confirmDelete = true }
                    .buttonStyle(NightButtonStyle(kind: .danger, height: 28))
                    .disabled(account.busy)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private var syncedText: String {
        guard let d = account.lastSynced else { return "Not synced yet" }
        return "Last synced " + d.formatted(.relative(presentation: .named))
    }

    // MARK: Actions

    private func send() { Task { await account.sendCode(email: email) } }
    private func verify() { Task { await account.verify(code: code) } }
    private func unlock() { Task { await account.enterRecoveryKey(recovery, store: store) } }

    private func copy(_ key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    private func saveFile(_ key: String) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.plainText]
        p.nameFieldStringValue = "Scribe recovery key.txt"
        p.message = "Keep this somewhere safe, like a password manager or a USB stick."
        if p.runModal() == .OK, let url = p.url {
            let text = "Scribe recovery key\n\n\(key)\n\nYou need this to read your Scribe backup on another Mac.\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
