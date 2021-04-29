//
//  AlacConvert.swift
//  UltronDemoSpace
//
//  Created by chuchu xu on 2021/4/29.
//

import AudioToolbox
import Foundation

class AudioStreamRecorderRawLPCMAudioBufferToALACConverter:AudioStreamRecorderRawLPCMAudioBufferConverter {
  var inputAudioFormat: AudioStreamBasicDescription {
    return settings.inputAudioFormat
  }

  var outputAudioFormat: AudioStreamBasicDescription {
    return settings.outputAudioFormat
  }

  fileprivate class Settings {
    var outputBufferSize: UInt32 = 32 * 1024 // 32 KB is a good starting point
    var outputBuffer: UnsafeMutablePointer<UInt8>?

    var inputAudioFormat: AudioStreamBasicDescription
    var outputAudioFormat: AudioStreamBasicDescription

    var packetsPerBufferSize: UInt32 = 0
    var packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?

    var sourceBuffer: UnsafeMutableRawPointer?
    var sourceBufferSize: UInt32?
    var sourceBufferPackets: UInt32?

    var currentBufferIsUsed = false

    init(inputAudioFormat: AudioStreamBasicDescription) {
      self.inputAudioFormat = inputAudioFormat

      var audioFormat = AudioStreamBasicDescription()
      audioFormat.mSampleRate = 16000.0
      audioFormat.mFormatID = kAudioFormatAppleLossless
      audioFormat.mChannelsPerFrame = 1
      audioFormat.mFramesPerPacket = 4096
      audioFormat.mBytesPerPacket = 0
      audioFormat.mBitsPerChannel = 0
      audioFormat.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData

      outputAudioFormat = audioFormat
    }
  }

  fileprivate var settings: Settings
  fileprivate var audioConverter: AudioConverterRef?
  fileprivate var error: OSStatus = noErr

  fileprivate var inputDataProc: AudioConverterComplexInputDataProc = { (
    _: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
  ) in
  guard let settings = inUserData?.assumingMemoryBound(to: Settings.self).pointee, settings.sourceBuffer != nil, settings.sourceBufferSize != nil else {
    return noErr // example
  }

  let dataPackets = settings.outputBufferSize / settings.inputAudioFormat.mBytesPerPacket
  if ioNumberDataPackets.pointee > dataPackets {
    ioNumberDataPackets.pointee = dataPackets
  }

  ioData.pointee.mBuffers.mData = settings.sourceBuffer!

  if settings.currentBufferIsUsed {
    ioData.pointee.mBuffers.mDataByteSize = 0
    ioNumberDataPackets.pointee = 0
  } else {
    ioData.pointee.mBuffers.mDataByteSize = settings.sourceBufferSize!
    ioNumberDataPackets.pointee = settings.sourceBufferPackets!
  }

  ioData.pointee.mBuffers.mNumberChannels = settings.inputAudioFormat.mChannelsPerFrame

  settings.currentBufferIsUsed = true

  outDataPacketDescription?.pointee = nil

  return noErr
  }

  init?(inputAudioFormat: AudioStreamBasicDescription) {
    if inputAudioFormat.mFormatID != kAudioFormatLinearPCM {
      return nil
    }

    settings = Settings(inputAudioFormat: inputAudioFormat)
  }

  func startConverter() throws {
    let error = AudioConverterNew(&settings.inputAudioFormat, &settings.outputAudioFormat, &audioConverter)
//    if error != noErr {
//      self.error = error
//      throw getError(code: Int(error), description: "AudioConverterNew")
//    }

    settings.packetsPerBufferSize = try getConverterPacketsPerBuffer()
    settings.outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(settings.outputBufferSize))
    settings.packetDescriptions = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: MemoryLayout<AudioStreamPacketDescription>.size * Int(settings.packetsPerBufferSize))
  }

  func writeConverterCookie(audioFileID: AudioFileID) -> OSStatus {
    var error = noErr

    var cookieSize: UInt32 = 0
    error = AudioConverterGetPropertyInfo(audioConverter!, kAudioConverterCompressionMagicCookie, &cookieSize, nil)
    if error != noErr {
      self.error = error
      return error
    }

    let cookie = UnsafeMutablePointer<UInt32>.allocate(capacity: Int(cookieSize))
    error = AudioConverterGetProperty(audioConverter!, kAudioConverterCompressionMagicCookie, &cookieSize, cookie)
    if error != noErr {
      self.error = error
      return error
    }

    error = AudioFileSetProperty(audioFileID, kAudioFilePropertyMagicCookieData, cookieSize, cookie)
    if error != noErr {
      self.error = error
      return error
    }

    cookie.deallocate()
    return noErr
  }

  func writePacketTableInfo(audioFileID: AudioFileID) -> OSStatus {
    var error = noErr
    
    var dataSize: UInt32 = 0
    var isWritable: UInt32 = 0
    
    error = AudioFileGetPropertyInfo(audioFileID, kAudioFilePropertyPacketTableInfo, &dataSize, &isWritable)
    if error != noErr {
      self.error = error
      return error
    }
    
    if isWritable > 0 {
      var primeInfo: AudioConverterPrimeInfo?
      var primeInfoSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
      error = AudioConverterGetProperty(audioConverter!, kAudioConverterPrimeInfo, &primeInfoSize, &primeInfo)
      if error != noErr {
        self.error = error
        return error
      }
      
      var packetTableInfo: AudioFilePacketTableInfo?
      var packetTableInfoSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
      error = AudioFileGetProperty(audioFileID, kAudioFilePropertyPacketTableInfo, &packetTableInfoSize, &packetTableInfo)
      if error != noErr {
        self.error = error
        return error
      }
      
      if packetTableInfo != nil, primeInfo != nil {
        packetTableInfo!.mPrimingFrames = Int32(primeInfo!.leadingFrames)
        packetTableInfo!.mRemainderFrames = Int32(primeInfo!.trailingFrames)
        error = AudioFileSetProperty(audioFileID, kAudioFilePropertyPacketTableInfo, packetTableInfoSize, &packetTableInfo)
        if error != noErr {
          self.error = error
          return error
        }
      }
    }
    return noErr
  }

  func handleRawLPCMAudioBufferData(buffer: UnsafeMutableRawPointer, bufferSize: UInt32, packetCount: UInt32) throws -> ConverterOutputData {
    settings.sourceBuffer = buffer
    settings.sourceBufferSize = bufferSize
    settings.sourceBufferPackets = packetCount

    var error = noErr

    var convertedData = AudioBufferList()
    convertedData.mNumberBuffers = 1
    convertedData.mBuffers.mNumberChannels = settings.inputAudioFormat.mChannelsPerFrame
    convertedData.mBuffers.mDataByteSize = settings.outputBufferSize
    convertedData.mBuffers.mData = UnsafeMutableRawPointer(settings.outputBuffer)

    settings.currentBufferIsUsed = false

    error = AudioConverterReset(audioConverter!)
//    if error != noErr {
//      throw getError(code: Int(error), description: "AudioConverterReset")
//    }
    var ioOutputDataPackets = settings.packetsPerBufferSize
    error = AudioConverterFillComplexBuffer(audioConverter!, inputDataProc, &settings, &ioOutputDataPackets, &convertedData, settings.packetDescriptions)

//    if error != noErr {
//      throw getError(code: Int(error), description: "AudioConverterFillComplexBuffer")
//    }

    let output = ConverterOutputData(outputBuffer: settings.outputBuffer!, outputBufferSize: convertedData.mBuffers.mDataByteSize)
    output.ioNumPackets = ioOutputDataPackets
    output.packetDescriptions = settings.packetDescriptions

    self.error = error

    return output
  }

  func stopConverter() throws {
    defer {
      if self.error == noErr {
        if settings.outputBuffer != nil {
          settings.outputBuffer?.deallocate()
        }
        if settings.packetDescriptions != nil {
          settings.packetDescriptions?.deallocate()
        }
      }
    }
    var error = noErr

    error = AudioConverterDispose(audioConverter!)
//    if error != noErr {
//      throw getError(code: Int(error), description: "AudioConverterDispose")
//    }
    self.error = error
  }

  fileprivate func getConverterPacketsPerBuffer() throws -> UInt32 {
    var sizePerPacket: UInt32 = settings.inputAudioFormat.mBytesPerPacket
    var size = UInt32(MemoryLayout.size(ofValue: sizePerPacket))

    let error = AudioConverterGetProperty(audioConverter!, kAudioConverterPropertyMaximumOutputPacketSize, &size, &sizePerPacket)
//    if error != noErr {
//      throw getError(code: Int(error), description: "AudioConverterGetProperty")
//    }
    self.error = error
    return settings.outputBufferSize / sizePerPacket
  }
}

class ConverterOutputData: NSObject {
  var outputBuffer: UnsafeMutableRawPointer
  var outputBufferSize: UInt32
  var ioNumPackets: UInt32?
  var packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?

  init(outputBuffer: UnsafeMutableRawPointer, outputBufferSize: UInt32) {
    self.outputBuffer = outputBuffer
    self.outputBufferSize = outputBufferSize
  }
}
