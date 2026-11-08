//
//  MirrorController.swift
//  Mitame
//
//  Created by synchrium on 2026/11/08
//
//  Copyright (C) 2026  synchrium
//

import Foundation
import Observation
import ServiceManagement

/// つながっている外部モニター
struct ExternalDisplay: Hashable, Identifiable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// モニター本来の解像度（ピクセル）
    let nativeWidth: UInt32
    let nativeHeight: UInt32

    /// UserDefaults で使う見分け用の名前
    var id: String { "\(vendor)-\(model)-\(serial)" }

    /// 4K 以上なら macOS がもとから HiDPI にできる
    var isAlreadyHiDPI: Bool { nativeWidth >= 3840 || nativeHeight >= 2160 }

    /// 見た目の大きさの候補（本来の解像度の ×0.75〜×1.33、縦横比はそのまま）
    var lookSizes: [LookSize] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let factors: [Double] = [0.75, 0.8333, 1.0, 1.0667, 1.1333, 1.2, 1.3333]
        return factors.compactMap { f in
            // 幅は 8 の倍数、高さは縦横比から出して偶数にそろえる
            let w = UInt32((Double(nativeWidth) * f / 8).rounded()) * 8
            let h = UInt32((Double(w) * Double(nativeHeight) / Double(nativeWidth) / 2).rounded()) * 2
            // 描画は 2 倍なので、8K（7680×4320）を超える大きさは出さない
            guard w * 2 <= 7680, h * 2 <= 4320 else { return nil }
            return LookSize(width: w, height: h, isNative: f == 1.0)
        }
    }

    /// 最初に選ぶ大きさ：少し広い（×1.13）。なければ本来の大きさ
    var defaultLookSize: LookSize? {
        let sizes = lookSizes
        return sizes.count > 4 ? sizes[4] : sizes.last
    }

    init?(_ info: [String: Any]) {
        guard let vendor = (info["vendor"] as? NSNumber)?.uint32Value,
              let model = (info["model"] as? NSNumber)?.uint32Value,
              let serial = (info["serial"] as? NSNumber)?.uint32Value,
              let w = (info["nativeWidth"] as? NSNumber)?.uint32Value,
              let h = (info["nativeHeight"] as? NSNumber)?.uint32Value
        else { return nil }
        self.vendor = vendor
        self.model = model
        self.serial = serial
        nativeWidth = w
        nativeHeight = h
    }
}

/// 見た目の大きさ（ポイント）。実際の描画はこの 2 倍のピクセルで行い、モニターに縮めて映す。
struct LookSize: Hashable, Identifiable {
    let width: UInt32
    let height: UInt32
    var isNative = false
    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }

    init(width: UInt32, height: UInt32, isNative: Bool = false) {
        self.width = width
        self.height = height
        self.isNative = isNative
    }

    init?(id: String) {
        let parts = id.split(separator: "x").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(width: parts[0], height: parts[1])
    }

    // isNative は見分けに使わない
    static func == (a: LookSize, b: LookSize) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// ミラーのオン／オフ・モニター・大きさ・ログイン時の起動を受け持つ
@Observable
final class MirrorController {
    static let shared = MirrorController()

    private(set) var isOn = false
    /// オンで、いまモニターがつながってミラーしている
    private(set) var isMirroring = false
    private(set) var displays: [ExternalDisplay] = []
    /// 選んでいるモニター（つながっていなければ nil）
    private(set) var display: ExternalDisplay?
    private(set) var size: LookSize?
    private(set) var launchAtLogin = false

    private let defaults = UserDefaults.standard

    private init() {
        MitameSetChangeHandler { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - 表示

    var statusText: String {
        guard let display else {
            if isOn { return String(localized: "モニターをつなぐと HiDPI になります") }
            return String(localized: "外部モニターが見つかりません")
        }
        let name = name(of: display)
        if display.isAlreadyHiDPI && !isOn {
            return String(localized: "\(name)：もとから HiDPI です")
        }
        if !isOn { return String(localized: "\(name)：オフ") }
        guard isMirroring, let size else { return String(localized: "\(name)：準備中…") }
        return String(localized: "\(name)：\(size.label)")
    }

    var canTurnOn: Bool {
        isOn || (display != nil && display?.isAlreadyHiDPI == false)
    }

    func name(of display: ExternalDisplay) -> String {
        defaults.string(forKey: "name.\(display.id)")
            ?? defaults.string(forKey: "displayName.\(display.vendor)") // bfdc507 までの覚え方
            ?? String(localized: "外部モニター")
    }

    // MARK: - 操作

    /// 起動したとき、前回オンだったら続きからオンにする
    func restoreOnLaunch() {
        if defaults.bool(forKey: "enabled") {
            start()
        }
    }

    func setOn(_ on: Bool) {
        defaults.set(on, forKey: "enabled")
        if on { start() } else { MitameStop() }
        refresh()
    }

    func setSize(_ newSize: LookSize) {
        guard let display else { return }
        defaults.set(newSize.id, forKey: "size.\(display.id)")
        size = newSize
        if isOn { start() }
    }

    func selectDisplay(_ newDisplay: ExternalDisplay) {
        defaults.set(newDisplay.id, forKey: "display")
        refresh()
        if isOn {
            if newDisplay.isAlreadyHiDPI { setOn(false) } else { start() }
        }
    }

    func rebuild() {
        MitameRebuild()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("launch at login: \(error)")
        }
        refresh()
    }

    // MARK: - 中身

    private func start() {
        refresh()
        if let display, let size {
            MitameStart(size.width, size.height, display.vendor, display.model, display.serial)
            return
        }
        // 抜いているときは、前回のモニターがつながるのを待つ
        guard let saved = defaults.string(forKey: "display"),
              let sizeID = defaults.string(forKey: "size.\(saved)"),
              let savedSize = LookSize(id: sizeID) else {
            NSLog("no external display")
            return
        }
        let parts = saved.split(separator: "-").compactMap { UInt32($0) }
        guard parts.count == 3 else { return }
        MitameStart(savedSize.width, savedSize.height, parts[0], parts[1], parts[2])
    }

    private func refresh() {
        isOn = MitameIsRunning()
        isMirroring = MitameIsMirroring()
        launchAtLogin = SMAppService.mainApp.status == .enabled

        let list = MitameListExternalDisplays()
        displays = list.compactMap { ExternalDisplay($0) }
        // 名前は見えたときに覚える（ミラー中は macOS の画面一覧に出てこないため）
        for (info, d) in zip(list, list.map { ExternalDisplay($0) }) {
            if let d, let name = info["name"] as? String {
                defaults.set(name, forKey: "name.\(d.id)")
            }
        }

        // 選んでいたモニターがつながっていればそれ、なければ最初の 1 台
        let saved = defaults.string(forKey: "display")
        display = displays.first { $0.id == saved } ?? displays.first
        if let display {
            if saved == nil { defaults.set(display.id, forKey: "display") }
            let sizes = display.lookSizes
            let savedSize = defaults.string(forKey: "size.\(display.id)").flatMap { LookSize(id: $0) }
            size = sizes.first { $0 == savedSize } ?? display.defaultLookSize
        } else {
            size = nil
        }
    }
}
