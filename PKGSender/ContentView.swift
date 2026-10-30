import SwiftUI
import UIKit
import Network

// ======================================================
// MARK: - Transfer History Model
// ======================================================

enum TransferMode: String {
    case wifi
    case usb
}

struct TransferHistoryItem: Identifiable, Codable {

    let id: UUID
    let fileName: String
    let totalBytes: UInt64
    let transferredBytes: UInt64
    let averageSpeed: Double
    let peakSpeed: Double?
    let duration: Double
    let date: Date
    let completed: Bool
    // Added in vNext. Optional fields keep old saved history fully compatible.
    let batchID: UUID?
    let title: String?
    let titleID: String?
    let contentID: String?
    let version: String?
    let packageKind: String?
    let iconData: Data?
    let transferType: String?

    init(
        id: UUID = UUID(),
        fileName: String,
        totalBytes: UInt64,
        transferredBytes: UInt64,
        averageSpeed: Double,
        peakSpeed: Double? = nil,
        duration: Double,
        date: Date = Date(),
        completed: Bool,
        batchID: UUID? = nil,
        title: String? = nil,
        titleID: String? = nil,
        contentID: String? = nil,
        version: String? = nil,
        packageKind: String? = nil,
        iconData: Data? = nil,
        transferType: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.averageSpeed = averageSpeed
        self.peakSpeed = peakSpeed
        self.duration = duration
        self.date = date
        self.completed = completed
        self.batchID = batchID
        self.title = title
        self.titleID = titleID
        self.contentID = contentID
        self.version = version
        self.packageKind = packageKind
        self.iconData = iconData
        self.transferType = transferType
    }
}


// ======================================================
// MARK: - History Store
// ======================================================

final class TransferHistoryStore: ObservableObject {

    @Published var items: [TransferHistoryItem] = []

    private let key = "transferHistory"

    init() {
        load()
    }

    func add(_ item: TransferHistoryItem) {

        items.insert(item, at: 0)

        save()
    }

    func clear() {

        items.removeAll()

        save()
    }

    private func save() {

        do {

            let data = try JSONEncoder()
                .encode(items)

            UserDefaults.standard
                .set(data, forKey: key)

        } catch {

            print(
                "History save error: \(error)"
            )
        }
    }

    private func load() {

        guard
            let data = UserDefaults.standard
                .data(forKey: key)
        else {
            return
        }

        do {

            items = try JSONDecoder()
                .decode(
                    [TransferHistoryItem].self,
                    from: data
                )

        } catch {

            print(
                "History load error: \(error)"
            )
        }
    }
}



// ======================================================
// MARK: - PKG Queue Model
// ======================================================

struct PKGQueueItem: Identifiable {
    let id = UUID()
    let url: URL
    var metadata: PKGMetadata?
    var metadataError: String?
    var isReadingMetadata: Bool = true
    var fileSize: UInt64 = 0
}

// ======================================================
// MARK: - Content View
// ======================================================

struct ContentView: View {

    // MARK: Saved Settings

    @AppStorage("appLanguage")
    private var appLanguage = "en"

    @AppStorage("playStationIP")
    private var psIP = ""

    @AppStorage("playStationPort")
    private var psPort = "12800"

    @AppStorage("hasCompletedFirstLaunch")
    private var hasCompletedFirstLaunch = false

    @StateObject
    private var historyStore =
        TransferHistoryStore()

    @StateObject
    private var libraryStore =
        LibraryStore()

    private var isArabic: Bool {
        appLanguage == "ar"
    }

    private var layoutDirection: LayoutDirection {
        isArabic
        ? .rightToLeft
        : .leftToRight
    }

    // MARK: Connection

    enum ConnectionState {
        case notChecked
        case checking
        case connected
        case disconnected
    }

    @State
    private var connectionState:
        ConnectionState = .notChecked

    @State private var checkedIP = ""
    @State private var checkedPort = ""

    @State private var transferMode: TransferMode = .wifi

    // MARK: File / Server

    @State private var selectedFile: URL?
    @State private var selectedMetadata: PKGMetadata?
    @State private var isReadingMetadata = false
    @State private var metadataError: String?
    @State private var packageQueue: [PKGQueueItem] = []
    @State private var activeQueueIndex: Int? = nil
    @State private var queueRunning = false
    @State private var queueCompletedItemIDs: Set<UUID> = []
    @State private var queueItemProgress: [UUID: Double] = [:]
    @State private var queueItemSpeed: [UUID: Double] = [:]
    @State private var queueItemSentBytes: [UUID: UInt64] = [:]
    @State private var queueItemTotalBytes: [UUID: UInt64] = [:]
    @State private var server: (any PKGHTTPServing)?

    @State private var status = ""
    @State private var showFilePicker = false
    @State private var pickerAddsToQueue = false
    @State private var overlayPackageGroupKey: String? = nil
    @State private var expandedPackageItems: Set<UUID> = []
    @State private var visiblePackageDetails: Set<UUID> = []
    @Namespace private var packageOverlayNamespace
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showLibrary = false

    // MARK: Transfer

    @State private var progress: Double = 0
    @State private var sentBytes: UInt64 = 0
    @State private var totalBytes: UInt64 = 0
    @State private var speed: Double = 0
    @State private var remainingSeconds: Double?
    @State private var isTransferQueueExpanded = false

    @State private var isSending = false
    @State private var completed = false
    @State private var wasCancelled = false

    // MARK: History Tracking

    @State private var transferStartDate: Date?
    @State private var speedSamplesTotal: Double = 0
    @State private var speedSamplesCount: Int = 0
    @State private var peakSpeed: Double = 0
    @State private var showCancelConfirmation = false
    @State private var historySavedForTransfer = false
    @State private var currentHistoryBatchID: UUID?

    @State private var selectedMainTab: PKGMainTab = .home
    @State private var libraryDetailsPackages: [LibraryPackage]? = nil

    var body: some View {
        Group {
            Group {
                switch selectedMainTab {
                case .home:
                    homeTab
                case .history:
                    HistoryView(store: historyStore, appLanguage: appLanguage)
                case .library:
                    LibraryView(
                        store: libraryStore,
                        appLanguage: appLanguage,
                        psIP: psIP,
                        detailsPackages: $libraryDetailsPackages,
                        historyItems: historyStore.items,
                        transferMode: $transferMode,
                        onSendPackage: { package in sendLibraryPackage(package) },
                        onQueuePackage: { package in queueLibraryPackage(package) },
                        onGoHome: {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                libraryDetailsPackages = nil
                                selectedMainTab = .home
                            }
                        },
                        isPackageSent: { package in libraryPackageWasSent(package) },
                        isPackageQueued: { package in libraryPackageIsQueued(package) }
                    )
                case .tools:
                    ToolsView(appLanguage: appLanguage, psIP: psIP)
                case .settings:
                    SettingsView(appLanguage: $appLanguage, psPort: $psPort)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if libraryDetailsPackages == nil {
                PKGBottomTabBar(selectedTab: $selectedMainTab, isArabic: isArabic)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
        .environment(\.layoutDirection, layoutDirection)
        .blur(radius: hasCompletedFirstLaunch ? 0 : 8)
        .allowsHitTesting(hasCompletedFirstLaunch)
        .overlay {
            if !hasCompletedFirstLaunch {
                FirstLaunchView(appLanguage: $appLanguage) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        hasCompletedFirstLaunch = true
                    }
                }
                .transition(.opacity)
            }
        }
        .overlay {
            packageQueueOverlay
        }
        .overlay {
            cancelConfirmationOverlay
        }
    }

    private var homeTab: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    UnifiedPageHeader(
                        title: t("Home", "الرئيسية"),
                        subtitle: "PKG Sender"
                    )
                    transferModeCard
                    if transferMode == .usb { usbPayloadStatusCard }
                    if transferMode == .wifi {
                        connectionCard
                    }
                    fileCard

                    if isSending || progress > 0 || wasCancelled {
                        transferCard
                    }

                    if isSending {
                        cancelButton
                    } else {
                        sendButton
                    }

                    statusCard
                    Color.clear.frame(height: 104)
                }
                .padding()
            }
            .background(PKGTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $showFilePicker) {
                PKGDocumentPicker { urls in
                    handlePickedPackages(urls, append: pickerAddsToQueue)
                    pickerAddsToQueue = false
                    showFilePicker = false
                }
            }
            .onAppear {
                if status.isEmpty {
                    status = t(
                        "Enter your PlayStation IP and check the connection.",
                        "\u{623}\u{62F}\u{62E}\u{644} IP \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{62B}\u{645} \u{627}\u{641}\u{62D}\u{635} \u{627}\u{644}\u{627}\u{62A}\u{635}\u{627}\u{644}."
                    )
                }
            }
            .onChange(of: appLanguage) { _ in updateStatusForLanguage() }
            .onChange(of: psIP) { _ in
                guard !isSending else { return }
                resetConnectionCheck()
            }
            .onChange(of: psPort) { _ in
                guard !isSending else { return }
                resetConnectionCheck()
            }
            .onChange(of: isSending) { sending in
                UIApplication.shared.isIdleTimerDisabled = sending
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    @ViewBuilder
    private var cancelConfirmationOverlay: some View {
        if showCancelConfirmation {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showCancelConfirmation = false
                        }
                    }

                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 46, height: 46)
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.red)
                    }

                    VStack(spacing: 6) {
                        Text(t("Stop this transfer?", "إيقاف هذا النقل؟"))
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text(t(
                            "The current transfer will stop and cannot be resumed from PKG Sender.",
                            "سيتوقف النقل الحالي ولا يمكن استكماله من PKG Sender."
                        ))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    }

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showCancelConfirmation = false
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.right.circle.fill")
                            Text(t("Keep Transfer Running", "الإبقاء على النقل"))
                        }
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(Color.accentColor)
                        )
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showCancelConfirmation = false
                        cancelTransfer()
                    } label: {
                        Text(t("Cancel Transfer", "إلغاء النقل"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
                .frame(maxWidth: 330)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(PKGTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .zIndex(1000)
        }
    }

    // ======================================================
    // MARK: - PlayStation Card
    // ======================================================

    private var transferModeCard: some View {
        HStack(spacing: 8) {
            modeButton(.wifi, title: t("Wi-Fi", "واي فاي"), icon: "wifi")
            modeButton(.usb, title: "USB", icon: "cable.connector")
        }
        .padding(5)
        .background(cardBackground)
    }

    private var usbPayloadStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.green).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(t("USB Payload", "بايلود USB")).font(.caption).foregroundStyle(.secondary)
                Text(PayloadManager.shared.activePayloadName()).font(.subheadline.weight(.semibold))
            }
            Spacer()
            Text(PayloadManager.shared.bundledVersion()).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(13)
        .background(cardBackground)
    }

    private func modeButton(_ mode: TransferMode, title: String, icon: String) -> some View {
        Button {
            guard !isSending else { return }
            transferMode = mode
            USBBridgeServer.shared.disarm()
            status = mode == .usb
                ? t("USB mode ready. Choose a PKG, then tap Send.", "وضع USB جاهز. اختر ملف PKG ثم اضغط إرسال.")
                : t("Wi-Fi mode ready. Check the PlayStation connection.", "وضع الواي فاي جاهز. افحص اتصال البلايستيشن.")
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(transferMode == mode ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var connectionCard: some View {

        VStack(
            alignment: .leading,
            spacing: 14
        ) {

            HStack {

                Label(
                    t(
                        "PlayStation",
                        "\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646}"
                    ),
                    systemImage:
                        "gamecontroller.fill"
                )
                .font(.headline)

                Spacer()

                connectionBadge
            }

            Divider()

            HStack {

                Image(
                    systemName: "network"
                )
                .foregroundColor(
                    .secondary
                )

                TextField(
                    t(
                        "PlayStation IP",
                        "\u{639}\u{646}\u{648}\u{627}\u{646} IP \u{644}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646}"
                    ),
                    text: $psIP
                )
                .keyboardType(
                    .numbersAndPunctuation
                )
                .autocorrectionDisabled(
                    true
                )
                .environment(
                    \.layoutDirection,
                    .leftToRight
                )
                .multilineTextAlignment(
                    .leading
                )
                .disabled(
                    isSending ||
                    connectionState ==
                        .checking
                )
            }

            Divider()

            Button {

                checkConnection()

            } label: {

                HStack {

                    if connectionState ==
                        .checking {

                        ProgressView()
                            .controlSize(
                                .small
                            )

                    } else {

                        Image(
                            systemName:
                                "antenna.radiowaves.left.and.right"
                        )
                    }

                    Text(
                        connectionButtonTitle
                    )
                    .fontWeight(
                        .semibold
                    )

                    Spacer()
                }
                .frame(
                    maxWidth:
                        .infinity
                )
            }
            .disabled(
                isSending ||
                connectionState ==
                    .checking ||
                psIP
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .isEmpty
            )
        }
        .padding()
        .background(
            cardBackground
        )
    }

    // MARK: Connection Badge

    @ViewBuilder
    private var connectionBadge:
        some View {

        HStack(spacing: 6) {

            Circle()
                .fill(
                    connectionColor
                )
                .frame(
                    width: 9,
                    height: 9
                )

            Text(connectionText)
                .font(.caption)
                .fontWeight(
                    .semibold
                )
                .foregroundColor(
                    connectionColor
                )
        }
    }

    private var connectionText:
        String {

        switch connectionState {

        case .notChecked:

            return t(
                "Not Checked",
                "\u{644}\u{645} \u{64A}\u{62A}\u{645} \u{627}\u{644}\u{641}\u{62D}\u{635}"
            )

        case .checking:

            return t(
                "Checking...",
                "\u{62C}\u{627}\u{631}\u{64A} \u{627}\u{644}\u{641}\u{62D}\u{635}..."
            )

        case .connected:

            return t(
                "Connected",
                "\u{645}\u{62A}\u{635}\u{644}"
            )

        case .disconnected:

            return t(
                "Not Connected",
                "\u{63A}\u{64A}\u{631} \u{645}\u{62A}\u{635}\u{644}"
            )
        }
    }

    private var connectionColor:
        Color {

        switch connectionState {

        case .notChecked:
            return .secondary

        case .checking:
            return .orange

        case .connected:
            return .green

        case .disconnected:
            return .red
        }
    }

    private var connectionButtonTitle:
        String {

        switch connectionState {

        case .checking:

            return t(
                "Checking Connection...",
                "\u{62C}\u{627}\u{631}\u{64A} \u{641}\u{62D}\u{635} \u{627}\u{644}\u{627}\u{62A}\u{635}\u{627}\u{644}..."
            )

        case .connected:

            return t(
                "Check Again",
                "\u{641}\u{62D}\u{635} \u{645}\u{631}\u{629} \u{623}\u{62E}\u{631}\u{649}"
            )

        default:

            return t(
                "Check Connection",
                "\u{641}\u{62D}\u{635} \u{627}\u{644}\u{627}\u{62A}\u{635}\u{627}\u{644}"
            )
        }
    }

    // ======================================================
    // MARK: - Check Connection
    // ======================================================

    private func checkConnection() {

        let cleanIP =
            psIP.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        let cleanPort =
            psPort.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard !cleanIP.isEmpty
        else {

            connectionState =
                .disconnected

            status = t(
                "Enter the PlayStation IP first.",
                "\u{623}\u{62F}\u{62E}\u{644} IP \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{623}\u{648}\u{644}\u{627}\u{64B}."
            )

            return
        }

        guard
            let portNumber =
                UInt16(cleanPort),

            let port =
                NWEndpoint.Port(
                    rawValue:
                        portNumber
                )

        else {

            connectionState =
                .disconnected

            status = t(
                "Invalid PlayStation port.",
                "\u{645}\u{646}\u{641}\u{630} \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{63A}\u{64A}\u{631} \u{635}\u{62D}\u{64A}\u{62D}."
            )

            return
        }

        connectionState =
            .checking

        status = t(
            "Checking Remote Package Installer...",
            "\u{62C}\u{627}\u{631}\u{64A} \u{641}\u{62D}\u{635} Remote Package Installer..."
        )

        let host =
            NWEndpoint.Host(
                cleanIP
            )

        let connection =
            NWConnection(
                host: host,
                port: port,
                using: .tcp
            )

        var finished = false

        func finish(
            connected: Bool
        ) {

            guard !finished else {
                return
            }

            finished = true

            connection.cancel()

            DispatchQueue.main.async {

                let currentIP =
                    self.psIP
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )

                let currentPort =
                    self.psPort
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )

                guard
                    currentIP ==
                        cleanIP,
                    currentPort ==
                        cleanPort
                else {

                    self.connectionState =
                        .notChecked

                    return
                }

                if connected {

                    self.connectionState =
                        .connected

                    self.checkedIP =
                        cleanIP

                    self.checkedPort =
                        cleanPort

                    self.status =
                        self.t(
                            "PlayStation is connected and ready.",
                            "\u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{645}\u{62A}\u{635}\u{644} \u{648}\u{62C}\u{627}\u{647}\u{632}."
                        )

                } else {

                    self.connectionState =
                        .disconnected

                    self.checkedIP = ""
                    self.checkedPort = ""

                    self.status =
                        self.t(
                            "Could not connect to Remote Package Installer. Make sure it is running on the PlayStation.",
                            "\u{62A}\u{639}\u{630}\u{631} \u{627}\u{644}\u{627}\u{62A}\u{635}\u{627}\u{644} \u{628}\u{640} Remote Package Installer. \u{62A}\u{623}\u{643}\u{62F} \u{623}\u{646} \u{627}\u{644}\u{628}\u{631}\u{646}\u{627}\u{645}\u{62C} \u{634}\u{63A}\u{627}\u{644} \u{639}\u{644}\u{649} \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646}."
                        )
                }
            }
        }

        connection
            .stateUpdateHandler = {
                state in

                switch state {

                case .ready:

                    finish(
                        connected:
                            true
                    )

                case .failed:

                    finish(
                        connected:
                            false
                    )

                case .cancelled:
                    break

                default:
                    break
                }
            }

        connection.start(
            queue:
                DispatchQueue
                    .global(
                        qos:
                            .userInitiated
                    )
        )

        DispatchQueue
            .global(qos: .userInitiated)
            .asyncAfter(
                deadline:
                    .now() + 6
            ) {

                finish(
                    connected:
                        false
                )
            }
    }

    private func resetConnectionCheck() {

        connectionState =
            .notChecked

        checkedIP = ""
        checkedPort = ""

        if selectedFile == nil {

            status = t(
                "Enter your PlayStation IP and check the connection.",
                "\u{623}\u{62F}\u{62E}\u{644} IP \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{62B}\u{645} \u{627}\u{641}\u{62D}\u{635} \u{627}\u{644}\u{627}\u{62A}\u{635}\u{627}\u{644}."
            )
        }
    }

    private var connectionIsValid:
        Bool {

        let currentIP =
            psIP.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        let currentPort =
            psPort.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        return
            connectionState ==
                .connected &&
            checkedIP ==
                currentIP &&
            checkedPort ==
                currentPort
    }

    // ======================================================
    // MARK: - Package Card
    // ======================================================

    private var fileCard: some View {

        VStack(alignment: .leading, spacing: 12) {

            if packageQueue.isEmpty {

                Button {
                    if !isSending && (transferMode == .usb || connectionIsValid) {
                        pickerAddsToQueue = false
                        showFilePicker = true
                    }
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill((transferMode == .usb || connectionIsValid) ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
                                .frame(width: 48, height: 48)

                            Image(systemName: "shippingbox.fill")
                                .font(.title3)
                                .foregroundColor((transferMode == .usb || connectionIsValid) ? .accentColor : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(t("Choose PKG", "\u{627}\u{62E}\u{62A}\u{64A}\u{627}\u{631} \u{645}\u{644}\u{641} PKG"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Text(transferMode == .usb
                                 ? t("Tap to select a PKG for USB transfer", "اضغط لاختيار ملف PKG للنقل عبر USB")
                                 : connectionIsValid
                                 ? t("Tap to select one or more packages", "اضغط لاختيار ملف أو عدة ملفات")
                                 : t("Check the PlayStation connection first", "افحص اتصال البلايستيشن أولاً"))
                                .font(.headline)
                                .foregroundColor((transferMode == .usb || connectionIsValid) ? .primary : .secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Image(systemName: (transferMode == .usb || connectionIsValid) ? "chevron.forward" : "lock.fill")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(cardBackground)
                }
                .buttonStyle(.plain)
                .disabled(isSending || (transferMode == .wifi && !connectionIsValid))

            } else {

                VStack(alignment: .leading, spacing: 12) {

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("Install Queue", "\u{642}\u{627}\u{626}\u{645}\u{629} \u{627}\u{644}\u{62A}\u{62B}\u{628}\u{64A}\u{62A}"))
                                .font(.headline)

                            Text(queueSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if !isSending {
                            HStack(spacing: 12) {
                                Button {
                                    pickerAddsToQueue = true
                                    showFilePicker = true
                                } label: {
                                    Label(t("Add", "\u{625}\u{636}\u{627}\u{641}\u{629}"), systemImage: "plus.circle.fill")
                                        .font(.subheadline.weight(.semibold))
                                }

                                Button {
                                    pickerAddsToQueue = false
                                    showFilePicker = true
                                } label: {
                                    Text(t("Change", "\u{62A}\u{63A}\u{64A}\u{64A}\u{631}"))
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    }

                    ForEach(packageGroups, id: \.key) { group in
                        packageGroupView(group)
                    }
                }
                .padding()
                .background(cardBackground)
            }
        }
    }

    private var queueSubtitle: String {
        if packageQueue.count == 1 {
            return t("1 Package", "\u{645}\u{644}\u{641} \u{648}\u{627}\u{62D}\u{62F}")
        }
        return t(
            "\(packageQueue.count) Packages",
            "\(packageQueue.count) \u{645}\u{644}\u{641}\u{627}\u{62A}"
        )
    }

    private struct PackageGroup {
        let key: String
        let items: [PKGQueueItem]
    }

    private var packageGroups: [PackageGroup] {
        var order: [String] = []
        var grouped: [String: [PKGQueueItem]] = [:]

        for item in packageQueue {
            let rawID = item.metadata?.titleID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = rawID.isEmpty ? item.url.lastPathComponent : rawID.uppercased()
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }

        return order.compactMap { key in
            guard let items = grouped[key] else { return nil }
            return PackageGroup(key: key, items: items)
        }
    }

    @ViewBuilder
    private func packageGroupView(_ group: PackageGroup) -> some View {
        if group.items.count == 1 {
            let item = group.items[0]
            expandablePackageCard(item: item, index: queueIndex(for: item))
        } else {
            Button {
                expandedPackageItems.removeAll()
                withAnimation(.spring(response: 0.48, dampingFraction: 0.86, blendDuration: 0.12)) {
                    overlayPackageGroupKey = group.key
                }
            } label: {
                packageStackPreview(group)
            }
            .buttonStyle(.plain)
            .disabled(isSending)
        }
    }

    // Shared package-card surface. The main queue stack and the cards inside
    // the floating package panel intentionally use this exact same color.
    private var packageCardSurface: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 1.0)
                : UIColor(white: 0.93, alpha: 1.0)
        })
    }

    @ViewBuilder
    private func packageStackPreview(_ group: PackageGroup) -> some View {
        let first = group.items[0]

        ZStack(alignment: .top) {
            // Quiet, real-card layers: the stack is visible without extra labels or badges.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(packageCardSurface.opacity(0.46))
                .frame(height: 122)
                .padding(.horizontal, 22)
                .offset(y: 20)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(packageCardSurface.opacity(0.72))
                .frame(height: 122)
                .padding(.horizontal, 11)
                .offset(y: 10)

            HStack(spacing: 14) {
                packageArtwork(first, width: 74, height: 96, radius: 15)

                VStack(alignment: .leading, spacing: 5) {
                    Text(first.metadata?.title ?? first.url.deletingPathExtension().lastPathComponent)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)

                    if let id = first.metadata?.titleID, !id.isEmpty {
                        Text(id)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.caption)
                        Text(t("\(group.items.count) Packages", "\(group.items.count) \u{62D}\u{632}\u{645}"))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.75))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(packageCardSurface)
            }
            .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
        }
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func packageArtwork(_ item: PKGQueueItem, width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
                .frame(width: width, height: height)

            if let iconData = item.metadata?.iconData,
               let image = UIImage(data: iconData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else if item.isReadingMetadata {
                ProgressView()
            } else {
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var packageQueueOverlay: some View {
        if let key = overlayPackageGroupKey,
           let group = packageGroups.first(where: { $0.key == key }) {

            ZStack {
                // Keep the page behind the floating panel visible and only softly dimmed.
                // The actual blur/frosted-glass effect belongs to the floating panel itself.
                Color.black
                    .opacity(0.24)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closePackageOverlay(group) }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.items.first?.metadata?.title ?? t("Packages", "\u{627}\u{644}\u{62D}\u{632}\u{645}"))
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(1)

                                Text(t("\(group.items.count) Packages", "\(group.items.count) \u{62D}\u{632}\u{645}"))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button {
                                closePackageOverlay(group)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 32, height: 32)
                                    .background(Color.primary.opacity(0.07))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(spacing: 10) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { position, item in
                                expandablePackageCard(item: item, index: queueIndex(for: item))
                                    .transition(
                                        .asymmetric(
                                            insertion: .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.985, anchor: .top)),
                                            removal: .opacity.combined(with: .offset(y: -6))
                                        )
                                    )
                                    .animation(
                                        .spring(response: 0.42, dampingFraction: 0.90).delay(Double(position) * 0.035),
                                        value: overlayPackageGroupKey
                                    )
                            }
                        }

                        // Quiet bottom close control: intentionally smaller and much more transparent.
                        Button {
                            closePackageOverlay(group)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.up")
                                    .font(.caption2.weight(.semibold))
                                Text(t("Close Packages", "\u{625}\u{63A}\u{644}\u{627}\u{642} \u{627}\u{644}\u{62D}\u{632}\u{645}"))
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.025))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                    }
                    .padding(16)
                }
                // Preserve the original full floating-panel width.
                // Without this, the ScrollView sizes itself to its content and the panel becomes too narrow.
                .frame(maxWidth: .infinity)
                .frame(maxHeight: UIScreen.main.bounds.height * 0.72)
                .background {
                    // Frosted-glass floating surface: background content remains visible
                    // through a real system blur instead of a nearly opaque gray fill.
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.18))
                        }
                        .shadow(color: .black.opacity(0.32), radius: 32, y: 16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .padding(.horizontal, 28)
                // Keep the floating panel at its natural content size.
                // Animate its appearance without letting the source stack dictate
                // the final frame (which previously left the panel permanently clipped).
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: 0.90, anchor: .center))
                            .combined(with: .offset(y: 18)),
                        removal: .opacity
                            .combined(with: .scale(scale: 0.94, anchor: .center))
                            .combined(with: .offset(y: 10))
                    )
                )
            }
            .zIndex(100)
        }
    }

    private func closePackageOverlay(_ group: PackageGroup) {
        withAnimation(.spring(response: 0.46, dampingFraction: 0.90, blendDuration: 0.08)) {
            for item in group.items {
                visiblePackageDetails.remove(item.id)
                expandedPackageItems.remove(item.id)
            }
            overlayPackageGroupKey = nil
        }
    }

    @ViewBuilder
    private func expandablePackageCard(item: PKGQueueItem, index: Int) -> some View {
        let expanded = expandedPackageItems.contains(item.id)
        let detailsVisible = visiblePackageDetails.contains(item.id)

        VStack(spacing: 0) {
            Button {
                if expanded {
                    // Fade the detail content first, then collapse the card.
                    withAnimation(.easeOut(duration: 0.12)) {
                        _ = visiblePackageDetails.remove(item.id)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) {
                            _ = expandedPackageItems.remove(item.id)
                        }
                    }
                } else {
                    // Reserve the detail area first so the card grows cleanly.
                    // The content fades in only after the layout has opened.
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.90)) {
                        _ = expandedPackageItems.insert(item.id)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                        guard expandedPackageItems.contains(item.id) else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            _ = visiblePackageDetails.insert(item.id)
                        }
                    }
                }
            } label: {
                queuePackageCard(
                    item: item,
                    index: index,
                    groupCount: nil,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    inlinePackageDetails(item)

                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            _ = visiblePackageDetails.remove(item.id)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) {
                                _ = expandedPackageItems.remove(item.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.semibold))
                            Text(t("Close Details", "\u{625}\u{63A}\u{644}\u{627}\u{642} \u{627}\u{644}\u{62A}\u{641}\u{627}\u{635}\u{64A}\u{644}"))
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.025))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary.opacity(0.72))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .opacity(detailsVisible ? 1 : 0)
                .allowsHitTesting(detailsVisible)
                .clipped()
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(packageCardSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func inlinePackageDetails(_ item: PKGQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal)

            if let metadata = item.metadata, !metadata.contentID.isEmpty {
                packageDetailRow(title: "Content ID", value: metadata.contentID, icon: "number")
                Divider().padding(.leading, 50)
            }

            packageDetailRow(
                title: t("File Size", "\u{62D}\u{62C}\u{645} \u{627}\u{644}\u{645}\u{644}\u{641}"),
                value: formatBytes(item.fileSize),
                icon: "internaldrive.fill"
            )
            Divider().padding(.leading, 50)
            packageDetailRow(
                title: t("Full File Name", "\u{627}\u{633}\u{645} \u{627}\u{644}\u{645}\u{644}\u{641} \u{627}\u{644}\u{643}\u{627}\u{645}\u{644}"),
                value: item.url.lastPathComponent,
                icon: "doc.fill"
            )
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func queueIndex(for item: PKGQueueItem) -> Int {
        packageQueue.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    private func handlePickedPackages(_ urls: [URL], append: Bool) {
        guard !urls.isEmpty else { return }

        // UIDocumentPicker is intentionally kept in import/copy mode.  Large PKGs
        // returned by the picker can live at an import URL whose lifetime is tied
        // to the picker/provider.  Move that already-imported copy immediately into
        // our own Caches/PKGSenderQueue folder.  A move on the same app volume is
        // metadata-only (no second 40Ã¢ÂÂ70 GB copy) and gives LocalHTTPServer a stable
        // path for the whole Game -> Update -> DLC queue.
        let existingSignatures = Set(packageQueue.map {
            "\($0.url.lastPathComponent.lowercased())|\($0.fileSize)"
        })

        var stableURLs: [URL] = []
        for pickedURL in urls {
            let size = packageFileSize(pickedURL)
            let signature = "\(pickedURL.lastPathComponent.lowercased())|\(size)"
            guard !existingSignatures.contains(signature) else { continue }

            do {
                stableURLs.append(try stagePickedPackage(pickedURL))
            } catch {
                status = t(
                    "Could not keep access to \(pickedURL.lastPathComponent): \(error.localizedDescription)",
                    "Could not keep access to \(pickedURL.lastPathComponent): \(error.localizedDescription)"
                )
                return
            }
        }

        guard !stableURLs.isEmpty else {
            status = t("Those packages are already in the queue.", "\u{647}\u{630}\u{647} \u{627}\u{644}\u{645}\u{644}\u{641}\u{627}\u{62A} \u{645}\u{648}\u{62C}\u{648}\u{62F}\u{629} \u{641}\u{64A} \u{627}\u{644}\u{642}\u{627}\u{626}\u{645}\u{629} \u{628}\u{627}\u{644}\u{641}\u{639}\u{644}.")
            return
        }

        if !append {
            clearTransferDisplay()
            cleanupStagedPackages(packageQueue.map { $0.url })
            packageQueue.removeAll()
            overlayPackageGroupKey = nil
            expandedPackageItems.removeAll()
        }

        let newURLs = stableURLs
        guard !newURLs.isEmpty else {
            status = t("Those packages are already in the queue.", "\u{647}\u{630}\u{647} \u{627}\u{644}\u{645}\u{644}\u{641}\u{627}\u{62A} \u{645}\u{648}\u{62C}\u{648}\u{62F}\u{629} \u{641}\u{64A} \u{627}\u{644}\u{642}\u{627}\u{626}\u{645}\u{629} \u{628}\u{627}\u{644}\u{641}\u{639}\u{644}.")
            return
        }

        // When using Add, keep the current queue visually untouched while metadata is read.
        // The new package appears only after parsing completes, so there is no temporary
        // "Reading PKG information" card before it joins the existing game stack.
        if append {
            for url in newURLs {
                let pending = PKGQueueItem(
                    url: url,
                    metadata: nil,
                    metadataError: nil,
                    isReadingMetadata: true,
                    fileSize: packageFileSize(url)
                )

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let metadata = try PKGMetadataParser.parse(url: url)
                        DispatchQueue.main.async {
                            var ready = pending
                            ready.metadata = metadata
                            ready.metadataError = nil
                            ready.isReadingMetadata = false
                            libraryStore.addSelectedPackage(url: url, metadata: metadata)

                            guard !packageQueue.contains(where: {
                                $0.url.standardizedFileURL.path == url.standardizedFileURL.path
                            }) else { return }

                            withAnimation(.spring(response: 0.38, dampingFraction: 0.90)) {
                                packageQueue.append(ready)
                                sortPackageQueue()
                                syncPrimarySelection()
                            }

                            status = t(
                                packageQueue.count > 1 ? "\(packageQueue.count) packages ready in the install queue." : "Ready to send",
                                packageQueue.count > 1 ? "\(packageQueue.count) \u{645}\u{644}\u{641}\u{627}\u{62A} \u{62C}\u{627}\u{647}\u{632}\u{629} \u{641}\u{64A} \u{642}\u{627}\u{626}\u{645}\u{629} \u{627}\u{644}\u{62A}\u{62B}\u{628}\u{64A}\u{62A}." : "\u{62C}\u{627}\u{647}\u{632} \u{644}\u{644}\u{625}\u{631}\u{633}\u{627}\u{644}"
                            )
                        }
                    } catch {
                        DispatchQueue.main.async {
                            var failed = pending
                            failed.metadataError = error.localizedDescription
                            failed.isReadingMetadata = false
                            packageQueue.append(failed)
                            sortPackageQueue()
                            syncPrimarySelection()
                        }
                    }
                }
            }
            return
        }

        // Replace/initial selection keeps the existing immediate reading state.
        let newItems = newURLs.map { url in
            PKGQueueItem(url: url, metadata: nil, metadataError: nil, isReadingMetadata: true, fileSize: packageFileSize(url))
        }
        packageQueue.append(contentsOf: newItems)
        sortPackageQueue()
        syncPrimarySelection()

        for item in newItems {
            let id = item.id
            let url = item.url
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let metadata = try PKGMetadataParser.parse(url: url)
                    DispatchQueue.main.async {
                        if let index = packageQueue.firstIndex(where: { $0.id == id }) {
                            packageQueue[index].metadata = metadata
                            packageQueue[index].metadataError = nil
                            packageQueue[index].isReadingMetadata = false
                            libraryStore.addSelectedPackage(url: url, metadata: metadata)
                            sortPackageQueue()
                            syncPrimarySelection()
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        if let index = packageQueue.firstIndex(where: { $0.id == id }) {
                            packageQueue[index].metadataError = error.localizedDescription
                            packageQueue[index].isReadingMetadata = false
                            syncPrimarySelection()
                        }
                    }
                }
            }
        }

        status = t("Ready to send", "\u{62C}\u{627}\u{647}\u{632} \u{644}\u{644}\u{625}\u{631}\u{633}\u{627}\u{644}")
    }

    private func stagePickedPackage(_ sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PKGSenderQueue", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let itemDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        let destination = itemDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            try fm.moveItem(at: sourceURL, to: destination)
        } catch {
            // Some providers return an imported URL that cannot be renamed even
            // though it is readable.  A hard link is still instant and does not
            // duplicate the PKG data.  We deliberately do NOT fall back to a byte
            // copy because PKGs may be tens of gigabytes.
            do {
                try fm.linkItem(at: sourceURL, to: destination)
            } catch {
                try? fm.removeItem(at: itemDirectory)
                throw error
            }
        }

        guard fm.fileExists(atPath: destination.path) else {
            try? fm.removeItem(at: itemDirectory)
            throw NSError(
                domain: "PKGSender.FileAccess",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The imported PKG could not be secured for the install queue."]
            )
        }
        return destination
    }

    private func cleanupStagedPackages(_ urls: [URL]) {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PKGSenderQueue", isDirectory: true)
            .standardizedFileURL.path

        for url in urls {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path.hasPrefix(root) {
                try? fm.removeItem(at: parent)
            }
        }
    }

    private func packageDetailRow(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.subheadline).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func queuePackageCard(
        item: PKGQueueItem,
        index: Int,
        groupCount: Int? = nil,
        showsDisclosure: Bool = false
    ) -> some View {

        HStack(alignment: .top, spacing: 14) {

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
                    .frame(width: 76, height: 98)

                if let iconData = item.metadata?.iconData,
                   let image = UIImage(data: iconData) {

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 98)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous
                            )
                        )

                } else if item.isReadingMetadata {

                    ProgressView()

                } else {

                    Image(systemName: "shippingbox.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {

                Text(
                    item.metadata?.title
                    ?? item.url.deletingPathExtension().lastPathComponent
                )
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(2)

                if item.isReadingMetadata {

                    Text(t("Reading PKG information…", "\u{62C}\u{627}\u{631}\u{64D} \u{642}\u{631}\u{627}\u{621}\u{629} \u{645}\u{639}\u{644}\u{648}\u{645}\u{627}\u{62A} PKG…"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                } else if let metadata = item.metadata {

                    if !metadata.titleID.isEmpty {
                        Text(metadata.titleID)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }

                    HStack(spacing: 6) {
                        packageInfoBadge(
                            metadata.kind.rawValue,
                            systemImage:
                                metadata.kind == .game ? "gamecontroller.fill" :
                                metadata.kind == .update ? "arrow.down.circle.fill" :
                                metadata.kind == .dlc ? "puzzlepiece.extension.fill" :
                                "shippingbox.fill"
                        )

                        if !metadata.version.isEmpty {
                            packageInfoBadge(
                                "v\(metadata.version)",
                                systemImage: "tag.fill"
                            )
                        }
                    }
                }

                Text(formatBytes(item.fileSize))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let error = item.metadataError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(spacing: 8) {
                if let groupCount, groupCount > 1 {
                    Text("\(groupCount) PKGs")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                } else if queueRunning && activeQueueIndex == index {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Circle())
                }

                if showsDisclosure {
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func packageInfoBadge(
        _ text: String,
        systemImage: String
    ) -> some View {

        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)

            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12))
        .foregroundColor(.accentColor)
        .clipShape(Capsule())
        .environment(\.layoutDirection, .leftToRight)
    }

    private func packageFileSize(_ url: URL) -> UInt64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize,
           size >= 0 {
            return UInt64(size)
        }
        return 0
    }

    private func packageSortRank(_ kind: PKGMetadata.Kind?) -> Int {
        switch kind {
        case .game: return 0
        case .update: return 1
        case .dlc: return 2
        default: return 3
        }
    }

    private func sortPackageQueue() {
        packageQueue.sort {
            let left = packageSortRank($0.metadata?.kind)
            let right = packageSortRank($1.metadata?.kind)

            if left != right {
                return left < right
            }

            let leftTitle = $0.metadata?.title ?? $0.url.lastPathComponent
            let rightTitle = $1.metadata?.title ?? $1.url.lastPathComponent
            return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
        }
    }

    private func syncPrimarySelection() {
        guard let first = packageQueue.first else {
            USBBridgeServer.shared.setSelectedFile(nil)
            selectedFile = nil
            selectedMetadata = nil
            metadataError = nil
            isReadingMetadata = false
            return
        }

        selectedFile = first.url
        USBBridgeServer.shared.setSelectedFile(first.url)
        selectedMetadata = first.metadata
        metadataError = first.metadataError
        isReadingMetadata = first.isReadingMetadata
    }

    // ======================================================
    // MARK: - Transfer Card
    // ======================================================

    private var transferCard: some View {

        VStack(alignment: .leading, spacing: 12) {

            // Same visual hierarchy as Install Queue:
            // quiet outer container + one inner card. No stack effect here.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Transfer Queue", "قائمة النقل"))
                        .font(.headline)

                    Text(transferQueueSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Button {
                guard packageQueue.count > 1 else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    isTransferQueueExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 18) {

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(transferTitle)
                                .font(.headline)

                            Text(selectedFile?.lastPathComponent ?? "PKG")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if wasCancelled {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.red)
                        } else if completed {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.green)
                        } else {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                        }
                    }

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .scaleEffect(x: 1, y: 1.8)

                    HStack {
                        statItem(
                            title: t("Transferred", "تم النقل"),
                            value: "\(formatBytes(sentBytes)) / \(formatBytes(totalBytes))"
                        )

                        Spacer()

                        statItem(
                            title: t("Speed", "السرعة"),
                            value: formatSpeed(speed)
                        )
                    }

                    if wasCancelled {
                        Label(
                            t("Transfer cancelled", "تم إلغاء النقل"),
                            systemImage: "xmark.circle.fill"
                        )
                        .font(.subheadline.bold())
                        .foregroundColor(.red)
                    } else if completed {
                        Label(
                            t("Package sent successfully", "تم إرسال الملف بنجاح"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                    } else {
                        HStack {
                            Image(systemName: "clock")
                            Text(remainingText)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    if packageQueue.count > 1 && isTransferQueueExpanded {
                        queueTransferProgressSection
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if packageQueue.count > 1 {
                        HStack {
                            Spacer()
                            Image(systemName: isTransferQueueExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.top, -4)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(packageCardSurface)
                )
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(cardBackground)
    }

    private var transferQueueSubtitle: String {
        if packageQueue.count <= 1 {
            return t("1 Package", "ملف واحد")
        }

        return t(
            "\(packageQueue.count) Packages • Tap for details",
            "\(packageQueue.count) ملفات • اضغط للتفاصيل"
        )
    }

    @ViewBuilder
    private var queueTransferProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack {
                Text(t("Package Progress", "تقدم الملفات"))
                    .font(.subheadline.bold())

                Spacer()

                Text(queuePositionText)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }

            ForEach(Array(packageQueue.enumerated()), id: \.element.id) { index, item in
                queueTransferRow(item: item, index: index)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func queueTransferRow(item: PKGQueueItem, index: Int) -> some View {
        let isDone = queueCompletedItemIDs.contains(item.id)
        let isActive = activeQueueIndex == index && (isSending || queueRunning)
        let itemProgress = isDone ? 1.0 : (isActive ? progress : (queueItemProgress[item.id] ?? 0))
        let itemSpeed = isActive ? speed : (queueItemSpeed[item.id] ?? 0)

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: queueKindIcon(item))
                    .font(.caption.bold())
                    .foregroundColor(isDone ? .green : (isActive ? .accentColor : .secondary))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(queueKindTitle(item))
                        .font(.caption.bold())
                        .foregroundColor(isActive ? .primary : .secondary)

                    Text(queueItemSubtitle(item))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isDone {
                    Label(t("Completed", "مكتمل"), systemImage: "checkmark.circle.fill")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                } else if isActive {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(itemProgress * 100))%")
                            .font(.caption.bold())
                        Text(formatSpeed(itemSpeed))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(t("Waiting", "في الانتظار"))
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                }
            }

            ProgressView(value: itemProgress)
                .progressViewStyle(.linear)
                .tint(isDone ? .green : (isActive ? .accentColor : Color.secondary.opacity(0.35)))
        }
        .padding(.vertical, 2)
    }

    private var queuePositionText: String {
        let current = min((activeQueueIndex ?? 0) + 1, max(packageQueue.count, 1))
        return "\(current) of \(packageQueue.count)"
    }

    private func queueKindTitle(_ item: PKGQueueItem) -> String {
        guard let kind = item.metadata?.kind else { return "PKG" }
        switch kind {
        case .game: return t("GAME", "\u{627}\u{644}\u{644}\u{639}\u{628}\u{629}")
        case .update: return t("UPDATE", "\u{627}\u{644}\u{62A}\u{62D}\u{62F}\u{64A}\u{62B}")
        case .dlc: return "DLC"
        default: return "PKG"
        }
    }

    private func queueKindIcon(_ item: PKGQueueItem) -> String {
        guard let kind = item.metadata?.kind else { return "shippingbox.fill" }
        switch kind {
        case .game: return "gamecontroller.fill"
        case .update: return "arrow.down.circle.fill"
        case .dlc: return "puzzlepiece.extension.fill"
        default: return "shippingbox.fill"
        }
    }

    private func queueItemSubtitle(_ item: PKGQueueItem) -> String {
        if let metadata = item.metadata {
            var parts: [String] = []
            if !metadata.version.isEmpty { parts.append("v\(metadata.version)") }
            parts.append(formatBytes(item.fileSize))
            return parts.joined(separator: "  •  ")
        }
        return formatBytes(item.fileSize)
    }

    private var transferTitle:
        String {

        if wasCancelled {

            return t(
                "Transfer Cancelled",
                "\u{62A}\u{645} \u{625}\u{644}\u{63A}\u{627}\u{621} \u{627}\u{644}\u{646}\u{642}\u{644}"
            )
        }

        if completed {

            return t(
                "Transfer Complete",
                "\u{627}\u{643}\u{62A}\u{645}\u{644} \u{627}\u{644}\u{646}\u{642}\u{644}"
            )
        }

        return t(
            "Transferring",
            "\u{62C}\u{627}\u{631}\u{64A} \u{627}\u{644}\u{646}\u{642}\u{644}"
        )
    }

    // ======================================================
    // MARK: - Send Button
    // ======================================================

    private var sendButton:
        some View {

        Button {

            sendPackage()

        } label: {

            HStack {

                Image(
                    systemName:
                        completed ||
                        wasCancelled
                        ? "arrow.clockwise"
                        : "paperplane.fill"
                )

                Text(
                    completed ||
                    wasCancelled
                    ? t(
                        "Send Again",
                        "\u{625}\u{631}\u{633}\u{627}\u{644} \u{645}\u{631}\u{629} \u{623}\u{62E}\u{631}\u{649}"
                    )
                    : packageQueue.count > 1
                    ? t(
                        "Install Queue (\(packageQueue.count))",
                        "\u{62A}\u{62B}\u{628}\u{64A}\u{62A} \u{627}\u{644}\u{642}\u{627}\u{626}\u{645}\u{629} (\(packageQueue.count))"
                    )
                    : t(
                        "Send to PlayStation",
                        "\u{625}\u{631}\u{633}\u{627}\u{644} \u{625}\u{644}\u{649} \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646}"
                    )
                )
                .fontWeight(
                    .semibold
                )
            }
            .frame(
                maxWidth:
                    .infinity
            )
            .padding(
                .vertical,
                15
            )
        }
        .buttonStyle(
            .borderedProminent
        )
        .controlSize(.large)
        .disabled(
            packageQueue.isEmpty ||
            (transferMode == .wifi && !connectionIsValid) ||
            packageQueue.contains(where: { $0.isReadingMetadata })
        )
    }

    // ======================================================
    // MARK: - Cancel Button
    // ======================================================

    private var cancelButton:
        some View {

        Button(
            role: .destructive
        ) {

            showCancelConfirmation = true

        } label: {

            HStack(spacing: 10) {

                Image(
                    systemName:
                        "xmark.circle.fill"
                )

                Text(
                    t(
                        "Cancel Transfer",
                        "\u{625}\u{644}\u{63A}\u{627}\u{621} \u{627}\u{644}\u{646}\u{642}\u{644}"
                    )
                )
                .fontWeight(
                    .semibold
                )
            }
            .frame(
                maxWidth:
                    .infinity
            )
            .padding(
                .vertical,
                15
            )
        }
        .buttonStyle(
            .borderedProminent
        )
        .tint(.red)
        .controlSize(.large)
    }

    // ======================================================
    // MARK: - Status
    // ======================================================

    private var statusCard:
        some View {

        HStack(
            alignment: .top,
            spacing: 10
        ) {

            Image(
                systemName:
                    statusIcon
            )
            .foregroundColor(
                statusColor
            )

            Text(status)
                .font(.footnote)
                .foregroundColor(
                    .secondary
                )

            Spacer()
        }
        .padding()
        .background(
            cardBackground
        )
    }

    private var statusIcon:
        String {

        if completed {
            return "checkmark.circle.fill"
        }

        if wasCancelled {
            return "xmark.circle.fill"
        }

        if connectionState ==
            .connected {

            return "checkmark.circle.fill"
        }

        if connectionState ==
            .disconnected {

            return "exclamationmark.circle.fill"
        }

        return "info.circle.fill"
    }

    private var statusColor:
        Color {

        if completed {
            return .green
        }

        if wasCancelled {
            return .red
        }

        if connectionState ==
            .connected {

            return .green
        }

        if connectionState ==
            .disconnected {

            return .red
        }

        if connectionState ==
            .checking {

            return .orange
        }

        return .secondary
    }

    private var cardBackground:
        some View {

        RoundedRectangle(
            cornerRadius: 18,
            style: .continuous
        )
        .fill(PKGTheme.surface)
    }

    // ======================================================
    // MARK: - Stats
    // ======================================================

    private func statItem(
        title: String,
        value: String
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 3
        ) {

            Text(title)
                .font(.caption)
                .foregroundColor(
                    .secondary
                )

            Text(value)
                .font(
                    .system(
                        .subheadline,
                        design:
                            .rounded
                    )
                    .weight(
                        .semibold
                    )
                )
        }
    }

    private var remainingText:
        String {

        guard
            let seconds =
                remainingSeconds,
            seconds.isFinite,
            seconds > 0

        else {

            return t(
                "Calculating time remaining...",
                "\u{62C}\u{627}\u{631}\u{64A} \u{62D}\u{633}\u{627}\u{628} \u{627}\u{644}\u{648}\u{642}\u{62A} \u{627}\u{644}\u{645}\u{62A}\u{628}\u{642}\u{64A}..."
            )
        }

        let value =
            Int(seconds)

        if value < 60 {

            return isArabic
            ? "\u{645}\u{62A}\u{628}\u{642}\u{64A} \(value) \u{62B}\u{627}\u{646}\u{64A}\u{629}"
            : "\(value) sec remaining"
        }

        let minutes =
            value / 60

        let secs =
            value % 60

        return isArabic
        ? "\u{645}\u{62A}\u{628}\u{642}\u{64A} \(minutes) \u{62F}\u{642}\u{64A}\u{642}\u{629} \u{648} \(secs) \u{62B}\u{627}\u{646}\u{64A}\u{629}"
        : "\(minutes)m \(secs)s remaining"
    }

    private func libraryPackageWasSent(_ package: LibraryPackage) -> Bool {
        historyStore.items.contains { item in
            guard item.completed else { return false }
            if !package.contentID.isEmpty, let contentID = item.contentID, !contentID.isEmpty {
                return contentID.caseInsensitiveCompare(package.contentID) == .orderedSame &&
                    (item.version ?? "") == package.version &&
                    (item.packageKind ?? "") == package.kindRawValue
            }
            return item.fileName.caseInsensitiveCompare(package.fileName) == .orderedSame
        }
    }

    private func libraryPackageIsQueued(_ package: LibraryPackage) -> Bool {
        guard let url = libraryStore.fileURL(for: package) else { return false }
        let path = url.standardizedFileURL.path
        return packageQueue.contains { $0.url.standardizedFileURL.path == path }
    }

    private func sendLibraryPackage(_ package: LibraryPackage) {
        guard let url = libraryStore.fileURL(for: package), FileManager.default.fileExists(atPath: url.path) else {
            status = t("This PKG file is missing from the library.", "ملف PKG مفقود من المكتبة.")
            return
        }

        let metadata = PKGMetadata(
            title: package.title,
            titleID: package.titleID,
            contentID: package.contentID,
            version: package.version,
            category: package.category,
            kind: package.kind,
            iconData: libraryStore.iconData(for: package)
        )

        let item = PKGQueueItem(url: url, metadata: metadata, metadataError: nil, isReadingMetadata: false, fileSize: package.fileSize)
        if !packageQueue.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            packageQueue.insert(item, at: 0)
        }
        sortPackageQueue()
        if let selectedIndex = packageQueue.firstIndex(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }), selectedIndex != 0 {
            let selectedItem = packageQueue.remove(at: selectedIndex)
            packageQueue.insert(selectedItem, at: 0)
        }
        syncPrimarySelection()
        status = t("Sending…", "جارٍ الإرسال…")

        if !isSending {
            queueCompletedItemIDs.removeAll()
            queueItemProgress.removeAll()
            queueItemSpeed.removeAll()
            queueItemSentBytes.removeAll()
            queueItemTotalBytes.removeAll()
            queueRunning = packageQueue.count > 1
            currentHistoryBatchID = UUID()
            activeQueueIndex = 0
            DispatchQueue.main.async { startQueuePackage(at: 0) }
        }
    }

    private func queueLibraryPackage(_ package: LibraryPackage) {
        guard let url = libraryStore.fileURL(for: package), FileManager.default.fileExists(atPath: url.path) else {
            status = t("This PKG file is missing from the library.", "ملف PKG مفقود من المكتبة.")
            return
        }

        guard !packageQueue.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else {
            status = t("This package is already in the queue.", "هذا الملف موجود بالفعل في قائمة الانتظار.")
            return
        }

        let metadata = PKGMetadata(
            title: package.title, titleID: package.titleID, contentID: package.contentID,
            version: package.version, category: package.category, kind: package.kind,
            iconData: libraryStore.iconData(for: package)
        )
        packageQueue.append(PKGQueueItem(url: url, metadata: metadata, metadataError: nil, isReadingMetadata: false, fileSize: package.fileSize))
        sortPackageQueue()
        syncPrimarySelection()
        status = t("Added to install queue.", "تمت الإضافة إلى قائمة الانتظار.")
    }

    // ======================================================
    // MARK: - Send
    // ======================================================

    private func sendPackage() {

        guard !packageQueue.isEmpty else {
            status = t("Select a PKG file first.", "\u{627}\u{62E}\u{62A}\u{631} \u{645}\u{644}\u{641} PKG \u{623}\u{648}\u{644}\u{627}\u{64B}.")
            return
        }

        sortPackageQueue()
        queueCompletedItemIDs.removeAll()
        queueItemProgress.removeAll()
        queueItemSpeed.removeAll()
        queueItemSentBytes.removeAll()
        queueItemTotalBytes.removeAll()
        queueRunning = packageQueue.count > 1
        currentHistoryBatchID = UUID()
        activeQueueIndex = 0
        startQueuePackage(at: 0)
    }

    private func startQueuePackage(at index: Int) {

        guard packageQueue.indices.contains(index) else {
            queueRunning = false
            activeQueueIndex = nil
            status = t(
                "Install queue completed successfully.",
                "\u{627}\u{643}\u{62A}\u{645}\u{644}\u{62A} \u{642}\u{627}\u{626}\u{645}\u{629} \u{627}\u{644}\u{62A}\u{62B}\u{628}\u{64A}\u{62A} \u{628}\u{646}\u{62C}\u{627}\u{62D}."
            )
            return
        }

        activeQueueIndex = index
        selectedFile = packageQueue[index].url
        selectedMetadata = packageQueue[index].metadata
        metadataError = packageQueue[index].metadataError
        isReadingMetadata = false

        sendCurrentPackage()
    }

    private func sendCurrentPackageOverUSB() {
        guard let file = selectedFile else {
            status = t("Select a PKG file first.", "اختر ملف PKG أولاً.")
            return
        }

        // Keep the bridge pointed at exactly the file shown in Home, then arm it.
        // Progress comes from unique READ ranges requested by the PS4 payload, so
        // BGFT retries/probes do not inflate the percentage.
        USBBridgeServer.shared.setTransferObserver { snapshot in
            DispatchQueue.main.async {
                guard self.isSending else { return }
                self.applyUSBTransferSnapshot(snapshot)
            }
        }
        USBBridgeServer.shared.setSelectedFile(file)
        USBBridgeServer.shared.armSelectedFile()

        prepareNewTransfer()
        transferStartDate = Date()
        speedSamplesTotal = 0
        speedSamplesCount = 0
        peakSpeed = 0
        historySavedForTransfer = false
        isSending = true
        UIApplication.shared.isIdleTimerDisabled = true
        status = t(
            "USB ready. Sending selected payload to GoldHEN…",
            "USB جاهز. جارٍ إرسال البايلود المختار إلى GoldHEN…"
        )

        PayloadManager.shared.sendBuiltInPayload(host: psIP) { result in
            switch result {
            case .success:
                status = t(
                    "Payload sent. Waiting for the PS4 USB bridge…",
                    "تم إرسال البايلود. بانتظار اتصال USB من البلايستيشن…"
                )
            case .failure(let error):
                USBBridgeServer.shared.disarm()
                isSending = false
                UIApplication.shared.isIdleTimerDisabled = false
                status = t(
                    "Could not start USB payload: \(error.localizedDescription) Make sure GoldHEN BinLoader is enabled on port 9090.",
                    "تعذر تشغيل بايلود USB: \(error.localizedDescription) تأكد أن GoldHEN BinLoader مفعّل على المنفذ 9090."
                )
            }
        }
    }

    private func applyUSBTransferSnapshot(_ transfer: USBTransferSnapshot) {
        progress = transfer.fraction
        sentBytes = transfer.sentBytes
        totalBytes = transfer.totalBytes
        speed = transfer.bytesPerSecond
        remainingSeconds = transfer.remainingSeconds

        if let current = activeQueueIndex, packageQueue.indices.contains(current) {
            let itemID = packageQueue[current].id
            queueItemProgress[itemID] = transfer.fraction
            queueItemSpeed[itemID] = transfer.bytesPerSecond
            queueItemSentBytes[itemID] = transfer.sentBytes
            queueItemTotalBytes[itemID] = transfer.totalBytes
        }

        if transfer.bytesPerSecond > 0 {
            speedSamplesTotal += transfer.bytesPerSecond
            speedSamplesCount += 1
            peakSpeed = max(peakSpeed, transfer.bytesPerSecond)
        }

        if transfer.fraction >= 1 {
            finishUSBTransfer()
        } else if transfer.sentBytes > 0 {
            status = t("Transferring package over USB…", "جارٍ نقل ملف PKG عبر USB…")
        }
    }

    private func finishUSBTransfer() {
        guard isSending else { return }

        USBBridgeServer.shared.disarm()
        if let current = activeQueueIndex, packageQueue.indices.contains(current) {
            let itemID = packageQueue[current].id
            queueCompletedItemIDs.insert(itemID)
            queueItemProgress[itemID] = 1
            queueItemSpeed[itemID] = speed
            queueItemSentBytes[itemID] = totalBytes
            queueItemTotalBytes[itemID] = totalBytes
        }

        progress = 1
        sentBytes = totalBytes
        completed = true
        isSending = false
        UIApplication.shared.isIdleTimerDisabled = false
        saveHistory(completed: true)
        status = t("USB transfer completed successfully.", "اكتمل نقل USB بنجاح.")

        if queueRunning, let current = activeQueueIndex {
            let next = current + 1
            if packageQueue.indices.contains(next) {
                status = t(
                    "Package \(current + 1) completed. Starting \(next + 1) of \(packageQueue.count)…",
                    "اكتمل الملف \(current + 1). جارٍ بدء \(next + 1) من \(packageQueue.count)…"
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.startQueuePackage(at: next)
                }
            } else {
                queueRunning = false
                activeQueueIndex = nil
                let finishedURLs = packageQueue.map { $0.url }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.cleanupStagedPackages(finishedURLs)
                    self.packageQueue.removeAll()
                }
                status = t("Install queue completed successfully.", "اكتملت قائمة التثبيت بنجاح.")
            }
        } else if let file = selectedFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.cleanupStagedPackages([file])
                if self.packageQueue.count == 1 { self.packageQueue.removeAll() }
            }
        }
    }

    private func sendCurrentPackage() {

        if transferMode == .usb {
            sendCurrentPackageOverUSB()
            return
        }

        guard connectionIsValid
        else {

            status = t(
                "Check the PlayStation connection first.",
                "\u{627}\u{641}\u{62D}\u{635} \u{627}\u{62A}\u{635}\u{627}\u{644} \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{623}\u{648}\u{644}\u{627}\u{64B}."
            )

            return
        }

        guard let file =
            selectedFile
        else {

            status = t(
                "Select a PKG file first.",
                "\u{627}\u{62E}\u{62A}\u{631} \u{645}\u{644}\u{641} PKG \u{623}\u{648}\u{644}\u{627}\u{64B}."
            )

            return
        }

        let cleanIP =
            psIP.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard !cleanIP.isEmpty
        else {

            status = t(
                "Enter the PlayStation IP first.",
                "\u{623}\u{62F}\u{62E}\u{644} \u{639}\u{646}\u{648}\u{627}\u{646} IP \u{644}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{623}\u{648}\u{644}\u{627}\u{64B}."
            )

            return
        }

        prepareNewTransfer()

        // Start History Timer

        transferStartDate =
            Date()

        speedSamplesTotal = 0
        speedSamplesCount = 0
        peakSpeed = 0

        historySavedForTransfer =
            false

        isSending = true

        UIApplication.shared
            .isIdleTimerDisabled =
                true

        status = t(
            "Starting local server...",
            "\u{62C}\u{627}\u{631}\u{64A} \u{62A}\u{634}\u{63A}\u{64A}\u{644} \u{633}\u{64A}\u{631}\u{641}\u{631} \u{627}\u{644}\u{625}\u{631}\u{633}\u{627}\u{644}..."
        )

        do {

            let newServer =
                try makePKGHTTPServer(
                    fileURL: file,
                    targetPlayStationIP: cleanIP,

                    onReady: {
                        packageURL in

                        guard
                            self.isSending
                        else {
                            return
                        }

                        self.status =
                            self.t(
                                "PlayStation connected. Waiting for transfer...",
                                "\u{62A}\u{645} \u{627}\u{644}\u{627}\u{62A}\u{635}\u{627}\u{644} \u{628}\u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646}. \u{628}\u{627}\u{646}\u{62A}\u{638}\u{627}\u{631} \u{628}\u{62F}\u{621} \u{627}\u{644}\u{646}\u{642}\u{644}..."
                            )

                        self.install(
                            packageURL:
                                packageURL
                        )
                    },

                    onProgress: {
                        transfer in

                        guard
                            self.isSending
                        else {
                            return
                        }

                        self.progress =
                            transfer.fraction

                        self.sentBytes =
                            transfer.sentBytes

                        self.totalBytes =
                            transfer.totalBytes

                        self.speed =
                            transfer.bytesPerSecond

                        self.remainingSeconds =
                            transfer.remainingSeconds

                        if let current = self.activeQueueIndex,
                           self.packageQueue.indices.contains(current) {
                            let itemID = self.packageQueue[current].id
                            self.queueItemProgress[itemID] = transfer.fraction
                            self.queueItemSpeed[itemID] = transfer.bytesPerSecond
                            self.queueItemSentBytes[itemID] = transfer.sentBytes
                            self.queueItemTotalBytes[itemID] = transfer.totalBytes
                        }

                        // Collect speed samples
                        // only when real transfer
                        // speed is available.

                        if transfer
                            .bytesPerSecond > 0 {

                            self
                                .speedSamplesTotal +=
                                transfer
                                    .bytesPerSecond

                            self
                                .speedSamplesCount +=
                                1

                            self.peakSpeed = max(
                                self.peakSpeed,
                                transfer.bytesPerSecond
                            )
                        }

                        if transfer
                            .fraction >= 1 {

                            if let current = self.activeQueueIndex,
                               self.packageQueue.indices.contains(current) {
                                let itemID = self.packageQueue[current].id
                                self.queueCompletedItemIDs.insert(itemID)
                                self.queueItemProgress[itemID] = 1
                                self.queueItemSpeed[itemID] = transfer.bytesPerSecond
                            }

                            self.completed =
                                true

                            self.isSending =
                                false

                            UIApplication
                                .shared
                                .isIdleTimerDisabled =
                                    false

                            self.saveHistory(
                                completed:
                                    true
                            )

                            if !self.queueRunning, let file = self.selectedFile {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                    self.cleanupStagedPackages([file])
                                    if self.packageQueue.count == 1 {
                                        self.packageQueue.removeAll()
                                    }
                                }
                            }

                            self.status =
                                self.t(
                                    "Transfer completed successfully.",
                                    "\u{627}\u{643}\u{62A}\u{645}\u{644} \u{646}\u{642}\u{644} \u{627}\u{644}\u{645}\u{644}\u{641} \u{628}\u{646}\u{62C}\u{627}\u{62D}."
                                )

                            if self.queueRunning,
                               let current = self.activeQueueIndex {

                                self.server?.stop()
                                self.server = nil

                                let next = current + 1

                                if self.packageQueue.indices.contains(next) {

                                    self.status = self.t(
                                        "Package \(current + 1) completed. Starting \(next + 1) of \(self.packageQueue.count)…",
                                        "\u{627}\u{643}\u{62A}\u{645}\u{644} \u{627}\u{644}\u{645}\u{644}\u{641} \(current + 1). \u{62C}\u{627}\u{631}\u{64D} \u{628}\u{62F}\u{621} \(next + 1) \u{645}\u{646} \(self.packageQueue.count)…"
                                    )

                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                        self.startQueuePackage(at: next)
                                    }

                                } else {

                                    self.queueRunning = false
                                    self.activeQueueIndex = nil

                                    let finishedURLs = self.packageQueue.map { $0.url }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                        self.cleanupStagedPackages(finishedURLs)
                                        self.packageQueue.removeAll()
                                    }

                                    self.status = self.t(
                                        "Install queue completed successfully.",
                                        "\u{627}\u{643}\u{62A}\u{645}\u{644}\u{62A} \u{642}\u{627}\u{626}\u{645}\u{629} \u{627}\u{644}\u{62A}\u{62B}\u{628}\u{64A}\u{62A} \u{628}\u{646}\u{62C}\u{627}\u{62D}."
                                    )
                                }
                            }

                        } else {

                            self.status =
                                self.t(
                                    "Transferring package...",
                                    "\u{62C}\u{627}\u{631}\u{64A} \u{646}\u{642}\u{644} \u{645}\u{644}\u{641} PKG..."
                                )
                        }
                    }
                )

            server =
                newServer

            try newServer
                .start()

        } catch {

            isSending = false

            UIApplication.shared
                .isIdleTimerDisabled =
                    false

            status = isArabic
            ? "\u{62E}\u{637}\u{623} \u{641}\u{64A} \u{627}\u{644}\u{633}\u{64A}\u{631}\u{641}\u{631}: \(error.localizedDescription)"
            : "Server error: \(error.localizedDescription)"
        }
    }

    // ======================================================
    // MARK: - Cancel
    // ======================================================

    private func cancelTransfer() {

        if transferMode == .usb {
            USBBridgeServer.shared.disarm()
            USBBridgeServer.shared.setTransferObserver(nil)
        }

        // Save history BEFORE
        // resetting transfer data.

        saveHistory(
            completed: false
        )

        isSending = false
        queueRunning = false
        activeQueueIndex = nil
        wasCancelled = true
        completed = false

        server?.stop()
        server = nil

        cleanupStagedPackages(packageQueue.map { $0.url })
        packageQueue.removeAll()
        selectedFile = nil
        selectedMetadata = nil
        metadataError = nil
        queueCompletedItemIDs.removeAll()
        queueItemProgress.removeAll()
        queueItemSpeed.removeAll()
        queueItemSentBytes.removeAll()
        queueItemTotalBytes.removeAll()

        speed = 0
        remainingSeconds = nil

        UIApplication.shared
            .isIdleTimerDisabled =
                false

        status = t(
            "Transfer cancelled.",
            "\u{62A}\u{645} \u{625}\u{644}\u{63A}\u{627}\u{621} \u{627}\u{644}\u{646}\u{642}\u{644}."
        )
    }

    // ======================================================
    // MARK: - Save History
    // ======================================================

    private func saveHistory(
        completed:
            Bool
    ) {

        guard
            !historySavedForTransfer,
            let file =
                selectedFile,
            let start =
                transferStartDate
        else {
            return
        }

        historySavedForTransfer =
            true

        let duration =
            max(
                0,
                Date()
                    .timeIntervalSince(
                        start
                    )
            )

        let averageSpeed:
            Double

        if speedSamplesCount > 0 {

            averageSpeed =
                speedSamplesTotal /
                Double(
                    speedSamplesCount
                )

        } else {

            averageSpeed = 0
        }

        let item =
            TransferHistoryItem(
                fileName:
                    file.lastPathComponent,

                totalBytes:
                    totalBytes,

                transferredBytes:
                    sentBytes,

                averageSpeed:
                    averageSpeed,

                peakSpeed:
                    peakSpeed,

                duration:
                    duration,

                completed:
                    completed,

                batchID:
                    currentHistoryBatchID,

                title:
                    selectedMetadata?.title,

                titleID:
                    selectedMetadata?.titleID,

                contentID:
                    selectedMetadata?.contentID,

                version:
                    selectedMetadata?.version,

                packageKind:
                    selectedMetadata?.kind.rawValue,

                iconData:
                    historyThumbnailData(from: selectedMetadata?.iconData),

                transferType:
                    transferMode == .usb ? "USB" : "Network"
            )

        historyStore.add(
            item
        )
    }

    private func historyThumbnailData(from data: Data?) -> Data? {
        guard let data, let image = UIImage(data: data) else { return nil }
        let size = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumb = renderer.image { _ in
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return thumb.jpegData(compressionQuality: 0.78)
    }

    // ======================================================
    // MARK: - Install
    // ======================================================

    private func install(
        packageURL:
            String
    ) {

        guard isSending else {
            return
        }

        let cleanIP =
            psIP.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        let cleanPort =
            psPort.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            let portNumber =
                Int(cleanPort),

            (1...65535)
                .contains(
                    portNumber
                ),

            let url =
                URL(
                    string:
                        "http://\(cleanIP):\(portNumber)/api/install"
                )

        else {

            isSending = false

            UIApplication.shared
                .isIdleTimerDisabled =
                    false

            status = t(
                "Invalid PlayStation address or port.",
                "\u{639}\u{646}\u{648}\u{627}\u{646} \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{623}\u{648} \u{627}\u{644}\u{645}\u{646}\u{641}\u{630} \u{63A}\u{64A}\u{631} \u{635}\u{62D}\u{64A}\u{62D}."
            )

            return
        }

        var request =
            URLRequest(
                url: url
            )

        request.httpMethod =
            "POST"

        // Fail fast if the RPI connection disappeared after the last successful check.
        // More importantly, never leave the UI showing a green Connected badge after
        // /api/install itself has failed.
        let isHotspotTarget = cleanIP.hasPrefix("172.20.10.")
        request.timeoutInterval = isHotspotTarget ? 15 : 10
        TransferDiagnostics.log("RPI POST config hotspot=\(isHotspotTarget) timeout=\(Int(request.timeoutInterval))s")

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        let body:
            [String: Any] = [

                "type":
                    "direct",

                "packages": [
                    packageURL
                ]
            ]

        do {

            request.httpBody =
                try JSONSerialization
                    .data(
                        withJSONObject:
                            body
                    )

        } catch {

            isSending = false

            UIApplication.shared
                .isIdleTimerDisabled =
                    false

            status = isArabic
            ? "\u{62E}\u{637}\u{623} JSON: \(error.localizedDescription)"
            : "JSON error: \(error.localizedDescription)"

            return
        }

        TransferDiagnostics.log("RPI POST begin endpoint=\(url.absoluteString) package=\(packageURL)")

        URLSession.shared
            .dataTask(
                with: request
            ) {
                data,
                response,
                error in

                DispatchQueue
                    .main
                    .async {

                        guard
                            self
                                .isSending
                        else {
                            return
                        }

                        if let error =
                            error {

                            TransferDiagnostics.log("RPI POST error=\(error.localizedDescription)")
                            self.connectionState = .disconnected
                            self.checkedIP = ""
                            self.checkedPort = ""

                            self.isSending =
                                false

                            UIApplication
                                .shared
                                .isIdleTimerDisabled =
                                    false

                            self.status =
                                self.isArabic
                                ? "\u{62E}\u{637}\u{623} \u{641}\u{64A} \u{627}\u{644}\u{625}\u{631}\u{633}\u{627}\u{644}: \(error.localizedDescription)"
                                : "Send error: \(error.localizedDescription)"

                            return
                        }

                        if let http =
                            response
                            as?
                            HTTPURLResponse {

                            TransferDiagnostics.log("RPI POST response status=\(http.statusCode) bytes=\(data?.count ?? 0)")

                            if (200...299)
                                .contains(
                                    http
                                        .statusCode
                                ) {

                                self.status =
                                    self.t(
                                        "PlayStation accepted the package. Waiting for download...",
                                        "\u{62A}\u{645} \u{642}\u{628}\u{648}\u{644} \u{627}\u{644}\u{645}\u{644}\u{641} \u{645}\u{646} \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646}. \u{628}\u{627}\u{646}\u{62A}\u{638}\u{627}\u{631} \u{628}\u{62F}\u{621} \u{627}\u{644}\u{62A}\u{62D}\u{645}\u{64A}\u{644}..."
                                    )

                            } else {

                                self.connectionState = .disconnected
                                self.checkedIP = ""
                                self.checkedPort = ""

                                self.isSending =
                                    false

                                UIApplication
                                    .shared
                                    .isIdleTimerDisabled =
                                        false

                                self.status =
                                    self.isArabic
                                    ? "\u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{623}\u{639}\u{627}\u{62F} \u{62E}\u{637}\u{623} HTTP \(http.statusCode)"
                                    : "PlayStation returned HTTP \(http.statusCode)"
                            }
                        }

                        if let data =
                            data,

                           let text =
                            String(
                                data:
                                    data,
                                encoding:
                                    .utf8
                            ),

                           !text.isEmpty {

                            print(
                                "PlayStation: \(text)"
                            )
                        }
                    }
            }
            .resume()
    }

    // ======================================================
    // MARK: - Reset
    // ======================================================

    private func prepareNewTransfer() {

        server?.stop()
        server = nil

        progress = 0
        sentBytes = 0
        totalBytes = 0
        speed = 0

        remainingSeconds = nil

        completed = false
        wasCancelled = false
        isSending = false

        transferStartDate = nil

        speedSamplesTotal = 0
        speedSamplesCount = 0
        peakSpeed = 0

        historySavedForTransfer =
            false
    }

    private func clearTransferDisplay() {

        server?.stop()
        server = nil

        progress = 0
        sentBytes = 0
        totalBytes = 0
        speed = 0

        remainingSeconds = nil

        completed = false
        wasCancelled = false
        isSending = false
        queueRunning = false
        activeQueueIndex = nil

        transferStartDate = nil

        speedSamplesTotal = 0
        speedSamplesCount = 0
        peakSpeed = 0

        historySavedForTransfer =
            false

        UIApplication.shared
            .isIdleTimerDisabled =
                false
    }

    // ======================================================
    // MARK: - Language
    // ======================================================

    private func t(
        _ english: String,
        _ arabic: String
    ) -> String {

        isArabic
        ? arabic
        : english
    }

    private func updateStatusForLanguage() {

        if completed {

            status = t(
                "Transfer completed successfully.",
                "\u{627}\u{643}\u{62A}\u{645}\u{644} \u{646}\u{642}\u{644} \u{627}\u{644}\u{645}\u{644}\u{641} \u{628}\u{646}\u{62C}\u{627}\u{62D}."
            )

        } else if wasCancelled {

            status = t(
                "Transfer cancelled.",
                "\u{62A}\u{645} \u{625}\u{644}\u{63A}\u{627}\u{621} \u{627}\u{644}\u{646}\u{642}\u{644}."
            )

        } else if isSending {

            status = t(
                "Transferring package...",
                "\u{62C}\u{627}\u{631}\u{64A} \u{646}\u{642}\u{644} \u{645}\u{644}\u{641} PKG..."
            )

        } else {

            switch connectionState {

            case .connected:

                status = t(
                    "PlayStation is connected and ready.",
                    "\u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{645}\u{62A}\u{635}\u{644} \u{648}\u{62C}\u{627}\u{647}\u{632}."
                )

            case .disconnected:

                status = t(
                    "PlayStation is not connected.",
                    "\u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{63A}\u{64A}\u{631} \u{645}\u{62A}\u{635}\u{644}."
                )

            case .checking:

                status = t(
                    "Checking Remote Package Installer...",
                    "\u{62C}\u{627}\u{631}\u{64A} \u{641}\u{62D}\u{635} Remote Package Installer..."
                )

            case .notChecked:

                status = t(
                    "Enter your PlayStation IP and check the connection.",
                    "\u{623}\u{62F}\u{62E}\u{644} IP \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{62B}\u{645} \u{627}\u{641}\u{62D}\u{635} \u{627}\u{644}\u{627}\u{62A}\u{635}\u{627}\u{644}."
                )
            }
        }
    }

    // ======================================================
    // MARK: - Formatting
    // ======================================================

    private func formatBytes(
        _ bytes:
            UInt64
    ) -> String {

        let formatter =
            ByteCountFormatter()

        formatter.countStyle =
            .file

        return formatter.string(
            fromByteCount:
                Int64(bytes)
        )
    }

    private func formatSpeed(
        _ bytesPerSecond:
            Double
    ) -> String {

        guard
            bytesPerSecond > 0
        else {
            return "—"
        }

        let formatter =
            ByteCountFormatter()

        formatter.countStyle =
            .file

        let formatted =
            formatter.string(
                fromByteCount:
                    Int64(
                        bytesPerSecond
                    )
            )

        return "\(formatted)/s"
    }
}


// ======================================================
// MARK: - History View
// ======================================================

enum PKGMainTab: String, CaseIterable, Identifiable {
    case home, history, library, tools, settings
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .history: return "clock.arrow.circlepath"
        case .library: return "books.vertical.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .settings: return "gearshape.fill"
        }
    }

    func title(isArabic: Bool) -> String {
        switch self {
        case .home: return isArabic ? "الرئيسية" : "Home"
        case .history: return isArabic ? "السجل" : "History"
        case .library: return isArabic ? "المكتبة" : "Library"
        case .tools: return isArabic ? "الأدوات" : "Tools"
        case .settings: return isArabic ? "الإعدادات" : "Settings"
        }
    }
}

private struct PKGBottomTabBar: View {
    @Binding var selectedTab: PKGMainTab
    let isArabic: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PKGMainTab.allCases) { tab in
                Button {
                    // Do not animate the whole page tree. The selected capsule still
                    // updates immediately, while heavy tabs such as History are not
                    // inserted under a global transaction.
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(tab.title(isArabic: isArabic))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(Color.primary.opacity(0.09))
                                .padding(.horizontal, 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 5)
    }
}

private struct UnifiedPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 25, weight: .bold, design: .rounded))
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

private extension UnifiedPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct HistoryView: View {
    @ObservedObject var store: TransferHistoryStore
    let appLanguage: String
    @Environment(\.dismiss) private var dismiss
    @State private var expandedID: UUID?
    @State private var showClearAlert = false
    @State private var cachedGroups: [HistoryGroup] = []

    private var isArabic: Bool { appLanguage == "ar" }
    private var layoutDirection: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }

    private struct HistoryGroup: Identifiable {
        let id: UUID
        let items: [TransferHistoryItem]
        var newest: TransferHistoryItem { items.max(by: { $0.date < $1.date })! }
        var allCompleted: Bool { items.allSatisfy(\.completed) }
        var anyCompleted: Bool { items.contains(where: \.completed) }
        var totalBytes: UInt64 { items.reduce(0) { $0 + $1.totalBytes } }
        var transferredBytes: UInt64 { items.reduce(0) { $0 + $1.transferredBytes } }
    }

    private func rebuildGroups() {
        var map: [UUID: [TransferHistoryItem]] = [:]
        for item in store.items {
            map[item.batchID ?? item.id, default: []].append(item)
        }
        cachedGroups = map.map { HistoryGroup(id: $0.key, items: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.newest.date > $1.newest.date }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                UnifiedPageHeader(
                    title: isArabic ? "السجل" : "History",
                    subtitle: isArabic ? "عمليات النقل" : "Transfers"
                ) {
                    Button { showClearAlert = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.items.isEmpty)
                    .opacity(store.items.isEmpty ? 0.34 : 1)
                }
                .padding(.horizontal, 16)

                Group {
                    if store.items.isEmpty { emptyView }
                    else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(cachedGroups) { group in historyCard(group) }
                                Color.clear.frame(height: 110)
                            }.padding(.horizontal, 16).padding(.bottom, 8)
                        }
                    }
                }
            }
            .background(PKGTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .alert(isArabic ? "مسح سجل الإرسالات؟" : "Clear Transfer History?", isPresented: $showClearAlert) {
                Button(isArabic ? "إلغاء" : "Cancel", role: .cancel) { }
                Button(isArabic ? "مسح" : "Clear", role: .destructive) { withAnimation { expandedID = nil; store.clear() } }
            } message: {
                Text(isArabic ? "سيتم حذف جميع عمليات الإرسال المحفوظة من هذا الجهاز." : "All saved transfer history will be deleted from this device.")
            }
        }
        .environment(\.layoutDirection, layoutDirection)
        .onAppear { rebuildGroups() }
        .onChange(of: store.items.map(\.id)) { _ in rebuildGroups() }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 48)).foregroundColor(.secondary)
            Text(isArabic ? "لا يوجد سجل إرسال" : "No Transfer History").font(.headline)
            Text(isArabic ? "ستظهر هنا عمليات إرسال ملفات PKG بعد الإرسال أو الإلغاء." : "Completed and cancelled PKG transfers will appear here.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding().background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func historyCard(_ group: HistoryGroup) -> some View {
        let expanded = expandedID == group.id
        let lead = group.items.first(where: { $0.packageKind == "GAME" }) ?? group.items.first!
        let title = (lead.title?.isEmpty == false ? lead.title! : lead.fileName)
        let stateColor: Color = group.allCompleted ? .green : (group.anyCompleted ? .orange : .red)
        let stateText = group.allCompleted ? (isArabic ? "اكتمل" : "Completed") : (group.anyCompleted ? (isArabic ? "اكتمل جزئياً" : "Partial") : (isArabic ? "تم الإلغاء" : "Cancelled"))

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.20, extraBounce: 0)) { expandedID = expanded ? nil : group.id }
            } label: {
                HStack(spacing: 12) {
                    historyArtwork(lead, color: stateColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline).foregroundColor(.primary).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(stateText).foregroundColor(stateColor)
                            if group.items.count > 1 { Text("•"); Text("\(group.items.count) PKGs") }
                            Text("•"); Text(shortDate(group.newest.date))
                        }.font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.bold()).foregroundColor(.secondary)
                }.padding().contentShape(Rectangle())
            }.buttonStyle(.plain)

            if expanded {
                Divider().padding(.horizontal)
                VStack(alignment: .leading, spacing: 12) {
                    if group.items.count > 1 {
                        HStack {
                            Label(isArabic ? "\(group.items.count) ملفات في هذه العملية" : "\(group.items.count) packages in this transfer", systemImage: "square.stack.3d.up.fill")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(formatBytes(group.totalBytes)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    ForEach(group.items) { item in packageHistoryDetails(item) }
                    Button { withAnimation(.snappy(duration: 0.20, extraBounce: 0)) { expandedID = nil } } label: {
                        HStack { Spacer(); Image(systemName: "chevron.up"); Text(isArabic ? "إغلاق التفاصيل" : "Close Details").fontWeight(.semibold); Spacer() }
                    }.buttonStyle(.bordered)
                }.padding().transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(PKGTheme.surface))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func historyArtwork(_ item: TransferHistoryItem, color: Color) -> some View {
        if let data = item.iconData, let image = UIImage(data: data) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: color.opacity(0.48), radius: 7)

                Image(systemName: item.completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72), color.opacity(0.58))
                    .opacity(0.72)
                    .offset(x: 5, y: 5)
            }
            .frame(width: 57, height: 57, alignment: .topLeading)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)).frame(width: 52, height: 52)
                Image(systemName: item.completed ? "checkmark.circle.fill" : "xmark.circle.fill").font(.title3).foregroundColor(color)
            }
        }
    }

    private func packageHistoryDetails(_ item: TransferHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                historyArtwork(item, color: item.completed ? .green : .red).scaleEffect(0.82)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title?.isEmpty == false ? item.title! : item.fileName).font(.subheadline.weight(.bold)).lineLimit(1)
                    HStack(spacing: 6) {
                        if let kind = item.packageKind { Text(kind) }
                        if let version = item.version, !version.isEmpty { Text("v\(version)") }
                        Text(item.completed ? (isArabic ? "اكتمل" : "Completed") : (isArabic ? "تم الإلغاء" : "Cancelled")).foregroundColor(item.completed ? .green : .red)
                    }.font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            historyDetail(icon: "doc.fill", title: isArabic ? "الاسم الكامل" : "Full File Name", value: item.fileName)
            if let titleID = item.titleID, !titleID.isEmpty { historyDetail(icon: "tag.fill", title: "Title ID", value: titleID) }
            if let contentID = item.contentID, !contentID.isEmpty { historyDetail(icon: "number", title: "Content ID", value: contentID) }
            historyDetail(icon: "externaldrive.fill", title: isArabic ? "حجم الملف" : "File Size", value: formatBytes(item.totalBytes))
            historyDetail(icon: "arrow.up.arrow.down", title: isArabic ? "تم نقله" : "Transferred", value: "\(formatBytes(item.transferredBytes)) / \(formatBytes(item.totalBytes))")
            if let transferType = item.transferType { historyDetail(icon: transferType == "USB" ? "cable.connector" : "network", title: isArabic ? "نوع النقل" : "Transfer Type", value: transferType) }
            historyDetail(icon: "speedometer", title: isArabic ? "متوسط السرعة" : "Average Speed", value: formatSpeed(item.averageSpeed))
            if let peak = item.peakSpeed, peak > 0 {
                historyDetail(icon: "gauge.with.dots.needle.67percent", title: isArabic ? "أعلى سرعة" : "Peak Speed", value: formatSpeed(peak))
            }
            historyDetail(icon: "timer", title: item.completed ? (isArabic ? "مدة النقل" : "Transfer Time") : (isArabic ? "المدة قبل الإلغاء" : "Time Before Cancellation"), value: formatDuration(item.duration))
            historyDetail(icon: "calendar", title: isArabic ? "التاريخ والوقت" : "Date & Time", value: fullDate(item.date))
        }.padding(12).background(RoundedRectangle(cornerRadius: 14).fill(PKGTheme.elevatedSurface))
    }

    private func historyDetail(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromByteCount: Int64(bytes))
    }
    private func formatSpeed(_ speed: Double) -> String {
        guard speed > 0 else { return "—" }
        let f = ByteCountFormatter(); f.countStyle = .file; return "\(f.string(fromByteCount: Int64(speed)))/s"
    }
    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded())); let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: isArabic ? "ar" : "en_US"); f.dateStyle = .short; f.timeStyle = .short; return f.string(from: date)
    }
    private func fullDate(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: isArabic ? "ar" : "en_US"); f.dateStyle = .medium; f.timeStyle = .medium; return f.string(from: date)
    }
}


// ======================================================
// MARK: - Settings View
// ======================================================

struct SettingsView: View {
    @Binding var appLanguage: String
    @Binding var psPort: String
    @AppStorage("libraryAppearance") private var libraryAppearance = "minimalist"
    @AppStorage("appTheme") private var appTheme = "charcoal"
    @AppStorage("gameHubAppearance") private var gameHubAppearance = "original"

    private var isArabic: Bool { appLanguage == "ar" }
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    UnifiedPageHeader(title: t("Settings", "الإعدادات"), subtitle: t("Make PKG Sender yours", "خصص PKG Sender بطريقتك"))

                    settingsGroup(t("GENERAL", "عام")) {
                        NavigationLink { AppearanceSettings(isArabic: isArabic, appTheme: $appTheme, libraryAppearance: $libraryAppearance, gameHubAppearance: $gameHubAppearance) } label: {
                            settingsRow(icon: "paintpalette.fill", tint: .indigo, title: t("Appearance", "المظهر"), value: t("Theme • Library • Game Hub", "الثيم • المكتبة • مركز اللعبة"))
                        }
                        rowDivider
                        NavigationLink { LanguageSettings(appLanguage: $appLanguage) } label: {
                            settingsRow(icon: "globe", tint: .cyan, title: t("Language", "اللغة"), value: isArabic ? "العربية" : "English")
                        }
                        rowDivider
                        NavigationLink { PlayStationSettings(psPort: $psPort, isArabic: isArabic) } label: {
                            settingsRow(icon: "gamecontroller.fill", tint: .purple, title: t("PlayStation", "بلايستيشن"), value: "RPI")
                        }
                    }

                    settingsGroup(t("SUPPORT & ADVANCED", "الدعم والمتقدم")) {
                        NavigationLink { PayloadSettingsView(isArabic: isArabic) } label: {
                            settingsRow(icon: "bolt.horizontal.circle.fill", tint: .green, title: t("USB Payload", "بايلود USB"), value: PayloadManager.shared.hasCustomPayload ? t("Custom", "يدوي") : PayloadManager.shared.bundledVersion())
                        }
                        rowDivider
                        NavigationLink { DiagnosticsView(appLanguage: appLanguage) } label: {
                            settingsRow(icon: "stethoscope", tint: .orange, title: t("Diagnostics & Errors", "التشخيص والأخطاء"))
                        }
                        rowDivider
                        NavigationLink { AboutView(appLanguage: appLanguage) } label: {
                            settingsRow(icon: "info.circle.fill", tint: .blue, title: t("About PKG Sender", "حول PKG Sender"))
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(t("LIBRARY PREVIEW", "معاينة المكتبة")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.grid.2x2.fill").font(.system(size: 25, weight: .semibold)).foregroundStyle(.blue).frame(width: 48, height: 48).background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t("Library style", "تشكيلة المكتبة") + ": " + libraryAppearance.capitalized).font(.headline)
                                Text(t("Both layouts open the same Game Hub.", "كلا التصميمين يفتحان نفس مركز اللعبة.")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(15).background(PKGTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 18).padding(.top, 8)
            }
            .background(PKGTheme.background.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
        .id("settings-\(appLanguage)")
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 13)
                .background(PKGTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.055), lineWidth: 0.7))
        }
    }

    private func settingsRow(icon: String, tint: Color, title: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(width: 34, height: 34).background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
            Spacer()
            if let value { Text(value).font(.subheadline).foregroundStyle(.secondary) }
            Image(systemName: "chevron.forward").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }.frame(minHeight: 58).contentShape(Rectangle())
    }

    private var rowDivider: some View { Divider().opacity(0.14).padding(.leading, 46) }
}


private struct PayloadSettingsView: View {
    let isArabic: Bool
    @State private var showImporter = false
    @State private var refreshToken = UUID()
    @State private var message: String?
    @State private var showRestore = false

    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }
    private var manager: PayloadManager { .shared }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: manager.hasCustomPayload ? "bolt.horizontal.fill" : "shippingbox.fill")
                        .foregroundStyle(manager.hasCustomPayload ? Color.green : Color.blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("Active Payload", "البايلود الحالي")).font(.headline)
                        Text(manager.activePayloadName()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }.padding(.vertical, 4)
            } header: {
                Text(t("USB PAYLOAD", "بايلود USB"))
            } footer: {
                Text(t("A manually imported ELF is copied into PKG Sender and stays selected until you restore the built-in payload.",
                       "ملف ELF الذي تضيفه يدويًا يُنسخ داخل PKG Sender ويظل هو المختار حتى ترجع للبايلود المدمج."))
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label(t("Choose ELF Manually", "اختيار ELF يدويًا"), systemImage: "folder.badge.plus")
                }

                if manager.hasCustomPayload {
                    Button(role: .destructive) {
                        showRestore = true
                    } label: {
                        Label(t("Restore Built-in Payload", "الرجوع للبايلود المدمج"), systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }

            if let message {
                Section {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .id(refreshToken)
        .navigationTitle(t("USB Payload", "بايلود USB"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImporter) {
            PKGDocumentPicker { urls in
                guard let url = urls.first else {
                    showImporter = false
                    return
                }
                do {
                    try manager.importCustomPayload(from: url)
                    message = t("Custom ELF selected. The next USB transfer will inject it automatically.",
                                "تم اختيار ELF اليدوي. النقل القادم عبر USB سيحقنه تلقائيًا.")
                    refreshToken = UUID()
                } catch {
                    message = error.localizedDescription
                }
                showImporter = false
            }
        }
        .alert(t("Restore built-in payload?", "الرجوع للبايلود المدمج؟"), isPresented: $showRestore) {
            Button(t("Cancel", "إلغاء"), role: .cancel) {}
            Button(t("Restore", "رجوع"), role: .destructive) {
                do {
                    try manager.restoreBuiltInPayload()
                    message = t("Built-in payload restored.", "تم الرجوع للبايلود المدمج.")
                    refreshToken = UUID()
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }
}

private struct AppearanceSettings: View {
    let isArabic: Bool
    @Binding var appTheme: String
    @Binding var libraryAppearance: String
    @Binding var gameHubAppearance: String

    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }
    private var libraryAppearanceName: String {
        switch libraryAppearance {
        case "og", "classic": return t("OG", "الأصلي")
        case "showcase": return t("Showcase", "استعراضي")
        case "compact": return t("Compact", "مضغوط")
        case "list": return t("List", "قائمة")
        case "coverflow": return t("Cover Flow", "تدفق الأغلفة")
        default: return t("Minimalist", "بسيط")
        }
    }
    private var gameHubAppearanceName: String {
        gameHubAppearance == "showcase" ? t("Showcase", "استعراضي") : t("Original", "أصلي")
    }

    var body: some View {
        List {
            Section {
                appearanceChoice(
                    id: "charcoal",
                    selection: $appTheme,
                    icon: "moon.stars.fill",
                    title: t("Charcoal", "فحمي"),
                    subtitle: t("Dark navy and charcoal appearance", "مظهر فحمي وكحلي داكن")
                )
                appearanceChoice(
                    id: "black",
                    selection: $appTheme,
                    icon: "circle.fill",
                    title: t("Black", "أسود"),
                    subtitle: t("Original deep black appearance", "المظهر الأسود الأصلي")
                )
                appearanceChoice(
                    id: "light",
                    selection: $appTheme,
                    icon: "sun.max.fill",
                    title: t("Light", "فاتح"),
                    subtitle: t("Bright system appearance", "مظهر النظام الفاتح")
                )
                appearanceChoice(
                    id: "system",
                    selection: $appTheme,
                    icon: "iphone",
                    title: t("System", "النظام"),
                    subtitle: t("Follow iPhone appearance", "يتبع مظهر الآيفون")
                )
            } header: {
                Text(t("THEME", "الثيم"))
            }

            Section {
                NavigationLink {
                    LibraryAppearanceSettings(isArabic: isArabic, selection: $libraryAppearance)
                } label: {
                    appearanceRow(
                        icon: "rectangle.grid.2x2.fill",
                        title: t("Library", "المكتبة"),
                        value: libraryAppearanceName
                    )
                }

                NavigationLink {
                    GameHubAppearanceSettings(isArabic: isArabic, selection: $gameHubAppearance)
                } label: {
                    appearanceRow(
                        icon: "gamecontroller.fill",
                        title: t("Game Hub", "مركز اللعبة"),
                        value: gameHubAppearanceName
                    )
                }
            } header: {
                Text(t("PAGES", "الصفحات"))
            }
        }
        .navigationTitle(t("Appearance", "المظهر"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
    }

    private func appearanceChoice(
        id: String,
        selection: Binding<String>,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection.wrappedValue = id
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 32)
                    .foregroundStyle(selection.wrappedValue == id ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if selection.wrappedValue == id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func appearanceRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(Color.accentColor)
            Text(title).font(.headline).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct LibraryAppearanceSettings: View {
    let isArabic: Bool
    @Binding var selection: String
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }
    var body: some View {
        List {
            Section {
                choice("og", icon: "rectangle.grid.3x2.fill", title: t("OG", "الأصلي"), subtitle: t("Original PKG Sender library layout", "تصميم مكتبة PKG Sender الأصلي"))
                choice("minimalist", icon: "square.grid.2x2.fill", title: t("Minimalist", "بسيط"), subtitle: t("Clean artwork-first grid", "شبكة نظيفة تركز على الأغلفة"))
                choice("showcase", icon: "rectangle.grid.1x2.fill", title: t("Showcase", "استعراضي"), subtitle: t("Large featured artwork with a focused title card", "غلاف بارز كبير مع بطاقة اسم هادئة"))
                choice("compact", icon: "square.grid.4x3.fill", title: t("Compact", "مضغوط"), subtitle: t("More games on screen at once", "ألعاب أكثر في الشاشة في نفس الوقت"))
                choice("list", icon: "list.bullet.rectangle.fill", title: t("List", "قائمة"), subtitle: t("Detailed vertical library list", "قائمة عمودية بتفاصيل أوضح"))
                choice("coverflow", icon: "rectangle.stack.fill", title: t("Cover Flow", "تدفق الأغلفة"), subtitle: t("Swipe through large game covers", "تنقل بين أغلفة الألعاب الكبيرة"))
            } footer: { Text(t("This only changes how games are displayed. Both styles use the same library data and Game Hub.", "هذا يغير طريقة عرض الألعاب فقط. كلا التصميمين يستخدمان نفس بيانات المكتبة ونفس مركز اللعبة.")) }
        }
        .navigationTitle(t("Library Appearance", "مظهر المكتبة"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func choice(_ id: String, icon: String, title: String, subtitle: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { selection = id } } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 32).foregroundStyle(selection == id ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer(); if selection == id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            }.padding(.vertical, 5)
        }.buttonStyle(.plain)
    }
}

private struct GameHubAppearanceSettings: View {
    let isArabic: Bool
    @Binding var selection: String
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }
    var body: some View {
        List {
            Section {
                choice("original", icon: "gamecontroller.fill", title: t("Original", "أصلي"), subtitle: t("Original Game Hub layout", "تصميم مركز اللعبة الأصلي"))
                choice("showcase", icon: "sparkles.rectangle.stack.fill", title: t("Showcase", "استعراضي"), subtitle: t("Large hero artwork and richer game details", "غلاف كبير وتفاصيل أغنى للعبة"))
            }
        }
        .navigationTitle(t("Game Hub Appearance", "مظهر مركز اللعبة"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func choice(_ id: String, icon: String, title: String, subtitle: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { selection = id } } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 32).foregroundStyle(selection == id ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer(); if selection == id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            }.padding(.vertical, 5)
        }.buttonStyle(.plain)
    }
}

private struct LanguageSettings: View {
    @Binding var appLanguage: String
    private var isArabic: Bool { appLanguage == "ar" }
    var body: some View {
        List {
            Button { appLanguage = "en" } label: { HStack { Text("English").foregroundStyle(.primary); Spacer(); if appLanguage == "en" { Image(systemName: "checkmark").foregroundStyle(.blue) } } }
            Button { appLanguage = "ar" } label: { HStack { Text("العربية").foregroundStyle(.primary); Spacer(); if appLanguage == "ar" { Image(systemName: "checkmark").foregroundStyle(.blue) } } }
        }.navigationTitle(isArabic ? "اللغة" : "Language").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlayStationSettings: View {
    @Binding var psPort: String
    let isArabic: Bool
    @State private var draft = ""
    @State private var showWarning = false
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }
    private var valid: Bool { Int(draft).map { (1...65535).contains($0) } ?? false }
    var body: some View {
        Form {
            Section {
                HStack { Label(t("Port", "المنفذ"), systemImage: "network"); Spacer(); Text(psPort).foregroundStyle(.secondary) }
                Button(t("Change Port", "تغيير المنفذ")) { draft = psPort; showWarning = true }
                if psPort != "12800" { Button(t("Reset to 12800", "إعادة إلى 12800")) { psPort = "12800" } }
            } header: {
                Text(t("REMOTE PACKAGE INSTALLER", "REMOTE PACKAGE INSTALLER"))
            } footer: {
                Text(t("12800 is the default RPI port. Change it only if your PlayStation service uses another port.", "12800 هو المنفذ الافتراضي لـ RPI. غيّره فقط إذا كانت الخدمة على البلايستيشن تستخدم منفذًا آخر."))
            }
        }
        .navigationTitle(t("PlayStation", "بلايستيشن")).navigationBarTitleDisplayMode(.inline)
        .alert(t("Change RPI Port", "تغيير منفذ RPI"), isPresented: $showWarning) {
            TextField("12800", text: $draft).keyboardType(.numberPad)
            Button(t("Cancel", "إلغاء"), role: .cancel) {}
            Button(t("Save", "حفظ")) { if valid { psPort = String(Int(draft)!) } }.disabled(!valid)
        } message: { Text(t("Only change this when you know RPI is listening on a different port.", "غيّر هذا فقط إذا كنت متأكدًا أن RPI يعمل على منفذ مختلف.")) }
    }
}


// ======================================================
// MARK: - First Launch View
// ======================================================

struct FirstLaunchView: View {
    @Binding var appLanguage: String
    let onContinue: () -> Void
    @State private var step = 0

    private var isArabic: Bool { appLanguage == "ar" }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor.opacity(0.13))
                        .frame(width: 72, height: 72)
                    Image(systemName: step == 0 ? "globe" : "sparkles")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                if step == 0 {
                    VStack(spacing: 7) {
                        Text("Choose your language").font(.title2.bold())
                        Text("\u{627}\u{62E}\u{62A}\u{631} \u{644}\u{63A}\u{62A}\u{643}")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }

                    VStack(spacing: 12) {
                        languageButton(title: "\u{627}\u{644}\u{639}\u{631}\u{628}\u{64A}\u{629}", subtitle: "Arabic", language: "ar")
                        languageButton(title: "English", subtitle: "English", language: "en")
                    }
                } else {
                    VStack(spacing: 10) {
                        Text(isArabic ? "\u{62A}\u{646}\u{628}\u{64A}\u{647} \u{642}\u{628}\u{644} \u{627}\u{644}\u{645}\u{62A}\u{627}\u{628}\u{639}\u{629}" : "Before You Continue")
                            .font(.title2.bold())
                        Text(
                            isArabic
                            ? "\u{62A}\u{645} \u{625}\u{646}\u{634}\u{627}\u{621} \u{62A}\u{637}\u{628}\u{64A}\u{642} PKG Sender \u{648}\u{643}\u{62A}\u{627}\u{628}\u{629} \u{623}\u{643}\u{648}\u{627}\u{62F}\u{647} \u{628}\u{627}\u{633}\u{62A}\u{62E}\u{62F}\u{627}\u{645} \u{627}\u{644}\u{630}\u{643}\u{627}\u{621} \u{627}\u{644}\u{627}\u{635}\u{637}\u{646}\u{627}\u{639}\u{64A}. \u{642}\u{62F} \u{64A}\u{62D}\u{62A}\u{648}\u{64A} \u{627}\u{644}\u{62A}\u{637}\u{628}\u{64A}\u{642} \u{639}\u{644}\u{649} \u{623}\u{62E}\u{637}\u{627}\u{621} \u{623}\u{648} \u{633}\u{644}\u{648}\u{643} \u{63A}\u{64A}\u{631} \u{645}\u{62A}\u{648}\u{642}\u{639}. \u{627}\u{633}\u{62A}\u{62E}\u{62F}\u{645}\u{647} \u{639}\u{644}\u{649} \u{645}\u{633}\u{624}\u{648}\u{644}\u{64A}\u{62A}\u{643} \u{648}\u{62A}\u{623}\u{643}\u{62F} \u{645}\u{646} \u{641}\u{647}\u{645} \u{645}\u{627} \u{64A}\u{642}\u{648}\u{645} \u{628}\u{647} \u{642}\u{628}\u{644} \u{627}\u{644}\u{627}\u{633}\u{62A}\u{62E}\u{62F}\u{627}\u{645}."
                            : "PKG Sender and its code were created using artificial intelligence. The app may contain errors or unexpected behavior. Use it at your own responsibility and make sure you understand what it does before using it."
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(isArabic ? .trailing : .leading)
                        .lineSpacing(4)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .foregroundColor(.secondary)
                        Text(isArabic ? "\u{627}\u{644}\u{645}\u{624}\u{644}\u{641}: T2oDna" : "Author: T2oDna")
                            .font(.footnote.weight(.semibold))
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                    Button { onContinue() } label: {
                        HStack {
                            Text(isArabic ? "\u{641}\u{647}\u{645}\u{62A}\u{60C} \u{645}\u{62A}\u{627}\u{628}\u{639}\u{629}" : "I Understand, Continue")
                                .fontWeight(.semibold)
                            Image(systemName: isArabic ? "arrow.left" : "arrow.right")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: 430)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.20), radius: 30, y: 14)
            .padding(.horizontal, 22)
            .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
            .animation(.easeInOut(duration: 0.28), value: step)
        }
    }

    private func languageButton(title: String, subtitle: String, language: String) -> some View {
        Button {
            appLanguage = language
            withAnimation(.easeInOut(duration: 0.28)) { step = 1 }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "globe").font(.title3).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.primary)
            .padding(16)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, .leftToRight)
    }
}

// ======================================================
// MARK: - About View
// ======================================================

struct AboutView: View {
    let appLanguage: String
    private var isArabic: Bool { appLanguage == "ar" }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.accentColor.opacity(0.13))
                            .frame(width: 82, height: 82)
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.accentColor)
                    }
                    Text("PKG Sender").font(.title2.bold())
                    Text(isArabic ? "الإصدار \(version) • البناء \(build)" : "Version \(version) • Build \(build)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                aboutCard(
                    icon: "info.circle.fill",
                    title: isArabic ? "\u{639}\u{646} \u{627}\u{644}\u{62A}\u{637}\u{628}\u{64A}\u{642}" : "About the App",
                    text: isArabic
                    ? "\u{62A}\u{637}\u{628}\u{64A}\u{642} \u{644}\u{625}\u{631}\u{633}\u{627}\u{644} \u{645}\u{644}\u{641}\u{627}\u{62A} PKG \u{645}\u{646} \u{627}\u{644}\u{622}\u{64A}\u{641}\u{648}\u{646} \u{645}\u{628}\u{627}\u{634}\u{631}\u{629} \u{625}\u{644}\u{649} \u{627}\u{644}\u{628}\u{644}\u{627}\u{64A}\u{633}\u{62A}\u{64A}\u{634}\u{646} \u{639}\u{646} \u{637}\u{631}\u{64A}\u{642} \u{628}\u{631}\u{646}\u{627}\u{645}\u{62C} \u{631}\u{64A}\u{645}\u{648}\u{62A} \u{628}\u{643}\u{62C} \u{625}\u{646}\u{633}\u{62A}\u{627}\u{644}\u{631}."
                    : "PKG Sender is an app for sending PKG files from an iPhone to a PlayStation through Remote Package Installer."
                )
                aboutCard(icon: "person.fill", title: isArabic ? "\u{627}\u{644}\u{645}\u{624}\u{644}\u{641}" : "Author", text: "T2oDna")
                aboutCard(
                    icon: "sparkles",
                    title: isArabic ? "\u{627}\u{644}\u{628}\u{631}\u{645}\u{62C}\u{629} \u{628}\u{627}\u{644}\u{630}\u{643}\u{627}\u{621} \u{627}\u{644}\u{627}\u{635}\u{637}\u{646}\u{627}\u{639}\u{64A}" : "AI-Generated Code",
                    text: isArabic
                    ? "\u{62A}\u{645} \u{625}\u{646}\u{634}\u{627}\u{621} \u{627}\u{644}\u{62A}\u{637}\u{628}\u{64A}\u{642} \u{648}\u{643}\u{62A}\u{627}\u{628}\u{629} \u{623}\u{643}\u{648}\u{627}\u{62F}\u{647} \u{628}\u{627}\u{633}\u{62A}\u{62E}\u{62F}\u{627}\u{645} \u{627}\u{644}\u{630}\u{643}\u{627}\u{621} \u{627}\u{644}\u{627}\u{635}\u{637}\u{646}\u{627}\u{639}\u{64A}\u{60C} \u{645}\u{639} \u{62A}\u{62D}\u{62F}\u{64A}\u{62F} \u{641}\u{643}\u{631}\u{629} \u{627}\u{644}\u{62A}\u{637}\u{628}\u{64A}\u{642} \u{648}\u{62E}\u{635}\u{627}\u{626}\u{635}\u{647} \u{648}\u{627}\u{62E}\u{62A}\u{628}\u{627}\u{631}\u{647} \u{628}\u{648}\u{627}\u{633}\u{637}\u{629} \u{627}\u{644}\u{645}\u{624}\u{644}\u{641}."
                    : "The app and its code were created using artificial intelligence, with the app concept, features, and testing directed by the author."
                )
                aboutCard(
                    icon: "exclamationmark.triangle.fill",
                    title: isArabic ? "\u{62A}\u{646}\u{628}\u{64A}\u{647}" : "Notice",
                    text: isArabic
                    ? "\u{642}\u{62F} \u{64A}\u{62D}\u{62A}\u{648}\u{64A} \u{627}\u{644}\u{62A}\u{637}\u{628}\u{64A}\u{642} \u{639}\u{644}\u{649} \u{623}\u{62E}\u{637}\u{627}\u{621} \u{623}\u{648} \u{633}\u{644}\u{648}\u{643} \u{63A}\u{64A}\u{631} \u{645}\u{62A}\u{648}\u{642}\u{639}. \u{627}\u{633}\u{62A}\u{62E}\u{62F}\u{645}\u{647} \u{639}\u{644}\u{649} \u{645}\u{633}\u{624}\u{648}\u{644}\u{64A}\u{62A}\u{643} \u{648}\u{62A}\u{623}\u{643}\u{62F} \u{645}\u{646} \u{641}\u{647}\u{645} \u{645}\u{627} \u{64A}\u{642}\u{648}\u{645} \u{628}\u{647} \u{642}\u{628}\u{644} \u{627}\u{644}\u{627}\u{633}\u{62A}\u{62E}\u{62F}\u{627}\u{645}."
                    : "The app may contain errors or unexpected behavior. Use it at your own responsibility and make sure you understand what it does before using it."
                )

                Text("© 2026 T2oDna")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(isArabic ? "\u{62D}\u{648}\u{644} \u{627}\u{644}\u{62A}\u{637}\u{628}\u{64A}\u{642}" : "About")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
    }

    private func aboutCard(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}


// ======================================================
// MARK: - Diagnostics View
// ======================================================

struct DiagnosticsView: View {
    let appLanguage: String
    @State private var logText = ""

    private var isArabic: Bool { appLanguage == "ar" }

    private var logURL: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("PKGSender-Diagnostic.log")
    }

    var body: some View {
        Group {
            if logText.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 42))
                        .foregroundColor(.secondary)

                    Text(isArabic ? "\u{644}\u{627} \u{64A}\u{648}\u{62C}\u{62F} \u{633}\u{62C}\u{644} \u{62A}\u{634}\u{62E}\u{64A}\u{635}" : "No Diagnostic Log")
                        .font(.headline)

                    Text(
                        isArabic
                        ? "\u{627}\u{628}\u{62F}\u{623} \u{639}\u{645}\u{644}\u{64A}\u{629} \u{646}\u{642}\u{644} \u{62B}\u{645} \u{627}\u{631}\u{62C}\u{639} \u{644}\u{647}\u{630}\u{647} \u{627}\u{644}\u{635}\u{641}\u{62D}\u{629}."
                        : "Start a transfer, then return to this page."
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                .padding()
            } else {
                ScrollView {
                    Text(logText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .navigationTitle(isArabic ? "\u{627}\u{644}\u{62A}\u{634}\u{62E}\u{64A}\u{635} \u{648}\u{627}\u{644}\u{623}\u{62E}\u{637}\u{627}\u{621}" : "Diagnostics")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { loadLog() } label: {
                    Image(systemName: "arrow.clockwise")
                }

                if FileManager.default.fileExists(atPath: logURL.path) {
                    ShareLink(item: logURL) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: logURL)
                        logText = ""
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .onAppear { loadLog() }
    }

    private func loadLog() {
        // Never load the whole diagnostic file into a SwiftUI Text view.
        // Long transfers can make this file many MB and freeze this screen.
        let url = logURL
        DispatchQueue.global(qos: .userInitiated).async {
            var text = ""
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                let size = try handle.seekToEnd()
                let maxBytes: UInt64 = 128 * 1024
                let start = size > maxBytes ? size - maxBytes : 0
                try handle.seek(toOffset: start)
                let data = try handle.readToEnd() ?? Data()
                text = String(decoding: data, as: UTF8.self)

                // If we started in the middle of a UTF-8/log line, drop that first fragment.
                if start > 0, let newline = text.firstIndex(of: "\n") {
                    text = String(text[text.index(after: newline)...])
                }
            } catch {
                text = "Diagnostics read error: \(error.localizedDescription)"
            }

            DispatchQueue.main.async {
                self.logText = text
            }
        }
    }
}
