//
//  ByeTimeView.swift
//  Geranium
//
//  Created by cclerc on 29.12.23.
//

import SwiftUI

struct ByeTimeView: View {
    @Binding var DebugStuff: Bool
    @State var ScreenTimeAgent: Bool = true
    @State var usagetrackingd: Bool = true
    @State var homed: Bool = false
    @State var familycircled: Bool = false
    var body: some View {
        VStack {
            List {
                Section(header: Label("屏幕使用时间代理", systemImage: "hourglass"), footer: Text("Screen Time Agent is responsible for managing all of ScreenTime preferences. Disabling this process only might at best disable Screen Time partially.")) {
                    Toggle(isOn: $ScreenTimeAgent) {
                        Text("禁用屏幕使用时间代理")
                    }
                    .disabled(!DebugStuff)
                }
                Section(header: Label("使用跟踪代理", systemImage: "magnifyingglass"), footer: Text("Usage Tracking Agent monitors and reports usage budgets set by Health, Parental Controls (= Screen Time) or Device Management. Disabling this might also disable some other features on your iPhone.")) {
                    Toggle(isOn: $usagetrackingd) {
                        Text("禁用使用跟踪代理")
                    }
                }
                Section(header: Label("Homed", systemImage: "homekit"), footer: Text("Homed is in charge of HomeKit accessories and products, for instance HomePods, connected light bulbs and other, that you are managing from the 'Home' app on your phone. Don't disable this if you are using those accessories.")) {
                    Toggle(isOn: $homed) {
                        Text("禁用 Homed")
                    }
                }
                Section(header: Label("Familycircled", systemImage: "figure.and.child.holdinghands"), footer: Text("Familycircled is in charge of iCloud Family system. This includes family subscriptions, so if you disable this you won't be able to use them. However, this can help preventing ScreenTime from working.")) {
                    Toggle(isOn: $familycircled) {
                        Text("禁用 Familycircled")
                    }
                }
            }
            Button("和屏幕使用时间说再见！", action : {
                UIApplication.shared.confirmAlert(title: "你即将禁用这些守护进程。", body: "This will delete Screen Time Preferences files and prevent the following daemoms from starting up with iOS. Are you sure you want to continue ?", onOK: {
                    UIApplication.shared.alert(title: "正在移除屏幕使用时间...", body: "Your device will reboot, but I'd recommend you do a manual reboot after the first automatic one.", animated: false, withButton: false)
                    DisableScreenTime(screentimeagentd: ScreenTimeAgent, usagetrackingd: usagetrackingd, homed: homed, familycircled: familycircled)
                }, noCancel: false, yes: true)
            })
            .padding(10)
            .background(Color.accentColor)
            .cornerRadius(8)
            .foregroundColor(.black)
            Button("启用屏幕使用时间", action : {
                UIApplication.shared.confirmAlert(title: "你即将重新启用屏幕使用时间。", body: "This will revert any ScreenTime backup you made and logging will be put back on.", onOK: {
                    enableBack()
                }, noCancel: false, yes: true)
            })
            .padding(10)
            .background(Color.accentColor)
            .cornerRadius(8)
            .foregroundColor(.black)
        }
    }
}
