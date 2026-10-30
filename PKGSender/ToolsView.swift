import SwiftUI
import Network
import UniformTypeIdentifiers
import UIKit

struct ToolsView: View {
    let appLanguage: String
    let psIP: String
    @State private var showFTP = false
    private var isArabic: Bool { appLanguage == "ar" }
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    consoleCard
                    section(t("CONSOLE", "الجهاز")) {
                        NavigationLink { ConsoleInfoPage(host: psIP, isArabic: isArabic) } label: {
                            toolCard(t("Console Info", "معلومات الجهاز"), t("RPI • FTP • installed titles", "RPI • FTP • الألعاب المثبتة"), "info.circle.fill")
                        }
                    }
                    section("GOLDHEN") {
                        NavigationLink { CheatsManagerPage(host: psIP, isArabic: isArabic) } label: {
                            toolCard(t("Cheats", "الغش"), t("Games • repositories • downloads", "الألعاب • المستودعات • التنزيلات"), "wand.and.stars")
                        }
                        Button { showFTP = true } label: {
                            toolCard("GoldHEN FTP", t("Browse PS4 files • Port 2121", "تصفح ملفات PS4 • المنفذ 2121"), "externaldrive.connected.to.line.below")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 110)
            }
            .background(PKGTheme.background.ignoresSafeArea())
            .navigationTitle(t("Tools", "الأدوات"))
            .tint(.primary)
        }
        .fullScreenCover(isPresented: $showFTP) {
            FTPBrowserPage(host: psIP, isArabic: isArabic)
        }
    }

    private var consoleCard: some View {
        HStack(spacing: 14) {
            ZStack { RoundedRectangle(cornerRadius: 15).fill(PKGTheme.elevatedSurface); Image(systemName: "playstation.logo").font(.system(size: 28, weight: .semibold)).foregroundStyle(.primary) }.frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) { Text("PlayStation 4").font(.system(size: 17, weight: .semibold, design: .rounded)); Text(psIP.isEmpty ? t("IP not configured", "لم يتم إعداد IP") : psIP).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
            Spacer(); Circle().fill(psIP.isEmpty ? Color.secondary.opacity(0.35) : .green).frame(width: 8, height: 8)
        }.padding(16).background(PKGTheme.surface, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.05)))
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).padding(.horizontal, 4); content() } }
    private func toolCard(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 14) { Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.primary).frame(width: 44, height: 44).background(PKGTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 13)); VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.primary); Text(subtitle).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary) }; Spacer(); Image(systemName: isArabic ? "chevron.left" : "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }.padding(14).background(PKGTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CheatsManagerPage: View {
    let host: String; let isArabic: Bool
    @StateObject private var ftp = FTPService(); @StateObject private var repos = CheatRepositoryStore()
    @State private var games:[PS4GameInfo]=[]; @State private var online:[String:[RemoteCheat]]=[:]; @State private var installedCounts:[String:Int]=[:]
    @State private var search=""; @State private var loading=false; @State private var error:String?
    private func t(_ en:String,_ ar:String)->String{isArabic ? ar:en}
    private var filtered:[PS4GameInfo]{search.isEmpty ? games : games.filter{$0.title.localizedCaseInsensitiveContains(search)||$0.titleID.localizedCaseInsensitiveContains(search)}}
    private var enabledRepoCount:Int{repos.repositories.filter(\.enabled).count}
    private var downloadedCount:Int{CheatLocalStore.downloadedFiles().count}

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack(spacing:12) {
                    NavigationLink { RepositoriesPage(store:repos,isArabic:isArabic) } label:{ dashboardCard(title:t("Repositories","المستودعات"),value:"\(enabledRepoCount)",subtitle:t("Enabled sources","مصادر مفعلة"),icon:"shippingbox.fill") }.buttonStyle(.plain)
                    NavigationLink { DownloadedCheatsPage(host:host,isArabic:isArabic) } label:{ dashboardCard(title:t("Downloaded","التنزيلات"),value:"\(downloadedCount)",subtitle:t("Saved locally","محفوظ محلياً"),icon:"arrow.down.circle.fill") }.buttonStyle(.plain)
                }
                HStack{Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField(t("Search games or CUSA","ابحث باسم اللعبة أو CUSA"),text:$search).textInputAutocapitalization(.never)}.padding(13).background(PKGTheme.surface,in:RoundedRectangle(cornerRadius:16))
                Text(t("YOUR GAMES","ألعابك")).font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal,4)
                if loading && games.isEmpty { ProgressView(t("Reading games…","جارٍ قراءة الألعاب…")).frame(maxWidth:.infinity).padding(.top,40) }
                else if let error, games.isEmpty { errorBox(error) }
                else if filtered.isEmpty { emptyBox }
                else { LazyVStack(spacing:12){ForEach(filtered){game in NavigationLink{CheatGameDetailPage(host:host,game:game,initialCheats:online[game.titleID] ?? [],repositories:repos,isArabic:isArabic)}label:{gameCard(game)}.buttonStyle(.plain)}} }
            }.padding(16).padding(.bottom,150)
        }
        .background(PKGTheme.background.ignoresSafeArea()).navigationTitle(t("Cheats","الغش")).navigationBarTitleDisplayMode(.inline)
        .toolbar{ToolbarItem(placement:.topBarTrailing){Button{Task{await scan(showLoading:false,forceRepositories:true)}}label:{Image(systemName:"arrow.clockwise")}}}
        .task{CheatLocalStore.prepare();let cached=PS4GameCache.load();if !cached.isEmpty{games=cached;await refreshOnline();await scan(showLoading:false,forceRepositories:false)}else{await scan(showLoading:true,forceRepositories:false)}}
        .onChange(of:repos.repositories){_ in Task{await refreshOnline(force:true)}}
    }
    private func dashboardCard(title:String,value:String,subtitle:String,icon:String)->some View{VStack(alignment:.leading,spacing:10){HStack{Image(systemName:icon).font(.title3);Spacer();Image(systemName:isArabic ? "chevron.left":"chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)};Text(value).font(.system(size:28,weight:.bold,design:.rounded));VStack(alignment:.leading,spacing:2){Text(title).font(.subheadline.weight(.semibold));Text(subtitle).font(.caption2).foregroundStyle(.secondary)}}.foregroundStyle(.primary).padding(15).frame(maxWidth:.infinity,alignment:.leading).background(PKGTheme.surface,in:RoundedRectangle(cornerRadius:20))}
    private func gameCard(_ game:PS4GameInfo)->some View{HStack(spacing:14){Group{if let d=game.iconData,let ui=UIImage(data:d){Image(uiImage:ui).resizable().scaledToFill()}else{ZStack{PKGTheme.elevatedSurface;Image(systemName:"gamecontroller.fill").font(.title2).foregroundStyle(.secondary)}}}.frame(width:82,height:82).clipShape(RoundedRectangle(cornerRadius:17));VStack(alignment:.leading,spacing:5){Text(game.title).font(.system(size:17,weight:.semibold,design:.rounded)).foregroundStyle(.primary).lineLimit(2);Text(game.titleID).font(.caption.monospaced()).foregroundStyle(.secondary);HStack(spacing:6){badge("GAME",icon:"gamecontroller.fill");if !game.version.isEmpty{badge("v\(game.version)",icon:"tag.fill")}};let all=online[game.titleID] ?? [];let compatible=game.version.isEmpty ? all.count:all.filter{$0.version==game.version}.count;let stored=installedCounts[game.titleID] ?? 0;Text(compatible>0 ? "\(compatible) \(t("Compatible Cheats","شيت متوافق"))":stored>0 ? "\(stored) \(t("Stored on PS4","محفوظ على PS4"))":t("No compatible cheats","لا توجد شيتات متوافقة")).font(.caption.weight(.semibold)).foregroundStyle(compatible>0 ? .primary:.secondary)};Spacer();Image(systemName:isArabic ? "chevron.left":"chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)}.padding(13).background(PKGTheme.surface,in:RoundedRectangle(cornerRadius:22))}
    private func badge(_ text:String,icon:String)->some View{Label(text,systemImage:icon).font(.system(size:9,weight:.bold,design:.rounded)).foregroundStyle(.secondary).padding(.horizontal,7).padding(.vertical,4).background(PKGTheme.elevatedSurface,in:Capsule())}
    private func errorBox(_ text:String)->some View{VStack(spacing:12){Image(systemName:"exclamationmark.triangle.fill").font(.largeTitle);Text(text).multilineTextAlignment(.center);Button(t("Try Again","إعادة المحاولة")){Task{await scan(showLoading:games.isEmpty,forceRepositories:true)}}.buttonStyle(.bordered)}.frame(maxWidth:.infinity).padding(.top,40)}
    private var emptyBox:some View{VStack(spacing:10){Image(systemName:"gamecontroller").font(.largeTitle);Text(t("No installed CUSA games were found.","لم يتم العثور على ألعاب CUSA مثبتة."));Button(t("Scan Again","إعادة الفحص")){Task{await scan(showLoading:games.isEmpty,forceRepositories:true)}}}.frame(maxWidth:.infinity).padding(.top,40)}
    private func scan(showLoading:Bool,forceRepositories:Bool) async{if showLoading{loading=true};error=nil;await ftp.list(host:host,path:"/user/app");guard case .connected=ftp.state else{if games.isEmpty,case .failed(let e)=ftp.state{error=e};loading=false;return};let ids=ftp.entries.filter{$0.isDirectory&&$0.name.uppercased().hasPrefix("CUSA")}.map{$0.name.uppercased()}.sorted();let cachedByID=Dictionary(uniqueKeysWithValues:PS4GameCache.load().map{($0.titleID,$0)});var loaded:[PS4GameInfo]=[];for id in ids{if let c=cachedByID[id],!forceRepositories{loaded.append(c)}else{loaded.append(await readGame(id:id,cached:cachedByID[id]))}};games=loaded.sorted{$0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending};await scanInstalled();await refreshOnline(force:forceRepositories);applyRepositoryNames();PS4GameCache.save(games);loading=false}
    private func readGame(id:String,cached:PS4GameInfo?) async->PS4GameInfo{var title=cached?.title ?? id;var version=cached?.version ?? "";var icon=cached?.iconData;for path in ["/user/app/\(id)/app0/sce_sys/param.sfo","/system_data/priv/appmeta/\(id)/param.sfo","/user/appmeta/\(id)/param.sfo"] where title==id || version.isEmpty{if let data=try? await ftp.download(host:host,remotePath:path){let m=PS4SFO.parse(data);if let v=m["TITLE"],!v.isEmpty{title=v};if let v=m["APP_VER"] ?? m["VERSION"],!v.isEmpty{version=v}}};if icon==nil{for path in ["/user/appmeta/\(id)/icon0.png","/system_data/priv/appmeta/\(id)/icon0.png","/user/app/\(id)/app0/sce_sys/icon0.png"]{if let d=try? await ftp.download(host:host,remotePath:path),UIImage(data:d) != nil{icon=d;break}}};return PS4GameInfo(titleID:id,title:title,version:version,iconData:icon)}
    private func scanInstalled() async{var counts:[String:Int]=[:];for root in ["/user/data/GoldHEN/cheats/json","/user/data/GoldHEN/cheats/shn","/user/data/GoldHEN/cheats/mc4"]{await ftp.list(host:host,path:root);guard case .connected=ftp.state else{continue};for e in ftp.entries where !e.isDirectory{let n=e.name.uppercased();for g in games where n.contains(g.titleID){counts[g.titleID,default:0]+=1}}};installedCounts=counts}
    private func refreshOnline(force:Bool=false) async{let all=await CheatRepositoryClient.allCheats(repositories:repos.repositories,forceRefresh:force);online=Dictionary(grouping:all.filter{$0.titleID.uppercased().hasPrefix("CUSA")},by:{$0.titleID.uppercased()});applyRepositoryNames()}
    private func applyRepositoryNames(){var u=games;for i in u.indices where u[i].title==u[i].titleID{if let name=online[u[i].titleID]?.map(\.gameName).first(where:{!$0.isEmpty&&$0.caseInsensitiveCompare(u[i].titleID) != .orderedSame}){u[i].title=name}};games=u.sorted{$0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending}}
}

private struct CheatGameDetailPage: View {
    let host:String;let game:PS4GameInfo;let initialCheats:[RemoteCheat];@ObservedObject var repositories:CheatRepositoryStore;let isArabic:Bool
    @StateObject private var ftp=FTPService();@State private var cheats:[RemoteCheat]=[];@State private var installed=Set<String>();@State private var busy:String?;@State private var message:String?;@State private var showOther=false
    private func t(_ en:String,_ ar:String)->String{isArabic ? ar:en}
    private var compatible:[RemoteCheat]{dedupe(game.version.isEmpty ? cheats:cheats.filter{$0.version==game.version})}
    private var other:[RemoteCheat]{dedupe(game.version.isEmpty ? []:cheats.filter{$0.version != game.version})}
    private var otherVersions:[String]{Array(Set(other.map{$0.version})).sorted()}
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:18){hero;sectionTitle(t("COMPATIBLE WITH YOUR VERSION","متوافق مع إصدارك"));if compatible.isEmpty{Text(t("No exact CUSA + version match was found.","لا يوجد تطابق دقيق مع CUSA وإصدار اللعبة.")).foregroundStyle(.secondary).padding(16).frame(maxWidth:.infinity,alignment:.leading).background(PKGTheme.surface,in:RoundedRectangle(cornerRadius:18))}else{VStack(spacing:1){ForEach(compatible){cheatRow($0)}}.clipShape(RoundedRectangle(cornerRadius:20))};if !other.isEmpty{Button{withAnimation(.easeInOut(duration:0.2)){showOther.toggle()}}label:{HStack{VStack(alignment:.leading,spacing:3){Text(t("Other Versions","إصدارات أخرى")).font(.headline);Text("\(otherVersions.count) \(t("versions •","إصدار •")) \(other.count) \(t("cheats","شيت"))").font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:showOther ? "chevron.up":"chevron.down")}.foregroundStyle(.primary).padding(16).background(PKGTheme.surface,in:RoundedRectangle(cornerRadius:18))}.buttonStyle(.plain);if showOther{VStack(spacing:1){ForEach(other){cheatRow($0)}}.clipShape(RoundedRectangle(cornerRadius:20))}}}.padding(16).padding(.bottom,150)}.background(PKGTheme.background.ignoresSafeArea()).navigationTitle(game.title).navigationBarTitleDisplayMode(.inline).task{cheats=initialCheats.isEmpty ? await CheatRepositoryClient.cheats(for:game.titleID,repositories:repositories.repositories):initialCheats;await refreshInstalled()}.alert("Cheats",isPresented:Binding(get:{message != nil},set:{if !$0{message=nil}})){Button("OK"){message=nil}}message:{Text(message ?? "")}}
    private var hero:some View{HStack(spacing:16){Group{if let d=game.iconData,let ui=UIImage(data:d){Image(uiImage:ui).resizable().scaledToFill()}else{ZStack{PKGTheme.elevatedSurface;Image(systemName:"gamecontroller.fill").font(.title)}}}.frame(width:92,height:92).clipShape(RoundedRectangle(cornerRadius:20));VStack(alignment:.leading,spacing:6){Text(game.title).font(.title3.bold()).lineLimit(2);Text(game.titleID).font(.caption.monospaced()).foregroundStyle(.secondary);if !game.version.isEmpty{Label("v\(game.version)",systemImage:"checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)};Text("\(compatible.count) \(t("compatible cheats","شيت متوافق"))").font(.caption.weight(.semibold))};Spacer()}.padding(14).background(PKGTheme.surface,in:RoundedRectangle(cornerRadius:24))}
    private func sectionTitle(_ s:String)->some View{Text(s).font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal,4)}
    private func cheatRow(_ c:RemoteCheat)->some View{let downloaded=CheatLocalStore.isDownloaded(c);let stored=installed.contains(c.fileName.lowercased());let exact=game.version.isEmpty||c.version==game.version;return HStack(spacing:12){VStack(alignment:.leading,spacing:4){Text(c.gameName.isEmpty ? c.repositoryName:c.gameName).font(.subheadline.weight(.semibold)).lineLimit(1);Text("\(c.repositoryName) • v\(c.version) • \(c.format.uppercased())").font(.caption2.monospaced()).foregroundStyle(.secondary);if stored{Label(exact ? t("Installed on PS4","مثبت على PS4"):t("Stored on PS4","محفوظ على PS4"),systemImage:exact ? "checkmark.circle.fill":"internaldrive.fill").font(.caption.weight(.semibold)).foregroundStyle(exact ? .green:.secondary)}};Spacer();if !stored{Button{Task{downloaded ? await install(c):await download(c)}}label:{if busy==c.id{ProgressView().controlSize(.small)}else{Image(systemName:downloaded ? "arrow.up.to.line":"arrow.down.to.line").frame(width:32,height:32)}}.buttonStyle(.bordered).tint(.primary).disabled(busy != nil)}}.padding(13).background(PKGTheme.surface)}
    private func dedupe(_ input:[RemoteCheat])->[RemoteCheat]{var seen=Set<String>();return input.filter{seen.insert("\($0.titleID.lowercased())|\($0.version.lowercased())|\($0.format.lowercased())|\($0.fileName.lowercased())").inserted}}
    private func download(_ c:RemoteCheat)async{busy=c.id;defer{busy=nil};do{let d=try await CheatRepositoryClient.download(c);try CheatLocalStore.save(d,cheat:c)}catch{message=error.localizedDescription}}
    private func install(_ c:RemoteCheat)async{busy=c.id;defer{busy=nil};do{let u=CheatLocalStore.url(for:c);try await ftp.upload(host:host,localURL:u,remotePath:"/user/data/GoldHEN/cheats/\(c.format)/\(c.fileName)");await refreshInstalled()}catch{message=error.localizedDescription}}
    private func refreshInstalled()async{var names=Set<String>();for root in ["/user/data/GoldHEN/cheats/json","/user/data/GoldHEN/cheats/shn","/user/data/GoldHEN/cheats/mc4"]{await ftp.list(host:host,path:root);if case .connected=ftp.state{for e in ftp.entries where !e.isDirectory{names.insert(e.name.lowercased())}}};installed=names}
}

private struct RepositoriesPage:View{@ObservedObject var store:CheatRepositoryStore;let isArabic:Bool;@State private var adding=false;private func t(_ en:String,_ ar:String)->String{isArabic ? ar:en};var body:some View{ScrollView{VStack(alignment:.leading,spacing:14){Text(t("CHEAT SOURCES","مصادر الشيتات")).font(.caption.bold()).foregroundStyle(.secondary);ForEach(store.repositories){r in HStack(spacing:12){Image(systemName:r.isDefault ? "checkmark.shield.fill":"shippingbox.fill").font(.title3).frame(width:42,height:42).background(PKGTheme.elevatedSurface,in:RoundedRectangle(cornerRadius:12));VStack(alignment:.leading,spacing:4){HStack{Text(r.name).font(.headline);if r.isDefault{Text("DEFAULT").font(.system(size:9,weight:.bold)).padding(.horizontal,6).padding(.vertical,3).background(PKGTheme.elevatedSurface,in:Capsule())}};Text(r.isDefault ? t("Official built-in source","مصدر رسمي مدمج"):"GitHub • \(t("Added by you","أضفته أنت"))").font(.caption).foregroundStyle(.secondary)};Spacer();Toggle("",isOn:Binding(get:{r.enabled},set:{_ in store.toggle(r.id)})).labelsHidden()}.padding(14).background(PKGTheme.surface,in:RoundedRectangle(cornerRadius:20)).contextMenu{if !r.isDefault{Button(role:.destructive){if let i=store.repositories.firstIndex(where:{$0.id==r.id}){store.remove(at:IndexSet(integer:i))}}label:{Label(t("Delete","حذف"),systemImage:"trash")}}}};Button{adding=true}label:{Label(t("Add Repository","إضافة مستودع"),systemImage:"plus.circle.fill").font(.headline).frame(maxWidth:.infinity).padding(.vertical,10)}.buttonStyle(.bordered).tint(.primary)}.padding(16).padding(.bottom,120)}.background(PKGTheme.background.ignoresSafeArea()).navigationTitle(t("Repositories","المستودعات")).navigationBarTitleDisplayMode(.inline).sheet(isPresented:$adding){NavigationStack{AddRepositoryPage(store:store,isArabic:isArabic)}}}}

private struct AddRepositoryPage:View{@ObservedObject var store:CheatRepositoryStore;let isArabic:Bool;@Environment(\.dismiss)private var dismiss;@State private var url="";@State private var checking=false;@State private var result:CheatRepositoryClient.RepoCheck?;@State private var error:String?;private func t(_ en:String,_ ar:String)->String{isArabic ? ar:en};var body:some View{Form{Section(t("Repository URL","رابط المستودع")){TextField("https://github.com/owner/repository",text:$url).textInputAutocapitalization(.never).autocorrectionDisabled();Button{Task{await check()}}label:{checking ? AnyView(ProgressView()):AnyView(Label(t("Check Repository","فحص المستودع"),systemImage:"checkmark.shield"))}.disabled(url.isEmpty||checking)};if let r=result{Section{Label(t("Compatible Repository","مستودع متوافق"),systemImage:"checkmark.circle.fill").foregroundStyle(.green);Text(r.name);Text("\(r.cheatCount) \(t("supported cheat files found","ملف شيت مدعوم"))").font(.caption).foregroundStyle(.secondary);Button(t("Add Repository","إضافة المستودع")){store.add(CheatRepository(id:UUID(),name:r.name,url:url.trimmingCharacters(in:.whitespacesAndNewlines),enabled:true,isDefault:false));dismiss()}}};if let error{Section{Label(error,systemImage:"exclamationmark.triangle.fill")}}}.navigationTitle(t("Add Repository","إضافة مستودع")).navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.cancellationAction){Button(t("Cancel","إلغاء")){dismiss()}}}};private func check()async{checking=true;result=nil;error=nil;defer{checking=false};do{result=try await CheatRepositoryClient.validate(urlString:url)}catch{self.error=error.localizedDescription}}}

private struct DownloadedCheatsPage: View {
    let host: String
    let isArabic: Bool

    @StateObject private var ftp = FTPService()
    @State private var files: [URL] = []
    @State private var message: String?

    private func t(_ en: String, _ ar: String) -> String {
        isArabic ? ar : en
    }

    private var groups: [String: [URL]] {
        Dictionary(grouping: files) { url in
            url.lastPathComponent
                .uppercased()
                .split(separator: "_")
                .first
                .map(String.init) ?? "OTHER"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if files.isEmpty {
                    emptyState
                } else {
                    DownloadedCheatGroups(
                        groups: groups,
                        isArabic: isArabic,
                        onInstall: install,
                        onDelete: delete
                    )
                }
            }
            .padding(16)
            .padding(.bottom, 140)
        }
        .background(PKGTheme.background.ignoresSafeArea())
        .navigationTitle(t("Downloaded", "التنزيلات"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .alert("Cheats", isPresented: messageBinding) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.secondary)

            Text(t("No Downloads", "لا توجد تنزيلات"))
                .font(.headline)

            Text(t(
                "Downloaded cheats will stay here for offline reinstall.",
                "الشيتات المنزلة ستبقى هنا لإعادة التثبيت."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )
    }

    private func reload() {
        CheatLocalStore.prepare()
        files = CheatLocalStore.downloadedFiles()
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    private func install(_ url: URL) async {
        let ext = url.pathExtension.lowercased()
        guard ["json", "shn", "mc4"].contains(ext) else { return }
        do {
            try await ftp.upload(
                host: host,
                localURL: url,
                remotePath: "/user/data/GoldHEN/cheats/\(ext)/\(url.lastPathComponent)"
            )
            message = t("Installed on PS4.", "تم التثبيت على PS4.")
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct DownloadedCheatGroups: View {
    let groups: [String: [URL]]
    let isArabic: Bool
    let onInstall: (URL) async -> Void
    let onDelete: (URL) -> Void

    var body: some View {
        ForEach(groups.keys.sorted(), id: \.self) { key in
            VStack(alignment: .leading, spacing: 8) {
                Text(key)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                VStack(spacing: 1) {
                    ForEach(groups[key] ?? [], id: \.path) { url in
                        DownloadedCheatRow(
                            url: url,
                            isArabic: isArabic,
                            onInstall: onInstall,
                            onDelete: onDelete
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
    }
}

private struct DownloadedCheatRow: View {
    let url: URL
    let isArabic: Bool
    let onInstall: (URL) async -> Void
    let onDelete: (URL) -> Void

    private func t(_ en: String, _ ar: String) -> String {
        isArabic ? ar : en
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(url.pathExtension.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await onInstall(url) }
            } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
        .padding(12)
        .background(PKGTheme.surface)
        .contextMenu {
            Button(role: .destructive) {
                onDelete(url)
            } label: {
                Label(t("Delete", "حذف"), systemImage: "trash")
            }
        }
    }
}

@MainActor
private final class FTPTransferState: ObservableObject {
    @Published var title = ""
    @Published var fileName = ""
    @Published var completed: UInt64 = 0
    @Published var total: UInt64 = 0
    @Published var startedAt = Date()
    @Published var active = false

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    var speedText: String {
        let elapsed = max(0.25, Date().timeIntervalSince(startedAt))
        let speed = Double(completed) / elapsed
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    func begin(title: String, fileName: String, total: UInt64) {
        self.title = title
        self.fileName = fileName
        self.total = total
        completed = 0
        startedAt = Date()
        active = true
    }

    func update(_ bytes: UInt64) { completed = bytes }
    func finish() { active = false }
}

private struct InteractivePopDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Controller() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Controller: UIViewController {
        private weak var popGesture: UIGestureRecognizer?
        private var previousEnabled = true

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            popGesture = gesture
            previousEnabled = gesture.isEnabled
            gesture.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            popGesture?.isEnabled = previousEnabled
        }
    }
}

private struct FTPBrowserPage: View {
    let host: String
    let isArabic: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ftp = FTPService()
    @StateObject private var transfer = FTPTransferState()
    @State private var path = "/"
    @State private var picker = false
    @State private var message: String?
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var renameEntry: FTPEntry?
    @State private var renameText = ""
    @State private var uploadQueue: [String] = []
    @State private var uploadIndex = 0

    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }

    var body: some View {
        ZStack {
            PKGTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ftpHeader
                pathBar
                if transfer.active { transferCard }
                content
            }
        }
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onEnded { value in
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    let backSwipe = isArabic ? value.translation.width < -55 : value.translation.width > 55
                    if horizontal && backSwipe && path != "/" { goUp() }
                }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) { ftpControlCapsule }
        .task { await load("/") }
        .sheet(isPresented: $picker) {
            PKGDocumentPicker(contentTypes: [.item], allowsMultipleSelection: true) { urls in
                picker = false
                guard !urls.isEmpty else { return }
                Task { await upload(urls) }
            }
        }
        .alert(t("New Folder", "مجلد جديد"), isPresented: $newFolder) {
            TextField(t("Folder name", "اسم المجلد"), text: $folderName)
            Button(t("Create", "إنشاء")) { Task { await createFolder() } }
            Button(t("Cancel", "إلغاء"), role: .cancel) { }
        }
        .alert(t("Rename", "إعادة تسمية"), isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
            TextField(t("New name", "الاسم الجديد"), text: $renameText)
            Button(t("Save", "حفظ")) { Task { await rename() } }
            Button(t("Cancel", "إلغاء"), role: .cancel) { renameEntry = nil }
        }
        .alert("FTP", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private var ftpHeader: some View {
        HStack(alignment: .center) {
            Text("GoldHEN FTP")
                .font(.system(size: 31, weight: .bold, design: .rounded))
            Spacer()
            Button { Task { await load(path) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(PKGTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var pathBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("CURRENT PATH", "المسار الحالي"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(ftp.currentPath.isEmpty ? path : ftp.currentPath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var ftpControlCapsule: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 48, height: 48)
            }
            Spacer(minLength: 4)
            Menu {
                Button { picker = true } label: { Label(t("Upload Files", "رفع ملفات"), systemImage: "doc.badge.plus") }
                Button { folderName = ""; newFolder = true } label: { Label(t("New Folder", "مجلد جديد"), systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 52, height: 48)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
            }
            Spacer(minLength: 4)
            Button { if path != "/" { goUp() } } label: {
                Image(systemName: isArabic ? "arrow.right" : "arrow.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 48, height: 48)
                    .opacity(path == "/" ? 0.30 : 1)
            }
            .disabled(path == "/")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 224)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        .padding(.bottom, 8)
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: transfer.title == t("Downloading", "جارٍ التنزيل") ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.title).font(.caption.weight(.semibold))
                    Text(transfer.fileName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if uploadQueue.count > 1 && transfer.title == t("Uploading", "جارٍ الرفع") {
                        Text("\(uploadIndex + 1) / \(uploadQueue.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if transfer.total > 0 { Text("\(Int(transfer.fraction * 100))%").font(.caption.monospacedDigit().weight(.semibold)) }
            }
            ProgressView(value: Double(transfer.completed), total: Double(max(transfer.total, 1)))
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(transfer.completed), countStyle: .file))
                if transfer.total > 0 {
                    Text("/ " + ByteCountFormatter.string(fromByteCount: Int64(transfer.total), countStyle: .file))
                }
                Spacer()
                Text(transfer.speedText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(PKGTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if case .connecting = ftp.state {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .failed(let error) = ftp.state {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                Text(error).multilineTextAlignment(.center)
                Button(t("Try Again", "إعادة المحاولة")) { Task { await load(path) } }.buttonStyle(.bordered)
            }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if path != "/" { Button { goUp() } label: { Label("..", systemImage: "arrow.turn.up.left") } }
                ForEach(ftp.entries) { entry in
                    Button {
                        if entry.isDirectory { Task { await load(join(path, entry.name)) } }
                    } label: {
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).foregroundStyle(.primary)
                                if let size = entry.size, !entry.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if entry.isDirectory { Image(systemName: isArabic ? "chevron.left" : "chevron.right").foregroundStyle(.tertiary) }
                        }
                    }
                    .contextMenu {
                        if !entry.isDirectory {
                            Button { Task { await download(entry) } } label: { Label(t("Download to iPhone", "تنزيل إلى الآيفون"), systemImage: "arrow.down.to.line") }
                        }
                        Button { renameEntry = entry; renameText = entry.name } label: { Label(t("Rename", "إعادة تسمية"), systemImage: "pencil") }
                        Button(role: .destructive) { Task { await remove(entry) } } label: { Label(t("Delete", "حذف"), systemImage: "trash") }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PKGTheme.background)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 108) }
        }
    }

    private func load(_ requestedPath: String) async { path = requestedPath; await ftp.list(host: host, path: requestedPath) }
    private func goUp() { let parent = (path as NSString).deletingLastPathComponent; Task { await load(parent.isEmpty ? "/" : parent) } }
    private func join(_ base: String, _ name: String) -> String { base == "/" ? "/" + name : base + "/" + name }

    private func upload(_ urls: [URL]) async {
        uploadQueue = urls.map(\.lastPathComponent)
        uploadIndex = 0
        for (index, url) in urls.enumerated() {
            uploadIndex = index
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let total = UInt64(max(0, values?.fileSize ?? 0))
            transfer.begin(title: t("Uploading", "جارٍ الرفع"), fileName: url.lastPathComponent, total: total)
            do {
                let state = transfer
                try await ftp.upload(host: host, localURL: url, remotePath: join(path, url.lastPathComponent)) { sent in
                    Task { @MainActor in state.update(sent) }
                }
            } catch {
                transfer.finish(); message = error.localizedDescription; break
            }
        }
        transfer.finish()
        uploadQueue = []
        uploadIndex = 0
        await ftp.list(host: host, path: path)
    }

    private func download(_ entry: FTPEntry) async {
        transfer.begin(title: t("Downloading", "جارٍ التنزيل"), fileName: entry.name, total: entry.size ?? 0)
        do {
            let state = transfer
            let data = try await ftp.download(host: host, remotePath: join(path, entry.name)) { received in
                Task { @MainActor in state.update(received) }
            }
            let root = try FTPDownloadStore.root()
            let output = root.appendingPathComponent(entry.name)
            try data.write(to: output, options: .atomic)
            transfer.finish()
            message = "\(t("Saved to PKG Sender/Downloads", "تم الحفظ في PKG Sender/Downloads"))\n\(entry.name)"
        } catch {
            transfer.finish(); message = error.localizedDescription
        }
    }

    private func createFolder() async {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { message = t("Use a folder name without /", "اكتب اسم المجلد بدون /"); return }
        do {
            try await ftp.createDirectory(host: host, remotePath: join(path, name))
            await ftp.list(host: host, path: path)
        } catch { message = error.localizedDescription }
    }

    private func rename() async {
        guard let entry = renameEntry else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entry.name else { renameEntry = nil; return }
        do {
            try await ftp.rename(host: host, from: join(path, entry.name), to: join(path, name))
            renameEntry = nil
            await ftp.list(host: host, path: path)
        } catch { message = error.localizedDescription; renameEntry = nil }
    }

    private func remove(_ entry: FTPEntry) async {
        do {
            try await ftp.delete(host: host, remotePath: join(path, entry.name), isDirectory: entry.isDirectory)
            await ftp.list(host: host, path: path)
        } catch { message = error.localizedDescription }
    }
}

private enum FTPDownloadStore{static func root()throws->URL{let fm=FileManager.default;let docs=try fm.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true);let root=docs.appendingPathComponent("PKG Sender",isDirectory:true).appendingPathComponent("Downloads",isDirectory:true);try fm.createDirectory(at:root,withIntermediateDirectories:true);return root}}


private struct ConsoleInfoPage: View {
    let host: String
    let isArabic: Bool

    @StateObject private var ftp = FTPService()
    @State private var rpi: Bool?
    @State private var ftpOK: Bool?
    @State private var binLoader: Bool?
    @State private var klog: Bool?
    @State private var titles: Int?
    @State private var ftpBanner: String?
    @State private var checking = false

    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                systemSection
                librarySection
                servicesSection
            }
            .padding(16)
            .padding(.bottom, 28)
        }
        .background(PKGTheme.background.ignoresSafeArea())
        .navigationTitle(t("Console Info", "معلومات الجهاز"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.07))
                Image(systemName: "playstation.logo").font(.system(size: 34, weight: .semibold))
            }
            .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text("PlayStation 4").font(.title3.bold())
                Text(host.isEmpty ? "—" : host).font(.caption.monospaced()).foregroundStyle(.secondary)
                Label(ftpOK == true ? t("Connected", "متصل") : t("Checking console", "جارٍ فحص الجهاز"), systemImage: ftpOK == true ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ftpOK == true ? .green : .secondary)
            }
            Spacer()
            Button { Task { await refresh() } } label: {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.07)).frame(width: 40, height: 40)
                    if checking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)) }
                }
            }
            .buttonStyle(.plain)
            .disabled(checking)
            .accessibilityLabel(t("Refresh Console Info", "تحديث معلومات الجهاز"))
        }
        .padding(16)
        .background(PKGTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var systemSection: some View {
        infoSection(t("SYSTEM", "النظام")) {
            infoLine("GoldHEN FTP", cleanedBanner, "server.rack")
            Divider()
            infoLine(t("Console Address", "عنوان الجهاز"), host.isEmpty ? "—" : host, "network")
        }
    }

    private var librarySection: some View {
        infoSection(t("LIBRARY", "المكتبة")) {
            infoLine(t("Installed CUSA Titles", "ألعاب CUSA المثبتة"), titles.map(String.init) ?? "—", "gamecontroller.fill")
        }
    }

    private var servicesSection: some View {
        infoSection(t("SERVICES", "الخدمات")) {
            serviceLine("Remote Package Installer", port: 12800, state: rpi)
            Divider()
            serviceLine("GoldHEN FTP", port: 2121, state: ftpOK)
            Divider()
            serviceLine("BinLoader", port: 9090, state: binLoader)
            Divider()
            serviceLine("Klog", port: 3232, state: klog)
        }
    }

    private var cleanedBanner: String {
        guard let ftpBanner, !ftpBanner.isEmpty else { return ftpOK == true ? t("Online", "متصل") : "—" }
        return ftpBanner.replacingOccurrences(of: "220 ", with: "")
    }

    private func infoSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 10) { content() }
                .padding(14)
                .background(PKGTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func infoLine(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func serviceLine(_ title: String, port: UInt16, state: Bool?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state == true ? "checkmark.circle.fill" : state == false ? "xmark.circle.fill" : "minus.circle")
                .foregroundStyle(state == true ? .green : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("TCP \(port)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state == true ? t("Online", "متصل") : state == false ? t("Offline", "غير متصل") : "—")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        checking = true
        async let a = TCPProbe.check(host: host, port: 12800)
        async let b = TCPProbe.check(host: host, port: 2121)
        async let c = TCPProbe.check(host: host, port: 9090)
        async let d = TCPProbe.check(host: host, port: 3232)
        let states = await (a, b, c, d)
        rpi = states.0; ftpOK = states.1; binLoader = states.2; klog = states.3

        if states.1 {
            ftpBanner = try? await ftp.serverBanner(host: host)
            await ftp.list(host: host, path: "/user/app")
            if case .connected = ftp.state {
                titles = ftp.entries.filter { $0.isDirectory && $0.name.uppercased().hasPrefix("CUSA") }.count
            }
        } else {
            ftpBanner = nil
            titles = nil
        }
        checking = false
    }
}

private actor TCPProbeGate {
    private var finished = false
    func claim() -> Bool {
        guard !finished else { return false }
        finished = true
        return true
    }
}

private enum TCPProbe {
    static func check(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let p = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let queue = DispatchQueue(label: "PKGSender.Probe.\(port)")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let gate = TCPProbeGate()

            let finish: @Sendable (Bool) -> Void = { value in
                Task {
                    guard await gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                case .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.5) { finish(false) }
        }
    }
}
