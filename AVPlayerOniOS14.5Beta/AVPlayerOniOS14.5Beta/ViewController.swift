//
//  ViewController.swift
//  AVPlayerOniOS14.5Beta
//
//  Created by chuchu xu on 2021/4/19.
//

import AVFoundation
import UIKit

class ViewController: UIViewController {
  struct Constrant {
    static let iOS14_3URL = Bundle.main.url(forResource: "iOS14.3_version", withExtension: ".m4a")
    static let iOS14_5_betaURL = Bundle.main.url(forResource: "iOS14.5_beta_version", withExtension: ".m4a")
  }

  private lazy var iOS14_3Button: UIButton = {
    let btn = UIButton(frame: .init(x: 20, y: 100, width: 260, height: 80))
    btn.setTitle("Normal On iOS14.3", for: .normal)
    btn.setTitle("Playing", for: .selected)
    btn.addTarget(self, action: #selector(playForRecordOniOS14_3(_:)), for: .touchUpInside)
    btn.backgroundColor = .green
    return btn
  }()

  private lazy var iOS14_5_betaButton: UIButton = {
    let btn = UIButton(frame: .init(x: 20, y: 250, width: 260, height: 80))
    btn.setTitle("Normal On iOS14.5_beta", for: .normal)
    btn.setTitle("Playing", for: .selected)
    btn.addTarget(self, action: #selector(playForRecordOniOS14_5_beta(_:)), for: .touchUpInside)
    btn.backgroundColor = .red
    return btn
  }()

  private var player: AVPlayer?

  override func viewDidLoad() {
    super.viewDidLoad()
    // Do any additional setup after loading the view.
    view.addSubview(iOS14_3Button)
    view.addSubview(iOS14_5_betaButton)
  }

  @objc
  func playForRecordOniOS14_3(_ sender: UIButton) {
    player = AVPlayer(url: Constrant.iOS14_3URL!)
    sender.isSelected.toggle()
    sender.isSelected ? player?.play() : player?.pause()
  }

  @objc
  func playForRecordOniOS14_5_beta(_ sender: UIButton) {
    player = AVPlayer(url: Constrant.iOS14_5_betaURL!)
    sender.isSelected.toggle()
    sender.isSelected ? player?.play() : player?.pause()
  }
}
