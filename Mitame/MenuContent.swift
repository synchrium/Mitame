//
//  MenuContent.swift
//  Mitame
//
//  Created by synchrium on 2026/11/08
//
//  Copyright (C) 2026  synchrium
//

import SwiftUI

/// メニューバーのアイコンを押したときに出るメニュー
struct MenuContent: View {
    @Bindable var controller: MirrorController

    var body: some View {
        Text(controller.statusText)

        Divider()

        Toggle("HiDPI にする", isOn: Binding(
            get: { controller.isOn },
            set: { controller.setOn($0) }
        ))
        .disabled(!controller.canTurnOn)

        if let display = controller.display, !display.isAlreadyHiDPI {
            Picker("見た目の大きさ", selection: Binding(
                get: { controller.size },
                set: { if let s = $0 { controller.setSize(s) } }
            )) {
                ForEach(display.lookSizes) { size in
                    Group {
                        if size.isNative && display.isBuiltin {
                            Text("\(size.label)（画面の点と同じ）")
                        } else if size.isNative {
                            Text("\(size.label)（モニターと同じ）")
                        } else {
                            Text("\(size.label)")
                        }
                    }
                    .tag(Optional(size))
                }
            }
        }

        // どの画面を HiDPI にするか選ぶ。2 つ以上あるとき、
        // または選んでいた外部モニターを抜いている（内蔵に切り替えられるように）とき
        if controller.displays.count > 1
            || (controller.display == nil && !controller.displays.isEmpty) {
            Picker("モニター", selection: Binding(
                get: { controller.display },
                set: { if let d = $0 { controller.selectDisplay(d) } }
            )) {
                ForEach(controller.displays) { d in
                    Group {
                        // 同じ名前のモニターがほかにあるときだけ、点の数を付けて見分ける
                        // （String にしてカンマ区切りにしない）
                        let name = controller.name(of: d)
                        if controller.displays.filter({ controller.name(of: $0) == name }).count > 1 {
                            Text("\(name)（\(String(d.nativeWidth)) × \(String(d.nativeHeight))）")
                        } else {
                            Text(verbatim: name)
                        }
                    }
                        .tag(Optional(d))
                }
            }
        }

        Button("作り直す") { controller.rebuild() }
            .disabled(!controller.isMirroring)

        Divider()

        Toggle("ログイン時に起動", isOn: Binding(
            get: { controller.launchAtLogin },
            set: { controller.setLaunchAtLogin($0) }
        ))

        Button("Mitame について") { showAbout() }

        Button("終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showAbout() {
        let credits = String(localized: """
        外部モニターを HiDPI（Retina）で表示します。
        内蔵ディスプレイを、標準の設定より広く使うこともできます。

        hidpi-mirror（Petr Baudis、MIT License）の処理を使っています。
        https://github.com/pasky/hidpi-mirror
        """)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: credits,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.labelColor]),
        ])
    }
}
