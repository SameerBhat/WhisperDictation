import AVFoundation

final class AudioCapture {
    /// Every AVAudioEngine call (create, select device, prepare, tap, start, stop)
    /// runs on this worker, never on the main thread. CoreAudio can block forever
    /// inside engine setup: creating the input node makes AVAudioEngine move the
    /// AUHAL to its private default-device aggregate on an internal thread, and when
    /// that races with our explicit device selection the internal switch fails
    /// ('nope', "listener was already added") and the selecting thread never
    /// returns. On the main thread that froze the whole app (hotkey tap, menu bar)
    /// until it was force-killed. Now the main thread waits at most
    /// `startTimeout`; a stuck worker is abandoned and the next recording gets a
    /// fresh one. Main-thread only (written by start/stop, both called on main).
    private var worker = AudioCapture.makeWorker()

    private static func makeWorker() -> DispatchQueue {
        DispatchQueue(label: "com.whisperdictation.audio-capture", qos: .userInitiated)
    }

    /// How long the main thread waits for the engine to start before giving up.
    /// A healthy start takes ~50–250 ms.
    static let startTimeout: TimeInterval = 3

    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()

    // Guarded by bufferLock. Each start bumps `sessionGeneration`; stop and an
    // abandoned start bump it again. Tap callbacks, config notifications and a
    // late-finishing start from an abandoned worker compare against it, so a
    // stale engine can never feed or stop the current session.
    private var sessionGeneration = 0
    private var activeEngine: AVAudioEngine?
    private var activeObserver: NSObjectProtocol?

    /// Invoked when the audio engine's configuration changes while recording
    /// (e.g. the selected input device is unplugged). Called on an arbitrary
    /// thread — the handler must hop to the main actor before touching UI state.
    var onConfigurationChange: (() -> Void)?

    /// Invoked once when the recording reaches the maximum duration cap. Called on
    /// the audio tap thread — the handler must hop to the main actor. The engine
    /// should treat this exactly like the user stopping (transcribe what was captured).
    var onMaxDurationReached: (() -> Void)?

    /// Optional live-mode hook: each converted 16 kHz mono Float32 batch,
    /// invoked on the tap thread. The receiver must hop off this thread
    /// immediately (VADSegmenter.append does). Cleared by the engine when a
    /// live session ends. Written on main while the tap thread reads it, so both
    /// sides go through `bufferLock` (a closure is two words; a torn read could
    /// invoke a released context).
    var onSamples: (([Float]) -> Void)? {
        get { bufferLock.lock(); defer { bufferLock.unlock() }; return _onSamples }
        set { bufferLock.lock(); _onSamples = newValue; bufferLock.unlock() }
    }
    private var _onSamples: (([Float]) -> Void)?

    private static let sampleRate: Double = 16000

    /// Hard cap on recording length (5 minutes). Guards against an unbounded buffer
    /// if a toggle-mode session is left running — 5 min ≈ 18.4 MB of Float32 at 16kHz.
    static let maxRecordingSeconds: Double = 300
    static let maxRecordingSamples = Int(sampleRate * maxRecordingSeconds)

    /// True exactly on the append that first crosses the duration cap, so the stop is
    /// triggered once and only once. Pure/static for unit testing without hardware.
    static func crossesDurationCap(previousCount: Int, newCount: Int) -> Bool {
        previousCount < maxRecordingSamples && newCount >= maxRecordingSamples
    }

    /// AVAudioEngine posts a configuration-change notification once right after
    /// start() when the AUHAL renegotiates a stale format (observed after another
    /// app switches the device's sample rate). In that case the engine keeps
    /// running and the tap keeps delivering at its installed format, so the
    /// session must continue. A real input change (device unplugged, rate or
    /// channel flip mid-session) stops the engine or invalidates the tap format
    /// and must end the session. Pure/static for unit testing without hardware.
    static func isBenignConfigurationChange(
        isRunning: Bool,
        tapRate: Double, tapChannels: UInt32,
        hwRate: Double, hwChannels: UInt32
    ) -> Bool {
        isRunning && hwRate == tapRate && hwChannels == tapChannels && hwRate > 0 && hwChannels > 0
    }
    private static let desiredFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Starts capture on the worker and waits (bounded) for it. Main thread only.
    func startRecording() throws {
        // Snapshot main-thread state for the worker.
        let selectedUID = AppSettings.shared.selectedAudioDeviceUID
        let devices = AudioDeviceManager.shared.inputDevices

        bufferLock.lock()
        sessionGeneration += 1
        let generation = sessionGeneration
        audioBuffer.removeAll(keepingCapacity: true)
        // Pre-size for ~60s of 16kHz mono Float32 to avoid repeated reallocation of
        // the hot append path. The buffer still grows if a session runs longer (up to
        // the 5-minute cap enforced in the tap).
        audioBuffer.reserveCapacity(Int(Self.sampleRate) * 60)
        bufferLock.unlock()

        let outcome = StartOutcome()
        let done = DispatchSemaphore(value: 0)
        worker.async {
            do {
                try self.startOnWorker(generation: generation, selectedUID: selectedUID, devices: devices)
            } catch {
                outcome.error = error
            }
            done.signal()
        }

        if done.wait(timeout: .now() + Self.startTimeout) == .timedOut {
            fputs("[AudioCapture] Engine start did not return within \(Self.startTimeout)s — CoreAudio is stuck; abandoning that worker\n", stderr)
            bufferLock.lock()
            if sessionGeneration == generation { sessionGeneration += 1 }
            bufferLock.unlock()
            worker = Self.makeWorker()
            throw AudioCaptureError.audioSystemNotResponding
        }
        if let error = outcome.error { throw error }
        fputs("[AudioCapture] Recording started\n", stderr)
    }

    /// Box for the worker's start result. Written on the worker before
    /// `done.signal()` and read on main only after a successful wait, so the
    /// semaphore orders the accesses; after a timeout main never reads it.
    private final class StartOutcome: @unchecked Sendable {
        var error: Error?
    }

    private func isCurrent(_ generation: Int) -> Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return sessionGeneration == generation
    }

    /// Worker only.
    private func startOnWorker(generation: Int, selectedUID: String?, devices: [AudioInputDevice]) throws {
        let engine = AVAudioEngine()

        // Apply the user-selected input device BEFORE prepare()/reading the format,
        // so the hardware format reflects the chosen device. Failure falls back to
        // the system default device (logged inside applySelectedDevice).
        AudioDeviceManager.applySelectedDevice(to: engine, selectedUID: selectedUID, devices: devices)

        let inputNode = engine.inputNode

        // prepare() FIRST — settles the audio hardware format
        engine.prepare()

        // Must be inputFormat (the hardware capture format), NOT outputFormat: after
        // an external sample-rate change (e.g. a conferencing app switching the mic to
        // 16 kHz), outputFormat keeps vending the stale rate while installTap validates
        // the tap format against the real hardware rate and throws NSException on
        // mismatch — an uncaught crash, since ObjC exceptions can't be caught in Swift.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        fputs("[AudioCapture] Hardware format: \(hwFormat.sampleRate)Hz \(hwFormat.channelCount)ch\n", stderr)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: Self.desiredFormat) else {
            fputs("[AudioCapture] Could not create converter from hardware format\n", stderr)
            throw AudioCaptureError.invalidFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            #if DEBUG
            fputs(".", stderr) // Heartbeat — proves callback is firing (DEBUG only)
            #endif
            guard let self else { return }

            let ratio = Self.sampleRate / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: Self.desiredFormat, frameCapacity: capacity) else {
                #if DEBUG
                fputs("X", stderr)
                #endif
                return
            }

            // Per CLAUDE.md: reset before each conversion. Without this, the converter's
            // internal state expects a continuous stream and produces empty output across
            // discrete tap-callback buffers.
            converter.reset()

            var consumed = false
            var convErr: NSError?
            // Result status is only useful for the DEBUG heartbeat below; discard it in
            // release so it isn't an unused binding (DEBUG is not defined by `make app`).
            _ = converter.convert(to: converted, error: &convErr) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let convErr {
                #if DEBUG
                fputs("[E:\(convErr.code)]", stderr)
                #endif
                return
            }

            if converted.frameLength > 0, let data = converted.floatChannelData {
                let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
                self.bufferLock.lock()
                // A stale engine (stopped or abandoned session) still draining its
                // last buffers must not leak into the current session.
                guard self.sessionGeneration == generation else {
                    self.bufferLock.unlock()
                    return
                }
                let previousCount = self.audioBuffer.count
                self.audioBuffer.append(contentsOf: samples)
                let crossedCap = Self.crossesDurationCap(previousCount: previousCount, newCount: self.audioBuffer.count)
                let sink = self._onSamples   // read under the lock; called outside it
                self.bufferLock.unlock()
                sink?(samples)
                #if DEBUG
                fputs("+", stderr) // successful conversion (DEBUG only)
                #endif
                // Fires exactly once (on the crossing append). Hop handled by the engine.
                if crossedCap { self.onMaxDurationReached?() }
            } else {
                #if DEBUG
                fputs("[f:\(converted.frameLength)]", stderr)
                #endif
            }
        }

        // Detect audio configuration changes mid-recording (device unplugged, a new
        // default device appearing, sample-rate change — all invalidate the tap).
        // Observe this specific engine only. Removed when the session is torn down.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, self.isCurrent(generation) else { return }
            let hw = engine?.inputNode.inputFormat(forBus: 0)
            if Self.isBenignConfigurationChange(
                isRunning: engine?.isRunning ?? false,
                tapRate: hwFormat.sampleRate, tapChannels: hwFormat.channelCount,
                hwRate: hw?.sampleRate ?? 0, hwChannels: hw?.channelCount ?? 0
            ) {
                fputs("[AudioCapture] Engine configuration changed (benign renegotiation) — continuing\n", stderr)
                return
            }
            fputs("[AudioCapture] Engine configuration changed\n", stderr)
            self.onConfigurationChange?()
        }

        do {
            try engine.start()
        } catch {
            Self.teardown(engine: engine, observer: observer)
            throw error
        }

        // Publish the engine — unless this start was abandoned (timed out) or
        // superseded while it was stuck, in which case shut it down right here.
        bufferLock.lock()
        let stillCurrent = sessionGeneration == generation
        if stillCurrent {
            activeEngine = engine
            activeObserver = observer
        }
        bufferLock.unlock()
        if !stillCurrent {
            fputs("[AudioCapture] Late start from an abandoned session — shutting it down\n", stderr)
            Self.teardown(engine: engine, observer: observer)
        }
    }

    /// Remove the observer and tap, stop the engine. Worker only (may block).
    private static func teardown(engine: AVAudioEngine, observer: NSObjectProtocol?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Stops capture and returns the captured buffer. Never blocks on CoreAudio:
    /// the session is closed under the lock (late tap buffers are dropped by the
    /// generation check) and the engine teardown is queued on the worker.
    /// - Parameter trimTrailingSeconds: optional number of seconds to trim from the END of the
    ///   buffer. Used by toggle hotkey mode to discard the silent hold-to-stop interval, which
    ///   would otherwise be transcribed by Whisper as hallucinated punctuation/filler.
    func stopRecording(trimTrailingSeconds: TimeInterval = 0) -> [Float] {
        bufferLock.lock()
        sessionGeneration += 1
        let engine = activeEngine
        let observer = activeObserver
        activeEngine = nil
        activeObserver = nil
        var buffer = audioBuffer
        audioBuffer.removeAll()
        bufferLock.unlock()

        if let engine {
            worker.async { Self.teardown(engine: engine, observer: observer) }
        }

        if trimTrailingSeconds > 0 {
            let samplesToTrim = Int(trimTrailingSeconds * Self.sampleRate)
            if buffer.count > samplesToTrim {
                buffer.removeLast(samplesToTrim)
            } else {
                buffer.removeAll()
            }
        }

        let sec = Double(buffer.count) / Self.sampleRate
        fputs("[AudioCapture] Stopped. \(buffer.count) samples (\(String(format: "%.1f", sec))s, trimmed \(String(format: "%.1f", trimTrailingSeconds))s)\n", stderr)
        return buffer
    }

    /// True while a started session is open (between a successful start and stop).
    var isRecording: Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return activeEngine != nil
    }
}

enum AudioCaptureError: LocalizedError {
    case invalidFormat
    case audioSystemNotResponding

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Audio input format is invalid."
        case .audioSystemNotResponding:
            return "The microphone didn’t start (macOS audio didn’t respond). Try again."
        }
    }
}
