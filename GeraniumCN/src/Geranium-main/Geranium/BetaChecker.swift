//
//  BetaChecker.swift
//  Geranium
//
//  This is used to check if current device is enrolled onto my db.
//  Created by cclerc on 24.12.23.
//

import Foundation
import SwiftUI

struct BetaView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        @State var textPlaceHorder = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        @State var validation = ""
        @State var isEnrolled = false
        var timer: Timer?
        VStack {
            Image(uiImage: Bundle.main.icon!)
                .cornerRadius(10)
            Text("欢迎参与 Geranium Beta 测试计划")
                .font(.title2)
                .bold()
                .multilineTextAlignment(.center)
            Text("请复制你的 UUID 并发送给负责的开发者。")
                .padding()
                .multilineTextAlignment(.center)
            Text(textPlaceHorder)
                .padding()
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text(validation)
                .padding()
                .multilineTextAlignment(.center)
            if !isEnrolled {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
                    .scaleEffect(1.0, anchor: .center)
                Text("请退出并重新进入应用。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                    .padding(.top)
                    .multilineTextAlignment(.center)
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            if isDeviceEnrolled() {
                print("should quit ?")
                isEnrolled.toggle()
                close()
            }
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                if isDeviceEnrolled() {
                    print("should quit ?")
                    isEnrolled.toggle()
                    close()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    func close() {
        dismiss()
    }
}

func isDeviceEnrolled() -> Bool {
    var result = false
    let semaphore = DispatchSemaphore(value: 0)

    let url = URL(string: "<private>")!
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer {
            semaphore.signal()
        }

        if let error = error {
            print("Error: \(error)")
            return
        }

        guard let data = data else {
            print("未收到数据")
            return
        }

        if let fileContent = String(data: data, encoding: .utf8) {
            let vendorID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            result = fileContent.contains(vendorID)
            if result {
                print("用户已加入 Beta 测试计划")
            }
        } else {
            print("数据转换为字符串失败")
        }
    }

    task.resume()
    semaphore.wait()
    return result
}
