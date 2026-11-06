import AppKit
import CoreImage.CIFilterBuiltins
import MimamoriCore
import SwiftUI

/// Settings › iPhone: show the agents on paired iPhones, pair one, and remove one.
struct CompanionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pairing = false
    @State private var removing: CompanionPairings.Phone?

    private var companion: CompanionController { model.companion }

    var body: some View {
        let settings = SettingsBinding.make(model)
        Form {
            Section {
                Toggle("Show agents on your iPhone", isOn: settings.companionEnabled)
                    .help("Let paired iPhones on your network show your agents, as the Agents window does")
                if let problem = companion.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("iPhone companion")
            } footer: {
                Text("With this on, Mimamori listens on your local network for the iPhones paired below, and only those: each connects with a key of its own, encrypted, so nobody else on the network can read what is sent. Off, nothing listens. The first time, macOS asks to let Mimamori find devices on your local network.")
            }

            Section {
                if companion.pairings.phones.isEmpty {
                    Text("No iPhone is paired yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(companion.pairings.phones) { phone in
                    PairedPhoneRow(phone: phone, connected: companion.connected.contains(phone.id)) {
                        removing = phone
                    }
                }
                Button("Pair iPhone…") {
                    companion.startPairing()
                    pairing = companion.pairingCode != nil
                }
                .disabled(!companion.isOn)
                .help(companion.isOn
                      ? "Show a code to scan with your iPhone's camera"
                      : "Turn on Show agents on your iPhone first")
            } header: {
                Text("Paired iPhones")
            } footer: {
                Text("Install Mimamori on your iPhone, then choose Pair iPhone… and scan the code with the iPhone's camera. Tasks and steps reach the iPhone only when \u{201C}Show tasks and steps in widgets\u{201D} is on, in Settings › Agents.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pairing, onDismiss: { companion.endPairing() }) {
            PairingSheet(companion: companion) { pairing = false }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this iPhone")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { companion.remove(removing) }
                removing = nil
            }
        } message: {
            Text("It stops showing your agents at once. To use it again, pair it again.")
        }
    }
}

/// A paired phone: its name, and whether it's connected or when it was last.
private struct PairedPhoneRow: View {
    let phone: CompanionPairings.Phone
    let connected: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(phone.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(connected ? .green : .secondary)
            }
            Spacer()
            Button("Remove…", action: onRemove)
                .help("Unpair \(phone.name): it can no longer connect")
                .accessibilityLabel("Remove \(phone.name)")
        }
    }

    private var detail: String {
        if connected { return "Connected" }
        if let seen = phone.lastSeen { return "Last connected \(Format.relative(seen, to: Date()))" }
        return "Paired \(Format.dateTime.string(from: phone.pairedAt))"
    }
}

/// The code to scan, until a phone pairs with it.
private struct PairingSheet: View {
    let companion: CompanionController
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let phone = companion.justPaired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Paired with \(phone.name)")
                    .font(.title2.weight(.semibold))
                Text("It shows your agents whenever it's on the same network as this Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let code = companion.pairingCode {
                Text("Pair your iPhone")
                    .font(.title2.weight(.semibold))
                QRCodeImage(text: code.url.absoluteString)
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("Pairing code for Mimamori on your iPhone")
                Text("Open the Camera on your iPhone and point it at the code, then tap the link to open it in Mimamori. Your iPhone needs to be on the same network as this Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The code works once, while this window is open.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button(companion.justPaired != nil ? "Done" : "Cancel", action: onDone)
                .keyboardShortcut(companion.justPaired != nil ? .defaultAction : .cancelAction)
                .help(companion.justPaired != nil ? "Close this window" : "Close this window; the code stops working")
        }
        .padding(24)
        .frame(width: 360)
    }
}

/// `text` as a QR code, its modules kept sharp.
private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
