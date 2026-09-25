import SwiftUI
import AVKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

private struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let name = UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

struct GalleryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var importError: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 12) {
                    ForEach(model.captures) { capture in
                        NavigationLink {
                            CaptureDetail(id: capture.id, model: model)
                        } label: {
                            VStack(spacing: 6) {
                                CaptureThumbnail(capture: capture, library: model.library)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(alignment: .bottomTrailing) {
                                        if capture.kind == "video" {
                                            Label(duration(capture.duration), systemImage: "play.fill")
                                                .font(.caption2.weight(.semibold)).padding(5)
                                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5)).padding(4)
                                        }
                                    }
                                UploadStatus(uploaded: capture.uploaded).font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(capture.kind == "video" ? "Video" : "Photo"), \(capture.createdAt.formatted()), \(capture.uploaded ? "Uploaded" : "Pending")")
                    }
                }.padding(.horizontal, 3)
            }
            .overlay {
                if model.captures.isEmpty { ContentUnavailableView("No captures", systemImage: "photo.on.rectangle") }
            }
            .safeAreaInset(edge: .bottom) {
                if importing { ProgressView("Importing…").padding().frame(maxWidth: .infinity).background(.regularMaterial) }
            }
            .interactiveDismissDisabled(model.managingCapture || importing)
            .navigationTitle("Recents").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 0, matching: .any(of: [.images, .videos])) {
                        Text("Import")
                    }.disabled(model.managingCapture || importing)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(model.managingCapture || importing) }
            }
            .onChange(of: selectedItems) { _, items in
                guard !items.isEmpty, !importing else { return }
                Task { await importSelected(items) }
            }
            .alert("Could not import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(importError ?? "Try again") }
        }
    }
    private func importSelected(_ items: [PhotosPickerItem]) async {
        importing = true
        var failed = 0
        for item in items {
            do {
                if item.supportedContentTypes.first?.conforms(to: .movie) == true {
                    guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                        throw APIError(status: 0, message: "Could not read video")
                    }
                    defer { try? FileManager.default.removeItem(at: video.url) }
                    try await model.importVideo(video.url)
                } else {
                    guard let photo = try await item.loadTransferable(type: Data.self) else {
                        throw APIError(status: 0, message: "Could not read photo")
                    }
                    try await model.importPhoto(photo)
                }
            } catch { failed += 1 }
        }
        selectedItems = []
        importing = false
        if failed > 0 { importError = failed == 1 ? "One item could not be imported." : "\(failed) items could not be imported." }
    }
    private func duration(_ value: Double) -> String {
        let seconds = Int(value.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct CaptureThumbnail: View {
    let capture: LocalCapture?
    let library: CaptureLibrary
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.14)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(systemName: capture?.kind == "video" ? "video" : "photo.on.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: capture?.thumbnailID) {
            image = nil
            guard let capture else { return }
            if let data = try? await library.thumbnail(for: capture), !Task.isCancelled { image = UIImage(data: data) }
        }
    }
}

private struct UploadStatus: View {
    let uploaded: Bool
    var body: some View {
        Label(uploaded ? "Uploaded" : "Pending", systemImage: uploaded ? "checkmark.icloud" : "icloud.and.arrow.up")
            .foregroundStyle(uploaded ? .green : .orange)
    }
}

private struct CaptureDetail: View {
    let id: String
    @ObservedObject var model: AppModel
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var message: String?
    @State private var confirmingDelete = false
    @State private var deletionError: String?
    @Environment(\.dismiss) private var dismiss
    private var capture: LocalCapture? { model.captures.first { $0.id == id } }
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Color.black
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if let player { VideoPlayer(player: player) }
                else if let message { Text(message).foregroundStyle(.secondary) }
                else { ProgressView() }
            }
            if let capture { UploadStatus(uploaded: capture.uploaded).font(.subheadline).padding(.bottom) }
        }
        .navigationTitle(capture?.kind == "video" ? "Video" : "Photo").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.managingCapture)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.managingCapture { ProgressView() }
                else {
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete capture").disabled(capture == nil)
                }
            }
        }
        .confirmationDialog("Delete capture?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    player?.pause()
                    do {
                        try await model.deleteCapture(id)
                        player = nil; image = nil; dismiss()
                    } catch let error as APIError { deletionError = error.message }
                    catch { deletionError = "Check your connection and try again." }
                }
            }
        } message: {
            Text("Removes it from this app and the cloud. Copies in Photos stay.")
        }
        .alert("Could not delete", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(deletionError ?? "Try again") }
        .task(id: id) {
            guard let capture else { return }
            do {
                if capture.kind == "photo" {
                    let data = try await model.library.photo(for: capture)
                    if !Task.isCancelled { image = UIImage(data: data) }
                } else {
                    let url = try await model.library.video(for: capture)
                    guard !Task.isCancelled else { return }
                    player = AVPlayer(url: url); player?.play()
                }
            } catch { if !Task.isCancelled { message = "Could not open" } }
        }
        .onDisappear { player?.pause(); player = nil }
    }
}
