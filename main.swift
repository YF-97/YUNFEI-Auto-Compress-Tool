import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import UserNotifications
import Darwin

let appVersion = "1.0.2.51"
let appTitle = "YUNFEI自动压缩_\(appVersion)"
let appDisplayTitle = appTitle
let appAuthor = "制作者：摄影师云飞"
let appAuthorLink = "https://space.bilibili.com/17519822"
let maxInputFolderCount = 3
let maxKeywordCount = 3

enum TimeGateOption: String, CaseIterable, Identifiable {
    case last24h
    case last7d
    case customDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last24h: return "最近24小时"
        case .last7d: return "最近7天"
        case .customDate: return "指定日期之后"
        }
    }
}

enum ScanIntervalOption: Int, CaseIterable, Identifiable {
    case minutes1 = 1
    case minutes5 = 5
    case minutes15 = 15
    case minutes60 = 60

    var id: Int { rawValue }

    var title: String {
        "每\(rawValue)分钟"
    }
}

enum MountCheckIntervalOption: Int, CaseIterable, Identifiable {
    case minutes3 = 3
    case minutes5 = 5
    case minutes10 = 10

    var id: Int { rawValue }

    var title: String {
        "每\(rawValue)分钟"
    }
}

enum CodecOption: String, CaseIterable, Identifiable {
    case h264
    case h265

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265"
        }
    }

    var crf: String {
        switch self {
        case .h264: return "23"
        case .h265: return "28"
        }
    }

    var encoder: String {
        switch self {
        case .h264: return "libx264"
        case .h265: return "libx265"
        }
    }
}

enum QualityPreset: String, CaseIterable, Identifiable {
    case spaceSaving
    case balanced
    case highQuality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaceSaving: return "省空间"
        case .balanced: return "均衡"
        case .highQuality: return "高质量"
        }
    }

    var bitrateKbps: Int {
        switch self {
        case .spaceSaving: return 12000
        case .balanced: return 18000
        case .highQuality: return 25000
        }
    }

    var displayTitle: String {
        "\(title) \(bitrateKbps / 1000)Mbps"
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case overwrite
    case outputFolder
    case suffix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite: return "覆盖原文件"
        case .outputFolder: return "另存到指定文件夹"
        case .suffix: return "添加后缀"
        }
    }
}

struct QueueEntry: Identifiable {
    let id = UUID()
    let name: String
    let sizeBytes: Int64
    let estimatedBytes: Int64?
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var inputPath: String = UserDefaults.standard.string(forKey: "inputPath") ?? "" {
        didSet {
            UserDefaults.standard.set(inputPath, forKey: "inputPath")
            checkMountStatus(notifyOnChange: true)
            if scanEnabled {
                startMonitor()
            }
        }
    }
    @Published var extraInputPaths: [String] = {
        let stored = UserDefaults.standard.stringArray(forKey: "extraInputPaths") ?? []
        let limit = max(0, maxInputFolderCount - 1)
        if stored.count > limit {
            return Array(stored.prefix(limit))
        }
        return stored
    }() {
        didSet {
            UserDefaults.standard.set(extraInputPaths, forKey: "extraInputPaths")
            checkMountStatus(notifyOnChange: true)
            if scanEnabled {
                startMonitor()
            }
        }
    }
    @Published var outputPath: String = UserDefaults.standard.string(forKey: "outputPath") ?? "" { didSet { UserDefaults.standard.set(outputPath, forKey: "outputPath") } }
    @Published var includeSubfolders: Bool = UserDefaults.standard.bool(forKey: "includeSubfolders") { didSet { UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders") } }
    @Published var timeGate: TimeGateOption = TimeGateOption(rawValue: UserDefaults.standard.string(forKey: "timeGate") ?? "last24h") ?? .last24h { didSet { UserDefaults.standard.set(timeGate.rawValue, forKey: "timeGate") } }
    @Published var customDate: Date = UserDefaults.standard.object(forKey: "customDate") as? Date ?? Date().addingTimeInterval(-7 * 24 * 3600) { didSet { UserDefaults.standard.set(customDate, forKey: "customDate") } }
    @Published var interval: ScanIntervalOption = ScanIntervalOption(rawValue: UserDefaults.standard.integer(forKey: "scanInterval").nonZeroOrDefault(5)) ?? .minutes5 { didSet { UserDefaults.standard.set(interval.rawValue, forKey: "scanInterval") } }
    @Published var immediateCompress: Bool = (UserDefaults.standard.object(forKey: "immediateCompress") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(immediateCompress, forKey: "immediateCompress")
            if scanEnabled { startMonitor() }
        }
    }
    @Published var codec: CodecOption = CodecOption(rawValue: UserDefaults.standard.string(forKey: "codec") ?? "h264") ?? .h264 {
        didSet {
            UserDefaults.standard.set(codec.rawValue, forKey: "codec")
            refreshFfmpegStatus()
        }
    }
    @Published var qualityPreset: QualityPreset = QualityPreset(rawValue: UserDefaults.standard.string(forKey: "qualityPreset") ?? "balanced") ?? .balanced {
        didSet {
            UserDefaults.standard.set(qualityPreset.rawValue, forKey: "qualityPreset")
            updateQueueSnapshot()
        }
    }
    @Published var outputMode: OutputMode = OutputMode(rawValue: UserDefaults.standard.string(forKey: "outputMode") ?? "outputFolder") ?? .outputFolder { didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var suffixText: String = UserDefaults.standard.string(forKey: "suffixText") ?? "_压缩" { didSet { UserDefaults.standard.set(suffixText, forKey: "suffixText") } }
    @Published var draftSuffix: String = UserDefaults.standard.string(forKey: "suffixText") ?? "_压缩"
    @Published var isSuffixEditing: Bool = false
    @Published var keywords: [String] = {
        let stored = UserDefaults.standard.stringArray(forKey: "keywords") ?? []
        let trimmed = stored.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !trimmed.isEmpty {
            return Array(trimmed.prefix(maxKeywordCount))
        }
        let legacy = UserDefaults.standard.string(forKey: "keyword") ?? "带字幕"
        let legacyTrimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyTrimmed.isEmpty ? [] : [legacyTrimmed]
    }() {
        didSet {
            UserDefaults.standard.set(keywords, forKey: "keywords")
            if let first = keywords.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), keyword != first {
                keyword = first
            }
        }
    }
    @Published var keyword: String = {
        if let single = UserDefaults.standard.string(forKey: "keyword"), !single.isEmpty {
            return single
        }
        if let list = UserDefaults.standard.stringArray(forKey: "keywords"), let first = list.first, !first.isEmpty {
            return first
        }
        return "带字幕"
    }() { didSet { UserDefaults.standard.set(keyword, forKey: "keyword") } }
    @Published var draftKeyword: String = UserDefaults.standard.string(forKey: "keyword") ?? "带字幕"
    @Published var isKeywordEditing: Bool = false
    @Published var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: "launchAtLogin") { didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var keepAlive: Bool = UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAlive, forKey: "keepAlive")
            updateDockVisibility()
        }
    }
    @Published var scanEnabled: Bool = false
    @Published var lastScan: Date? = nil
    @Published var statusText: String = "已停止"
    @Published var mountStatus: String = "未检测"
    @Published var mountMonitorEnabled: Bool = (UserDefaults.standard.object(forKey: "mountMonitorEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(mountMonitorEnabled, forKey: "mountMonitorEnabled")
            applyMountMonitorSettings()
        }
    }
    @Published var mountInterval: MountCheckIntervalOption = MountCheckIntervalOption(rawValue: UserDefaults.standard.integer(forKey: "mountInterval").nonZeroOrDefault(5)) ?? .minutes5 {
        didSet {
            UserDefaults.standard.set(mountInterval.rawValue, forKey: "mountInterval")
            rescheduleMountMonitor()
        }
    }
    @Published var ffmpegPath: String = UserDefaults.standard.string(forKey: "ffmpegPath") ?? "" {
        didSet {
            UserDefaults.standard.set(ffmpegPath, forKey: "ffmpegPath")
            refreshFfmpegStatus()
        }
    }
    @Published var ffmpegVersionShort: String = "未配置"
    @Published var ffmpegVersionFull: String = ""
    @Published var ffmpegEncoderList: [String] = []
    @Published var ffmpegEncoderError: String = ""
    @Published var hardwareStatusText: String = "硬件编码状态未知"

    func refreshFfmpegStatus() {
        let ffmpeg = resolvedFfmpegPath
        let selectedCodec = codec
        Task.detached {
            let result = Self.collectFfmpegStatus(ffmpegPath: ffmpeg, codec: selectedCodec)
            await AppState.shared.applyFfmpegStatus(result)
        }
    }

    @MainActor
    private func applyFfmpegStatus(_ result: FfmpegStatusResult) {
        ffmpegVersionShort = result.versionShort
        ffmpegVersionFull = result.versionFull
        ffmpegEncoderList = result.encoderList
        ffmpegEncoderError = result.encoderError
        hardwareAvailableH264 = result.hardwareH264
        hardwareAvailableH265 = result.hardwareH265
        hardwareStatusText = result.statusText
        hardwareStatusHint = result.statusHint
        currentEncoderText = result.currentEncoder
    }

    private struct FfmpegStatusResult {
        let versionShort: String
        let versionFull: String
        let encoderList: [String]
        let encoderError: String
        let hardwareH264: Bool
        let hardwareH265: Bool
        let statusText: String
        let statusHint: String
        let currentEncoder: String
    }

    nonisolated private static func collectFfmpegStatus(ffmpegPath: String?, codec: CodecOption) -> FfmpegStatusResult {
        let fallbackEncoder = codec == .h264 ? "libx264" : "libx265"
        guard let ffmpegPath else {
            return FfmpegStatusResult(
                versionShort: "未配置",
                versionFull: "",
                encoderList: [],
                encoderError: "",
                hardwareH264: false,
                hardwareH265: false,
                statusText: "FFmpeg 未配置",
                statusHint: "请配置 FFmpeg 路径或等待自动下载",
                currentEncoder: fallbackEncoder
            )
        }

        let versionOutput = runProcess(ffmpegPath, ["-version"])?.output ?? ""
        let versionLine = versionOutput.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let versionShort = parseVersionShort(from: versionLine)

        guard let encoderResult = runProcess(ffmpegPath, ["-encoders"]) else {
            return FfmpegStatusResult(
                versionShort: versionShort.isEmpty ? "未知" : versionShort,
                versionFull: versionLine,
                encoderList: [],
                encoderError: "无法执行 ffmpeg -encoders",
                hardwareH264: false,
                hardwareH265: false,
                statusText: "硬件编码状态未知",
                statusHint: "请检查 FFmpeg 是否可执行",
                currentEncoder: fallbackEncoder
            )
        }

        let encoderLines = encoderResult.output.split(separator: "\n").map(String.init)
        let vtLines = encoderLines.filter { $0.contains("videotoolbox") }
        let hardwareH264 = vtLines.contains { $0.contains("h264_videotoolbox") }
        let hardwareH265 = vtLines.contains { $0.contains("hevc_videotoolbox") }
        let currentEncoder: String
        let statusText: String
        let statusHint: String

        if codec == .h264 {
            currentEncoder = hardwareH264 ? "h264_videotoolbox" : "libx264"
            statusText = hardwareH264 ? "H.264 硬件编码：已开启" : "H.264 硬件编码：未开启（仅软件编码）"
        } else {
            currentEncoder = hardwareH265 ? "hevc_videotoolbox" : "libx265"
            statusText = hardwareH265 ? "HEVC 硬件编码：已开启" : "HEVC 硬件编码：未开启（仅软件编码）"
        }

        if !hardwareH264 && !hardwareH265 {
            statusHint = "建议更换支持 VideoToolbox 的 FFmpeg，或检查系统权限"
        } else {
            statusHint = "当前使用：\(currentEncoder)"
        }

        return FfmpegStatusResult(
            versionShort: versionShort.isEmpty ? "未知" : versionShort,
            versionFull: versionLine,
            encoderList: vtLines,
            encoderError: encoderResult.exitCode == 0 ? "" : encoderResult.output,
            hardwareH264: hardwareH264,
            hardwareH265: hardwareH265,
            statusText: statusText,
            statusHint: statusHint,
            currentEncoder: currentEncoder
        )
    }

    nonisolated private static func runProcess(_ path: String, _ arguments: [String]) -> (output: String, exitCode: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output: output, exitCode: process.terminationStatus)
    }

    nonisolated private static func parseVersionShort(from line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return "" }
        return String(parts[2])
    }
    @Published var hardwareStatusHint: String = ""
    @Published var currentEncoderText: String = ""
    @Published var hardwareAvailableH264: Bool = false
    @Published var hardwareAvailableH265: Bool = false
    @Published var isDownloadingFfmpeg: Bool = false
    @Published var currentFileName: String = ""
    @Published var currentFileProgress: Double = 0
    @Published var currentFileElapsed: String = ""
    @Published var currentFileRemaining: String = ""
    @Published var currentFileEstimatedTotal: String = ""
    @Published var lastCompletedName: String = ""
    weak var mainWindow: NSWindow?
    lazy var windowDelegate = MainWindowDelegate()

    private var timer: Timer?
    private var mountTimer: Timer?
    private var lastMountState: Bool?
    private var monitorSources: [DispatchSourceFileSystemObject] = []
    private var monitorFDs: [Int32] = []
    private var pendingFiles: [URL] = []
    private var lastSeenSizes: [String: Int64] = [:]
    private var processedTimes: [String: TimeInterval] = [:]
    private var inProgress: Set<String> = []
    private var h265SoftwareFallback: Set<String> = []
    private var rescanWorkItem: DispatchWorkItem?
    private var isCompressing = false
    private var isDownloading = false
    private var currentDurationMs: Double = 0
    private var progressBuffer: String = ""
    private var currentTaskStart: Date?

    private let logLimit = 200
    private let versionLine = "版本 v\(appVersion)"
    @Published var logs: [String] = []
    @Published var queueItems: [QueueEntry] = []
    @Published var batchTotal: Int = 0
    @Published var batchCompleted: Int = 0

    private init() {
        logs = [versionLine]
        loadProcessedTimes()
        if launchAtLogin {
            enableLaunchAgent(true)
        }
        applyMountMonitorSettings()
        checkMountStatus(notifyOnChange: false)
        updateDockVisibility()
        refreshFfmpegStatus()
    }

    var allInputPaths: [String] {
        ([inputPath] + extraInputPaths).filter { !$0.isEmpty }
    }

    var cutoffDate: Date {
        switch timeGate {
        case .last24h:
            return Date().addingTimeInterval(-24 * 3600)
        case .last7d:
            return Date().addingTimeInterval(-7 * 24 * 3600)
        case .customDate:
            return customDate
        }
    }

    var statusDisplay: String {
        "\(statusText) · \(mountStatus) · v\(appVersion)"
    }

    var queueProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1.0, Double(batchCompleted) / Double(batchTotal))
    }

    var resolvedFfmpegPath: String? {
        if !ffmpegPath.isEmpty, FileManager.default.isExecutableFile(atPath: ffmpegPath) {
            return ffmpegPath
        }
        let downloaded = ffmpegStoreURL().path
        if FileManager.default.isExecutableFile(atPath: downloaded) {
            return downloaded
        }
        if let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil), FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated private func ffmpegStoreURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SubtitleCompress/tools", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ffmpeg")
    }

    private func ensureFfmpegAvailable() {
        if resolvedFfmpegPath != nil { return }
        if isDownloadingFfmpeg { return }
        isDownloadingFfmpeg = true
        statusText = "下载 ffmpeg 中"
        log("开始下载 ffmpeg")
        guard let url = URL(string: "https://evermeet.cx/ffmpeg/ffmpeg-6.1.1.zip") else {
            log("ffmpeg 下载地址无效")
            isDownloadingFfmpeg = false
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.log("下载失败：\(error.localizedDescription)")
                    self.isDownloadingFfmpeg = false
                    self.statusText = "未找到 ffmpeg"
                }
                return
            }
            guard let tempURL else {
                Task { @MainActor in
                    self.log("下载失败：文件为空")
                    self.isDownloadingFfmpeg = false
                    self.statusText = "未找到 ffmpeg"
                }
                return
            }

            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent("ffmpeg-download-\(UUID().uuidString)")
            let zipPath = tempDir.appendingPathComponent("ffmpeg.zip")

            do {
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try fm.moveItem(at: tempURL, to: zipPath)
            } catch {
                Task { @MainActor in
                    self.log("准备下载文件失败")
                    self.isDownloadingFfmpeg = false
                }
                return
            }

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipPath.path, "-d", tempDir.path]

            do {
                try unzip.run()
                unzip.waitUntilExit()
            } catch {
                Task { @MainActor in
                    self.log("解压 ffmpeg 失败")
                    self.isDownloadingFfmpeg = false
                }
                return
            }

            guard let ffmpegURL = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent == "ffmpeg" }) else {
                Task { @MainActor in
                    self.log("未找到 ffmpeg 可执行文件")
                    self.isDownloadingFfmpeg = false
                }
                return
            }

            let destURL = self.ffmpegStoreURL()
            do {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.moveItem(at: ffmpegURL, to: destURL)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
            } catch {
                Task { @MainActor in
                    self.log("保存 ffmpeg 失败")
                    self.isDownloadingFfmpeg = false
                }
                return
            }

            Task { @MainActor in
                self.log("ffmpeg 下载完成")
                self.isDownloadingFfmpeg = false
                self.statusText = "运行中"
                self.startNextIfNeeded()
            }
        }
        task.resume()
    }

    private func applyMountMonitorSettings() {
        if mountMonitorEnabled {
            startMountMonitor()
            checkMountStatus(notifyOnChange: false)
        } else {
            mountTimer?.invalidate()
            mountTimer = nil
            mountStatus = "检测关闭"
        }
    }

    private func startMountMonitor() {
        mountTimer?.invalidate()
        guard mountMonitorEnabled else { return }
        let seconds = TimeInterval(mountInterval.rawValue * 60)
        mountTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkMountStatus(notifyOnChange: true)
            }
        }
    }

    private func rescheduleMountMonitor() {
        if mountMonitorEnabled {
            startMountMonitor()
        }
    }

    private func checkMountStatus(notifyOnChange: Bool) {
        let paths = allInputPaths
        guard !paths.isEmpty else {
            mountStatus = "未选择"
            if statusText != "请选择监听文件夹" {
                statusText = "请选择监听文件夹"
            }
            lastMountState = nil
            return
        }

        let mounted = paths.filter { FileManager.default.fileExists(atPath: $0) }
        let isMounted = mounted.count == paths.count
        mountStatus = isMounted ? "已挂载" : "未挂载"

        if !isMounted {
            if statusText != "目录未挂载" {
                statusText = "目录未挂载"
            }
        } else if lastMountState == false {
            statusText = scanEnabled ? "运行中" : "已停止"
        }

        if notifyOnChange, mountMonitorEnabled, lastMountState != nil, lastMountState != isMounted, !isMounted {
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
            let detail = missing.joined(separator: ", ")
            notify(title: "NAS 未挂载", body: "目录不可用：\(detail)")
        }

        lastMountState = isMounted
    }

    func updateDockVisibility(windowVisible: Bool? = nil) {
        let visible = windowVisible ?? (mainWindow?.isVisible ?? false)
        if keepAlive {
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func validateSettings() -> Bool {
        let trimmedKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let outputOK: Bool
        switch outputMode {
        case .outputFolder:
            outputOK = !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .overwrite, .suffix:
            outputOK = true
        }
        let ffmpegOK = resolvedFfmpegPath != nil
        let ok = !trimmedKeywords.isEmpty && outputOK && ffmpegOK
        if !ok {
            showValidationAlert()
        }
        return ok
    }

    private func showValidationAlert() {
        let alert = NSAlert()
        alert.messageText = "请设置关键词、存放路径和压缩器后才能开始运作"
        alert.runModal()
    }

    func start() {
        guard timer == nil else { return }
        guard validateSettings() else { return }
        scanEnabled = true
        statusText = "运行中"
        if resolvedFfmpegPath == nil {
            log("未找到 ffmpeg，开始自动下载")
            ensureFfmpegAvailable()
        }
        scheduleTimer()
        startMonitor()
        scanOnce()
    }

    func stop() {
        scanEnabled = false
        timer?.invalidate()
        timer = nil
        stopMonitor()
        statusText = "已停止"
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let seconds = TimeInterval(interval.rawValue * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanOnce()
            }
        }
    }

    private func startMonitor() {
        stopMonitor()
        guard scanEnabled, immediateCompress else { return }
        let paths = allInputPaths
        guard !paths.isEmpty else { return }

        for path in paths {
            let fd = open(path, O_RDONLY | O_EVTONLY)
            if fd < 0 {
                log("无法监听目录变化，路径可能无效：\(path)")
                checkMountStatus(notifyOnChange: true)
                continue
            }
            monitorFDs.append(fd)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: DispatchQueue.global()
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.scanOnce()
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            monitorSources.append(source)
            source.resume()
        }
    }

    private func stopMonitor() {
        monitorSources.forEach { $0.cancel() }
        monitorSources.removeAll()
        monitorFDs.removeAll()
    }

    func reschedule() {
        if scanEnabled {
            scheduleTimer()
        }
    }

    func scanOnce() {
        let paths = allInputPaths
        guard !paths.isEmpty else {
            statusText = "请选择监听文件夹"
            return
        }
        checkMountStatus(notifyOnChange: true)
        lastScan = Date()
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]

        var newCandidates: [URL] = []
        var seen: Set<String> = []

        for path in paths {
            if !fm.fileExists(atPath: path) {
                log("目录未挂载：\(path)")
                continue
            }
            let inputURL = URL(fileURLWithPath: path)

            let enumerator: FileManager.DirectoryEnumerator?
            if includeSubfolders {
                enumerator = fm.enumerator(at: inputURL, includingPropertiesForKeys: resourceKeys)
            } else {
                enumerator = fm.enumerator(at: inputURL, includingPropertiesForKeys: resourceKeys, options: [.skipsSubdirectoryDescendants])
            }

            guard let files = enumerator else {
                statusText = "无法读取目录"
                continue
            }

            for case let fileURL as URL in files {
                if fileURL.hasDirectoryPath { continue }
                if !isVideoFile(fileURL) { continue }
                if !matchesKeywords(fileURL.lastPathComponent) { continue }
                if !suffixText.isEmpty, fileURL.lastPathComponent.contains(suffixText) { continue }
                if outputMode == .outputFolder, !outputPath.isEmpty {
                    let outPath = URL(fileURLWithPath: outputPath).standardizedFileURL.path
                    if fileURL.standardizedFileURL.path.hasPrefix(outPath + "/") {
                        continue
                    }
                }

                guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
                let fileDate = values.creationDate ?? values.contentModificationDate ?? Date.distantPast
                if fileDate < cutoffDate { continue }

                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let key = fileURL.path
                if inProgress.contains(key) {
                    continue
                }
                if let processed = processedTimes[key], processed >= mtime {
                    continue
                }

                let size = Int64(values.fileSize ?? 0)
                if size <= 0 { continue }
                let lastSize = lastSeenSizes[key]
                if let lastSize, lastSize != size {
                    lastSeenSizes[key] = size
                    if immediateCompress {
                        scheduleImmediateRescan()
                    }
                    continue
                }
                lastSeenSizes[key] = size

                if seen.contains(key) { continue }
                seen.insert(key)
                newCandidates.append(fileURL)
            }
        }

        for url in newCandidates where !pendingFiles.contains(url) {
            pendingFiles.append(url)
        }

        if !newCandidates.isEmpty {
            log("发现 \(newCandidates.count) 个候选文件")
            notify(title: "发现新文件", body: "共 \(newCandidates.count) 个待压缩文件")
        }
        updateQueueSnapshot()
        startNextIfNeeded()
    }

    private func updateQueueSnapshot() {
        queueItems = pendingFiles.map { queueEntry(for: $0) }
    }

    private func scheduleImmediateRescan() {
        rescanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.scanOnce()
        }
        rescanWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func queueEntry(for url: URL) -> QueueEntry {
        let sizeBytes = fileSizeBytes(url)
        let estimated = estimatedSizeBytes(url)
        return QueueEntry(name: url.lastPathComponent, sizeBytes: sizeBytes, estimatedBytes: estimated)
    }

    private func fileSizeBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func estimatedSizeBytes(_ url: URL) -> Int64? {
        let duration = videoDurationSeconds(url)
        guard duration > 0 else { return nil }
        let audioKbps = 128
        let totalKbps = qualityPreset.bitrateKbps + audioKbps
        let bytesPerSecond = Double(totalKbps * 1000) / 8.0
        return Int64(duration * bytesPerSecond)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "-" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f%@", value, units[index])
    }

    private func startNextIfNeeded() {
        guard !isCompressing, !pendingFiles.isEmpty else { return }
        guard let ffmpeg = resolvedFfmpegPath else {
            statusText = "未找到 ffmpeg"
            log("未找到 ffmpeg，开始自动下载")
            ensureFfmpegAvailable()
            return
        }
        if batchTotal == 0 || batchCompleted >= batchTotal {
            batchTotal = pendingFiles.count
            batchCompleted = 0
            log("开始新一轮任务，共\(batchTotal)个")
        }
        isCompressing = true
        let fileURL = pendingFiles.removeFirst()
        inProgress.insert(fileURL.path)
        updateQueueSnapshot()
        statusText = "压缩中：\(fileURL.lastPathComponent)"
        notify(title: "开始压缩", body: fileURL.lastPathComponent)
        compress(fileURL, ffmpegPath: ffmpeg)
    }

    private func actualEncoder(for codec: CodecOption) -> String {
        switch codec {
        case .h264:
            return hardwareAvailableH264 ? "h264_videotoolbox" : "libx264"
        case .h265:
            return hardwareAvailableH265 ? "hevc_videotoolbox" : "libx265"
        }
    }

    private func compress(_ inputURL: URL, ffmpegPath: String) {
        let outputURL = outputURLFor(inputURL)
        guard let outputURL else {
            log("输出路径无效：\(inputURL.lastPathComponent)")
            isCompressing = false
            startNextIfNeeded()
            return
        }

        currentFileName = inputURL.lastPathComponent
        currentFileProgress = 0

        let durationSeconds = videoDurationSeconds(inputURL)
        if durationSeconds > 0 {
            currentFileElapsed = "00:00:00"
            currentFileRemaining = formatTime(durationSeconds)
            currentFileEstimatedTotal = formatTime(durationSeconds)
        } else {
            currentFileElapsed = "--:--:--"
            currentFileRemaining = "--:--:--"
            currentFileEstimatedTotal = "--:--:--"
        }
        let useSoftwareH265 = codec == .h265 && h265SoftwareFallback.contains(inputURL.path)
        let encoder = useSoftwareH265 ? "libx265" : actualEncoder(for: codec)
        currentEncoderText = encoder
        let bitrate = "\(qualityPreset.bitrateKbps)k"
        var args = ["-hide_banner", "-i", inputURL.path, "-c:v", encoder, "-preset", "medium", "-b:v", bitrate, "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-map", "0", "-y", "-progress", "pipe:1", "-nostats", "-stats_period", "0.2", outputURL.path]
        if codec == .h265 {
            args.insert(contentsOf: ["-tag:v", "hvc1"], at: 5)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.handleProgressText(text, durationSeconds: durationSeconds)
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.handleCompletion(inputURL: inputURL, outputURL: outputURL, status: proc.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            log("启动 ffmpeg 失败：\(error.localizedDescription)")
            isCompressing = false
            startNextIfNeeded()
        }
    }

    private func handleProgressText(_ text: String, durationSeconds: Double) {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        progressBuffer += normalized
        let lines = progressBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last, !last.isEmpty {
            progressBuffer = String(last)
        } else {
            progressBuffer = ""
        }
        for line in lines.dropLast() {
            handleProgressLine(String(line), durationSeconds: durationSeconds)
        }
    }

    private func handleProgressLine(_ line: String, durationSeconds: Double) {
        if line.hasPrefix("out_time_ms=") {
            let value = line.replacingOccurrences(of: "out_time_ms=", with: "")
            let ms = Double(value) ?? 0
            updateProgress(elapsed: ms / 1000.0, durationSeconds: durationSeconds)
        } else if line.hasPrefix("out_time_us=") {
            let value = line.replacingOccurrences(of: "out_time_us=", with: "")
            let us = Double(value) ?? 0
            updateProgress(elapsed: us / 1_000_000.0, durationSeconds: durationSeconds)
        } else if line.hasPrefix("out_time=") {
            let value = line.replacingOccurrences(of: "out_time=", with: "")
            let elapsed = parseTime(value)
            if elapsed > 0 {
                updateProgress(elapsed: elapsed, durationSeconds: durationSeconds)
            }
        } else if line == "progress=end" {
            currentFileProgress = 1.0
        }
    }

    private func updateProgress(elapsed: Double, durationSeconds: Double) {
        let remainingTime = max(0, durationSeconds - elapsed)
        currentFileElapsed = formatTime(elapsed)
        currentFileRemaining = formatTime(remainingTime)
        currentFileEstimatedTotal = durationSeconds > 0 ? formatTime(durationSeconds) : ""
        if durationSeconds > 0 {
            currentFileProgress = min(1.0, elapsed / durationSeconds)
        }
    }

    private func parseTime(_ value: String) -> Double {
        let parts = value.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2]) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    }

    private func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func videoDurationSeconds(_ url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0.1 {
            return seconds
        }
        guard let ffmpeg = resolvedFfmpegPath else { return 0 }
        return probeDurationSeconds(url, ffmpegPath: ffmpeg)
    }

    private func probeDurationSeconds(_ url: URL, ffmpegPath: String) -> Double {
        guard let result = Self.runProcess(ffmpegPath, ["-i", url.path]) else { return 0 }
        let output = result.output
        guard let range = output.range(of: "Duration:") else { return 0 }
        let suffix = output[range.upperBound...]
        let parts = suffix.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
        guard let timePart = parts.first else { return 0 }
        let timeString = timePart.trimmingCharacters(in: .whitespaces)
        let comps = timeString.split(separator: ":")
        guard comps.count == 3 else { return 0 }
        let hours = Double(comps[0]) ?? 0
        let minutes = Double(comps[1]) ?? 0
        let seconds = Double(comps[2]) ?? 0
        let total = hours * 3600 + minutes * 60 + seconds
        return total.isFinite ? total : 0
    }

    private func handleCompletion(inputURL: URL, outputURL: URL, status: Int32) {
        if status != 0, codec == .h265, currentEncoderText == "hevc_videotoolbox", !h265SoftwareFallback.contains(inputURL.path) {
            log("H.265 硬编失败，自动改用软件编码重试：\(inputURL.lastPathComponent)")
            h265SoftwareFallback.insert(inputURL.path)
            guard let ffmpeg = resolvedFfmpegPath else {
                inProgress.remove(inputURL.path)
                updateQueueSnapshot()
                isCompressing = false
                startNextIfNeeded()
                return
            }
            compress(inputURL, ffmpegPath: ffmpeg)
            return
        }
        inProgress.remove(inputURL.path)
        h265SoftwareFallback.remove(inputURL.path)
        updateQueueSnapshot()
        defer {
            isCompressing = false
            startNextIfNeeded()
        }
        if status == 0 {
            if outputMode == .overwrite {
                do {
                    if FileManager.default.fileExists(atPath: inputURL.path) {
                        try FileManager.default.removeItem(at: inputURL)
                    }
                    try FileManager.default.moveItem(at: outputURL, to: inputURL)
                } catch {
                    log("覆盖原文件失败：\(inputURL.lastPathComponent)")
                }
            }
            let mtime = (try? inputURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? Date().timeIntervalSince1970
            processedTimes[inputURL.path] = mtime
            saveProcessedTimes()
            lastCompletedName = inputURL.lastPathComponent
            log("压缩完成：\(inputURL.lastPathComponent)")
            notify(title: "压缩完成", body: inputURL.lastPathComponent)
        } else {
            log("压缩失败：\(inputURL.lastPathComponent)")
            notify(title: "压缩失败", body: inputURL.lastPathComponent)
            if outputMode == .overwrite, FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        if batchTotal > 0 {
            batchCompleted = min(batchTotal, batchCompleted + 1)
        }
        if pendingFiles.isEmpty {
            currentFileName = ""
            currentFileProgress = 0
            currentFileElapsed = ""
            currentFileRemaining = ""
            currentFileEstimatedTotal = ""
            if batchTotal > 0, batchCompleted >= batchTotal {
                batchTotal = 0
                batchCompleted = 0
            }
            statusText = scanEnabled ? "空闲" : "已停止"
            updateQueueSnapshot()
        } else {
            statusText = "运行中"
        }
    }

    private func outputURLFor(_ inputURL: URL) -> URL? {
        switch outputMode {
        case .overwrite:
            return inputURL.appendingPathExtension("tmp")
        case .outputFolder:
            guard !outputPath.isEmpty else { return nil }
            return URL(fileURLWithPath: outputPath).appendingPathComponent(inputURL.lastPathComponent)
        case .suffix:
            let base = inputURL.deletingPathExtension().lastPathComponent + suffixText
            let name = base + "." + inputURL.pathExtension
            return inputURL.deletingLastPathComponent().appendingPathComponent(name)
        }
    }

    private func matchesKeywords(_ name: String) -> Bool {
        let keys = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if keys.isEmpty { return true }
        return keys.contains { name.contains($0) }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "mkv", "avi", "m4v"].contains(ext)
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "[\(formatter.string(from: Date()))] \(message)"
        if logs.first == versionLine {
            logs.insert(entry, at: 1)
        } else {
            logs.insert(entry, at: 0)
        }
        if logs.count > logLimit {
            logs = Array(logs.prefix(logLimit))
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func applyKeyword() {
        if keywords.isEmpty {
            keywords = [draftKeyword]
        } else {
            keywords[0] = draftKeyword
        }
        applyKeywords()
    }

    func applyKeywords() {
        var cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned.count > maxKeywordCount {
            cleaned = Array(cleaned.prefix(maxKeywordCount))
        }
        let display = cleaned.joined(separator: " / ")
        keywords = cleaned
        if let first = cleaned.first {
            keyword = first
            draftKeyword = first
        } else {
            keyword = ""
            draftKeyword = ""
        }
        isKeywordEditing = false
        if display.isEmpty {
            log("关键词已设置：全部")
        } else if cleaned.count > 1 {
            log("关键词已设置：\(display)（\(cleaned.count)个）")
        } else {
            log("关键词已设置：\(display)")
        }
    }

    func applySuffix() {
        let trimmed = draftSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            suffixText = "_压缩"
            draftSuffix = suffixText
        } else {
            suffixText = trimmed
        }
        isSuffixEditing = false
        log("后缀已设置：\(suffixText)")
    }

    func addInputPath() {
        guard allInputPaths.count < maxInputFolderCount else { return }
        let panel = NSOpenPanel()
        panel.title = "添加监听目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appendInputPath(url.path)
        }
    }

    func removeInputPath(at index: Int) {
        let paths = allInputPaths
        guard index >= 0, index < paths.count else { return }
        if !inputPath.isEmpty {
            if index == 0 {
                inputPath = ""
            } else if index - 1 < extraInputPaths.count {
                extraInputPaths.remove(at: index - 1)
            }
        } else if index < extraInputPaths.count {
            extraInputPaths.remove(at: index)
        }
    }

    private func appendInputPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if allInputPaths.contains(trimmed) {
            log("监听目录已存在：\(trimmed)")
            return
        }
        if inputPath.isEmpty {
            inputPath = trimmed
        } else if extraInputPaths.count < max(0, maxInputFolderCount - 1) {
            extraInputPaths.append(trimmed)
        }
    }

    func pickFolder(title: String, forOutput: Bool) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if forOutput {
                outputPath = url.path
            } else {
                inputPath = url.path
            }
        }
    }

    func pickFfmpeg() {
        let panel = NSOpenPanel()
        panel.title = "选择 ffmpeg 可执行文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegPath = url.path
        }
    }

    func applyLaunchAtLogin() {
        enableLaunchAgent(launchAtLogin)
    }

    private func enableLaunchAgent(_ enabled: Bool) {
        let fm = FileManager.default
        let plistName = "com.yunfei.subtitle-compress.plist"
        let launchDir = (fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"))
        let plistURL = launchDir.appendingPathComponent(plistName)

        if enabled {
            try? fm.createDirectory(at: launchDir, withIntermediateDirectories: true)
            let bundlePath = Bundle.main.bundlePath
            let plist: [String: Any] = [
                "Label": "com.yunfei.subtitle-compress",
                "ProgramArguments": ["/usr/bin/open", "-a", bundlePath],
                "RunAtLoad": true
            ]
            let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try? data?.write(to: plistURL)
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }

    private func appSupportDir() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SubtitleCompress", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func processedStoreURL() -> URL {
        appSupportDir().appendingPathComponent("processed.json")
    }

    private func loadProcessedTimes() {
        let url = processedStoreURL()
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return
        }
        processedTimes = map
    }

    private func saveProcessedTimes() {
        let url = processedStoreURL()
        if let data = try? JSONEncoder().encode(processedTimes) {
            try? data.write(to: url)
        }
    }
}

struct ContentView: View {
    @StateObject private var state = AppState.shared
    @State private var showHelp = false
    @State private var showHelpDetail = false
    @State private var showDonate = false
    @State private var showUpdateLog = false
    @State private var showFfmpegDetail = false
    @State private var showMoreInputPaths = false
    @State private var showMoreKeywords = false
    @FocusState private var keywordFocusIndex: Int?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func bytesText(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "-" }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private var mainKeywordBinding: Binding<String> {
        Binding(
            get: { state.keywords.first ?? "" },
            set: { newValue in
                if state.keywords.isEmpty {
                    state.keywords = [newValue]
                } else {
                    state.keywords[0] = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monitorSection
                    scanSection
                    compressSection
                    outputSection
                    runtimeSection
                    logSection
                }
                .padding(.bottom, 12)
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 720)
        .background(WindowAccessor { window in
            window?.title = appDisplayTitle
            if let window {
                window.delegate = AppState.shared.windowDelegate
                AppState.shared.mainWindow = window
                AppState.shared.updateDockVisibility(windowVisible: window.isVisible)
            }
        })
        .sheet(isPresented: $showHelp) {
            helpSheet
        }
        .sheet(isPresented: $showDonate) {
            donateSheet
        }
    }

    private var keywordDisplayText: String {
        let keys = state.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if keys.isEmpty {
            return "全部"
        }
        if keys.count == 1 {
            return "“\(keys[0])”"
        }
        return "“\(keys.joined(separator: " / "))”"
    }

    private var keywordHighlightColor: Color {
        let keys = state.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return keys.isEmpty ? Color.secondary : Color.blue
    }

    private let labelWidth: CGFloat = 96
    private let inputWidth: CGFloat = 200

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .leading)
    }

    private func bitrateButton(title: String, preset: QualityPreset) -> some View {
        let selected = state.qualityPreset == preset
        return Button {
            state.qualityPreset = preset
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                }
                Text(title)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 72)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.blue : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.blue.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.blue : Color.gray.opacity(0.4), lineWidth: 1)
        )
    }

    private func mountBadgeColor() -> Color {
        switch state.mountStatus {
        case "已挂载":
            return Color.green.opacity(0.2)
        case "未挂载":
            return Color.red.opacity(0.2)
        case "检测关闭":
            return Color.gray.opacity(0.2)
        default:
            return Color.orange.opacity(0.2)
        }
    }

    private func mountTextColor() -> Color {
        switch state.mountStatus {
        case "已挂载":
            return Color.green
        case "未挂载":
            return Color.red
        case "检测关闭":
            return Color.gray
        default:
            return Color.orange
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(appDisplayTitle)
                    .font(.title2.weight(.bold))
                (Text("监控文件夹 -> 发现")
                    .foregroundColor(.secondary)
                + Text(keywordDisplayText)
                    .foregroundColor(keywordHighlightColor)
                    .fontWeight(keywordHighlightColor == .secondary ? .regular : .semibold)
                + Text("视频 -> 自动压缩")
                    .foregroundColor(.secondary))
            }
            Spacer()
            Link("主页", destination: URL(string: appAuthorLink)!)
                .buttonStyle(.bordered)
            Button("说明") {
                showHelp = true
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            Button(state.scanEnabled ? "停止" : "开始") {
                if state.scanEnabled {
                    state.stop()
                } else {
                    state.start()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var helpSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("功能说明")
                .font(.title2.weight(.bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• 自动监控指定文件夹，发现符合关键词的视频并加入队列")
                    Text("• 批量压缩：保持分辨率与帧率，压缩体积更省空间")
                    Text("• 支持覆盖原文件/另存文件夹/添加后缀三种输出方式")
                    Text("• 队列进度与当前任务实时显示，空闲状态一目了然")
                    Text("• 支持后台常驻与开机自启动，减少手动操作")
                    Text("• 自动检查并下载 ffmpeg，避免环境配置问题")
                    Text("适合解决：素材体积大、手动压缩耗时、批量处理容易遗漏的问题。")
                }
                .font(.body)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("详细说明") {
                    showHelpDetail = true
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("关闭") {
                    showHelp = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .sheet(isPresented: $showHelpDetail) {
            helpDetailSheet
        }
    }

    private var helpDetailSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("功能详情")
                .font(.title2.weight(.bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• 自动监测：持续监听指定目录，发现新文件立即入队")
                    Text("• 挂载检测：3/5/10 分钟自动检测挂载状态并提醒")
                    Text("• 多目录添加：最多 3 个监听目录，支持逐个添加/删除")
                    Text("• 多关键词过滤：最多 3 个关键词，文件名包含任意关键词即可触发")
                    Text("• 防止重复压缩：已处理文件会记录时间戳，避免反复压缩")
                    Text("• 进度可视化：0.2 秒刷新进度、已用时、剩余时间")
                    Text("• 压缩策略：保持分辨率与帧率，按码率档位压缩体积")
                    Text("• 4K 码率档位：12 / 18 / 25 Mbps（默认 18Mbps）")
                    Text("• 输出方式：覆盖原文件 / 另存到指定文件夹 / 添加后缀")
                    Text("• 硬件编码：显示 FFmpeg 版本与 H.264/H.265 硬编状态")
                    Text("• ffmpeg：自动检测/下载，开箱即用")
                }
                .font(.body)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("关闭") {
                    showHelpDetail = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
    }

    private func bundledImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func donateImageView(resourceName: String, label: String) -> some View {
        let image = bundledImage(named: resourceName)
        return VStack(spacing: 8) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 180, height: 180)
                    .overlay(
                        Text("\(label)二维码未找到")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var donateSheet: some View {
        VStack(spacing: 16) {
            Text("请我喝蜜雪冰城")
                .font(.title2.weight(.bold))
            HStack(spacing: 24) {
                donateImageView(resourceName: "wechat.png", label: "微信")
                donateImageView(resourceName: "alipay.jpg", label: "支付宝")
            }
            Button("关闭") {
                showDonate = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private var updateLogs: [String] {
        [
            "1.0.2.51 捐赠二维码内置打包",
            "1.0.2.50 修复启动校验误判（输出路径/压缩器）",
            "1.0.2.48 关键词确认后取消高亮",
            "1.0.2.47 关键词确认高亮与日志完善",
            "1.0.2.46 更多关键词增加确认按钮",
            "1.0.2.45 挂载检测恢复/监听与关键词UI优化",
            "1.0.2.44 恢复多目录/多关键词与功能详情增强",
            "1.0.1.33 修复关闭窗口后状态栏无法唤醒",
            "1.0.1.32 新增挂载自动检测开关与时间间隔设置",
            "1.0.1.31 挂载状态显示与未挂载提醒",
            "1.0.1.29 新增说明按钮与更新日志入口",
            "1.0.1.28 队列完成显示“当前空闲”，恢复 ffmpeg 自动下载"
        ]
    }

    private var monitorSection: some View {
        section("监听设置") {
            HStack {
                fieldLabel("监听目录：")
                Text(state.inputPath.isEmpty ? "未选择" : state.inputPath)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("选择…") {
                    state.pickFolder(title: "选择监听文件夹", forOutput: false)
                }
            }
            HStack {
                fieldLabel("更多目录：")
                if state.extraInputPaths.isEmpty {
                    Text("未添加")
                        .foregroundStyle(.secondary)
                } else {
                    Text("已添加 \(state.extraInputPaths.count) 个")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !state.extraInputPaths.isEmpty {
                    Button(showMoreInputPaths ? "收起" : "展开") {
                        showMoreInputPaths.toggle()
                    }
                }
                Button("添加…") {
                    state.addInputPath()
                    showMoreInputPaths = true
                }
                .disabled(state.allInputPaths.count >= maxInputFolderCount)
            }
            if showMoreInputPaths, !state.extraInputPaths.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.extraInputPaths.enumerated()), id: \.offset) { index, path in
                        HStack {
                            Text(path)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                state.removeInputPath(at: index + (state.inputPath.isEmpty ? 0 : 1))
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Color.red)
                            }
                        }
                    }
                }
                .padding(.leading, 72)
            }
            HStack {
                fieldLabel("挂载状态：")
                Text(state.mountStatus)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(mountBadgeColor())
                    .foregroundStyle(mountTextColor())
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer()
                Toggle("自动检测挂载", isOn: $state.mountMonitorEnabled)
            }
            HStack {
                fieldLabel("检测间隔：")
                Picker("", selection: $state.mountInterval) {
                    ForEach(MountCheckIntervalOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!state.mountMonitorEnabled)
                Spacer()
            }
            Toggle("包含子文件夹", isOn: $state.includeSubfolders)
        }
    }

    private var scanSection: some View {
        section("扫描规则") {
            HStack {
                fieldLabel("关键词：")
                TextField("带字幕", text: mainKeywordBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: inputWidth)
                    .focused($keywordFocusIndex, equals: 0)
                Button("确认") {
                    state.applyKeywords()
                    keywordFocusIndex = nil
                }
            }
            HStack {
                fieldLabel("更多关键词：")
                if state.keywords.count <= 1 {
                    Text("未添加")
                        .foregroundStyle(.secondary)
                } else {
                    Text("已添加 \(state.keywords.count - 1) 个")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.keywords.count > 1 {
                    Button(showMoreKeywords ? "收起" : "展开") {
                        showMoreKeywords.toggle()
                    }
                }
                Button("添加…") {
                    if state.keywords.isEmpty {
                        state.keywords = [""]
                    } else {
                        state.keywords.append("")
                    }
                    showMoreKeywords = true
                }
                .disabled(state.keywords.count >= maxKeywordCount)
            }
            if showMoreKeywords, state.keywords.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.keywords.dropFirst().enumerated()), id: \.offset) { index, keyword in
                        HStack {
                            TextField(keyword.isEmpty ? "关键词" : keyword, text: $state.keywords[index + 1])
                                .textFieldStyle(.roundedBorder)
                                .frame(width: inputWidth)
                                .focused($keywordFocusIndex, equals: index + 1)
                            Spacer()
                            Button(role: .destructive) {
                                state.keywords.remove(at: index + 1)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Color.red)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("确认") {
                            state.applyKeywords()
                            keywordFocusIndex = nil
                        }
                    }
                }
                .padding(.leading, 72)
            }
            HStack {
                fieldLabel("时间门槛：")
                Picker("", selection: $state.timeGate) {
                    ForEach(TimeGateOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            if state.timeGate == .customDate {
                DatePicker("起始日期", selection: $state.customDate, displayedComponents: .date)
            }
            HStack {
                fieldLabel("扫描频率：")
                Picker("", selection: $state.interval) {
                    ForEach(ScanIntervalOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.interval) { _ in
                    state.reschedule()
                }
            }
            Toggle("检测到新文件立即压缩", isOn: $state.immediateCompress)
        }
    }

    private var compressSection: some View {
        section("压缩设置") {
            HStack {
                fieldLabel("编码器：")
                Picker("", selection: $state.codec) {
                    ForEach(CodecOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                fieldLabel("码率档位：")
                HStack(spacing: 8) {
                    bitrateButton(title: "12Mbps", preset: .spaceSaving)
                    bitrateButton(title: "18Mbps 推荐", preset: .balanced)
                    bitrateButton(title: "25Mbps", preset: .highQuality)
                }
            }
            Text("当前：\(state.qualityPreset.displayTitle)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("自动压缩参数：保持分辨率/帧率，4K 码率 12/18/25 Mbps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        section("输出设置") {
            HStack {
                fieldLabel("输出方式：")
                Picker("", selection: $state.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            if state.outputMode == .outputFolder {
                HStack {
                    fieldLabel("输出文件夹：")
                    Text(state.outputPath.isEmpty ? "未选择" : state.outputPath)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("选择…") {
                        state.pickFolder(title: "选择输出文件夹", forOutput: true)
                    }
                }
            }
            HStack {
                fieldLabel("后缀：")
                ZStack {
                    TextField("_压缩", text: $state.draftSuffix)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(state.isSuffixEditing ? Color.white : Color.gray.opacity(0.2))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(state.isSuffixEditing ? Color.blue.opacity(0.7) : Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .disabled(!state.isSuffixEditing)
                    if !state.isSuffixEditing {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.isSuffixEditing = true
                            }
                    }
                }
                .frame(width: inputWidth)
                Button("确定") {
                    state.applySuffix()
                }
            }
            if state.outputMode == .overwrite {
                Text("覆盖模式会直接替换原文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Toggle("开机自启动", isOn: $state.launchAtLogin)
                    .onChange(of: state.launchAtLogin) { _ in
                        state.applyLaunchAtLogin()
                    }
                Spacer()
                Toggle("后台常驻（关闭窗口不退出）", isOn: $state.keepAlive)
            }
        }
    }

    private var runtimeSection: some View {
        section("运行状态") {
            HStack {
                Text("状态：\(state.statusDisplay)")
                Spacer()
                Text("上次扫描：\(state.lastScan?.formatted(date: .omitted, time: .standard) ?? "无")")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("FFmpeg \(state.ffmpegVersionShort) | \(state.hardwareStatusText)")
                    .font(.caption)
                    .foregroundStyle(state.hardwareStatusText.contains("已开启") ? Color.green : Color.secondary)
                Button(action: { showFfmpegDetail = true }) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showFfmpegDetail) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FFmpeg 版本")
                            .font(.headline)
                        Text(state.ffmpegVersionFull.isEmpty ? "未配置" : state.ffmpegVersionFull)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("检测到的硬件编码器")
                            .font(.headline)
                        if state.ffmpegEncoderList.isEmpty {
                            Text("无")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(state.ffmpegEncoderList, id: \.self) { item in
                                Text(item)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("当前实际使用：\(state.currentEncoderText.isEmpty ? "未知" : state.currentEncoderText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !state.hardwareStatusHint.isEmpty {
                            Text("提示：\(state.hardwareStatusHint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !state.ffmpegEncoderError.isEmpty {
                            Text("错误：\(state.ffmpegEncoderError)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(width: 420)
                }
            }
            if !state.currentFileName.isEmpty {
                HStack {
                    Text("当前任务：\(state.currentFileName)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(state.currentFileProgress * 100))%")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: state.currentFileProgress)
                HStack {
                    Text("预估时长：\(state.currentFileEstimatedTotal)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("预计剩余：\(state.currentFileRemaining)")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("当前空闲")
                        .foregroundStyle(.secondary)
                    if !state.lastCompletedName.isEmpty {
                        Text("已完成：\(state.lastCompletedName)")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            if state.batchTotal > 0 {
                HStack {
                    Text("队列进度：\(state.batchCompleted)/\(state.batchTotal)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(state.queueProgress * 100))%")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: state.queueProgress)
            }
            if !state.queueItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待处理列表：")
                        .foregroundStyle(.secondary)
                    ForEach(state.queueItems.prefix(6)) { item in
                        Text("• \(item.name)  原始 \(bytesText(item.sizeBytes))  预估 \(bytesText(item.estimatedBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("ffmpeg：\(state.resolvedFfmpegPath ?? "未找到")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("选择 ffmpeg") {
                    state.pickFfmpeg()
                }
            }
            HStack {
                Text(appAuthor)
                    .foregroundStyle(.secondary)
                Link("主页", destination: URL(string: appAuthorLink)!)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("日志")
                    .font(.headline)
                Spacer()
                Button(showUpdateLog ? "收起更新日志" : "更新日志") {
                    showUpdateLog.toggle()
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .controlSize(.small)
            }
            if showUpdateLog {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(updateLogs, id: \.self) { entry in
                        Text(entry)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .opacity(0.8)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.logs.prefix(12), id: \.self) { entry in
                    Text(entry)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(0.8)
                }
                if state.logs.isEmpty {
                    Text("暂无日志")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(0.8)
                }
            }
            HStack {
                Spacer()
                Button("请作者喝奶茶") {
                    showDonate = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            self.callback(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.callback(nsView.window)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let taskItem = NSMenuItem(title: "当前任务：无", action: nil, keyEquivalent: "")
    private let queueItem = NSMenuItem(title: "队列剩余：0", action: nil, keyEquivalent: "")
    private let logItem = NSMenuItem(title: "最近日志：-", action: nil, keyEquivalent: "")
    private let openItem = NSMenuItem(title: "打开主界面", action: #selector(openMainWindow), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationAuthorization()
        setupStatusItem()
        refreshMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenu()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !AppState.shared.keepAlive
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let icon = NSApp.applicationIconImage {
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            }
        }

        menu.autoenablesItems = false
        taskItem.isEnabled = false
        queueItem.isEnabled = false
        logItem.isEnabled = false
        openItem.target = self
        quitItem.target = self

        menu.addItem(taskItem)
        menu.addItem(queueItem)
        menu.addItem(logItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(openItem)
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func refreshMenu() {
        let state = AppState.shared
        let currentName = state.currentFileName
        let percent = Int(state.currentFileProgress * 100)
        if currentName.isEmpty {
            taskItem.title = "当前任务：无"
        } else {
            taskItem.title = "当前任务：\(currentName) \(percent)%"
        }
        let pending = state.queueItems.count + (currentName.isEmpty ? 0 : 1)
        queueItem.title = "队列剩余：\(pending)"
        logItem.title = "最近日志：\(state.logs.first ?? "-")"
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = AppState.shared.mainWindow {
            window.makeKeyAndOrderFront(nil)
            AppState.shared.updateDockVisibility(windowVisible: true)
            return
        }
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            AppState.shared.mainWindow = window
            AppState.shared.updateDockVisibility(windowVisible: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appDisplayTitle
        window.center()
        window.contentView = NSHostingView(rootView: ContentView())
        AppState.shared.mainWindow = window
        AppState.shared.updateDockVisibility(windowVisible: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@main
struct SubtitleCompressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let state = AppState.shared
        if state.keepAlive {
            sender.orderOut(nil)
            state.updateDockVisibility(windowVisible: false)
            return false
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppState.shared.updateDockVisibility(windowVisible: true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        AppState.shared.updateDockVisibility(windowVisible: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        AppState.shared.updateDockVisibility(windowVisible: true)
    }
}

private extension Int {
    func nonZeroOrDefault(_ value: Int) -> Int {
        self == 0 ? value : self
    }
}
