//
//  OwlWAVPacker.swift
//  Owltype — Voice Input Subsystem
//

import Foundation

enum OwlWAVPacker {
  /// Packages raw 16kHz, 16-bit mono PCM bytes into a 44-byte standard RIFF WAVE file in memory.
  static func pack16kMono(pcmData: Data) -> Data {
    let alignedCount = pcmData.count - (pcmData.count % 2)
    let sanitizedData = pcmData.prefix(alignedCount)

    var header = Data(capacity: 44)
    let sampleRate: UInt32 = 16000
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8 // 32,000
    let blockAlign: UInt16 = channels * bitsPerSample / 8                           // 2
    let subchunk2Size = UInt32(sanitizedData.count)
    let chunkSize = UInt32(36 + sanitizedData.count)

    // 0x00: "RIFF"
    header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
    // 0x04: ChunkSize (36 + data size)
    var cs = chunkSize.littleEndian
    header.append(Data(bytes: &cs, count: 4))
    // 0x08: "WAVE"
    header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
    // 0x0C: "fmt "
    header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
    // 0x10: Subchunk1Size = 16
    var s1s = UInt32(16).littleEndian
    header.append(Data(bytes: &s1s, count: 4))
    // 0x14: AudioFormat = 1 (PCM)
    var af = UInt16(1).littleEndian
    header.append(Data(bytes: &af, count: 2))
    // 0x16: NumChannels = 1
    var ch = channels.littleEndian
    header.append(Data(bytes: &ch, count: 2))
    // 0x18: SampleRate = 16000
    var sr = sampleRate.littleEndian
    header.append(Data(bytes: &sr, count: 4))
    // 0x1C: ByteRate = 32000
    var br = byteRate.littleEndian
    header.append(Data(bytes: &br, count: 4))
    // 0x20: BlockAlign = 2
    var ba = blockAlign.littleEndian
    header.append(Data(bytes: &ba, count: 2))
    // 0x22: BitsPerSample = 16
    var bps = bitsPerSample.littleEndian
    header.append(Data(bytes: &bps, count: 2))
    // 0x24: "data"
    header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
    // 0x28: Subchunk2Size = PCM count
    var s2s = subchunk2Size.littleEndian
    header.append(Data(bytes: &s2s, count: 4))

    var result = header
    result.append(sanitizedData)
    return result
  }
}
