// Sounds added over the video: music and effects from audio files kept in the recording's
// `sounds/` folder. Composition.make plays them; this is their files and their waveforms,
// which the timeline draws for them and for the recorded sound.
// @ref LLP 0002#sound — an added sound plays straight through; only the recorded sound follows the cuts
#if os(macOS)
import AppKit
import AVFoundation

enum Sounds {
    static let types = ["m4a", "mp3", "wav", "aiff", "aif", "aac", "caf"]
    /// The folder inside a recording that holds its sound files.
    static let folder = "sounds"
    typealias Refused = FileRefused

    private static var lengths: [String: (Date, Double)] = [:]
    private static let lock = NSLock()

    /// How many seconds of sound a file in the recording holds; nil when it is not readable sound.
    static func length(_ file: String?, in folder: URL?) -> Double? {
        guard let file, !file.isEmpty, let folder else { return nil }
        let url = folder.appendingPathComponent(file)
        guard let changed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        lock.lock()
        if let hit = lengths[url.path], hit.0 == changed { lock.unlock(); return hit.1 }
        lock.unlock()
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        let seconds = track.timeRange.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        lock.lock(); lengths[url.path] = (changed, seconds); lock.unlock()
        return seconds
    }

    /// A sound file the person picks in a panel; not while an agent drives the app.
    static func pick(prompt: String = "Add", then: @escaping (URL) -> Void) {
        guard Pictures.mayAsk else { return }
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedFileTypes = types
            panel.prompt = prompt
            panel.message = "Choose music or another sound to play over the video."
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            then(url)
        }
    }

    /// Copy a sound file into a recording's sounds folder and give its path inside the recording.
    static func bring(_ url: URL, into recording: URL) throws -> String {
        guard types.contains(url.pathExtension.lowercased()) else {
            throw Refused(why: "Exact Studio can’t play that file. Use an M4A, MP3, WAV, AIFF, AAC or CAF sound file.")
        }
        let file = try RecordingFiles.bring(url, into: recording, folder: folder, what: "sound")
        guard length(file, in: recording) != nil else { throw Refused(why: "Couldn’t read the sound in that file.") }
        return file
    }

    /// A new sound for a file already in the recording, from `start` (recording time): the whole file,
    /// or what fits before the video ends. A long one fades out at its end.
    static func make(id: String, file: String, in recording: URL, start: Double, map: TimeMap) -> Sound? {
        guard let whole = length(file, in: recording) else { return nil }
        let length = min(whole, map.outputDuration - map.output(start))
        guard length >= 0.1 else { return nil }
        return Sound(id: id, file: file, start: start, length: (length * 1000).rounded(.down) / 1000, fadeOut: length > 2 ? 0.5 : 0)
    }
}

/// A sound's loudness over time, for drawing: the loudest sample in each hundredth of a second, 0–1
/// of the file's loudest. Read once per file (and again when it changes), away from the main thread.
final class Waveform {
    static let perSecond = 100.0
    let peaks: [Float]
    init(_ peaks: [Float]) { self.peaks = peaks }

    /// The loudest peak from `a` to `b` seconds of the file.
    func level(_ a: Double, _ b: Double) -> Float {
        let i = max(0, Int(a * Self.perSecond)), j = min(peaks.count, max(i + 1, Int(b * Self.perSecond)))
        guard i < j else { return 0 }
        return peaks[i..<j].max() ?? 0
    }

    private static var cache: [String: (Date, Waveform)] = [:]
    private static var reading: Set<String> = []
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "exact-studio.waveform", qos: .utility)

    /// The waveform of a file's first sound track when it has been read; else nil, and `ready` is
    /// called on the main thread once it has.
    static func of(_ url: URL, ready: @escaping () -> Void) -> Waveform? {
        guard let changed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        let key = url.path
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key], hit.0 == changed { return hit.1 }
        guard !reading.contains(key) else { return nil }
        reading.insert(key)
        queue.async {
            let made = read(url) ?? Waveform([])
            lock.lock()
            cache[key] = (changed, made)
            reading.remove(key)
            lock.unlock()
            DispatchQueue.main.async(execute: ready)
        }
        return nil
    }

    private static func read(_ url: URL) -> Waveform? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var rate = 44_100.0
        if let desc = track.formatDescriptions.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc as! CMAudioFormatDescription) {
            rate = basic.pointee.mSampleRate
        }
        let bucket = max(1, Int(rate / perSecond))
        var peaks: [Float] = [], loudest: Int16 = 0, count = 0
        while let buffer = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            guard !samples.isEmpty, CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 2, destination: &samples) == noErr else { continue }
            for sample in samples {
                let v = sample == Int16.min ? Int16.max : abs(sample)
                if v > loudest { loudest = v }
                count += 1
                if count == bucket { peaks.append(Float(loudest)); loudest = 0; count = 0 }
            }
        }
        if count > 0 { peaks.append(Float(loudest)) }
        // Scaled to its loudest, but near-silence (below about -40 dB) stays flat.
        let top = max(peaks.max() ?? 0, 330)
        return Waveform(peaks.map { $0 / top })
    }
}
#endif
