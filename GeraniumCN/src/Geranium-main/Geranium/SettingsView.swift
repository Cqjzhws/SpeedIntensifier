//
//  SettingsView.swift
//  Geranium
//
//  Created by cclerc on 23.12.23.
//

import SwiftUI
import AlertKit

struct SettingsView: View {
    @State var defaultTab = AppSettings().defaultTab
    @State var DebugStuff: Bool = false
    @State var MinimCal: String = ""
    @State var LocSimTries: String = ""
    @State var localisation: String = {
        if langaugee != "" {
            return langaugee
        }
        else if let languages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           let firstLanguage = languages.first {
                return "\(Locale.current.languageCode ?? "en-GB")"
        } else {
            return "en-GB"
        }
    }()
    @StateObject private var appSettings = AppSettings()
    
    // Custom language
    @State var appCodeLanguage = langaugee
    let languageMapping: [String: String] = [
        // i made catgpt work for me on this one
                "zh-Hans": "Chinese (Simplified)", //
                "zh-Hant": "Chinese (Traditional)", //
                "Base": "English", //
                "en-GB": "English (GB)",
                "es": "Spanish", //
                "es-419": "Spanish (Latin America)", //
                "fr": "French", //
                "it": "Italian", //
                "ja": "Japanese", //
                "ko": "Korean", //
                "ru": "Russian", //
                "sk": "Slovak", //
                "sv": "Swedish", //
                "vi": "Vietnamese", //
    ]
    var sortedLocalisalist: [String] {
        languageMapping.keys.sorted()
    }
    
    
    // Open Tab
    let defaultTabList: [Int: String] = [
                1: "主页", //
                2: "守护进程", //
                3: "LocSim", //
                4: "清理器",
                5: "监管工具", //
    ]
    
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Label("ByeTime", systemImage: "hourglass"), footer: Text("ByeTime allows you to completly disable Screen Time, iCloud or not.")) {
                    NavigationLink(destination: ByeTimeView(DebugStuff: $DebugStuff)) {
                        HStack {
                            Text("ByeTime 设置")
                        }
                    }
                }
                
                Section(header: Label("应用语言", systemImage: "magnifyingglass"), footer: Text("Here you can choose in what language you want the app to be. The app will automatically exit to apply changes ; feel free to launch it again.")) {
                    Picker("语言", selection: $localisation) {
                        ForEach(sortedLocalisalist, id: \.self) { abbreviation in
                            Text(languageMapping[abbreviation] ?? abbreviation)
                                .tag(abbreviation)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: localisation) { newValue in
                        if localisation.contains("en-GB") || localisation.contains("zh") || localisation.contains("es-419"){
                            let parts = localisation.components(separatedBy: "-")
                            if let appCodeLanguage = parts.last {
                                print("set custom region: \(appCodeLanguage)")
                                appSettings.languageCode = appCodeLanguage
                                UserDefaults.standard.set(["\(localisation)"], forKey: "AppleLanguages")
                            }
                        }
                        else {
                            print(localisation)
                            appSettings.languageCode = ""
                            UserDefaults.standard.set(["\(newValue)"], forKey: "AppleLanguages")
                        }
                        UIApplication.shared.confirmAlert(title: "需要退出应用才能使更改生效。", body: "请重新打开应用。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    .onAppear {
                        print(langaugee)
                        appSettings.languageCode = ""
                    }
                }
                
                
                Section(header: Label("调试选项", systemImage: "chevron.left.forwardslash.chevron.right"), footer: Text("This setting allows you to see experimental values from some app variables.")) {
                    Toggle(isOn: $DebugStuff) {
                        Text("调试信息")
                    }
                    if DebugStuff {
                        Text("Language set to : \(localisation)")
                        Button("将语言恢复为默认") {
                            UserDefaults.standard.set(["Base"], forKey: "AppleLanguages")
                            UIApplication.shared.confirmAlert(title: "需要退出应用才能使更改生效。", body: "请重新打开应用。", onOK: {
                                exitGracefully()
                            }, noCancel: true)
                        }
                        Text("UUID : \(appSettings.usrUUID)")
                        Text("RootHelper Path : \(RootHelper.whatsthePath())")
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            Text("用户是否在 iPadOS 16 的 iPad 上：是")
                        }
                        else {
                            Text("用户是否在 iPadOS 16 的 iPad 上：否")
                        }
                        Text("Safari Cache Path : \(removeFilePrefix(safariCachePath))")
                    }
                }
                
                Section(header: Label("清理器设置", systemImage: "trash"), footer: Text("清理器的各项设置。")) {
                    Toggle(isOn: $appSettings.keepCheckBoxesC) {
                        Text("清理后保留所选")
                    }
                    Toggle(isOn: $appSettings.getSizes) {
                        Text("计算可清理空间")
                    }
                    .onChange(of: appSettings.getSizes) { newValue in
                        UIApplication.shared.confirmAlert(title: "需要退出应用才能使更改生效。", body: "请重新打开应用。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    Toggle(isOn: Binding<Bool>(
                        get: { !appSettings.tmpClean },
                        set: { appSettings.tmpClean = !$0 }
                    )) {
                        Text("安全清理措施（iOS 15 请务必开启！）")
                    }
                    .onChange(of: appSettings.tmpClean) { newValue in
                        UIApplication.shared.confirmAlert(title: "需要退出应用才能使更改生效。", body: "请重新打开应用。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    
                    if DebugStuff {
                        HStack {
                            Text("最小大小：")
                            Spacer()
                            TextField("50.0 MB", text: $MinimCal)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: MinimCal) { newValue in
                                    MinimCal = newValue.replacingOccurrences(of: ",", with: ".")
                                }
                        }
                        .onAppear {
                            MinimCal = "\(appSettings.minimSizeC)"
                        }
                        .onChange(of: MinimCal) { newValue in
                            appSettings.minimSizeC = Double(MinimCal) ?? 50.0
                        }
                    }
                }
                Section(header: Label("LocSim 设置", systemImage: "location.fill.viewfinder"), footer: Text("Various settings for LocSim. Sometimes, users can encounter issues with stopping LocSim. Those settings will allow you to attempt to stop LocSim multiple time.")) {
                    Toggle(isOn: $appSettings.locSimMultipleAttempts) {
                        Text("请尝试多次停止 LocSim")
                    }
                    if appSettings.locSimMultipleAttempts {
                        HStack {
                            Text("最小尝试次数：")
                            Spacer()
                            TextField("3", text: $LocSimTries)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .onAppear {
                            LocSimTries = "\(appSettings.locSimAttemptNB)"
                        }
                        .onChange(of: LocSimTries) { newValue in
                            appSettings.locSimAttemptNB = Int(LocSimTries) ?? 1
                        }
                    }
                }
                Section(header: Label("启动设置", systemImage: "play"), footer: Text("This will personalize app start-up settings. Useful for debugging on Simulator or for betas.")
                ) {
                    Picker("默认标签页", selection: $defaultTab) {
                        ForEach(Array(defaultTabList.keys).sorted(), id: \.self) { key in
                            Text(defaultTabList[key] ?? "")
                                .tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: defaultTab) { newValue in
                        print(defaultTab)
                        appSettings.defaultTab = defaultTab
                        print(appSettings.defaultTab)
                        UIApplication.shared.confirmAlert(title: "需要退出应用才能使更改生效。", body: "请重新打开应用。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    Toggle(isOn: $appSettings.tsBypass) {
                        Text("屏蔽 TrollStore 弹窗")
                    }
                    .onChange(of: appSettings.tsBypass) { newValue in
                        AlertKitAPI.present(
                            title: "已保存！",
                            icon: .done,
                            style: .iOS17AppleMusic,
                            haptic: .success
                        )
                    }
                    Toggle(isOn: $appSettings.updBypass) {
                        Text("屏蔽应用更新弹窗")
                    }
                    .onChange(of: appSettings.updBypass) { newValue in
                        AlertKitAPI.present(
                            title: "已保存！",
                            icon: .done,
                            style: .iOS17AppleMusic,
                            haptic: .success
                        )
                    }
                    .onChange(of: appSettings.tsBypass) { newValue in
                        AlertKitAPI.present(
                            title: "已保存！",
                            icon: .done,
                            style: .iOS17AppleMusic,
                            haptic: .success
                        )
                    }
                }
                Section(header: Label("应用图标", systemImage: "app"), footer: Text("You can choose and define a custom icon proposed by the community.")
                ) {
                    Button(action: {
                        UIApplication.shared.setAlternateIconName(nil) { error in
                            if let error = error {
                                UIApplication.shared.alert(body:"\(error.localizedDescription)")
                            }
                        }
                    }) {
                        HStack {
                            Image(uiImage: Bundle.main.icon!)
                                .cornerRadius(15)
                                .frame(width: 62.5, height: 62.5)
                            VStack(alignment: .leading) {
                                Text("默认")
                                Text("by c22dev")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Button(action: {
                        UIApplication.shared.setAlternateIconName("Flore") { error in
                            if let error = error {
                                UIApplication.shared.alert(body:"\(error.localizedDescription)")
                            }
                        }
                    }) {
                        HStack {
                            if let imageURL = URL(string: "https://cclerc.ch/db/geranium/icn/Bouquet.png") {
                                AsyncImageView(url: imageURL)
                                    .cornerRadius(15)
                                    .frame(width: 62.5, height: 62.5)
                            }
                            VStack(alignment: .leading) {
                                Text("Flore")
                                Text("by PhucDo")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Button(action: {
                        UIApplication.shared.setAlternateIconName("Beta") { error in
                            if let error = error {
                                UIApplication.shared.alert(body:"\(error.localizedDescription)")
                            }
                        }
                    }) {
                        HStack {
                            if let imageURL = URL(string: "https://cclerc.ch/db/geranium/icn/Beta-2.png") {
                                AsyncImageView(url: imageURL)
                                    .cornerRadius(15)
                                    .frame(width: 62.5, height: 62.5)
                            }
                            VStack(alignment: .leading) {
                                Text("Beta")
                                Text("by c22dev")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Button(action: {
                        UIApplication.shared.setAlternateIconName("Bouquet") { error in
                            if let error = error {
                                UIApplication.shared.alert(body:"\(error.localizedDescription)")
                            }
                        }
                    }) {
                        HStack {
                            if let imageURL = URL(string: "https://cclerc.ch/db/geranium/icn/Flore.png") {
                                AsyncImageView(url: imageURL)
                                    .cornerRadius(15)
                                    .frame(width: 62.5, height: 62.5)
                            }
                            VStack(alignment: .leading) {
                                Text("Suika")
                                Text("by PhucDo")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(header: Label("日志设置", systemImage: "cloud"), footer: Text("We collect some logs that are uploaded to our server for fixing bugs and adressing crash logs. The logs never contains any of your personal information, just your device type and the crash log itself. We also collect measurement information to see what was the most used in the app. You can choose if you want to prevent ANY data from being sent to our server.")
                ) {
                    Toggle(isOn: $appSettings.loggingAllowed) {
                        Text("启用日志记录")
                    }
                    .onChange(of: appSettings.loggingAllowed) { newValue in
                        if newValue {
                            AlertKitAPI.present(
                                title: "已启用！",
                                icon: .done,
                                style: .iOS17AppleMusic,
                                haptic: .success
                            )
                        }
                        else {
                            AlertKitAPI.present(
                                title: "已禁用！",
                                icon: .done,
                                style: .iOS17AppleMusic,
                                haptic: .success
                            )
                        }
                    }
                }
                Section (header: Label("翻译人员", systemImage: "pencil"), footer: Text("感谢所有出色的翻译者！")) {
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/640759347240108061/79be8e2ce1557085a6cbb6e58b8d6182.webp?size=160", url: "https://twitter.com/CySxL", title: "CySxL", description: "🇹🇼 Chinese (Traditional)")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/620318902983065606/fe19b5c660b9e8535e884e0fe6c15dbe.webp?size=160", url: "https://twitter.com/Defflix19", title: "Defflix", description: "🇨🇿/🇸🇰 Czech & Slovak")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/984192641170276442/a4859069e955ae712a1874acd6c13fb2.webp?size=160", url: "https://twitter.com/dis667_ilya", title: "dis667", description: "🇷🇺 Russian")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/771526460413444096/aa73119afd1f7a84a5e43a4dd7345d1e.webp?size=160", url: "https://twitter.com/w0wbox", title: "w0wbox", description: "🇪🇸 Spanish (Latin America)")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/711515258732150795/622daeaddcbf09887ce40168c7de6a45.webp?size=160", url: "https://twitter.com/LeonardoIzzo_", title: "LeonardoIz", description: "🇪🇸 Spanish / 🇮🇹 Italian / Catalan")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/530721708546588692/e45b6eda6c7127f418d8ec607026bad8.webp?size=160", url: "https://twitter.com/loy64_", title: "Loy64", description: "🇦🇱 Albanian / 🇮🇹 Italian")
                    LinkCell(imageLink: "https://i.ibb.co/M53ycZw/pasmoi.webp", url: "https://cclerc.ch/pasmoi.html", title: "PasMoi", description: "🇫🇷 French")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/1090613392710062141/dbd47d708e2be6eac591419e085848a9.webp?size=160", url: "https://twitter.com/dobabaophuc", title: "Phuc Do", description: "🇻🇳 Vietnamese")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/662843309391216670/4238ed35692fc2ee1df97033b5c76bcc.webp?size=160", url: "https://twitter.com/SAUCECOMPANY_", title: "saucecompany", description: "🇰🇷 Korean")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/766292544765820958/ca2d1e7a4bd147b67146b51c349f15e0.webp?size=160", url: "https://twitter.com/speedyfriend67", title: "Speedyfriend67", description: "🇰🇷 Korean")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/607904288882294795/76b2725a7e4f0b1fa18bc2fe4938a846.webp?size=160", url: "https://twitter.com/spy_g_", title: "Spy_G", description: "🇸🇪 Swedish")
                    LinkCell(imageLink: "https://cclerc.ch/db/geranium/dTiW9yol-2.jpg", url: "https://twitter.com/straight_tamago", title: "Straight Tamago", description: "🇯🇵 Japanese")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/1183594247929208874/2bfce82426459ce7f55aeb736fd95a9f.webp?size=160", url: "https://twitter.com/Ting2021", title: "ting0441", description: "🇨🇳 Chinese (Simplified)")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/259867085453131778/685ffaefba4fce61d633f5f5434b7647.webp?size=160", url: "https://twitter.com/Alz971", title: "W$D$B", description: "🇮🇹 Italian")
                    LinkCell(imageLink: "https://cdn.discordapp.com/avatars/709644128685916185/51c2ef8ff5c774f27662753208fa0f67.webp?size=160", url: "https://twitter.com/yyyyyy_public", title: "yyyywaiwai", description: "🇯🇵 Japanese")
                }
            }
            .navigationTitle("设置")
        }
    }
}
