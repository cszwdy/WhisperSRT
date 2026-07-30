import Foundation
import Combine
import SwiftUI
import AVFoundation

/// One subtitle segment from whisper output.
struct SubtitleItem: Identifiable {
    let id = UUID()
    let index: Int
    let startTime: String
    let endTime: String
    let text: String
}

/// One audio file queued for conversion.
struct AudioFileItem: Identifiable {
    let id = UUID()
    let url: URL
    var duration: TimeInterval = 0
    var status: FileStatus = .pending

    var fileName: String { url.lastPathComponent }
    var fileSize: String {
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
        let bytes = attrs?.fileSize ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

enum FileStatus: Equatable {
    case pending
    case processing
    case done
    case failed(String)
}

/// Holds all state for the conversion UI.
@MainActor
final class ConversionViewModel: ObservableObject {
    @Published var files: [AudioFileItem] = []
    @Published var isConverting = false
    @Published var statusMessage = ""
    @Published var currentFile: String?  // name of file being processed
    @Published var subtitles: [SubtitleItem] = []
    @Published var durationProgress: Double = 0    // 0…1
    @Published var progressText: String = ""        // "1:23 / 15:00"
    @Published var debugTrace: String = ""           // internal state for debugging

    // User-configurable
    @Published var modelPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/whisper.cpp/models/ggml-large-v3.bin"
    }()
    @Published var language: String = "en"
    @Published var useAutoDetect = true

    private var process: Process?
    private var accumulatedStderr = ""

    // Duration-based progress tracking — derived from file list state
    private var totalDuration: TimeInterval = 0
    private var currentFileDuration: TimeInterval = 0
    private var latestEndTime: TimeInterval = 0
    // Map: input file URL → actual SRT output path (from stderr)
    private var srtOutputPaths: [URL: String] = [:]
    // Map: original MP4 URL → temp extracted WAV URL
    private var tempAudioMap: [URL: URL] = [:]
    // Per-file elapsed time tracking
    private var fileStartTimes: [URL: Date] = [:]
    private var fileElapsedTimes: [URL: TimeInterval] = [:]  // frozen on completion
    private var elapsedTimer: Timer?
    @Published var clockTick: Date = .now  // drives UI refresh every second
    @Published var totalElapsedText: String = ""

    // ──────────────────────────── Public API ────────────────────────────

    func addFiles(urls: [URL]) {
        let allowedExts = ["mp3", "mp4"]
        let newFiles = urls
            .filter { allowedExts.contains($0.pathExtension.lowercased()) }
            .filter { url in !files.contains(where: { $0.url == url }) }
            .map { AudioFileItem(url: $0) }
        files.append(contentsOf: newFiles)
    }

    func removeFiles(at offsets: IndexSet) {
        files.remove(atOffsets: offsets)
    }

    func removeAll() {
        files.removeAll()
    }

    func startConversion() {
        guard !files.isEmpty, !isConverting else { return }
        isConverting = true
        statusMessage = "Initializing model…"
        currentFile = nil
        accumulatedStderr = ""
        subtitles = []
        durationProgress = 0
        progressText = ""
        debugTrace = ""
        currentFileDuration = 0
        latestEndTime = 0
        srtOutputPaths = [:]
        tempAudioMap = [:]
        fileStartTimes = [:]
        fileElapsedTimes = [:]
        totalElapsedText = ""

        // Reset statuses and compute durations
        for i in files.indices {
            files[i].status = .pending
            let asset = AVURLAsset(url: files[i].url)
            files[i].duration = asset.duration.seconds
            if !files[i].duration.isFinite { files[i].duration = 0 }
        }
        totalDuration = files.reduce(0) { $0 + $1.duration }

        // Extract audio for MP4 files, then launch whisper-cli
        statusMessage = "Preparing audio tracks…"
        Task {
            do {
                for file in files where file.url.pathExtension.lowercased() == "mp4" {
                    let tempDir = FileManager.default.temporaryDirectory
                    let tempWAV = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
                    try self.extractAudio(from: file.url, to: tempWAV)
                    self.tempAudioMap[file.url] = tempWAV
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "⚠️ Audio extraction failed: \(error.localizedDescription)"
                    self.isConverting = false
                }
                return
            }

            await MainActor.run { self.launchWhisperProcess() }
        }
    }

    /// Launch whisper-cli with the current file list (MP4s already extracted).
    @MainActor
    private func launchWhisperProcess() {
        // Build args: use temp WAV for MP4s, original file for MP3s
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
        var args = ["-m", modelPath, "--output-srt", "--print-progress"]
        args += ["-l", useAutoDetect ? "auto" : language]
        for file in files {
            let inputPath = tempAudioMap[file.url]?.path ?? file.url.path
            args.append(inputPath)
        }
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.process = proc

        // Collect stdout for real-time subtitles
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let parsed = ConversionViewModel.parseSubtitleLines(text)
            Task { @MainActor in
                let items = parsed.enumerated().map { i, s in
                    SubtitleItem(
                        index: self.subtitles.count + i + 1,
                        startTime: s.startTime,
                        endTime: s.endTime,
                        text: s.text
                    )
                }
                self.subtitles.append(contentsOf: items)

                if let last = items.last, self.currentFileDuration > 0 {
                    self.latestEndTime = Self.parseTimeToSeconds(last.endTime)
                    self.updateDurationProgress()
                }
            }
        }

        // Collect stderr asynchronously
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.accumulatedStderr += text
                self.parseProgress(text)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.elapsedTimer?.invalidate()
                self.elapsedTimer = nil
                self.isConverting = false
                self.process = nil

                if proc.terminationStatus == 0 {
                    for i in self.files.indices {
                        self.files[i].status = .done
                        self.freezeElapsedTime(for: self.files[i].url)
                    }
                    self.updateTotalElapsedText()
                    self.durationProgress = 1
                    self.progressText = self.formatTime(self.totalDuration) + " / " + self.formatTime(self.totalDuration)
                    self.statusMessage = "✅ Done — \(self.files.count) file(s) converted"
                    self.currentFile = nil
                    self.renameOutputFiles()
                    self.cleanupTempFiles()
                } else {
                    let msg = self.errorMessageFromStderr()
                    for i in self.files.indices {
                        if self.files[i].status != .done {
                            self.files[i].status = .failed(msg)
                        }
                    }
                    self.statusMessage = "❌ \(msg)"
                    self.cleanupTempFiles()
                }
            }
        }

        do {
            try proc.run()
            statusMessage = "Converting \(files.count) file(s)…"
            elapsedTimer?.invalidate()
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.clockTick = .now
                    self?.updateTotalElapsedText()
                }
            }
        } catch {
            statusMessage = "⚠️ Failed to launch whisper-cli: \(error.localizedDescription)"
            isConverting = false
        }
    }

    func cancelConversion() {
        process?.interrupt()
        process = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        isConverting = false
        statusMessage = "Cancelled"
        durationProgress = 0
        progressText = ""
        debugTrace = ""
        currentFileDuration = 0
        latestEndTime = 0
        srtOutputPaths = [:]
        cleanupTempFiles()
    }

    /// Freeze elapsed time for a file when it completes.
    private func freezeElapsedTime(for url: URL) {
        if let start = fileStartTimes[url] {
            fileElapsedTimes[url] = Date().timeIntervalSince(start)
        }
    }

    /// Recompute total elapsed text from all non-pending files.
    private func updateTotalElapsedText() {
        var total: TimeInterval = 0
        for file in files {
            if file.status == .pending { continue }
            if let frozen = fileElapsedTimes[file.url] {
                total += frozen
            } else if let start = fileStartTimes[file.url] {
                total += Date().timeIntervalSince(start)
            }
        }
        totalElapsedText = total > 0 ? "Total: \(formatTime(total))" : ""
    }

    /// Duration display string for a file row: "5:30", "2:15 / 5:30  (0:45, ~1:30)".
    func durationDisplay(for file: AudioFileItem) -> String {
        let total = formatTime(file.duration)
        let elapsed: TimeInterval
        if let frozen = fileElapsedTimes[file.url] {
            elapsed = frozen
        } else if let start = fileStartTimes[file.url] {
            elapsed = Date().timeIntervalSince(start)
        } else {
            elapsed = 0
        }
        let elapsedStr = elapsed > 0 ? formatTime(elapsed) : ""

        if file.status == .done {
            return elapsedStr.isEmpty ? total : "\(total)  (\(elapsedStr))"
        }
        if file.status == .processing && file.fileName == currentFile {
            let done = min(latestEndTime, file.duration)
            let doneStr = formatTime(done)
            // Estimate remaining: (elapsed / progress) - elapsed
            let progress = max(latestEndTime, 1)
            let estimatedRemaining = elapsed * (file.duration - latestEndTime) / progress
            let remainStr = estimatedRemaining > 0 ? "~\(formatTime(estimatedRemaining))" : ""
            if elapsedStr.isEmpty { return "\(doneStr) / \(total)" }
            return "\(doneStr) / \(total)  (\(elapsedStr), \(remainStr))"
        }
        return total
    }

    // ────────────────────────────── Private ──────────────────────────────

    /// Parse subtitle lines from whisper-cli stdout.
    /// Format: [00:00:00.000 --> 00:00:05.000] text
    nonisolated private static func parseSubtitleLines(_ text: String) -> [(startTime: String, endTime: String, text: String)] {
        var result: [(startTime: String, endTime: String, text: String)] = []
        let pattern = "^\\[(\\d{2}:\\d{2}:\\d{2}\\.\\d{3})\\s*-->\\s*(\\d{2}:\\d{2}:\\d{2}\\.\\d{3})\\]\\s*(.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for line in text.components(separatedBy: "\n") {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange) else { continue }
            let extract = { (at: Int) -> String in
                let r = match.range(at: at)
                return r.location != NSNotFound ? (line as NSString).substring(with: r) : ""
            }
            result.append((extract(1), extract(2), extract(3)))
        }
        return result
    }

    /// Convert "HH:MM:SS.mmm" to seconds.
    nonisolated private static func parseTimeToSeconds(_ time: String) -> TimeInterval {
        let parts = time.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2])
        else { return 0 }
        return h * 3600 + m * 60 + s
    }

    /// Recompute durationProgress and progressText from file list state.
    private func updateDurationProgress() {
        let doneDuration = files.filter { $0.status == .done }.reduce(0) { $0 + $1.duration }
        let current = doneDuration + (currentFileDuration > 0 ? min(latestEndTime, currentFileDuration) : 0)
        if totalDuration > 0 {
            durationProgress = min(current / totalDuration, 1)
        }
        progressText = "\(formatTime(current)) / \(formatTime(totalDuration))"
        updateTotalElapsedText()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", sec))" }
        return "\(m):\(String(format: "%02d", sec))"
    }

    /// Extract audio track from MP4 to 16kHz mono WAV using afconvert (built-in macOS tool).
    private func extractAudio(from sourceURL: URL, to outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            sourceURL.path,
            outputURL.path
        ]

        // Capture stderr for error messages
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "WhisperSRT", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Audio extraction failed: \(errMsg)"])
        }
    }

    /// whisper-cli produces "file.mp3.srt" — rename to "file.srt".
    /// For MP4 files, the SRT output is at temp WAV's location.
    private func renameOutputFiles() {
        let fm = FileManager.default
        for file in files {
            let newURL = file.url.deletingPathExtension().appendingPathExtension("srt")
            let newPath = newURL.path

            // For MP4 files: whisper-cli processed a temp WAV, so SRT is tempWAV.srt
            if let tempWAV = tempAudioMap[file.url] {
                let tempSRT = tempWAV.path + ".srt"
                if tryRename(from: tempSRT, to: newPath, fm: fm) { continue }
            }

            // Prefer the exact path reported by whisper via output_srt:
            if let capturedPath = srtOutputPaths[file.url] {
                if tryRename(from: capturedPath, to: newPath, fm: fm) { continue }
            }
            // Fallback 1: file.mp3.srt
            if tryRename(from: file.url.path + ".srt", to: newPath, fm: fm) { continue }
            // Fallback 2: file.srt (whisper may have used this directly)
            if tryRename(from: newPath, to: newPath, fm: fm) { continue }
            // Fallback 3: file.wav.srt etc.
            let oldPath2 = file.url.deletingPathExtension().path + ".srt"
            _ = tryRename(from: oldPath2, to: newPath, fm: fm)
        }
    }

    /// Delete all temporary WAV files created from MP4 extraction.
    private func cleanupTempFiles() {
        let fm = FileManager.default
        for (_, tempWAV) in tempAudioMap {
            try? fm.removeItem(at: tempWAV)
            // Also clean up any .srt left alongside the temp WAV
            let srtPath = tempWAV.path + ".srt"
            if fm.fileExists(atPath: srtPath) {
                try? fm.removeItem(at: URL(fileURLWithPath: srtPath))
            }
        }
        tempAudioMap.removeAll()
    }

    /// Try to rename oldPath → newPath. Returns true on success.
    @discardableResult
    private func tryRename(from oldPath: String, to newPath: String, fm: FileManager) -> Bool {
        guard oldPath != newPath, fm.fileExists(atPath: oldPath) else { return false }
        if fm.fileExists(atPath: newPath) {
            try? fm.removeItem(atPath: newPath)
        }
        do {
            try fm.moveItem(atPath: oldPath, toPath: newPath)
            return true
        } catch {
            // Fallback: copy + delete
            if (try? fm.copyItem(atPath: oldPath, toPath: newPath)) != nil {
                try? fm.removeItem(atPath: oldPath)
                return true
            }
            return false
        }
    }

    private func parseProgress(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            // Detect which file is being loaded
            // whisper-cli outputs:  main: processing 'path/to/file.mp3'
            if line.contains("main: processing '") {
                let parts = line.components(separatedBy: "'")
                if parts.count >= 2 {
                    let path = parts[1].trimmingCharacters(in: .whitespaces)
                    let fileName = URL(fileURLWithPath: path).lastPathComponent

                    // Mark previous file as done (new file starting = prev finished)
                    if let prev = currentFile, let prevIdx = files.firstIndex(where: { $0.fileName == prev }) {
                        files[prevIdx].status = .done
                        freezeElapsedTime(for: files[prevIdx].url)
                    }

                    currentFile = fileName
                    // Try direct filename match; for MP4s the stderr shows temp WAV name
                    if let idx = files.firstIndex(where: { $0.fileName == fileName }) {
                        files[idx].status = .processing
                        currentFileDuration = files[idx].duration
                        fileStartTimes[files[idx].url] = Date()
                    } else if let (origURL, _) = tempAudioMap.first(where: { $1.path == path }),
                              let idx = files.firstIndex(where: { $0.url == origURL }) {
                        // Temp WAV → original MP4: use original file name for tracking
                        currentFile = files[idx].fileName
                        files[idx].status = .processing
                        currentFileDuration = files[idx].duration
                        fileStartTimes[files[idx].url] = Date()
                    }
                    latestEndTime = 0
                    statusMessage = "Processing: \(currentFile ?? fileName)"
                    updateDurationProgress()
                }
            }
            // Detect final timing output (means a file finished)
            // whisper-cli outputs:  whisper_print_timings: ...
            if line.contains("whisper_print_timings:") && currentFile != nil {
                if let idx = files.firstIndex(where: { $0.fileName == currentFile }) {
                    files[idx].status = .done
                    freezeElapsedTime(for: files[idx].url)
                }
                currentFileDuration = 0
                latestEndTime = 0
                currentFile = nil
                updateDurationProgress()
            }
            // Per-file progress callback (--print-progress)
            // whisper_print_progress_callback: progress = 73%
            if line.contains("whisper_print_progress_callback:") && currentFileDuration > 0 {
                let parts = line.components(separatedBy: "progress = ")
                if parts.count >= 2 {
                    let pct = parts[1].trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "%", with: "")
                    if let pctVal = Double(pct) {
                        latestEndTime = currentFileDuration * pctVal / 100.0
                        updateDurationProgress()
                    }
                }
            }
            // Capture actual SRT output path from whisper
            // output_srt: saving output to '/path/to/file.mp3.srt'
            if line.contains("output_srt:") {
                let parts = line.components(separatedBy: "'")
                if parts.count >= 2 {
                    let srtPath = parts[1].trimmingCharacters(in: .whitespaces)
                    let srtPathMinusExt = (srtPath as NSString).deletingPathExtension
                    // Direct match: input file path == SRT path minus extension
                    for file in files {
                        if file.url.path == srtPathMinusExt {
                            srtOutputPaths[file.url] = srtPath
                            if let idx = files.firstIndex(where: { $0.url == file.url }) {
                                files[idx].status = .done
                                freezeElapsedTime(for: files[idx].url)
                            }
                            break
                        }
                    }
                    // Temp WAV match: SRT was saved based on temp WAV path
                    if let (origURL, _) = tempAudioMap.first(where: { $1.path == srtPathMinusExt }) {
                        srtOutputPaths[origURL] = srtPath
                        if let idx = files.firstIndex(where: { $0.url == origURL }) {
                            files[idx].status = .done
                            freezeElapsedTime(for: files[idx].url)
                        }
                    }
                }
            }
        }
    }

    private func errorMessageFromStderr() -> String {
        // Extract last meaningful error from stderr
        let lines = accumulatedStderr
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("ggml_") && !$0.hasPrefix("load_backend:") && !$0.hasPrefix("whisper_") }
        return lines.last ?? "Conversion failed"
    }
}
