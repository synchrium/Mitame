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
                    Text(size.isNative ? "\(size.label)（モニターと同じ）" : "\(size.label)")
                        .tag(Optional(size))
                }
            }
        }

        // 2 台以上つながっているときだけ、どのモニターを HiDPI にするか選ぶ
        if controller.displays.count > 1 {
            Picker("モニター", selection: Binding(
                get: { controller.display },
                set: { if let d = $0 { controller.selectDisplay(d) } }
            )) {
                ForEach(controller.displays) { d in
                    Text("\(controller.name(of: d))（\(d.nativeWidth) × \(d.nativeHeight)）")
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
