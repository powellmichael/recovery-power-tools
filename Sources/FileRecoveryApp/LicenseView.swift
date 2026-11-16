import LicenseKit
import SwiftUI

/// Shown when an unlicensed copy is asked to recover files. Scanning and
/// previewing stay free, so by this point the user has already seen exactly
/// what they would be paying to get back.
struct LicenseSheet: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @State private var key = ""
    @State private var rejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("A licence is needed to recover files", systemImage: "key.fill")
                .font(.title2.weight(.semibold))

            Text("Scanning and previewing are free, and your results stay here. Recovering the files to another drive needs a licence: a one-time purchase, with no subscription.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Already bought one? Paste your licence key:")
                    .font(.callout.weight(.medium))
                TextEditor(text: $key)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 84)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Licence key")
                if rejected {
                    Label("That key is not valid for this app. Copy the whole key from your purchase email, starting with RPT1.", systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if let url = RecoveryViewModel.purchaseURL {
                    Link("Buy a Licence", destination: url)
                }
                Spacer()
                Button("Not Now", role: .cancel) { viewModel.showLicensePrompt = false }
                    .keyboardShortcut(.cancelAction)
                Button("Activate") { rejected = !viewModel.activateLicense(key) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

/// Licence status in Settings: who it belongs to, or how to add one.
struct LicenseSettingsSection: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        Section("Licence") {
            if viewModel.licensePublicKey == nil {
                Text("Development build. Recovery is unlocked.")
                    .foregroundStyle(.secondary)
            } else if let license = viewModel.license {
                LabeledContent("Licensed to", value: license.name)
                LabeledContent("Email", value: license.email)
                LabeledContent("Issued", value: license.issued.formatted(date: .abbreviated, time: .omitted))
                Button("Remove Licence From This Mac") { viewModel.removeLicense() }
            } else {
                Text("No licence. Scanning and previewing are free; recovering files needs a licence.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                Button("Enter Licence Key…") { viewModel.showLicensePrompt = true }
            }
        }
    }
}
