//
//  BookMarkSlider.swift
//  Geranium
//
//  Created by cclerc on 21.12.23.
//

import SwiftUI
import AlertKit

struct Bookmark: Identifiable {
    var id = UUID()
    var name: String
    var lat: Double
    var long: Double
}

struct BookMarkSlider: View {
    @Environment(\.dismiss) var dismiss
    @Binding var lat: Double
    @Binding var long: Double
    @State private var name = ""
    @State private var result: Bool = false
    @AppStorage("isMika") var isMika: Bool = false
    @State private var bookmarks: [Bookmark] = BookMarkRetrieve().map {
        Bookmark(name: $0["name"] as! String, lat: $0["lat"] as! Double, long: $0["long"] as! Double)
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(bookmarks) { bookmark in
                    Button(action: {
                        close()
                        LocSimManager.startLocSim(location: .init(latitude: bookmark.lat, longitude: bookmark.long))
                        AlertKitAPI.present(
                            title: "已开始！",
                            icon: .done,
                            style: .iOS17AppleMusic,
                            haptic: .success
                        )
                    }) {
                        VStack(alignment: .leading) {
                            Text("\(bookmark.name)")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Latitude: \(bookmark.lat) Longitude: \(bookmark.long)")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .onDelete(perform: deleteBookmark)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("书签")
                        .font(.title2)
                        .bold()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        if lat != 0.00 && long != 0.00 {
                            UIApplication.shared.TextFieldAlert(
                                title: "输入书签名称",
                                textFieldPlaceHolder: "示例..."
                            ) { enteredText, _ in
                                let bookmarkName = enteredText ?? "未知"
                                result = BookMarkSave(lat: lat, long: long, name: bookmarkName)
                                bookmarks = BookMarkRetrieve().map {
                                    Bookmark(name: $0["name"] as! String, lat: $0["lat"] as! Double, long: $0["long"] as! Double)
                                }
                            }

                        } else {
                            UIApplication.shared.confirmAlert(title: "你的位置已设置为 0", body: "Are you sure you want to continue? This might be a mistake; try picking somewhere on the map", onOK: {
                                UIApplication.shared.TextFieldAlert(title: "输入书签名称", textFieldPlaceHolder: "示例...", completion: { enteredText, _ in
                                    result = BookMarkSave(lat: lat, long: long, name: enteredText ?? "未知")
                                    bookmarks = BookMarkRetrieve().map {
                                        Bookmark(name: $0["name"] as! String, lat: $0["lat"] as! Double, long: $0["long"] as! Double)
                                    }
                                    AlertKitAPI.present(
                                        title: "已添加！",
                                        icon: .done,
                                        style: .iOS17AppleMusic,
                                        haptic: .success
                                    )
                                })
                            }, noCancel: false)
                        }
                    }) {
                        Image(systemName: "plus")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .overlay(
                    Group {
                        if bookmarks.isEmpty {
                            VStack {
                                Text("暂无已保存的书签。")
                                    .foregroundColor(.secondary)
                                    .font(.title)
                                    .padding()
                                    .multilineTextAlignment(.center)
                                Text("To add a bookmark, select a custom location then tap the + button.")
                                    .foregroundColor(.secondary)
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    , alignment: .center
                )
            .onAppear {
                if isThereAnyMika(), !isMika {
                    UIApplication.shared.confirmAlert(title:"检测到 Mika 的 LocSim 书签/记录。", body: "是否要导入？", onOK: {
                        importMika()
                        bookmarks = BookMarkRetrieve().map {
                            Bookmark(name: $0["name"] as! String, lat: $0["lat"] as! Double, long: $0["long"] as! Double)
                        }
                        isMika.toggle()
                    }, noCancel: false, yes: true)
                }
            }
        }
    }

    private func deleteBookmark(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        updateBookmarks()
        AlertKitAPI.present(
            title: "已删除！",
            icon: .done,
            style: .iOS17AppleMusic,
            haptic: .success
        )
    }
    let sharedUserDefaultsSuiteName = "group.live.cclerc.geraniumBookmarks"
    private func updateBookmarks() {
        let sharedUserDefaults = UserDefaults(suiteName: sharedUserDefaultsSuiteName)
        sharedUserDefaults?.set(bookmarks.map { ["name": $0.name, "lat": $0.lat, "long": $0.long] }, forKey: "bookmarks")
        sharedUserDefaults?.synchronize()
    }
    
    func close() {
        dismiss()
    }
}
