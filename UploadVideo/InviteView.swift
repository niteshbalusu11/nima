import SwiftUI
import CoreImage.CIFilterBuiltins

struct InviteView: View {
    let api: API
    @State private var invite: Invitation?
    @State private var qr: UIImage?
    @State private var creating = false
    @State private var copied = false
    @State private var message: String?
    private struct Invitation: Decodable {
        let token: String
        let expiresAt: Int64
        var expiration: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }
    }
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if let invite, let qr {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 320).accessibilityLabel("Invite QR code")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let expired = context.date >= invite.expiration
                    VStack(spacing: 20) {
                        if expired { Text("Invite expired").foregroundStyle(.secondary) }
                        else {
                            Text("Expires \(invite.expiration, format: .dateTime.weekday(.abbreviated).hour().minute())")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button(copied ? "Copied" : "Copy token") {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: invite.token]],
                                options: [.localOnly: true, .expirationDate: invite.expiration])
                            copied = true
                        }.disabled(expired)
                    }
                }
            }
            Button { Task { await create() } } label: {
                if creating { ProgressView().frame(maxWidth: .infinity) }
                else { Text(invite == nil ? "Create invite" : "New invite").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(creating)
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(28).frame(maxWidth: 400).frame(maxWidth: .infinity)
        .navigationTitle("Invite person").navigationBarTitleDisplayMode(.inline)
    }
    private func create() async {
        guard !creating else { return }
        creating = true; message = nil; defer { creating = false }
        do {
            let next: Invitation = try await api.request("POST", "invites", body: Data("{}".utf8))
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data((InviteToken.prefix + next.token).utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
                  let image = CIContext().createCGImage(output, from: output.extent) else {
                message = "Could not show invite"; return
            }
            invite = next; qr = UIImage(cgImage: image); copied = false
        } catch let error as APIError { message = error.message }
        catch { message = "Offline" }
    }
}
