//
//  Format.swift
//  AVPlayerOniOS14.5Beta
//
//  Created by chuchu xu on 2021/4/29.
//

import AVFoundation
import Foundation
@objc protocol AudioStreamRecorderRawLPCMAudioBufferConverter: class {
  var inputAudioFormat: AudioStreamBasicDescription { get }
  var outputAudioFormat: AudioStreamBasicDescription { get }

  func startConverter() throws
  func handleRawLPCMAudioBufferData(buffer: UnsafeMutableRawPointer, bufferSize: UInt32, packetCount: UInt32) throws -> ConverterOutputData
  func stopConverter() throws

  @objc optional func writeConverterCookie(audioFileID: AudioFileID) -> OSStatus
  @objc optional func writePacketTableInfo(audioFileID: AudioFileID) -> OSStatus
}

public enum AudioStreamRecorderAudioBufferConverter {
  case toALAC(inputAudioFormat: AudioStreamBasicDescription)

  public static func defaultALAC() -> AudioStreamRecorderAudioBufferConverter {
    return .toALAC(inputAudioFormat: RecorderQueue.Settings().audioFormat)
  }

  var audioFileTypeID: AudioFileTypeID {
    switch self {
    case .toALAC:
      return kAudioFileM4AType
    }
  }

  var converter: AudioStreamRecorderRawLPCMAudioBufferConverter? {
    switch self {
    case .toALAC(let inputAudioFormat):
      return AudioStreamRecorderRawLPCMAudioBufferToALACConverter(inputAudioFormat: inputAudioFormat)
    }
  }
}

public protocol AudioStreamRecorderWriter: AudioStreamRecorderProcessor {
  init(localPath: String, converter: AudioStreamRecorderAudioBufferConverter)
}

public final class AudioStreamRecorderSystemAudioConverterWriter: AudioStreamRecorderWriter {
  public var isInvalid: Bool {
    return finished || cancelled
  }

  private let serial = DispatchQueue(label: "AudioStreamRecorderSystemAudioConverterWriter")

  private var localPath: String?
  private var error: UltronError?
  private var duration: TimeInterval?

  private var audioFileType: AudioFileTypeID?
  private var converter: AudioStreamRecorderRawLPCMAudioBufferConverter?
  private var recordPacket: Int64?

  private var recordFile: AudioFileID?

  private var cancelled: Bool = false
  private var finished: Bool = false
  private var hasBuffer: Bool = false

  public init(localPath: String, converter: AudioStreamRecorderAudioBufferConverter) {
    serial.async { [weak self] in
      guard let self = self else { return }

      self.localPath = localPath
      self.audioFileType = converter.audioFileTypeID
      self.converter = converter.converter
      self.recordPacket = 0
    }
  }

  deinit {
//    Logger.debug("AudioStreamRecorderSystemAudioConverterWriter deinit")
  }

  public func cancel() {
    if !finished, !cancelled {
      cancelled = true
    }
  }

  public func begin() {
    serial.async { [weak self] in
      guard let self = self, let converter = self.converter, let localPath = self.localPath, let audioFileType = self.audioFileType, !self.cancelled, !self.finished else { return }

      self.hasBuffer = false
      do {
        try converter.startConverter()
      } catch {
        self.handleError(description: "Failed to start system audio converter: \(error)")
      }

      var error = noErr
      var audioFormat = converter.outputAudioFormat
      error = AudioFileCreateWithURL(URL(fileURLWithPath: localPath) as CFURL, audioFileType, &audioFormat, .eraseFile, &self.recordFile)
      guard let recordFile = self.recordFile, error == noErr else {
        self.handleError(status: error, operation: "AudioFileCreateWithURL")
        return
      }
      error = converter.writeConverterCookie?(audioFileID: recordFile) ?? noErr
      if error != noErr {
        self.handleError(status: error, operation: "writeConverterCookie")
      }
    }
  }

  public func process(buffer data: RecorderProcessorData) {
    serial.async { [weak self] in
      guard let self = self else { return }
      self.hasBuffer = true
      self._process(buffer: data)
    }
  }

  public func end(error: Error?) {
    serial.async { [weak self] in
      guard let self = self, let recordFile = self.recordFile, let converter = self.converter, let localPath = self.localPath, !self.cancelled, !self.finished else { return }

      if !self.hasBuffer {
        // write single empty frame after audio converter begins to avoid generating invalid audio file
        self.writeEmptySingleFrame()
      }

      var err = noErr
      err = converter.writePacketTableInfo?(audioFileID: recordFile) ?? noErr
      if err != noErr {
        self.handleError(status: err, operation: "writePacketTableInfo")
      }
      err = converter.writeConverterCookie?(audioFileID: recordFile) ?? noErr
      if err != noErr {
        self.handleError(status: err, operation: "writeConverterCookie")
      }

      do {
        try converter.stopConverter()
      } catch {
        self.handleError(description: "Failed to stop system audio converter: \(error)")
      }

      err = AudioFileClose(recordFile)
      if err != noErr {
        self.handleError(status: err, operation: "AudioFileClose")
      }

      let asset = AVAsset(url: URL(fileURLWithPath: localPath))
      var duration = CMTimeGetSeconds(asset.duration)
      if duration.isNaN {
        duration = 0.0
      }
      self.duration = duration
      self.finished = true

      if let error = error {
        self.error = UltronError(category: .streamRecorder, message: "Audio converter ended on external error: \(error)")
      }
    }
  }

  private func _process(buffer data: RecorderProcessorData) {
    guard let converter = self.converter,
      let recordFile = self.recordFile,
      let recordPacket = self.recordPacket,
      data.audioPacketCount > 0,
      !cancelled, !finished else { return }

    let bytes = data.copyAudioBytes
    let output = try? converter.handleRawLPCMAudioBufferData(buffer: bytes.0, bufferSize: bytes.1, packetCount: data.audioPacketCount)
    bytes.0.deallocate()
    if let output = output {
      var error = noErr
      var packets: UInt32 = output.ioNumPackets ?? 0
      error = AudioFileWritePackets(recordFile, false, output.outputBufferSize, output.packetDescriptions, recordPacket, &packets, output.outputBuffer)
      if error != noErr {
        handleError(status: error, operation: "AudioFileWritePackets")
      } else {
        self.recordPacket = recordPacket + Int64(packets)
      }
    }
  }

  private func writeEmptySingleFrame() {
    guard let inputFormat = converter?.inputAudioFormat else { return }
    let byteCount = inputFormat.mBytesPerPacket
    let frameCount = inputFormat.mFramesPerPacket
    let packageDescription = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: frameCount, mDataByteSize: byteCount)
    let audioData = RecorderProcessorData(recordData: Data(repeating: 0, count: numericCast(byteCount)), audioFormat: packageDescription, audioPacketCount: 1)
    _process(buffer: audioData)
  }

  private func handleError(status: OSStatus, operation: String) {
    handleError(description: "\(operation) failed: OSStatus \(status)")
  }

  private func handleError(description: String) {
    if error == nil {
      error = UltronError(category: .streamRecorder, message: description)
    }
  }
}

public extension AudioStreamRecorderAudioBufferConverter {
  static func alac() -> AudioStreamRecorderAudioBufferConverter {
    return .toALAC(inputAudioFormat: RecorderQueue.Settings().audioFormat)
  }
}
