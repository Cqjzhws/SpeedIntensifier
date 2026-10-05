//
//  DaemonWelcomeView.swift
//  Geranium
//
//  Created by cclerc on 21.12.23.
//

import SwiftUI

struct DaemonWelcomeView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        List {
            
            Section(header: Text("用途")) {
                Text("By adding some rules to iOS internals, this software prevents the daemon from launching when you boot your phone. The app lists every running daemon, and you can swipe to the left to remove one of them.")
            }
            
            Section(header: Text("警告")) {
                Text("DISABLING SYSTEM DAEMONS IS DANGEROUS. YOU COULD BOOTLOOP YOUR DEVICE. PROCEED WITH CAUTION. I AM NOT RESPONSIBLE FOR ANY PROBLEM ON YOUR DEVICE.")
                    .foregroundStyle(.red)
            }
            Section(header: Text("请注意")) {
                Text("If you want to revert any of your choice, you should go into the manager (list icon next to the apply icon), where you can toggle disabled daemons.")
                    .foregroundStyle(.green)
            }
            Section(header: Text("更多信息")) {
                Button("守护进程列表及其功能说明") {
                    UIApplication.shared.open(URL(string: "https://www.reddit.com/r/jailbreak/comments/10v7j59/tutorial_list_of_ios_daemons_and_what_they_do/")!)
                }
                Button("可禁用的守护进程列表") {
                    UIApplication.shared.open(URL(string: "https://www.reddit.com/r/jailbreak/comments/10v7j59/comment/j8s1lgj/")!)
                }
            }
        }
        .navigationTitle("提示")
        .navigationBarItems(trailing: Button("我知道了") {
            close()
        })
        .environment(\.defaultMinListRowHeight, 50)
        .interactiveDismissDisabled()
    }

    func close() {
        dismiss()
    }
}

#Preview {
    DaemonWelcomeView()
}
