//
//  MitameApp.swift
//  Mitame
//  
//  Created by synchrium on 2026/11/08
//  
//  Copyright (C) 2026  synchrium
//

import SwiftUI

@main
struct MitameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = MirrorController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.isOn ? "inset.filled.tv" : "tv")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MirrorController.shared.restoreOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 終わるときはミラーを外してモニターを元の解像度に戻す
        MitameStop()
    }
}
