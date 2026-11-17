import Foundation

/// Process-wide diagnostics for a menu-bar app that otherwise logs to an
/// invisible stderr:
/// - stderr (every `fputs(..., stderr)` in the app) is copied, with timestamps, to
///   ~/Library/Logs/WhisperDictation/WhisperDictation.log (rotated at 5 MB).
/// - A watchdog notices when the main thread stops responding for
///   `hangThreshold` seconds and saves a `sample` of every thread's stack to
///   ~/Library/Logs/WhisperDictation/hang-<time>.txt, so a freeze leaves evidence
///   even if the app is force-killed afterwards.
/// Transcribed text is never written by the app's release logging, so the log
/// holds timings and states only.
enum Diagnostics {
    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WhisperDictation", isDirectory: true)
    static let maxLogBytes = 5 * 1024 * 1024
    static let hangThreshold: TimeInterval = 5

    private static var started = false

    /// Call once, on the main thread, as early as possible.
    static func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        // Keep stderr on the terminal when run from a shell (make run / debugging).
        if isatty(STDERR_FILENO) == 0 { redirectStderrToLogFile() }
        startHangWatchdog()
        fputs("[Diagnostics] Started (pid \(getpid()), version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"))\n", stderr)
    }

    // MARK: - Log file

    private static func redirectStderrToLogFile() {
        let logURL = logDirectory.appendingPathComponent("WhisperDictation.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
           size > maxLogBytes {
            let old = logDirectory.appendingPathComponent("WhisperDictation.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        guard let file = fopen(logURL.path, "a") else { return }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { fclose(file); return }
        let readFD = fds[0]
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        setvbuf(stderr, nil, _IONBF, 0)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")   // 24h regardless of user settings
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let thread = Thread {
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(readFD, &chunk, chunk.count)
                if n <= 0 { break }
                pending.append(contentsOf: chunk[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    fputs("\(formatter.string(from: Date())) \(line)\n", file)
                    fflush(file)
                }
            }
        }
        thread.name = "WhisperDictation.stderr-log"
        thread.qualityOfService = .utility
        thread.start()
    }

    // MARK: - Main-thread hang watchdog

    /// Uptime (excludes system sleep, so sleep is never mistaken for a hang) of the
    /// last time the main thread answered. Guarded by `lock`.
    private static var lastMainResponse = ProcessInfo.processInfo.systemUptime
    private static let lock = NSLock()

    private static func startHangWatchdog() {
        let thread = Thread {
            var reportedThisHang = false
            while true {
                Thread.sleep(forTimeInterval: 1)
                DispatchQueue.main.async {
                    lock.lock(); lastMainResponse = ProcessInfo.processInfo.systemUptime; lock.unlock()
                }
                lock.lock()
                let silentFor = ProcessInfo.processInfo.systemUptime - lastMainResponse
                lock.unlock()
                if silentFor < hangThreshold {
                    if reportedThisHang {
                        fputs("[Diagnostics] Main thread responsive again\n", stderr)
                        reportedThisHang = false
                    }
                    continue
                }
                guard !reportedThisHang else { continue }
                reportedThisHang = true
                captureHangSample(silentFor: silentFor)
            }
        }
        thread.name = "WhisperDictation.hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func captureHangSample(silentFor: TimeInterval) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let out = logDirectory.appendingPathComponent("hang-\(formatter.string(from: Date())).txt")
        fputs("[Diagnostics] MAIN THREAD UNRESPONSIVE for \(Int(silentFor))s — sampling all threads to \(out.path)\n", stderr)
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(getpid()), "3", "-file", out.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        do {
            try sample.run()
        } catch {
            fputs("[Diagnostics] Could not run sample: \(error)\n", stderr)
        }
    }
}
