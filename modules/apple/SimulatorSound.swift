#if os(macOS)
import AVFoundation
import CoreAudio

// @ref LLP 0001#simulator-sound
enum SimulatorDevices {
    struct Device: Equatable { var name: String; var udid: String }
    enum Match: Equatable { case device(String), none, ambiguous([String]) }
    struct Heard { var start: Double; var seconds: Double; var problem: String? }

    static let file = "\(Sounds.folder)/simulator.m4a"

    static func booted(json: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { d in
            guard d["state"] as? String == "Booted", let name = d["name"] as? String, let udid = d["udid"] as? String else { return nil }
            return Device(name: name, udid: udid)
        }
    }

    static func match(title: String, in booted: [Device]) -> Match {
        let name = title.components(separatedBy: " – ").first ?? title
        let found = booted.filter { $0.name == name }.map(\.udid).sorted()
        if found.count > 1 { return .ambiguous(found) }
        return found.first.map(Match.device) ?? .none
    }

    static func processes(of udid: String, listing: String) -> Set<pid_t> {
        var parent: [pid_t: pid_t] = [:]
        var roots: Set<pid_t> = []
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            parent[pid] = ppid
            let command = parts[2]
            if command.split(separator: " ").first?.hasSuffix("launchd_sim") == true, command.contains("/Devices/\(udid)/") { roots.insert(pid) }
        }
        var found = roots
        var grew = true
        while grew {
            grew = false
            for (pid, ppid) in parent where !found.contains(pid) && found.contains(ppid) {
                found.insert(pid)
                grew = true
            }
        }
        return found
    }

    static func gap(start: Double, written: Int64, rate: Double, at now: Double) -> Int64 {
        let late = now - start - Double(written) / rate
        return late > 0.02 ? Int64((late * rate).rounded()) : 0
    }

    static func offset(fileStart: Double, firstFrame: Double) -> Double {
        ((firstFrame - fileStart) * 1000).rounded() / 1000
    }

    static func run(_ path: String, _ arguments: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : Data()
    }

    static func listing() -> String {
        String(decoding: run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="]), as: UTF8.self)
    }

    static func tap(title: String, into folder: URL) -> (tap: AnyObject?, note: String?) {
        let without = "so this recording has the Simulator app's own sound, which holds none of the simulated apps'"
        guard #available(macOS 14.2, *) else { return (nil, "Recording a simulated device's sound needs macOS 14.2 or later, \(without).") }
        switch match(title: title, in: booted(json: run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"]))) {
        case .none:
            return (nil, "No booted simulated device is named \"\(title)\" (xcrun simctl list devices booted), \(without).")
        case let .ambiguous(udids):
            return (nil, "\(udids.count) booted simulated devices are named \"\(title)\" (\(udids.joined(separator: ", "))), \(without). Give each a different name to record its sound.")
        case let .device(udid):
            do {
                let sound = try SimulatorSound(udid: udid, url: folder.appendingPathComponent(file))
                return (sound, "The simulated device's own sound (\(udid)), in \(file), is the recorded sound.")
            } catch {
                return (nil, "The simulated device's sound could not be recorded (\(error)), \(without).")
            }
        }
    }
}

@available(macOS 14.2, *)
final class SimulatorSound {
    let udid: String
    let url: URL
    private let description: CATapDescription
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var stopped = false
    private let io = DispatchQueue(label: "exact-studio.simulator-sound")
    private let watch = DispatchQueue(label: "exact-studio.simulator-sound.watch")
    private var listener: AudioObjectPropertyListenerBlock?
    private var tapped: [AudioObjectID] = []
    private var start: Double?
    private var frames: AVAudioFramePosition = 0
    private var problem: String?

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw ExactStudioError("\(what) failed, CoreAudio error \(status)") }
    }

    init(udid: String, url: URL) throws {
        self.udid = udid
        self.url = url
        let now = Self.objects(of: SimulatorDevices.processes(of: udid, listing: SimulatorDevices.listing()))
        description = CATapDescription(stereoMixdownOfProcesses: now)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Exact Studio"
        tapped = now
        do {
            try Self.check(AudioHardwareCreateProcessTap(description, &tap), "Creating the process tap")
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var formatAddress = Self.address(kAudioTapPropertyFormat)
            try Self.check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &asbd), "Reading the tap's format")
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw ExactStudioError("The tap's sound format is not readable") }
            self.format = format
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Exact Studio Simulator Sound", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Creating the tap's device")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitDepthHintKey: 24,
            ], commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, io) { [weak self] _, input, time, _, _ in
                self?.write(input, at: time.pointee)
            }, "Reading the tap")
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.follow() }
            var list = Self.address(kAudioHardwarePropertyProcessObjectList)
            try Self.check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, watch, listener), "Watching for new processes")
            self.listener = listener
            try Self.check(AudioDeviceStart(device, proc), "Starting the tap")
        } catch {
            _ = stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit { if !stopped { _ = stop() } }

    private func write(_ input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) {
        guard let file, problem == nil, time.mFlags.contains(.hostTimeValid),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil), buffer.frameLength > 0 else { return }
        let now = Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9
        let start = self.start ?? now
        self.start = start
        do {
            var missing = SimulatorDevices.gap(start: start, written: frames, rate: format.sampleRate, at: now)
            while missing > 0 {
                let chunk = AVAudioFrameCount(min(missing, AVAudioFramePosition(format.sampleRate)))
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                silence.frameLength = chunk
                for b in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
                try file.write(from: silence)
                frames += AVAudioFramePosition(chunk)
                missing -= AVAudioFramePosition(chunk)
            }
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            problem = "Writing \(url.lastPathComponent) failed: \(error.localizedDescription)"
        }
    }

    private static func objects(of pids: Set<pid_t>) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = address(kAudioProcessPropertyPID)
            return AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr && pids.contains(pid)
        }.sorted()
    }

    private func follow() {
        guard tap != kAudioObjectUnknown else { return }
        let now = Self.objects(of: SimulatorDevices.processes(of: udid, listing: SimulatorDevices.listing()))
        guard now != tapped else { return }
        tapped = now
        description.processes = now
        var address = Self.address(kAudioTapPropertyDescription)
        var d = description
        let status = withUnsafePointer(to: &d) { AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0) }
        if status != noErr { NSLog("exact-studio: the simulated device's new processes could not be tapped: \(status)") }
    }

    func stop() -> SimulatorDevices.Heard? {
        guard !stopped else { return nil }
        stopped = true
        if let listener {
            var list = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, watch, listener)
            self.listener = nil
        }
        watch.sync {}
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
            self.proc = nil
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
        return io.sync {
            defer { file = nil }
            guard file != nil, let start else { return nil }
            return SimulatorDevices.Heard(start: start, seconds: Double(frames) / format.sampleRate, problem: problem)
        }
    }
}
#endif
