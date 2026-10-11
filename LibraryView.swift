import SwiftUI

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    let appLanguage: String
    @State private var searchText = ""
    @State private var featuredKey: String? = nil
    @State private var isSearchExpanded = false
    @State private var featuredCollapseProgress: CGFloat = 0
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
                                    collapseProgress: featuredCollapseProgress
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
                                // Track the grid's real scroll offset. The hero follows the finger
                                // directly: no delayed animation, snapping, or two-state jump.
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(
                                            key: LibraryScrollOffsetPreferenceKey.self,
                                            value: geo.frame(in: .named("LibraryGridScroll")).minY
                                        )
                                }
                                .frame(height: 0)

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
                            .coordinateSpace(name: "LibraryGridScroll")
                            .onPreferenceChange(LibraryScrollOffsetPreferenceKey.self) { minY in
                                // 0...1 over the first 128pt of scrolling. Keeping this centralized
                                // makes the hero easy to tune later without touching its layout logic.
                                let collapseDistance: CGFloat = 128
                                let progress = min(max(-minY / collapseDistance, 0), 1)
                                featuredCollapseProgress = progress
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
            .onAppear { store.scan() }
        }.environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
    }
}

private struct LibraryScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    let collapseProgress: CGFloat

    // Hero dimensions: expanded at the top, then smoothly interpolate to
    // the exact compact dimensions that were already stable in the app.
    private let compactHeight: CGFloat = 148
    private let expandedHeight: CGFloat = 218
    private let compactArtworkSize: CGFloat = 122
    private let expandedArtworkSize: CGFloat = 174

    private var featuredHeight: CGFloat {
        expandedHeight + (compactHeight - expandedHeight) * collapseProgress
    }

    private var artworkSize: CGFloat {
        expandedArtworkSize + (compactArtworkSize - expandedArtworkSize) * collapseProgress
    }

    private var horizontalInset: CGFloat {
        14 + (12 - 14) * collapseProgress
    }

    private var cardSpacing: CGFloat {
        16 + (14 - 16) * collapseProgress
    }

    private var image: UIImage? {
        guard let iconData else { return nil }
        return UIImage(data: iconData)
    }

    private var hasGame: Bool { packages.contains(where: { $0.kind == .game }) }
    private var hasUpdate: Bool { packages.contains(where: { $0.kind == .update }) }
    private var hasDLC: Bool { packages.contains(where: { $0.kind == .dlc }) }

    var body: some View {
        HStack(spacing: cardSpacing) {
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

                    NavigationLink {
                        LibraryGameDetailsView(store: store, packages: packages, isArabic: isArabic)
                    } label: {
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
        .padding(.horizontal, horizontalInset)
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

private struct LibraryGameDetailsView: View {
    @ObservedObject var store: LibraryStore
    let packages: [LibraryPackage]
    let isArabic: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false

    private var lead: LibraryPackage { packages.first(where: { $0.kind == .game }) ?? packages[0] }
    private func t(_ en: String, _ ar: String) -> String { isArabic ? ar : en }
    private func kindName(_ p: LibraryPackage) -> String {
        switch p.kind { case .game: return t("GAME", "اللعبة"); case .update: return t("UPDATE", "التحديث"); case .dlc: return t("DLC", "الإضافة"); case .other: return p.kindRawValue.uppercased() }
    }
    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let data = store.iconData(for: lead), let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 230).clipShape(RoundedRectangle(cornerRadius: 22))
                }
                VStack(spacing: 5) {
                    Text(lead.title).font(.title2.bold()).multilineTextAlignment(.center)
                    if !lead.titleID.isEmpty { Text(lead.titleID).font(.subheadline.monospaced()).foregroundColor(.secondary) }
                }
                ForEach(packages) { p in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(kindName(p)).font(.headline)
                            Spacer()
                            Label(store.isFileAvailable(p) ? t("File Available", "الملف موجود") : t("File Missing", "الملف غير موجود"), systemImage: store.isFileAvailable(p) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption.bold()).foregroundColor(store.isFileAvailable(p) ? .green : .orange)
                        }
                        detail(t("Version", "الإصدار"), p.version.isEmpty ? "—" : p.version)
                        detail("Content ID", p.contentID.isEmpty ? "—" : p.contentID)
                        detail(t("File name", "اسم الملف"), p.fileName)
                        detail(t("File size", "حجم الملف"), size(p.fileSize))
                    }.padding().background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                }
                Button(role: .destructive) { showDelete = true } label: { Label(t("Remove from Library", "حذف من المكتبة"), systemImage: "trash") }.buttonStyle(.bordered)
            }.padding()
        }
        .navigationTitle(t("Game Details", "تفاصيل اللعبة")).navigationBarTitleDisplayMode(.inline)
        .alert(t("Remove from Library?", "حذف من المكتبة؟"), isPresented: $showDelete) {
            Button(t("Cancel", "إلغاء"), role: .cancel) {}
            Button(t("Remove", "حذف"), role: .destructive) { packages.forEach(store.removeFromLibrary); dismiss() }
        } message: { Text(t("Saved metadata will be removed. PKG files will not be deleted.", "سيتم حذف البيانات المحفوظة من المكتبة فقط، ولن يتم حذف ملفات PKG.")) }
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(name).foregroundColor(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.subheadline)
    }
}
