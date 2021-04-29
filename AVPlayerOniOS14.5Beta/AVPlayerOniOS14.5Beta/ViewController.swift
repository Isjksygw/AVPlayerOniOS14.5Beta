//
//  ViewController.swift
//  AVPlayerOniOS14.5Beta
//
//  Created by chuchu xu on 2021/4/19.
//

import AVFoundation
import UIKit

/// ReadMe
/// 1. Click Record say something
/// 2. Click Play
/// and you will here kakakak
///
class ViewController: UIViewController {
  struct Constrant {
    static let iOS14_3URL = Bundle.main.url(forResource: "iOS14.3_version", withExtension: ".m4a")
    static let iOS14_5_URL = Bundle.main.url(forResource: "iOS14.5_beta_version", withExtension: ".m4a")
  }

  private lazy var iOS14_5Button: UIButton = {
    let btn = UIButton(frame: .init(x: 20, y: 100, width: 260, height: 80))
    btn.setTitle("Play", for: .normal)
    btn.setTitle("Playing", for: .selected)
    btn.addTarget(self, action: #selector(playForRecordOniOS14_5(_:)), for: .touchUpInside)
    btn.backgroundColor = .green
    return btn
  }()

  private lazy var record: UIButton = {
    let btn = UIButton(frame: .init(x: 20, y: 350, width: 260, height: 80))
    btn.setTitle("Record", for: .normal)
    btn.setTitle("Stop", for: .selected)
    btn.addTarget(self, action: #selector(recordAction(_:)), for: .touchUpInside)
    btn.backgroundColor = .brown
    return btn
  }()

  private var currentURL: URL?
  private var player: AVPlayer?
  private var audioRecorder: AudioStreamRecorder?

  override func viewDidLoad() {
    super.viewDidLoad()
    // Do any additional setup after loading the view.
    view.addSubview(iOS14_5Button)
    view.addSubview(record)
  }

  @objc
  func playForRecordOniOS14_5(_ sender: UIButton) {
    player = AVPlayer(url: currentURL ?? Constrant.iOS14_3URL!)
    sender.isSelected.toggle()
    sender.isSelected ? player?.play() : player?.pause()
  }

  @objc
  func playForRecordOniOS14_5_beta(_ sender: UIButton) {
    player = AVPlayer(url: currentURL ?? Constrant.iOS14_5_URL!)
    sender.isSelected.toggle()
    sender.isSelected ? player?.play() : player?.pause()
  }

  @objc
  func recordAction(_ sender: UIButton) {
    sender.isSelected.toggle()
    sender.isSelected ? startRecord() : stopRecord()
  }

  func initRecord() {
    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord)
    try? AVAudioSession.sharedInstance().setActive(true)

    let alacFileWriter = AudioStreamRecorderSystemAudioConverterWriter(localPath: getUserAlacTempRecordFilePath(), converter: .alac())

    let processors: [AudioStreamRecorderProcessor] = [alacFileWriter]
    let audioRecorder = AudioStreamRecorder(processors: processors)
    audioRecorder.startRecorder()
    self.audioRecorder = audioRecorder
  }

  func startRecord() {
    initRecord()
  }

  func stopRecord() {
    audioRecorder?.stop()
  }
}

extension ViewController {
  private func getUserAlacTempRecordFilePath() -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("record.m4a")
    print("====== path \(url)")
    currentURL = url
    return url.path
  }
}
