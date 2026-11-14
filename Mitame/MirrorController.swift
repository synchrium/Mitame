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

/// つながっている画面（外部モニターか内蔵ディスプレイ）
struct ExternalDisplay: Hashable, Identifiable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// モニター本来の解像度（ピクセル）
    let nativeWidth: UInt32
    let nativeHeight: UInt32
    /// Mac の内蔵ディスプレイ
    let isBuiltin: Bool

    /// UserDefaults で使う見分け用の名前（内蔵は 1 つだけなので "builtin"）
    var id: String { isBuiltin ? Self.builtinID : "\(vendor)-\(model)-\(serial)" }
    static let builtinID = "builtin"

    /// 4K 以上なら macOS がもとから HiDPI にできる。
    /// 内蔵はもとから Retina だが、標準の設定より広くするために使うので対象にする
    var isAlreadyHiDPI: Bool { !isBuiltin && (nativeWidth >= 3840 || nativeHeight >= 2160) }

    /// 見た目の大きさの候補（縦横比はそのまま）。
    /// 外部モニター：本来の解像度の ×0.75〜×1.33。
    /// 内蔵：画面の点の数の ×0.7〜×1.0（macOS の「スペースを拡大」より広いところだけ。
    /// 13 インチの 2560×1600 なら 1800×1125〜2560×1600）
    var lookSizes: [LookSize] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let factors: [Double] = isBuiltin
            ? [0.7031, 0.75, 0.8, 0.875, 1.0]
            : [0.75, 0.8333, 1.0, 1.0667, 1.1333, 1.2, 1.3333]
        return factors.compactMap { f in
            // 幅は 8 の倍数、高さは縦横比から出して偶数にそろえる
            let w = UInt32((Double(nativeWidth) * f / 8).rounded()) * 8
            // 割り切れるならそのまま（2560×1600 の 1800 → 1125）、でなければ偶数にそろえる
            let exact = Double(w) * Double(nativeHeight) / Double(nativeWidth)
            let h = exact == exact.rounded() ? UInt32(exact) : UInt32((exact / 2).rounded()) * 2
            // 描画は 2 倍なので、8K（7680×4320）を超える大きさは出さない
            guard w * 2 <= 7680, h * 2 <= 4320 else { return nil }
            return LookSize(width: w, height: h, isNative: f == 1.0)
        }
    }

    /// 最初に選ぶ大きさ：外部は少し広い（×1.13）、内蔵は ×0.75（13 インチで 1920×1200）。
    /// なければ一番大きいもの
    var defaultLookSize: LookSize? {
        let sizes = lookSizes
        let index = isBuiltin ? 1 : 4
        return sizes.count > index ? sizes[index] : sizes.last
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
        isBuiltin = (info["builtin"] as? NSNumber)?.boolValue ?? false
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
            if isOn {
                if defaults.string(forKey: "display") == ExternalDisplay.builtinID {
                    return String(localized: "Mac を開くと HiDPI になります")
                }
                return String(localized: "モニターをつなぐと HiDPI になります")
            }
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
        if display.isBuiltin { return String(localized: "内蔵ディスプレイ") }
        return defaults.string(forKey: "name.\(display.id)")
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
            // オフのときに代わりに選んでいた画面でオンにしたら、それを覚える
            defaults.set(display.id, forKey: "display")
            MitameStart(size.width, size.height, display.isBuiltin,
                        display.vendor, display.model, display.serial)
            return
        }
        // 抜いているときは、前回のモニターがつながるのを待つ
        guard let saved = defaults.string(forKey: "display"),
              let sizeID = defaults.string(forKey: "size.\(saved)"),
              let savedSize = LookSize(id: sizeID) else {
            NSLog("no external display")
            return
        }
        // 内蔵を選んでいてふたを閉じているときは、開くのを待つ
        if saved == ExternalDisplay.builtinID {
            MitameStart(savedSize.width, savedSize.height, true, 0, 0, 0)
            return
        }
        let parts = saved.split(separator: "-").compactMap { UInt32($0) }
        guard parts.count == 3 else { return }
        MitameStart(savedSize.width, savedSize.height, false, parts[0], parts[1], parts[2])
    }

    private func refresh() {
        isOn = MitameIsRunning()
        isMirroring = MitameIsMirroring()
        launchAtLogin = SMAppService.mainApp.status == .enabled

        let list = MitameListDisplays()
        displays = list.compactMap { ExternalDisplay($0) }
        // 名前は見えたときに覚える（ミラー中は macOS の画面一覧に出てこないため）
        for (info, d) in zip(list, list.map { ExternalDisplay($0) }) {
            if let d, !d.isBuiltin, let name = info["name"] as? String {
                defaults.set(name, forKey: "name.\(d.id)")
            }
        }

        // 選んでいた画面があればそれ。
        // なければ、オンのときはその画面が戻るのを待ち（nil）、オフのときは外部モニター、次に内蔵
        let saved = defaults.string(forKey: "display")
        if let found = displays.first(where: { $0.id == saved }) {
            display = found
        } else if (isOn || defaults.bool(forKey: "enabled")) && saved != nil {
            // 起動した直後はまだ isOn が false なので、保存した「オン」も見る
            display = nil
        } else {
            display = displays.first { !$0.isBuiltin } ?? displays.first
        }
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
