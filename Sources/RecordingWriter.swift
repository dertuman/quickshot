import AVFoundation
import ScreenCaptureKit

/// Writes stream samples to an MP4 as they arrive: H.264 video plus one AAC track per audio source.
/// With both mic and computer audio, the tracks are mixed into one at the end. Only audio is
/// re-encoded there (video is copied), so saving takes seconds, not a fraction of the recording.
/// Use from one serial queue.
final class RecordingWriter {
    private let url: URL
    private let raw: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private var audio: [SCStreamOutputType: AVAssetWriterInput] = [:]
    private var started = false

    init(url: URL, size: CGSize, system: Bool, mic: Bool) throws {
        self.url = url
        raw = url.deletingPathExtension().appendingPathExtension("tracks.mov")
        writer = try AVAssetWriter(outputURL: (system && mic) ? raw : url, fileType: (system && mic) ? .mov : .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * 2),
                                              AVVideoExpectedSourceFrameRateKey: 60],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        for (on, type, channels) in [(system, SCStreamOutputType.audio, 2), (mic, .microphone, 1)] where on {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: channels))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audio[type] = input
        }
    }

    private static func aac(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
         AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 64000 * channels]
    }

    func append(_ buffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard buffer.isValid, writer.status != .failed else { return }
        if type == .screen {
            // ScreenCaptureKit also sends idle and blank frames; only complete ones carry pixels.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                started = writer.startWriting()
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            }
            if video.isReadyForMoreMediaData { video.append(buffer) }
        } else if started, let input = audio[type], input.isReadyForMoreMediaData {
            input.append(buffer)
        }
    }

    func finish(_ done: @escaping (Error?) -> Void) {
        guard started else { return done(writer.error ?? CocoaError(.fileWriteUnknown)) }
        video.markAsFinished()
        audio.values.forEach { $0.markAsFinished() }
        writer.finishWriting { [self] in
            guard writer.status == .completed else { return done(writer.error) }
            guard audio.count > 1 else { return done(nil) }
            Task {
                do { try await mix() } catch { done(error); return }
                try? FileManager.default.removeItem(at: raw)
                done(nil)
            }
        }
    }

    /// Copies the video and mixes every audio track into one, so any player hears both.
    private func mix() async throws {
        let asset = AVURLAsset(url: raw)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(videoOut)
        reader.add(audioOut)

        let out = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                         sourceFormatHint: try await track.load(.formatDescriptions).first)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 2))
        out.add(videoIn)
        out.add(audioIn)
        guard reader.startReading(), out.startWriting() else { throw reader.error ?? out.error ?? CocoaError(.fileWriteUnknown) }
        out.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (input, output, name) in [(videoIn, videoOut as AVAssetReaderOutput, "video"), (audioIn, audioOut, "audio")] {
                group.addTask {
                    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                        input.requestMediaDataWhenReady(on: DispatchQueue(label: "quickshot.mix.\(name)")) {
                            while input.isReadyForMoreMediaData {
                                guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                                    input.markAsFinished()
                                    finished.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        guard reader.status == .completed else { out.cancelWriting(); throw reader.error ?? CocoaError(.fileReadUnknown) }
        await out.finishWriting()
        guard out.status == .completed else { throw out.error ?? CocoaError(.fileWriteUnknown) }
    }
}
