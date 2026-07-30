import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = ConversionViewModel()
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            // ── Main content ──
            VStack(spacing: 0) {
                dropZone
                    .padding(16)

                optionsBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                fileList
                    .padding(.horizontal, 8)

                if vm.isConverting || !vm.statusMessage.isEmpty {
                    statusBar
                        .padding(12)
                }

                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .frame(minWidth: 380)

            // ── Sidebar: live subtitles ──
            if vm.isConverting || !vm.subtitles.isEmpty {
                subtitleSidebar
                    .frame(width: 280)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                )

            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Drop MP3 / MP4 files here")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("or click Browse below")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 110)
        .onDrop(of: [.data], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Options Bar

    private var optionsBar: some View {
        HStack(spacing: 12) {
            Label("Model:", systemImage: "brain")
                .foregroundStyle(.secondary)
            Text(vm.modelPath.components(separatedBy: "/").last ?? "large-v3")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider().frame(height: 16)

            Toggle("Auto-detect language", isOn: $vm.useAutoDetect)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            if !vm.useAutoDetect {
                Picker("", selection: $vm.language) {
                    Text("English").tag("en")
                    Text("Chinese").tag("zh")
                    Text("Japanese").tag("ja")
                    Text("Korean").tag("ko")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Spanish").tag("es")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Russian").tag("ru")
                }
                .frame(width: 100)
                .disabled(vm.useAutoDetect)
            }

            Spacer()
        }
    }

    // MARK: - File List

    private var fileList: some View {
        ZStack {
            if vm.files.isEmpty {
                EmptyFilesView()
            } else {
                List {
                    ForEach(Array(vm.files.enumerated()), id: \.element.id) { idx, file in
                        FileRowView(
                            file: file, index: idx + 1,
                            isCurrentFile: file.fileName == vm.currentFile,
                            durationDisplay: vm.durationDisplay(for: file),
                            onDelete: vm.isConverting ? nil : { vm.removeFiles(at: IndexSet(integer: idx)) }
                        )
                    }
                    .onDelete { offsets in
                        if !vm.isConverting { vm.removeFiles(at: offsets) }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 36)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary, lineWidth: 1).opacity(0.15)
        )
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(spacing: 4) {
            if vm.isConverting {
                ProgressView(value: vm.durationProgress)
                    .progressViewStyle(.linear)
            }
            HStack {
                if vm.isConverting {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor, options: .repeating)
                        .foregroundColor(.accentColor)
                        .frame(width: 14)
                }
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !vm.progressText.isEmpty {
                    Text(vm.progressText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if !vm.totalElapsedText.isEmpty {
                    Text(vm.totalElapsedText)
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button("Browse…") {
                browseFiles()
            }
            .disabled(vm.isConverting)

            if !vm.files.isEmpty {
                Text("\(vm.files.count) file(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear", role: .destructive) {
                    vm.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if vm.isConverting {
                Button("Cancel", role: .cancel) {
                    vm.cancelConversion()
                }
            }

            Button(action: { vm.startConversion() }) {
                Label("Convert to SRT", systemImage: "waveform.badge.mic")
                    .frame(minWidth: 60)
            }
            .keyboardShortcut(.return)
            .disabled(vm.files.isEmpty || vm.isConverting)
        }
    }

    // MARK: - Helpers

    private static func collectMediaFiles(from url: URL) -> [URL] {
        let allowedExts = ["mp3", "mp4"]
        guard url.hasDirectoryPath else {
            return allowedExts.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil
        ) else { return [] }
        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            if allowedExts.contains(fileURL.pathExtension.lowercased()) {
                results.append(fileURL)
            }
        }
        return results
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // loadInPlaceFileRepresentation is the most reliable way to get
            // the original file URL from a Finder drag on macOS.
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _, error in
                guard let url, error == nil else { return }
                let mediaFiles = Self.collectMediaFiles(from: url)
                Task { @MainActor in
                    vm.addFiles(urls: mediaFiles)
                }
            }
        }
        return true
    }

    private func browseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.mp3, .mpeg4Movie]
        panel.message = "Choose MP3/MP4 files or folders containing them"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            vm.addFiles(urls: Self.collectMediaFiles(from: url))
        }
    }
}

// MARK: - Sub-views

struct FileRowView: View {
    let file: AudioFileItem
    let index: Int
    let isCurrentFile: Bool  // whether this is the file being processed now
    let durationDisplay: String
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(durationDisplay)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if isCurrentFile {
                Text("Processing…")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }

            Spacer()

            Text(file.fileSize)
                .font(.caption)
                .foregroundStyle(.tertiary)

            if case .failed(let err) = file.status {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .trailing)
            }

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary.opacity(0.4))
                .help("Remove from list")
            }
        }
        .opacity(file.status == .done ? 0.5 : 1)
        .background(
            isCurrentFile
                ? Color.accentColor.opacity(0.08)
                : Color.clear
        )
        .animation(.easeInOut(duration: 0.3), value: isCurrentFile)
    }

    private var iconName: String {
        switch file.status {
        case .pending:    return "circle"
        case .processing: return "circle.fill"
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch file.status {
        case .pending:    return .secondary.opacity(0.4)
        case .processing: return .accentColor
        case .done:       return .green
        case .failed:     return .red
        }
    }
}

// MARK: - Subtitle Sidebar

extension ContentView {
    @ViewBuilder
    fileprivate var subtitleSidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.secondary)
                Text("Live Captions")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(vm.subtitles.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Subtitle list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.subtitles) { item in
                            SubtitleRow(item: item)
                                .id(item.id)
                        }
                    }
                }
                .onChange(of: vm.subtitles.count) { _, _ in
                    if let last = vm.subtitles.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .frame(width: 280)
    }
}

struct SubtitleRow: View {
    let item: SubtitleItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.startTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Text(item.endTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(item.text)
                .font(.body)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            item.index % 2 == 0
                ? Color.secondary.opacity(0.03)
                : Color.clear
        )
    }
}

struct EmptyFilesView: View {
    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No media files added")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
