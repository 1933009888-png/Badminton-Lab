import SwiftUI
import PhotosUI
import Photos
import simd
import CoreImage
import AVFoundation
import Combine
import UIKit
import UniformTypeIdentifiers
// MARK: - Calibration modes
private enum CalibMode: String, CaseIterable, Identifiable {
    case fourCorners   = "Four Corners"
    case sixPoints     = "6 Points"
    case customCorners = "Custom Corners" // BL→BR→TR→TL, choose Inner/Outer per corner
    var id: String { rawValue }
}

private enum CornerPos: String, CaseIterable, Identifiable {
    case bl = "BL", br = "BR", tr = "TR", tl = "TL"
    var id: String { rawValue }
    var title: String { rawValue }
}

private enum CornerKind: String, CaseIterable, Identifiable {
    case outer = "Outer"
    case inner = "Inner"
    var id: String { rawValue }
}



private enum GuideTarget: Hashable {
    case pick, court, dual, videoA, videoB, csv, calibrateA, calibrateB, play, run
}

private struct GuideBounds: PreferenceKey {
    static var defaultValue: [GuideTarget: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [GuideTarget: Anchor<CGRect>],
                       nextValue: () -> [GuideTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GuideCardLayout: Layout {
    let focus: CGRect?
    let safeTop: CGFloat
    let safeBottom: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let width = max(1, bounds.width - 32)
        let cardProposal = ProposedViewSize(width: width, height: nil)
        let height = card.sizeThatFits(cardProposal).height
        let top = safeTop + 8
        let bottom = max(top, bounds.height - safeBottom - height - 8)
        let above = (focus?.minY ?? top) - height - 10
        let below = (focus?.maxY ?? top) + 10
        let y = above >= top ? above : (below <= bottom ? below : top)
        card.place(at: CGPoint(x: bounds.minX + 16, y: bounds.minY + min(bottom, max(top, y))),
                   anchor: .topLeading, proposal: cardProposal)
    }
}

private extension View {
    func guideTarget(_ target: GuideTarget) -> some View {
        anchorPreference(key: GuideBounds.self, value: .bounds) { [target: $0] }
            .id(target)
    }

    func guided(_ target: GuideTarget?, hint: String, safeInsets: EdgeInsets = EdgeInsets(), exit: @escaping () -> Void) -> some View {
        overlayPreferenceValue(GuideBounds.self) { anchors in
            if let target {
                GeometryReader { geo in
                    let bounds = CGRect(origin: .zero, size: geo.size)
                    let focus = anchors[target].map { geo[$0].insetBy(dx: -3, dy: -3) }
                    ZStack {
                        Path { path in
                            path.addRect(bounds)
                            if let focus {
                                path.addRoundedRect(in: focus, cornerSize: CGSize(width: 12, height: 12))
                            }
                        }
                        .fill(Color.black.opacity(0.63), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        GuideCardLayout(focus: focus, safeTop: max(safeInsets.top, geo.safeAreaInsets.top),
                                        safeBottom: max(safeInsets.bottom, geo.safeAreaInsets.bottom)) {
                            HStack(alignment: .center, spacing: 12) {
                                Text(hint)
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button(action: exit) {
                                    Text("Skip").bold().frame(minWidth: 44, minHeight: 44)
                                }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color("BrandAccent"))
                                    .fixedSize()
                                    .accessibilityLabel("Skip beginner guide")
                            }
                            .foregroundStyle(.primary)
                            .padding(14)
                            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @AppStorage("BadmintonLab.beginnerGuide") private var guideActive = true
    @AppStorage("BadmintonLab.nightMode") private var nightMode = false
    // Court auto-detection state
    @State private var isDetecting = false

    // Calibration (classic 4-tap)
    @State private var mode: CalibMode = .sixPoints
    @State private var taps: [CGPoint] = []          // BL → BR → TR → TL
    @State private var orderError: String? = nil

    // Custom corners (inner/outer choice for each)
    @State private var cornerKind: [CornerPos: CornerKind] = [
        .bl: .outer, .br: .outer, .tr: .outer, .tl: .outer
    ]

    // Overlays
    @State private var showSingles = false
    @State private var showNet = true
    @State private var showService = true

    // Photo import + zoom
    @State private var photoItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var zoomScale: CGFloat = 1
    @State private var contentKey = UUID()           // forces ZoomableScrollView rebuild

    // Many-anchors LS calibration + probe cursor
    @State private var useManyAnchors = false
    private enum AnchorSet: String, CaseIterable, Identifiable { case corners, hGrid; var id: String { rawValue } }
    @State private var anchorSet: AnchorSet = .corners
    @State private var selectedCorner: CourtAnchor = .BL
    @State private var hAnchors: [AnchorDef] = []
    @State private var selectedHIndex: Int = 0
    @State private var pairs: [AnchorPair] = []
    @State private var Hls: HomoLS? = nil
    @State private var probePx: CGPoint? = nil       // image px of last probe tap
    @State private var controlsHidden: Bool = false  // collapse bottom panel to avoid covering court
    @State private var showMultiCamRecorder = false
    @State private var showStereoAnalysis = false
    @State private var stereoLaunchShowSavedMatches = false
    @State private var showCalibrationTutorial = false
    @State private var highlightedLandingEventID: UUID? = nil
    // Corner sub-selection for Many Anchors (x-edge/y-edge)
    @State private var cornerXEdge: CornerKind = .outer
    @State private var cornerYEdge: CornerKind = .outer
    @State private var classificationTolerance: Double = 0.01 // meters (1 cm default)

    // Video import (no on-device tracking)
    @State private var workspaceVisible = true
    @State private var showVideoPicker = false
    @State private var videoURL: URL?
    @State private var videoPreview: UIImage?
    @State private var videoFrameSize: CGSize?
    @State private var isLoadingVideo = false
    @State private var videoLoadError: String? = nil
    @State private var player: AVPlayer? = nil
    @State private var playerTimeObserver: Any? = nil
    @State private var currentFrame: Int = 0
    @State private var isPlaying: Bool = false
    @State private var playbackRate: Float = 1.0
    private let playbackRates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0]

    // Share / Export
    @State private var showShareSheet = false
    @State private var shareURL: URL? = nil
    @State private var exportError: String? = nil

    // MARK: - Tracking import (PC results)
    private struct TrackSample: Identifiable {
        let id = UUID()
        let frame: Int
        let x: Double
        let y: Double
        let vis: Int
    }

    enum ShotType: String, CaseIterable {
        case netShot   = "Net Shot"
        case netCross  = "Net Cross"
        case liftClear = "Lift/Clear"
        case dropCut   = "Drop/Cut"
        case drive     = "Drive"
        case pushBlock = "Push/Block"
        case smashKill = "Smash/Kill"
        case unknown   = "Unknown"

        var displayLabel: String { rawValue }
    }

    struct ShotEvent: Identifiable {
        let id = UUID()
        let startFrame: Int
        let endFrame: Int
        let startWorld: CGPoint
        let endWorld: CGPoint
        let isLanding: Bool
        let type: ShotType
        let confidence: Double
    }

    @State private var showCSVImporter = false
    @State private var calibrationSlot: StereoVideoSlot? = nil
    @State private var trackSamples: [TrackSample] = []            // raw CSV samples
    @State private var trackPointsOrientedPx: [CGPoint?] = []       // indexed by frame, oriented pixel coords
    @State private var csvImportError: String? = nil

    // Video geometry (to map PC coords -> iOS oriented pixel coords)
    @State private var videoRawSize: CGSize? = nil                 // track.naturalSize (storage orientation)
    @State private var videoPreferredTransform: CGAffineTransform = .identity
    @State private var videoOrientedRect: CGRect = .zero           // standardized rect after applying preferredTransform

    // Visualization toggles
    @State private var showTrajectory = true
    @State private var showLandings = true

    // Analysis results
    @State private var shotEvents: [ShotEvent] = []
    @State private var landingViewPoints: [CGPoint] = []
    @State private var selectedShotEventID: UUID? = nil

    // Cache container size (for exporting calibration in real pixel coords)
    @State private var containerSize: CGSize = .zero

    private let court = BadmintonCourt()

    private var calibrationRequiredTapCount: Int {
        mode == .sixPoints ? 6 : 4
    }

    private var calibrationOverlayLabels: [String] {
        mode == .sixPoints ? ["BL", "BR", "TR", "TL", "N-L", "N-R"] : ["BL", "BR", "TR", "TL"]
    }

    private var singleCamSixPointAnchors: [StereoCourtAnchor] {
        [.BL, .BR, .TR, .TL, .NetLeftTop, .NetRightTop]
    }

    private func singleCamWorldPoints2D() -> [CGPoint] {
        switch mode {
        case .fourCorners:
            return [
                CGPoint(x: 0, y: 0),
                CGPoint(x: court.W, y: 0),
                CGPoint(x: court.W, y: court.L),
                CGPoint(x: 0, y: court.L)
            ]
        case .sixPoints:
            return singleCamSixPointAnchors.map { $0.worldMeters2D() }
        case .customCorners:
            return worldPointsForCustomCorners()
        }
    }

    private func singleCamWorldPoints3D() -> [SIMD3<Double>]? {
        guard mode == .sixPoints else { return nil }
        return singleCamSixPointAnchors.map { let p = $0.worldMeters3D(); return SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
    }

    // MARK: - Layout helpers (to dock controls below the aspect-fitted media)
    private func currentMediaSize() -> CGSize {
        if let img = selectedImage { return img.size }
        if let vimg = videoPreview { return vimg.size }
        // Camera preview is aspectFill, so this is only a sensible fallback for docking.
        return CGSize(width: 4, height: 3)
    }

    private var isLivePlaybackEnabled: Bool {
        videoURL != nil && player != nil
    }

    private var showLiveAnalysisOverlay: Bool {
        isLivePlaybackEnabled && !shotEvents.isEmpty
    }

    private var currentShotEventID: UUID? {
        shotEvents.first(where: { currentFrame >= $0.startFrame && currentFrame < $0.endFrame })?.id
    }

    private var isNearHitFrame: Bool {
        let hits = Set(shotEvents.map { $0.startFrame })
        return ((currentFrame - 2)...(currentFrame + 2)).contains { hits.contains($0) }
    }

    /// Aspect-fit rect for the currently displayed media.
    private func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        let origin = CGPoint(
            x: (container.width - size.width) / 2,
            // Center vertically (keep the photo where it naturally belongs).
            y: (container.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Body
    @ViewBuilder
    private func rootGeometryContent(_ geo: GeometryProxy) -> some View {
        if workspaceVisible && hasDisplayMedia {
            mediaWorkspace(geo)
        } else {
            homeLandingScreen(geo)
        }
    }

    private var homeGuideTarget: GuideTarget? {
        guard guideActive, !showStereoAnalysis, !isLoadingVideo else { return nil }
        if !workspaceVisible || !hasDisplayMedia { return .pick }
        return taps.count < 6 ? .court : .dual
    }

    private var homeGuideHint: String {
        if !workspaceVisible || !hasDisplayMedia { return "Tap Pick Video and choose your Camera A rally clip." }
        let points = ["near left corner", "near right corner", "far right corner", "far left corner", "left net-post top", "right net-post top"]
        guard taps.count < points.count else { return "Six points placed. Tap Dual Assist to open the two-camera workspace." }
        return "Point \(taps.count + 1) of 6 · Tap the \(points[taps.count]) on the court."
    }

    var body: some View {
        GeometryReader { geo in
            rootGeometryContent(geo)
                .guided(homeGuideTarget, hint: homeGuideHint, safeInsets: geo.safeAreaInsets) { guideActive = false }
                .onAppear { containerSize = geo.size }
                .onChange(of: geo.size) { _, newSize in containerSize = newSize }
                .frame(width: geo.size.width, height: geo.size.height)
                .ignoresSafeArea()
        }
        .preferredColorScheme(nightMode ? .dark : .light)
        .alert("Video Import Failed", isPresented: Binding(
            get: { videoLoadError != nil },
            set: { if !$0 { videoLoadError = nil } }
        )) {
            Button("OK", role: .cancel) { videoLoadError = nil }
        } message: {
            Text(videoLoadError ?? "Unknown error")
        }
        .fullScreenCover(isPresented: $showMultiCamRecorder) {
            MultiCamRecorderScreen()
        }
        .fullScreenCover(isPresented: $showStereoAnalysis, onDismiss: { stereoLaunchShowSavedMatches = false }) {
            NavigationStack {
                StereoAnalysisScreen(showSavedMatchesFirst: stereoLaunchShowSavedMatches, guideActive: $guideActive)

            }
        }
        .sheet(isPresented: $showCalibrationTutorial) {
            NavigationStack { CalibrationTutorialScreen() }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(
                onPicked: { pickedURL in
                    showVideoPicker = false
                    isLoadingVideo = true
                    videoLoadError = nil
                    Task {
                        await importPickedVideo(url: pickedURL)
                        await MainActor.run { isLoadingVideo = false }
                    }
                },
                onCancel: {
                    showVideoPicker = false
                    isLoadingVideo = false
                }
            )
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ActivityView(activityItems: [url])
            } else {
                Text("Nothing to share").padding()
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .alert("CSV Import Failed", isPresented: Binding(
            get: { csvImportError != nil },
            set: { if !$0 { csvImportError = nil } }
        )) {
            Button("OK", role: .cancel) { csvImportError = nil }
        } message: {
            Text(csvImportError ?? "Unknown error")
        }
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importTrackingCSV(url: url) }
            case .failure(let err):
                csvImportError = err.localizedDescription
            }
        }
        .onAppear {
            if player == nil, let videoURL { configurePlayer(with: videoURL) }
            // Build H-grid anchors once
            hAnchors = AnchorDef.gridAnchors(court: court)
        }
        .onDisappear {
            teardownPlayer()
        }
        .onChange(of: currentFrame) { _, _ in
            if let active = currentShotEventID {
                selectedShotEventID = active
            }
        }
        .onChange(of: mode) { _, _ in clearCalibration() }
        .onChange(of: taps) { _, newTaps in
            if newTaps.count == 4, !trackPointsOrientedPx.isEmpty { runAnalysisIfPossible() }
        }
        .onChange(of: pairs.count) { _, _ in
            if Hls != nil, !trackPointsOrientedPx.isEmpty { runAnalysisIfPossible() }
        }
        .onChange(of: Hls?.H.columns.0.x) { _, _ in
            if Hls != nil, !trackPointsOrientedPx.isEmpty { runAnalysisIfPossible() }
        }
        .onChange(of: photoItem) { _, new in
            guard let item = new else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img  = UIImage(data: data) {
                    DispatchQueue.main.async {
                        selectedImage = img
                        // Clear video selection if user picks a photo
                        teardownPlayer()
                        videoURL = nil
                        videoPreview = nil
                        videoFrameSize = nil
                        currentFrame = 0

                        zoomScale = 1
                        clearCalibration()
                        contentKey = UUID()
                        photoItem = nil
                    }
                }
            }
        }
    }

    @ViewBuilder private func mediaWorkspace(_ geo: GeometryProxy) -> some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            zoomContent(geo)
                .frame(width: geo.size.width, height: geo.size.height)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.62), Color.black.opacity(0.22), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(190, geo.size.height * 0.26))
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.18), Color.black.opacity(0.60)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(280, geo.size.height * 0.34))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if showLiveAnalysisOverlay {
                livePlaybackOverlay(geo)
            }

            VStack(spacing: 0) {
                topToolbar
                Spacer(minLength: 0)
            }
            .padding(.top, geo.safeAreaInsets.top + 6)

            if guideActive {
                let courtRect = aspectFitRect(content: currentMediaSize(), in: geo.size)
                Color.clear
                    .frame(width: courtRect.width, height: courtRect.height)
                    .guideTarget(.court)
                    .position(x: courtRect.midX, y: courtRect.midY)
                    .allowsHitTesting(false)
                if taps.count >= 6 {
                    VStack {
                        Spacer()
                        Button("Dual Assist") { showStereoAnalysis = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .guideTarget(.dual)
                            .padding(.bottom, geo.safeAreaInsets.bottom + 16)
                    }
                }
            } else {
                bottomDock(geo)
            }

            if isLoadingVideo {
                Color.black.opacity(0.14).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Importing video…")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.82))
                }
                .padding(14)
                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
        }
    }

    private func homeLandingScreen(_ geo: GeometryProxy) -> some View {
        let accent = Color("BrandAccent")

        return VStack(spacing: 0) {
            Picker("Appearance", selection: $nightMode) {
                Text("Day").tag(false)
                Text("Night").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Appearance")
            .padding(.horizontal, 24)
            .padding(.top, geo.safeAreaInsets.top + 6)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image("HomeShuttle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            Text("Badminton Lab")
                                .font(.largeTitle.bold())
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        Text("Welcome! Pick a video or record a rally to start your analysis.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 12) {
                        Button {
                            if guideActive {
                                mode = .sixPoints
                                useManyAnchors = false
                            }
                            showVideoPicker = true
                        } label: {
                            Label("Pick Video", systemImage: "film")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.69, green: 0.25, blue: 0.0))
                        .foregroundStyle(.white)
                        .guideTarget(.pick)

                        Button {
                            showMultiCamRecorder = true
                        } label: {
                            Label("Dual Camera Capture", systemImage: "camera")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.69, green: 0.25, blue: 0.0))
                        .foregroundStyle(.white)
                    }
                    .font(.headline)
                    .controlSize(.large)

                    VStack(spacing: 12) {
                        homeLink("Calibration Tutorial", icon: "scope") { showCalibrationTutorial = true }
                        homeLink("Dual Cam Assist", icon: "rectangle.on.rectangle") {
                            stereoLaunchShowSavedMatches = false
                            showStereoAnalysis = true
                        }
                        homeLink("Saved Matches", icon: "tray.full") {
                            stereoLaunchShowSavedMatches = true
                            showStereoAnalysis = true
                        }
                        if !guideActive {
                            Button("Start Beginner Guide") { guideActive = true }
                                .padding(.top, 4)
                        }
                    }

                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, max(24, geo.safeAreaInsets.bottom))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .tint(accent)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    private func homeLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func bottomDock(_ geo: GeometryProxy) -> some View {
        let container = geo.size
        let fit = aspectFitRect(content: currentMediaSize(), in: container)
        let dockHeight = max(0, container.height - fit.maxY)
        // Keep controls as LOW as possible. Using the full bottom safe-area inset
        // can make the panel look "too high", so we reduce it aggressively.
        let bottomPad = max(2.0, geo.safeAreaInsets.bottom - 32.0)

        // If there's meaningful blank area under the photo, dock controls there.
        // Otherwise (e.g., camera aspectFill), keep them at the bottom but rely on auto-hide while tapping.
        if dockHeight >= 80 {
            bottomControls
                .padding(.bottom, bottomPad)
                .frame(maxWidth: container.width)
                .frame(height: dockHeight, alignment: .bottom)
                .position(x: container.width / 2, y: fit.maxY + dockHeight / 2)
        } else {
            bottomControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, bottomPad)
        }
    }

    // MARK: - Subviews
    private var topToolbar: some View {
        TopToolbar(
            onBack: {
                player?.pause()
                isPlaying = false
                workspaceVisible = false
            },
            onReset: { clearCalibration() },
            onUndo: { undoLastTap() },
            onPickPhoto: { item in photoItem = item },
            onClearPhoto: { clearAllMediaAction() },
            onAutoCalibrate: { autoCalibrate() },
            onOpenTutorial: { showCalibrationTutorial = true },
            hasPhoto: selectedImage != nil || videoPreview != nil,
            isDetecting: isDetecting,
            orderError: orderError,
            isCalibrated: isCalibrated,
            mode: mode,
            useManyAnchors: useManyAnchors,
            currentAnchorLabel: (
                useManyAnchors
                ? (anchorSet == .corners
                    ? "\(selectedCorner.rawValue) (X: \(cornerXEdge == .outer ? "Out" : "In"), Y: \(cornerYEdge == .outer ? "Out" : "In"))"
                    : (hAnchors.indices.contains(selectedHIndex) ? hAnchors[selectedHIndex].label : "H?"))
                : nil),
            probeInfo: probeInfoForToolbar,
            onOpenMultiCam: { showMultiCamRecorder = true }

        )
    }

    @ViewBuilder private func zoomContent(_ geo: GeometryProxy) -> some View {
        ZoomableScrollView(minZoom: 1, maxZoom: 6, zoomScale: $zoomScale, onSingleTap: { p in handleTap(p) }) {
            ZStack {
                // Image, video preview, or camera
                Group {
                    if let img = selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(img.size, contentMode: .fit)
                            .id(img)
                            .background(Color.clear)
                    } else if let player {
                        PlayerLayerView(player: player)
                            .aspectRatio(currentMediaSize(), contentMode: .fit)
                            .id(videoURL)
                            .background(Color.clear)
                            .allowsHitTesting(false)
                    } else if let vimg = videoPreview {
                        Image(uiImage: vimg)
                            .resizable()
                            .aspectRatio(vimg.size, contentMode: .fit)
                            .id(vimg)
                            .background(Color.clear)
                    } else {
                        emptyMediaPlaceholder
                    }
                }

                // Calibration taps overlay (draggable handles)
                if !taps.isEmpty {
                    CalibrationHandlesOverlay(taps: $taps, labels: calibrationOverlayLabels, allowEditing: taps.count >= calibrationRequiredTapCount)
                }
                // Show accumulating many-anchors points
                if useManyAnchors && !pairs.isEmpty { anchorsOverlay }
                // Court overlay + probe
                if let H = displayHomography() { courtAndProbeOverlay(H: H, geo: geo) }

                // Trajectory overlay (from PC CSV)
                if showTrajectory, !trackPointsOrientedPx.isEmpty {
                    if isLivePlaybackEnabled {
                        LiveTrajectoryOverlay(
                            pointsPx: trackPointsOrientedPx,
                            pixelSize: currentPixelSource()?.size ?? currentMediaSize(),
                            containerSize: geo.size,
                            currentFrame: currentFrame,
                            tailLength: 16,
                            hitFrames: Set(shotEvents.map { $0.startFrame })
                        )
                    } else {
                        TrajectoryOverlay(
                            pointsPx: trackPointsOrientedPx,
                            pixelSize: currentPixelSource()?.size ?? currentMediaSize(),
                            containerSize: geo.size,
                            maxPoints: 2400
                        )
                    }
                }

                // Optional landing marker for the card the user explicitly selected.
                if let point = highlightedLandingViewPoint {
                    LandingMarkersOverlay(points: [point])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(contentKey)
        .ignoresSafeArea(edges: .horizontal)
    }

    private var emptyMediaPlaceholder: some View {
        ZStack {
            Color.black

            Image(systemName: "video.badge.plus")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.white.opacity(0.10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder private var anchorsOverlay: some View {
        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
            ZStack(alignment: .leading) {
                Circle().fill(Color.yellow.opacity(Hls == nil ? 0.95 : 0.55))
                    .frame(width: 8, height: 8)
                    .position(pair.image)
                Text(pair.name)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(Hls == nil ? 0.95 : 0.55), in: Capsule())
                    .position(CGPoint(x: pair.image.x + 14, y: pair.image.y - 10))
            }
        }
    }

    @ViewBuilder private func courtAndProbeOverlay(H: Homography, geo: GeometryProxy) -> some View {
        CourtOverlay(
            size: geo.size,
            homography: H,
            court: court,
            showSingles: showSingles,
            showNet: showNet,
            showService: showService
        )
        if let p = probePx, let info = computeProbeInfo(H: H, p: p) {
            // Crosshair stays on the photo; the (X,Y) readout is shown in the top toolbar to avoid covering the image.
            ProbeOverlayClamped(
                imagePoint: p,
                label: "",
                color: info.color,
                containerSize: geo.size,
                bottomExclusion: 0
            )
        }
    }

    private var hasDisplayMedia: Bool {
        selectedImage != nil || player != nil || videoPreview != nil
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if hasDisplayMedia {
                if showLiveAnalysisOverlay {
                    if controlsHidden {
                        livePlaybackCardsDock
                    }
                } else if !shotEvents.isEmpty {
                    analysisReportPanel
                }

                if controlsHidden {
                    HStack {
                        Spacer()
                        glassMiniButton(title: "Show Controls", systemImage: "slider.horizontal.3") {
                            controlsHidden = false
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        HStack {
                            Spacer()
                            glassMiniButton(title: "Hide", systemImage: "chevron.down") {
                                controlsHidden = true
                            }
                        }

                        ModeBar(mode: $mode, cornerKind: $cornerKind)

                        if mode == .customCorners { manyAnchorsControls }

                        OverlayControlsBar(showSingles: $showSingles, showNet: $showNet, showService: $showService)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Tolerance")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.86))
                                Spacer()
                                Text("\(Int(classificationTolerance*1000)) mm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.70))
                            }
                            Slider(value: $classificationTolerance, in: 0...0.05, step: 0.005) {
                                Text("Tolerance")
                            }
                            .tint(Color("BrandAccent"))
                        }
                        .padding(.horizontal, 4)

                        mediaActionBar

                        if videoURL != nil, !trackSamples.isEmpty {
                            analysisControlBar
                        }

                        if showLiveAnalysisOverlay {
                            livePlaybackCardsHint
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.black.opacity(0.68))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                }
            } else {
                VStack(spacing: 0) {
                    mediaActionBar
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.66))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var mediaActionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                mediaPillButton(title: videoURL == nil ? "Pick Video" : "Change Video", systemImage: "film", prominent: false) {
                    showVideoPicker = true
                }

                mediaPillButton(title: "Dual Assist", systemImage: "camera.metering.center.weighted", prominent: true) {
                    showStereoAnalysis = true
                }

                if let url = videoURL {
                    mediaPillButton(title: "Share Video", systemImage: "square.and.arrow.up", prominent: false) {
                        share(url: url)
                    }

                    mediaPillButton(title: "Export Calib JSON", systemImage: "doc.badge.arrow.up", prominent: false, disabled: !isCalibrated) {
                        exportCalibrationAndShare()
                    }

                    mediaPillButton(title: trackSamples.isEmpty ? "Import ball.csv" : "Change CSV", systemImage: "doc.text", prominent: false) {
                        showCSVImporter = true
                    }

                    if !trackSamples.isEmpty {
                        mediaPillButton(title: "Clear CSV", systemImage: "trash", prominent: false, destructive: true) {
                            trackSamples.removeAll()
                            trackPointsOrientedPx.removeAll()
                            shotEvents.removeAll()
                            landingViewPoints.removeAll()
                            selectedShotEventID = nil
                            highlightedLandingEventID = nil
                        }
                    }

                    mediaPillButton(title: "Clear Video", systemImage: "trash", prominent: false, destructive: true) {
                        clearVideo()
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder private func glassMiniButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.58), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func mediaPillButton(title: String, systemImage: String, prominent: Bool, disabled: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(destructive ? Color.red.opacity(disabled ? 0.45 : 0.95) : (prominent ? .white : Color(red: 0.76, green: 0.31, blue: 0.02).opacity(disabled ? 0.45 : 0.96)))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Group {
                        if prominent {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(disabled ? Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.28) : Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.95))
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(destructive ? Color.red.opacity(disabled ? 0.18 : 0.32) : Color.white.opacity(prominent ? 0.04 : 0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.65 : 1.0)
    }

    @ViewBuilder private var analysisControlBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCalibrated {
                Text("Finish calibration first to run shot analysis.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var analysisReportPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("📊 Shot Analysis")
                        .font(.headline)
                    Text("Detected \(shotEvents.count) events · \(landingViewPoints.count) landings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let selected = selectedShotEvent,
                   let idx = shotEvents.firstIndex(where: { $0.id == selected.id }) {
                    Text("Selected: #\(idx + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(shotEvents.enumerated()), id: \.element.id) { idx, ev in
                        Button {
                            selectedShotEventID = ev.id
                            highlightedLandingEventID = ev.isLanding ? (highlightedLandingEventID == ev.id ? nil : ev.id) : nil
                            seekToFrame(ev.startFrame, shouldResume: false)
                        } label: {
                            AnalysisShotCard(
                                index: idx + 1,
                                event: ev,
                                isSelected: selectedShotEventID == ev.id,
                                landingStatusText: landingStatusText(for: ev),
                                pointSummaryText: pointSummaryText(for: ev),
                                landingOffsetText: landingOffsetText(for: ev)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            if let selected = selectedShotEvent,
               let idx = shotEvents.firstIndex(where: { $0.id == selected.id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shot #\(idx + 1) details")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(String(format: "Frames: %d → %d · %@ · Confidence %.0f%%", selected.startFrame, selected.endFrame, selected.type.displayLabel, selected.confidence * 100.0))
                        .font(.caption)
                    Text(String(format: "Start: (%.2f m, %.2f m) · End: (%.2f m, %.2f m)%@", selected.startWorld.x, selected.startWorld.y, selected.endWorld.x, selected.endWorld.y, selected.isLanding ? " · Landing" : ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let landingStatus = landingStatusText(for: selected) {
                        Text("Landing: \(landingStatus) · \(pointSummaryText(for: selected))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let offset = landingOffsetText(for: selected) {
                            Text(offset)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }


    @ViewBuilder private func livePlaybackOverlay(_ geo: GeometryProxy) -> some View {
        let fit = aspectFitRect(content: currentMediaSize(), in: geo.size)
        VStack(spacing: 0) {
            HStack {
                if isNearHitFrame {
                    Text("💥 HIT!")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.68), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        ForEach(playbackRates, id: \.self) { rate in
                            Button {
                                setPlaybackRate(rate)
                            } label: {
                                if playbackRate == rate {
                                    Label("\(String(format: "%g", rate))x", systemImage: "checkmark")
                                } else {
                                    Text("\(String(format: "%g", rate))x")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "speedometer")
                            Text("\(String(format: "%g", playbackRate))x")
                                .fontWeight(.bold)
                        }
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.68), in: Capsule())
                    }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .frame(width: fit.width, height: fit.height)
        .position(x: fit.midX, y: fit.midY)
        .allowsHitTesting(true)
    }

    @ViewBuilder private var livePlaybackCardsDock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let active = currentShotEventID,
                   let idx = shotEvents.firstIndex(where: { $0.id == active }) {
                    Text("Now Playing · Shot #\(idx + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Shot Cards")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Tap a card to jump · landing cards toggle point")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(shotEvents.enumerated()), id: \.element.id) { idx, ev in
                            let activeID = currentShotEventID ?? selectedShotEventID
                            Button {
                                selectedShotEventID = ev.id
                                highlightedLandingEventID = ev.isLanding ? (highlightedLandingEventID == ev.id ? nil : ev.id) : nil
                                seekToFrame(ev.startFrame, shouldResume: false)
                            } label: {
                                AnalysisShotCard(
                                    index: idx + 1,
                                    event: ev,
                                    isSelected: activeID == ev.id,
                                    landingStatusText: landingStatusText(for: ev),
                                    pointSummaryText: pointSummaryText(for: ev),
                                    landingOffsetText: landingOffsetText(for: ev)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(ev.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: currentShotEventID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
                .onAppear {
                    if let currentShotEventID {
                        proxy.scrollTo(currentShotEventID, anchor: .center)
                    } else if let selectedShotEventID {
                        proxy.scrollTo(selectedShotEventID, anchor: .center)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    @ViewBuilder private var livePlaybackCardsHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
            Text("Hide controls to view shot cards. Tap a landing card to show or hide its orange landing point.")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var selectedShotEvent: ShotEvent? {
        if let selectedShotEventID,
           let event = shotEvents.first(where: { $0.id == selectedShotEventID }) {
            return event
        }
        return shotEvents.first
    }

    private var highlightedLandingViewPoint: CGPoint? {
        guard controlsHidden,
              let id = highlightedLandingEventID,
              let event = shotEvents.first(where: { $0.id == id }),
              event.isLanding,
              let H = displayHomography() else { return nil }
        return H.project(event.endWorld)
    }

    @ViewBuilder private var manyAnchorsControls: some View {
        VStack(spacing: 8) {
            Toggle("Use Many Anchors (Least-Squares)", isOn: $useManyAnchors)
                .controlSize(.small)
            if useManyAnchors {
                VStack(spacing: 8) {
                    Picker("Anchor Set", selection: $anchorSet) {
                        Text("Corners").tag(AnchorSet.corners)
                        Text("H-grid").tag(AnchorSet.hGrid)
                    }
                    .pickerStyle(.segmented)

                    if anchorSet == .corners {
                        Picker("Anchor", selection: $selectedCorner) { ForEach(CourtAnchor.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented)
                        HStack(spacing: 12) {
                            Picker("X edge", selection: $cornerXEdge) { Text("X: Out").tag(CornerKind.outer); Text("X: In").tag(CornerKind.inner) }
                                .pickerStyle(.segmented)
                            Picker("Y edge", selection: $cornerYEdge) { Text("Y: Out").tag(CornerKind.outer); Text("Y: In").tag(CornerKind.inner) }
                                .pickerStyle(.segmented)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(hAnchors.enumerated()), id: \.element.id) { idx, a in
                                    Button(action: { selectedHIndex = idx }) {
                                        Text(a.label)
                                            .font(.caption2).monospaced()
                                            .padding(.horizontal, 8).padding(.vertical, 6)
                                            .background(selectedHIndex == idx ? Color.blue.opacity(0.2) : Color.clear)
                                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                                    }
                                }
                            }
                        }
                        .frame(height: 34)
                    }

                    Button("Solve (\(pairs.count))") {
                        let img = pairs.map { $0.image }
                        let wrd = pairs.map { $0.world }
                        Hls = HomoLS.estimate(imagePts: img, worldPts: wrd)
                        probePx = nil
                        runAnalysisIfPossible()
                    }
                    .disabled(pairs.count < 4)

                    Button("Clear") {
                        pairs.removeAll(); Hls = nil; probePx = nil
                    }
                }
            }
        }
    }

    // MARK: - Derived

    /// Prefer LS (many-anchors) homography if available; else fall back to 4-tap
    private func displayHomography() -> Homography? {
        if let Hls { return Homography(h: Hls.H) }
        return currentHomography()
    }

    private var isCalibrated: Bool {
        if Hls != nil { return true }
        let required = calibrationRequiredTapCount
        return taps.count >= required && currentHomography() != nil
    }

    private var analysisPlayMode: PlayMode { showSingles ? .singles : .doubles }

    private func landingStatusText(for event: ShotEvent) -> String? {
        guard event.isLanding else { return nil }
        let result = court.classifyPlay(point: event.endWorld, mode: analysisPlayMode, tolerance: classificationTolerance)
        switch result.status {
        case .inside: return "IN"
        case .onLine: return "LINE"
        case .outside: return "OUT"
        }
    }

    private func pointSummaryText(for event: ShotEvent) -> String {
        if event.isLanding {
            return String(format: "Landing · X %.2f m, Y %.2f m", event.endWorld.x, event.endWorld.y)
        }
        return String(format: "End · X %.2f m, Y %.2f m", event.endWorld.x, event.endWorld.y)
    }

    private func landingOffsetText(for event: ShotEvent) -> String? {
        guard event.isLanding else { return nil }

        let p = event.endWorld
        let x = Double(p.x)
        let y = Double(p.y)
        let left = (analysisPlayMode == .singles) ? court.xS1 : 0.0
        let right = (analysisPlayMode == .singles) ? court.xS2 : court.W
        let near = 0.0
        let far = court.L

        var misses: [String] = []
        if x < left { misses.append(String(format: "%.2f m outside left", left - x)) }
        if x > right { misses.append(String(format: "%.2f m outside right", x - right)) }
        if y < near { misses.append(String(format: "%.2f m short of near baseline", near - y)) }
        if y > far { misses.append(String(format: "%.2f m long of far baseline", y - far)) }

        if !misses.isEmpty {
            return "Distance from legal area: " + misses.joined(separator: " · ")
        }

        let distances: [(String, Double)] = [
            ("left sideline", x - left),
            ("right sideline", right - x),
            ("near baseline", y - near),
            ("far baseline", far - y)
        ]
        if let nearest = distances.min(by: { $0.1 < $1.1 }) {
            if nearest.1 <= classificationTolerance + court.lineWidth * 0.5 {
                return "Distance from legal line: 0.00 m · On the line"
            }
            return String(format: "Distance from nearest legal line: %.2f m (%@)", nearest.1, nearest.0)
        }
        return nil
    }

    /// Latest probe (X,Y, IN/OUT) for showing in the top toolbar (keeps the photo unobstructed).
    private var probeInfoForToolbar: (text: String, color: Color)? {
        guard let p = probePx, let H = displayHomography() else { return nil }
        return computeProbeInfo(H: H, p: p)
    }

    private func computeProbeInfo(H: Homography, p: CGPoint) -> (text: String, color: Color)? {
        guard let world = H.unproject(p) else { return nil }
        let playMode: PlayMode = showSingles ? .singles : .doubles
        let xmm = world.x * 1000.0
        let ymm = world.y * 1000.0
        let result = court.classifyPlay(point: world, mode: playMode, tolerance: classificationTolerance, useServiceLines: showService)
        let tag: String = {
            switch result.status {
            case .inside: return "IN"
            case .onLine: return "IN (LINE)"
            case .outside: return "OUT"
            }
        }()
        let color: Color = result.isIn ? .green : .red
        let label = String(format: "X=%5.0f mm, Y=%5.0f mm • %@", xmm, ymm, tag)
        return (label, color)
    }

    // Compute world coordinate for Many-Anchor corner with X/Y edge choice
    private func worldForManyAnchorCorner(_ c: CourtAnchor, xEdge: CornerKind, yEdge: CornerKind) -> CGPoint {
        let W = court.W, L = court.L
        let xS1 = court.xS1, xS2 = court.xS2
        let d = court.dLong
        func xForLeft() -> CGFloat { xEdge == .outer ? 0 : xS1 }
        func xForRight() -> CGFloat { xEdge == .outer ? W : xS2 }
        func yForBottom() -> CGFloat { yEdge == .outer ? 0 : d }
        func yForTop() -> CGFloat { yEdge == .outer ? L : L - d }
        switch c {
        case .BL: return CGPoint(x: xForLeft(),  y: yForBottom())
        case .BR: return CGPoint(x: xForRight(), y: yForBottom())
        case .TR: return CGPoint(x: xForRight(), y: yForTop())
        case .TL: return CGPoint(x: xForLeft(),  y: yForTop())
        }
    }

    // MARK: - Actions

    private func handleTap(_ p: CGPoint) {
        orderError = nil

        // If already calibrated (LS or classic), tap becomes a probe cursor.
        if isCalibrated {
            probePx = p
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        // If collecting many-anchors, each tap pairs with the selected anchor.
        if useManyAnchors {
            // While the user is placing anchors, keep the bottom panel out of the way.
            if !controlsHidden { controlsHidden = true }
            if anchorSet == .corners {
                let world = worldForManyAnchorCorner(selectedCorner, xEdge: cornerXEdge, yEdge: cornerYEdge)
                let suffix = "-" + (cornerXEdge == .outer ? "O" : "I") + (cornerYEdge == .outer ? "O" : "I")
                pairs.append(AnchorPair(image: p, world: world, name: selectedCorner.rawValue + suffix))
            } else {
                let def = hAnchors[min(max(0, selectedHIndex), hAnchors.count-1)]
                pairs.append(AnchorPair(image: p, world: def.world, name: def.label))
            }
            return
        }

        // Otherwise: classic tap-based flow
        let maxTaps = calibrationRequiredTapCount
        guard taps.count < maxTaps else { return }

        // Once the user starts tapping, auto-hide the bottom controls to avoid accidental presses.
        if !controlsHidden { controlsHidden = true }
        taps.append(p)

        if taps.count == 4, !isOrderBL_BR_TR_TL(Array(taps.prefix(4))) {
            orderError = "Order incorrect. Please tap: ① BL → ② BR → ③ TR → ④ TL."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else if taps.count == maxTaps {
            // Calibration done — if we already imported tracking, update analysis.
            runAnalysisIfPossible()
        }
    }

    private func undoLastTap() {
        if useManyAnchors, Hls == nil {
            guard !pairs.isEmpty else { return }
            pairs.removeLast()
        } else {
            guard !taps.isEmpty else { return }
            taps.removeLast()
        }
        orderError = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }


    private func configurePlayer(with url: URL) {
        teardownPlayer()
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
        currentFrame = 0
        isPlaying = false
        setupPlayerTimeObserver(for: newPlayer)
    }

    private func teardownPlayer() {
        if let player, let token = playerTimeObserver {
            player.removeTimeObserver(token)
        }
        playerTimeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func setupPlayerTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 1.0 / max(fpsForPlayback(), 30.0), preferredTimescale: 600)
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let fps = max(self.fpsForPlayback(), 1.0)
            self.currentFrame = max(0, Int((time.seconds * fps).rounded()))

            if self.isPlaying,
               let item = player.currentItem,
               item.status == .readyToPlay,
               item.duration.isNumeric,
               item.duration.seconds > 0,
               time.seconds >= item.duration.seconds - 0.05 {
                self.isPlaying = false
            }
        }
    }

    private func fpsForPlayback() -> Double {
        if let url = videoURL, let fps = Self.videoFPS(url: url) { return fps }
        return 50.0
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if trackPointsOrientedPx.indices.contains(currentFrame) == false,
               !trackPointsOrientedPx.isEmpty {
                seekToFrame(0, shouldResume: false)
            } else if let item = player.currentItem,
                      item.duration.isNumeric,
                      item.duration.seconds > 0,
                      player.currentTime().seconds >= item.duration.seconds - 0.05 {
                seekToFrame(0, shouldResume: false)
            }
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    private func seekToFrame(_ frame: Int, shouldResume: Bool) {
        guard let player else { return }
        let fps = max(fpsForPlayback(), 1.0)
        let seconds = Double(max(0, frame)) / fps
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        let resume = shouldResume && isPlaying
        player.pause()
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            self.currentFrame = max(0, frame)
            if resume {
                player.playImmediately(atRate: self.playbackRate)
                self.isPlaying = true
            } else {
                self.isPlaying = false
            }
        }
    }

    private func clearCalibration() {
        taps.removeAll()
        orderError = nil
        pairs.removeAll()
        Hls = nil
        probePx = nil
        shotEvents.removeAll()
        landingViewPoints.removeAll()
        selectedShotEventID = nil
        highlightedLandingEventID = nil
    }

    private func clearPhotoAction() {
        selectedImage = nil
        photoItem = nil
        zoomScale = 1
        clearCalibration()
        contentKey = UUID() // ensure zoom container does not keep old subviews
    }

    private func clearAllMediaAction() {
        clearPhotoAction()
        clearVideo()
        controlsHidden = false
        mode = .fourCorners
    }

    private func clearVideo() {
        teardownPlayer()
        videoURL = nil
        videoPreview = nil
        videoFrameSize = nil
        videoRawSize = nil
        videoPreferredTransform = .identity
        videoOrientedRect = .zero
        trackSamples.removeAll()
        trackPointsOrientedPx.removeAll()
        shotEvents.removeAll()
        landingViewPoints.removeAll()
        selectedShotEventID = nil
        highlightedLandingEventID = nil
        currentFrame = 0
        isPlaying = false
        contentKey = UUID()
    }


    // MARK: - Export / Share

    private func share(url: URL) {
        shareURL = url
        showShareSheet = true
    }

    private struct ExportPoint: Codable {
        var x: Double
        var y: Double
    }

    private struct ExportPoint3D: Codable {
        var x: Double
        var y: Double
        var z: Double
    }

    private struct CalibrationExport: Codable {
        var version: Int
        var createdAtISO8601: String
        var sourceType: String            // "video" or "photo"
        var sourceName: String
        var imagePixelWidth: Int
        var imagePixelHeight: Int
        var mode: String                  // fourCorners / 6Points / customCorners
        var calibrationLabels: [String]
        var homographyPointCount: Int
        var imagePointsPx: [ExportPoint]
        var worldPointsM: [ExportPoint]
        var worldPoints3D: [ExportPoint3D]?
        var H_world_to_image: [[Double]]  // 3x3
        var H_image_to_world: [[Double]]  // 3x3
    }

    private func exportCalibrationAndShare() {
        guard let url = writeCalibrationJSON() else { return }
        share(url: url)
    }

    /// Convert a tap point in *view/container coordinates* to a pixel coordinate in the underlying media.
    private func viewPointToPixel(_ p: CGPoint, pixelSize: CGSize) -> CGPoint? {
        guard containerSize.width > 0, containerSize.height > 0 else { return nil }
        let fit = aspectFitRect(content: pixelSize, in: containerSize)
        guard fit.width > 0, fit.height > 0 else { return nil }
        let clamped = CGPoint(
            x: min(max(p.x, fit.minX), fit.maxX),
            y: min(max(p.y, fit.minY), fit.maxY)
        )
        let u = (clamped.x - fit.minX) / fit.width
        let v = (clamped.y - fit.minY) / fit.height
        return CGPoint(x: u * pixelSize.width, y: v * pixelSize.height)
    }

    private func currentPixelSource() -> (type: String, name: String, size: CGSize)? {
        if let url = videoURL, let vs = videoFrameSize {
            return ("video", url.lastPathComponent, vs)
        }
        if let img = selectedImage {
            let w: CGFloat
            let h: CGFloat
            if let cg = img.cgImage {
                w = CGFloat(cg.width)
                h = CGFloat(cg.height)
            } else {
                w = img.size.width * img.scale
                h = img.size.height * img.scale
            }
            return ("photo", "photo", CGSize(width: w, height: h))
        }
        if let vs = videoFrameSize {
            return ("video", "video", vs)
        }
        return nil
    }

    private func matrixToRows(_ H: simd_double3x3) -> [[Double]] {
        return [
            [H[0,0], H[0,1], H[0,2]],
            [H[1,0], H[1,1], H[1,2]],
            [H[2,0], H[2,1], H[2,2]]
        ]
    }

    /// Writes calibration as JSON to a temp file and returns its URL.
    private func writeCalibrationJSON() -> URL? {
        guard let src = currentPixelSource() else {
            exportError = "No media loaded (pick a video or photo first)."
            return nil
        }

        guard taps.count >= calibrationRequiredTapCount, let _ = currentHomography() else {
            exportError = mode == .sixPoints
                ? "Please finish 6-point calibration first (BL→BR→TR→TL→Net-L→Net-R)."
                : "Please finish 4-point calibration first (tap 4 corners BL→BR→TR→TL)."
            return nil
        }

        let tapsForExport = Array(taps.prefix(calibrationRequiredTapCount))
        let pixelPtsAll: [CGPoint] = tapsForExport.compactMap { viewPointToPixel($0, pixelSize: src.size) }
        if pixelPtsAll.count != calibrationRequiredTapCount {
            exportError = "Calibration points are outside the media area. Please tap directly on the image/video."
            return nil
        }

        let pixelPts = Array(pixelPtsAll.prefix(4))
        let worldPtsAll = singleCamWorldPoints2D()
        let worldPts = Array(worldPtsAll.prefix(4))

        guard let Hpx = Homography.estimate(world: worldPts, image: pixelPts) else {
            exportError = "Failed to compute homography from the selected points."
            return nil
        }
        let H_w2i = matrixToRows(Hpx.h)
        let H_i2w = matrixToRows(Hpx.h.inverse)

        let iso = ISO8601DateFormatter().string(from: Date())
        let payload = CalibrationExport(
            version: 1,
            createdAtISO8601: iso,
            sourceType: src.type,
            sourceName: src.name,
            imagePixelWidth: Int(src.size.width.rounded()),
            imagePixelHeight: Int(src.size.height.rounded()),
            mode: mode.rawValue,
            calibrationLabels: mode == .sixPoints
                ? ["BL", "BR", "TR", "TL", "Net-L", "Net-R"]
                : ["BL", "BR", "TR", "TL"],
            homographyPointCount: 4,
            imagePointsPx: pixelPtsAll.map { ExportPoint(x: Double($0.x), y: Double($0.y)) },
            worldPointsM: worldPtsAll.prefix(calibrationRequiredTapCount).map { ExportPoint(x: Double($0.x), y: Double($0.y)) },
            worldPoints3D: singleCamWorldPoints3D()?.prefix(calibrationRequiredTapCount).map { ExportPoint3D(x: $0.x, y: $0.y, z: $0.z) },
            H_world_to_image: H_w2i,
            H_image_to_world: H_i2w
        )

        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(payload)
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let out = tmp.appendingPathComponent("calibration_\(UUID().uuidString).json")
            try data.write(to: out, options: [.atomic])
            return out
        } catch {
            exportError = "Failed to write calibration JSON: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Tracking (ball.csv) Import + Analysis

    private func importTrackingCSV(url: URL) async {
        guard videoURL != nil else {
            await MainActor.run {
                csvImportError = "Please pick a video first (so we can align coordinates)."
            }
            return
        }

        var didAccess = false
        if url.startAccessingSecurityScopedResource() {
            didAccess = true
        }
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                throw NSError(domain: "CSV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode CSV as UTF-8/ASCII."])
            }

            let samples = try parseTrackCSV(text)

            // Convert to oriented pixel coordinates that match the preview frame (appliesPreferredTrackTransform=true)
            let oriented = convertSamplesToOrientedPixel(samples)

            await MainActor.run {
                self.trackSamples = samples
                self.trackPointsOrientedPx = oriented
                self.shotEvents.removeAll()
                self.landingViewPoints.removeAll()
                self.selectedShotEventID = nil
                self.highlightedLandingEventID = nil
                // Auto-run analysis if calibrated
                runAnalysisIfPossible()
            }
        } catch {
            await MainActor.run {
                csvImportError = error.localizedDescription
            }
        }
    }

    private func parseTrackCSV(_ text: String) throws -> [TrackSample] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else {
            throw NSError(domain: "CSV", code: -2, userInfo: [NSLocalizedDescriptionKey: "CSV has no data."])
        }

        // Header
        let header = lines[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func idx(_ key: String) -> Int? {
            header.firstIndex { $0.lowercased() == key.lowercased() }
        }
        guard let iFrame = idx("Frame"), let iVis = idx("Visibility"), let iX = idx("X"), let iY = idx("Y") else {
            throw NSError(domain: "CSV", code: -3, userInfo: [NSLocalizedDescriptionKey: "CSV header must include Frame,Visibility,X,Y"])
        }

        var out: [TrackSample] = []
        out.reserveCapacity(lines.count - 1)
        for ln in lines.dropFirst() {
            let cols = ln.split(separator: ",")
            if cols.count <= max(iFrame, iVis, iX, iY) { continue }
            let f = Int(cols[iFrame].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let v = Int(cols[iVis].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let x = Double(cols[iX].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let y = Double(cols[iY].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            out.append(TrackSample(frame: f, x: x, y: y, vis: v))
        }
        return out.sorted { $0.frame < $1.frame }
    }

    /// Convert PC/OpenCV pixel coordinates (storage orientation) to iOS preview coordinates
    /// (appliesPreferredTrackTransform=true). Returns an array indexed by frame.
    private func convertSamplesToOrientedPixel(_ samples: [TrackSample]) -> [CGPoint?] {
        // Determine max frame
        let maxFrame = samples.map { $0.frame }.max() ?? 0
        var arr = Array<CGPoint?>(repeating: nil, count: maxFrame + 1)

        // If we don't have transform info, assume coords already match preview
        guard videoPreferredTransform != .identity || videoOrientedRect != .zero else {
            for s in samples {
                if s.vis == 1 { arr[s.frame] = CGPoint(x: s.x, y: s.y) }
            }
            return arr
        }

        let orientedSize = videoFrameSize ?? CGSize(width: abs(videoOrientedRect.width), height: abs(videoOrientedRect.height))
        let rawSize = videoRawSize

        func inBounds(_ p: CGPoint, size: CGSize) -> Bool {
            p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height
        }

        // Option A: assume CSV coords already in oriented space
        var rawInBounds = 0
        var total = 0
        for s in samples where s.vis == 1 {
            total += 1
            if inBounds(CGPoint(x: s.x, y: s.y), size: orientedSize) { rawInBounds += 1 }
        }

        // Option B: apply preferredTransform (raw -> oriented)
        var xformInBounds = 0
        var xformed: [Int: CGPoint] = [:]
        xformed.reserveCapacity(total)
        for s in samples where s.vis == 1 {
            let pr = CGPoint(x: s.x, y: s.y)
            let p2 = pr.applying(videoPreferredTransform)
            let po = CGPoint(x: p2.x - videoOrientedRect.origin.x, y: p2.y - videoOrientedRect.origin.y)
            xformed[s.frame] = po
            if inBounds(po, size: orientedSize) { xformInBounds += 1 }
        }

        // Choose the mapping that keeps more points inside bounds
        let useTransform = xformInBounds >= rawInBounds && (rawSize != nil)

        for s in samples {
            guard s.vis == 1 else { continue }
            if useTransform {
                if let p = xformed[s.frame] { arr[s.frame] = p }
            } else {
                arr[s.frame] = CGPoint(x: s.x, y: s.y)
            }
        }
        return arr
    }


    private func runAnalysisIfPossible() {
        guard let H = displayHomography() else { return }
        guard !trackPointsOrientedPx.isEmpty else { return }
        guard let pxSize = currentPixelSource()?.size else { return }
        guard let vurl = videoURL else { return }

        // Important:
        // The shuttle is airborne, so a full frame-by-frame homography unprojection onto the court plane
        // is only a proxy, not a true 3D position. We therefore do detection in IMAGE SPACE first,
        // and only use the homography later for approximate on-court display / end-zone classification.
        let fps = ContentView.videoFPS(url: vurl) ?? 50.0

        // 1) Clean the imported image-space trajectory.
        var cleanedPx = suppressLoopedRepeats(trackPointsOrientedPx)
        cleanedPx = rejectPixelOutliers(cleanedPx, fps: fps)
        cleanedPx = interpolateShortGaps(cleanedPx, maxGap: Int(round(0.12 * fps))) // up to ~0.12 s
        cleanedPx = medianFilter(cleanedPx, radius: 2)
        cleanedPx = movingAverage(cleanedPx, radius: 1)

        // 2) Build approximate world proxies only AFTER cleaning.
        var worldByFrame: [CGPoint?] = Array(repeating: nil, count: cleanedPx.count)
        for f in 0..<cleanedPx.count {
            guard let ppx = cleanedPx[f] else { continue }
            guard let pv = pixelPointToView(ppx, pixelSize: pxSize) else { continue }
            guard let w = H.unproject(pv) else { continue }
            worldByFrame[f] = clampWorldProxy(w)
        }

        // 3) Detect hit events in image space (more stable for airborne shuttle motion).
        let hitFrames = refineHitFramesWithPhysics(cleanedPx, fps: fps, seedHits: detectHitFramesImageSpace(cleanedPx, fps: fps))

        // 4) Detect only very conservative terminal landings (long disappearance / point end).
        let landingFrames = detectLandingFramesImageSpace(cleanedPx, worldByFrame: worldByFrame, fps: fps)

        // 5) Build shot segments from hit -> next hit, plus an optional final landing.
        let segments = buildShotSegmentsFromHits(pixel: cleanedPx, world: worldByFrame, fps: fps, hitFrames: hitFrames, landingFrames: landingFrames)

        // 6) Classify conservatively. Prefer "Unknown" over confident wrong labels.
        let events: [ShotEvent] = segments.map { seg in
            let (typ, conf) = classifyShotSegment(seg)
            return ShotEvent(
                startFrame: seg.startFrame,
                endFrame: seg.endFrame,
                startWorld: seg.startWorld,
                endWorld: seg.endWorld,
                isLanding: seg.isLanding,
                type: typ,
                confidence: conf
            )
        }

        shotEvents = events
        landingViewPoints = events.filter { $0.isLanding }.map { H.project($0.endWorld) }
        if selectedShotEventID == nil || !events.contains(where: { $0.id == selectedShotEventID }) {
            selectedShotEventID = events.first?.id
        }
        highlightedLandingEventID = nil
    }

    // MARK: - Shot analysis helpers

    private struct ShotSegment {
        let startFrame: Int
        let endFrame: Int
        let startPx: CGPoint
        let endPx: CGPoint
        let startWorld: CGPoint
        let endWorld: CGPoint
        let durationSec: Double
        let isLanding: Bool
        let analysisStartFrame: Int
        let analysisEndFrame: Int
        let sampleFrames: [Int]
        let pixelSamples: [CGPoint]
        let worldSamples: [CGPoint]
    }

    private struct SingleCamSegmentFeatures {
        let startDepthFromNet: Double
        let endDepthFromNet: Double
        let startSignedLongitudinal: Double
        let endSignedLongitudinal: Double
        let travelMeters: Double
        let lateralTravelMeters: Double
        let longitudinalTravelMeters: Double
        let crossesNet: Bool
        let isCrossCourt: Bool
        let apexProminenceMeters: Double?
        let apexAbsoluteHeightMeters: Double?
        let startApproxHeightMeters: Double?
        let endApproxHeightMeters: Double?
        let netClearanceMeters: Double?
        let timeToPeakRatio: Double?
        let endDescentPxPerFrame: Double
        let validSampleCount: Int
        let durationSec: Double
        let landingDepthBand: DepthBand
        let startDepthBand: DepthBand
        let endDepthBand: DepthBand
    }

    private enum DepthBand {
        case front
        case mid
        case rear
    }

    private func clampWorldProxy(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: min(CGFloat(court.W), max(0, p.x)),
            y: min(CGFloat(court.L), max(0, p.y))
        )
    }

    private func suppressLoopedRepeats(_ points: [CGPoint?]) -> [CGPoint?] {
        // TrackNet can occasionally emit a copied / looped subsequence (same 8/10/12/16-frame pattern
        // repeated several times). Those loops create fake "hits", so keep the first cycle and drop repeats.
        let lags = [8, 10, 12, 16, 20]
        let minRun = 10

        func samePoint(_ a: CGPoint?, _ b: CGPoint?, tol: CGFloat = 0.5) -> Bool {
            switch (a, b) {
            case (.none, .none):
                return true
            case let (.some(pa), .some(pb)):
                return hypot(pa.x - pb.x, pa.y - pb.y) <= tol
            default:
                return false
            }
        }

        var out = points
        for lag in lags {
            var i = 0
            while i + lag < out.count {
                if samePoint(out[i], out[i + lag]) {
                    let start = i
                    while i + lag < out.count && samePoint(out[i], out[i + lag]) {
                        i += 1
                    }
                    let end = i - 1
                    let runLen = end - start + 1
                    if runLen >= minRun {
                        let j0 = start + lag
                        let j1 = min(out.count - 1, end + lag)
                        if j0 <= j1 {
                            for j in j0...j1 { out[j] = nil }
                        }
                    }
                } else {
                    i += 1
                }
            }
        }
        return out
    }

    private func rejectPixelOutliers(_ points: [CGPoint?], fps: Double) -> [CGPoint?] {
        // Remove single-frame spikes in image space. Use a generous threshold so we only reject
        // obvious tracker glitches, not genuine fast smashes.
        let maxJump: CGFloat = 180.0 * CGFloat(50.0 / max(1.0, fps))

        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }

        var out = points
        guard out.count >= 3 else { return out }

        for i in 1..<(out.count - 1) {
            guard let prev = out[i - 1], let cur = out[i], let next = out[i + 1] else { continue }
            let d1 = dist(prev, cur)
            let d2 = dist(cur, next)
            let bridge = dist(prev, next)

            if d1 > maxJump && d2 > maxJump && bridge < maxJump * 0.8 {
                out[i] = nil
            }
        }
        return out
    }

    private func interpolateShortGaps(_ world: [CGPoint?], maxGap: Int) -> [CGPoint?] {
        guard maxGap >= 1 else { return world }
        var out = world
        var i = 0
        while i < out.count {
            if out[i] != nil { i += 1; continue }
            let gapStart = i
            while i < out.count && out[i] == nil { i += 1 }
            let gapEnd = i - 1
            let gapLen = gapEnd - gapStart + 1

            let left = gapStart - 1
            let right = gapEnd + 1
            if gapLen <= maxGap,
               left >= 0, right < out.count,
               let p0 = out[left], let p1 = out[right] {

                for k in 1..<(gapLen + 1) {
                    let t = CGFloat(k) / CGFloat(gapLen + 1)
                    let x = p0.x + (p1.x - p0.x) * t
                    let y = p0.y + (p1.y - p0.y) * t
                    out[gapStart + (k - 1)] = CGPoint(x: x, y: y)
                }
            }
        }
        return out
    }

    private func movingAverage(_ world: [CGPoint?], radius: Int) -> [CGPoint?] {
        guard radius >= 1 else { return world }
        var out = world
        for i in 0..<world.count {
            guard world[i] != nil else { continue }
            var xs: [CGFloat] = []
            var ys: [CGFloat] = []
            for j in max(0, i - radius)...min(world.count - 1, i + radius) {
                if let p = world[j] {
                    xs.append(p.x)
                    ys.append(p.y)
                }
            }
            if xs.count >= 2 {
                let mx = xs.reduce(0, +) / CGFloat(xs.count)
                let my = ys.reduce(0, +) / CGFloat(ys.count)
                out[i] = CGPoint(x: mx, y: my)
            }
        }
        return out
    }


    private func medianFilter(_ points: [CGPoint?], radius: Int) -> [CGPoint?] {
        guard radius >= 1 else { return points }
        var out = points
        for i in 0..<points.count {
            guard points[i] != nil else { continue }
            var xs: [CGFloat] = []
            var ys: [CGFloat] = []
            for j in max(0, i - radius)...min(points.count - 1, i + radius) {
                if let p = points[j] {
                    xs.append(p.x)
                    ys.append(p.y)
                }
            }
            guard xs.count >= 3 else { continue }
            xs.sort(); ys.sort()
            out[i] = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
        }
        return out
    }

    private func localPixelSpeed(_ points: [CGPoint?], at frame: Int, span: Int = 2) -> CGFloat {
        let a = max(0, frame - span)
        let b = min(points.count - 1, frame + span)
        guard a < b else { return 0 }
        guard let p0 = nearestValidPoint(in: points, around: a, radius: span)?.1,
              let p1 = nearestValidPoint(in: points, around: b, radius: span)?.1 else { return 0 }
        return hypot(p1.x - p0.x, p1.y - p0.y) / CGFloat(max(1, b - a))
    }

    private func stabilizationDelayFrames(_ points: [CGPoint?], around hitFrame: Int, fps: Double) -> Int {
        let minDelay = Int(round(0.08 * fps))
        let maxDelay = Int(round(0.16 * fps))
        let baseDelay = Int(round(0.10 * fps))
        let speed = localPixelSpeed(points, at: hitFrame, span: 2)
        let normalized = min(1.0, max(0.0, Double(speed / 22.0)))
        let extra = Int(round(normalized * 0.04 * fps))
        return min(maxDelay, max(minDelay, baseDelay + extra))
    }

    private func representativePoint(in arr: [CGPoint?], around frame: Int, radius: Int = 3) -> (Int, CGPoint)? {
        guard !arr.isEmpty else { return nil }
        let lo = max(0, frame - radius)
        let hi = min(arr.count - 1, frame + radius)
        var candidates: [(Int, CGPoint)] = []
        if lo <= hi {
            for idx in lo...hi {
                if let p = arr[idx] { candidates.append((idx, p)) }
            }
        }
        if candidates.isEmpty {
            return nearestValidPoint(in: arr, around: frame, radius: max(radius + 3, 6))
        }

        var xs = candidates.map { $0.1.x }.sorted()
        var ys = candidates.map { $0.1.y }.sorted()
        let med = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])

        return candidates.min { lhs, rhs in
            let dl = hypot(lhs.1.x - med.x, lhs.1.y - med.y) + CGFloat(abs(lhs.0 - frame)) * 0.35
            let dr = hypot(rhs.1.x - med.x, rhs.1.y - med.y) + CGFloat(abs(rhs.0 - frame)) * 0.35
            return dl < dr
        }
    }

    private func stableRepresentativePoint(in arr: [CGPoint?], around hitFrame: Int, direction: Int, delay: Int, radius: Int = 2) -> (Int, CGPoint)? {
        guard !arr.isEmpty else { return nil }
        let center = min(max(0, hitFrame + direction * delay), arr.count - 1)
        return representativePoint(in: arr, around: center, radius: radius)
    }

    private func refineHitFramesWithPhysics(_ points: [CGPoint?], fps: Double, seedHits: [Int]) -> [Int] {
        guard !seedHits.isEmpty else { return [] }
        let minGap = max(10, Int(round(0.22 * fps)))
        var refined: [Int] = []

        for seed in seedHits {
            let search = max(4, Int(round(0.08 * fps)))
            let lo = max(1, seed - search)
            let hi = min(points.count - 2, seed + search)
            var bestFrame = seed
            var bestScore: CGFloat = -.greatestFiniteMagnitude

            for frame in lo...hi {
                guard let pPrev = points[frame - 1], let p = points[frame], let pNext = points[frame + 1] else { continue }
                let pre = CGPoint(x: p.x - pPrev.x, y: p.y - pPrev.y)
                let post = CGPoint(x: pNext.x - p.x, y: pNext.y - p.y)
                let speedPre = hypot(pre.x, pre.y)
                let speedPost = hypot(post.x, post.y)
                guard speedPre > 3, speedPost > 3 else { continue }
                let dot = pre.x * post.x + pre.y * post.y
                let cosv = max(-1.0, min(1.0, Double(dot / max(1e-6, speedPre * speedPost))))
                let angle = CGFloat(acos(cosv))
                let score = angle + 0.02 * (speedPre + speedPost)
                if score > bestScore {
                    bestScore = score
                    bestFrame = frame
                }
            }

            if let last = refined.last, bestFrame - last < minGap {
                let lastSpeed = localPixelSpeed(points, at: last)
                let newSpeed = localPixelSpeed(points, at: bestFrame)
                if newSpeed > lastSpeed { refined[refined.count - 1] = bestFrame }
            } else {
                refined.append(bestFrame)
            }
        }
        return refined
    }

    private func detectHitFramesImageSpace(_ points: [CGPoint?], fps: Double) -> [Int] {
        // Broad-window direction-change detector in IMAGE SPACE.
        let k = max(3, Int(round(0.08 * fps)))            // ~4 frames @ 50 fps
        let minGap = max(14, Int(round(0.28 * fps)))      // separate consecutive contacts
        let minDisp: CGFloat = 18.0 * CGFloat(50.0 / max(1.0, fps))
        let angleTh: CGFloat = 135.0 * .pi / 180.0

        func angleBetween(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let da = hypot(a.x, a.y)
            let db = hypot(b.x, b.y)
            if da < 1e-6 || db < 1e-6 { return 0 }
            let dot = a.x * b.x + a.y * b.y
            let c = max(-1.0, min(1.0, Double(dot / (da * db))))
            return CGFloat(acos(c))
        }

        var candidates: [(frame: Int, score: CGFloat)] = []

        guard points.count > 2 * k + 1 else { return [] }

        for i in k..<(points.count - k) {
            guard let p0 = points[i - k], let p1 = points[i], let p2 = points[i + k] else { continue }

            let pre = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
            let post = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)

            let disp = min(hypot(pre.x, pre.y), hypot(post.x, post.y))
            if disp < minDisp { continue }

            let ang = angleBetween(pre, post)
            let flipY = (pre.y * post.y) < 0 && min(abs(pre.y), abs(post.y)) > 8.0
            let flipX = (pre.x * post.x) < 0 && min(abs(pre.x), abs(post.x)) > 12.0

            var score = ang
            if flipY { score += 25.0 * .pi / 180.0 }
            if flipX { score += 10.0 * .pi / 180.0 }

            if score >= angleTh {
                candidates.append((frame: i, score: score))
            }
        }

        var hits: [(frame: Int, score: CGFloat)] = []
        for cand in candidates {
            if let last = hits.last, cand.frame - last.frame <= minGap {
                if cand.score > last.score {
                    hits[hits.count - 1] = cand
                }
            } else {
                hits.append(cand)
            }
        }

        return hits.map { $0.frame }
    }

    private func detectLandingFramesImageSpace(_ points: [CGPoint?], worldByFrame: [CGPoint?], fps: Double) -> [Int] {
        // Very conservative landing detector:
        // only count it if the shuttle vanishes for a fairly long time OR the clip ends,
        // and the final visible proxy point is on the court.
        let longGap = max(18, Int(round(0.36 * fps)))
        let minMotionBefore: CGFloat = 10.0 * CGFloat(50.0 / max(1.0, fps))
        let maxMotionAtEnd: CGFloat = 4.0 * CGFloat(50.0 / max(1.0, fps))

        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }

        func isCourtPoint(_ p: CGPoint?) -> Bool {
            guard let p else { return false }
            return p.x >= 0 && p.x <= CGFloat(court.W) && p.y >= 0 && p.y <= CGFloat(court.L)
        }

        var landings: [Int] = []
        var i = 1
        while i < points.count {
            if points[i] != nil { i += 1; continue }

            let gapStart = i
            while i < points.count && points[i] == nil { i += 1 }
            let gapLen = i - gapStart

            guard gapLen >= longGap else { continue }

            let cand = gapStart - 1
            guard cand >= 2 else { continue }
            guard let p0 = points[cand - 2], let p1 = points[cand - 1], let p2 = points[cand] else { continue }

            let dPrev = dist(p0, p1)
            let dEnd = dist(p1, p2)

            if dPrev >= minMotionBefore && dEnd <= maxMotionAtEnd && isCourtPoint(worldByFrame[cand]) {
                landings.append(cand)
            }
        }

        if let lastVisible = points.indices.last(where: { points[$0] != nil }),
           lastVisible >= 2,
           let p0 = points[lastVisible - 2],
           let p1 = points[lastVisible - 1],
           let p2 = points[lastVisible],
           isCourtPoint(worldByFrame[lastVisible]) {

            let dPrev = dist(p0, p1)
            let dEnd = dist(p1, p2)
            if dPrev >= minMotionBefore && dEnd <= maxMotionAtEnd {
                landings.append(lastVisible)
            }
        }

        var deduped: [Int] = []
        let minGap = max(20, Int(round(0.40 * fps)))
        for f in landings.sorted() {
            if let last = deduped.last, f - last < minGap { continue }
            deduped.append(f)
        }
        return deduped
    }

    private func nearestValidPoint(in arr: [CGPoint?], around frame: Int, radius: Int = 6) -> (Int, CGPoint)? {
        guard !arr.isEmpty else { return nil }
        let lo = max(0, frame - radius)
        let hi = min(arr.count - 1, frame + radius)

        if frame >= 0, frame < arr.count, let p = arr[frame] {
            return (frame, p)
        }

        for d in 1...radius {
            let a = frame - d
            if a >= lo, a < arr.count, let p = arr[a] { return (a, p) }
            let b = frame + d
            if b <= hi, b >= 0, let p = arr[b] { return (b, p) }
        }
        return nil
    }

    private func estimateFallbackLanding(world: [CGPoint?], after lastHit: Int) -> (Int, CGPoint)? {
        guard !world.isEmpty else { return nil }
        guard let lastVisible = world.indices.last(where: { $0 > lastHit && world[$0] != nil }) else { return nil }

        var valid: [(Int, CGPoint)] = []
        for f in stride(from: lastVisible, through: max(lastHit + 1, lastVisible - 8), by: -1) {
            if let p = world[f] { valid.append((f, p)) }
            if valid.count >= 3 { break }
        }
        guard let newest = valid.first?.1 else { return nil }
        if valid.count >= 2 {
            let p0 = valid[1].1
            let p1 = newest
            let dx = Double(p1.x - p0.x)
            let dy = Double(p1.y - p0.y)
            let gain = 0.35
            let candidate = clampWorldProxy(CGPoint(x: p1.x + CGFloat(dx * gain), y: p1.y + CGFloat(dy * gain)))
            return (lastVisible, candidate)
        }
        return (lastVisible, newest)
    }

    private func collectSegmentSamples(pixel px: [CGPoint?], world: [CGPoint?], start: Int, end: Int) -> (frames: [Int], px: [CGPoint], world: [CGPoint]) {
        guard !px.isEmpty, !world.isEmpty, start <= end else { return ([], [], []) }
        var frames: [Int] = []
        var pixels: [CGPoint] = []
        var worlds: [CGPoint] = []
        let lo = max(0, start)
        let hi = min(min(px.count, world.count) - 1, end)
        guard lo <= hi else { return ([], [], []) }
        for f in lo...hi {
            if let p = px[f], let w = world[f] {
                frames.append(f)
                pixels.append(p)
                worlds.append(w)
            }
        }
        return (frames, pixels, worlds)
    }

    private func buildShotSegmentsFromHits(pixel px: [CGPoint?], world: [CGPoint?], fps: Double, hitFrames: [Int], landingFrames: [Int]) -> [ShotSegment] {
        guard hitFrames.count >= 2 else { return [] }

        var segments: [ShotSegment] = []
        let minSpan = max(8, Int(round(0.16 * fps)))

        for i in 0..<(hitFrames.count - 1) {
            let f0 = hitFrames[i]
            let f1 = hitFrames[i + 1]
            guard f1 - f0 >= minSpan else { continue }

            let startDelay = stabilizationDelayFrames(px, around: f0, fps: fps)
            let endDelay = max(2, stabilizationDelayFrames(px, around: f1, fps: fps) / 2)

            guard let (spxFrame, p0) = stableRepresentativePoint(in: px, around: f0, direction: +1, delay: startDelay, radius: 2),
                  let (epxFrame, p1) = stableRepresentativePoint(in: px, around: f1, direction: -1, delay: endDelay, radius: 2),
                  let (_, w0) = stableRepresentativePoint(in: world, around: f0, direction: +1, delay: startDelay, radius: 2),
                  let (_, w1) = stableRepresentativePoint(in: world, around: f1, direction: -1, delay: endDelay, radius: 2) else { continue }

            let dt = Double(max(1, epxFrame - spxFrame)) / max(1.0, fps)
            let samples = collectSegmentSamples(pixel: px, world: world, start: spxFrame, end: epxFrame)
            guard samples.frames.count >= 5 else { continue }

            segments.append(
                ShotSegment(
                    startFrame: f0,
                    endFrame: f1,
                    startPx: p0,
                    endPx: p1,
                    startWorld: w0,
                    endWorld: w1,
                    durationSec: dt,
                    isLanding: false,
                    analysisStartFrame: spxFrame,
                    analysisEndFrame: epxFrame,
                    sampleFrames: samples.frames,
                    pixelSamples: samples.px,
                    worldSamples: samples.world
                )
            )
        }

        if let lastHit = hitFrames.last {
            let startDelay = stabilizationDelayFrames(px, around: lastHit, fps: fps)
            guard let (spxFrame, p0) = stableRepresentativePoint(in: px, around: lastHit, direction: +1, delay: startDelay, radius: 2),
                  let (_, w0) = stableRepresentativePoint(in: world, around: lastHit, direction: +1, delay: startDelay, radius: 2) else {
                return segments
            }

            if let landing = landingFrames.first(where: { $0 > lastHit + minSpan }),
               let (epxFrame, p1) = representativePoint(in: px, around: landing, radius: 3),
               let (_, w1) = representativePoint(in: world, around: landing, radius: 3) {

                let dt = Double(max(1, epxFrame - spxFrame)) / max(1.0, fps)
                if dt >= 0.10 {
                    let samples = collectSegmentSamples(pixel: px, world: world, start: spxFrame, end: epxFrame)
                    if samples.frames.count >= 4 {
                        segments.append(
                            ShotSegment(
                                startFrame: lastHit,
                                endFrame: landing,
                                startPx: p0,
                                endPx: p1,
                                startWorld: w0,
                                endWorld: w1,
                                durationSec: dt,
                                isLanding: true,
                                analysisStartFrame: spxFrame,
                                analysisEndFrame: epxFrame,
                                sampleFrames: samples.frames,
                                pixelSamples: samples.px,
                                worldSamples: samples.world
                            )
                        )
                    }
                }
            } else if let (landingFrame, landingWorld) = estimateFallbackLanding(world: world, after: lastHit),
                      landingFrame > lastHit + minSpan,
                      let (_, landingPx) = representativePoint(in: px, around: landingFrame, radius: 4) {

                let dt = Double(max(1, landingFrame - spxFrame)) / max(1.0, fps)
                if dt >= 0.10 {
                    let samples = collectSegmentSamples(pixel: px, world: world, start: spxFrame, end: landingFrame)
                    if samples.frames.count >= 4 {
                        segments.append(
                            ShotSegment(
                                startFrame: lastHit,
                                endFrame: landingFrame,
                                startPx: p0,
                                endPx: landingPx,
                                startWorld: w0,
                                endWorld: landingWorld,
                                durationSec: dt,
                                isLanding: true,
                                analysisStartFrame: spxFrame,
                                analysisEndFrame: landingFrame,
                                sampleFrames: samples.frames,
                                pixelSamples: samples.px,
                                worldSamples: samples.world
                            )
                        )
                    }
                }
            }
        }

        return segments
    }

    private func depthBand(forDepthFromNet depth: Double) -> DepthBand {
        if depth < 1.75 { return .front }
        if depth < 4.25 { return .mid }
        return .rear
    }

    private func singleCamNetReferenceGeometry() -> (topL: CGPoint, topR: CGPoint, floorL: CGPoint, floorR: CGPoint)? {
        guard mode == .sixPoints, taps.count >= 6, let H = currentHomography() else { return nil }
        let floorL = H.project(CGPoint(x: 0, y: CGFloat(court.halfL)))
        let floorR = H.project(CGPoint(x: CGFloat(court.W), y: CGFloat(court.halfL)))
        return (taps[4], taps[5], floorL, floorR)
    }

    private func interpolatePoint(_ a: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func pixelPointToViewIfPossible(_ px: CGPoint) -> CGPoint? {
        guard let pxSize = currentPixelSource()?.size else { return nil }
        return pixelPointToView(px, pixelSize: pxSize)
    }

    private func averageNetPixelsPerMeter() -> Double? {
        guard let g = singleCamNetReferenceGeometry() else { return nil }
        let samples: [CGFloat] = [0.15, 0.5, 0.85]
        let vals = samples.compactMap { u -> Double? in
            let top = interpolatePoint(g.topL, g.topR, t: u)
            let floor = interpolatePoint(g.floorL, g.floorR, t: u)
            let px = Double(floor.y - top.y)
            return px > 6.0 ? px / 1.55 : nil
        }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private func approximateShuttleHeightMeters(pixelPoint: CGPoint, worldX: CGFloat?) -> Double? {
        guard let g = singleCamNetReferenceGeometry(), let viewPoint = pixelPointToViewIfPossible(pixelPoint) else { return nil }
        let u: CGFloat
        if let worldX {
            u = min(1, max(0, worldX / CGFloat(court.W)))
        } else {
            let dx = g.floorR.x - g.floorL.x
            if abs(dx) > 1e-3 {
                u = min(1, max(0, (viewPoint.x - g.floorL.x) / dx))
            } else {
                u = 0.5
            }
        }
        let top = interpolatePoint(g.topL, g.topR, t: u)
        let floor = interpolatePoint(g.floorL, g.floorR, t: u)
        let netPixels = Double(floor.y - top.y)
        guard netPixels > 6.0 else { return nil }
        let height = Double(floor.y - viewPoint.y) / netPixels * 1.55
        return max(-0.5, min(8.0, height))
    }

    private func estimateSingleCamNetClearance(pixelSamples: [CGPoint], worldSamples: [CGPoint]) -> Double? {
        guard pixelSamples.count == worldSamples.count, pixelSamples.count >= 2 else { return nil }
        let targetY = CGFloat(court.halfL)
        var clearances: [Double] = []

        for i in 0..<(worldSamples.count - 1) {
            let y0 = worldSamples[i].y
            let y1 = worldSamples[i + 1].y
            let dy = y1 - y0
            if abs(dy) > 1e-5, (y0 - targetY) * (y1 - targetY) <= 0 {
                let t = min(1.0, max(0.0, (targetY - y0) / dy))
                let px = interpolatePoint(pixelSamples[i], pixelSamples[i + 1], t: t)
                let worldX = worldSamples[i].x + (worldSamples[i + 1].x - worldSamples[i].x) * t
                if let h = approximateShuttleHeightMeters(pixelPoint: px, worldX: worldX) {
                    clearances.append(h - 1.55)
                }
            }
        }

        if clearances.isEmpty {
            let nearby = worldSamples.indices.filter { abs(worldSamples[$0].y - targetY) <= 0.85 }
            for idx in nearby {
                if let h = approximateShuttleHeightMeters(pixelPoint: pixelSamples[idx], worldX: worldSamples[idx].x) {
                    clearances.append(h - 1.55)
                }
            }
        }

        guard !clearances.isEmpty else { return nil }
        let sorted = clearances.sorted()
        return sorted[sorted.count / 2]
    }

    private func estimateSingleCamApexHeight(pixelSamples: [CGPoint], worldSamples: [CGPoint], startPx: CGPoint, endPx: CGPoint) -> (absolute: Double?, prominence: Double?) {
        guard pixelSamples.count == worldSamples.count, !pixelSamples.isEmpty else { return (nil, nil) }
        guard let apexIdx = pixelSamples.indices.min(by: { pixelSamples[$0].y < pixelSamples[$1].y }) else { return (nil, nil) }
        let apexPx = pixelSamples[apexIdx]
        let apexAbs = approximateShuttleHeightMeters(pixelPoint: apexPx, worldX: worldSamples[apexIdx].x)
        let startH = approximateShuttleHeightMeters(pixelPoint: startPx, worldX: worldSamples.first?.x)
        let endH = approximateShuttleHeightMeters(pixelPoint: endPx, worldX: worldSamples.last?.x)
        let baseline = max(startH ?? 0.7, endH ?? 0.3, 0.3)
        let promFromHeights = apexAbs.map { max(0.0, $0 - baseline) }
        let risePx = max(0.0, Double(min(startPx.y, endPx.y) - apexPx.y))
        let promFromPixels = averageNetPixelsPerMeter().map { ppm in ppm > 1.0 ? risePx / ppm : nil } ?? nil
        return (apexAbs, promFromHeights ?? promFromPixels)
    }

    private func estimateTimeToPeakRatio(frames: [Int], pixels: [CGPoint]) -> Double? {
        guard frames.count >= 3, frames.count == pixels.count else { return nil }
        guard let apexIdx = pixels.indices.min(by: { pixels[$0].y < pixels[$1].y }) else { return nil }
        let totalFrames = max(1, frames.last! - frames.first!)
        let riseFrames = max(0, frames[apexIdx] - frames.first!)
        return Double(riseFrames) / Double(totalFrames)
    }

    private func endDescentRatePxPerFrame(frames: [Int], pixels: [CGPoint]) -> Double {
        guard frames.count >= 3, frames.count == pixels.count else { return 0 }
        let last = pixels.count - 1
        let first = max(0, last - 3)
        let dy = Double(pixels[last].y - pixels[first].y)
        let dtFrames = max(1, frames[last] - frames[first])
        return dy / Double(dtFrames)
    }

    private func computeSingleCamSegmentFeatures(_ seg: ShotSegment) -> SingleCamSegmentFeatures {
        let halfL = Double(court.halfL)
        let midX = Double(court.W) / 2.0
        let startSigned = Double(seg.startWorld.y) - halfL
        let endSigned = Double(seg.endWorld.y) - halfL
        let startDepth = abs(startSigned)
        let endDepth = abs(endSigned)
        let dx = Double(seg.endWorld.x - seg.startWorld.x)
        let dy = Double(seg.endWorld.y - seg.startWorld.y)
        let crossesNet = seg.worldSamples.contains(where: { Double($0.y) < halfL }) && seg.worldSamples.contains(where: { Double($0.y) > halfL })
        let isCrossCourt = (Double(seg.startWorld.x) - midX) * (Double(seg.endWorld.x) - midX) < 0 && abs(dx) > 0.8
        let apex = estimateSingleCamApexHeight(pixelSamples: seg.pixelSamples, worldSamples: seg.worldSamples, startPx: seg.startPx, endPx: seg.endPx)
        let landingBand = depthBand(forDepthFromNet: endDepth)
        let startH = approximateShuttleHeightMeters(pixelPoint: seg.startPx, worldX: seg.startWorld.x)
        let endH = approximateShuttleHeightMeters(pixelPoint: seg.endPx, worldX: seg.endWorld.x)
        return SingleCamSegmentFeatures(
            startDepthFromNet: startDepth,
            endDepthFromNet: endDepth,
            startSignedLongitudinal: startSigned,
            endSignedLongitudinal: endSigned,
            travelMeters: hypot(dx, dy),
            lateralTravelMeters: abs(dx),
            longitudinalTravelMeters: abs(dy),
            crossesNet: crossesNet,
            isCrossCourt: isCrossCourt,
            apexProminenceMeters: apex.prominence,
            apexAbsoluteHeightMeters: apex.absolute,
            startApproxHeightMeters: startH,
            endApproxHeightMeters: endH,
            netClearanceMeters: estimateSingleCamNetClearance(pixelSamples: seg.pixelSamples, worldSamples: seg.worldSamples),
            timeToPeakRatio: estimateTimeToPeakRatio(frames: seg.sampleFrames, pixels: seg.pixelSamples),
            endDescentPxPerFrame: endDescentRatePxPerFrame(frames: seg.sampleFrames, pixels: seg.pixelSamples),
            validSampleCount: seg.sampleFrames.count,
            durationSec: seg.durationSec,
            landingDepthBand: landingBand,
            startDepthBand: depthBand(forDepthFromNet: startDepth),
            endDepthBand: depthBand(forDepthFromNet: endDepth)
        )
    }

    private func legacyClassifyShotSegment(startPx sPx: CGPoint, endPx ePx: CGPoint, startWorld sW: CGPoint, endWorld eW: CGPoint, durationSec: Double, isLanding: Bool) -> (ShotType, Double) {
        let W = CGFloat(court.W)
        let L = CGFloat(court.L)
        let netY = CGFloat(court.halfL)
        let midX = W / 2.0

        func nearNet(_ y: CGFloat) -> Bool { abs(y - netY) <= 1.10 }
        func deep(_ y: CGFloat) -> Bool { y <= 1.50 || y >= (L - 1.50) }
        func crossCourt(_ a: CGPoint, _ b: CGPoint) -> Bool {
            (a.x - midX) * (b.x - midX) < 0
        }

        let dxWorld = abs(eW.x - sW.x)
        let dyWorld = abs(eW.y - sW.y)
        let travelNorm = hypot(dxWorld, dyWorld) / max(L, 1)
        let dyPxSigned = ePx.y - sPx.y
        let dyPx = abs(dyPxSigned)
        let isCross = crossCourt(sW, eW) && dxWorld >= 1.0
        let shortTime = durationSec <= 0.52
        let longTime = durationSec >= 0.72
        let nearStraight = dxWorld <= 1.1
        let steepDown = dyPxSigned >= 130
        let flatDrive = dyPx <= 110

        if nearNet(eW.y) {
            if isCross { return (.netCross, shortTime ? 0.70 : 0.64) }
            if longTime { return (.dropCut, 0.64) }
            return (.netShot, 0.66)
        }

        if deep(eW.y) && longTime {
            return (.liftClear, max(0.62, min(0.78, 0.64 + 0.12 * travelNorm)))
        }

        if shortTime {
            if steepDown && nearStraight {
                return (.smashKill, 0.64)
            }
            if flatDrive {
                return (.drive, 0.60)
            }
            if travelNorm < 0.26 {
                return (isCross ? .netCross : .netShot, 0.56)
            }
        }

        if durationSec <= 0.70 && travelNorm < 0.45 {
            return (.pushBlock, 0.56)
        }

        if isLanding {
            if deep(eW.y) {
                return (.liftClear, 0.68)
            }
            if steepDown {
                return (.smashKill, 0.58)
            }
        }

        return (.unknown, 0.42)
    }

    private func classifyShotSegment(_ seg: ShotSegment) -> (ShotType, Double) {
        let legacy = legacyClassifyShotSegment(startPx: seg.startPx, endPx: seg.endPx, startWorld: seg.startWorld, endWorld: seg.endWorld, durationSec: seg.durationSec, isLanding: seg.isLanding)
        guard mode == .sixPoints, taps.count >= 6, singleCamNetReferenceGeometry() != nil else {
            return legacy
        }

        let f = computeSingleCamSegmentFeatures(seg)
        guard f.validSampleCount >= 5 else { return legacy }

        var scores: [ShotType: Double] = [:]
        func add(_ type: ShotType, _ amount: Double) { scores[type, default: 0] += amount }

        let netClear = f.netClearanceMeters
        let apexProm = f.apexProminenceMeters ?? 0.9
        let apexAbs = f.apexAbsoluteHeightMeters ?? 2.0
        let shortTime = f.durationSec < 0.58
        let mediumTime = f.durationSec >= 0.58 && f.durationSec < 0.95
        let longTime = f.durationSec >= 0.95
        let startsFront = f.startDepthBand == .front
        let startsRear = f.startDepthBand == .rear
        let endsFront = f.endDepthBand == .front
        let endsRear = f.endDepthBand == .rear
        let startsLow = (f.startApproxHeightMeters ?? 1.1) < 1.55
        let startsHigh = (f.startApproxHeightMeters ?? 1.1) > 1.95
        let endsLow = (f.endApproxHeightMeters ?? 0.6) < 1.25
        let timeToPeak = f.timeToPeakRatio ?? 0.42
        let hasNetCue = netClear != nil
        let lowNet = (netClear ?? 0.35) < 0.18
        let mediumNet = (netClear ?? 0.35) >= 0.18 && (netClear ?? 0.35) < 0.65
        let highNet = (netClear ?? 0.35) >= 0.65

        // carry a small prior from the legacy classifier, so enhanced mode differs but stays sane
        add(legacy.0, max(0.25, legacy.1 - 0.35))

        // Net family
        if endsFront && f.travelMeters < 3.2 {
            add(.netShot, 1.0)
            if startsFront { add(.netShot, 1.2) }
            if lowNet { add(.netShot, 1.4) }
            if f.isCrossCourt || f.lateralTravelMeters > 1.1 {
                add(.netCross, 1.5)
            } else {
                add(.netShot, 0.6)
            }
            if shortTime { add(f.isCrossCourt ? .netCross : .netShot, 0.5) }
        }

        // Rear-court high arc family: clear / lift
        if endsRear || (startsFront && f.crossesNet && longTime) {
            add(.liftClear, 1.3)
            if longTime { add(.liftClear, 1.2) }
            if apexProm > 1.25 { add(.liftClear, 1.0) }
            if apexAbs > 2.7 { add(.liftClear, 0.9) }
            if highNet { add(.liftClear, 1.1) }
            if mediumNet { add(.liftClear, 0.4) }
            if startsFront || startsLow { add(.liftClear, 0.5) }
            if timeToPeak < 0.52 { add(.liftClear, 0.3) }
        }

        // Rear -> front low crossing: drop / cut
        if startsRear && endsFront {
            add(.dropCut, 1.5)
            if lowNet { add(.dropCut, 1.5) }
            if mediumNet { add(.dropCut, 0.7) }
            if apexProm < 1.3 { add(.dropCut, 0.9) }
            if apexAbs < 2.7 { add(.dropCut, 0.5) }
            if mediumTime || shortTime { add(.dropCut, 0.7) }
            if f.endDescentPxPerFrame > 6.5 { add(.dropCut, 0.5) }
        }

        // Flat fast crossing: drive
        if f.crossesNet {
            add(.drive, 0.3)
            if shortTime { add(.drive, 1.0) }
            if lowNet { add(.drive, 1.2) }
            if apexProm < 0.95 { add(.drive, 1.0) }
            if f.travelMeters > 3.0 { add(.drive, 0.6) }
            if f.endDepthBand == .mid || f.startDepthBand == .mid { add(.drive, 0.5) }
        }

        // Steep, fast, low crossing from higher contact: smash / kill
        if f.crossesNet {
            add(.smashKill, 0.2)
            if shortTime { add(.smashKill, 0.9) }
            if startsHigh { add(.smashKill, 1.1) }
            if lowNet { add(.smashKill, 1.0) }
            if f.endDescentPxPerFrame > 8.0 { add(.smashKill, 1.4) }
            if endsLow { add(.smashKill, 0.6) }
            if endsFront || f.endDepthBand == .mid { add(.smashKill, 0.4) }
            if apexProm < 1.0 { add(.smashKill, 0.6) }
        }

        // Controlled middle-depth rally shot: push / block
        if mediumTime {
            add(.pushBlock, 0.7)
            if f.endDepthBand == .mid { add(.pushBlock, 1.1) }
            if mediumNet { add(.pushBlock, 0.8) }
            if f.travelMeters < 4.8 { add(.pushBlock, 0.5) }
            if apexProm < 1.25 { add(.pushBlock, 0.7) }
            if timeToPeak > 0.42 && timeToPeak < 0.68 { add(.pushBlock, 0.3) }
        }

        if seg.isLanding {
            switch f.landingDepthBand {
            case .rear:
                add(.liftClear, 0.7)
            case .front:
                add(.dropCut, 0.6)
                add(.netShot, 0.3)
            case .mid:
                add(.pushBlock, 0.4)
                add(.drive, 0.2)
            }
        }

        if hasNetCue == false {
            return legacy
        }
        guard let best = scores.max(by: { lhs, rhs in lhs.value < rhs.value }) else { return legacy }
        let sorted = scores.values.sorted(by: >)
        let second = sorted.dropFirst().first ?? 0.0
        let margin = max(0.0, best.value - second)
        var confidence = max(0.54, min(0.94, 0.58 + 0.06 * best.value + 0.07 * margin))
        if !hasNetCue { confidence -= 0.10 }
        if best.value < 1.15, legacy.0 != .unknown {
            return (legacy.0, max(legacy.1, confidence - 0.08))
        }
        return (best.key, confidence)
    }
    /// Convert oriented pixel point -> view/container coordinate (matches taps / homography).
    private func pixelPointToView(_ px: CGPoint, pixelSize: CGSize) -> CGPoint? {
        guard containerSize.width > 0, containerSize.height > 0 else { return nil }
        let fit = aspectFitRect(content: pixelSize, in: containerSize)
        guard fit.width > 0, fit.height > 0 else { return nil }
        let u = px.x / pixelSize.width
        let v = px.y / pixelSize.height
        return CGPoint(x: fit.minX + u * fit.width, y: fit.minY + v * fit.height)
    }

    // MARK: - Homography (classic 4-tap)

    private func currentHomography() -> Homography? {
        switch mode {
        case .fourCorners:
            guard taps.count >= 4, isOrderBL_BR_TR_TL(Array(taps.prefix(4))) else { return nil }
            let W = court.W, L = court.L
            let world = [
                CGPoint(x: 0, y: 0),      // BL
                CGPoint(x: W, y: 0),      // BR
                CGPoint(x: W, y: L),      // TR
                CGPoint(x: 0, y: L)       // TL
            ]
            return Homography.estimate(world: world, image: Array(taps.prefix(4)))

        case .sixPoints:
            guard taps.count >= 4, isOrderBL_BR_TR_TL(Array(taps.prefix(4))) else { return nil }
            let world = Array(singleCamWorldPoints2D().prefix(4))
            return Homography.estimate(world: world, image: Array(taps.prefix(4)))

        case .customCorners:
            guard taps.count >= 4, isOrderBL_BR_TR_TL(Array(taps.prefix(4))) else { return nil }
            let world = worldPointsForCustomCorners()
            return Homography.estimate(world: world, image: Array(taps.prefix(4)))
        }
    }

    private func worldPointsForCustomCorners() -> [CGPoint] {
        let W = court.W, L = court.L, xS1 = court.xS1, xS2 = court.xS2
        func xLeft(_ k: CornerKind) -> CGFloat  { k == .inner ? xS1 : 0 }
        func xRight(_ k: CornerKind) -> CGFloat { k == .inner ? xS2 : W }
        let bl = CGPoint(x: xLeft(cornerKind[ .bl] ?? .outer),  y: 0)
        let br = CGPoint(x: xRight(cornerKind[.br] ?? .outer), y: 0)
        let tr = CGPoint(x: xRight(cornerKind[.tr] ?? .outer), y: L)
        let tl = CGPoint(x: xLeft(cornerKind[ .tl] ?? .outer), y: L)
        return [bl, br, tr, tl]
    }

    /// Validate that taps are BL → BR → TR → TL in image space (y-down).
    private func isOrderBL_BR_TR_TL(_ pts: [CGPoint]) -> Bool {
        guard pts.count == 4 else { return false }
        let byYDesc = pts.enumerated().sorted { $0.element.y > $1.element.y }
        let bottom = Array(byYDesc.prefix(2)).sorted { $0.element.x < $1.element.x }
        let top    = Array(byYDesc.suffix(2)).sorted { $0.element.x < $1.element.x }
        let bl = bottom[0].element, br = bottom[1].element
        let tl = top[0].element,    tr = top[1].element
        let tol: CGFloat = 1.0
        func eq(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x-b.x)<tol && abs(a.y-b.y)<tol }
        return eq(pts[0], bl) && eq(pts[1], br) && eq(pts[2], tr) && eq(pts[3], tl)
    }

    // MARK: - Video: loading

    private func autoCalibrate() {
        guard let img = selectedImage ?? videoPreview else { return }
        isDetecting = true
        Task {
            defer { Task { @MainActor in self.isDetecting = false } }
            if let corners = await CourtDetector.detectCourt(in: img) {
                await MainActor.run {
                    let preserveSixPoint = (self.mode == .sixPoints)
                    self.mode = preserveSixPoint ? .sixPoints : .fourCorners
                    self.taps = corners
                    self.orderError = preserveSixPoint ? "Auto set BL/BR/TR/TL. Please tap Net-L and Net-R." : nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } else {
                await MainActor.run {
                    self.orderError = "Could not detect court. Please tap manually."
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func loadVideo(from item: PhotosPickerItem) async {
        do {
            // 1) Import the movie file (MovieFile returns a temporary URL quickly).
            // IMPORTANT: run loadTransferable off the Main Actor to avoid PhotosPicker UI freezes.
            let movie = try await Task.detached(priority: .userInitiated) {
                try await item.loadTransferable(type: MovieFile.self)
            }.value

            guard let movie else {
                await MainActor.run {
                    self.videoLoadError = "Could not import this video (no transferable result)."
                }
                return
            }

            // 1b) Make our own stable copy in app tmp on a background task.
            // This avoids Photos temp files being cleaned up later, and avoids blocking the UI.
            let url = await Task.detached(priority: .userInitiated) { () -> URL in
                let src = movie.url
                let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
                let dst = tmpDir.appendingPathComponent("imported_video_\(UUID().uuidString).\(ext)")
                if FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.removeItem(at: dst)
                }
                do {
                    // Try fast move/rename first.
                    try FileManager.default.moveItem(at: src, to: dst)
                } catch {
                    // Fall back to copy.
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
                return dst
            }.value

            // 2) Generate thumbnail + get display size off the main thread.
            let thumb = await Task.detached(priority: .userInitiated) { () -> (UIImage, CGSize)? in
                return ContentView.firstFrameImage(for: url)
            }.value

            guard let (img, size) = thumb else {
                await MainActor.run {
                    self.videoLoadError = "Imported video, but failed to generate a preview frame."
                }
                return
            }

            // 3) Update UI state on MainActor.
            await MainActor.run {
                self.videoURL = url
                self.workspaceVisible = true
            self.videoPreview = img
                self.videoFrameSize = size
                self.selectedImage = nil
                self.clearCalibration()
                self.configurePlayer(with: url)
                self.contentKey = UUID()
            }
        } catch {
            await MainActor.run {
                self.videoLoadError = "Video import failed: \(error.localizedDescription)"
            }
        }
    }

    /// Import a picked video URL (already copied into app temp by `VideoPicker`).
    /// This runs thumbnail generation off the main thread, then updates UI state.
    private func importPickedVideo(url: URL) async {
        // Make an additional stable copy so we can safely overwrite/clear and avoid collisions.
        let stableURL = await Task.detached(priority: .userInitiated) { () -> URL in
            let src = url
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
            let dst = tmpDir.appendingPathComponent("imported_video_\(UUID().uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.removeItem(at: dst)
            }
            do {
                // Try fast move/rename first.
                try FileManager.default.moveItem(at: src, to: dst)
            } catch {
                // Fall back to copy.
                try? FileManager.default.copyItem(at: src, to: dst)
            }
            return dst
        }.value

        let thumb = await Task.detached(priority: .userInitiated) { () -> (UIImage, CGSize)? in
            return ContentView.firstFrameImage(for: stableURL)
        }.value

        guard let (img, size) = thumb else {
            await MainActor.run {
                self.videoLoadError = "Imported video, but failed to generate a preview frame."
            }
            return
        }

        // Capture video geometry (natural size + preferred transform)
        let info = await Task.detached(priority: .userInitiated) { () -> (CGSize?, CGAffineTransform, CGRect) in
            let asset = AVAsset(url: stableURL)
            if let track = asset.tracks(withMediaType: .video).first {
                let natural = track.naturalSize
                let t = track.preferredTransform
                let rect = CGRect(origin: .zero, size: natural).applying(t).standardized
                return (natural, t, rect)
            }
            return (nil, .identity, .zero)
        }.value

        await MainActor.run {
            self.videoURL = stableURL
            self.workspaceVisible = true
            self.videoPreview = img
            self.videoFrameSize = size
            self.videoRawSize = info.0
            self.videoPreferredTransform = info.1
            self.videoOrientedRect = info.2
            self.selectedImage = nil
            self.clearCalibration()
            self.configurePlayer(with: stableURL)
            self.contentKey = UUID()
        }
    }

    private nonisolated static func videoFPS(url: URL) -> Double? {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let fps = Double(track.nominalFrameRate)
        return fps > 0 ? fps : nil
    }

    private nonisolated static func firstFrameImage(for url: URL) -> (UIImage, CGSize)? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.0, preferredTimescale: 600)
        do {
            let cg = try gen.copyCGImage(at: time, actualTime: nil)
            let img = UIImage(cgImage: cg)
            // Determine display size (respecting transform)
            let size: CGSize
            if let track = asset.tracks(withMediaType: .video).first {
                let nat = track.naturalSize.applying(track.preferredTransform)
                size = CGSize(width: abs(nat.width), height: abs(nat.height))
            } else {
                size = img.size
            }
            return (img, size)
        } catch {
            return nil
        }
    }

// MARK: - UI Pieces

private struct TrajectoryOverlay: View {
    let pointsPx: [CGPoint?]          // oriented pixel coords, indexed by frame
    let pixelSize: CGSize             // oriented pixel size
    let containerSize: CGSize         // view size
    let maxPoints: Int

    private func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        let origin = CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    private func pxToView(_ p: CGPoint, pixelSize: CGSize, in container: CGSize) -> CGPoint {
        let fit = aspectFitRect(content: pixelSize, in: container)
        let u = p.x / pixelSize.width
        let v = p.y / pixelSize.height
        return CGPoint(x: fit.minX + u * fit.width, y: fit.minY + v * fit.height)
    }

    var body: some View {
        Canvas { ctx, _ in
            guard pixelSize.width > 0, pixelSize.height > 0 else { return }
            guard !pointsPx.isEmpty else { return }

            // Downsample if extremely dense
            let strideN = max(1, pointsPx.count / max(1, maxPoints))

            var path = Path()
            var didMove = false
            var lastViewPoint: CGPoint? = nil

            for i in stride(from: 0, to: pointsPx.count, by: strideN) {
                guard let p = pointsPx[i] else {
                    didMove = false
                    continue
                }
                let v = pxToView(p, pixelSize: pixelSize, in: containerSize)
                if !didMove {
                    path.move(to: v)
                    didMove = true
                } else {
                    path.addLine(to: v)
                }
                lastViewPoint = v
            }

            ctx.stroke(path, with: .color(.cyan.opacity(0.8)), lineWidth: 2)

            // Current/last point marker
            if let p = lastViewPoint {
                let r: CGFloat = 5
                let rect = CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r)
                ctx.fill(Path(ellipseIn: rect), with: .color(.red.opacity(0.9)))
            }
        }
        .allowsHitTesting(false)
    }
}


private struct LiveTrajectoryOverlay: View {
    let pointsPx: [CGPoint?]
    let pixelSize: CGSize
    let containerSize: CGSize
    let currentFrame: Int
    let tailLength: Int
    let hitFrames: Set<Int>

    private func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        let origin = CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    private func pxToView(_ p: CGPoint, pixelSize: CGSize, in container: CGSize) -> CGPoint {
        let fit = aspectFitRect(content: pixelSize, in: container)
        let u = p.x / pixelSize.width
        let v = p.y / pixelSize.height
        return CGPoint(x: fit.minX + u * fit.width, y: fit.minY + v * fit.height)
    }

    var body: some View {
        Canvas { ctx, _ in
            guard pixelSize.width > 0, pixelSize.height > 0, !pointsPx.isEmpty else { return }
            let start = max(0, currentFrame - tailLength)
            let end = min(max(0, pointsPx.count - 1), currentFrame)
            guard end >= start else { return }

            var path = Path()
            var moved = false
            var currentViewPoint: CGPoint? = nil

            for frame in start...end {
                guard let p = pointsPx[frame] else {
                    moved = false
                    continue
                }
                let v = pxToView(p, pixelSize: pixelSize, in: containerSize)
                let age = CGFloat(end - frame)
                let alpha = max(0.12, 1.0 - (age / CGFloat(max(tailLength, 1))))

                let dotRadius: CGFloat = frame == end ? 5.5 : 3.0
                let dotRect = CGRect(x: v.x - dotRadius, y: v.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                ctx.fill(Path(ellipseIn: dotRect), with: .color((frame == end ? Color.red : Color.cyan).opacity(alpha)))

                if !moved {
                    path.move(to: v)
                    moved = true
                } else {
                    path.addLine(to: v)
                }

                if hitFrames.contains(frame) {
                    let hitRect = CGRect(x: v.x - 14, y: v.y - 14, width: 28, height: 28)
                    ctx.stroke(Path(ellipseIn: hitRect), with: .color(.yellow.opacity(0.95)), lineWidth: 3)
                }

                currentViewPoint = v
            }

            ctx.stroke(path, with: .color(.cyan.opacity(0.88)), lineWidth: 2.4)

            if let v = currentViewPoint, hitFrames.contains(currentFrame) {
                let pulse = CGRect(x: v.x - 20, y: v.y - 20, width: 40, height: 40)
                ctx.stroke(Path(ellipseIn: pulse), with: .color(.orange.opacity(0.85)), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var poster: UIImage? = nil

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspect
        view.display(player, poster: poster)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.display(player, poster: poster)
    }
}

private final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var posterView: UIImageView?
    private var readiness: NSKeyValueObservation?

    func display(_ player: AVPlayer, poster: UIImage?) {
        if playerLayer.player !== player { playerLayer.player = player }
        guard let poster else {
            readiness = nil
            posterView?.removeFromSuperview()
            posterView = nil
            return
        }
        if posterView == nil {
            let imageView = UIImageView(frame: bounds)
            imageView.contentMode = .scaleAspectFit
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.isUserInteractionEnabled = false
            addSubview(imageView)
            posterView = imageView
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.posterView?.isHidden = self.playerLayer.isReadyForDisplay
                }
            }
        }
        if posterView?.image !== poster { posterView?.image = poster }
        posterView?.isHidden = playerLayer.isReadyForDisplay
    }
}

private struct LandingMarkersOverlay: View {
    let points: [CGPoint] // in view/container coordinates

    var body: some View {
        ForEach(Array(points.enumerated()), id: \.offset) { _, p in
            ZStack {
                Circle().fill(Color.orange.opacity(0.9)).frame(width: 12, height: 12)
                    .position(p)
                Circle().stroke(Color.black.opacity(0.75), lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .position(p)
            }
            .allowsHitTesting(false)
        }
    }
}
private struct TopToolbar: View {
    var onBack: () -> Void
    var onReset: () -> Void
    var onUndo: () -> Void
    var onPickPhoto: (PhotosPickerItem?) -> Void
    var onClearPhoto: () -> Void
    var onAutoCalibrate: () -> Void
    var onOpenTutorial: () -> Void
    var hasPhoto: Bool
    var isDetecting: Bool
    var orderError: String?
    var isCalibrated: Bool
    var mode: CalibMode
    var useManyAnchors: Bool
    var currentAnchorLabel: String?
    var probeInfo: (text: String, color: Color)?
    var onOpenMultiCam: () -> Void

    @State private var pickItem: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    toolbarButton(title: "Back", systemImage: "chevron.left", style: .secondary, action: onBack)
                    toolbarButton(title: "Reset", systemImage: "arrow.counterclockwise", style: .accent, action: onReset)
                    toolbarButton(title: "Undo", systemImage: "arrow.uturn.backward", style: .secondary, action: onUndo)

                    if !isCalibrated && hasPhoto {
                        if isDetecting {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Auto")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white.opacity(0.90))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Color.purple.opacity(0.88), in: Capsule())
                        } else {
                            toolbarButton(title: "Auto", systemImage: "wand.and.stars", style: .purple, action: onAutoCalibrate)
                        }
                    }

                    PhotosPicker(selection: $pickItem, matching: .images) {
                        toolbarIconButton(systemImage: "photo.on.rectangle")
                    }
                    .onChange(of: pickItem) { _, newValue in onPickPhoto(newValue) }

                    Button(action: onOpenMultiCam) {
                        toolbarIconButton(systemImage: "camera")
                    }
                    .buttonStyle(.plain)

                    Button(action: onOpenTutorial) {
                        toolbarIconButton(systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)

                    if hasPhoto {
                        Button(role: .destructive, action: onClearPhoto) {
                            toolbarIconButton(systemImage: "trash", destructive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            let statusText: String = {
                if let probeInfo { return probeInfo.text }
                if let orderError { return "⚠️ \(orderError)" }
                return hintText()
            }()
            let statusStroke: Color = {
                if let probeInfo { return probeInfo.color.opacity(0.88) }
                if orderError != nil { return .orange.opacity(0.90) }
                return .white.opacity(0.08)
            }()

            if hasPhoto || probeInfo != nil || orderError != nil {
                Text(statusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.52), in: Capsule())
                    .overlay(Capsule().stroke(statusStroke, lineWidth: 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .padding(.horizontal, 16)
            }
        }
    }

    private enum ToolbarPillStyle {
        case accent
        case secondary
        case purple
    }

    @ViewBuilder
    private func toolbarButton(title: String, systemImage: String, style: ToolbarPillStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(style == .secondary ? .white.opacity(0.90) : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(background(for: style), in: Capsule())
            .overlay(Capsule().stroke(border(for: style), lineWidth: style == .secondary ? 1 : 0))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toolbarIconButton(systemImage: String, destructive: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(destructive ? Color.red.opacity(0.92) : Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.96))
            .frame(width: 50, height: 42)
            .background(Color.black.opacity(0.52), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func background(for style: ToolbarPillStyle) -> Color {
        switch style {
        case .accent: return Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.96)
        case .purple: return Color.purple.opacity(0.92)
        case .secondary: return Color.black.opacity(0.52)
        }
    }

    private func border(for style: ToolbarPillStyle) -> Color {
        switch style {
        case .secondary: return Color.white.opacity(0.10)
        case .accent, .purple: return .clear
        }
    }

    private func hintText() -> String {
        if isCalibrated { return "Calibrated: court overlay on" }
        switch mode {
        case .fourCorners:
            return "Tap 4 OUTER corners in order: ① BL → ② BR → ③ TR → ④ TL"
        case .sixPoints:
            return "Recommended: ① BL → ② BR → ③ TR → ④ TL → ⑤ Net-L → ⑥ Net-R"
        case .customCorners:
            if useManyAnchors {
                let sel = currentAnchorLabel ?? "?"
                return "Many-Anchors: Now \(sel). Tap points (4+), then Solve."
            }
            return "4-Tap Mode: Tap 4 corners in order: ① BL → ② BR → ③ TR → ④ TL"
        }
    }
}

private struct ModeBar: View {
    @Binding var mode: CalibMode
    @Binding var cornerKind: [CornerPos: CornerKind]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                modeChip(title: CalibMode.sixPoints.rawValue, target: .sixPoints)
                modeChip(title: CalibMode.fourCorners.rawValue, target: .fourCorners)
                modeChip(title: CalibMode.customCorners.rawValue, target: .customCorners)
            }

            if mode == .customCorners {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CornerChipMenu(pos: .bl, selection: binding(for: .bl))
                        CornerChipMenu(pos: .br, selection: binding(for: .br))
                        CornerChipMenu(pos: .tr, selection: binding(for: .tr))
                        CornerChipMenu(pos: .tl, selection: binding(for: .tl))
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func modeChip(title: String, target: CalibMode) -> some View {
        let selected = mode == target
        return Button {
            mode = target
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.76))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(selected ? Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.95) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(selected ? Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.98) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func binding(for pos: CornerPos) -> Binding<CornerKind> {
        Binding(
            get: { cornerKind[pos] ?? .outer },
            set: { cornerKind[pos] = $0 }
        )
    }
}

private struct CornerChipMenu: View {
    let pos: CornerPos
    @Binding var selection: CornerKind

    private let chipWidth: CGFloat = 77
    private var shortValue: String { selection == .outer ? "Out" : "In" }

    var body: some View {
        Menu {
            Picker("Corner \(pos.title)", selection: $selection) {
                Text("Outer").tag(CornerKind.outer)
                Text("Inner").tag(CornerKind.inner)
            }
        } label: {
            HStack(spacing: 4) {
                Text(pos.title).font(.caption2).bold().monospaced()
                Text("· \(shortValue)").font(.caption2).monospaced()
            }
            .frame(width: chipWidth)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

private struct ToggleChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isOn ? Color.green.opacity(0.16) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(
                Capsule().stroke(isOn ? Color.green.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AnalysisShotCard: View {
    let index: Int
    let event: ContentView.ShotEvent
    let isSelected: Bool
    let landingStatusText: String?
    let pointSummaryText: String
    let landingOffsetText: String?

    private var accent: Color {
        switch event.type {
        case .smashKill: return .red
        case .liftClear: return .blue
        case .netShot, .netCross: return .green
        case .drive, .pushBlock: return .orange
        case .dropCut: return .purple
        case .unknown: return .gray
        }
    }

    private var statusColor: Color {
        switch landingStatusText {
        case "IN": return .green
        case "LINE": return .yellow
        case "OUT": return .red
        default: return accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shot \(index)")
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                Spacer(minLength: 8)
                if event.isLanding {
                    Text("LAND")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                }
            }
            Text(event.type.displayLabel)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("F\(event.startFrame) → F\(event.endFrame)")
                .font(.caption2)
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            if let landingStatusText {
                HStack(spacing: 6) {
                    Text(landingStatusText)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(isSelected ? 0.28 : 0.18), in: Capsule())
                    Text(pointSummaryText)
                        .font(.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                if let landingOffsetText {
                    Text(landingOffsetText)
                        .font(.caption2)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(2)
                }
            } else {
                Text(pointSummaryText)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? accent.opacity(0.95) : Color(uiColor: .secondarySystemBackground).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.white.opacity(0.95) : accent.opacity(0.55), lineWidth: isSelected ? 2 : 1)
        )
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isSelected)
    }
}

struct OverlayControlsBar: View {
    @Binding var showSingles: Bool
    @Binding var showNet: Bool
    @Binding var showService: Bool

    var body: some View {
        HStack(spacing: 10) {
            overlayChip(title: "Singles", isOn: $showSingles)
            overlayChip(title: "Net", isOn: $showNet)
            overlayChip(title: "Service Lines", isOn: $showService)
        }
    }

    private func overlayChip(title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn.wrappedValue ? .white : .white.opacity(0.74))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule()
                        .fill(isOn.wrappedValue ? Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.92) : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(isOn.wrappedValue ? Color(red: 0.76, green: 0.31, blue: 0.02).opacity(0.98) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}



// MARK: - Share Sheet
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No-op
    }
}

private enum MultiCamResolutionOption: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"

    var id: String { rawValue }
    var label: String { rawValue }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720: return .hd1280x720
        case .hd1080: return .hd1920x1080
        }
    }
    var targetDimensions: CMVideoDimensions {
        switch self {
        case .hd720: return CMVideoDimensions(width: 1280, height: 720)
        case .hd1080: return CMVideoDimensions(width: 1920, height: 1080)
        }
    }
}

private enum MultiCamFPSOption: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }
}

private struct MultiCamRecorderScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = MultiCamRecorderModel()
    @State private var showQualitySheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                if recorder.isSupported {
                    MultiCamPreviewHost(recorder: recorder)
                        .overlay(alignment: .top) {
                            topOverlay
                        }
                        .overlay(alignment: .bottom) {
                            bottomOverlay
                        }
                } else {
                    unsupportedView
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showQualitySheet) {
            qualitySheet
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .task {
            recorder.prepare()
        }
        .onDisappear {
            recorder.shutdown()
        }
        .onChange(of: recorder.selectedResolution) { _ in
            recorder.reconfigureVideoSettings()
        }
        .onChange(of: recorder.selectedFPS) { _ in
            recorder.reconfigureVideoSettings()
        }
    }

    private var topOverlay: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }
            .disabled(recorder.isRecording)

            VStack(alignment: .leading, spacing: 6) {
                Text("Dual Camera Capture")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
                Text("\(recorder.primaryTitle) + \(recorder.secondaryTitle)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                if recorder.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(recorder.recordingDurationText)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.45), in: Capsule())
                }
            }

            Spacer(minLength: 0)

            Button {
                showQualitySheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("\(recorder.selectedResolution.label) · \(recorder.selectedFPS.rawValue)FPS")
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.45), in: Capsule())
            }
            .disabled(recorder.isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var bottomOverlay: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(recorder.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                if let errorText = recorder.errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.95))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {

                Button {
                    recorder.toggleRecording()
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : Color("BrandAccent"))
                .disabled(!recorder.isConfigured)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.18), Color.black.opacity(0.70)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var unsupportedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("Dual camera not supported")
                .font(.headline)
            Text("This iPhone or iPad can't run AVCaptureMultiCamSession. Use a supported device to record two views at the same time.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Back") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding(24)
    }

    private var qualitySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resolution")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Picker("Resolution", selection: $recorder.selectedResolution) {
                        ForEach(MultiCamResolutionOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(recorder.isRecording)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("FPS")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Picker("FPS", selection: $recorder.selectedFPS) {
                        ForEach(MultiCamFPSOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(recorder.isRecording)
                }


                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Recording Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") {
                        showQualitySheet = false
                    }
                }
            }
        }
    }
}

private struct MultiCamPreviewHost: UIViewRepresentable {
    @ObservedObject var recorder: MultiCamRecorderModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        recorder.attachPreviewLayers(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        recorder.attachPreviewLayers(to: uiView)
        recorder.layoutPreviewLayers(in: uiView.bounds)
    }
}

private final class MultiCamRecorderModel: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var isSupported: Bool = AVCaptureMultiCamSession.isMultiCamSupported
    @Published var isConfigured = false
    @Published var isRecording = false
    @Published var statusText = "Checking permissions…"
    @Published var errorText: String? = nil
    @Published var primaryTitle = "Camera A"
    @Published var secondaryTitle = "Camera B"
    @Published var selectedResolution: MultiCamResolutionOption = .hd1080
    @Published var selectedFPS: MultiCamFPSOption = .fps60
    @Published var recordingDuration: TimeInterval = 0

    let session = AVCaptureMultiCamSession()
    let primaryPreviewLayer: AVCaptureVideoPreviewLayer
    let secondaryPreviewLayer: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "dualcam.session.queue")
    private var primaryMovieOutput = AVCaptureMovieFileOutput()
    private var secondaryMovieOutput = AVCaptureMovieFileOutput()
    private var outputURLs: [URL] = []
    private var finishedOutputCount = 0
    private var isPrepared = false
    private var configuredDevices: [AVCaptureDevice] = []
    private var activeVideoConnections: [AVCaptureConnection] = []
    private var recordingStartedAt: Date? = nil
    private var recordingTimer: Timer? = nil

    override init() {
        primaryPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        secondaryPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        primaryPreviewLayer.videoGravity = .resizeAspectFill
        secondaryPreviewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true

        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async {
                self.isSupported = false
                self.statusText = "This device doesn't support simultaneous multi-camera capture."
            }
            return
        }

        requestPermissions { granted in
            guard granted else { return }
            self.configureSession()
        }
    }

    func shutdown() {
        stopRecordingTimer(reset: true)
        sessionQueue.async {
            if self.primaryMovieOutput.isRecording { self.primaryMovieOutput.stopRecording() }
            if self.secondaryMovieOutput.isRecording { self.secondaryMovieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func attachPreviewLayers(to view: UIView) {
        if primaryPreviewLayer.superlayer !== view.layer {
            view.layer.addSublayer(primaryPreviewLayer)
        }
        if secondaryPreviewLayer.superlayer !== view.layer {
            view.layer.addSublayer(secondaryPreviewLayer)
        }
        layoutPreviewLayers(in: view.bounds)
    }

    func layoutPreviewLayers(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        primaryPreviewLayer.frame = bounds

        let pipWidth = max(150, bounds.width * 0.34)
        let pipHeight = pipWidth * 16.0 / 9.0
        let topInset: CGFloat = 68
        let pipFrame = CGRect(
            x: bounds.maxX - pipWidth - 14,
            y: topInset,
            width: pipWidth,
            height: min(pipHeight, bounds.height * 0.28)
        )
        secondaryPreviewLayer.frame = pipFrame
        secondaryPreviewLayer.cornerRadius = 16
        secondaryPreviewLayer.masksToBounds = true
        secondaryPreviewLayer.borderColor = UIColor.white.withAlphaComponent(0.65).cgColor
        secondaryPreviewLayer.borderWidth = 1.0
        CATransaction.commit()
    }

    private func setNativeZoomIfPossible(on device: AVCaptureDevice?) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(1.0, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            print("Failed to set native zoom on \(device.localizedName): \(error)")
        }
    }

    private func normalizeZoomForActiveDevices(_ devices: [AVCaptureDevice?]) {
        var seen = Set<String>()
        for device in devices.compactMap({ $0 }) {
            guard seen.insert(device.uniqueID).inserted else { continue }
            setNativeZoomIfPossible(on: device)
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    var recordingDurationText: String {
        let totalSeconds = max(0, Int(recordingDuration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func reconfigureVideoSettings() {
        sessionQueue.async {
            guard self.isPrepared else { return }
            guard !self.isRecording else { return }
            self.session.beginConfiguration()
            self.applyCurrentSessionPreset()
            self.applySelectedVideoSettingsLocked()
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                if self.isConfigured {
                    self.statusText = "Ready · \(self.primaryTitle) + \(self.secondaryTitle) · \(self.selectedResolution.label) \(self.selectedFPS.rawValue) FPS"
                }
            }
        }
    }

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        var videoGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        var photoGranted = PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized

        if !videoGranted {
            group.enter()
            AVCaptureDevice.requestAccess(for: .video) { granted in
                videoGranted = granted
                group.leave()
            }
        }

        if !photoGranted {
            group.enter()
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                photoGranted = (status == .authorized || status == .limited)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if videoGranted && photoGranted {
                self.statusText = "Preparing dual-camera session…"
                completion(true)
            } else {
                self.errorText = "Please allow Camera and Add to Photos access in Settings."
                self.statusText = "Permissions are required before recording."
                completion(false)
            }
        }
    }

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.activeVideoConnections.removeAll()
            self.configuredDevices.removeAll()
            self.applyCurrentSessionPreset()

            var configured = false
            if self.buildVirtualBackStereo(virtualType: .builtInDualWideCamera, secondaryType: .builtInUltraWideCamera, secondaryName: "Ultra Wide") {
                configured = true
            } else if self.buildVirtualBackStereo(virtualType: .builtInDualCamera, secondaryType: .builtInTelephotoCamera, secondaryName: "Telephoto") {
                configured = true
            } else if self.buildVirtualBackStereo(virtualType: .builtInTripleCamera, secondaryType: .builtInUltraWideCamera, secondaryName: "Ultra Wide") {
                configured = true
            } else if self.buildFrontBackFallback() {
                configured = true
            }

            self.applySelectedVideoSettingsLocked()
            self.session.commitConfiguration()

            guard configured else {
                DispatchQueue.main.async {
                    self.errorText = "Couldn't configure two simultaneous cameras on this device."
                    self.statusText = "Dual-camera setup failed."
                    self.isConfigured = false
                }
                return
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                self.errorText = nil
                self.isConfigured = true
                self.statusText = "Ready · \(self.primaryTitle) + \(self.secondaryTitle) · \(self.selectedResolution.label) \(self.selectedFPS.rawValue) FPS"
            }
        }
    }

    private func applyCurrentSessionPreset() {
        if session.canSetSessionPreset(selectedResolution.preset) {
            session.sessionPreset = selectedResolution.preset
        }
    }

    private func buildVirtualBackStereo(virtualType: AVCaptureDevice.DeviceType,
                                        secondaryType: AVCaptureDevice.DeviceType,
                                        secondaryName: String) -> Bool {
        guard let virtualDevice = AVCaptureDevice.default(virtualType, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: virtualDevice),
              session.canAddInput(input) else {
            return false
        }

        session.addInputWithNoConnections(input)

        let wideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let auxDevice = AVCaptureDevice.default(secondaryType, for: .video, position: .back)
        normalizeZoomForActiveDevices([virtualDevice, wideDevice, auxDevice])

        let primaryPort = input.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first
        let secondaryPort = input.ports(for: .video, sourceDeviceType: secondaryType, sourceDevicePosition: .back).first

        guard let primaryPort, let secondaryPort else {
            session.removeInput(input)
            return false
        }

        guard attachOutputs(primaryPort: primaryPort, secondaryPort: secondaryPort) else {
            session.removeInput(input)
            return false
        }

        configuredDevices = uniqueDevices([virtualDevice, wideDevice, auxDevice])

        DispatchQueue.main.async {
            self.primaryTitle = "Wide"
            self.secondaryTitle = secondaryName
        }
        return true
    }

    private func buildFrontBackFallback() -> Bool {
        let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let frontDevice = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)

        guard let backDevice, let frontDevice,
              let backInput = try? AVCaptureDeviceInput(device: backDevice),
              let frontInput = try? AVCaptureDeviceInput(device: frontDevice),
              session.canAddInput(backInput), session.canAddInput(frontInput) else {
            return false
        }

        session.addInputWithNoConnections(backInput)
        session.addInputWithNoConnections(frontInput)

        normalizeZoomForActiveDevices([backDevice, frontDevice])

        guard let backPort = backInput.ports.first(where: { $0.mediaType == .video }),
              let frontPort = frontInput.ports.first(where: { $0.mediaType == .video }) else {
            session.removeInput(backInput)
            session.removeInput(frontInput)
            return false
        }

        guard attachOutputs(primaryPort: backPort, secondaryPort: frontPort) else {
            session.removeInput(backInput)
            session.removeInput(frontInput)
            return false
        }

        configuredDevices = uniqueDevices([backDevice, frontDevice])

        DispatchQueue.main.async {
            self.primaryTitle = "Back"
            self.secondaryTitle = "Front"
        }
        return true
    }

    private func uniqueDevices(_ devices: [AVCaptureDevice?]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        var out: [AVCaptureDevice] = []
        for device in devices.compactMap({ $0 }) {
            if seen.insert(device.uniqueID).inserted {
                out.append(device)
            }
        }
        return out
    }

    private func attachOutputs(primaryPort: AVCaptureInput.Port, secondaryPort: AVCaptureInput.Port) -> Bool {
        let primaryOut = AVCaptureMovieFileOutput()
        let secondaryOut = AVCaptureMovieFileOutput()

        guard session.canAddOutput(primaryOut), session.canAddOutput(secondaryOut) else {
            return false
        }
        session.addOutputWithNoConnections(primaryOut)
        session.addOutputWithNoConnections(secondaryOut)

        let primaryMovieConnection = AVCaptureConnection(inputPorts: [primaryPort], output: primaryOut)
        let secondaryMovieConnection = AVCaptureConnection(inputPorts: [secondaryPort], output: secondaryOut)
        let primaryPreviewConnection = AVCaptureConnection(inputPort: primaryPort, videoPreviewLayer: primaryPreviewLayer)
        let secondaryPreviewConnection = AVCaptureConnection(inputPort: secondaryPort, videoPreviewLayer: secondaryPreviewLayer)

        let newConnections = [primaryMovieConnection, secondaryMovieConnection, primaryPreviewConnection, secondaryPreviewConnection]
        for connection in newConnections {
            guard session.canAddConnection(connection) else {
                session.removeOutput(primaryOut)
                session.removeOutput(secondaryOut)
                return false
            }
            session.addConnection(connection)

            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported, connection === secondaryPreviewConnection, secondaryPort.sourceDevicePosition == .front {
                connection.isVideoMirrored = true
            }
        }

        primaryMovieOutput = primaryOut
        secondaryMovieOutput = secondaryOut
        activeVideoConnections = newConnections
        return true
    }

    private func applySelectedVideoSettingsLocked() {
        let target = selectedResolution.targetDimensions
        let fps = selectedFPS.rawValue

        // On iOS, frame duration should be configured on AVCaptureDevice after
        // selecting a compatible activeFormat. AVCaptureConnection's min/max
        // frame-duration APIs are unavailable here.
        for device in configuredDevices {
            applyBestFormat(to: device, target: target, fps: fps)
        }
    }

    private func applyBestFormat(to device: AVCaptureDevice, target: CMVideoDimensions, fps: Int) {
        let supported = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let rangeOK = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= Double(fps) && range.maxFrameRate >= Double(fps)
            }
            return rangeOK && dims.width > 0 && dims.height > 0
        }

        let candidates = supported.isEmpty ? device.formats : supported
        let best = candidates.min { lhs, rhs in
            formatScore(lhs, target: target, fps: fps) < formatScore(rhs, target: target, fps: fps)
        }

        guard let best else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            let clamped = max(device.minAvailableVideoZoomFactor, min(1.0, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            print("Failed to configure \(device.localizedName): \(error)")
        }
    }

    private func formatScore(_ format: AVCaptureDevice.Format, target: CMVideoDimensions, fps: Int) -> Int64 {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let area = Int64(dims.width) * Int64(dims.height)
        let targetArea = Int64(target.width) * Int64(target.height)
        let areaPenalty = abs(area - targetArea)
        let widthPenalty = Int64(abs(Int(dims.width - target.width)))
        let heightPenalty = Int64(abs(Int(dims.height - target.height)))
        let undershootPenalty: Int64 = (dims.width < target.width || dims.height < target.height) ? 5_000_000 : 0
        let fpsPenalty: Int64 = format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) ? 0 : 20_000_000
        return areaPenalty + widthPenalty * 4 + heightPenalty * 4 + undershootPenalty + fpsPenalty
    }

    private func startRecording() {
        sessionQueue.async {
            guard self.isConfigured, !self.primaryMovieOutput.isRecording, !self.secondaryMovieOutput.isRecording else { return }

            let primaryURL = Self.makeTempMovieURL(name: "dualcam_primary")
            let secondaryURL = Self.makeTempMovieURL(name: "dualcam_secondary")
            try? FileManager.default.removeItem(at: primaryURL)
            try? FileManager.default.removeItem(at: secondaryURL)

            self.outputURLs = []
            self.finishedOutputCount = 0
            self.primaryMovieOutput.startRecording(to: primaryURL, recordingDelegate: self)
            self.secondaryMovieOutput.startRecording(to: secondaryURL, recordingDelegate: self)

            DispatchQueue.main.async {
                self.errorText = nil
                self.isRecording = true
                self.recordingDuration = 0
                self.startRecordingTimer()
                self.statusText = "Recording at \(self.selectedResolution.label) \(self.selectedFPS.rawValue) FPS…"
            }
        }
    }

    private func stopRecording() {
        sessionQueue.async {
            if self.primaryMovieOutput.isRecording { self.primaryMovieOutput.stopRecording() }
            if self.secondaryMovieOutput.isRecording { self.secondaryMovieOutput.stopRecording() }
            DispatchQueue.main.async {
                self.stopRecordingTimer(reset: false)
                self.statusText = "Finishing and saving 2 clips…"
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.stopRecordingTimer(reset: true)
                self.errorText = error.localizedDescription
                self.statusText = "Recording finished with an error."
                self.isRecording = false
            }
            return
        }

        sessionQueue.async {
            self.outputURLs.append(outputFileURL)
            self.finishedOutputCount += 1
            guard self.finishedOutputCount >= 2 else { return }
            let urls = self.outputURLs
            self.outputURLs.removeAll()
            self.saveToPhotos(urls)
        }
    }

    private func saveToPhotos(_ urls: [URL]) {
        let group = DispatchGroup()
        var saveError: String? = nil

        for url in urls {
            group.enter()
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if !success, let error {
                    saveError = error.localizedDescription
                }
                try? FileManager.default.removeItem(at: url)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.stopRecordingTimer(reset: true)
            self.isRecording = false
            if let saveError {
                self.errorText = saveError
                self.statusText = "The clips were recorded, but saving to Photos failed."
            } else {
                self.errorText = nil
                self.statusText = "Saved 2 clips to Photos."
            }
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingStartedAt = Date()
        updateRecordingDuration()

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateRecordingDuration()
        }
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingTimer(reset: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        if reset {
            recordingDuration = 0
        }
    }

    private func updateRecordingDuration() {
        guard let recordingStartedAt else { return }
        recordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt))
    }

    private static func makeTempMovieURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }
}

// MARK: - Stereo CSV + Dual-Video 3D Reconstruction (PC-side processing only)

private enum StereoVideoSlot: String, Identifiable {
    case a
    case b

    var id: String { rawValue }
}

private struct StereoVideoMeta {
    var rawSize: CGSize = .zero
    var preferredTransform: CGAffineTransform = .identity
    var orientedRect: CGRect = .zero
    var previewSize: CGSize = .zero

    static let empty = StereoVideoMeta()
}

private struct StereoCSVRow: Identifiable {
    let id = UUID()
    let stereoIndex: Int
    let timeSec: Double
    let frameA: Int
    let visibilityA: Int
    let xA: Double
    let yA: Double
    let timeSecA: Double
    let frameB: Int
    let visibilityB: Int
    let xB: Double
    let yB: Double
    let timeSecB: Double
    let timeDeltaMs: Double
}

private struct Stereo3DPoint: Identifiable {
    let id = UUID()
    let stereoIndex: Int
    let timeSec: Double
    let frameA: Int
    let frameB: Int
    let imageA: CGPoint?
    let imageB: CGPoint?
    let groundA: CGPoint?
    let groundB: CGPoint?
    let world3D: SIMD3<Double>?
    let reprojectionErrorPx: Double?
}

private enum StereoShotType: String, CaseIterable, Codable, Identifiable {
    case serve = "Serve"
    case netShot = "Net Shot"
    case netCross = "Net Cross"
    case clearLift = "Clear / Lift"
    case drop = "Drop / Cut"
    case drive = "Drive"
    case pushBlock = "Push / Block"
    case smash = "Smash / Kill"
    case unknown = "Unknown"

    var id: String { rawValue }

    var displayLabel: String { rawValue }
}

private struct StereoShotEvent: Identifiable {
    var id = UUID()
    let startTime: Double
    let endTime: Double
    let startFrameA: Int
    let endFrameA: Int
    let startPoint: SIMD3<Double>
    let endPoint: SIMD3<Double>
    let peakHeight: Double
    let netHeight: Double?
    var type: StereoShotType
    var confidence: Double
    var isUserEdited: Bool = false
}

private struct DualAssistMetrics {
    let coverageB: Double
    let stereoCoverage: Double
    let timingQuality: Double
    let reprojectionQuality: Double
    let trendAgreement: Double

    var supportScore: Double {
        let raw = 0.26 * coverageB + 0.26 * stereoCoverage + 0.18 * timingQuality + 0.14 * reprojectionQuality + 0.16 * trendAgreement
        return min(1.0, max(0.0, raw))
    }
}

private struct DualAssistMotionCue {
    let startPx: CGPoint
    let endPx: CGPoint
    let dxPx: Double
    let dyPx: Double
    let travelPx: Double
    let durationSec: Double
}

private struct DualAssistCandidate {
    var shot: StereoShotEvent
    var cue: DualAssistMotionCue
}

private enum DualAssistCourtZone {
    case rear
    case mid
    case fore
    case net
}

private struct SavedStereoShotEvent: Codable, Identifiable {
    var id: UUID
    var startTime: Double
    var endTime: Double
    var startFrameA: Int?
    var endFrameA: Int?
    var startX: Double
    var startY: Double
    var startZ: Double
    var endX: Double
    var endY: Double
    var endZ: Double
    var peakHeight: Double
    var netHeight: Double?
    var type: StereoShotType
    var confidence: Double
    var isUserEdited: Bool

    init(from shot: StereoShotEvent) {
        id = shot.id
        startTime = shot.startTime
        endTime = shot.endTime
        startFrameA = shot.startFrameA
        endFrameA = shot.endFrameA
        startX = shot.startPoint.x
        startY = shot.startPoint.y
        startZ = shot.startPoint.z
        endX = shot.endPoint.x
        endY = shot.endPoint.y
        endZ = shot.endPoint.z
        peakHeight = shot.peakHeight
        netHeight = shot.netHeight
        type = shot.type
        confidence = shot.confidence
        isUserEdited = shot.isUserEdited
    }

    var shotEvent: StereoShotEvent {
        StereoShotEvent(
            id: id,
            startTime: startTime,
            endTime: endTime,
            startFrameA: startFrameA ?? Int((startTime * 30.0).rounded()),
            endFrameA: endFrameA ?? Int((endTime * 30.0).rounded()),
            startPoint: SIMD3<Double>(startX, startY, startZ),
            endPoint: SIMD3<Double>(endX, endY, endZ),
            peakHeight: peakHeight,
            netHeight: netHeight,
            type: type,
            confidence: confidence,
            isUserEdited: isUserEdited
        )
    }
}

private struct SavedCGPoint: Codable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

private struct SavedStereoCSVRow: Codable {
    var stereoIndex: Int
    var timeSec: Double
    var frameA: Int
    var visibilityA: Int
    var xA: Double
    var yA: Double
    var timeSecA: Double
    var frameB: Int
    var visibilityB: Int
    var xB: Double
    var yB: Double
    var timeSecB: Double
    var timeDeltaMs: Double

    init(_ row: StereoCSVRow) {
        stereoIndex = row.stereoIndex
        timeSec = row.timeSec
        frameA = row.frameA
        visibilityA = row.visibilityA
        xA = row.xA
        yA = row.yA
        timeSecA = row.timeSecA
        frameB = row.frameB
        visibilityB = row.visibilityB
        xB = row.xB
        yB = row.yB
        timeSecB = row.timeSecB
        timeDeltaMs = row.timeDeltaMs
    }

    var row: StereoCSVRow {
        StereoCSVRow(
            stereoIndex: stereoIndex,
            timeSec: timeSec,
            frameA: frameA,
            visibilityA: visibilityA,
            xA: xA,
            yA: yA,
            timeSecA: timeSecA,
            frameB: frameB,
            visibilityB: visibilityB,
            xB: xB,
            yB: yB,
            timeSecB: timeSecB,
            timeDeltaMs: timeDeltaMs
        )
    }
}

private struct SavedStereoMatch: Codable, Identifiable {
    var id: UUID
    var title: String
    var savedAt: Date
    var videoALabel: String
    var videoBLabel: String
    var csvLabel: String
    var totalPointCount: Int
    var validPointCount: Int
    var meanReprojectionError: Double?
    var peakHeight: Double?
    var shots: [SavedStereoShotEvent]
    var videoAFile: String?
    var videoBFile: String?
    var videoABookmark: Data?
    var videoBBookmark: Data?
    var csvBookmark: Data?
    var tapsA: [SavedCGPoint]
    var tapsB: [SavedCGPoint]
    var rows: [SavedStereoCSVRow]
    var rallyStartTimeSec: Double?
}

private struct StereoCameraMatrix {
    let rows: [SIMD4<Double>] // 3 rows

    func project(_ point: SIMD3<Double>) -> CGPoint? {
        let X = SIMD4<Double>(point.x, point.y, point.z, 1.0)
        let x = simd_dot(rows[0], X)
        let y = simd_dot(rows[1], X)
        let w = simd_dot(rows[2], X)
        guard abs(w) > 1e-9 else { return nil }
        return CGPoint(x: x / w, y: y / w)
    }
}

private struct StereoInputHeading: View {
    let title: String
    let loaded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Image(systemName: loaded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(loaded ? Color.green : Color.red)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(loaded ? "File loaded" : "File missing")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct StereoCalibrationPanel: View {
    let videoName: String
    let slot: StereoVideoSlot
    let image: UIImage?
    @Binding var taps: [CGPoint]
    let accent: Color
    let onImport: () -> Void
    let onOpenFullScreen: () -> Void

    private let orderLabels = StereoCourtAnchor.allCases.map(\.shortLabel)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StereoInputHeading(title: "\(videoName) Calibration", loaded: image != nil)
            Button(action: onImport) {
                Label(image == nil ? "Import \(videoName)" : "Change \(videoName)", systemImage: "film")
            }
            .buttonStyle(.borderedProminent)
            .guideTarget(slot == .a ? .videoA : .videoB)
            if let image {
                calibrationControls(for: image)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func calibrationControls(for image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text("BL → BR → TR → TL → Net-L → Net-R")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if taps.count < orderLabels.count {
                        Text("Next: \(orderLabels[taps.count])")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(accent.opacity(0.12), in: Capsule())
                    } else {
                        Text("Complete")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(orderLabels.enumerated()), id: \.offset) { idx, label in
                            let stateColor: Color = idx < taps.count ? .green : (idx == taps.count ? accent : .white.opacity(0.22))
                            Text(label)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(idx <= taps.count ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(stateColor.opacity(idx <= taps.count ? 0.20 : 0.10), in: Capsule())
                                .overlay(Capsule().stroke(stateColor.opacity(0.45), lineWidth: 1))
                        }
                    }
                }
            }

            Button(action: onOpenFullScreen) {
                GeometryReader { geo in
                    let fit = StereoCalibrationLayout.aspectFitRect(content: image.size, in: geo.size)
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.04))

                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        StereoCalibrationGuides(fitRect: fit, taps: taps, pixelSize: image.size, accent: accent)

                        ForEach(Array(taps.enumerated()), id: \.offset) { idx, tap in
                            let v = StereoCalibrationLayout.viewPoint(fromPixel: tap, pixelSize: image.size, fitRect: fit)
                            StereoMarker(label: orderLabels[idx], accent: accent, showLabel: false, labelOffset: StereoMarker.defaultOffset(for: orderLabels[idx]))
                                .position(v)
                        }

                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Label("Calibrate Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(12)
                            }
                        }
                    }
                }
                .frame(height: 220)
            }
            .buttonStyle(.plain)
            .guideTarget(slot == .a ? .calibrateA : .calibrateB)

            HStack(spacing: 10) {
                Button {
                    if !taps.isEmpty { _ = taps.removeLast() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(taps.isEmpty)

                Button(role: .destructive) {
                    taps.removeAll()
                } label: {
                    Label("Reset", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(taps.isEmpty)
            }
        }

    }
}

private enum StereoCalibrationLayout {
    static func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        let origin = CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    static func viewPoint(fromPixel point: CGPoint, pixelSize: CGSize, fitRect: CGRect) -> CGPoint {
        CGPoint(
            x: fitRect.minX + (point.x / max(1, pixelSize.width)) * fitRect.width,
            y: fitRect.minY + (point.y / max(1, pixelSize.height)) * fitRect.height
        )
    }

    static func pixelPoint(fromView point: CGPoint, pixelSize: CGSize, fitRect: CGRect) -> CGPoint {
        let nx = min(max((point.x - fitRect.minX) / max(1, fitRect.width), 0), 1)
        let ny = min(max((point.y - fitRect.minY) / max(1, fitRect.height), 0), 1)
        return CGPoint(x: nx * pixelSize.width, y: ny * pixelSize.height)
    }
}

private struct StereoCalibrationGuides: View {
    let fitRect: CGRect
    let taps: [CGPoint]
    let pixelSize: CGSize
    let accent: Color

    var body: some View {
        Canvas { ctx, _ in
            guard fitRect.width > 0, fitRect.height > 0 else { return }

            var border = Path()
            border.addRect(fitRect)
            ctx.stroke(border, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [8, 6]))

            let viewPoints = taps.map { StereoCalibrationLayout.viewPoint(fromPixel: $0, pixelSize: pixelSize, fitRect: fitRect) }
            if viewPoints.count > 1 {
                var poly = Path()
                poly.addLines(Array(viewPoints.prefix(min(4, viewPoints.count))))
                if viewPoints.count >= 4 { poly.closeSubpath() }
                ctx.stroke(poly, with: .color(accent.opacity(0.88)), style: StrokeStyle(lineWidth: 1.8, dash: [7, 5]))
            }

            if viewPoints.count >= 6 {
                var net = Path()
                net.move(to: viewPoints[4])
                net.addLine(to: viewPoints[5])
                ctx.stroke(net, with: .color(.green.opacity(0.95)), style: StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StereoCalibrationHandlesOverlay: View {
    @Binding var taps: [CGPoint]
    let pixelSize: CGSize
    let fitRect: CGRect
    let accent: Color
    var allowEditing: Bool = false
    var showLabels: Bool = false

    private let labels = StereoCourtAnchor.allCases.map(\.shortLabel)

    var body: some View {
        ZStack {
            ForEach(Array(taps.enumerated()), id: \.offset) { idx, tap in
                let viewPoint = StereoCalibrationLayout.viewPoint(fromPixel: tap, pixelSize: pixelSize, fitRect: fitRect)
                if allowEditing {
                    StereoMarker(label: labels[idx], accent: accent, showLabel: showLabels, labelOffset: StereoMarker.defaultOffset(for: labels[idx]))
                        .position(viewPoint)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let bounded = CGPoint(
                                        x: min(max(value.location.x, fitRect.minX), fitRect.maxX),
                                        y: min(max(value.location.y, fitRect.minY), fitRect.maxY)
                                    )
                                    taps[idx] = StereoCalibrationLayout.pixelPoint(fromView: bounded, pixelSize: pixelSize, fitRect: fitRect)
                                }
                        )
                } else {
                    StereoMarker(label: labels[idx], accent: accent, showLabel: showLabels, labelOffset: StereoMarker.defaultOffset(for: labels[idx]))
                        .position(viewPoint)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct StereoMarker: View {
    let label: String
    let accent: Color
    var showLabel: Bool = true
    var labelOffset: CGSize = .zero

    static func defaultOffset(for label: String) -> CGSize {
        switch label {
        case "BL": return CGSize(width: 16, height: -10)
        case "BR": return CGSize(width: -16, height: -10)
        case "TL": return CGSize(width: 16, height: 10)
        case "TR": return CGSize(width: -16, height: 10)
        case "Net-L": return CGSize(width: -26, height: -12)
        case "Net-R": return CGSize(width: 26, height: -12)
        default: return CGSize(width: 0, height: -12)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.20))
                .frame(width: 12, height: 12)
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
            Circle()
                .fill(accent)
                .frame(width: 3.5, height: 3.5)
        }
        .frame(width: 18, height: 18)
        .overlay(alignment: .center) {
            if showLabel {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .offset(x: labelOffset.width, y: labelOffset.height)
            }
        }
        .contentShape(Circle())
    }
}


private struct StereoCalibrationEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let image: UIImage
    @Binding var taps: [CGPoint]
    let accent: Color
    @Binding var guideActive: Bool

    @State private var zoomScale: CGFloat = 1
    private let orderLabels = StereoCourtAnchor.allCases.map(\.shortLabel)

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button("Back") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Spacer()
                    if guideActive {
                        Button("Skip") { guideActive = false }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Skip beginner guide")
                    }
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(taps.count < orderLabels.count ? "Tap: \(orderLabels[taps.count])" : "6-point calibration complete")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(taps.count < orderLabels.count ? accent : .green)
                            Text("BL → BR → TR → TL → Net-L → Net-R")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1fx", zoomScale))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(orderLabels.enumerated()), id: \.offset) { idx, label in
                                let stateColor: Color = idx < taps.count ? .green : (idx == taps.count ? accent : .white.opacity(0.22))
                                Text(label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(idx <= taps.count ? .primary : .secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(stateColor.opacity(idx <= taps.count ? 0.20 : 0.10), in: Capsule())
                                    .overlay(Capsule().stroke(stateColor.opacity(0.45), lineWidth: 1))
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)

                GeometryReader { geo in
                    let fit = StereoCalibrationLayout.aspectFitRect(content: image.size, in: geo.size)
                    ZoomableScrollView(minZoom: 1, maxZoom: 8, zoomScale: $zoomScale, onSingleTap: { point in
                        guard taps.count < orderLabels.count else { return }
                        guard fit.contains(point) else { return }
                        taps.append(StereoCalibrationLayout.pixelPoint(fromView: point, pixelSize: image.size, fitRect: fit))
                    }) {
                        ZStack {
                            Color.black

                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width, height: geo.size.height)

                            StereoCalibrationGuides(fitRect: fit, taps: taps, pixelSize: image.size, accent: accent)
                            StereoCalibrationHandlesOverlay(taps: $taps, pixelSize: image.size, fitRect: fit, accent: accent, allowEditing: taps.count >= orderLabels.count, showLabels: true)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }

                HStack(spacing: 12) {
                    Text(taps.count < orderLabels.count ? "Pinch to zoom · existing points won’t block the next tap" : "Pinch to zoom · drag points to fine-tune")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        zoomScale = 1
                    } label: {
                        Label("1x", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.top, 10)

                HStack(spacing: 12) {
                    Button {
                        if !taps.isEmpty { _ = taps.removeLast() }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(taps.isEmpty)

                    Button(role: .destructive) {
                        taps.removeAll()
                        zoomScale = 1
                    } label: {
                        Label("Reset", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(taps.isEmpty)
                }
                .padding()
            }
        }
    }
}

private struct StereoEditableShotCard: View {
    let index: Int
    let shot: StereoShotEvent
    let isSelected: Bool
    let onSelect: () -> Void
    let onTypeChange: (StereoShotType) -> Void

    private var tint: Color {
        switch shot.type {
        case .serve: return .cyan
        case .smash: return .red
        case .drop: return .orange
        case .clearLift: return .blue
        case .drive: return .purple
        case .pushBlock: return .mint
        case .netShot, .netCross: return .green
        case .unknown: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shot \(index)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(shot.type.displayLabel)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Menu {
                    ForEach(StereoShotType.allCases) { type in
                        Button {
                            onTypeChange(type)
                        } label: {
                            if shot.type == type {
                                Label(type.displayLabel, systemImage: "checkmark")
                            } else {
                                Text(type.displayLabel)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Label(String(format: "%.3fs", shot.startTime), systemImage: "play.fill")
                Text("→")
                Label(String(format: "%.3fs", shot.endTime), systemImage: "stop.fill")
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)

            Text(String(format: "Peak %.2f m", shot.peakHeight))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                if !shot.isUserEdited {
                    Text(String(format: "%.0f%%", shot.confidence * 100))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(tint)
                }
                Spacer()
                if shot.isUserEdited {
                    Label("Edited", systemImage: "pencil")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? tint.opacity(0.16) : Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.85) : Color.white.opacity(0.05), lineWidth: isSelected ? 1.6 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

private struct StereoSaveMatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var title: String
    let isUpdating: Bool
    let onSave: () throws -> Void
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if let failure { Text(failure).foregroundStyle(.red) }
                Section("Match Name") {
                    TextField("Enter a name", text: $title)
                }

                Section {
                    Text("Saved results can be reopened and edited later.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(isUpdating ? "Update Match" : "Save Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUpdating ? "Update" : "Save") {
                        do {
                            try onSave()
                            dismiss()
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

private struct StereoSavedMatchRow: View {
    let match: SavedStereoMatch
    let isActive: Bool
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(match.title)
                        .font(.subheadline.weight(.semibold))
                    if isActive {
                        Text("Loaded")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }
                Text(match.savedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(match.shots.count) shots · \(match.videoALabel) / \(match.videoBLabel) · \(match.csvLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Load", action: onLoad)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StereoSingleCameraReview: View {
    @Environment(\.dismiss) private var dismiss

    let player: AVPlayer
    let displayPixelSize: CGSize
    let calibrationPixelSize: CGSize
    let homography: Homography?
    let court: BadmintonCourt
    let pointsPx: [CGPoint?]
    let fps: Double
    @Binding var shots: [StereoShotEvent]
    @Binding var selectedShotID: UUID?
    let onTypeChange: (UUID, StereoShotType) -> Void
    let defaultTitle: String
    let isUpdating: Bool
    let saveMatch: (String) throws -> Void
    @State private var namingMatch = false
    @State private var name = ""
    @State private var savedNotice: String?

    @State private var playbackRate: Float = 1.0
    @State private var currentFrame: Int = 0
    @State private var timeObserver: Any?

    private var reviewFrameOffset: Int { 0 }

    private var selectedShot: StereoShotEvent? {
        if let selectedShotID, let found = shots.first(where: { $0.id == selectedShotID }) { return found }
        return shots.first
    }

    private var activeShotID: UUID? {
        shots.first(where: { currentFrame >= $0.startFrameA && currentFrame < $0.endFrameA })?.id
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button("Back") {
                        player.pause()
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("Video A Review")
                        .font(.headline)
                    Spacer()
                    Button("Save") {
                        player.pause()
                        savedNotice = nil
                        name = defaultTitle
                        namingMatch = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 10)

                GeometryReader { geo in
                    let videoPxSize = displayPixelSize == .zero ? CGSize(width: 1920, height: 1080) : displayPixelSize
                    let overlayPxSize = calibrationPixelSize == .zero ? videoPxSize : calibrationPixelSize
                    let fit = StereoCalibrationLayout.aspectFitRect(content: videoPxSize, in: geo.size)
                    ZStack(alignment: .top) {
                        PlayerLayerView(player: player)
                            .aspectRatio(max(1.0, videoPxSize.width) / max(1.0, videoPxSize.height), contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .background(Color.black)

                        if let homography {
                            StereoReviewCourtOverlay(size: geo.size, fitRect: fit, pixelSize: overlayPxSize, homography: homography, court: court)
                        }

                        LiveTrajectoryOverlay(
                            pointsPx: pointsPx,
                            pixelSize: videoPxSize,
                            containerSize: geo.size,
                            currentFrame: currentFrame,
                            tailLength: 16,
                            hitFrames: Set(shots.map { $0.startFrameA })
                        )


                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                HStack(spacing: 8) {
                                    Button {
                                        if player.timeControlStatus == .playing {
                                            player.pause()
                                        } else {
                                            player.playImmediately(atRate: playbackRate)
                                        }
                                    } label: {
                                        Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundColor(.white)
                                            .frame(width: 38, height: 38)
                                            .background(Color.black.opacity(0.68), in: Circle())
                                    }
                                    .buttonStyle(.plain)

                                    Menu {
                                        ForEach([0.5 as Float, 1.0, 1.5, 2.0], id: \.self) { rate in
                                            Button {
                                                playbackRate = rate
                                                if player.timeControlStatus == .playing {
                                                    player.rate = rate
                                                }
                                            } label: {
                                                if playbackRate == rate {
                                                    Label("\(String(format: "%g", rate))x", systemImage: "checkmark")
                                                } else {
                                                    Text("\(String(format: "%g", rate))x")
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "speedometer")
                                            Text("\(String(format: "%g", playbackRate))x")
                                                .fontWeight(.bold)
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(Color.black.opacity(0.68), in: Capsule())
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        if let active = activeShotID, let idx = shots.firstIndex(where: { $0.id == active }) {
                            Text("Now Playing · Shot #\(idx + 1)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Shot Cards")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("Tap a card to jump · use ⋯ to fix the label")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(shots.enumerated()), id: \.element.id) { idx, shot in
                                    StereoEditableShotCard(
                                        index: idx + 1,
                                        shot: shot,
                                        isSelected: (activeShotID ?? selectedShotID) == shot.id,
                                        onSelect: {
                                            selectedShotID = shot.id
                                            let time = CMTime(seconds: shot.startTime, preferredTimescale: 600)
                                            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                                            player.pause()
                                        },
                                        onTypeChange: { type in
                                            savedNotice = nil
                                            onTypeChange(shot.id, type)
                                        }
                                    )
                                    .id(shot.id)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .onChange(of: activeShotID) { _, newID in
                            guard let newID else { return }
                            selectedShotID = newID
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
        }
        .sheet(isPresented: $namingMatch) {
            StereoSaveMatchSheet(title: $name, isUpdating: isUpdating) {
                try saveMatch(name)
                savedNotice = "Saved to Saved Matches."
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let savedNotice {
                Label(savedNotice, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .padding(6)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .onAppear {
            if selectedShotID == nil {
                selectedShotID = shots.first?.id
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / max(fps, 1.0), preferredTimescale: 600), queue: .main) { time in
                let sec = max(0, time.seconds)
                let rawFrame = Int(floor(sec * fps + 0.0001))
                currentFrame = max(0, rawFrame - reviewFrameOffset)
                if let active = activeShotID {
                    selectedShotID = active
                }
            }
        }
        .onDisappear {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }
    }
}

private struct StereoReviewCourtOverlay: View {
    let size: CGSize
    let fitRect: CGRect
    let pixelSize: CGSize
    let homography: Homography
    let court: BadmintonCourt

    private var primarySegments: [(CGPoint, CGPoint)] {
        [
            // Outer doubles boundary
            (CGPoint(x: 0, y: 0), CGPoint(x: court.W, y: 0)),
            (CGPoint(x: court.W, y: 0), CGPoint(x: court.W, y: court.L)),
            (CGPoint(x: court.W, y: court.L), CGPoint(x: 0, y: court.L)),
            (CGPoint(x: 0, y: court.L), CGPoint(x: 0, y: 0)),

            // Net and key service geometry
            (CGPoint(x: 0, y: court.halfL), CGPoint(x: court.W, y: court.halfL)),
            (CGPoint(x: 0, y: court.halfL - court.sSvc), CGPoint(x: court.W, y: court.halfL - court.sSvc)),
            (CGPoint(x: 0, y: court.halfL + court.sSvc), CGPoint(x: court.W, y: court.halfL + court.sSvc)),
            (CGPoint(x: 0, y: court.dLong), CGPoint(x: court.W, y: court.dLong)),
            (CGPoint(x: 0, y: court.L - court.dLong), CGPoint(x: court.W, y: court.L - court.dLong)),

            // Centre service line split by the net
            (CGPoint(x: court.halfW, y: court.dLong), CGPoint(x: court.halfW, y: court.halfL - court.sSvc)),
            (CGPoint(x: court.halfW, y: court.halfL + court.sSvc), CGPoint(x: court.halfW, y: court.L - court.dLong))
        ]
    }

    private var referenceSegments: [(CGPoint, CGPoint)] {
        [
            // Singles sidelines across the full court
            (CGPoint(x: court.xS1, y: 0), CGPoint(x: court.xS1, y: court.L)),
            (CGPoint(x: court.xS2, y: 0), CGPoint(x: court.xS2, y: court.L)),

            // Centre line extensions toward the baselines so every calibration guide stays visible
            (CGPoint(x: court.halfW, y: 0), CGPoint(x: court.halfW, y: court.dLong)),
            (CGPoint(x: court.halfW, y: court.L - court.dLong), CGPoint(x: court.halfW, y: court.L))
        ]
    }

    var body: some View {
        Canvas { ctx, _ in
            func vp(_ p: CGPoint) -> CGPoint {
                StereoCalibrationLayout.viewPoint(fromPixel: p, pixelSize: pixelSize, fitRect: fitRect)
            }
            func drawSegments(_ segs: [(CGPoint, CGPoint)], color: Color, lineWidth: CGFloat, dash: [CGFloat] = []) {
                var path = Path()
                for (a, b) in segs {
                    path.move(to: vp(homography.project(a)))
                    path.addLine(to: vp(homography.project(b)))
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash))
            }

            // Review mode should always show the full calibration proof overlay,
            // not just the currently emphasised play-mode lines.
            drawSegments(primarySegments, color: .green.opacity(0.98), lineWidth: 2.8)
            drawSegments(referenceSegments, color: .yellow.opacity(0.98), lineWidth: 2.0, dash: [8, 6])
        }
        .allowsHitTesting(false)
    }
}

private struct StereoAnalysisScreen: View {

    @Environment(\.dismiss) private var dismiss
    var showSavedMatchesFirst: Bool = false
    @Binding var guideActive: Bool
    private enum AnchorPlaybackPhase: Equatable {
        case ready, playing, paused, finished
    }

    @State private var anchorPlayback: AnchorPlaybackPhase = .ready
    @State private var analysisProgress: Double?
    @State private var analysisTask: Task<Void, Never>?

    @State private var pickerSlot: StereoVideoSlot? = nil
    @State private var showCSVImporter = false
    @State private var calibrationSlot: StereoVideoSlot? = nil

    @State private var videoAURL: URL? = nil
    @State private var videoBURL: URL? = nil
    @State private var stereoCSVURL: URL? = nil
    @State private var previewA: UIImage? = nil
    @State private var previewB: UIImage? = nil
    @State private var metaA: StereoVideoMeta = .empty
    @State private var metaB: StereoVideoMeta = .empty
    @State private var tapsA: [CGPoint] = []
    @State private var tapsB: [CGPoint] = []

    @State private var stereoRows: [StereoCSVRow] = []
    @State private var points3D: [Stereo3DPoint] = []
    @State private var shots: [StereoShotEvent] = []
    @State private var selectedShotID: UUID? = nil
    @State private var stereoPlayer: AVPlayer? = nil
    @State private var savedMatches: [SavedStereoMatch] = []
    @State private var currentSavedMatchID: UUID? = nil
    @State private var saveDraftTitle: String = ""
    @State private var showSavePrompt = false
    @State private var showReviewMode = false
    @State private var errorText: String? = nil
    @State private var exportURL: URL? = nil
    @State private var showExportSheet = false
    @State private var rallyStartTimeSec: Double? = nil
    @State private var anchorPreviewTimeSec: Double = 0
    @State private var anchorDurationSec: Double = 0
    @State private var isAnchorScrubbing = false
    @State private var anchorTimeObserver: Any? = nil

    private let court = BadmintonCourt()
    private let maxTimeDeltaMs: Double = 20.0
    private let maxReprojectionErrorPx: Double = 28.0
    private let netPostHeightMeters: Double = 1.55

    private var missingInputs: [String] {
        var missing: [String] = []
        if previewA == nil { missing.append("Import Video A.") }
        else if tapsA.count != 6 { missing.append("Video A Calibration: \(tapsA.count)/6 points.") }
        if previewB == nil { missing.append("Import Video B.") }
        else if tapsB.count != 6 { missing.append("Video B Calibration: \(tapsB.count)/6 points.") }
        if stereoRows.isEmpty { missing.append("Import the dual-view CSV for these videos.") }
        return missing
    }

    private var assistGuideTarget: GuideTarget? {
        guard guideActive, !showSavedMatchesFirst, analysisProgress == nil,
              anchorPlayback != .playing, anchorPlayback != .paused else { return nil }
        if previewA == nil { return .videoA }
        if previewB == nil { return .videoB }
        if stereoRows.isEmpty { return .csv }
        if tapsA.count < 6 { return .calibrateA }
        if tapsB.count < 6 { return .calibrateB }
        return anchorPlayback == .finished ? .run : .play
    }

    private var assistGuideHint: String {
        switch assistGuideTarget {
        case .videoA: return "Import the video used as Camera A in your backend run."
        case .videoB: return "Import the matching Camera B video from the same rally."
        case .csv: return "Choose the matching _stereo.csv from the backend output."
        case .calibrateA: return "Open Video A Calibration. Tap the four court corners and both net-post tops, then tap Done."
        case .calibrateB: return "Open Video B Calibration. Mark the same six court locations in this view, then tap Done."
        case .play: return "In Rally Start Anchor, tap Play to watch Camera A. The guide continues when the video ends."
        case .run: return "Tap Run Dual Camera Assisted Analysis to reconstruct the trajectory and detect shots."
        default: return ""
        }
    }

    private var meanReprojectionError: Double? {
        let vals = points3D.compactMap { $0.reprojectionErrorPx }
        if !vals.isEmpty { return vals.reduce(0, +) / Double(vals.count) }
        return savedMatches.first(where: { $0.id == currentSavedMatchID })?.meanReprojectionError
    }

    private var maxHeight: Double? {
        let vals = points3D.compactMap { $0.world3D?.z }
        if let live = vals.max() { return live }
        return savedMatches.first(where: { $0.id == currentSavedMatchID })?.peakHeight
    }

    private var validPointCount: Int {
        if !points3D.isEmpty { return points3D.compactMap { $0.world3D }.count }
        return savedMatches.first(where: { $0.id == currentSavedMatchID })?.validPointCount ?? 0
    }

    private var currentLoadedTotalPointCount: Int {
        if !points3D.isEmpty { return points3D.count }
        return savedMatches.first(where: { $0.id == currentSavedMatchID })?.totalPointCount ?? 0
    }

    private var meanAssistConfidence: Double? {
        guard !shots.isEmpty else { return nil }
        return shots.map(\.confidence).reduce(0, +) / Double(shots.count)
    }

    private var suggestedMatchTitle: String {
        if let active = savedMatches.first(where: { $0.id == currentSavedMatchID }) {
            return active.title
        }
        return "Rally · " + Date.now.formatted(date: .abbreviated, time: .shortened)
    }

    private var anchorFPS: Double {
        estimatedFPS()
    }

    private var anchorNudgeSec: Double {
        0.10
    }

    private var hasRallyStartAnchor: Bool {
        rallyStartTimeSec != nil
    }

    private var reviewPointsA: [CGPoint?] {
        // Display layer only:
        // In Dual Camera review, draw the on-video shuttle marker / trajectory directly from
        // the dual CSV Camera A columns (x_a / y_a). Keep these in the real oriented video
        // pixel space so the overlay matches the AVPlayer display just like single-camera mode.
        return frameIndexedRawCameraAPixelsForReview()
    }

    private func frameIndexedRawCameraAPixelsForReview() -> [CGPoint?] {
        guard !stereoRows.isEmpty else { return [] }
        let baseFrame = stereoRows.map(\.frameA).min() ?? 0
        let maxFrame = stereoRows.reduce(0) { partial, row in
            max(partial, max(0, row.frameA - baseFrame))
        }
        guard maxFrame >= 0 else { return [] }

        var out: [CGPoint?] = Array(repeating: nil, count: maxFrame + 1)
        for row in stereoRows {
            guard row.visibilityA == 1 else { continue }
            let point = CGPoint(x: row.xA, y: row.yA)
            if point == .zero { continue }
            let frame = max(0, row.frameA - baseFrame)
            guard out.indices.contains(frame) else { continue }
            out[frame] = point
        }
        return out
    }

    private var savedMatchesFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SavedMatches", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dual_camera_assisted_matches.json")
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                if showSavedMatchesFirst { savedMatchesPanel }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Dual Camera Assisted Analysis")
                        .font(.title2.weight(.bold))
                    Text("Camera A remains the main reference for segmentation and shot labels. Camera B is used as an assistant layer to reject false positives, recover short gaps, and raise or lower confidence when the two views agree or disagree.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if !showSavedMatchesFirst, !savedMatches.isEmpty { savedMatchesPanel }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Calibration Guide")
                        .font(.headline)
                    Text("Open Video A or Video B to calibrate full-screen. Camera A drives the main analysis; Camera B is calibrated for assisted validation. While placing the 6 points, existing markers stay out of the way; after all 6 taps are done, you can drag them to fine-tune just like the normal calibration flow.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                inputPanels

                if let stereoPlayer, previewA != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Rally Start Anchor")
                                        .font(.headline)
                                    Text("Play Video A to preview the rally. To set the start, pause at the first serve and tap Use current frame as serve start.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if let rallyStartTimeSec {
                                    Text(String(format: "Serve @ %.2fs", rallyStartTimeSec))
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.cyan)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.cyan.opacity(0.12), in: Capsule())
                                }
                            }

                            GeometryReader { geo in
                                let pxSize = metaA.previewSize == .zero ? CGSize(width: 1920, height: 1080) : metaA.previewSize
                                PlayerLayerView(player: stereoPlayer, poster: previewA)
                                    .aspectRatio(max(1.0, pxSize.width) / max(1.0, pxSize.height), contentMode: .fit)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .background(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .frame(height: 220)
                            HStack {
                                Button(action: toggleAnchorPlayback) {
                                    Label(anchorPlayback == .playing ? "Pause" : "Play",
                                          systemImage: anchorPlayback == .playing ? "pause.fill" : "play.fill")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.borderedProminent)
                                if guideActive && !showSavedMatchesFirst && (anchorPlayback == .playing || anchorPlayback == .paused) {
                                    Button("Skip Guide") { guideActive = false }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .guideTarget(.play)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Current")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.1fs", anchorPreviewTimeSec))
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Selected start")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(hasRallyStartAnchor ? String(format: "%.1fs", rallyStartTimeSec ?? 0) : "Not set")
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                        .foregroundColor(hasRallyStartAnchor ? .cyan : .primary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Duration")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.1fs", anchorDurationSec))
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Scrub timeline")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("Adjust in 0.1s steps")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { anchorPreviewTimeSec },
                                    set: { newValue in
                                        isAnchorScrubbing = true
                                        anchorPreviewTimeSec = min(max(0, newValue), max(anchorDurationSec, 0.01))
                                    }
                                ), in: 0...max(anchorDurationSec, 0.01), onEditingChanged: { editing in
                                    if editing { pauseAnchorPlayback() }
                                    isAnchorScrubbing = editing
                                    if !editing {
                                        seekAnchorPreview(to: anchorPreviewTimeSec)
                                    }
                                })
                                .tint(.cyan)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Fine adjust by time")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack(spacing: 10) {
                                    Button {
                                        stepAnchorPreview(by: -anchorNudgeSec)
                                    } label: {
                                        Label("Back 0.1s", systemImage: "gobackward.10")
                                            .labelStyle(.titleAndIcon)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.85)
                                            .frame(maxWidth: .infinity, minHeight: 50)
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        stepAnchorPreview(by: anchorNudgeSec)
                                    } label: {
                                        Label("Forward 0.1s", systemImage: "goforward.10")
                                            .labelStyle(.titleAndIcon)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.85)
                                            .frame(maxWidth: .infinity, minHeight: 50)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    markCurrentFrameAsRallyStart()
                                } label: {
                                    Label("Use current frame as serve start", systemImage: "flag.checkered.2.crossed")
                                        .frame(maxWidth: .infinity, minHeight: 50)
                                }
                                .buttonStyle(.borderedProminent)

                                if hasRallyStartAnchor {
                                    Button(role: .destructive) {
                                        clearRallyStartAnchor()
                                    } label: {
                                        Label("Clear", systemImage: "xmark.circle")
                                            .frame(minHeight: 50)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        startAssistedAnalysis()
                    } label: {
                        Label("Run Dual Camera Assisted Analysis", systemImage: "camera.metering.center.weighted")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .guideTarget(.run)
                    if let analysisProgress {
                        ProgressView("Analyzing \(stereoRows.count) paired frames…", value: analysisProgress)
                    } else if !missingInputs.isEmpty {
                        Text(missingInputs.joined(separator: " "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !points3D.isEmpty || currentSavedMatchID != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Assist Summary")
                                .font(.headline)
                            Text("Valid 3D points: \(validPointCount) / \(max(points3D.count, currentLoadedTotalPointCount))")
                                .font(.subheadline)
                            if let meanReprojectionError {
                                Text(String(format: "Mean reprojection error: %.1f px", meanReprojectionError))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if meanReprojectionError > 18 {
                                    Text("3D calibration looks weak right now, so shot typing will lean more on Camera A 2D trajectory until the stereo fit improves.")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            if let maxHeight {
                                Text(String(format: "Peak reconstructed height: %.2f m", maxHeight))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("Detected shots: \(shots.count) · Video A remains the main review and labeling reference")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let meanAssistConfidence {
                                Text(String(format: "Mean assist confidence: %.0f%%", meanAssistConfidence * 100.0))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if stereoPlayer != nil, !shots.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Video A Review")
                                    .font(.headline)
                                Text("Use Video A as the main review reference. Camera B only acts as an assistant signal for confidence, trajectory sanity checks, and short-gap recovery.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                showReviewMode = true
                            } label: {
                                Label("Open Review Mode", systemImage: "play.rectangle.on.rectangle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if !shots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Shot Results")
                                .font(.headline)
                            Spacer()
                            Button {
                                saveDraftTitle = saveDraftTitle.isEmpty ? suggestedMatchTitle : saveDraftTitle
                                showSavePrompt = true
                            } label: {
                                Label(currentSavedMatchID == nil ? "Save Match" : "Update Saved Match", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        ForEach(Array(shots.enumerated()), id: \.element.id) { idx, shot in
                            StereoEditableShotCard(index: idx + 1, shot: shot, isSelected: selectedShotID == shot.id, onSelect: {
                                selectedShotID = shot.id
                                seekStereoPlayer(to: shot.startTime)
                            }, onTypeChange: { type in
                                updateShotType(shot.id, to: type)
                            })
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                }
                .padding()
                .disabled(analysisProgress != nil)
            }
            .onChange(of: assistGuideTarget, initial: true) { _, step in
                if let step { proxy.scrollTo(step, anchor: .center) }
            }
            .onChange(of: calibrationSlot) { _, slot in
                if slot == nil, let step = assistGuideTarget { proxy.scrollTo(step, anchor: .center) }
            }
            .guided(assistGuideTarget, hint: assistGuideHint) { guideActive = false }
        }
        }
        .navigationTitle(showSavedMatchesFirst ? "Saved Matches" : "Dual Cam Assist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { dismiss() }
            }
        }
        .onAppear {
            loadSavedMatches()
            if let url = videoAURL, stereoPlayer == nil {
                let asset = AVAsset(url: url)
                let loadedDuration = max(asset.duration.seconds, asset.tracks(withMediaType: .video).first?.timeRange.duration.seconds ?? 0)
                stereoPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                if loadedDuration.isFinite, loadedDuration > 0 {
                    anchorDurationSec = loadedDuration
                }
            }
            attachAnchorTimeObserverIfNeeded()
            if selectedShotID == nil {
                selectedShotID = shots.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === stereoPlayer?.currentItem,
                  anchorPlayback == .playing, !showReviewMode, !isAnchorScrubbing else { return }
            anchorPlayback = .finished
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === stereoPlayer?.currentItem,
                  anchorPlayback == .playing, !showReviewMode else { return }
            pauseAnchorPlayback()
            errorText = item.error?.localizedDescription ?? "Video A could not finish playing. Try playing it again or re-import the clip."
        }
        .onDisappear {
            pauseAnchorPlayback()
            analysisTask?.cancel()
            detachAnchorTimeObserver()
        }
        .sheet(item: $pickerSlot) { slot in
            VideoPicker(
                onPicked: { url in
                    pickerSlot = nil
                    Task { await loadVideo(url: url, slot: slot) }
                },
                onCancel: { pickerSlot = nil }
            )
        }
        .fullScreenCover(item: $calibrationSlot) { slot in
            switch slot {
            case .a:
                if let previewA {
                    StereoCalibrationEditor(title: "Video A Calibration", image: previewA, taps: $tapsA, accent: .blue, guideActive: $guideActive)
                }
            case .b:
                if let previewB {
                    StereoCalibrationEditor(title: "Video B Calibration", image: previewB, taps: $tapsB, accent: .orange, guideActive: $guideActive)
                }
            }
        }
        .fullScreenCover(isPresented: $showReviewMode) {
            if let stereoPlayer {
                StereoSingleCameraReview(
                    player: stereoPlayer,
                    displayPixelSize: {
                        let w = abs(metaA.orientedRect.width)
                        let h = abs(metaA.orientedRect.height)
                        if w > 0, h > 0 { return CGSize(width: w, height: h) }
                        return metaA.previewSize
                    }(),
                    calibrationPixelSize: metaA.previewSize,
                    homography: homography(from: tapsA),
                    court: court,
                    pointsPx: reviewPointsA,
                    fps: estimatedFPS(),
                    shots: $shots,
                    selectedShotID: $selectedShotID,
                    onTypeChange: { id, type in updateShotType(id, to: type) },
                    defaultTitle: suggestedMatchTitle,
                    isUpdating: currentSavedMatchID != nil,
                    saveMatch: { try persistCurrentMatch(named: $0) }
                )
            }
        }
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await loadStereoCSV(url: url) }
            case .failure(let err):
                errorText = err.localizedDescription
            }
        }
        .alert("Dual Camera Assist", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "Unknown error")
        }
        .sheet(isPresented: $showSavePrompt) {
            StereoSaveMatchSheet(title: $saveDraftTitle, isUpdating: currentSavedMatchID != nil) {
                try persistCurrentMatch(named: saveDraftTitle)
            }
        }
        .sheet(isPresented: $showExportSheet, onDismiss: {
            exportURL = nil
        }) {
            if let url = exportURL {
                ActivityView(activityItems: [url])
            }
        }
    }

    private func estimatedFPS() -> Double {
        let dts = zip(stereoRows, stereoRows.dropFirst()).map { max(0, $1.timeSecA - $0.timeSecA) }.filter { $0 > 1e-5 }
        guard !dts.isEmpty else { return 30.0 }
        let sorted = dts.sorted()
        let median = sorted[sorted.count / 2]
        return max(1.0, min(240.0, 1.0 / median))
    }

    private func baseFrameIndex(for slot: StereoVideoSlot) -> Int {
        let frames = stereoRows.map { slot == .a ? $0.frameA : $0.frameB }
        return frames.min() ?? 0
    }

    private func normalizedFrameIndex(_ rawFrame: Int, slot: StereoVideoSlot) -> Int {
        max(0, rawFrame - baseFrameIndex(for: slot))
    }

    private func makeSecurityBookmark(for url: URL?) -> Data? {
        guard let url else { return nil }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolveSecurityBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    private func restoreSavedMedia(for match: SavedStereoMatch) {
        tapsA = match.tapsA.map(\.cgPoint)
        tapsB = match.tapsB.map(\.cgPoint)
        stereoRows = match.rows.map(\.row)
        if let url = resolveSecurityBookmark(match.csvBookmark) {
            stereoCSVURL = url
        }
        func savedVideo(_ filename: String?, _ bookmark: Data?) -> URL? {
            if let filename {
                let url = mediaDirectory(match.id).appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return resolveSecurityBookmark(bookmark)
        }
        let a = savedVideo(match.videoAFile, match.videoABookmark)
        let b = savedVideo(match.videoBFile, match.videoBBookmark)
        Task { @MainActor in
            if let url = b { await loadVideo(url: url, slot: .b, resetCalibration: false, resetAnalysis: false, clearCurrentMatch: false, restoring: match.id) }
            guard currentSavedMatchID == match.id else { return }
            if let url = a {
                await loadVideo(url: url, slot: .a, resetCalibration: false, resetAnalysis: false, clearCurrentMatch: false, restoring: match.id)
            }
            guard currentSavedMatchID == match.id else { return }
            if stereoPlayer != nil, !shots.isEmpty {
                showReviewMode = true
            } else if stereoPlayer == nil {
                errorText = "The saved results are loaded. Re-import the original Camera A video to play this older match."
            }
        }
    }


    private var savedMatchesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Matches")
                    .font(.headline)
                Spacer()
                Text("Open and continue editing later")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if savedMatches.isEmpty {
                Text("Saved matches will appear here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(savedMatches) { match in
                StereoSavedMatchRow(match: match, isActive: currentSavedMatchID == match.id, onLoad: {
                    loadSavedMatch(match)
                }, onDelete: {
                    deleteSavedMatch(match.id)
                })
            }
        }
        .id("savedMatchesSection")
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var inputPanels: some View {
        StereoCalibrationPanel(videoName: "Video A", slot: .a, image: previewA, taps: $tapsA, accent: .blue,
                               onImport: { pickerSlot = .a }, onOpenFullScreen: { calibrationSlot = .a })
        StereoCalibrationPanel(videoName: "Video B", slot: .b, image: previewB, taps: $tapsB, accent: .orange,
                               onImport: { pickerSlot = .b }, onOpenFullScreen: { calibrationSlot = .b })

        VStack(alignment: .leading, spacing: 12) {
            StereoInputHeading(title: "Dual-View CSV", loaded: !stereoRows.isEmpty)
            Button { showCSVImporter = true } label: {
                Label(stereoRows.isEmpty ? "Import Dual-View CSV" : "Change Dual-View CSV", systemImage: "doc.text")
            }
            .buttonStyle(.borderedProminent)
            .guideTarget(.csv)
            if !stereoRows.isEmpty {
                Text("\(stereoRows.count) rows loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

        HStack {
            Button { exportStereoCalibrationAndShare() } label: {
                Label("Export Calibration JSON", systemImage: "square.and.arrow.up")
            }
            .disabled(previewA == nil || previewB == nil || tapsA.count < 6 || tapsB.count < 6)
            Button(role: .destructive) { clearAll() } label: {
                Label("Clear All", systemImage: "trash")
            }
        }
        .buttonStyle(.bordered)
    }

    private func attachAnchorTimeObserverIfNeeded() {
        detachAnchorTimeObserver()
        guard let stereoPlayer else {
            anchorDurationSec = 0
            anchorPreviewTimeSec = 0
            return
        }
        let rawDuration = stereoPlayer.currentItem?.asset.duration.seconds ?? stereoPlayer.currentItem?.duration.seconds ?? anchorDurationSec
        let safeDuration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : anchorDurationSec
        anchorDurationSec = max(0, safeDuration)
        let currentSec = stereoPlayer.currentTime().seconds
        let safeCurrent = currentSec.isFinite ? currentSec : 0
        anchorPreviewTimeSec = min(max(0, safeCurrent), max(anchorDurationSec, 0))
        anchorTimeObserver = stereoPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / max(anchorFPS, 30.0), preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isAnchorScrubbing else { return }
            let sec = max(0, time.seconds)
            if sec.isFinite {
                anchorPreviewTimeSec = min(sec, max(anchorDurationSec, 0))
            }
        }
    }

    private func detachAnchorTimeObserver() {
        guard let stereoPlayer, let anchorTimeObserver else { return }
        stereoPlayer.removeTimeObserver(anchorTimeObserver)
        self.anchorTimeObserver = nil
    }

    private func seekAnchorPreview(to timeSec: Double) {
        guard let stereoPlayer else { return }
        if anchorPlayback == .finished { anchorPlayback = .paused }
        let snapped = (timeSec / anchorNudgeSec).rounded() * anchorNudgeSec
        let clamped = min(max(0, snapped), max(anchorDurationSec, 0))
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        stereoPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        anchorPreviewTimeSec = clamped
    }

    private func stepAnchorPreview(by deltaSec: Double) {
        pauseAnchorPlayback()
        seekAnchorPreview(to: anchorPreviewTimeSec + deltaSec)
    }

    private func pauseAnchorPlayback() {
        stereoPlayer?.pause()
        if anchorPlayback == .playing { anchorPlayback = .paused }
    }

    private func toggleAnchorPlayback() {
        guard let stereoPlayer, let item = stereoPlayer.currentItem else { return }
        if anchorPlayback == .playing {
            pauseAnchorPlayback()
            return
        }
        guard item.status != .failed else {
            errorText = item.error?.localizedDescription ?? "Video A could not be played. Please re-import the clip."
            return
        }
        let time = stereoPlayer.currentTime().seconds
        if anchorPlayback == .finished || (anchorDurationSec > 0 && time >= anchorDurationSec - 0.001) {
            stereoPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        anchorPlayback = .playing
        stereoPlayer.play()
    }

    private func markCurrentFrameAsRallyStart() {
        pauseAnchorPlayback()
        let liveSec = stereoPlayer?.currentTime().seconds ?? anchorPreviewTimeSec
        let safeSec = liveSec.isFinite ? liveSec : anchorPreviewTimeSec
        let snapped = (safeSec / anchorNudgeSec).rounded() * anchorNudgeSec
        rallyStartTimeSec = min(max(0, snapped), max(anchorDurationSec, 0))
        anchorPreviewTimeSec = rallyStartTimeSec ?? anchorPreviewTimeSec
    }

    private func clearRallyStartAnchor() {
        rallyStartTimeSec = nil
    }

    private func seekStereoPlayer(to timeSec: Double) {
        guard let stereoPlayer else { return }
        let t = CMTime(seconds: timeSec, preferredTimescale: 600)
        stereoPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func updateShotType(_ id: UUID, to newType: StereoShotType) {
        guard let idx = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[idx].type = newType
        shots[idx].isUserEdited = true
        shots[idx].confidence = max(shots[idx].confidence, 0.95)
        selectedShotID = id
    }

    private struct StereoCalibrationExportPoint: Codable {
        var x: Double
        var y: Double
    }

    private struct StereoCalibrationExportPoint3D: Codable {
        var x: Double
        var y: Double
        var z: Double
    }

    private struct StereoCalibrationCameraExport: Codable {
        var camera: String
        var sourceName: String
        var imagePixelWidth: Int
        var imagePixelHeight: Int
        var firstCSVFrameIndex: Int?
        var calibrationLabels: [String]
        var imagePointsPx: [StereoCalibrationExportPoint]
        var worldPointsM: [StereoCalibrationExportPoint]
        var worldPoints3D: [StereoCalibrationExportPoint3D]
        var H_world_to_image: [[Double]]
        var H_image_to_world: [[Double]]
    }

    private struct StereoCalibrationExportPayload: Codable {
        var version: Int
        var createdAtISO8601: String
        var mode: String
        var matchTitle: String?
        var csvLabel: String?
        var rallyStartTimeSec: Double?
        var cameraA: StereoCalibrationCameraExport
        var cameraB: StereoCalibrationCameraExport
    }

    private func exportStereoCalibrationAndShare() {
        guard let url = writeStereoCalibrationJSON() else { return }
        exportURL = url
        showExportSheet = true
    }

    private func writeStereoCalibrationJSON() -> URL? {
        guard previewA != nil, previewB != nil else {
            errorText = "Please load both videos first."
            return nil
        }
        guard tapsA.count >= 6, tapsB.count >= 6 else {
            errorText = "Please finish the 6-point calibration on both videos first."
            return nil
        }
        guard let H_A = homography(from: tapsA), let H_B = homography(from: tapsB) else {
            errorText = "Failed to compute calibration homography for one or both cameras."
            return nil
        }

        let labels = StereoCourtAnchor.allCases.map(\.shortLabel)
        let world2D: [CGPoint] = StereoCourtAnchor.allCases.map { $0.worldMeters2D() }
        let world3D: [SIMD3<Double>] = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(Double(court.W), 0, 0),
            SIMD3<Double>(Double(court.W), Double(court.L), 0),
            SIMD3<Double>(0, Double(court.L), 0),
            SIMD3<Double>(0, Double(court.halfL), netPostHeightMeters),
            SIMD3<Double>(Double(court.W), Double(court.halfL), netPostHeightMeters)
        ]

        func rows(_ h: simd_double3x3) -> [[Double]] {
            [
                [h[0,0], h[0,1], h[0,2]],
                [h[1,0], h[1,1], h[1,2]],
                [h[2,0], h[2,1], h[2,2]]
            ]
        }

        func makeCameraExport(camera: String, url: URL?, meta: StereoVideoMeta, taps: [CGPoint], H: Homography, firstCSVFrameIndex: Int?) -> StereoCalibrationCameraExport {
            let size = meta.previewSize == .zero
                ? CGSize(width: abs(meta.orientedRect.width), height: abs(meta.orientedRect.height))
                : meta.previewSize
            return StereoCalibrationCameraExport(
                camera: camera,
                sourceName: url?.lastPathComponent ?? camera,
                imagePixelWidth: Int(size.width.rounded()),
                imagePixelHeight: Int(size.height.rounded()),
                firstCSVFrameIndex: firstCSVFrameIndex,
                calibrationLabels: labels,
                imagePointsPx: Array(taps.prefix(6)).map { StereoCalibrationExportPoint(x: Double($0.x), y: Double($0.y)) },
                worldPointsM: world2D.map { StereoCalibrationExportPoint(x: Double($0.x), y: Double($0.y)) },
                worldPoints3D: world3D.map { StereoCalibrationExportPoint3D(x: $0.x, y: $0.y, z: $0.z) },
                H_world_to_image: rows(H.h),
                H_image_to_world: rows(H.h.inverse)
            )
        }

        let payload = StereoCalibrationExportPayload(
            version: 1,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
            mode: "dualCameraAssisted6Point",
            matchTitle: saveDraftTitle.isEmpty ? nil : saveDraftTitle,
            csvLabel: stereoCSVURL?.lastPathComponent,
            rallyStartTimeSec: rallyStartTimeSec,
            cameraA: makeCameraExport(camera: "A", url: videoAURL, meta: metaA, taps: tapsA, H: H_A, firstCSVFrameIndex: stereoRows.map(\.frameA).min()),
            cameraB: makeCameraExport(camera: "B", url: videoBURL, meta: metaB, taps: tapsB, H: H_B, firstCSVFrameIndex: stereoRows.map(\.frameB).min())
        )

        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(payload)
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let out = tmp.appendingPathComponent("dual_camera_calibration_\(UUID().uuidString).json")
            try data.write(to: out, options: [.atomic])
            return out
        } catch {
            errorText = "Failed to write calibration JSON: \(error.localizedDescription)"
            return nil
        }
    }

    private func loadSavedMatches() {
        guard let data = try? Data(contentsOf: savedMatchesFileURL) else {
            savedMatches = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([SavedStereoMatch].self, from: data)
            savedMatches = decoded.sorted { $0.savedAt > $1.savedAt }
        } catch {
            savedMatches = []
        }
    }

    private func writeMatches(_ matches: [SavedStereoMatch]) throws {
        let data = try JSONEncoder().encode(matches)
        try data.write(to: savedMatchesFileURL, options: .atomic)
        savedMatches = matches
    }

    private func mediaDirectory(_ id: UUID) -> URL {
        savedMatchesFileURL.deletingLastPathComponent().appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func keepVideo(_ source: URL?, in directory: URL, slot: String, existing: String?, created: inout [URL]) throws -> String? {
        guard let source else { return existing }
        let fm = FileManager.default
        if let existing, source.standardizedFileURL == directory.appendingPathComponent(existing).standardizedFileURL { return existing }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = slot + "-" + source.lastPathComponent
        let destination = directory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: destination.path) {
            created.append(destination)
            do {
                try fm.linkItem(at: source, to: destination)
            } catch {
                try fm.copyItem(at: source, to: destination)
            }
        }
        return filename
    }

    private func persistCurrentMatch(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? suggestedMatchTitle : trimmed
        let id = currentSavedMatchID ?? UUID()
        let previous = savedMatches.first { $0.id == id }
        let directory = mediaDirectory(id)
        var created: [URL] = []
        var committed = false
        defer {
            if !committed { for url in created { try? FileManager.default.removeItem(at: url) } }
        }
        let fileA = try keepVideo(videoAURL, in: directory, slot: "A", existing: previous?.videoAFile, created: &created)
        let fileB = try keepVideo(videoBURL, in: directory, slot: "B", existing: previous?.videoBFile, created: &created)
        let match = SavedStereoMatch(
            id: id,
            title: title,
            savedAt: Date(),
            videoALabel: previous?.videoALabel ?? videoAURL?.lastPathComponent ?? "Video A",
            videoBLabel: previous?.videoBLabel ?? videoBURL?.lastPathComponent ?? "Video B",
            csvLabel: stereoCSVURL?.lastPathComponent ?? previous?.csvLabel ?? "Dual-View CSV",
            totalPointCount: points3D.isEmpty ? currentLoadedTotalPointCount : points3D.count,
            validPointCount: validPointCount,
            meanReprojectionError: meanReprojectionError,
            peakHeight: maxHeight,
            shots: shots.map(SavedStereoShotEvent.init(from:)),
            videoAFile: fileA,
            videoBFile: fileB,
            videoABookmark: makeSecurityBookmark(for: videoAURL) ?? previous?.videoABookmark,
            videoBBookmark: makeSecurityBookmark(for: videoBURL) ?? previous?.videoBBookmark,
            csvBookmark: makeSecurityBookmark(for: stereoCSVURL),
            tapsA: tapsA.map(SavedCGPoint.init),
            tapsB: tapsB.map(SavedCGPoint.init),
            rows: stereoRows.map(SavedStereoCSVRow.init),
            rallyStartTimeSec: rallyStartTimeSec
        )

        try writeMatches([match] + savedMatches.filter { $0.id != id })
        committed = true
        currentSavedMatchID = id
        saveDraftTitle = title
    }

    private func loadSavedMatch(_ match: SavedStereoMatch) {
        clearAll()
        currentSavedMatchID = match.id
        showReviewMode = false
        saveDraftTitle = match.title
        shots = match.shots.map { $0.shotEvent }
        selectedShotID = shots.first?.id
        points3D.removeAll()
        rallyStartTimeSec = match.rallyStartTimeSec
        restoreSavedMedia(for: match)
    }

    private func deleteSavedMatch(_ id: UUID) {
        do {
            try writeMatches(savedMatches.filter { $0.id != id })
        } catch {
            errorText = error.localizedDescription
            return
        }
        try? FileManager.default.removeItem(at: mediaDirectory(id))
        if currentSavedMatchID == id {
            currentSavedMatchID = nil
            saveDraftTitle = ""
        }

    }

    private func clearAll() {
        anchorPlayback = .ready
        videoAURL = nil
        videoBURL = nil
        stereoCSVURL = nil
        previewA = nil
        previewB = nil
        metaA = .empty
        metaB = .empty
        tapsA.removeAll()
        tapsB.removeAll()
        stereoRows.removeAll()
        points3D.removeAll()
        shots.removeAll()
        selectedShotID = nil
        stereoPlayer?.pause()
        detachAnchorTimeObserver()
        stereoPlayer = nil
        rallyStartTimeSec = nil
        anchorPreviewTimeSec = 0
        anchorDurationSec = 0
        currentSavedMatchID = nil
        saveDraftTitle = ""
    }

    private func loadVideo(url: URL, slot: StereoVideoSlot?, resetCalibration: Bool = true, resetAnalysis: Bool = true, clearCurrentMatch: Bool = true, restoring matchID: UUID? = nil) async {
        guard let slot else { return }
        do {
            let asset = AVAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else {
                throw NSError(domain: "StereoVideo", code: -1, userInfo: [NSLocalizedDescriptionKey: "Selected file has no video track."])
            }
            let natural = track.naturalSize
            let pref = track.preferredTransform
            let orientedRect = CGRect(origin: .zero, size: natural).applying(pref).standardized

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1600)
            let cg = try generator.copyCGImage(at: .zero, actualTime: nil)
            let image = UIImage(cgImage: cg)
            let meta = StereoVideoMeta(rawSize: natural, preferredTransform: pref, orientedRect: orientedRect, previewSize: image.size)
            let assetDurationSec = max(asset.duration.seconds, track.timeRange.duration.seconds)
            let playerItem = AVPlayerItem(asset: asset)

            await MainActor.run {
                if let matchID, currentSavedMatchID != matchID { return }
                analysisTask?.cancel()
                switch slot {
                case .a:
                    anchorPlayback = .ready
                    videoAURL = url
                    previewA = image
                    metaA = meta
                    if resetCalibration { tapsA.removeAll() }
                    stereoPlayer?.pause()
                    detachAnchorTimeObserver()
                    stereoPlayer = AVPlayer(playerItem: playerItem)
                    anchorDurationSec = assetDurationSec.isFinite && assetDurationSec > 0 ? assetDurationSec : anchorDurationSec
                    anchorPreviewTimeSec = 0
                    stereoPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    attachAnchorTimeObserverIfNeeded()
                case .b:
                    videoBURL = url
                    previewB = image
                    metaB = meta
                    if resetCalibration { tapsB.removeAll() }
                }
                if resetAnalysis {
                    points3D.removeAll()
                    shots.removeAll()
                    selectedShotID = nil
                    rallyStartTimeSec = nil
                }
                if clearCurrentMatch {
                    currentSavedMatchID = nil
                }
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
            }
        }
    }

    private func loadStereoCSV(url: URL, resetAnalysis: Bool = true, clearCurrentMatch: Bool = true) async {
        var accessed = false
        if url.startAccessingSecurityScopedResource() { accessed = true }
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                throw NSError(domain: "StereoCSV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot decode CSV as UTF-8 or ASCII."])
            }
            let rows = try parseStereoCSV(text)
            await MainActor.run {
                analysisTask?.cancel()
                stereoCSVURL = url
                stereoRows = rows
                if resetAnalysis {
                    points3D.removeAll()
                    shots.removeAll()
                    selectedShotID = nil
                }
                if clearCurrentMatch {
                    currentSavedMatchID = nil
                }
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
            }
        }
    }

    private struct StereoDisplayTrackSample {
        let frame: Int
        let x: Double
        let y: Double
        let vis: Int
    }


    private func parseStereoCSV(_ text: String) throws -> [StereoCSVRow] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else {
            throw NSError(domain: "StereoCSV", code: -2, userInfo: [NSLocalizedDescriptionKey: "CSV has no data."])
        }

        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func idx(_ key: String) -> Int? { header.firstIndex(of: key.lowercased()) }

        let required = [
            "stereoindex", "timesec", "frame_a", "visibility_a", "x_a", "y_a", "timesec_a",
            "frame_b", "visibility_b", "x_b", "y_b", "timesec_b", "timedeltams"
        ]
        for key in required where idx(key) == nil {
            throw NSError(domain: "StereoCSV", code: -3, userInfo: [NSLocalizedDescriptionKey: "CSV header is missing \(key)."])
        }

        func parseInt(_ raw: Substring) -> Int {
            let field = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let integer = Int(field) { return integer }
            // A missing Camera B match makes pandas export this column as floats.
            return Double(field).flatMap { Int(exactly: $0) } ?? 0
        }

        func parseDouble(_ raw: Substring) -> Double {
            let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            return value.flatMap { $0.isFinite ? $0 : nil } ?? 0
        }

        let iStereo = idx("stereoindex")!
        let iTime = idx("timesec")!
        let iFrameA = idx("frame_a")!
        let iVisA = idx("visibility_a")!
        let iXA = idx("x_a")!
        let iYA = idx("y_a")!
        let iTimeA = idx("timesec_a")!
        let iFrameB = idx("frame_b")!
        let iVisB = idx("visibility_b")!
        let iXB = idx("x_b")!
        let iYB = idx("y_b")!
        let iTimeB = idx("timesec_b")!
        let iDelta = idx("timedeltams")!

        var out: [StereoCSVRow] = []
        out.reserveCapacity(lines.count - 1)

        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= header.count else { continue }
            out.append(
                StereoCSVRow(
                    stereoIndex: parseInt(cols[iStereo]),
                    timeSec: parseDouble(cols[iTime]),
                    frameA: parseInt(cols[iFrameA]),
                    visibilityA: parseInt(cols[iVisA]),
                    xA: parseDouble(cols[iXA]),
                    yA: parseDouble(cols[iYA]),
                    timeSecA: parseDouble(cols[iTimeA]),
                    frameB: parseInt(cols[iFrameB]),
                    visibilityB: parseInt(cols[iVisB]),
                    xB: parseDouble(cols[iXB]),
                    yB: parseDouble(cols[iYB]),
                    timeSecB: parseDouble(cols[iTimeB]),
                    timeDeltaMs: parseDouble(cols[iDelta])
                )
            )
        }

        guard !out.isEmpty else {
            throw NSError(domain: "StereoCSV", code: -4, userInfo: [NSLocalizedDescriptionKey: "The CSV contains no complete dual-camera data rows."])
        }
        return out.sorted { $0.stereoIndex < $1.stereoIndex }
    }

    @MainActor
    private func startAssistedAnalysis() {
        guard analysisProgress == nil else { return }
        guard missingInputs.isEmpty else {
            errorText = missingInputs.joined(separator: "\n")
            return
        }
        pauseAnchorPlayback()
        analysisProgress = 0
        analysisTask = Task { @MainActor in
            defer {
                analysisProgress = nil
                analysisTask = nil
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            await runStereoReconstruction()
        }
    }

    @MainActor
    private func runStereoReconstruction() async {
        guard let H_A = homography(from: tapsA), let H_B = homography(from: tapsB) else {
            errorText = "Could not map the court corners. Check the first four points in both videos, then run again."
            return
        }
        guard let P_A = cameraMatrix(from: tapsA), let P_B = cameraMatrix(from: tapsB) else {
            errorText = "Could not reconstruct the camera positions. Check the two net-post tops in both calibrations, then run again."
            return
        }

        let imgPtsA = convertStereoRowsToPreviewPixels(stereoRows, meta: metaA, slot: .a)
        let imgPtsB = convertStereoRowsToPreviewPixels(stereoRows, meta: metaB, slot: .b)

        var recon: [Stereo3DPoint] = []
        recon.reserveCapacity(stereoRows.count)

        let baseFrameA = baseFrameIndex(for: .a)
        let baseFrameB = baseFrameIndex(for: .b)

        let rows = stereoRows
        for i in rows.indices {
            if i.isMultiple(of: 64) {
                analysisProgress = 0.85 * Double(i) / Double(rows.count)
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            let row = rows[i]
            let pA = imgPtsA[i]
            let pB = imgPtsB[i]
            let gA = pA.flatMap { H_A.unproject($0) }
            let gB = pB.flatMap { H_B.unproject($0) }
            let frameA = max(0, row.frameA - baseFrameA)
            let frameB = max(0, row.frameB - baseFrameB)

            var world3D: SIMD3<Double>? = nil
            var reprojError: Double? = nil

            if abs(row.timeDeltaMs) <= maxTimeDeltaMs,
               let pA, let pB,
               let tri = triangulate(imageA: pA, imageB: pB, cameraA: P_A, cameraB: P_B) {
                let pa = P_A.project(tri)
                let pb = P_B.project(tri)
                let errA = pa.map { hypot($0.x - pA.x, $0.y - pA.y) } ?? 1_000
                let errB = pb.map { hypot($0.x - pB.x, $0.y - pB.y) } ?? 1_000
                let err = (errA + errB) / 2.0
                if err <= maxReprojectionErrorPx {
                    world3D = SIMD3<Double>(
                        min(max(-1.0, tri.x), Double(court.W) + 1.0),
                        min(max(-1.0, tri.y), Double(court.L) + 1.0),
                        min(max(0.0, tri.z), 12.0)
                    )
                    reprojError = err
                }
            }

            recon.append(
                Stereo3DPoint(
                    stereoIndex: row.stereoIndex,
                    timeSec: row.timeSec,
                    frameA: frameA,
                    frameB: frameB,
                    imageA: pA,
                    imageB: pB,
                    groundA: gA,
                    groundB: gB,
                    world3D: world3D,
                    reprojectionErrorPx: reprojError
                )
            )
        }

        analysisProgress = 0.85
        await Task.yield()
        guard !Task.isCancelled else { return }
        recon = smoothedStereoPoints(recon)
        let framePixelsA = frameIndexedPixels(from: stereoRows, meta: metaA, slot: .a)
        let framePixelsB = frameIndexedPixels(from: stereoRows, meta: metaB, slot: .b)
        let frameGroundA = framePixelsA.map { $0.flatMap { H_A.unproject($0) } }
        let frameGroundB = framePixelsB.map { $0.flatMap { H_B.unproject($0) } }
        let events = await buildDualCameraAssistedEvents(
            recon: recon,
            rows: stereoRows,
            framePixelsA: framePixelsA,
            framePixelsB: framePixelsB,
            frameGroundA: frameGroundA,
            frameGroundB: frameGroundB,
            fps: estimatedFPS(),
            rallyStartTimeSec: rallyStartTimeSec
        )

        guard !Task.isCancelled else { return }
        points3D = recon
        shots = events
        selectedShotID = events.first?.id

        let reconstructedCount = recon.compactMap { $0.world3D }.count
        if reconstructedCount == 0 {
            errorText = "No valid 3D points. Check that both clips match the CSV, the frames are synchronized and the six points mark the same court locations."
        } else if events.isEmpty {
            errorText = "Analysis complete. The trajectory contains \(reconstructedCount) valid 3D points. No shots were detected in this interval."
        } else {
            showReviewMode = true
        }
        if guideActive && !showSavedMatchesFirst { guideActive = false }
    }

    private func homography(from taps: [CGPoint]) -> Homography? {
        guard taps.count >= 4 else { return nil }
        let world = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: court.W, y: 0),
            CGPoint(x: court.W, y: court.L),
            CGPoint(x: 0, y: court.L)
        ]
        return Homography.estimate(world: world, image: Array(taps.prefix(4)))
    }

    private func cameraMatrix(from taps: [CGPoint]) -> StereoCameraMatrix? {
        guard taps.count >= 6 else { return nil }
        let world: [SIMD3<Double>] = StereoCourtAnchor.allCases.map {
            let p = $0.worldMeters3D(netHeight: Float(netPostHeightMeters))
            return SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
        }
        let image = Array(taps.prefix(6))
        var A: [[Double]] = []
        var b: [Double] = []
        A.reserveCapacity(world.count * 2)
        b.reserveCapacity(world.count * 2)

        for (X, p) in zip(world, image) {
            let x = X.x, y = X.y, z = X.z
            let u = Double(p.x), v = Double(p.y)
            A.append([x, y, z, 1, 0, 0, 0, 0, -u * x, -u * y, -u * z])
            b.append(u)
            A.append([0, 0, 0, 0, x, y, z, 1, -v * x, -v * y, -v * z])
            b.append(v)
        }

        guard let q = solveLeastSquares(A: A, b: b), q.count == 11 else { return nil }
        return StereoCameraMatrix(rows: [
            SIMD4<Double>(q[0], q[1], q[2], q[3]),
            SIMD4<Double>(q[4], q[5], q[6], q[7]),
            SIMD4<Double>(q[8], q[9], q[10], 1.0)
        ])
    }

    private func convertStereoRowsToPreviewPixels(_ rows: [StereoCSVRow], meta: StereoVideoMeta, slot: StereoVideoSlot) -> [CGPoint?] {
        let displaySize = meta.orientedRect.size == .zero
            ? meta.previewSize : meta.orientedRect.size
        let sx = displaySize.width > 0 ? meta.previewSize.width / displaySize.width : 1
        let sy = displaySize.height > 0 ? meta.previewSize.height / displaySize.height : 1

        func inBounds(_ p: CGPoint, size: CGSize) -> Bool {
            p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height
        }

        var rawInBounds = 0
        var transformedInBounds = 0
        var transformed: [CGPoint?] = Array(repeating: nil, count: rows.count)

        for (idx, row) in rows.enumerated() {
            let vis: Int
            let raw: CGPoint
            switch slot {
            case .a:
                vis = row.visibilityA
                raw = CGPoint(x: row.xA, y: row.yA)
            case .b:
                vis = row.visibilityB
                raw = CGPoint(x: row.xB, y: row.yB)
            }

            guard vis == 1, raw != .zero else { continue }
            if inBounds(raw, size: displaySize) { rawInBounds += 1 }

            let p2 = raw.applying(meta.preferredTransform)
            let po = CGPoint(x: p2.x - meta.orientedRect.origin.x, y: p2.y - meta.orientedRect.origin.y)
            transformed[idx] = po
            if inBounds(po, size: displaySize) { transformedInBounds += 1 }
        }

        // Prefer raw CSV coordinates on ties. In the user's dual-camera runs, timing matches but
        // the overlay can shift consistently right/down if we over-apply preferredTransform to
        // coordinates that are already in the displayed orientation.
        let transformClearlyBetter = transformedInBounds >= rawInBounds + max(8, rows.count / 20)
        let useTransform = transformClearlyBetter && meta.rawSize != .zero

        return rows.enumerated().map { idx, row in
            let vis: Int
            let raw: CGPoint
            switch slot {
            case .a:
                vis = row.visibilityA
                raw = CGPoint(x: row.xA, y: row.yA)
            case .b:
                vis = row.visibilityB
                raw = CGPoint(x: row.xB, y: row.yB)
            }
            guard vis == 1, raw != .zero else { return nil }
            let display = useTransform ? (transformed[idx] ?? raw) : raw
            return CGPoint(x: display.x * sx, y: display.y * sy)
        }
    }

    private func convertStereoRowsToDisplayPixelsLikeSingleCamera(_ rows: [StereoCSVRow], meta: StereoVideoMeta, slot: StereoVideoSlot) -> [CGPoint?] {
        let orientedSize = meta.previewSize == .zero
            ? CGSize(width: abs(meta.orientedRect.width), height: abs(meta.orientedRect.height))
            : meta.previewSize

        func inBounds(_ p: CGPoint, size: CGSize) -> Bool {
            p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height
        }

        var rawInBounds = 0
        var transformedInBounds = 0
        var transformed: [CGPoint?] = Array(repeating: nil, count: rows.count)

        for (idx, row) in rows.enumerated() {
            let vis: Int
            let raw: CGPoint
            switch slot {
            case .a:
                vis = row.visibilityA
                raw = CGPoint(x: row.xA, y: row.yA)
            case .b:
                vis = row.visibilityB
                raw = CGPoint(x: row.xB, y: row.yB)
            }

            guard vis == 1, raw != .zero else { continue }
            if inBounds(raw, size: orientedSize) { rawInBounds += 1 }

            let p2 = raw.applying(meta.preferredTransform)
            let po = CGPoint(x: p2.x - meta.orientedRect.origin.x, y: p2.y - meta.orientedRect.origin.y)
            transformed[idx] = po
            if inBounds(po, size: orientedSize) { transformedInBounds += 1 }
        }

        // Match the single-camera importer exactly: on ties, prefer the transformed mapping when
        // video metadata is available. This keeps the dual review overlay in the same display space
        // as the single-camera mode that the user already verified as visually correct.
        let useTransform = transformedInBounds >= rawInBounds && meta.rawSize != .zero

        return rows.enumerated().map { idx, row in
            let vis: Int
            let raw: CGPoint
            switch slot {
            case .a:
                vis = row.visibilityA
                raw = CGPoint(x: row.xA, y: row.yA)
            case .b:
                vis = row.visibilityB
                raw = CGPoint(x: row.xB, y: row.yB)
            }
            guard vis == 1, raw != .zero else { return nil }
            return useTransform ? transformed[idx] : raw
        }
    }

    private func frameIndexedPixels(from rows: [StereoCSVRow], meta: StereoVideoMeta, slot: StereoVideoSlot) -> [CGPoint?] {
        let rowPixels = convertStereoRowsToPreviewPixels(rows, meta: meta, slot: slot)
        let baseFrame = rows.map { slot == .a ? $0.frameA : $0.frameB }.min() ?? 0
        let maxFrame = rows.reduce(0) { partial, row in
            let raw = slot == .a ? row.frameA : row.frameB
            return max(partial, max(0, raw - baseFrame))
        }
        guard maxFrame >= 0 else { return [] }
        var out: [CGPoint?] = Array(repeating: nil, count: maxFrame + 1)
        for (idx, row) in rows.enumerated() {
            let rawFrame = slot == .a ? row.frameA : row.frameB
            let frame = max(0, rawFrame - baseFrame)
            guard out.indices.contains(frame) else { continue }
            if let p = rowPixels[idx] { out[frame] = p }
        }
        return out
    }


    private func frameIndexedPixelsForReview(from points: [Stereo3DPoint], slot: StereoVideoSlot) -> [CGPoint?] {
        guard !points.isEmpty else { return [] }
        let maxFrame = points.reduce(0) { partial, p in
            max(partial, slot == .a ? p.frameA : p.frameB)
        }
        var out: [CGPoint?] = Array(repeating: nil, count: maxFrame + 1)
        for p in points {
            let frame = slot == .a ? p.frameA : p.frameB
            guard out.indices.contains(frame) else { continue }
            let px = (slot == .a ? p.imageA : p.imageB)
            if let px { out[frame] = px }
        }
        return out
    }

    private func cleanedReviewPixels(framePixelsA: [CGPoint?], fps: Double) -> [CGPoint?] {
        guard !framePixelsA.isEmpty else { return [] }
        let px0 = stereoSuppressLoopedRepeats(framePixelsA)
        let px1 = stereoRejectPixelOutliers(px0, fps: fps)
        let px2 = stereoMedianFilter(px1, radius: 1)
        let px3 = stereoInterpolateShortGaps(px2, maxGap: max(1, Int(round(0.10 * fps))))
        return stereoMovingAverage(px3, radius: 1)
    }

    private func lightReviewPixels(framePixelsA: [CGPoint?], fps: Double) -> [CGPoint?] {
        guard !framePixelsA.isEmpty else { return [] }
        let px0 = stereoSuppressLoopedRepeats(framePixelsA)
        let px1 = stereoRejectPixelOutliers(px0, fps: fps)
        return stereoMedianFilter(px1, radius: 1)
    }

    private func triangulate(imageA: CGPoint, imageB: CGPoint, cameraA: StereoCameraMatrix, cameraB: StereoCameraMatrix) -> SIMD3<Double>? {
        let rowsA = cameraA.rows
        let rowsB = cameraB.rows
        let uA = Double(imageA.x), vA = Double(imageA.y)
        let uB = Double(imageB.x), vB = Double(imageB.y)

        let A = [
            [rowsA[0].x - uA * rowsA[2].x, rowsA[0].y - uA * rowsA[2].y, rowsA[0].z - uA * rowsA[2].z],
            [rowsA[1].x - vA * rowsA[2].x, rowsA[1].y - vA * rowsA[2].y, rowsA[1].z - vA * rowsA[2].z],
            [rowsB[0].x - uB * rowsB[2].x, rowsB[0].y - uB * rowsB[2].y, rowsB[0].z - uB * rowsB[2].z],
            [rowsB[1].x - vB * rowsB[2].x, rowsB[1].y - vB * rowsB[2].y, rowsB[1].z - vB * rowsB[2].z]
        ]
        let b = [
            uA * rowsA[2].w - rowsA[0].w,
            vA * rowsA[2].w - rowsA[1].w,
            uB * rowsB[2].w - rowsB[0].w,
            vB * rowsB[2].w - rowsB[1].w
        ]
        guard let xyz = solveLeastSquares(A: A, b: b), xyz.count == 3 else { return nil }
        return SIMD3<Double>(xyz[0], xyz[1], xyz[2])
    }

    private func solveLeastSquares(A: [[Double]], b: [Double]) -> [Double]? {
        guard !A.isEmpty, A.count == b.count else { return nil }
        let cols = A[0].count
        guard cols > 0 else { return nil }

        var ata = Array(repeating: Array(repeating: 0.0, count: cols), count: cols)
        var atb = Array(repeating: 0.0, count: cols)

        for i in 0..<A.count {
            for r in 0..<cols {
                atb[r] += A[i][r] * b[i]
                for c in 0..<cols {
                    ata[r][c] += A[i][r] * A[i][c]
                }
            }
        }

        for i in 0..<cols { ata[i][i] += 1e-8 }
        return gaussianSolve(A: ata, b: atb)
    }

    private func gaussianSolve(A: [[Double]], b: [Double]) -> [Double]? {
        let n = A.count
        guard n > 0, A.allSatisfy({ $0.count == n }), b.count == n else { return nil }

        var M = A
        var y = b

        for k in 0..<n {
            var pivotRow = k
            var maxVal = abs(M[k][k])
            if k + 1 < n {
                for r in (k + 1)..<n {
                    if abs(M[r][k]) > maxVal {
                        maxVal = abs(M[r][k])
                        pivotRow = r
                    }
                }
            }
            if maxVal < 1e-12 { return nil }
            if pivotRow != k {
                M.swapAt(k, pivotRow)
                y.swapAt(k, pivotRow)
            }

            let piv = M[k][k]
            for j in k..<n { M[k][j] /= piv }
            y[k] /= piv

            for i in 0..<n where i != k {
                let f = M[i][k]
                if abs(f) < 1e-12 { continue }
                for j in k..<n { M[i][j] -= f * M[k][j] }
                y[i] -= f * y[k]
            }
        }

        return y
    }

    private func smoothedStereoPoints(_ pts: [Stereo3DPoint]) -> [Stereo3DPoint] {
        guard pts.count >= 3 else { return pts }
        var out = pts
        for i in 0..<pts.count {
            guard pts[i].world3D != nil else { continue }
            var vals: [SIMD3<Double>] = []
            for j in max(0, i - 2)...min(pts.count - 1, i + 2) {
                if let p = pts[j].world3D { vals.append(p) }
            }
            guard !vals.isEmpty else { continue }
            let mean = vals.reduce(SIMD3<Double>(repeating: 0), +) / Double(vals.count)
            out[i] = Stereo3DPoint(
                stereoIndex: pts[i].stereoIndex,
                timeSec: pts[i].timeSec,
                frameA: pts[i].frameA,
                frameB: pts[i].frameB,
                imageA: pts[i].imageA,
                imageB: pts[i].imageB,
                groundA: pts[i].groundA,
                groundB: pts[i].groundB,
                world3D: mean,
                reprojectionErrorPx: pts[i].reprojectionErrorPx
            )
        }
        return out
    }

    private struct StereoShotSegment2D {
        let startFrame: Int
        let endFrame: Int
        let startPx: CGPoint
        let endPx: CGPoint
        let startWorld: CGPoint
        let endWorld: CGPoint
        let durationSec: Double
        let isLanding: Bool
    }

    private func buildDualCameraAssistedEvents(recon: [Stereo3DPoint], rows: [StereoCSVRow], framePixelsA: [CGPoint?], framePixelsB: [CGPoint?], frameGroundA: [CGPoint?], frameGroundB: [CGPoint?], fps: Double, rallyStartTimeSec: Double?) async -> [StereoShotEvent] {
        guard !framePixelsA.isEmpty else { return [] }

        let anchorFrame = max(0, Int(round((rallyStartTimeSec ?? 0) * max(1.0, fps))))
        let px0 = stereoSuppressLoopedRepeats(framePixelsA)
        let px1 = stereoRejectPixelOutliers(px0, fps: fps)
        let px2 = stereoMedianFilter(px1, radius: 1)
        let px3 = stereoInterpolateShortGaps(px2, maxGap: max(1, Int(round(0.10 * fps))))
        let px4 = stereoMovingAverage(px3, radius: 1)
        let px5 = stereoTrimInitialHoldNoise(px4, fps: fps)
        let cleanedPx: [CGPoint?] = px5.enumerated().map { idx, point in
            idx < anchorFrame ? nil : point
        }

        let world0 = frameGroundA.enumerated().map { idx, p in
            idx < cleanedPx.count ? (cleanedPx[idx] == nil ? nil : p) : nil
        }
        let world1 = stereoInterpolateShortGaps(world0, maxGap: max(1, Int(round(0.10 * fps))))
        let cleanedWorld = stereoMovingAverage(world1, radius: 1)

        let seedHits0 = stereoDetectHitFramesImageSpace(cleanedPx, fps: fps)
        var hitFrames = stereoRefineHitFramesWithPhysics(cleanedPx, fps: fps, seedHits: seedHits0)
        if let anchoredHit = anchoredServeHitFrame(points: cleanedPx, anchorFrame: anchorFrame, fps: fps) {
            hitFrames.insert(anchoredHit, at: 0)
            hitFrames = Array(Set(hitFrames)).sorted()
        }
        let landingFrames = stereoDetectLandingFramesImageSpace(cleanedPx, worldByFrame: cleanedWorld, fps: fps)
        let segments = stereoBuildShotSegmentsFromHits(pixel: cleanedPx, world: cleanedWorld, fps: fps, hitFrames: hitFrames, landingFrames: landingFrames)

        var events: [DualAssistCandidate] = []
        events.reserveCapacity(segments.count)
        for (index, seg) in segments.enumerated() {
            if index.isMultiple(of: 4) {
                analysisProgress = 0.9 + 0.1 * Double(index) / Double(segments.count)
                await Task.yield()
                guard !Task.isCancelled else { return [] }
            }
            let (baseType, baseConf) = stereoClassifyShotSegment(startPx: seg.startPx, endPx: seg.endPx, startWorld: seg.startWorld, endWorld: seg.endWorld, durationSec: seg.durationSec, isLanding: seg.isLanding)
            let seg3D = recon.filter { p in
                p.frameA >= seg.startFrame && p.frameA <= seg.endFrame && p.world3D != nil
            }
            let assist = dualAssistMetrics(for: seg, rows: rows, framePixelsA: framePixelsA, framePixelsB: framePixelsB, frameGroundA: frameGroundA, frameGroundB: frameGroundB, recon: recon)
            let stereoReliable = stereo3DIsReliable(segment3D: seg3D, assist: assist)
            let refinedType = stereoReliable ? refineStereoType(baseType: baseType, segment3D: seg3D, durationSec: seg.durationSec) : baseType
            let chosenType: StereoShotType
            if stereoReliable, assist.supportScore >= 0.56, !seg3D.isEmpty {
                chosenType = refinedType
            } else if baseType != .unknown {
                chosenType = baseType
            } else {
                chosenType = stereoReliable ? refinedType : .unknown
            }

            let rawPeakHeight = seg3D.compactMap { $0.world3D?.z }.max()
            let peakHeight = stereoReliable ? max(0, rawPeakHeight ?? 0) : 0
            let netHeight = stereoReliable ? estimateNetHeight(seg3D.compactMap { p in
                guard let w = p.world3D else { return nil }
                return (p.timeSec, w)
            }) : nil

            let base = max(baseConf, stereoReliable ? (baseConf + 0.05) : baseConf)
            let supportBump = stereoReliable ? ((assist.supportScore - 0.50) * 0.22) : ((assist.supportScore - 0.50) * 0.10)
            let chosenConf = min(0.98, max(0.34, base + supportBump))

            let start3D = stereoReliable
                ? (nearestStereoWorld3D(in: recon, aroundFrameA: seg.startFrame) ?? SIMD3<Double>(Double(seg.startWorld.x), Double(seg.startWorld.y), 0))
                : SIMD3<Double>(Double(seg.startWorld.x), Double(seg.startWorld.y), 0)
            let end3D = stereoReliable
                ? (nearestStereoWorld3D(in: recon, aroundFrameA: seg.endFrame) ?? SIMD3<Double>(Double(seg.endWorld.x), Double(seg.endWorld.y), 0))
                : SIMD3<Double>(Double(seg.endWorld.x), Double(seg.endWorld.y), 0)

            let dxPx = Double(seg.endPx.x - seg.startPx.x)
            let dyPx = Double(seg.endPx.y - seg.startPx.y)
            let cue = DualAssistMotionCue(
                startPx: seg.startPx,
                endPx: seg.endPx,
                dxPx: dxPx,
                dyPx: dyPx,
                travelPx: hypot(dxPx, dyPx),
                durationSec: seg.durationSec
            )

            let shot = StereoShotEvent(
                startTime: Double(seg.startFrame) / max(1.0, fps),
                endTime: Double(seg.endFrame) / max(1.0, fps),
                startFrameA: seg.startFrame,
                endFrameA: seg.endFrame,
                startPoint: start3D,
                endPoint: end3D,
                peakHeight: peakHeight,
                netHeight: netHeight,
                type: chosenType,
                confidence: chosenConf
            )
            events.append(DualAssistCandidate(shot: shot, cue: cue))
        }
        return postProcessDualAssistEvents(events, rallyStartTimeSec: rallyStartTimeSec)
    }

    private func anchoredServeHitFrame(points: [CGPoint?], anchorFrame: Int, fps: Double) -> Int? {
        guard anchorFrame > 0 else { return nil }
        let radius = max(4, Int(round(0.18 * fps)))
        if let candidate = stereoNearestValidPoint(in: points, around: anchorFrame, radius: radius)?.0 {
            return candidate
        }
        return nil
    }

    private func postProcessDualAssistEvents(_ raw: [DualAssistCandidate], rallyStartTimeSec: Double?) -> [StereoShotEvent] {
        guard !raw.isEmpty else { return [] }
        let events = raw.sorted { $0.shot.startTime < $1.shot.startTime }

        func mergedCue(from first: DualAssistMotionCue, to last: DualAssistMotionCue, durationSec: Double) -> DualAssistMotionCue {
            let dxPx = Double(last.endPx.x - first.startPx.x)
            let dyPx = Double(last.endPx.y - first.startPx.y)
            return DualAssistMotionCue(
                startPx: first.startPx,
                endPx: last.endPx,
                dxPx: dxPx,
                dyPx: dyPx,
                travelPx: hypot(dxPx, dyPx),
                durationSec: durationSec
            )
        }

        var merged: [DualAssistCandidate] = []
        var i = 0
        while i < events.count {
            if i > 0, i + 1 < events.count {
                let prev = merged.last!
                let cur = events[i]
                let next = events[i + 1]
                let curDuration = cur.shot.endTime - cur.shot.startTime
                let weakMiddle = (cur.shot.type == .unknown || cur.shot.confidence < 0.56) && curDuration <= 0.52
                let bracketedByStrongerShots = prev.shot.type != .unknown && next.shot.type != .unknown
                if weakMiddle && bracketedByStrongerShots {
                    let mergeType: StereoShotType
                    if prev.shot.type == next.shot.type {
                        mergeType = prev.shot.type
                    } else {
                        mergeType = prev.shot.confidence >= next.shot.confidence ? prev.shot.type : next.shot.type
                    }
                    let stitchedShot = StereoShotEvent(
                        startTime: prev.shot.startTime,
                        endTime: next.shot.endTime,
                        startFrameA: prev.shot.startFrameA,
                        endFrameA: next.shot.endFrameA,
                        startPoint: prev.shot.startPoint,
                        endPoint: next.shot.endPoint,
                        peakHeight: max(prev.shot.peakHeight, max(cur.shot.peakHeight, next.shot.peakHeight)),
                        netHeight: prev.shot.netHeight ?? cur.shot.netHeight ?? next.shot.netHeight,
                        type: mergeType,
                        confidence: max(prev.shot.confidence, next.shot.confidence) * 0.95,
                        isUserEdited: prev.shot.isUserEdited || cur.shot.isUserEdited || next.shot.isUserEdited
                    )
                    let stitchedCue = mergedCue(from: prev.cue, to: next.cue, durationSec: stitchedShot.endTime - stitchedShot.startTime)
                    merged.removeLast()
                    merged.append(DualAssistCandidate(shot: stitchedShot, cue: stitchedCue))
                    i += 2
                    continue
                }
            }
            merged.append(events[i])
            i += 1
        }

        var relabeled = merged
        let anchor = max(0, rallyStartTimeSec ?? 1.10)
        let serveWindowStart = max(0, anchor - 0.18)
        let serveWindowEnd = anchor + 0.42
        relabeled.removeAll { $0.shot.endTime < max(0, serveWindowStart - 0.10) }

        if relabeled.count >= 2 {
            let first = relabeled[0].shot
            let second = relabeled[1].shot
            let firstDuration = first.endTime - first.startTime
            let firstContainsServeWindow = first.startTime <= serveWindowEnd && first.endTime >= serveWindowStart
            let likelyPreServeNoise = first.startTime < serveWindowStart && first.endTime <= serveWindowStart + 0.32 && firstDuration <= 0.65 && first.type != .serve && !firstContainsServeWindow
            let likelyTrueOpeningHit = second.startTime >= serveWindowStart && second.startTime <= serveWindowEnd + 0.25
            if likelyPreServeNoise && likelyTrueOpeningHit {
                relabeled.removeFirst()
            }
        }

        for idx in relabeled.indices {
            var candidate = relabeled[idx]
            var ev = candidate.shot
            let cue = candidate.cue
            let prev = idx > 0 ? relabeled[idx - 1] : nil
            let next = idx + 1 < relabeled.count ? relabeled[idx + 1] : nil
            let duration = ev.endTime - ev.startTime
            let overlapsAnchorServeWindow = ev.startTime <= serveWindowEnd && ev.endTime >= serveWindowStart

            if idx == 0 {
                let serveLikeByImage = cue.dyPx <= -160 && cue.travelPx >= 180
                let anchorAligned = overlapsAnchorServeWindow || abs(ev.startTime - anchor) <= 0.22
                if anchorAligned || isServeLikeDualAssistEvent(ev) || serveLikeByImage {
                    ev.type = .serve
                    ev.confidence = max(ev.confidence, anchorAligned ? 0.86 : 0.78)
                    candidate.shot = ev
                    relabeled[idx] = candidate
                    continue
                }
            }

            if let prev, prev.shot.type == .serve, cue.dyPx >= 200, duration >= 0.40, duration <= 1.80 {
                ev.type = .smash
                ev.confidence = max(ev.confidence, 0.78)
                candidate.shot = ev
                relabeled[idx] = candidate
                continue
            }

            if let prev, prev.shot.type == .smash, duration >= 0.28, duration <= 1.05 {
                ev.type = cue.dyPx <= -90 ? .pushBlock : .drive
                ev.confidence = max(ev.confidence, 0.68)
                candidate.shot = ev
                relabeled[idx] = candidate
                continue
            }

            if ev.type == .clearLift && (ev.peakHeight == 0 || ev.peakHeight < 1.6) {
                if duration <= 0.85 {
                    ev.type = abs(cue.dxPx) >= 115 ? .drive : .pushBlock
                    ev.confidence = max(ev.confidence, 0.66)
                    candidate.shot = ev
                    relabeled[idx] = candidate
                    continue
                }
                let inferred = inferDualAssistType(for: candidate, prev: prev, next: next)
                if inferred != .unknown && inferred != .serve {
                    ev.type = inferred
                    ev.confidence = max(ev.confidence, inferred == .clearLift ? 0.60 : 0.64)
                    candidate.shot = ev
                    relabeled[idx] = candidate
                    continue
                }
            }

            if ev.type == .netShot && cue.travelPx >= 150 && abs(cue.dxPx) >= 110 {
                ev.type = abs(cue.dxPx) >= 170 ? .netCross : .pushBlock
                ev.confidence = max(ev.confidence, 0.62)
                candidate.shot = ev
                relabeled[idx] = candidate
                continue
            }

            if ev.type == .unknown || ev.confidence < 0.58 {
                if let prev, prev.shot.type == .netShot, duration <= 1.10 {
                    ev.type = cue.dyPx <= -120 ? .clearLift : .pushBlock
                    ev.confidence = max(ev.confidence, 0.63)
                    candidate.shot = ev
                    relabeled[idx] = candidate
                    continue
                }
                let inferred = inferDualAssistType(for: candidate, prev: prev, next: next)
                if inferred != .unknown {
                    ev.type = inferred
                    ev.confidence = max(ev.confidence, 0.60)
                    candidate.shot = ev
                    relabeled[idx] = candidate
                    continue
                }
            }

            if ev.type == .clearLift && cue.dyPx >= 170 && duration <= 0.95 {
                ev.type = idx <= 2 ? .smash : .pushBlock
                ev.confidence = max(ev.confidence, 0.63)
                candidate.shot = ev
                relabeled[idx] = candidate
                continue
            }

            if next == nil && duration <= 1.00 && cue.dyPx >= 180 && cue.travelPx >= 160 {
                ev.type = .smash
                ev.confidence = max(ev.confidence, 0.72)
                candidate.shot = ev
                relabeled[idx] = candidate
            }
        }

        for idx in relabeled.indices {
            guard idx > 0 else { continue }
            if relabeled[idx].shot.type == .serve {
                var candidate = relabeled[idx]
                let prev = relabeled[idx - 1]
                let next = idx + 1 < relabeled.count ? relabeled[idx + 1] : nil
                let inferred = inferDualAssistType(for: candidate, prev: prev, next: next)
                candidate.shot.type = inferred == .serve ? .clearLift : inferred
                candidate.shot.confidence = max(candidate.shot.confidence, 0.60)
                relabeled[idx] = candidate
            }
        }

        if !relabeled.isEmpty {
            var first = relabeled[0]
            let overlapsAnchorServeWindow = first.shot.startTime <= serveWindowEnd && first.shot.endTime >= serveWindowStart
            if first.shot.type != .serve && (isServeLikeDualAssistEvent(first.shot) || overlapsAnchorServeWindow) {
                first.shot.type = .serve
                first.shot.confidence = max(first.shot.confidence, overlapsAnchorServeWindow ? 0.84 : 0.74)
                relabeled[0] = first
            }
        }

        if relabeled.count >= 3 {
            for idx in 0..<(relabeled.count - 1) {
                guard idx > 0 else { continue }
                var current = relabeled[idx]
                var following = relabeled[idx + 1]
                let prevShot = relabeled[idx - 1].shot
                let nextNextShot = idx + 2 < relabeled.count ? relabeled[idx + 2].shot : nil
                let cur = current.shot
                let nxt = following.shot
                let curDuration = cur.endTime - cur.startTime
                let nextDuration = nxt.endTime - nxt.startTime
                let curStartZone = dualAssistZone(for: cur.startPoint.y)
                let curEndZone = dualAssistZone(for: cur.endPoint.y)
                let nextStartZone = dualAssistZone(for: nxt.startPoint.y)
                let nextEndZone = dualAssistZone(for: nxt.endPoint.y)
                let curCrossesNet = (cur.startPoint.y - Double(court.halfL)) * (cur.endPoint.y - Double(court.halfL)) < 0
                let nextTravel = hypot(nxt.endPoint.x - nxt.startPoint.x, nxt.endPoint.y - nxt.startPoint.y)
                let nextLateral = abs(nxt.endPoint.x - nxt.startPoint.x)

                let clearToFrontSequence = prevShot.type == .clearLift || prevShot.type == .drive || prevShot.type == .pushBlock
                let nextLooksLikeFrontCourtReply = (nextStartZone == .fore || nextStartZone == .net) && (nextEndZone == .fore || nextEndZone == .net) && nextDuration <= 1.35 && nextTravel <= 3.0
                let currentLooksLikeDropEntry = curCrossesNet && (curStartZone == .mid || curStartZone == .rear || curStartZone == .fore) && (curEndZone == .fore || curEndZone == .net) && curDuration >= 0.45 && curDuration <= 1.15
                let rallyContinuesDeepAfterNext = nextNextShot?.type == .clearLift || nextNextShot?.type == .drive || dualAssistZone(for: nextNextShot?.endPoint.y ?? Double(court.halfL)) == .rear

                let prevEndsDeep = dualAssistZone(for: prevShot.endPoint.y) == .rear
                let nextBeginsFront = nextStartZone == .fore || nextStartZone == .net
                let nextEndsFront = nextEndZone == .fore || nextEndZone == .net
                let currentImpossibleAsNet = cur.type == .netShot && (prevShot.type == .clearLift || prevEndsDeep || curStartZone == .mid || curStartZone == .rear)
                let followingLooksLikeRealNetReply = (nxt.type == .drop || nxt.type == .unknown || nxt.type == .netShot) && nextBeginsFront && nextEndsFront && nextDuration <= 1.30 && nextTravel <= 2.4
                if currentImpossibleAsNet && followingLooksLikeRealNetReply {
                    current.shot.type = .drop
                    current.shot.confidence = max(current.shot.confidence, 0.86)
                    following.shot.type = nextLateral >= 1.20 ? .netCross : .netShot
                    following.shot.confidence = max(following.shot.confidence, 0.82)
                    relabeled[idx] = current
                    relabeled[idx + 1] = following
                    continue
                }
                if cur.type == .netShot && (nxt.type == .drop || nxt.type == .unknown) && currentLooksLikeDropEntry && nextLooksLikeFrontCourtReply && (clearToFrontSequence || prevEndsDeep) && nextBeginsFront && nextEndsFront && rallyContinuesDeepAfterNext {
                    current.shot.type = .drop
                    current.shot.confidence = max(current.shot.confidence, 0.82)
                    following.shot.type = nextLateral >= 1.20 ? .netCross : .netShot
                    following.shot.confidence = max(following.shot.confidence, 0.78)
                    relabeled[idx] = current
                    relabeled[idx + 1] = following
                }
            }
        }

        if relabeled.count >= 3 {
            for idx in 0..<(relabeled.count - 1) {
                var current = relabeled[idx]
                var following = relabeled[idx + 1]
                let nextNext = idx + 2 < relabeled.count ? relabeled[idx + 2].shot : nil
                let cur = current.shot
                let nxt = following.shot
                let curDuration = cur.endTime - cur.startTime
                let nextDuration = nxt.endTime - nxt.startTime
                let currentLooksTooLongForNet = current.cue.travelPx >= 135 || abs(current.cue.dyPx) >= 95 || curDuration >= 0.70
                let nextLooksLikeShortFrontReply = following.cue.travelPx <= 115 && nextDuration <= 1.10
                let currentEndsWhereNextBegins = hypot(current.cue.endPx.x - following.cue.startPx.x, current.cue.endPx.y - following.cue.startPx.y) <= 55
                let rallyContinuesAfterSwap = nextNext?.type == .clearLift || nextNext?.type == .drive || nextNext?.type == .pushBlock || nextNext?.type == .unknown
                let likelyReversedDropThenNet = cur.type == .netShot && (nxt.type == .drop || nxt.type == .unknown) && currentLooksTooLongForNet && nextLooksLikeShortFrontReply && currentEndsWhereNextBegins && rallyContinuesAfterSwap
                if likelyReversedDropThenNet {
                    current.shot.type = .drop
                    current.shot.confidence = max(current.shot.confidence, 0.78)
                    following.shot.type = abs(following.cue.dxPx) >= 95 ? .netCross : .netShot
                    following.shot.confidence = max(following.shot.confidence, 0.74)
                    relabeled[idx] = current
                    relabeled[idx + 1] = following
                }
            }
        }

        for idx in relabeled.indices {
            var candidate = relabeled[idx]
            var ev = candidate.shot
            let prev = idx > 0 ? relabeled[idx - 1].shot : nil
            let next = idx + 1 < relabeled.count ? relabeled[idx + 1].shot : nil
            let duration = ev.endTime - ev.startTime
            let startZone = dualAssistZone(for: ev.startPoint.y)
            let endZone = dualAssistZone(for: ev.endPoint.y)
            let travel = hypot(ev.endPoint.x - ev.startPoint.x, ev.endPoint.y - ev.startPoint.y)
            let lateral = abs(ev.endPoint.x - ev.startPoint.x)
            let crossesNet = (ev.startPoint.y - Double(court.halfL)) * (ev.endPoint.y - Double(court.halfL)) < 0

            let prevEndZone = prev.map { dualAssistZone(for: $0.endPoint.y) }
            let impossibleForecourtNetReply = ev.type == .netShot && (prevEndZone == .mid || prevEndZone == .rear)
            if ev.type == .netShot && ((((startZone == .mid || startZone == .rear) && crossesNet && (endZone == .fore || endZone == .net)) || candidate.cue.travelPx >= 135) || impossibleForecourtNetReply) {
                ev.type = .drop
                ev.confidence = max(ev.confidence, 0.74)
                candidate.shot = ev
                relabeled[idx] = candidate
                continue
            }

            if (ev.type == .unknown || ev.type == .drop) {
                let shortFrontCourtReply = (startZone == .fore || startZone == .net) && (endZone == .fore || endZone == .net) && duration <= 0.95 && travel <= 2.6
                let supportedByContext = prev?.type == .drop || prev?.type == .netShot || prev?.type == .netCross
                if shortFrontCourtReply && supportedByContext {
                    ev.type = lateral >= 1.20 ? .netCross : .netShot
                    ev.confidence = max(ev.confidence, 0.66)
                    candidate.shot = ev
                    relabeled[idx] = candidate
                    continue
                }
            }

            if next == nil && (ev.type == .pushBlock || ev.type == .drive) {
                let cue = candidate.cue
                if duration <= 0.95 && cue.dyPx >= 180 && cue.travelPx >= 150 {
                    ev.type = .smash
                    ev.confidence = max(ev.confidence, 0.70)
                    candidate.shot = ev
                    relabeled[idx] = candidate
                    continue
                }
            }
        }

        return relabeled.map(\.shot)
    }

    private func dualAssistZone(for y: Double) -> DualAssistCourtZone {
        let netY = Double(court.halfL)
        let dist = abs(y - netY)
        if dist <= 0.85 { return .net }
        if dist <= 2.35 { return .fore }
        if dist <= 4.75 { return .mid }
        return .rear
    }

    private func isServeLikeDualAssistEvent(_ event: StereoShotEvent) -> Bool {
        let duration = event.endTime - event.startTime
        let start = event.startPoint
        let end = event.endPoint
        let startY = start.y
        let endY = end.y
        let netY = Double(court.halfL)
        let shortServiceNear = netY - Double(court.sSvc)
        let shortServiceFar = netY + Double(court.sSvc)
        let startsNearServiceBand = abs(startY - shortServiceNear) <= 1.6 || abs(startY - shortServiceFar) <= 1.6
        let crossesNet = (startY - netY) * (endY - netY) < 0
        let modestPeak = event.peakHeight <= 2.8 || event.peakHeight == 0
        let travel = hypot(end.x - start.x, end.y - start.y)
        let openingWindow = event.startTime <= 1.70
        let preferredServeWindow = event.startTime <= 1.30 && event.endTime >= 0.95
        let lateServeWindow = event.startTime >= 0.90 && event.startTime <= 1.60
        let openingFallback = event.startTime <= 0.85 && duration <= 0.95
        let lateServeFallback = lateServeWindow && duration >= 0.25 && duration <= 1.30
        return openingWindow && duration >= 0.22 && duration <= 1.35 && crossesNet && modestPeak && travel >= 0.8 && travel <= 6.8 && (startsNearServiceBand || preferredServeWindow || openingFallback || lateServeFallback)
    }

    private func inferDualAssistType(for candidate: DualAssistCandidate, prev: DualAssistCandidate?, next: DualAssistCandidate?) -> StereoShotType {
        let event = candidate.shot
        let cue = candidate.cue
        let duration = event.endTime - event.startTime
        let peak = event.peakHeight
        let absDxPx = abs(cue.dxPx)
        let absDyPx = abs(cue.dyPx)
        let signedDyPx = cue.dyPx
        let travelPx = cue.travelPx

        if let prev, prev.shot.type == .serve {
            if signedDyPx >= 220 && duration >= 0.45 && duration <= 1.80 {
                return .smash
            }
            if signedDyPx <= -120 && duration >= 0.30 && duration <= 1.00 {
                return .pushBlock
            }
        }

        if peak == 0 || peak < 1.0 {
            if duration <= 0.55 {
                if absDxPx >= 170 && absDyPx <= 130 { return .netCross }
                if absDxPx >= 110 && absDyPx <= 120 { return .drive }
                if travelPx <= 110 { return .pushBlock }
            }

            if duration <= 0.85 {
                if signedDyPx >= 180 { return .pushBlock }
                if signedDyPx <= -180 { return .clearLift }
                if absDxPx >= 140 && absDyPx <= 140 { return .drive }
                if travelPx <= 150 { return .pushBlock }
            }

            if duration <= 1.30 {
                if signedDyPx <= -190 { return .clearLift }
                if signedDyPx >= 180 { return .pushBlock }
                if absDxPx >= 210 && absDyPx <= 170 { return .drive }
            }
        }

        if duration <= 0.80 && absDxPx >= 130 && absDyPx <= 120 {
            return .drive
        }

        if duration <= 0.85 && travelPx <= 120 {
            return .pushBlock
        }

        if let next, (next.shot.type == .netShot || next.shot.type == .netCross), duration < 0.95, signedDyPx < -90 {
            return .drop
        }

        if peak >= 1.55 && duration <= 1.25 && signedDyPx >= 170 {
            return prev?.shot.type == .serve ? .smash : .pushBlock
        }

        let netY = Double(court.halfL)
        let courtL = Double(court.L)
        let start = event.startPoint
        let end = event.endPoint
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        let travel = hypot(dx, dy)
        let crossesNet = (start.y - netY) * (end.y - netY) < 0
        let startNearNet = abs(start.y - netY) <= 1.15
        let endNearNet = abs(end.y - netY) <= 1.15
        let endDeep = end.y <= 1.7 || end.y >= (courtL - 1.7)
        let endMid = !endNearNet && !endDeep

        if peak >= 2.05 && duration >= 0.95 && (travel >= 2.8 || endDeep) {
            return .clearLift
        }

        if startNearNet && crossesNet && endDeep {
            if peak >= 1.8 || duration >= 1.00 || travel >= 3.6 {
                return .clearLift
            }
            if duration <= 0.72 {
                return travel >= 2.0 ? .drive : .pushBlock
            }
        }

        if endNearNet {
            if dx >= 1.45 && duration <= 1.05 {
                return .netCross
            }
            if duration >= 0.55 && (peak == 0 || peak < 2.1) {
                return .drop
            }
            return .netShot
        }

        if endDeep && (duration >= 1.18 || travel >= 4.8 || (peak >= 2.05 && duration >= 0.90)) {
            return .clearLift
        }

        if crossesNet {
            if peak >= 2.2 {
                return .clearLift
            }
            if duration <= 0.70 {
                return travel >= 2.15 ? .drive : .pushBlock
            }
            if duration <= 0.95 && endNearNet {
                return dx >= 1.15 ? .netCross : .netShot
            }
            if duration <= 0.95 && endMid {
                return .drop
            }
            if duration <= 1.05 && (peak == 0 || peak < 1.7) {
                return .pushBlock
            }
        }

        if duration <= 0.78 {
            if travel < 2.0 || endMid {
                return .pushBlock
            }
            return .drive
        }

        if !crossesNet && duration <= 0.82 {
            return travel >= 1.6 ? .drive : .pushBlock
        }

        if let prev, prev.shot.type == .clearLift, duration < 0.95, peak == 0 {
            return .drop
        }

        if let next, (next.shot.type == .netShot || next.shot.type == .netCross), duration < 0.95 {
            return .drop
        }

        if next == nil && duration <= 1.00 && signedDyPx >= 180 && travelPx >= 160 {
            return .smash
        }

        return .unknown
    }

    private func stereo3DIsReliable(segment3D: [Stereo3DPoint], assist: DualAssistMetrics) -> Bool {
        guard !segment3D.isEmpty else { return false }
        let reproj = segment3D.compactMap(\.reprojectionErrorPx)
        let meanReproj = reproj.isEmpty ? maxReprojectionErrorPx : reproj.reduce(0, +) / Double(reproj.count)
        let validWorld = segment3D.compactMap { $0.world3D }
        guard !validWorld.isEmpty else { return false }

        let inBoundsCount = validWorld.filter {
            $0.x >= -1.0 && $0.x <= Double(court.W) + 1.0 &&
            $0.y >= -2.0 && $0.y <= Double(court.L) + 2.0 &&
            $0.z >= -0.3 && $0.z <= 8.5
        }.count
        let inBoundsRatio = Double(inBoundsCount) / Double(validWorld.count)

        return assist.stereoCoverage >= 0.32 &&
               assist.reprojectionQuality >= 0.35 &&
               assist.trendAgreement >= 0.45 &&
               meanReproj <= 18.0 &&
               inBoundsRatio >= 0.70
    }

    private func dualAssistMetrics(for seg: StereoShotSegment2D, rows: [StereoCSVRow], framePixelsA: [CGPoint?], framePixelsB: [CGPoint?], frameGroundA: [CGPoint?], frameGroundB: [CGPoint?], recon: [Stereo3DPoint]) -> DualAssistMetrics {
        guard seg.endFrame >= seg.startFrame else {
            return DualAssistMetrics(coverageB: 0, stereoCoverage: 0, timingQuality: 0, reprojectionQuality: 0, trendAgreement: 0)
        }
        let frames = Array(seg.startFrame...seg.endFrame)
        let total = max(1, frames.count)

        let bVisible = frames.filter { idx in idx < framePixelsB.count && framePixelsB[idx] != nil }.count
        let stereoValid = recon.filter { $0.frameA >= seg.startFrame && $0.frameA <= seg.endFrame && $0.world3D != nil }.count

        let rowWindow = rows.filter { $0.frameA >= seg.startFrame && $0.frameA <= seg.endFrame }
        let meanTimeDelta = rowWindow.isEmpty ? maxTimeDeltaMs : rowWindow.map { abs($0.timeDeltaMs) }.reduce(0, +) / Double(rowWindow.count)
        let timingQuality = min(1.0, max(0.0, 1.0 - meanTimeDelta / max(maxTimeDeltaMs, 1.0)))

        let reprojVals = recon.filter { $0.frameA >= seg.startFrame && $0.frameA <= seg.endFrame }.compactMap { $0.reprojectionErrorPx }
        let reprojMean = reprojVals.isEmpty ? maxReprojectionErrorPx : reprojVals.reduce(0, +) / Double(reprojVals.count)
        let reprojQuality = min(1.0, max(0.0, 1.0 - reprojMean / max(maxReprojectionErrorPx, 1.0)))

        var agreements = 0
        var comparisons = 0
        if frames.count >= 2 {
            for (fa, fb) in zip(frames, frames.dropFirst()) {
                guard fa < framePixelsA.count, fb < framePixelsA.count,
                      fa < framePixelsB.count, fb < framePixelsB.count,
                      let a0 = framePixelsA[fa], let a1 = framePixelsA[fb],
                      let b0 = framePixelsB[fa], let b1 = framePixelsB[fb] else { continue }
                let dyA = a1.y - a0.y
                let dyB = b1.y - b0.y
                if abs(dyA) < 1.0 && abs(dyB) < 1.0 { continue }
                comparisons += 1
                if dyA == 0 || dyB == 0 || dyA.sign == dyB.sign {
                    agreements += 1
                }
            }
        }
        let trendAgreement = comparisons > 0 ? Double(agreements) / Double(comparisons) : 0.0

        return DualAssistMetrics(
            coverageB: Double(bVisible) / Double(total),
            stereoCoverage: Double(stereoValid) / Double(total),
            timingQuality: timingQuality,
            reprojectionQuality: reprojQuality,
            trendAgreement: trendAgreement
        )
    }

    private func nearestStereoWorld3D(in points: [Stereo3DPoint], aroundFrameA frame: Int, radius: Int = 4) -> SIMD3<Double>? {
        let lo = max(0, frame - radius)
        let hi = frame + radius
        return points
            .filter { $0.frameA >= lo && $0.frameA <= hi }
            .sorted { abs($0.frameA - frame) < abs($1.frameA - frame) }
            .compactMap { $0.world3D }
            .first
    }

    private func refineStereoType(baseType: StereoShotType, segment3D: [Stereo3DPoint], durationSec: Double) -> StereoShotType {
        guard !segment3D.isEmpty else { return baseType }
        let zs = segment3D.compactMap { $0.world3D?.z }
        let peak = zs.max() ?? 0
        let minZ = zs.min() ?? 0
        let net = estimateNetHeight(segment3D.compactMap { p in
            guard let w = p.world3D else { return nil }
            return (p.timeSec, w)
        })
        let start = segment3D.first?.world3D
        let end = segment3D.last?.world3D
        let crossesNet = segment3D.contains { ($0.world3D?.y ?? 0) < Double(court.halfL) } && segment3D.contains { ($0.world3D?.y ?? 0) > Double(court.halfL) }

        if baseType == .unknown {
            if peak > 4.8 && durationSec > 0.75 { return .clearLift }
            if let net, net < 1.6, peak < 3.6, durationSec < 0.70 { return .smash }
            if let net, net < 1.9, peak < 3.6, durationSec < 0.95 { return .drop }
            if let net, net > 1.0, net < 2.3, peak > 1.0, peak < 3.6, durationSec < 0.85 { return .drive }
            if let s = start, let e = end, abs(s.y - Double(court.halfL)) < 1.2, abs(e.y - Double(court.halfL)) < 1.2, peak < 1.8 {
                return abs(s.x - e.x) > 1.6 ? .netCross : .netShot
            }
        }

        if baseType == .smash, peak > 4.6, durationSec > 0.8 { return .clearLift }
        if baseType == .clearLift, peak < 3.8, let net, net < 1.8, durationSec < 0.8 { return .drop }
        if crossesNet == false, peak < 1.8, minZ >= 0, durationSec < 0.8 {
            return baseType == .unknown ? .pushBlock : baseType
        }
        return baseType
    }

    private func stereoSuppressLoopedRepeats(_ points: [CGPoint?]) -> [CGPoint?] {
        let lags = [8, 10, 12, 16, 20]
        let minRun = 10
        func samePoint(_ a: CGPoint?, _ b: CGPoint?, tol: CGFloat = 0.5) -> Bool {
            switch (a, b) {
            case (.none, .none): return true
            case let (.some(pa), .some(pb)): return hypot(pa.x - pb.x, pa.y - pb.y) <= tol
            default: return false
            }
        }
        var out = points
        for lag in lags {
            var i = 0
            while i + lag < out.count {
                if samePoint(out[i], out[i + lag]) {
                    let start = i
                    while i + lag < out.count && samePoint(out[i], out[i + lag]) { i += 1 }
                    let end = i - 1
                    let runLen = end - start + 1
                    if runLen >= minRun {
                        let j0 = start + lag
                        let j1 = min(out.count - 1, end + lag)
                        if j0 <= j1 { for j in j0...j1 { out[j] = nil } }
                    }
                } else {
                    i += 1
                }
            }
        }
        return out
    }

    private func stereoRejectPixelOutliers(_ points: [CGPoint?], fps: Double) -> [CGPoint?] {
        let maxJump: CGFloat = 180.0 * CGFloat(50.0 / max(1.0, fps))
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        var out = points
        guard out.count >= 3 else { return out }
        for i in 1..<(out.count - 1) {
            guard let prev = out[i - 1], let cur = out[i], let next = out[i + 1] else { continue }
            let d1 = dist(prev, cur)
            let d2 = dist(cur, next)
            let bridge = dist(prev, next)
            if d1 > maxJump && d2 > maxJump && bridge < maxJump * 0.8 { out[i] = nil }
        }
        return out
    }

    private func stereoTrimInitialHoldNoise(_ points: [CGPoint?], fps: Double) -> [CGPoint?] {
        guard points.count >= 12 else { return points }
        let inspectLimit = min(points.count - 1, max(18, Int(round(1.5 * fps))))
        let jitterRadius: CGFloat = 18.0 * CGFloat(50.0 / max(1.0, fps))
        let meanStepTh: CGFloat = 6.0 * CGFloat(50.0 / max(1.0, fps))
        let launchDispTh: CGFloat = 90.0 * CGFloat(50.0 / max(1.0, fps))
        let launchVertTh: CGFloat = 65.0 * CGFloat(50.0 / max(1.0, fps))

        func point(at idx: Int) -> CGPoint? {
            guard idx >= 0, idx < points.count else { return nil }
            return points[idx]
        }

        for i in 4..<inspectLimit {
            let histLo = max(0, i - 4)
            let hist = (histLo...i).compactMap { point(at: $0) }
            guard hist.count >= 4 else { continue }

            let xs = hist.map(\.x)
            let ys = hist.map(\.y)
            let maxX = xs.max() ?? 0
            let minX = xs.min() ?? 0
            let maxY = ys.max() ?? 0
            let minY = ys.min() ?? 0
            let spreadDX = maxX - minX
            let spreadDY = maxY - minY
            let spread = hypot(spreadDX, spreadDY)

            var stepSum: CGFloat = 0
            if hist.count > 1 {
                for idx in 1..<hist.count {
                    let dx = hist[idx].x - hist[idx - 1].x
                    let dy = hist[idx].y - hist[idx - 1].y
                    stepSum += hypot(dx, dy)
                }
            }
            let meanStep = stepSum / CGFloat(max(1, hist.count - 1))
            guard spread <= jitterRadius, meanStep <= meanStepTh else { continue }

            let lookahead = min(points.count - 1, i + max(4, Int(round(0.20 * fps))))
            guard let p0 = point(at: i), let p1 = point(at: lookahead) else { continue }
            let disp = hypot(p1.x - p0.x, p1.y - p0.y)
            let vert = abs(p1.y - p0.y)
            if disp >= launchDispTh || vert >= launchVertTh {
                var out = points
                let trimEnd = max(0, i - 1)
                if trimEnd > 0 {
                    for j in 0..<trimEnd { out[j] = nil }
                }
                return out
            }
        }

        return points
    }

    private func stereoInterpolateShortGaps(_ world: [CGPoint?], maxGap: Int) -> [CGPoint?] {
        guard maxGap >= 1 else { return world }
        var out = world
        var i = 0
        while i < out.count {
            if out[i] != nil { i += 1; continue }
            let gapStart = i
            while i < out.count && out[i] == nil { i += 1 }
            let gapEnd = i - 1
            let gapLen = gapEnd - gapStart + 1
            let left = gapStart - 1
            let right = gapEnd + 1
            if gapLen <= maxGap, left >= 0, right < out.count, let p0 = out[left], let p1 = out[right] {
                for k in 1..<(gapLen + 1) {
                    let t = CGFloat(k) / CGFloat(gapLen + 1)
                    out[gapStart + (k - 1)] = CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t)
                }
            }
        }
        return out
    }

    private func stereoMovingAverage(_ world: [CGPoint?], radius: Int) -> [CGPoint?] {
        guard radius >= 1 else { return world }
        var out = world
        for i in 0..<world.count {
            guard world[i] != nil else { continue }
            var xs: [CGFloat] = []
            var ys: [CGFloat] = []
            for j in max(0, i - radius)...min(world.count - 1, i + radius) {
                if let p = world[j] { xs.append(p.x); ys.append(p.y) }
            }
            if xs.count >= 2 {
                out[i] = CGPoint(x: xs.reduce(0, +) / CGFloat(xs.count), y: ys.reduce(0, +) / CGFloat(ys.count))
            }
        }
        return out
    }

    private func stereoMedianFilter(_ points: [CGPoint?], radius: Int) -> [CGPoint?] {
        guard radius >= 1 else { return points }
        var out = points
        for i in 0..<points.count {
            guard points[i] != nil else { continue }
            var xs: [CGFloat] = []
            var ys: [CGFloat] = []
            for j in max(0, i - radius)...min(points.count - 1, i + radius) {
                if let p = points[j] { xs.append(p.x); ys.append(p.y) }
            }
            guard xs.count >= 3 else { continue }
            xs.sort(); ys.sort()
            out[i] = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
        }
        return out
    }

    private func stereoLocalPixelSpeed(_ points: [CGPoint?], at frame: Int, span: Int = 2) -> CGFloat {
        let a = max(0, frame - span)
        let b = min(points.count - 1, frame + span)
        guard a < b else { return 0 }
        guard let p0 = stereoNearestValidPoint(in: points, around: a, radius: span)?.1,
              let p1 = stereoNearestValidPoint(in: points, around: b, radius: span)?.1 else { return 0 }
        return hypot(p1.x - p0.x, p1.y - p0.y) / CGFloat(max(1, b - a))
    }

    private func stereoStabilizationDelayFrames(_ points: [CGPoint?], around hitFrame: Int, fps: Double) -> Int {
        let minDelay = Int(round(0.08 * fps))
        let maxDelay = Int(round(0.16 * fps))
        let baseDelay = Int(round(0.10 * fps))
        let speed = stereoLocalPixelSpeed(points, at: hitFrame, span: 2)
        let normalized = min(1.0, max(0.0, Double(speed / 22.0)))
        let extra = Int(round(normalized * 0.04 * fps))
        return min(maxDelay, max(minDelay, baseDelay + extra))
    }

    private func stereoNearestValidPoint(in arr: [CGPoint?], around frame: Int, radius: Int = 6) -> (Int, CGPoint)? {
        guard !arr.isEmpty else { return nil }
        let lo = max(0, frame - radius)
        let hi = min(arr.count - 1, frame + radius)
        if frame >= 0, frame < arr.count, let p = arr[frame] { return (frame, p) }
        for d in 1...radius {
            let a = frame - d
            if a >= lo, a < arr.count, let p = arr[a] { return (a, p) }
            let b = frame + d
            if b <= hi, b >= 0, let p = arr[b] { return (b, p) }
        }
        return nil
    }

    private func stereoRepresentativePoint(in arr: [CGPoint?], around frame: Int, radius: Int = 3) -> (Int, CGPoint)? {
        guard !arr.isEmpty else { return nil }
        let lo = max(0, frame - radius)
        let hi = min(arr.count - 1, frame + radius)
        var candidates: [(Int, CGPoint)] = []
        if lo <= hi {
            for idx in lo...hi where arr[idx] != nil { candidates.append((idx, arr[idx]!)) }
        }
        if candidates.isEmpty { return stereoNearestValidPoint(in: arr, around: frame, radius: max(radius + 3, 6)) }
        var xs = candidates.map { $0.1.x }.sorted()
        var ys = candidates.map { $0.1.y }.sorted()
        let med = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
        return candidates.min { lhs, rhs in
            let dl = hypot(lhs.1.x - med.x, lhs.1.y - med.y) + CGFloat(abs(lhs.0 - frame)) * 0.35
            let dr = hypot(rhs.1.x - med.x, rhs.1.y - med.y) + CGFloat(abs(rhs.0 - frame)) * 0.35
            return dl < dr
        }
    }

    private func stereoStableRepresentativePoint(in arr: [CGPoint?], around hitFrame: Int, direction: Int, delay: Int, radius: Int = 2) -> (Int, CGPoint)? {
        guard !arr.isEmpty else { return nil }
        let center = min(max(0, hitFrame + direction * delay), arr.count - 1)
        return stereoRepresentativePoint(in: arr, around: center, radius: radius)
    }

    private func stereoRefineHitFramesWithPhysics(_ points: [CGPoint?], fps: Double, seedHits: [Int]) -> [Int] {
        guard !seedHits.isEmpty else { return [] }
        let minGap = max(10, Int(round(0.22 * fps)))
        var refined: [Int] = []
        for seed in seedHits {
            let search = max(4, Int(round(0.08 * fps)))
            let lo = max(1, seed - search)
            let hi = min(points.count - 2, seed + search)
            var bestFrame = seed
            var bestScore: CGFloat = -.greatestFiniteMagnitude
            for frame in lo...hi {
                guard let pPrev = points[frame - 1], let p = points[frame], let pNext = points[frame + 1] else { continue }
                let pre = CGPoint(x: p.x - pPrev.x, y: p.y - pPrev.y)
                let post = CGPoint(x: pNext.x - p.x, y: pNext.y - p.y)
                let turn = max(0, (pre.y * post.y < 0) ? abs(pre.y - post.y) : 0)
                let accel = abs(post.y - pre.y)
                let score = turn * 1.4 + accel
                if score > bestScore { bestScore = score; bestFrame = frame }
            }
            if let last = refined.last, bestFrame - last <= minGap {
                if bestFrame > last { refined[refined.count - 1] = bestFrame }
            } else {
                refined.append(bestFrame)
            }
        }
        return refined
    }

    private func stereoDetectHitFramesImageSpace(_ points: [CGPoint?], fps: Double) -> [Int] {
        guard points.count >= 5 else { return [] }
        let minGap = max(16, Int(round(0.32 * fps)))
        let angleTh: CGFloat = 35.0
        var candidates: [(frame: Int, score: CGFloat)] = []
        for i in 2..<(points.count - 2) {
            guard let p0 = points[i - 2], let p1 = points[i - 1], let p2 = points[i], let p3 = points[i + 1], let p4 = points[i + 2] else { continue }
            let v1 = CGVector(dx: p2.x - p0.x, dy: p2.y - p0.y)
            let v2 = CGVector(dx: p4.x - p2.x, dy: p4.y - p2.y)
            let n1 = hypot(v1.dx, v1.dy)
            let n2 = hypot(v2.dx, v2.dy)
            guard n1 > 1e-3, n2 > 1e-3 else { continue }
            let dot = max(-1.0, min(1.0, (v1.dx * v2.dx + v1.dy * v2.dy) / (n1 * n2)))
            let angle = acos(dot) * 180.0 / .pi
            let localMove = hypot(p3.x - p1.x, p3.y - p1.y)
            let score = CGFloat(angle) * 0.9 + localMove * 0.25 + abs((p3.y - p2.y) - (p2.y - p1.y)) * 0.9
            if angle >= angleTh { candidates.append((frame: i, score: score)) }
        }
        var hits: [(frame: Int, score: CGFloat)] = []
        for cand in candidates {
            if let last = hits.last, cand.frame - last.frame <= minGap {
                if cand.score > last.score { hits[hits.count - 1] = cand }
            } else {
                hits.append(cand)
            }
        }
        return hits.map { $0.frame }
    }

    private func stereoDetectLandingFramesImageSpace(_ points: [CGPoint?], worldByFrame: [CGPoint?], fps: Double) -> [Int] {
        let longGap = max(18, Int(round(0.36 * fps)))
        let minMotionBefore: CGFloat = 10.0 * CGFloat(50.0 / max(1.0, fps))
        let maxMotionAtEnd: CGFloat = 4.0 * CGFloat(50.0 / max(1.0, fps))
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func isCourtPoint(_ p: CGPoint?) -> Bool {
            guard let p else { return false }
            return p.x >= 0 && p.x <= CGFloat(court.W) && p.y >= 0 && p.y <= CGFloat(court.L)
        }
        var landings: [Int] = []
        var i = 1
        while i < points.count {
            if points[i] != nil { i += 1; continue }
            let gapStart = i
            while i < points.count && points[i] == nil { i += 1 }
            let gapLen = i - gapStart
            guard gapLen >= longGap else { continue }
            let cand = gapStart - 1
            guard cand >= 2 else { continue }
            guard let p0 = points[cand - 2], let p1 = points[cand - 1], let p2 = points[cand] else { continue }
            let dPrev = dist(p0, p1)
            let dEnd = dist(p1, p2)
            if dPrev >= minMotionBefore && dEnd <= maxMotionAtEnd && isCourtPoint(worldByFrame[cand]) { landings.append(cand) }
        }
        if let lastVisible = points.indices.last(where: { points[$0] != nil }), lastVisible >= 2,
           let p0 = points[lastVisible - 2], let p1 = points[lastVisible - 1], let p2 = points[lastVisible], isCourtPoint(worldByFrame[lastVisible]) {
            let dPrev = dist(p0, p1)
            let dEnd = dist(p1, p2)
            if dPrev >= minMotionBefore && dEnd <= maxMotionAtEnd { landings.append(lastVisible) }
        }
        var deduped: [Int] = []
        let minGap = max(20, Int(round(0.40 * fps)))
        for f in landings.sorted() {
            if let last = deduped.last, f - last < minGap { continue }
            deduped.append(f)
        }
        return deduped
    }

    private func stereoEstimateFallbackLanding(world: [CGPoint?], after lastHit: Int) -> (Int, CGPoint)? {
        guard !world.isEmpty else { return nil }
        guard let lastVisible = world.indices.last(where: { $0 > lastHit && world[$0] != nil }) else { return nil }
        var valid: [(Int, CGPoint)] = []
        for f in stride(from: lastVisible, through: max(lastHit + 1, lastVisible - 8), by: -1) {
            if let p = world[f] { valid.append((f, p)) }
            if valid.count >= 3 { break }
        }
        guard let newest = valid.first?.1 else { return nil }
        if valid.count >= 2 {
            let p0 = valid[1].1
            let p1 = newest
            let dx = Double(p1.x - p0.x)
            let dy = Double(p1.y - p0.y)
            let gain = 0.35
            let candidate = CGPoint(x: min(CGFloat(court.W), max(0, p1.x + CGFloat(dx * gain))), y: min(CGFloat(court.L), max(0, p1.y + CGFloat(dy * gain))))
            return (lastVisible, candidate)
        }
        return (lastVisible, newest)
    }

    private func stereoBuildShotSegmentsFromHits(pixel px: [CGPoint?], world: [CGPoint?], fps: Double, hitFrames: [Int], landingFrames: [Int]) -> [StereoShotSegment2D] {
        guard hitFrames.count >= 2 else { return [] }
        var segments: [StereoShotSegment2D] = []
        let minSpan = max(8, Int(round(0.16 * fps)))
        for i in 0..<(hitFrames.count - 1) {
            let f0 = hitFrames[i]
            let f1 = hitFrames[i + 1]
            guard f1 - f0 >= minSpan else { continue }
            let startDelay = stereoStabilizationDelayFrames(px, around: f0, fps: fps)
            let endDelay = max(2, stereoStabilizationDelayFrames(px, around: f1, fps: fps) / 2)
            guard let (spxFrame, p0) = stereoStableRepresentativePoint(in: px, around: f0, direction: +1, delay: startDelay, radius: 2),
                  let (epxFrame, p1) = stereoStableRepresentativePoint(in: px, around: f1, direction: -1, delay: endDelay, radius: 2),
                  let (_, w0) = stereoStableRepresentativePoint(in: world, around: f0, direction: +1, delay: startDelay, radius: 2),
                  let (_, w1) = stereoStableRepresentativePoint(in: world, around: f1, direction: -1, delay: endDelay, radius: 2) else { continue }
            let dt = Double(max(1, epxFrame - spxFrame)) / max(1.0, fps)
            segments.append(StereoShotSegment2D(startFrame: f0, endFrame: f1, startPx: p0, endPx: p1, startWorld: w0, endWorld: w1, durationSec: dt, isLanding: false))
        }
        if let lastHit = hitFrames.last {
            let startDelay = stereoStabilizationDelayFrames(px, around: lastHit, fps: fps)
            guard let (spxFrame, p0) = stereoStableRepresentativePoint(in: px, around: lastHit, direction: +1, delay: startDelay, radius: 2),
                  let (_, w0) = stereoStableRepresentativePoint(in: world, around: lastHit, direction: +1, delay: startDelay, radius: 2) else { return segments }
            if let landing = landingFrames.first(where: { $0 > lastHit + minSpan }),
               let (epxFrame, p1) = stereoRepresentativePoint(in: px, around: landing, radius: 3),
               let (_, w1) = stereoRepresentativePoint(in: world, around: landing, radius: 3) {
                let dt = Double(max(1, epxFrame - spxFrame)) / max(1.0, fps)
                if dt >= 0.10 {
                    segments.append(StereoShotSegment2D(startFrame: lastHit, endFrame: landing, startPx: p0, endPx: p1, startWorld: w0, endWorld: w1, durationSec: dt, isLanding: true))
                }
            } else if let (landingFrame, landingWorld) = stereoEstimateFallbackLanding(world: world, after: lastHit),
                      landingFrame > lastHit + minSpan,
                      let (_, landingPx) = stereoRepresentativePoint(in: px, around: landingFrame, radius: 4) {
                let dt = Double(max(1, landingFrame - spxFrame)) / max(1.0, fps)
                if dt >= 0.10 {
                    segments.append(StereoShotSegment2D(startFrame: lastHit, endFrame: landingFrame, startPx: p0, endPx: landingPx, startWorld: w0, endWorld: landingWorld, durationSec: dt, isLanding: true))
                }
            }
        }
        return segments
    }

    private func stereoClassifyShotSegment(startPx sPx: CGPoint, endPx ePx: CGPoint, startWorld sW: CGPoint, endWorld eW: CGPoint, durationSec: Double, isLanding: Bool) -> (StereoShotType, Double) {
        let W = CGFloat(court.W)
        let L = CGFloat(court.L)
        let netY = CGFloat(court.halfL)
        let midX = W / 2.0

        func nearNet(_ y: CGFloat) -> Bool { abs(y - netY) <= 1.10 }
        func deep(_ y: CGFloat) -> Bool { y <= 1.60 || y >= (L - 1.60) }
        func crossCourt(_ a: CGPoint, _ b: CGPoint) -> Bool { (a.x - midX) * (b.x - midX) < 0 }

        let dxWorld = abs(eW.x - sW.x)
        let dyWorld = abs(eW.y - sW.y)
        let travelNorm = hypot(dxWorld, dyWorld) / max(L, 1)
        let dyPxSigned = ePx.y - sPx.y
        let dyPx = abs(dyPxSigned)
        let isCross = crossCourt(sW, eW) && dxWorld >= 1.0
        let crossesNet = (sW.y - netY) * (eW.y - netY) < 0
        let shortTime = durationSec <= 0.52
        let mediumTime = durationSec <= 0.82
        let longTime = durationSec >= 0.72
        let nearStraight = dxWorld <= 1.1
        let steepDown = dyPxSigned >= 130
        let flatDrive = dyPx <= 110
        let startNearNet = nearNet(sW.y)
        let endNearNet = nearNet(eW.y)
        let endDeep = deep(eW.y)

        let shortServiceNear = netY - CGFloat(court.sSvc)
        let shortServiceFar = netY + CGFloat(court.sSvc)
        let startsNearServiceBand = abs(sW.y - shortServiceNear) <= 1.6 || abs(sW.y - shortServiceFar) <= 1.6
        if durationSec >= 0.22, durationSec <= 1.15, startsNearServiceBand, crossesNet, (travelNorm >= 0.10 && travelNorm <= 0.48) {
            return (.serve, 0.76)
        }

        if startNearNet && crossesNet && endDeep {
            if durationSec >= 0.95 || travelNorm > 0.34 || dyWorld > 3.0 {
                return (.clearLift, 0.64)
            }
            if shortTime || mediumTime {
                return (flatDrive ? .drive : .pushBlock, 0.58)
            }
        }

        if endNearNet {
            if isCross { return (.netCross, shortTime ? 0.70 : 0.64) }
            if durationSec >= 0.55 { return (.drop, 0.64) }
            return (.netShot, 0.66)
        }

        if endDeep && ((longTime && durationSec >= 1.08) || travelNorm > 0.42 || dyWorld > 3.6) {
            return (.clearLift, max(0.60, min(0.76, 0.60 + 0.09 * travelNorm)))
        }

        if shortTime {
            if steepDown && nearStraight { return (.smash, 0.64) }
            if flatDrive { return (.drive, 0.60) }
            if travelNorm < 0.26 { return (isCross ? .netCross : .netShot, 0.56) }
        }

        if mediumTime {
            if flatDrive && dyWorld >= 0.9 { return (.drive, 0.61) }
            if travelNorm < 0.42 { return (.pushBlock, 0.58) }
            if !endDeep && dyWorld < 2.0 { return (.drive, 0.57) }
        }

        if isLanding {
            if endDeep { return (.clearLift, 0.68) }
            if steepDown { return (.smash, 0.58) }
        }

        return (.unknown, 0.42)
    }

    private func detectHitIndices(_ valid: [(Double, SIMD3<Double>)]) -> [Int] {
        guard valid.count >= 5 else { return [] }
        var candidates: [Int] = []
        for i in 2..<(valid.count - 2) {
            let p0 = valid[i - 2].1
            let p1 = valid[i].1
            let p2 = valid[i + 2].1
            let v1 = SIMD3<Double>(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
            let v2 = SIMD3<Double>(p2.x - p1.x, p2.y - p1.y, p2.z - p1.z)
            let n1 = simd_length(v1)
            let n2 = simd_length(v2)
            guard n1 > 1e-6, n2 > 1e-6 else { continue }
            let d = max(-1.0, min(1.0, simd_dot(v1 / n1, v2 / n2)))
            let angle = acos(d) * 180 / .pi
            if angle > 28 { candidates.append(i) }
        }
        var deduped: [Int] = []
        for idx in candidates {
            if let last = deduped.last, idx - last < 8 { continue }
            deduped.append(idx)
        }
        return deduped
    }

    private func classifyShots(from points: [Stereo3DPoint]) -> [StereoShotEvent] {
        let validIndices = points.indices.compactMap { idx in
            points[idx].world3D == nil ? nil : idx
        }
        let valid = validIndices.compactMap { idx -> (Double, SIMD3<Double>)? in
            guard let p = points[idx].world3D else { return nil }
            return (points[idx].timeSec, p)
        }
        guard valid.count >= 8 else { return [] }

        let hitIdx = detectHitIndices(valid)
        guard hitIdx.count >= 2 else { return [] }

        var events: [StereoShotEvent] = []
        for pair in zip(hitIdx, hitIdx.dropFirst()) {
            let startValid = pair.0
            let endValid = pair.1
            guard endValid - startValid >= 2 else { continue }
            let startIndex = validIndices[startValid]
            let endIndex = validIndices[endValid]
            let segment = Array(points[startIndex...endIndex]).filter { $0.world3D != nil }
            let isLanding = endValid == valid.count - 1
            guard let shot = classifySegment(segment, isLanding: isLanding) else { continue }
            events.append(shot)
        }
        return events
    }

    private func classifySegment(_ segment: [Stereo3DPoint], isLanding: Bool) -> StereoShotEvent? {
        guard let first = segment.first, let last = segment.last,
              let start = first.world3D, let end = last.world3D else { return nil }
        let duration = max(1e-6, last.timeSec - first.timeSec)
        let halfL = Double(court.halfL)
        let startNear = start.y < halfL
        let peakZ = segment.compactMap { $0.world3D?.z }.max() ?? max(start.z, end.z)
        let horizDist = simd_length(SIMD2<Double>(end.x - start.x, end.y - start.y))
        let avgHorizSpeed = horizDist / duration
        let netHeight = estimateNetHeight(segment.map { ($0.timeSec, $0.world3D!) })
        let crossesNet = segment.contains { ($0.world3D?.y ?? 0) < halfL } && segment.contains { ($0.world3D?.y ?? 0) > halfL }
        let lateralDisp = abs(end.x - start.x)
        let endFront = startNear ? (end.y > halfL && end.y < halfL + 2.2) : (end.y < halfL && end.y > halfL - 2.2)
        let endMid = startNear ? (end.y >= halfL + 2.2 && end.y < Double(court.L) - 2.6) : (end.y <= halfL - 2.2 && end.y > 2.6)
        let endRear = startNear ? (end.y >= Double(court.L) - 2.6) : (end.y <= 2.6)
        let startNearNet = abs(start.y - halfL) < 1.5
        let endNearNet = abs(end.y - halfL) < 1.5
        let tailIdx = max(0, segment.count - 3)
        let tailDt = max(1e-6, last.timeSec - segment[tailIdx].timeSec)
        let descendRate = (segment.last!.world3D!.z - segment[tailIdx].world3D!.z) / tailDt

        var scores: [StereoShotType: Double] = [.unknown: 0.1]
        func add(_ type: StereoShotType, _ value: Double) { scores[type, default: 0] += value }

        if startNearNet && endNearNet && peakZ < 1.8 {
            add(.netShot, 2.8)
            if lateralDisp > 1.6 { add(.netCross, 3.2) } else { add(.netShot, 1.2) }
        }

        if crossesNet {
            if peakZ > 4.8 { add(.clearLift, 2.8) }
            if duration > 0.9 { add(.clearLift, 1.2) }
            if endRear { add(.clearLift, 2.2) }
            if let netHeight, netHeight > 2.0 { add(.clearLift, 1.4) }

            if peakZ < 4.2 { add(.drop, 0.8) }
            if endFront { add(.drop, 2.4) }
            if let netHeight, netHeight < 1.8 { add(.drop, 1.6) }
            if descendRate < -1.6 { add(.drop, 0.7) }

            if avgHorizSpeed > 6.5 { add(.smash, 2.0) }
            if duration < 0.8 { add(.smash, 1.2) }
            if let netHeight, netHeight < 1.55 { add(.smash, 1.4) }
            if descendRate < -3.0 { add(.smash, 1.6) }
            if peakZ < 3.8 { add(.smash, 0.8) }
            if endFront || endMid { add(.smash, 0.8) }

            if avgHorizSpeed > 4.5 && avgHorizSpeed < 8.5 { add(.drive, 1.6) }
            if peakZ > 1.0 && peakZ < 3.6 { add(.drive, 1.4) }
            if let netHeight, netHeight > 1.0 && netHeight < 2.2 { add(.drive, 1.4) }
            if duration < 0.85 { add(.drive, 1.0) }
            if endMid { add(.drive, 0.8) }

            if peakZ < 3.2 { add(.pushBlock, 1.3) }
            if endMid { add(.pushBlock, 1.6) }
            if duration < 0.9 { add(.pushBlock, 1.0) }
            if let netHeight, netHeight > 1.0 && netHeight < 2.4 { add(.pushBlock, 1.2) }
        }

        let sorted = scores.sorted { $0.value > $1.value }
        guard let best = sorted.first else { return nil }
        let second = sorted.dropFirst().first?.value ?? 0
        let total = max(1e-6, scores.values.reduce(0, +))
        let conf3D = min(0.98, max(0.35, (best.value - second + 0.6) / total + 0.35))
        let type3D: StereoShotType = best.value < 2.4 ? .unknown : best.key

        let fallback = singleCameraFallbackClassification(first: first, last: last, durationSec: duration, isLanding: isLanding)
        let chosenType: StereoShotType
        let chosenConfidence: Double
        if fallback.0 != .unknown {
            chosenType = fallback.0
            chosenConfidence = max(fallback.1, conf3D * (type3D == .unknown ? 0.55 : 0.72))
        } else {
            chosenType = type3D
            chosenConfidence = conf3D
        }

        return StereoShotEvent(
            startTime: first.timeSec,
            endTime: last.timeSec,
            startFrameA: first.frameA,
            endFrameA: last.frameA,
            startPoint: start,
            endPoint: end,
            peakHeight: peakZ,
            netHeight: netHeight,
            type: chosenType,
            confidence: chosenConfidence
        )
    }

    private func singleCameraFallbackClassification(first: Stereo3DPoint, last: Stereo3DPoint, durationSec: Double, isLanding: Bool) -> (StereoShotType, Double) {
        guard let startPx = first.imageA, let endPx = last.imageA else {
            return (.unknown, 0.35)
        }
        let startWorld = first.groundA ?? CGPoint(x: first.world3D?.x ?? 0, y: first.world3D?.y ?? 0)
        let endWorld = last.groundA ?? CGPoint(x: last.world3D?.x ?? 0, y: last.world3D?.y ?? 0)

        let W = CGFloat(court.W)
        let L = CGFloat(court.L)
        let netY = CGFloat(court.halfL)
        let midX = W / 2.0

        func nearNet(_ y: CGFloat) -> Bool { abs(y - netY) <= 1.10 }
        func deep(_ y: CGFloat) -> Bool { y <= 1.50 || y >= (L - 1.50) }
        func crossCourt(_ a: CGPoint, _ b: CGPoint) -> Bool { (a.x - midX) * (b.x - midX) < 0 }

        let dxWorld = abs(endWorld.x - startWorld.x)
        let dyWorld = abs(endWorld.y - startWorld.y)
        let travelNorm = hypot(dxWorld, dyWorld) / max(L, 1)
        let dyPxSigned = endPx.y - startPx.y
        let dyPx = abs(dyPxSigned)
        let isCross = crossCourt(startWorld, endWorld) && dxWorld >= 1.0
        let shortTime = durationSec <= 0.52
        let longTime = durationSec >= 0.72
        let nearStraight = dxWorld <= 1.1
        let steepDown = dyPxSigned >= 130
        let flatDrive = dyPx <= 110

        if nearNet(endWorld.y) {
            if isCross { return (.netCross, shortTime ? 0.70 : 0.64) }
            if longTime { return (.drop, 0.64) }
            return (.netShot, 0.66)
        }

        if deep(endWorld.y) && longTime {
            return (.clearLift, max(0.62, min(0.78, 0.64 + 0.12 * travelNorm)))
        }

        if shortTime {
            if steepDown && nearStraight {
                return (.smash, 0.64)
            }
            if flatDrive {
                return (.drive, 0.60)
            }
            if travelNorm < 0.26 {
                return (isCross ? .netCross : .netShot, 0.56)
            }
        }

        if durationSec <= 0.70 && travelNorm < 0.45 {
            return (.pushBlock, 0.56)
        }

        if isLanding {
            if deep(endWorld.y) {
                return (.clearLift, 0.68)
            }
            if steepDown {
                return (.smash, 0.58)
            }
        }

        return (.unknown, 0.42)
    }

    private func estimateNetHeight(_ segment: [(Double, SIMD3<Double>)]) -> Double? {
        let halfL = Double(court.halfL)
        guard segment.count >= 2 else { return nil }
        for i in 0..<(segment.count - 1) {
            let a = segment[i].1
            let b = segment[i + 1].1
            if (a.y - halfL) == 0 { return a.z }
            if (a.y - halfL) * (b.y - halfL) <= 0, abs(b.y - a.y) > 1e-6 {
                let t = (halfL - a.y) / (b.y - a.y)
                return a.z + (b.z - a.z) * t
            }
        }
        return nil
    }

    private func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let na = simd_length(a)
        let nb = simd_length(b)
        guard na > 1e-9, nb > 1e-9 else { return 0 }
        let d = max(-1.0, min(1.0, simd_dot(a / na, b / nb)))
        return acos(d) * 180.0 / .pi
    }
}


private struct CalibrationTutorialScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Calibration Tutorial")
                        .font(.system(size: 28, weight: .bold))
                    Text("Calibrate the court using four outside corners and the two top ends of the net.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TutorialDiagramCard()

                tutorialStep(number: "1", title: "Choose a clear frame", body: "Choose a frame that clearly shows all four court corners and both top ends of the net.")
                tutorialStep(number: "2", title: "Mark the four outside corners", body: "Tap the outside corners in order: near left, near right, far right, far left.")
                tutorialStep(number: "3", title: "Mark both top ends of the net", body: "Tap the left end of the net’s top edge, then the right end.")
                tutorialStep(number: "4", title: "Check the court overlay", body: "If the overlay misses the court lines, use Reset and mark the points again.")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Tips")
                        .font(.headline)
                    bullet("More accurate corners improve landing estimates and 3D reconstruction.")
                    bullet("If a net endpoint is obscured, choose a clearer frame when possible.")
                    bullet("Calibrate both camera views before running dual-camera analysis.")
                }
                .padding(18)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Calibration Tutorial")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func tutorialStep(number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.blue, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.blue).frame(width: 6, height: 6).padding(.top, 6)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TutorialDiagramCard: View {
    private let courtRatio: CGFloat = 13.4 / 6.1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Court reference points")
                .font(.headline)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let maxCourtHeight = h * 0.82
                let maxCourtWidth = w * 0.42
                let courtWidth = min(maxCourtWidth, maxCourtHeight / courtRatio)
                let courtHeight = courtWidth * courtRatio
                let rect = CGRect(
                    x: (w - courtWidth) / 2,
                    y: (h - courtHeight) / 2,
                    width: courtWidth,
                    height: courtHeight
                )
                let netY = rect.midY
                let leftNet = CGPoint(x: rect.minX, y: netY)
                let rightNet = CGPoint(x: rect.maxX, y: netY)
                let points: [(String, CGPoint, Color, CGSize)] = [
                    ("TL", CGPoint(x: rect.minX, y: rect.minY), .blue, CGSize(width: -8, height: -18)),
                    ("TR", CGPoint(x: rect.maxX, y: rect.minY), .blue, CGSize(width: 8, height: -18)),
                    ("BL", CGPoint(x: rect.minX, y: rect.maxY), .blue, CGSize(width: -8, height: 18)),
                    ("BR", CGPoint(x: rect.maxX, y: rect.maxY), .blue, CGSize(width: 8, height: 18)),
                    ("Net-L", leftNet, .green, CGSize(width: -34, height: 0)),
                    ("Net-R", rightNet, .green, CGSize(width: 34, height: 0))
                ]

                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.05, green: 0.06, blue: 0.09))

                    Path { p in
                        p.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
                        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                        p.move(to: CGPoint(x: rect.minX, y: netY))
                        p.addLine(to: CGPoint(x: rect.maxX, y: netY))
                    }
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

                    ForEach(0..<points.count, id: \.self) { idx in
                        let item = points[idx]
                        ZStack {
                            Circle()
                                .fill(item.2)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            Text(item.0)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .offset(item.3)
                        }
                        .position(item.1)
                    }
                }
            }
            .frame(height: 320)
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
}
