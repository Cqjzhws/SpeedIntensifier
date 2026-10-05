//
//  NotifHelp.swift
//  Geranium
//
//  Created by Constantin Clerc on 22.02.2024.
//

import SwiftUI

struct NotifHelp: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("问题"), footer: Text("You might lose some unimportant data, such as WiFi passwords and preferences.")) {
                    Text("Lost your notifications because of the cleaner ? Don't panic, here is the solution !")
                }
                Section(header: Text("操作步骤")) {
                    Text("First, you need to open Settings. The app can do it for you if you want. Then, go in **General**, scroll down, and go in **Reset**.")
                    Button("打开设置") {
                        if let url = URL(string:UIApplication.openSettingsURLString) {
                           if UIApplication.shared.canOpenURL(url) {
                              UIApplication.shared.open(url, options: [:], completionHandler: nil)
                           }
                        }
                    }
                }
                Section() {
                    Text("Then, you need to press the **Reset** button (NOT the erase all contents and settings)")
                }
                Section() {
                    Text("Press **Reset All Settings**, follow what's on your screen and you are done !")
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("更多帮助")
                        .font(.title2)
                        .bold()
                        .padding(.top, 10)
                }
            }

        }
        .environment(\.defaultMinListRowHeight, 50)
    }
}

#Preview {
    NotifHelp()
}
