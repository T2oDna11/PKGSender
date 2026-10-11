import SwiftUI

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    let appLanguage: String
    @Binding var detailsPackages: [LibraryPackage]?
    let onSendPackage: (LibraryPackage) -> Void
    let onQueuePackage: (LibraryPackage) -> Void
    let onGoHome: () -> Void
    let isPackageSent: (LibraryPackage) -> Bool
    let isPackageQueued: (LibraryPackage) -> Bool
    @State private var searchText = ""
    @State private var featuredKey: String? = nil
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFocused: Bool

    private var isArabic: Bool { appLanguage == "ar" }
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }

    private struct GameGroup: Identifiable {
        let key: String
        let packages: [LibraryPackage]
        var id: String { key }
        var title: String { packages.first?.title ?? "Unknown" }
        var titleID: String { packages.first(where: { !$0.titleID.isEmpty })?.titleID ?? "" }
        var displayPackage: LibraryPackage { packages.first(where: { $0.kind == .game }) ?? packages[0] }
    }

    private var groups: [GameGroup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = q.isEmpty ? store.packages : store.packages.filter {
            $0.title.lowercased().contains(q) || $0.titleID.lowercased().contains(q) || $0.fileName.lowercased().contains(q)
        }
        let grouped = Dictionary(grouping: visible) { package -> String in
            if !package.titleID.isEmpty { return package.titleID.uppercased() }
            if !package.contentID.isEmpty { return package.contentID.uppercased() }
            return package.title.lowercased()
        }
        return grouped.map { key, values in
            GameGroup(key: key, packages: values.sorted { lhs, rhs in
                if lhs.kind == .game && rhs.kind != .game { return true }
                if rhs.kind == .game && lhs.kind != .game { return false }
                return lhs.version.localizedStandardCompare(rhs.version) == .orderedAscending
            })
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private let gridSpacing: CGFloat = 8


    var body: some View {
        NavigationView {
            Group {
                if store.isScanning && store.packages.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView(value: store.scanProgress).frame(maxWidth: 240)
                        Text(t("Reading PKG library…", "جارٍ قراءة مكتبة PKG…")).foregroundColor(.secondary)
                    }
                } else if groups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical").font(.system(size: 42)).foregroundColor(.secondary)
                        Text(t("Your library is empty", "المكتبة فارغة")).font(.headline)
                        Text(t("Put .pkg files in Files → PKG Sender → PKG Sender, then refresh the library.", "ضع ملفات .pkg داخل الملفات ← PKG Sender ← PKG Sender، ثم حدّث المكتبة."))
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 28)
                    }
                } else {
                    GeometryReader { proxy in
                        let horizontalPadding: CGFloat = 12
                        let cardWidth = max(0, (proxy.size.width - (horizontalPadding * 2) - (gridSpacing * 2)) / 3)
                        let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: 3)

                        let featured = groups.first(where: { $0.key == featuredKey }) ?? groups.first

                        VStack(alignment: .leading, spacing: 18) {
                            // Header + Featured stay visible. Only the game library below scrolls.
                            LibraryCompactHeader(
                                title: t("Library", "المكتبة"),
                                gameCount: groups.count,
                                isArabic: isArabic,
                                searchText: $searchText,
                                isSearchExpanded: $isSearchExpanded,
                                isSearchFocused: $isSearchFocused,
                                isScanning: store.isScanning,
                                onRefresh: { store.scan() }
                            )
                            .padding(.horizontal, horizontalPadding)

                            if let featured {
                                FeaturedLibraryCard(
                                    store: store,
                                    packages: featured.packages,
                                    title: featured.title,
                                    titleID: featured.titleID,
                                    iconData: store.iconData(for: featured.displayPackage),
                                    isArabic: isArabic,
                                    onShowDetails: {
                                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                                            detailsPackages = featured.packages
                                        }
                                    }
                                )
                                .padding(.horizontal, horizontalPadding)
                            }

                            // All Games is the floating divider. The grid scrolls behind this edge.
                            HStack(spacing: 10) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.10))
                                    .frame(height: 0.5)
                                Text(t("All Games", "كل الألعاب"))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Rectangle()
                                    .fill(Color.primary.opacity(0.10))
                                    .frame(height: 0.5)
                            }
                            .padding(.horizontal, horizontalPadding + 8)

                            ScrollView {
                                LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
                                    ForEach(groups) { group in
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.20)) {
                                                featuredKey = group.key
                                            }
                                        } label: {
                                            LibraryPosterCard(
                                                title: group.title,
                                                iconData: store.iconData(for: group.displayPackage),
                                                cardWidth: cardWidth,
                                                isSelected: featured?.key == group.key
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: cardWidth)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, horizontalPadding)
                                .padding(.top, 4)
                                .padding(.bottom, 118)
                            }
                            // Pixel-level edge fade: only the slice crossing the divider/capsule fades.
                            // No card-wide opacity/blur and no material/black panels.
                            .mask {
                                VStack(spacing: 0) {
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0.00),
                                            .init(color: .white.opacity(0.30), location: 0.28),
                                            .init(color: .white, location: 1.00)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .frame(height: 18)

                                    Color.white

                                    LinearGradient(
                                        stops: [
                                            .init(color: .white, location: 0.00),
                                            .init(color: .white.opacity(0.75), location: 0.45),
                                            .init(color: .clear, location: 1.00)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .frame(height: 38)
                                }
                            }
                        }
                        .padding(.top, 10)
                        .onAppear {
                            if featuredKey == nil, let firstKey = groups.first?.key {
                                featuredKey = firstKey
                            }
                        }
                        .onChange(of: groups.map(\.key)) { keys in
                            guard let firstKey = keys.first else {
                                featuredKey = nil
                                return
                            }
                            if featuredKey == nil || !keys.contains(featuredKey!) {
                                featuredKey = firstKey
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
        }
        // Do not animate a live blur across the whole poster grid. Interpolating that
        // effect was one of the largest frame-time spikes when opening Details.
        .blur(radius: detailsPackages == nil ? 0 : 7)
        .animation(nil, value: detailsPackages != nil)
        .allowsHitTesting(detailsPackages == nil)
        .overlay {
            if let packages = detailsPackages, !packages.isEmpty {
                LibraryDetailsOverlay(
                    store: store,
                    packages: packages,
                    isArabic: isArabic,
                    isPackageSent: isPackageSent,
                    isPackageQueued: isPackageQueued,
                    onSendPackage: onSendPackage,
                    onQueuePackage: onQueuePackage,
                    onGoHome: onGoHome,
                    onClose: { detailsPackages = nil }
                )
                .ignoresSafeArea()
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
    }
}

private struct LibraryCompactHeader: View {
    let title: String
    let gameCount: Int
    let isArabic: Bool
    @Binding var searchText: String
    @Binding var isSearchExpanded: Bool
    var isSearchFocused: FocusState<Bool>.Binding
    let isScanning: Bool
    let onRefresh: () -> Void

    @State private var refreshAngle: Double = 0
    @State private var refreshTimer: Timer?

    private var countText: String {
        if isArabic { return "\(gameCount) ألعاب" }
        return "\(gameCount) " + (gameCount == 1 ? "Game" : "Games")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if !isSearchExpanded {
                VStack(alignment: isArabic ? .trailing : .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text(countText)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
                .transition(.opacity)
            }

            if isSearchExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField(isArabic ? "اللعبة أو CUSA" : "Game or CUSA", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused(isSearchFocused)

                    Button {
                        if !searchText.isEmpty {
                            searchText = ""
                        } else {
                            isSearchFocused.wrappedValue = false
                            withAnimation(.easeInOut(duration: 0.34)) {
                                isSearchExpanded = false
                            }
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground).opacity(0.92))
                )
                .transition(.opacity)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.34)) {
                        isSearchExpanded = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        isSearchFocused.wrappedValue = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground).opacity(0.72)))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .rotationEffect(.degrees(refreshAngle))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground).opacity(0.72)))
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
        }
        .frame(minHeight: 44)
        .onChange(of: isScanning) { scanning in
            if scanning {
                startRefreshAnimation()
            } else {
                stopRefreshAnimation()
            }
        }
        .onAppear {
            if isScanning { startRefreshAnimation() }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func startRefreshAnimation() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
            refreshAngle = (refreshAngle + 12).truncatingRemainder(dividingBy: 360)
        }
    }

    private func stopRefreshAnimation() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshAngle = 0
    }
}


private struct FeaturedLibraryCard: View {
    @ObservedObject var store: LibraryStore
    let packages: [LibraryPackage]
    let title: String
    let titleID: String
    let iconData: Data?
    let isArabic: Bool
    let onShowDetails: () -> Void

    private let featuredHeight: CGFloat = 148
    private let artworkSize: CGFloat = 122

    private var image: UIImage? {
        guard let iconData else { return nil }
        return UIImage(data: iconData)
    }

    private var hasGame: Bool { packages.contains(where: { $0.kind == .game }) }
    private var hasUpdate: Bool { packages.contains(where: { $0.kind == .update }) }
    private var hasDLC: Bool { packages.contains(where: { $0.kind == .dlc }) }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.04)
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: isArabic ? .trailing : .leading, spacing: 0) {
                // Reserve two title lines for every game so the content below never jumps.
                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: isArabic ? .topTrailing : .topLeading)
                    .frame(height: 46, alignment: isArabic ? .topTrailing : .topLeading)

                Group {
                    if !titleID.isEmpty {
                        Text(titleID)
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
                .frame(height: 18, alignment: isArabic ? .trailing : .leading)

                Spacer(minLength: 4)

                // A very subtle divider separates game identity from package actions.
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)

                // Keep GAME / UPDATE / DLC / More together on one fixed bottom row.
                HStack(spacing: 5) {
                    PackageCapsule(title: "GAME", isAvailable: hasGame)
                    PackageCapsule(title: "UPDATE", isAvailable: hasUpdate)
                    PackageCapsule(title: "DLC", isAvailable: hasDLC)

                    Button(action: onShowDetails) {
                        HStack(spacing: 3.5) {
                            Circle().frame(width: 3, height: 3)
                            Circle().frame(width: 3, height: 3)
                            Circle().frame(width: 3, height: 3)
                        }
                        .foregroundColor(Color.white.opacity(0.45))
                        .frame(width: 34, height: 25)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.022)))
                        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.03), lineWidth: 0.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
                .frame(height: 27, alignment: isArabic ? .trailing : .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: artworkSize)
        }
        .padding(.horizontal, 12)
        .frame(height: featuredHeight)
        .background {
            ZStack {
                Color(.secondarySystemGroupedBackground)

                if let image {
                    GeometryReader { proxy in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .blur(radius: 22)
                            .opacity(0.18)
                            .clipped()
                    }

                    Color.black.opacity(0.36)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
    }
}

private struct PackageCapsule: View {
    let title: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.white.opacity(isAvailable ? 0.82 : 0.16))
                .frame(width: 6.5, height: 6.5)

            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(Color.white.opacity(isAvailable ? 0.90 : 0.30))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(isAvailable ? 0.075 : 0.028))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(isAvailable ? 0.075 : 0.035), lineWidth: 0.6)
        )
    }
}

private struct LibraryPosterCard: View {
    let title: String
    let iconData: Data?
    let cardWidth: CGFloat
    let isSelected: Bool

    private var image: UIImage? {
        guard let iconData else { return nil }
        return UIImage(data: iconData)
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(.secondarySystemGroupedBackground)
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: cardWidth, height: cardWidth * 1.12)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.72) : Color.white.opacity(0.055),
                            lineWidth: isSelected ? 1.4 : 0.6)
            )

            Text(title)
                .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
                .frame(width: cardWidth, height: 23, alignment: .top)
        }
        .contentShape(Rectangle())
    }
}

private struct LibraryGameCard: View {
    @ObservedObject var store: LibraryStore
    let packages: [LibraryPackage]
    let title: String
    let titleID: String
    let iconData: Data?
    let isArabic: Bool
    let cardWidth: CGFloat

    @State private var infoPulse = false

    private var coverImage: UIImage? {
        guard let iconData else { return nil }
        return UIImage(data: iconData)
    }

    private var accent: Color {
        guard let image = coverImage else {
            return Color(red: 0.16, green: 0.18, blue: 0.22)
        }
        return Color(uiColor: image.libraryAccentColor())
    }

    private var posterHeight: CGFloat {
        cardWidth * 1.14
    }

    var body: some View {
        VStack(spacing: 4) {
            // Poster is now the visual hero: larger, cleaner, almost edge-to-edge.
            Group {
                if let image = coverImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.035)
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
            }
            .frame(width: cardWidth - 8, height: posterHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            // Lightweight glass-like information surface.
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.96))
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .top)

                Circle()
                    .fill(Color.white.opacity(infoPulse ? 0.66 : 0.36))
                    .frame(width: 12.5, height: 12.5)
                    .shadow(
                        color: Color.white.opacity(infoPulse ? 0.22 : 0.035),
                        radius: infoPulse ? 4 : 1
                    )
                    .scaleEffect(infoPulse ? 1.025 : 0.975)
                    .animation(
                        .easeInOut(duration: 1.7).repeatForever(autoreverses: true),
                        value: infoPulse
                    )
                    .onAppear { infoPulse = true }
                    .accessibilityLabel(isArabic ? "معلومات اللعبة" : "Game information")
            }
            .padding(.horizontal, 5)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .frame(width: cardWidth - 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.30))
                }
            )
        }
        .padding(4)
        .frame(width: cardWidth)
        .background(
            ZStack {
                // Very dark base; artwork accent is now ambient light, not a border.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.045, green: 0.047, blue: 0.052))

                RadialGradient(
                    colors: [
                        accent.opacity(0.34),
                        accent.opacity(0.12),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: cardWidth * 1.35
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.025),
                        Color.clear,
                        Color.black.opacity(0.20)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: accent.opacity(0.08), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// Picks a strong artwork accent instead of averaging the whole image into a
// muddy brown/grey. The card then uses that single accent as the tint source.
private extension UIImage {
    func libraryAccentColor() -> UIColor {
        guard let cgImage else { return UIColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1) }

        let width = 24
        let height = 24
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return UIColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1)
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var bestScore: CGFloat = -1
        var best = (r: CGFloat(0.18), g: CGFloat(0.20), b: CGFloat(0.24))

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i + 1]) / 255
            let b = CGFloat(pixels[i + 2]) / 255

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            let brightness = maxC

            // Ignore near-black/near-white pixels and reward saturated midtones.
            guard brightness > 0.16, brightness < 0.90, saturation > 0.18 else { continue }
            let midtone = 1 - abs(brightness - 0.55)
            let score = saturation * 0.72 + midtone * 0.28

            if score > bestScore {
                bestScore = score
                best = (r, g, b)
            }
        }

        // Slightly lift and enrich the selected accent so it survives the dark UI.
        let floor: CGFloat = 0.10
        let boost: CGFloat = 1.08
        return UIColor(
            red: min(1, max(floor, best.r * boost)),
            green: min(1, max(floor, best.g * boost)),
            blue: min(1, max(floor, best.b * boost)),
            alpha: 1
        )
    }
}


struct LibraryDetailsOverlay: View {
    @ObservedObject var store: LibraryStore
    let packages: [LibraryPackage]
    let isArabic: Bool
    let isPackageSent: (LibraryPackage) -> Bool
    let isPackageQueued: (LibraryPackage) -> Bool
    let onSendPackage: (LibraryPackage) -> Void
    let onQueuePackage: (LibraryPackage) -> Void
    let onGoHome: () -> Void
    let onClose: () -> Void

    @State private var showDelete = false
    @State private var selectedKind: PKGMetadata.Kind = .game
    @State private var showActions = false
    @State private var sentPulse = false
    @State private var addedPulse = false
    @State private var queuedWhenActionsOpened = false
    @State private var availabilityByID: [UUID: Bool] = [:]
    @State private var leadIconData: Data? = nil

    private let kinds: [PKGMetadata.Kind] = [.game, .update, .dlc]
    private var lead: LibraryPackage { packages.first(where: { $0.kind == .game }) ?? packages[0] }
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }
    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    private func package(for kind: PKGMetadata.Kind) -> LibraryPackage? { packages.first(where: { $0.kind == kind }) }
    private func kindName(_ kind: PKGMetadata.Kind) -> String {
        switch kind { case .game: return "GAME"; case .update: return "UPDATE"; case .dlc: return "DLC"; case .other: return "PKG" }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if showActions { closeActions() } else { closeDetails() }
                    }

                detailsCard(geo: geo)
                    // Keep the material card static while Actions opens. Animating blur/material
                    // forces an expensive off-screen render and was the remaining hitch.
                    .opacity(showActions ? 0.90 : 1)
                    .allowsHitTesting(!showActions)

                if showActions {
                    Color.black.opacity(0.10)
                        .ignoresSafeArea()
                        .onTapGesture { closeActions() }
                        .transition(.opacity)

                    actionsCard
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        .zIndex(2)
                }
            }
            .animation(.snappy(duration: 0.22, extraBounce: 0), value: showActions)
        }
        .alert(t("Remove from Library?", "حذف من المكتبة؟"), isPresented: $showDelete) {
            Button(t("Cancel", "إلغاء"), role: .cancel) {}
            Button(t("Remove", "حذف"), role: .destructive) {
                packages.forEach(store.removeFromLibrary)
                closeDetails()
            }
        } message: {
            Text(t("Saved metadata will be removed. PKG files will not be deleted.", "سيتم حذف البيانات المحفوظة من المكتبة فقط، ولن يتم حذف ملفات PKG."))
        }
        .onAppear {
            // Snapshot disk-backed values once when Details opens. Tab switches then stay
            // entirely in memory instead of hitting FileManager / Data(contentsOf:) mid-animation.
            availabilityByID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, store.isFileAvailable($0)) })
            leadIconData = store.iconData(for: lead)
            if package(for: .game) == nil {
                selectedKind = kinds.first(where: { package(for: $0) != nil }) ?? .game
            }
        }
    }

    private func detailsCard(geo: GeometryProxy) -> some View {
        let maxCardHeight = max(560, min(geo.size.height - 44, 720))
        return VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 9) {
                    if let data = leadIconData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 188, height: 188).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.7))
                            .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
                    }
                    Text(lead.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.78)
                    if !lead.titleID.isEmpty {
                        Text(lead.titleID).font(.caption.monospaced()).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                Button(action: closeDetails) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 18)

            HStack(spacing: 7) {
                ForEach(kinds, id: \.rawValue) { kind in
                    Button {
                        guard selectedKind != kind else { return }
                        selectedKind = kind
                    } label: {
                        VStack(spacing: 6) {
                            Text(kindName(kind))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(selectedKind == kind ? Color.primary : Color.secondary)
                            Capsule().fill(selectedKind == kind ? Color.accentColor : Color.clear).frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 26).padding(.top, 12)

            // Keep the metadata surface structurally stable. Replacing it with .id + move
            // briefly rendered old/new cards together and caused the visible one-frame twitch.
            packageDetails(selectedKind)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.14), value: selectedKind)
            .padding(.horizontal, 20).padding(.top, 10)

            Spacer(minLength: 18)

            Button {
                queuedWhenActionsOpened = package(for: selectedKind).map(isPackageQueued) ?? false
                withAnimation(.snappy(duration: 0.22, extraBounce: 0)) { showActions = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(width: 58, height: 32)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t("Actions", "الأوامر"))
            .padding(.bottom, 22)
        }
        .frame(maxWidth: 455)
        .frame(height: maxCardHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.34), radius: 30, y: 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder private func packageDetails(_ kind: PKGMetadata.Kind) -> some View {
        let p = package(for: kind)
        let available = p.flatMap { availabilityByID[$0.id] } ?? false
        let sent = p.map(isPackageSent) ?? false
        VStack(spacing: 0) {
            HStack {
                Text(kindName(kind)).font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer(); statusBadge(package: p, available: available, sent: sent)
            }.padding(.bottom, 9)

            Divider().opacity(0.16)

            if let p {
                compactRow("number", t("Version", "الإصدار"), p.version.isEmpty ? "—" : p.version)
                compactRow("square.grid.2x2", t("Category", "الفئة"), p.category.isEmpty ? "—" : p.category.uppercased())
                compactRow("number.square", "Content ID", p.contentID.isEmpty ? "—" : p.contentID, small: true)
                compactRow("tag", t("Title ID", "معرف اللعبة"), p.titleID.isEmpty ? "—" : p.titleID)
                compactRow("doc", t("File Name", "اسم الملف"), p.fileName, small: true)
                compactRow("externaldrive", t("File Size", "حجم الملف"), size(p.fileSize), divider: false)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "tray").foregroundStyle(.secondary)
                    Text(t("No package added for this type.", "لا يوجد ملف مضاف لهذا النوع."))
                        .font(.system(size: 14.5)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.vertical, 24)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.6))
    }

    private func compactRow(_ icon: String, _ label: String, _ value: String, small: Bool = false, divider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).frame(width: 19)
                Text(label).font(.system(size: 13.5)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: small ? 12.25 : 14, weight: .medium, design: small ? .monospaced : .default))
                    .lineLimit(1).minimumScaleFactor(0.58).multilineTextAlignment(.trailing)
            }.frame(height: 33)
            if divider { Divider().opacity(0.10).padding(.leading, 28) }
        }
    }

    private var actionsCard: some View {
        let p = package(for: selectedKind)
        let available = p.flatMap { availabilityByID[$0.id] } ?? false
        let alreadySent = p.map(isPackageSent) ?? false
        
        return VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 3) {
                    Text(t("Actions", "الأوامر"))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(kindName(selectedKind))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Button(action: closeActions) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }.buttonStyle(.plain)
            }

            Spacer(minLength: 18)

            HStack(spacing: 12) {
                actionCapsule(
                    title: (alreadySent || sentPulse) ? t("Sent", "تم الإرسال") : t("Send", "إرسال"),
                    icon: (alreadySent || sentPulse) ? "checkmark" : "paperplane.fill",
                    enabled: available
                ) {
                    guard let p, available else { return }
                    onSendPackage(p)
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.76)) { sentPulse = true }
                }

                actionCapsule(
                    title: (queuedWhenActionsOpened || addedPulse) ? t("Added", "تمت الإضافة") : t("Add", "إضافة"),
                    icon: (queuedWhenActionsOpened || addedPulse) ? "checkmark" : "plus",
                    enabled: available && !queuedWhenActionsOpened && !addedPulse
                ) {
                    guard let p, available, !queuedWhenActionsOpened, !addedPulse else { return }
                    onQueuePackage(p)
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.76)) { addedPulse = true }
                }
            }

            Spacer(minLength: 20)

            Button(action: onGoHome) {
                HStack(spacing: 7) {
                    Text(t("Follow progress", "تابع التقدم"))
                    Image(systemName: "house.fill")
                    Text(t("Home", "الرئيسية"))
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(height: 32)
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.035), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 20)

            Divider().opacity(0.12)

            Button(role: .destructive) { showDelete = true } label: {
                Label(t("Remove from Library", "حذف من المكتبة"), systemImage: "trash")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.56))
                    .frame(height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: 330, height: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.13), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.30), radius: 24, y: 12)
    }

    private func actionCapsule(title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(enabled ? 0.90 : 0.42))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(enabled ? 0.10 : 0.05), lineWidth: 0.6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: title)
    }

    private func closeActions() {
        withAnimation(.snappy(duration: 0.20, extraBounce: 0)) {
            showActions = false
            sentPulse = false
            addedPulse = false
            queuedWhenActionsOpened = false
        }
    }

    private func closeDetails() {
        withAnimation(.easeInOut(duration: 0.22)) { onClose() }
    }

    @ViewBuilder private func statusBadge(package: LibraryPackage?, available: Bool, sent: Bool) -> some View {
        let color: Color = package == nil ? .secondary : (!available ? .yellow : (sent ? .blue : .green))
        let text = package == nil ? t("Not Added", "غير مضاف") : (!available ? t("File Missing", "الملف مفقود") : (sent ? t("Sent", "تم الإرسال") : t("Available", "موجود")))
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7.25, height: 7.25)
            Text(text).font(.system(size: 12.25, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

