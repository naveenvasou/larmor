// larmor_audio.swift — Larmor's audio helper: the microphone with HARDWARE echo
// cancellation in, the agent's voice out, through one VoiceProcessingIO unit.
// SIGUSR1 flushes the playback ring instantly, so a barge-in silences the agent
// within one render block instead of after the queued audio.
//
// Capture the MICROPHONE with HARDWARE echo cancellation
// using macOS's native Voice Processing I/O audio unit
// (kAudioUnitSubType_VoiceProcessingIO). Writes raw Int16 mono PCM to stdout.
//
// WHY this exists:
//   Python's sounddevice cannot open the VoiceProcessingIO unit, which is the
//   only supported way to get Apple's built-in AEC + noise suppression on the
//   mic — the same processing Zoom/Teams/FaceTime get "for free". macOS does ALL
//   the signal processing; we build no echo algorithm. The unit subtracts the
//   machine's own output audio (our TTS + any system sound) out of the mic input
//   in real time. That is what unlocks true barge-in / interruption handling:
//   the assistant can keep listening while it speaks, because its own voice is
//   cancelled from the captured signal but the user's is not.
//
// HOW VPIO works (the plumbing, calibrated as "an afternoon"):
//   - It is a single I/O unit with TWO buses:
//       bus 0 (output/speaker side)  — the render "reference" AEC subtracts.
//       bus 1 (input/microphone side) — what we pull the cleaned mic from.
//   - You enable IO on both scopes, install an input callback, and pull frames
//     from bus 1 with AudioUnitRender inside that callback.
//   - AEC/AGC/noise-suppression are ON by default for this unit; we additionally
//     assert bypass=OFF and AGC=ON explicitly so behavior is deterministic.
//
// Output contract:
//   - On the FIRST rendered buffer, prints the negotiated format to stderr:
//         FORMAT sr=<rate> ch=<channels>
//     so Python knows the true sample rate. We request 16 kHz mono Int16.
//   - Then streams little-endian Int16 mono PCM frames to stdout, forever.
//
// FAR-END REFERENCE input (TASK 6 — the real AEC fix):
//   AEC can only cancel audio it is GIVEN as the far-end reference. Leaving
//   bus 0 unfed made macOS fall back to a blunt global output duck (all
//   speaker audio quieted) instead of real cancellation. So this binary now
//   also *plays* audio: it installs a render callback on bus 0 (the
//   output/speaker element) that drains a ring buffer filled from STDIN.
//   Whatever PCM the caller writes to our stdin is played out the speaker at
//   full volume AND used by VPIO as the AEC reference — the Zoom/Teams
//   pattern. The source is pluggable by design: TTS today, the full speaker
//   mix later; it is all just "write PCM to stdin".
//   - stdin protocol: little-endian Int16 mono at the rate announced on
//     stderr as:  REF_FORMAT sr=<rate> ch=1
//     (announced once at startup, before FORMAT). Writes are backpressured:
//     the ring holds ~10 s; when full the stdin reader blocks, so the pipe
//     naturally paces the writer at real time.
//   - stdin EOF / nothing written → the callback renders silence, which is
//     exactly the old behaviour (nothing to cancel). The mic contract
//     (FORMAT announce + Int16 mono to stdout) is unchanged.
//
// Build: cp larmor_audio.swift main.swift && swiftc -O main.swift mic_arbiter.swift -o larmor_audio
// Run:   ./larmor_audio   (needs Microphone permission for the parent app)

import Foundation
import AudioToolbox
import AVFoundation
import CoreAudio

let errh = FileHandle.standardError
func elog(_ s: String) { errh.write((s + "\n").data(using: .utf8)!) }
func die(_ s: String) -> Never { elog("FATAL " + s); exit(1) }

// Requested capture format: 16 kHz mono, 16-bit signed integer, interleaved.
let kSampleRate: Double = 16000
let kChannels: UInt32 = 1
// Far-end reference ring capacity, in seconds of audio at the reference rate.
// Big enough that a writer can burst a phrase ahead of real time; small enough
// that a stalled writer can't queue minutes of stale reference.
let kRefRingSeconds: Double = 10

// Thread-safe Int16 ring buffer between the stdin reader thread (producer)
// and the bus-0 render callback (consumer). The lock is os_unfair_lock held
// only for a bounded memmove-style copy — cheap enough for a render thread at
// audio block rate. When empty the consumer zero-fills (renders silence).
final class RefRing {
    private let capacity: Int
    private var storage: [Int16]
    private var readIdx = 0
    private var count = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.storage = [Int16](repeating: 0, count: self.capacity)
        self.lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock_s())
    }

    /// Write up to `src.count` samples; returns how many fit (caller retries
    /// the remainder — that block-until-space is the writer backpressure).
    func write(_ src: UnsafeBufferPointer<Int16>) -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let n = min(src.count, capacity - count)
        var w = (readIdx + count) % capacity
        for i in 0..<n {
            storage[w] = src[i]
            w += 1; if w == capacity { w = 0 }
        }
        count += n
        return n
    }

    /// Drop everything queued for playback (barge-in). Returns samples dropped.
    @discardableResult
    func clear() -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let dropped = count
        count = 0
        return dropped
    }

    /// Read up to `max` samples into `dst`; returns how many were available.
    /// The render callback zero-fills whatever this doesn't cover.
    func read(into dst: UnsafeMutablePointer<Int16>, max n: Int) -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let m = min(n, count)
        for i in 0..<m {
            dst[i] = storage[readIdx]
            readIdx += 1; if readIdx == capacity { readIdx = 0 }
        }
        count -= m
        return m
    }
}

final class VPIOCapture {
    var unit: AudioUnit?
    let out = FileHandle.standardOutput
    var announced = false
    // Client (canonical) format we ask the unit to convert the mic stream into.
    var clientFormat = AudioStreamBasicDescription()
    // Reusable buffer list target for AudioUnitRender.
    var renderBufferData = Data()
    // Far-end reference: stdin PCM → ring → bus-0 render callback (AEC ref).
    var refRing: RefRing?
    var refRate: Double = 0

    func start() {
        // --- describe & instantiate the VoiceProcessingIO unit ------------------
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            die("VoiceProcessingIO component not found")
        }
        var au: AudioUnit?
        check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let unit = au else { die("null audio unit") }
        self.unit = unit

        let inputBus: AudioUnitElement = 1   // microphone side (bus 0 = render/speaker)

        // --- enable IO: input on the input scope of bus 1 ----------------------
        var enable: UInt32 = 1
        check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, inputBus,
                                   &enable, UInt32(MemoryLayout<UInt32>.size)),
              "enable input IO")
        // --- enable IO: output on the output scope of bus 0 ---------------------
        // Bus 0 is the speaker/render side. It is enabled by default for output
        // units, but we assert it: this is the bus we FEED the far-end reference
        // through (see the render callback below). Feeding it — instead of
        // leaving it empty — is what turns macOS's blunt "duck all speaker
        // audio" fallback into real AEC: VPIO plays our reference at full
        // volume AND subtracts it from the mic.
        let outputBus: AudioUnitElement = 0
        var enableOut: UInt32 = 1
        check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, outputBus,
                                   &enableOut, UInt32(MemoryLayout<UInt32>.size)),
              "enable output IO")

        // --- client format --------------------------------------------------
        // VPIO runs its AEC at the microphone hardware's NATIVE sample rate. If
        // we force a foreign rate (e.g. 16 kHz) onto the input bus, the unit's
        // internal converter can fail AudioUnitInitialize with -10875
        // (kAudioUnitErr_InvalidPropertyValue) on some macOS versions. So we ask
        // the unit what native rate it produces, keep THAT rate, and only change
        // the encoding to mono Int16. Python resamples 48k→16k (same contract as
        // sck_capture.swift, which also announces its real rate on stderr).
        var hwFormat = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, inputBus, &hwFormat, &sz),
              "get native input format")
        let nativeRate = hwFormat.mSampleRate > 0 ? hwFormat.mSampleRate : kSampleRate

        clientFormat = AudioStreamBasicDescription(
            mSampleRate: nativeRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * kChannels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * kChannels,
            mChannelsPerFrame: kChannels,
            mBitsPerChannel: 16,
            mReserved: 0)
        // Format the unit hands US on the OUTPUT scope of the INPUT bus (bus 1):
        // this is the cleaned mic stream we read.
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, inputBus,
                                   &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
              "set client stream format on input bus output scope")

        // --- far-end reference format on bus 0 (input scope = what WE supply) --
        // Same -10875 caution as the input bus: don't force a foreign rate.
        // Prefer the output hardware's native rate (queried from bus 0's output
        // scope); AudioUnitInitialize below retries other rates if needed.
        var refFmtRate = nativeRate
        var hwOutFormat = AudioStreamBasicDescription()
        sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Output, outputBus,
                                &hwOutFormat, &sz) == noErr,
           hwOutFormat.mSampleRate > 0 {
            refFmtRate = hwOutFormat.mSampleRate
        }
        var refFormat = AudioStreamBasicDescription(
            mSampleRate: refFmtRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, outputBus,
                                   &refFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
              "set reference stream format on output bus input scope")

        // Render callback on bus 0: VPIO pulls the far-end reference from us.
        var refCb = AURenderCallbackStruct(
            inputProc: vpioRefRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, outputBus,
                                   &refCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
              "set reference render callback on bus 0")

        // --- turn AEC/AGC ON explicitly (deterministic) ------------------------
        // Bypass voice processing = OFF → AEC + NS active. Set VPIO_BYPASS_AEC=1
        // to flip bypass ON — this is the CONTROL run for the AEC self-test
        // (scripts/aec_selftest.py): with AEC bypassed the mic should hear the
        // speaker output, proving the test is real and that the ON run's silence
        // is genuine cancellation, not a dead mic. Not used in production.
        let bypassAEC = (ProcessInfo.processInfo.environment["VPIO_BYPASS_AEC"] == "1")
        var bypass: UInt32 = bypassAEC ? 1 : 0
        check(AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing,
                                   kAudioUnitScope_Global, 0,
                                   &bypass, UInt32(MemoryLayout<UInt32>.size)),
              bypassAEC ? "ENABLE bypass (AEC OFF — control run)"
                        : "disable bypass (enable AEC)")
        if bypassAEC { elog("WARNING: VPIO_BYPASS_AEC=1 — AEC is OFF (control run)") }
        // Automatic gain control ON.
        var agc: UInt32 = 1
        check(AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                   kAudioUnitScope_Global, 0,
                                   &agc, UInt32(MemoryLayout<UInt32>.size)),
              "enable AGC")

        // --- DON'T duck other apps' audio (macOS 14+) ---------------------------
        // By default, the moment VPIO starts, macOS CONSTANTLY ducks all other
        // audio (YouTube, music…) — the legacy phone-call behavior. Apple's
        // header: "If not set, the default ducking configuration is to disable
        // advanced ducking, with a ducking level set to Default." That default
        // is what made system audio go quiet whenever we ran.
        // The modern config (WWDC23, kAUVoiceIOProperty_OtherAudioDuckingConfiguration
        // = 2108) is how Zoom/Teams keep your video loud during a call:
        //   mEnableAdvancedDucking = true → duck ONLY while voice activity is
        //     present (dynamic), not constantly;
        //   mDuckingLevel = Min → and even then, barely.
        // Env overrides for experiments: VPIO_DUCKING=off|min|mid|max|default
        // ("off" = advanced+Min, the least intrusive; that's the default here).
        // "off" (default) = the LEAST intrusive: advanced ducking OFF (static, not
        // the dynamic voice-activity ducking that causes audio to dip in-and-out
        // while media plays) + Min level. Advanced=true is what caused the
        // "system audio dips and recovers" — it re-ducks on every detected voice
        // burst. Static+Min is the closest to "don't touch my media".
        let duckMode = ProcessInfo.processInfo.environment["VPIO_DUCKING"] ?? "off"
        var duckCfg = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: false,
            mDuckingLevel: .min)
        switch duckMode {
        case "advanced": duckCfg.mEnableAdvancedDucking = true   // dynamic (dips)
        case "default":  duckCfg.mDuckingLevel = .default
        case "min":      duckCfg.mDuckingLevel = .min
        case "mid":      duckCfg.mDuckingLevel = .mid
        case "max":      duckCfg.mDuckingLevel = .max
        default:         break  // "off" → advanced OFF + Min level (least dip)
        }
        let duckStatus = AudioUnitSetProperty(unit,
                                   kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                                   kAudioUnitScope_Global, 0,
                                   &duckCfg,
                                   UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        if duckStatus == noErr {
            elog("ducking: advanced=\(duckCfg.mEnableAdvancedDucking) level=\(duckCfg.mDuckingLevel.rawValue) (other apps' audio stays loud)")
        } else {
            // Non-fatal: older macOS or property rejected — fall back to legacy
            // behavior (constant duck) rather than dying.
            elog("WARNING: ducking config rejected (\(duckStatus)) — system may duck other audio")
        }

        // --- install the input callback ---------------------------------------
        var cb = AURenderCallbackStruct(
            inputProc: vpioInputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, inputBus,
                                   &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
              "set input callback")

        // Don't let the unit allocate its own input buffers — we render into ours.
        var shouldAllocate: UInt32 = 0
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer,
                                   kAudioUnitScope_Output, inputBus,
                                   &shouldAllocate, UInt32(MemoryLayout<UInt32>.size)),
              "disable buffer auto-allocation")

        // --- initialize & start ------------------------------------------------
        // If the unit rejects our reference rate at init (-10875, the same trap
        // as the input bus), retry with other plausible rates before giving up.
        var initStatus = AudioUnitInitialize(unit)
        if initStatus != noErr {
            for cand in [nativeRate, 48000, 44100, 24000, 16000] where cand != refFmtRate {
                refFormat.mSampleRate = cand
                guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, outputBus,
                                           &refFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
                else { continue }
                initStatus = AudioUnitInitialize(unit)
                if initStatus == noErr {
                    refFmtRate = cand
                    elog("ref: rate \(Int(cand))Hz accepted after retry")
                    break
                }
            }
        }
        check(initStatus, "AudioUnitInitialize")

        refRate = refFmtRate
        refRing = RefRing(capacity: Int(refFmtRate * kRefRingSeconds))
        // Announce BEFORE FORMAT so a writer knows the stdin rate up front.
        elog("REF_FORMAT sr=\(Int(refFmtRate)) ch=1")
        startStdinReader()

        check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
        elog("vpio capturing (AEC \(bypassAEC ? "OFF (bypass)" : "on"), \(Int(clientFormat.mSampleRate))Hz mono, ref \(Int(refFmtRate))Hz via stdin)")
    }

    // Reads little-endian Int16 mono PCM from STDIN into the reference ring.
    // Blocks (with the ring as backpressure) so a writer is paced to real time.
    // EOF just ends the feed — the render callback falls back to silence.
    func startStdinReader() {
        Thread.detachNewThread { [self] in
            guard let ring = refRing else { return }
            let chunkBytes = 8192
            let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 2)
            defer { buf.deallocate() }
            var pending = 0  // carried odd byte (Int16 alignment across reads)
            while true {
                let n = read(0, buf.advanced(by: pending), chunkBytes - pending)
                if n == 0 { elog("ref: stdin EOF — reference feed closed"); return }
                if n < 0 {
                    if errno == EINTR { continue }
                    elog("ref: stdin read error errno=\(errno)"); return
                }
                let total = pending + n
                let samples = total / 2
                let p = buf.assumingMemoryBound(to: Int16.self)
                var off = 0
                while off < samples {
                    let wrote = ring.write(UnsafeBufferPointer(start: p + off, count: samples - off))
                    off += wrote
                    if wrote == 0 { usleep(5000) }  // ring full — wait for playback
                }
                if total % 2 == 1 {
                    let last = buf.load(fromByteOffset: total - 1, as: UInt8.self)
                    buf.storeBytes(of: last, as: UInt8.self)
                    pending = 1
                } else {
                    pending = 0
                }
            }
        }
    }

    // Bus-0 render: supply the far-end reference. VPIO plays these samples out
    // the speaker AND uses them as the AEC reference. Empty ring → silence.
    func supplyReference(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        var supplied = 0
        for b in buffers {
            guard let data = b.mData else { continue }
            let want = Int(b.mDataByteSize) / 2
            let dst = data.assumingMemoryBound(to: Int16.self)
            let got = refRing?.read(into: dst, max: want) ?? 0
            if got < want {
                memset(dst + got, 0, (want - got) * 2)
            }
            supplied += got
        }
        if supplied == 0 {
            ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        }
        return noErr
    }

    // Called from the render thread. Pull cleaned mic frames from bus 1.
    func render(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32,
                numberFrames: UInt32) -> OSStatus {
        guard let unit = self.unit else { return noErr }

        let bytesNeeded = Int(numberFrames) * Int(clientFormat.mBytesPerFrame)
        if renderBufferData.count < bytesNeeded {
            renderBufferData = Data(count: bytesNeeded)
        }

        return renderBufferData.withUnsafeMutableBytes { raw -> OSStatus in
            var abl = AudioBufferList()
            abl.mNumberBuffers = 1
            abl.mBuffers.mNumberChannels = kChannels
            abl.mBuffers.mDataByteSize = UInt32(bytesNeeded)
            abl.mBuffers.mData = raw.baseAddress

            let status = AudioUnitRender(unit, ioActionFlags, timeStamp,
                                         1 /* input bus */, numberFrames, &abl)
            if status != noErr {
                // Under-run / transient; skip this cycle without crashing.
                return status
            }

            if !announced {
                elog("FORMAT sr=\(Int(clientFormat.mSampleRate)) ch=\(kChannels)")
                announced = true
            }

            // Write exactly the produced bytes (mDataByteSize may shrink).
            let produced = Int(abl.mBuffers.mDataByteSize)
            if produced > 0, let base = abl.mBuffers.mData {
                out.write(Data(bytes: base, count: produced))
            }
            return noErr
        }
    }

    func check(_ status: OSStatus, _ what: String) {
        if status != noErr { die("\(what) failed: OSStatus \(status)") }
    }
}

// C-compatible render callback trampoline.
private func vpioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let me = Unmanaged<VPIOCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return me.render(ioActionFlags: ioActionFlags,
                     timeStamp: inTimeStamp,
                     busNumber: inBusNumber,
                     numberFrames: inNumberFrames)
}

// C-compatible render callback trampoline for the bus-0 far-end reference.
private func vpioRefRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData = ioData else { return noErr }
    let me = Unmanaged<VPIOCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return me.supplyReference(ioActionFlags: ioActionFlags, ioData: ioData)
}

// AVCaptureDevice mic authorization must be granted to the *parent* process
// (Terminal / the packaged .app). We request it so a first run prompts.
func ensureMicPermission(_ done: @escaping () -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        done()
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted { done() } else { die("microphone permission denied") }
        }
    default:
        die("microphone permission not authorized (grant it in System Settings › Privacy › Microphone)")
    }
}

let capture = VPIOCapture()

// SIGUSR1 = barge-in: stop talking NOW. Handled on a dispatch source (not a raw
// signal handler) so taking the ring lock is safe.
signal(SIGUSR1, SIG_IGN)
let flushSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
flushSource.setEventHandler {
    let n = capture.refRing?.clear() ?? 0
    elog("FLUSHED \(n)")
}
flushSource.resume()
var arbiter: MicArbiter? = nil   // top-level so it outlives the closure

// --- mic handoff (see mic_arbiter.swift) -----------------------------------
// VPIO crushes every other reader of this mic by ~40 dB. So: if anyone else is
// already running input on it, don't open VPIO at all; and if anyone starts
// while we hold it, step out immediately (exit code kYieldExit). Opt-in with
// LARMOR_MIC_ARBITER=1.
let arbiterOn = ProcessInfo.processInfo.environment["LARMOR_MIC_ARBITER"] == "1"
let micDevice = defaultInputDeviceID()
if arbiterOn {
    let foreign = foreignInputUsers(on: micDevice)
    if !foreign.isEmpty {
        elog("YIELD-AT-START: \(foreign) already running input on device \(micDevice) — not opening VPIO")
        exit(kYieldExit)
    }
}

ensureMicPermission {
    capture.start()
    if arbiterOn {
        arbiter = MicArbiter(device: micDevice) { foreign in
            guard !foreign.isEmpty else { return }
            elog("YIELD: \(foreign) started input on device \(micDevice) — releasing VPIO")
            // Process exit tears the AudioUnit down and the device leaves
            // voice-processing mode within milliseconds; the other app's
            // signal recovers as soon as we're gone.
            exit(kYieldExit)
        }
        arbiter?.start()
        elog("arbiter: watching device \(micDevice) for other input users")
    }
}
RunLoop.main.run()
