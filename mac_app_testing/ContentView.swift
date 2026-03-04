//
//  ContentView.swift
//  mac_app_testing
//
//  Created by jakob n on 2/7/26.
//

import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selection: VideoSelection?
    @State private var isImporterPresented = false
    @State private var importError: String?
    @State private var photosPickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            if let selection {
                EditorView(
                    selection: selection,
                    onClose: { closeSelection(selection) }
                )
            } else {
                HomeView(
                    openAction: { isImporterPresented = true },
                    photosPickerItem: $photosPickerItem
                )
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let needsStop = url.startAccessingSecurityScopedResource()
                selection = VideoSelection(url: url, needsStopAccessing: needsStop)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .onChange(of: photosPickerItem) { _, newValue in
            guard let newValue else { return }
            Task {
                await loadFromPhotos(newValue)
            }
        }
        .alert("Unable to open video", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown error.")
        }
    }

    private func closeSelection(_ selection: VideoSelection) {
        if selection.needsStopAccessing {
            selection.url.stopAccessingSecurityScopedResource()
        }
        self.selection = nil
    }

    @MainActor
    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        do {
            if let importItem = try await item.loadTransferable(type: VideoImport.self) {
                selection = VideoSelection(url: importItem.url, needsStopAccessing: false)
            } else {
                importError = "No compatible video asset found."
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}

private struct VideoSelection: Hashable {
    let url: URL
    let needsStopAccessing: Bool
}

private struct HomeView: View {
    let openAction: () -> Void
    @Binding var photosPickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 16) {
            Text("EchoClip")
                .font(.system(size: 28, weight: .semibold))
            Text("Import a .mov or .mp4 to start clipping.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Open Video", action: openAction)
                    .keyboardShortcut(.defaultAction)
                PhotosPicker(
                    selection: $photosPickerItem,
                    matching: .videos,
                    preferredItemEncoding: .automatic
                ) {
                    Text("Choose From Photos")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct EditorView: View {
    let selection: VideoSelection
    let onClose: () -> Void

    @State private var player = AVPlayer()
    @State private var isLoading = false
    @State private var playbackError: String?
    @State private var durationSeconds: Double = 0
    @State private var currentSeconds: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserverToken: Any?
    @State private var keyMonitor: Any?
    @State private var isPlaying = false
    @State private var queryText = ""
    @State private var inPointSeconds: Double = 0
    @State private var outPointSeconds: Double = 0
    @State private var thumbnails: [NSImage] = []

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Clips")
                        .font(.headline)
                    Spacer()
                    Button("Back", action: onClose)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("No clips yet.")
                        .foregroundStyle(.secondary)
                    Text("Create clips manually or with NLP.")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                Spacer()
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selection.url.lastPathComponent)
                            .font(.headline)
                        Text("Original video")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manual Clip") {}
                        .disabled(true)
                    Button("Auto Clip") {}
                        .disabled(true)
                }

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        TextField("Search query (NLP clip)", text: $queryText)
                            .textFieldStyle(.roundedBorder)
                        Button("Run") {}
                            .disabled(true)
                    }

                    PlayerView(player: player)
                        .aspectRatio(16.0 / 9.0, contentMode: ContentMode.fit)
                        .frame(minWidth: 520, maxWidth: CGFloat.infinity, minHeight: 320, maxHeight: CGFloat.infinity)
                        .cornerRadius(10)
                        .shadow(radius: 8, y: 2)
                        .overlay {
                            if isLoading {
                                ProgressView()
                            }
                        }

                    TrimTimelineView(
                        images: thumbnails,
                        durationSeconds: durationSeconds,
                        currentSeconds: $currentSeconds,
                        inPointSeconds: $inPointSeconds,
                        outPointSeconds: $outPointSeconds,
                        isScrubbing: $isScrubbing,
                        onSeek: { seek(to: $0) }
                    )

                    PlaybackControlsView(
                        isPlaying: $isPlaying,
                        currentSeconds: currentSeconds,
                        durationSeconds: durationSeconds,
                        outPointSeconds: outPointSeconds,
                        onTogglePlay: { togglePlayPause() },
                        onReplay: { replayFromInPoint() }
                    )
                }
            }
            .padding(16)
        }
        .task(id: selection.url) {
            await loadPlayerItem()
        }
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            removeTimeObserver()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        .alert("Unable to play video", isPresented: Binding(
            get: { playbackError != nil },
            set: { if !$0 { playbackError = nil } }
        )) {
            Button("OK", role: .cancel) { playbackError = nil }
        } message: {
            Text(playbackError ?? "Unknown error.")
        }
    }

    @MainActor
    private func loadPlayerItem() async {
        isLoading = true
        playbackError = nil

        let asset = AVURLAsset(url: selection.url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            guard isPlayable else {
                throw PlaybackError.notPlayable
            }
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            durationSeconds = max(duration.seconds, 0)
            inPointSeconds = clamp(inPointSeconds, 0, durationSeconds)
            if outPointSeconds == 0 || outPointSeconds > durationSeconds {
                outPointSeconds = durationSeconds
            }
            currentSeconds = inPointSeconds
            await player.seek(to: CMTime(seconds: inPointSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            addTimeObserver()
            await loadThumbnails(from: asset)
        } catch {
            playbackError = error.localizedDescription
        }

        isLoading = false
    }

    private func addTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !isScrubbing {
                currentSeconds = time.seconds
            }
            isPlaying = player.timeControlStatus == .playing
            if outPointSeconds > 0, time.seconds >= outPointSeconds {
                player.pause()
                isPlaying = false
                currentSeconds = outPointSeconds
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func seek(to seconds: Double) {
        let clamped = clamp(seconds, 0, durationSeconds)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func markInPoint() {
        inPointSeconds = clamp(currentSeconds, 0, max(outPointSeconds, 0))
    }

    private func markOutPoint() {
        outPointSeconds = clamp(currentSeconds, max(inPointSeconds, 0), durationSeconds)
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if currentSeconds < inPointSeconds || currentSeconds >= outPointSeconds {
            currentSeconds = inPointSeconds
            seek(to: inPointSeconds)
        }
        player.play()
        isPlaying = true
    }

    private func replayFromInPoint() {
        currentSeconds = inPointSeconds
        seek(to: inPointSeconds)
        player.play()
        isPlaying = true
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if isTextInputFocused() {
                return event
            }
            switch event.charactersIgnoringModifiers {
            case " ":
                togglePlayPause()
                return nil
            case "i":
                markInPoint()
                return nil
            case "o":
                markOutPoint()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func isTextInputFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView
    }

    private func loadThumbnails(from asset: AVAsset) async {
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration > 0 else { return }

        let count = 24
        let times = (0..<count).map { index in
            CMTime(seconds: (duration / Double(count)) * Double(index), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)

        let images = await generateThumbnails(with: generator, times: times)

        await MainActor.run {
            thumbnails = images
        }
    }
}

private struct VideoImport: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try importFile($0) }
        FileRepresentation(importedContentType: .mpeg4Movie) { try importFile($0) }
    }

    private static func importFile(_ received: ReceivedTransferredFile) throws -> VideoImport {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoClipImports", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let destinationURL = tempDirectory.appendingPathComponent(received.file.lastPathComponent)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: received.file, to: destinationURL)
        return VideoImport(url: destinationURL)
    }
}

private enum PlaybackError: LocalizedError {
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "This video isn’t playable on this Mac."
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct TrimTimelineView: View {
    let images: [NSImage]
    let durationSeconds: Double
    @Binding var currentSeconds: Double
    @Binding var inPointSeconds: Double
    @Binding var outPointSeconds: Double
    @Binding var isScrubbing: Bool
    let onSeek: (Double) -> Void

    private let thumbSize = CGSize(width: 72, height: 46)
    private let thumbSpacing: CGFloat = 6
    private let handleWidth: CGFloat = 10
    private let handleHeight: CGFloat = 58

    var body: some View {
        let contentWidth = max(
            CGFloat(images.count) * (thumbSize.width + thumbSpacing) - thumbSpacing,
            200
        )

        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: thumbSpacing) {
                    if images.isEmpty {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .frame(width: contentWidth, height: thumbSize.height)
                            .overlay(Text("Generating thumbnails…").foregroundStyle(.secondary))
                    } else {
                        ForEach(images.indices, id: \.self) { index in
                            Image(nsImage: images[index])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: thumbSize.width, height: thumbSize.height)
                                .clipped()
                                .cornerRadius(5)
                        }
                    }
                }
                .frame(height: thumbSize.height)

                GeometryReader { geo in
                    let width = geo.size.width
                    let inX = position(for: inPointSeconds, width: width)
                    let outX = position(for: outPointSeconds, width: width)
                    let playheadX = position(for: currentSeconds, width: width)

                    Rectangle()
                        .fill(Color.yellow.opacity(0.22))
                        .frame(width: max(outX - inX, 0), height: thumbSize.height)
                        .offset(x: inX, y: 0)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: thumbSize.height + 12)
                        .offset(x: playheadX - 1, y: -6)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isScrubbing = true
                                    let seconds = seconds(for: value.location.x, width: width)
                                    currentSeconds = clamp(seconds, 0, durationSeconds)
                                }
                                .onEnded { _ in
                                    isScrubbing = false
                                    onSeek(currentSeconds)
                                }
                        )

                    handleView(isLeft: true)
                        .frame(width: handleWidth, height: handleHeight)
                        .offset(x: inX - handleWidth / 2, y: (thumbSize.height - handleHeight) / 2)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isScrubbing = true
                                    let newX = clamp(inX + value.translation.width, 0, max(outX - 4, 0))
                                    let seconds = seconds(for: newX, width: width)
                                    inPointSeconds = clamp(seconds, 0, outPointSeconds)
                                    currentSeconds = inPointSeconds
                                }
                                .onEnded { _ in
                                    isScrubbing = false
                                    onSeek(inPointSeconds)
                                }
                        )

                    handleView(isLeft: false)
                        .frame(width: handleWidth, height: handleHeight)
                        .offset(x: outX - handleWidth / 2, y: (thumbSize.height - handleHeight) / 2)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isScrubbing = true
                                    let newX = clamp(outX + value.translation.width, min(inX + 4, width), width)
                                    let seconds = seconds(for: newX, width: width)
                                    outPointSeconds = clamp(seconds, inPointSeconds, durationSeconds)
                                    currentSeconds = outPointSeconds
                                }
                                .onEnded { _ in
                                    isScrubbing = false
                                    onSeek(outPointSeconds)
                                }
                        )
                }
            }
            .frame(width: contentWidth, height: max(thumbSize.height, handleHeight))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: handleHeight + 12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func position(for seconds: Double, width: CGFloat) -> CGFloat {
        guard durationSeconds > 0, width > 0 else { return 0 }
        return CGFloat(seconds / durationSeconds) * width
    }

    private func seconds(for position: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(position / width) * durationSeconds
    }

    private func handleView(isLeft: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .overlay(
                Image(systemName: isLeft ? "chevron.compact.right" : "chevron.compact.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
            )
    }
}

private struct PlaybackControlsView: View {
    @Binding var isPlaying: Bool
    let currentSeconds: Double
    let durationSeconds: Double
    let outPointSeconds: Double
    let onTogglePlay: () -> Void
    let onReplay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onTogglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])

            if currentSeconds >= max(outPointSeconds - 0.05, 0), outPointSeconds > 0 {
                Button("Replay", action: onReplay)
            }

            Spacer()
            Text(formatTime(currentSeconds))
                .foregroundStyle(.secondary)
            Text("/")
                .foregroundStyle(.secondary)
            Text(formatTime(durationSeconds))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

private func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
    min(max(value, minValue), maxValue)
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let totalSeconds = max(Int(seconds.rounded()), 0)
    let minutes = totalSeconds / 60
    let remaining = totalSeconds % 60
    return String(format: "%d:%02d", minutes, remaining)
}

private func generateThumbnails(with generator: AVAssetImageGenerator, times: [CMTime]) async -> [NSImage] {
    let timeValues = times.map { NSValue(time: $0) }
    return await withCheckedContinuation { continuation in
        var results = Array<NSImage?>(repeating: nil, count: timeValues.count)
        var remaining = timeValues.count
        let lock = NSLock()

        generator.generateCGImagesAsynchronously(forTimes: timeValues) { requestedTime, cgImage, _, _, _ in
            let index = times.firstIndex(where: {
                $0.value == requestedTime.value && $0.timescale == requestedTime.timescale
            }) ?? 0
            if let cgImage {
                results[index] = NSImage(cgImage: cgImage, size: .zero)
            }

            lock.lock()
            remaining -= 1
            let shouldFinish = remaining == 0
            lock.unlock()

            if shouldFinish {
                continuation.resume(returning: results.compactMap { $0 })
            }
        }
    }
}
