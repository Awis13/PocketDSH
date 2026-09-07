import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

private func previewImage(_ data: Data, dimension: Int = 1000) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: dimension] as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}
struct ImageComposer: View {
    @EnvironmentObject var store: PocketStore
    @State private var showPhotos = false
    @State private var files = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(store.images) { image in
                            ZStack(alignment: .topTrailing) {
                                if let thumbnail = previewImage(image.data, dimension: 200) { Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: 78, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }
                                Button { store.removeImage(image.id) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7)).padding(3) }.accessibilityLabel("Remove image").disabled(store.submitting)
                            }
                        }
                    }
                }.frame(height: 78)
            }
            HStack(spacing: 18) {
                Button { showPhotos = true } label: { Label("Photos", systemImage: "photo") }.accessibilityIdentifier("attachPhoto")
                Button { files = true } label: { Label("Files", systemImage: "paperclip") }
                if store.preparingImages { ProgressView().controlSize(.small) }
            }.font(.caption).disabled(store.preparingImages || store.submitting || store.images.count >= store.imageLimits.maxCount)
        }
        .sheet(isPresented: $showPhotos) {
            PhotoLibraryPicker(limit: max(1, store.imageLimits.maxCount - store.images.count)) { providers in
                showPhotos = false
                guard !providers.isEmpty, let id = store.selectedID, !store.preparingImages else { return }
                let host = store.endpoint
                store.preparingImages = true
                Task {
                    defer { store.preparingImages = false }
                    for provider in providers {
                        do {
                            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { throw HarnessError(message: "Could not read the photo") }
                            let data: Data = try await withCheckedThrowingContinuation { continuation in
                                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                                    if let data { continuation.resume(returning: data) }
                                    else { continuation.resume(throwing: error ?? HarnessError(message: "Could not load the photo")) }
                                }
                            }
                            await store.addImage(data: data, name: provider.suggestedName ?? "photo", sessionID: id, host: host)
                        } catch { store.error = error.localizedDescription }
                    }
                }
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard let id = store.selectedID else { return }
            let host = store.endpoint
            store.preparingImages = true
            Task {
                defer { store.preparingImages = false }
                do {
                    let urls = try result.get()
                    guard urls.count + store.images.count <= store.imageLimits.maxCount else { throw HarnessError(message: "You can attach up to \(store.imageLimits.maxCount) images") }
                    for url in urls {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw HarnessError(message: "This file exceeds 64 MB") }
                        let data = try await Task.detached { try Data(contentsOf: url) }.value
                        await store.addImage(data: data, name: url.lastPathComponent, sessionID: id, host: host)
                    }
                } catch { store.error = error.localizedDescription }
            }
        }
    }
}
struct RemoteAttachment: View {
    @EnvironmentObject var store: PocketStore
    let reference: JSON
    let sessionID: String
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var presented = false
    @State private var attempt = 0
    var body: some View {
        Group {
            if let image {
                Button { presented = true } label: { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12)) }.accessibilityLabel("Open image")
            } else if let failure {
                Button { attempt += 1 } label: { Label(failure, systemImage: "arrow.clockwise").font(.caption) }
            } else { ProgressView().frame(width: 160, height: 100) }
        }
        .task(id: store.endpoint + sessionID + reference["attachmentId"].string + String(attempt) + String(store.connected)) {
            image = nil; failure = nil
            do {
                let data = try await store.attachmentData(reference["attachmentId"].string, sessionID: sessionID)
                guard !Task.isCancelled else { return }
                image = previewImage(data, dimension: 2048)
                if image == nil { failure = "Could not open the image" }
            } catch { if !Task.isCancelled { failure = "Retry loading image" } }
        }
        .fullScreenCover(isPresented: $presented) { if let image { ImageViewer(image: image) } }
    }
}
private struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: UIScreen.main.bounds.width * zoom * magnification, height: UIScreen.main.bounds.height * zoom * magnification)
            }.defaultScrollAnchor(.center)
                .gesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }.onEnded { zoom = min(4, max(1, zoom * $0.magnification)) })
                .onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1 }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(.white).padding(16).background(.ultraThinMaterial, in: Circle()) }.padding(20).accessibilityLabel("Close image")
        }
    }
}

private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let limit: Int
    let onSelection: ([NSItemProvider]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = limit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelection: ([NSItemProvider]) -> Void
        init(onSelection: @escaping ([NSItemProvider]) -> Void) { self.onSelection = onSelection }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { onSelection(results.map(\.itemProvider)) }
    }
}
