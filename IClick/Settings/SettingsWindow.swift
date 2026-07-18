//
//  SettingsWindow.swift
//  IClick
//
//  Created by 李旭 on 2024/9/25.
//

import SwiftUI

struct SettingsWindow: Scene {
    @ObservedObject var appState: AppState

    #if !APP_STORE
    @EnvironmentObject var updateManager: UpdateManager
    #endif

    let onAppear: () -> Void

    var body: some Scene {
        Window("Settings", id: Constants.settingsWindowID) {
            SettingsView()
                .environmentObject(appState)
                .onAppear {
                    onAppear()
                }
                .frame(minWidth: 800, minHeight: 500)
                #if !APP_STORE
                .sheet(isPresented: $updateManager.showUpdateSheet) {
                    UpdateView(updateManager: updateManager)
                }
                #endif
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 800, height: 500)
    }

}
