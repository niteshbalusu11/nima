import SwiftUI
import AVKit
import DeviceDiscoveryUI
import WiFiAware

struct NearbyView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 26.0, *), WiFiAwareRadio.supported {
                    if let nearby = model.nearby { NearbyControls(model: model, nearby: nearby) }
                    else {
                        VStack(spacing: 16) {
                            Text(message ?? "Preparing Nearby")
                            Button("Set up Nearby") { Task { await prepare() } }
                        }
                    }
                } else {
                    ContentUnavailableView("Nearby unavailable", systemImage: "wifi", description: Text("Nearby needs iOS 26 and a supported iPhone. Camera and cloud backup are still available."))
                }
            }
            .navigationTitle("Nearby").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(model.nearby?.receiving != nil)
            } }
        }
        .task { await prepare() }
    }
    private func prepare() async {
        guard #available(iOS 26.0, *), WiFiAwareRadio.supported else { return }
        do {
            if model.session?.deviceId == nil { try await model.registerSharingDevice() }
            else { try model.configureNearby() }
        } catch { message = error.localizedDescription }
    }
}

@available(iOS 26.0, *)
private struct NearbyControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nearby: NearbySharing
    @State private var pairing = false
    @State private var pairingBaseline: Set<WAPairedDevice.ID> = []
    @State private var joining = false
    @State private var selectedDevice: WAPairedDevice?
    @State private var ready = false
    @State private var error: String?
    var body: some View {
        Form {
            if nearby.receiving == nil {
                Section {
                    Button(nearby.sharing ? "Add nearby person" : "Share nearby", systemImage: "antenna.radiowaves.left.and.right") {
                        let addingPerson = nearby.sharing
                        Task {
                            do {
                                let devices = try await WAPairedDevice.allDevices.current() ?? [:]
                                try nearby.startSharing(start: model.recording ? model.recordingStarted : Date())
                                pairingBaseline = Set(devices.keys)
                                pairing = addingPerson || devices.isEmpty
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(!ready)
                    if nearby.sharing {
                        if let error = nearby.sharingError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Try again") {
                                do { try nearby.startSharing(start: model.recording ? model.recordingStarted : Date()) }
                                catch { self.error = error.localizedDescription }
                            }
                        } else if !nearby.sharingStatus.isEmpty { Text(nearby.sharingStatus).font(.caption).foregroundStyle(.secondary) }
                        Button("Stop sharing", role: .destructive) { nearby.stopSharing() }
                    } else {
                        Button("Join nearby", systemImage: "person.2") { joining = true }
                            .disabled(!ready || model.recording || model.stopping || model.preparingCapture)
                    }
                }
                if nearby.sharing {
                    Section("Sharing with") {
                        ForEach(nearby.approvals.filter { nearby.selected.contains($0.id) }) { approval in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(name(approval.recipientName))
                                    Text(nearby.senderStatus[approval.id] ?? "Connecting").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Stop", role: .destructive) { try? nearby.select(approval, enabled: false, start: Date()) }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text(nearby.receiveStatus)
                    Button("Stop receiving", role: .destructive) { Task { try? await model.receiveNearby(from: nil) } }
                } header: { Text("Receiving") } footer: { Text("Keep Nima open. Saved copies back up to the recorder’s account when online.") }
            }
            Section {
                NavigationLink { ReceivedCopiesView(nearby: nearby) } label: { Label("Received · \(nearby.received.count)", systemImage: "photo.on.rectangle") }
                NavigationLink("People") { NearbySettingsView(model: model) }
            }
            if let error { Text(error).font(.footnote) }
            if !ready {
                Button("Set up Nearby") { Task { await prepare() } }
                Text("Connect to the internet once to prepare this phone.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            await prepare()
            for await _ in await nearby.peers.updates() {
                guard !Task.isCancelled else { return }
                ready = (try? await nearby.peers.pairingCredentials()) != nil
                if ready { error = nil }
            }
        }
        .sheet(isPresented: $pairing) {
            NavigationStack {
                NativePairingView()
                    .navigationTitle("Share nearby")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pairing = false } } }
                    .task {
                        do {
                            for try await devices in WAPairedDevice.allDevices {
                                try Task.checkCancellation()
                                if !Set(devices.keys).isSubset(of: pairingBaseline) { pairing = false; return }
                            }
                        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
            }
        }
        .sheet(isPresented: $joining, onDismiss: {
            guard let device = selectedDevice else { return }
            selectedDevice = nil
            do { try model.joinNearby(device) } catch { self.error = error.localizedDescription }
        }) {
            NearbyJoinView { device in selectedDevice = device; joining = false }
        }
        .confirmationDialog("Receive from \(name(nearby.consent?.senderName ?? ""))?", isPresented: Binding(
            get: { nearby.consent != nil }, set: { if !$0 { nearby.resolveConsent(false) } }), titleVisibility: .visible) {
                Button("Save and back up") { nearby.resolveConsent(true) }
                Button("Cancel", role: .cancel) { nearby.resolveConsent(false) }
        } message: { Text("Save their photos and videos on this phone and upload them to their account using your connection.") }
        .interactiveDismissDisabled(nearby.receiving != nil)
        .onChange(of: nearby.receiving) { _, value in if value == nil { Task { try? await model.receiveNearby(from: nil) } } }
    }
    private func prepare() async {
        do {
            if (try? await nearby.peers.pairingCredentials()) == nil { try await nearby.peers.refresh() }
            _ = try await nearby.peers.pairingCredentials(); ready = true; error = nil
        } catch { ready = false; self.error = error.localizedDescription }
    }
    private func name(_ value: String) -> String { value.isEmpty ? "Nima member" : value }
}

@available(iOS 26.0, *)
private struct NearbyJoinView: View {
    let selected: (WAPairedDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [WAPairedDevice] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if !devices.isEmpty {
                    Section("Choose a phone") {
                        ForEach(devices) { device in
                            Button(device.name ?? device.pairingInfo?.pairingName ?? "Nearby iPhone", systemImage: "iphone") {
                                selected(device)
                            }
                        }
                    }
                }
                Section {
                    // Pairing grants device access. Observe allDevices instead of
                    // relying on the system picker to return a service endpoint.
                    DevicePicker(WASubscriberBrowser.wifiAware(.connecting(to: .userSpecifiedDevices, from: WASubscribableService.allServices[WiFiAwareRadio.service]!)), access: .permanent) { _ in } label: {
                        Label("Pair a phone", systemImage: "plus")
                    } fallback: {
                        Text("Nearby pairing is unavailable on this phone")
                    }
                }
                if let error { Text(error).font(.footnote) }
            }
            .navigationTitle("Join nearby").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            do {
                for try await paired in WAPairedDevice.allDevices {
                    try Task.checkCancellation()
                    devices = paired.values.sorted { $0.id < $1.id }
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@available(iOS 26.0, *)
private struct NativePairingView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DDDevicePairingViewController {
        let provider: WAPublisherListener = .wifiAware(.connecting(to: WAPublishableService.allServices[WiFiAwareRadio.service]!, from: .userSpecifiedDevices))
        return DDDevicePairingViewController(listenerProvider: provider, access: .permanent)
    }
    func updateUIViewController(_ controller: DDDevicePairingViewController, context: Context) {}
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
