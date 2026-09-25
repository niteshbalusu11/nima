import SwiftUI
import AVKit

struct NearbyView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let nearby = model.nearby { NearbyControls(model: model, nearby: nearby) }
                else {
                    Form {
                        Section {
                            NavigationLink("Set up nearby") { NearbySettingsView(model: model) }
                        } footer: { Text("Approve people while online. Then share nearby without internet.") }
                    }
                }
            }
            .navigationTitle("Nearby").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(model.nearby?.receiving != nil)
            } }
        }
        .task { do { if model.session?.deviceId != nil { try model.configureNearby() } } catch { model.message = "Nearby setup unavailable" } }
    }
}

private struct NearbyControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nearby: NearbySharing
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                ForEach(nearby.approvals.filter { $0.sender == nearby.peers.device }) { approval in
                    Toggle(isOn: Binding(get: { nearby.selected.contains(approval.id) }, set: { enabled in
                        do { try nearby.select(approval, enabled: enabled, start: model.recording ? model.recordingStarted : Date()) }
                        catch { self.error = error.localizedDescription }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name(approval.recipientName))
                            if let status = nearby.senderStatus[approval.id] { Text(status).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if !nearby.approvals.contains(where: { $0.sender == nearby.peers.device }) { Text("Add people to start sharing").foregroundStyle(.secondary) }
            } header: { Text("Share new captures") } footer: { Text("Up to three people. Sharing resumes when you reopen the app.") }
            Section {
                if let id = nearby.receiving {
                    Text(name(nearby.approvals.first { $0.id == id }?.senderName ?? ""))
                    Text(nearby.receiveStatus).font(.subheadline).foregroundStyle(.secondary)
                    Button("Stop receiving", role: .destructive) { Task { try? await model.receiveNearby(from: nil) } }
                } else {
                    ForEach(nearby.approvals.filter { $0.recipient == nearby.peers.device }) { approval in
                        Button("Receive from \(name(approval.senderName))") {
                            Task {
                                do { try await model.receiveNearby(from: approval) }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(model.recording || model.stopping || model.preparingCapture)
                    }
                    if !nearby.approvals.contains(where: { $0.recipient == nearby.peers.device }) { Text("No approved senders").foregroundStyle(.secondary) }
                }
            } header: { Text("Receive") } footer: {
                Text("Keep this screen open to receive. Saved copies upload to the recorder’s account when a connection is available.")
            }
            Section {
                NavigationLink { ReceivedCopiesView(nearby: nearby) } label: {
                    Label("Received · \(nearby.received.count)", systemImage: "photo.on.rectangle")
                }
                NavigationLink("People") { NearbySettingsView(model: model) }
            }
            if let message = error ?? nearby.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .interactiveDismissDisabled(nearby.receiving != nil)
        .onChange(of: nearby.receiving) { _, value in
            if value == nil { Task { try? await model.receiveNearby(from: nil) } }
        }
    }
    private func name(_ value: String) -> String { value.isEmpty ? "Nearby member" : value }
}

struct ReceivedCopiesView: View {
    @ObservedObject var nearby: NearbySharing
    var body: some View {
        List(nearby.received) { capture in
            NavigationLink {
                ReceivedDetail(id: capture.id, nearby: nearby)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Label(capture.recorderName, systemImage: capture.local.kind == "photo" ? "photo" : "video")
                    Text(capture.local.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    Text(receivedStatus(capture, nearby: nearby)).font(.caption).foregroundStyle(capture.cloudComplete ? .green : .secondary)
                }
            }
        }
        .overlay { if nearby.received.isEmpty { ContentUnavailableView("No received copies", systemImage: "antenna.radiowaves.left.and.right") } }
        .navigationTitle("Received")
    }
}

@MainActor
private func receivedStatus(_ capture: ReceivedMediaStore.CaptureInfo, nearby: NearbySharing) -> String {
    if capture.cloudComplete { return capture.ending == "interrupted" ? "Interrupted recording · backed up" : "Backed up to recorder" }
    if let status = nearby.relayStatus[capture.id] { return status }
    let coverage = capture.expectedObjects.map { "\(capture.savedObjects) of \($0) fragments saved" } ?? "\(capture.savedObjects) fragments saved · ending unknown"
    return capture.complete ? "\(capture.ending == "interrupted" ? "Interrupted · " : "")Saved here · \(capture.cloudObjects) uploaded" : coverage
}

private struct ReceivedDetail: View {
    let id: String
    @ObservedObject var nearby: NearbySharing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = LivePlayback()
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var deleting = false
    @State private var busy = false
    @State private var retry = 0
    private var capture: ReceivedMediaStore.CaptureInfo? { nearby.received.first { $0.id == id } }
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Color.black
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if let player { VideoPlayer(player: player) }
                else { Text("Waiting for video").foregroundStyle(.secondary) }
            }
            if let capture {
                Text(receivedStatus(capture, nearby: nearby)).font(.footnote).foregroundStyle(.secondary)
                if capture.savedObjects > capture.local.parts.count { Text("Playback waits at missing fragments").font(.caption).foregroundStyle(.secondary) }
                Button(capture.complete ? "Save to Photos" : "Save available video") { Task { await export(capture) } }
                    .disabled(!capture.local.playable || busy)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Retry playback") { retry += 1 }
            }
        }
        .padding(.bottom)
        .navigationTitle(capture?.recorderName ?? "Received").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") }.disabled(busy)
        } }
        .confirmationDialog("Remove this copy?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Remove from this phone", role: .destructive) {
                guard let capture else { return }
                Task {
                    busy = true; stopPlayer()
                    do { try await nearby.remove(capture); dismiss() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        } message: { Text("Only this phone’s copy is removed. Fragments still waiting for upload may be lost if no other copy exists.") }
        .task(id: "\(retry)-\(scenePhase == .active)") {
            stopPlayer(); error = nil
            guard scenePhase == .active else { return }
            do {
                while !Task.isCancelled {
                    if let capture, capture.local.playable {
                        if capture.local.kind == "photo" {
                            let object = try await nearby.store.savedObject(captureHash: capture.hash, sequence: 0)
                            if let object { image = UIImage(data: try Data(contentsOf: object.file)) }
                        } else {
                            let url = try await playback.start(store: nearby.store, hash: capture.hash)
                            try Task.checkCancellation()
                            player = AVPlayer(url: url); player?.play()
                            while !Task.isCancelled {
                                if player?.currentItem?.status == .failed { throw MediaRecords.failure("Playback paused. Saved copies are safe.") }
                                try await Task.sleep(for: .seconds(1))
                            }
                        }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { stopPlayer() }
    }
    private func stopPlayer() { player?.pause(); player = nil; image = nil; playback.stop() }
    private func export(_ capture: ReceivedMediaStore.CaptureInfo) async {
        busy = true; defer { busy = false }
        do {
            guard await PhotoLibrary.requestAccess() else { throw MediaRecords.failure("Photos access off") }
            if capture.local.kind == "photo" {
                guard let object = try await nearby.store.savedObject(captureHash: capture.hash, sequence: 0) else { throw CancellationError() }
                try await PhotoLibrary.savePhoto(Data(contentsOf: object.file))
            } else {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let url = try await PhotoLibrary.exportVideo(parts: capture.local.parts, in: folder)
                try await PhotoLibrary.saveVideoFile(url)
            }
            error = "Saved to Photos"
        } catch { self.error = error.localizedDescription }
    }
}
