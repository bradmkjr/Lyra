import AudioToolbox
import Foundation

/// Compresses 352-frame packets of 16-bit stereo PCM to Apple Lossless with macOS's own
/// encoder. The macOS AirPlay receiver only accepts ALAC from AirPlay 1 senders, and real
/// encoder output avoids any doubt about hand-built frames.
final class ALACEncoder {
    enum EncoderError: Error { case create(OSStatus), encode(OSStatus) }

    private var converter: AudioConverterRef?
    /// The packet being encoded, in memory that stays put while the converter reads it.
    fileprivate let input = UnsafeMutableBufferPointer<Int16>.allocate(capacity: RAOPFormat.framesPerPacket * 2)
    fileprivate var inputCount = 0
    fileprivate var inputConsumed = false
    /// What the input callback returns once the packet is used up.
    fileprivate static let noMoreInput: OSStatus = 1
    private var output = [UInt8](repeating: 0, count: 4096)

    init() throws {
        var source = AudioStreamBasicDescription(
            mSampleRate: Double(RAOPFormat.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var destination = AudioStreamBasicDescription(
            mSampleRate: Double(RAOPFormat.sampleRate), mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(RAOPFormat.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let status = AudioConverterNew(&source, &destination, &converter)
        guard status == noErr else { throw EncoderError.create(status) }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        input.deallocate()
    }

    /// One packet: exactly 352 interleaved stereo frames in, one ALAC frame out.
    func encode(_ samples: ArraySlice<Int16>) throws -> Data {
        guard let converter else { return Data() }
        inputCount = min(samples.count, input.count)
        _ = input.initialize(from: samples.prefix(inputCount))
        inputConsumed = false
        return try output.withUnsafeMutableBytes { buffer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(buffer.count), mData: buffer.baseAddress))
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = AudioConverterFillComplexBuffer(
                converter, alacInputProc, Unmanaged.passUnretained(self).toOpaque(),
                &packets, &list, &description)
            guard status == noErr || status == Self.noMoreInput, packets == 1 else {
                throw EncoderError.encode(status)
            }
            return Data(bytes: buffer.baseAddress!, count: Int(list.mBuffers.mDataByteSize))
        }
    }
}

/// Hands the converter the current packet once, then reports no more data.
private func alacInputProc(
    _ converter: AudioConverterRef, _ packetCount: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let encoder = Unmanaged<ALACEncoder>.fromOpaque(userData!).takeUnretainedValue()
    guard !encoder.inputConsumed else {
        packetCount.pointee = 0
        return ALACEncoder.noMoreInput
    }
    encoder.inputConsumed = true
    packetCount.pointee = UInt32(encoder.inputCount / 2)
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mNumberChannels = 2
    data.pointee.mBuffers.mDataByteSize = UInt32(encoder.inputCount * MemoryLayout<Int16>.size)
    data.pointee.mBuffers.mData = UnsafeMutableRawPointer(encoder.input.baseAddress)
    return noErr
}
