//
//  Record.swift
//  AVPlayerOniOS14.5Beta
//
//  Created by chuchu xu on 2021/4/29.
//

import AudioToolbox
import Foundation

public protocol AudioStreamRecorderProcessor: AudioBufferProcessor {
  /// 表示当前 Processor 不再接收任何调用
  var isInvalid: Bool { get }

  /// 开始音频处理
  func begin()

  /// 结束音频处理
  func end(error: Error?)
}

/// 表征激活某个事物的激活者（比较抽象）
public struct Activator: Hashable {
  /// 表征激活者的 identifier
  public let identifier: String

  public init(identifier: String) {
    self.identifier = identifier
  }
}

/// 可被激活的某个事物
/// 目前由 CommonActivatable 满足，而 CommonActivatable 是 RecorderEngine 和 PlayerEngine 的父类
public protocol Activatable {
  func active(from activator: Activator) -> Bool
  func inactive(from activator: Activator)
}

final class ActivatorContainer {
  private(set) var container: Set<Activator> = []

  var isEmpty: Bool {
    return container.isEmpty
  }

  @discardableResult func insert(activator: Activator) -> Bool {
    return container.insert(activator).inserted
  }

  @discardableResult func remove(activator: Activator) -> Bool {
    return container.remove(activator) != nil
  }

  func removeAll() {
    container.removeAll()
  }
}

class AudioStreamRecorder {
  let engine: RecorderEngine
  private let processors: [AudioStreamRecorderProcessor]
  private let activator = Activator(identifier: "Ultron.StreamRecorder.\(UUID().uuidString)")

  init(engine: RecorderEngine, processors: [AudioStreamRecorderProcessor]) {
    self.engine = engine
    self.processors = processors
  }

  public convenience init(processors: [AudioStreamRecorderProcessor]) {
    self.init(engine: .shared, processors: processors)
  }

  public var isRecording: Bool {
    return engine.contains(activator: activator)
  }

  public func startRecorder() {
    guard !isRecording else { return }

    guard engine.active(from: activator) else {
      return
    }

    processors.filter { !$0.isInvalid }.forEach {
      $0.begin()
    }

    setUpBufferProcessor()
  }

  public func stop() {
    stop(with: nil)
  }

  private func stop(with error: UltronError?) {
    guard isRecording else { return }

    engine.inactive(from: activator)

    tearDownBufferProcessor()

    processors.filter { !$0.isInvalid }.forEach { $0.end(error: error) }
  }

  private var bufferProcessor: BufferProcessor? {
    didSet {
      oldValue.map(engine.detach)
      bufferProcessor.map(engine.attach)
    }
  }

  private func setUpBufferProcessor() {
    bufferProcessor = BufferProcessor { [weak self] buffer in
      guard let self = self else { return }
      self.processors.filter { !$0.isInvalid }.forEach { $0.process(buffer: buffer) }
    }
  }

  private func tearDownBufferProcessor() {
    bufferProcessor = nil
  }
}

extension AudioStreamRecorder {
  private final class BufferProcessor: AudioBufferProcessor {
    private let processingBlock: (RecorderProcessorData) -> Void
    init(_ processingBlock: @escaping (RecorderProcessorData) -> Void) {
      self.processingBlock = processingBlock
    }

    func process(buffer: RecorderProcessorData) {
      processingBlock(buffer)
    }
  }

  private final class LevelMeterProcessor: RecorderLevelMeterProcessor {
    private let processingBlock: (_ level: Double) -> Void
    init(_ processingBlock: @escaping (_ level: Double) -> Void) {
      self.processingBlock = processingBlock
    }

    func processLevelUpdate(_ level: Double) {
      processingBlock(level)
    }
  }
}

class RecorderEngine: CommonActivatable {
  private(set) var bufferProcessors: [AudioBufferProcessor] = []
  private(set) var levelMeterProcessors: [RecorderLevelMeterProcessor] = []
  private lazy var recorderQueue = RecorderQueue(settings: RecorderQueue.Settings(), output: self)
  deinit {
    stop()
  }

  override init() {}

  override func start() throws {
    try recorderQueue.start()
  }

  override func stop() {
    recorderQueue.stop()
  }

  public var isRunning: Bool {
    return recorderQueue.isRunning
  }

  public func attach(processor: AudioBufferProcessor) {
    attach(element: processor, container: &bufferProcessors, matcher: ===)
  }

  public func detach(processor: AudioBufferProcessor) {
    detach(element: processor, container: &bufferProcessors, matcher: ===)
  }

  public func contains(processor: RecorderLevelMeterProcessor) -> Bool {
    return statusLock.sync { levelMeterProcessors.contains { $0 === processor } }
  }

  public func attach(processor: RecorderLevelMeterProcessor) {
    attach(element: processor, container: &levelMeterProcessors, matcher: ===)
  }

  public func detach(processor: RecorderLevelMeterProcessor) {
    detach(element: processor, container: &levelMeterProcessors, matcher: ===)
  }

  private func attach<T>(element: T, container: inout [T], matcher: (_ lhs: T, _ rhs: T) -> Bool) {
    statusLock.sync {
      guard !container.contains(where: { matcher($0, element) }) else {
        return
      }

      container.append(element)
    }
  }

  private func detach<T>(element: T, container: inout [T], matcher: (_ lhs: T, _ rhs: T) -> Bool) {
    statusLock.sync {
      guard let index = container.firstIndex(where: { matcher($0, element) }) else {
        return
      }
      container.remove(at: index)
    }
  }
}

extension RecorderEngine: RecorderQueueOutput {
  func process(data: RecorderProcessorData) {
    let processors = statusLock.sync { bufferProcessors }
    processors.forEach {
      $0.process(buffer: data)
    }
  }

  func process(error: UltronError) {
    stop()
  }

  var processesMeterUpdate: Bool {
    return true
  }

  func process(meter: AudioQueueLevelMeterState) {
    let processors = statusLock.sync { levelMeterProcessors } // Race condition is ignored here
    let power = meter.mAveragePower
    let formedLevel = max(0, 70 + power) / 70
    processors.forEach {
      $0.processLevelUpdate(Double(min(1, formedLevel)))
    }
  }
}

// MARK: - Single Accessor

extension RecorderEngine {
  static let shared = RecorderEngine()
}

public extension UltronError {
  enum Category: String {
    case playerEngine = "Player Engine"
    case recorderEngine = "Recorder Engine"
    case encoder = "Encoder"
    case subtitleParser = "Subtitle Parser"
    case audioPlayer = "Audio Player"

    case streamPlayer = "Stream Player"
    case streamRecorder = "Stream Recorder"

    case remoteScorer = "Remote Scorer"

    case external = "External"
  }
}

public struct UltronError: LocalizedError {
  let category: Category
  let message: String

  init(category: Category, message: String) {
    self.category = category
    self.message = message
  }

  public var errorDescription: String? {
    return "[Ultron] \(category.rawValue): \(message)"
  }
}

public class RecorderProcessorData {
  public let recordData: Data
  public let audioFormat: AudioStreamPacketDescription?
  public let audioPacketCount: UInt32

  public init(recordData: Data, audioFormat: AudioStreamPacketDescription?, audioPacketCount: UInt32) {
    self.recordData = recordData
    self.audioFormat = audioFormat
    self.audioPacketCount = audioPacketCount
  }

  public init(inBuffer: AudioQueueBufferRef, inNumPackets: UInt32, inPacketDesc: UnsafePointer<AudioStreamPacketDescription>?) {
    audioFormat = inPacketDesc?.pointee
    audioPacketCount = inNumPackets
    if inBuffer.pointee.mAudioDataByteSize == 0 {
      recordData = Data()
    } else {
      recordData = Data(bytes: inBuffer.pointee.mAudioData, count: Int(inBuffer.pointee.mAudioDataByteSize))
    }
  }

  public var copyAudioBytes: (UnsafeMutablePointer<UInt8>, UInt32) {
    let bufferSize = recordData.count
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    recordData.copyBytes(to: buffer, count: bufferSize)
    return (buffer, UInt32(bufferSize))
  }
}

/// 由 RecorderEngine / AudioStreamRecorder 直接输出的 LPCM 音频数据
public protocol AudioBufferProcessor: class {
  /// 处理 pcm data 的回调。非主线程
  func process(buffer: RecorderProcessorData)
}

/// 由 RecorderEngine / AudioStreamRecorder 直接输出的 Level Meter（声压/音量）数据
public protocol RecorderLevelMeterProcessor: class {
  /// 录音音量大小变化的回调。非主线程
  ///
  /// - Parameter level: 录音音量，范围 0.0 ~ 1.0
  func processLevelUpdate(_ level: Double)
}

protocol RecorderQueueOutput {
  func process(data: RecorderProcessorData)
  func process(error: UltronError)

  var processesMeterUpdate: Bool { get }
  func process(meter: AudioQueueLevelMeterState)
}

extension RecorderQueue {
  // MARK: - Recorder Queue Settings

  final class Settings {
    var audioFormat: AudioStreamBasicDescription
    var trackingLevelMeterState: Bool = false

    /// AudioFormatID should be kAudioFormatLinearPCM
    init(audioFormat: AudioStreamBasicDescription) {
      assert(audioFormat.mFormatID == kAudioFormatLinearPCM, "audio formatID should be kAudioFormatLinearPCM")
      self.audioFormat = audioFormat
    }

    /// Create default scorer audioFormat recorder settings
    convenience init() {
      var audioFormat = AudioStreamBasicDescription()
      audioFormat.mSampleRate = 16000.0
      audioFormat.mFormatID = kAudioFormatLinearPCM
      audioFormat.mChannelsPerFrame = 1
      audioFormat.mFramesPerPacket = 1
      audioFormat.mBytesPerFrame = 2
      audioFormat.mBytesPerPacket = 2
      audioFormat.mBitsPerChannel = 16
      audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
      self.init(audioFormat: audioFormat)

      trackingLevelMeterState = true
    }
  }

  // MARK: - Recorder Queue State

  final class State {
    var isRunning = false

    var output: RecorderQueueOutput?

    var tracksLevelMeterState: Bool {
      return output?.processesMeterUpdate == true
    }

    // MARK: - Concurrency protection

    private let processingQueue = DispatchQueue(label: "com.liulishuo.audioEngine.recorderQueue.stateProcessingQueue")
    func process(data: RecorderProcessorData) {
      processingQueue.async {
        self.output?.process(data: data)
      }
    }

    func process(meter: AudioQueueLevelMeterState) {
      processingQueue.async {
        self.output?.process(meter: meter)
      }
    }

    func process(error: UltronError) {
      processingQueue.async {
        self.output?.process(error: error)
      }
    }
  }
}

// MARK: - Recorder Queue

final class RecorderQueue {
  private let settings: Settings
  init(settings: Settings, output: RecorderQueueOutput) {
    self.settings = settings
    state.output = output
  }

  deinit {}

  var isRunning: Bool {
    return state.isRunning
  }

  func start() throws {
    if !state.isRunning {
      try configAudioQueue()
      try startAudioQueue()
    }
  }

  func stop() {
    stop(with: nil)
  }

  // MARK: - Internal Properties

  private let numberRecordBuffers = 3
  private var state: State = State()
  private var audioQueue: AudioQueueRef?
}

// MARK: - internal methods extension

extension RecorderQueue {
  func stop(with error: UltronError?) {
    guard state.isRunning else { return }

    state.isRunning = false

    if let audioQueue = audioQueue {
      var error = noErr
      error = AudioQueueStop(audioQueue, true)
//      if error != noErr {
//        Logger.warning("Audio queue was not stopped correctly, OSStatus(\(error))")
//      }
      error = AudioQueueDispose(audioQueue, true)
//      if error != noErr {
//        Logger.warning("Audio queue was not disposed correctly, OSStatus(\(error))")
//      }
    }
  }

  // MARK: - AudioQueue

  func configAudioQueue() throws {
    func generateAudioQueue() throws -> AudioQueueRef {
      let error = AudioQueueNewInput(&settings.audioFormat, audioQueueCallback, &state, nil, nil, 0, &self.audioQueue)
      if let audioQueue = self.audioQueue, error == noErr {
        return audioQueue
      } else {
        throw UltronError(category: .recorderEngine, message: "Failed to create new audio queue, OSStatus(\(error))")
      }
    }

    func generateAudioStreamDescription(audioQueue: AudioQueueRef) throws {
      var size = UInt32(MemoryLayout.size(ofValue: settings.audioFormat))
      let error = AudioQueueGetProperty(audioQueue, kAudioQueueProperty_StreamDescription, &settings.audioFormat, &size)
      if error != noErr {
        throw UltronError(category: .recorderEngine, message: "Unable to get kAudioQueueProperty_StreamDescription of current audio queue, OSStatus(\(error))")
      }
    }

    func enableAudioQueueLevelMetering(audioQueue: AudioQueueRef) throws {
      var value: UInt32 = 1
      let valueSize = UInt32(MemoryLayout<UInt32>.stride)
      let error = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_EnableLevelMetering, &value, valueSize)
      if error != noErr {
        throw UltronError(category: .recorderEngine, message: "Unable to activate level metering of audio queue, OSStatus(\(error))")
      }
    }

    func computeRecordBufferSize(audioQueue: AudioQueueRef) throws -> Int {
      var packets: Int, frames: Int, bytes: Int
      frames = Int(ceil(0.2 * settings.audioFormat.mSampleRate))

      if settings.audioFormat.mBytesPerFrame > 0 {
        bytes = frames * Int(settings.audioFormat.mBytesPerFrame)
      } else {
        var maxPacketSize = UInt32()

        if settings.audioFormat.mBytesPerPacket > 0 {
          maxPacketSize = settings.audioFormat.mBytesPerPacket
        } else {
          var propertySize = UInt32(MemoryLayout.size(ofValue: maxPacketSize))
          let error = AudioQueueGetProperty(audioQueue, kAudioConverterPropertyMaximumOutputPacketSize, &maxPacketSize, &propertySize)
          if error != noErr {
            throw UltronError(category: .recorderEngine, message: "Unable to get kAudioConverterPropertyMaximumOutputPacketSize of current audio queue, OSStatus(\(error))")
          }
        }

        if settings.audioFormat.mFramesPerPacket > 0 {
          packets = frames / Int(settings.audioFormat.mFramesPerPacket)
        } else {
          packets = frames
        }

        if packets == 0 {
          packets = 1
        }

        bytes = packets * Int(maxPacketSize)
      }

      return bytes
    }

    func configAudioQueueBuffer(audioQueue: AudioQueueRef, bufferSize: Int) throws {
      for _ in 0 ..< numberRecordBuffers {
        var createBuffer: AudioQueueBufferRef?
        var error = noErr
        error = AudioQueueAllocateBuffer(audioQueue, UInt32(bufferSize), &createBuffer)
        guard let buffer = createBuffer, error == noErr else {
          throw UltronError(category: .recorderEngine, message: "Failed to allocate audio queue buffer, OSStatus(\(error))")
        }
        error = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)
        guard error == noErr else {
          throw UltronError(category: .recorderEngine, message: "Failed to enqueue buffer, OSStatus(\(error))")
        }
      }
    }

    let audioQueue = try generateAudioQueue()
    try generateAudioStreamDescription(audioQueue: audioQueue)
    if settings.trackingLevelMeterState {
      try enableAudioQueueLevelMetering(audioQueue: audioQueue)
    }
    let bufferSize = try computeRecordBufferSize(audioQueue: audioQueue)
    try configAudioQueueBuffer(audioQueue: audioQueue, bufferSize: bufferSize)
  }

  private func startAudioQueue() throws {
    guard let audioQueue = audioQueue else {
      throw UltronError(category: .recorderEngine, message: "Trying to start an audio queue before it is created.")
    }
    let error = AudioQueueStart(audioQueue, nil)
    guard error == noErr else {
      throw UltronError(category: .recorderEngine, message: "Start audio queue failed with OSStatus(\(error))")
    }
    state.isRunning = true
  }
}

private func audioQueueCallback(
  inUserData: UnsafeMutableRawPointer?,
  inQueue: AudioQueueRef,
  inBuffer: AudioQueueBufferRef,
  inStartTime: UnsafePointer<AudioTimeStamp>,
  inNumPackets: UInt32,
  inPacketDesc: UnsafePointer<AudioStreamPacketDescription>?
) {
  guard let state = inUserData?.assumingMemoryBound(to: RecorderQueue.State.self).pointee else {
    return
  }
  guard state.isRunning else { return }
  // Process output
  state.process(data: RecorderProcessorData(inBuffer: inBuffer, inNumPackets: inNumPackets, inPacketDesc: inPacketDesc))

  var error = noErr
  error = AudioQueueEnqueueBuffer(inQueue, inBuffer, 0, nil)
  if error != noErr {
    let description = "Failed to enqueue buffer back to audio queue, OSStatus(\(error))"
//    Logger.error(description)
    state.process(error: UltronError(category: .recorderEngine, message: description))
  }

  if state.tracksLevelMeterState {
    var meter = AudioQueueLevelMeterState()
    var meterSize = UInt32(MemoryLayout<[AudioQueueLevelMeterState]>.size)
    error = AudioQueueGetProperty(inQueue, kAudioQueueProperty_CurrentLevelMeterDB, &meter, &meterSize)
    if error != noErr {
      let description = "Failed to enqueue buffer back to audio queue, OSStatus(\(error))"
//      Logger.error(description)
    } else {
      state.process(meter: meter)
    }
  }
}

public class CommonActivatable: Activatable {
  public init() {}

  let activatorContainer = ActivatorContainer()
  internal let statusLock = DispatchQueue(label: "com.liulishuo.audioEngine.activatable.lock")

  public func contains(activator: Activator) -> Bool {
    return statusLock.sync { activatorContainer.container.contains(activator) }
  }

  /// 注意在第一次激活时，会执行 start 方法（由子类实现）
  ///
  /// - Parameter activator: 被激活的某个事物
  public func active(from activator: Activator) -> Bool {
    return statusLock.sync {
      if activatorContainer.isEmpty {
        do {
          try syncToMainQueueIfNeeded(start)
        } catch {
          print(error)
//          Logger.warning("Activating \(type(of: self)) failed: \(error.localizedDescription)")
          return false
        }
      }
      activatorContainer.insert(activator: activator)
      return true
    }
  }

  /// 注意在最后一个反激活时，会执行 stop 方法（由子类实现）
  ///
  /// - Parameter activator: 被反激活的某个事物
  public func inactive(from activator: Activator) {
    statusLock.sync {
      guard activatorContainer.remove(activator: activator) else { return }
      if activatorContainer.isEmpty {
        dispatchToMainQueueIfNeeded(stop)
      }
    }
  }

  func start() throws {
    preconditionFailure("Subclass must override this method")
  }

  func stop() {
    preconditionFailure("Subclass must override this method")
  }

  // MARK: - Thread Safety

  func syncToMainQueueIfNeeded(_ block: () throws -> Void) rethrows {
    if Thread.isMainThread {
      try block()
    } else {
      try DispatchQueue.main.sync(execute: block)
    }
  }

  func dispatchToMainQueueIfNeeded(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
