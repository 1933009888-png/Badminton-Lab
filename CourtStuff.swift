import SwiftUI
import UIKit
import AVFoundation
import CoreGraphics
import Combine
import simd

// MARK: - Controls UI
struct ControlsBar: View {
    @Binding var showSingles: Bool
    @Binding var showNet: Bool
    @Binding var showService: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $showSingles) { Text("Singles") }.toggleStyle(.button)
            Toggle(isOn: $showNet) { Text("Net") }.toggleStyle(.button)
            Toggle(isOn: $showService) { Text("Service Lines") }.toggleStyle(.button)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 20)
    }
}

// MARK: - Court mode
enum PlayMode { case singles, doubles }

// MARK: - Badminton court geometry & styling (x = width 0..W, y = length 0..L)
struct BadmintonCourt {
    // BWF dimensions (meters)
    let L: Double = 13.40
    let W: Double = 6.10
    let singlesW: Double = 5.18
    let sSvc: Double = 1.98      // short-service distance from net (y)
    let dLong: Double = 0.76     // doubles long-service distance from baseline (y)
    let lineWidth: Double = 0.04 // official court line width (40 mm)
    
    // Derived
    var halfL: Double { L / 2.0 }                      // 6.70
    var halfW: Double { W / 2.0 }                      // 3.05
    var singlesInset: Double { (W - singlesW) / 2.0 }  // 0.46
    var xS1: Double { singlesInset }                   // 0.46
    var xS2: Double { W - singlesInset }               // 5.64
    var doublesServiceDepth: Double { halfL - sSvc - dLong } // ≈3.96 m
    
    /// Tap targets (outer doubles rectangle), order: BL → BR → TR → TL
    var cornerWorldPoints: [CGPoint] {
        [CGPoint(x: 0,  y: 0),
         CGPoint(x: W,  y: 0),
         CGPoint(x: W,  y: L),
         CGPoint(x: 0,  y: L)]
    }

    // Exposed key line coordinates as CGFloat for anchors
    var x0: CGFloat { CGFloat(0.0) }
    var xW: CGFloat { CGFloat(W) }
    var xMid: CGFloat { CGFloat(halfW) }
    var xS1cg: CGFloat { CGFloat(xS1) }
    var xS2cg: CGFloat { CGFloat(xS2) }
    var y0: CGFloat { CGFloat(0.0) }
    var yL: CGFloat { CGFloat(L) }
    var yNet: CGFloat { CGFloat(halfL) }
    var yShortNear: CGFloat { CGFloat(halfL - sSvc) }
    var yShortFar: CGFloat { CGFloat(halfL + sSvc) }
    var yDoublesNear: CGFloat { CGFloat(dLong) }
    var yDoublesFar: CGFloat { CGFloat(L - dLong) }
    
    // MARK: Helpers
    
    /// Add a horizontal at y. In Singles, splits into dotted ends + centered 5.18 m span.
    private func addHorizontal(
        y: Double,
        singlesCenterStyleIsSolid: Bool,
        mode: PlayMode,
        solid: inout [(CGPoint,CGPoint)],
        dotted: inout [(CGPoint,CGPoint)]
    ) {
        switch mode {
        case .doubles:
            solid.append((CGPoint(x: 0, y: y), CGPoint(x: W, y: y)))
        case .singles:
            dotted.append((CGPoint(x: 0,   y: y), CGPoint(x: xS1, y: y)))    // left trimmed
            if singlesCenterStyleIsSolid {
                solid.append((CGPoint(x: xS1, y: y), CGPoint(x: xS2, y: y))) // 5.18 m center
            } else {
                dotted.append((CGPoint(x: xS1, y: y), CGPoint(x: xS2, y: y)))
            }
            dotted.append((CGPoint(x: xS2, y: y), CGPoint(x: W,   y: y)))    // right trimmed
        }
    }
    
    /// Split a horizontal into pieces according to mode (used for dotted fallback drawing).
    private func horizontalPieces(y: Double, mode: PlayMode) -> [(CGPoint, CGPoint)] {
        if mode == .doubles {
            return [(CGPoint(x: 0, y: y), CGPoint(x: W, y: y))]
        } else {
            return [
                (CGPoint(x: 0,   y: y), CGPoint(x: xS1, y: y)),
                (CGPoint(x: xS1, y: y), CGPoint(x: xS2, y: y)), // 5.18 m center
                (CGPoint(x: xS2, y: y), CGPoint(x: W,   y: y))
            ]
        }
    }
    
    /// For “draw dotted when Service toggle is OFF”: all service-related pieces for the current mode.
    func serviceSegments(mode: PlayMode) -> [(CGPoint, CGPoint)] {
        var segs: [(CGPoint, CGPoint)] = []
        
        let yShortNear = halfL - sSvc
        let yShortFar  = halfL + sSvc
        
        // Short service (both halves)
        segs += horizontalPieces(y: yShortNear, mode: mode)
        segs += horizontalPieces(y: yShortFar,  mode: mode)
        
        // Long service lines (0.76 m from baselines) exist in both modes
        segs += horizontalPieces(y: dLong,      mode: mode)
        segs += horizontalPieces(y: L - dLong,  mode: mode)
        
        // Center-line portions (vertical at mid-width)
        let yBackNear = (mode == .singles) ? 0.0 : dLong
        let yBackFar  = (mode == .singles) ? L   : (L - dLong)
        segs.append((CGPoint(x: halfW, y: yBackNear), CGPoint(x: halfW, y: yShortNear)))
        segs.append((CGPoint(x: halfW, y: yShortFar),  CGPoint(x: halfW, y: yBackFar)))
        
        return segs
    }
    
    // MARK: Styled segments for overlay (solid vs dotted), including “doubles serve” baseline logic.
    func styledSegments(
        mode: PlayMode,
        includeNet: Bool,
        includeService: Bool
    ) -> (solid: [(CGPoint,CGPoint)], dotted: [(CGPoint,CGPoint)]) {
        var solid:  [(CGPoint,CGPoint)] = []
        var dotted: [(CGPoint,CGPoint)] = []

        // --- Sidelines ---
        if mode == .doubles {
            if includeService {
                // Doubles service view:
                // Outer (doubles) sidelines = SOLID only between long-service lines (11.88 m),
                // dotted stubs up to the baselines.
                let y0 = dLong            // 0.76
                let y1 = L - dLong        // 12.64

                // Left outer
                dotted.append((CGPoint(x: 0, y: 0),  CGPoint(x: 0, y: y0)))
                solid.append( (CGPoint(x: 0, y: y0), CGPoint(x: 0, y: y1)))
                dotted.append((CGPoint(x: 0, y: y1), CGPoint(x: 0, y: L)))

                // Right outer
                dotted.append((CGPoint(x: W, y: 0),  CGPoint(x: W, y: y0)))
                solid.append( (CGPoint(x: W, y: y0), CGPoint(x: W, y: y1)))
                dotted.append((CGPoint(x: W, y: y1), CGPoint(x: W, y: L)))

                // Singles sidelines visible as dotted full height
                dotted.append((CGPoint(x: xS1, y: 0), CGPoint(x: xS1, y: L)))
                dotted.append((CGPoint(x: xS2, y: 0), CGPoint(x: xS2, y: L)))
            } else {
                // Regular doubles view (non-service emphasis): outer sidelines solid full height
                solid.append((CGPoint(x: 0, y: 0), CGPoint(x: 0, y: L)))
                solid.append((CGPoint(x: W, y: 0), CGPoint(x: W, y: L)))
                // Singles sidelines dotted full height
                dotted.append((CGPoint(x: xS1, y: 0), CGPoint(x: xS1, y: L)))
                dotted.append((CGPoint(x: xS2, y: 0), CGPoint(x: xS2, y: L)))
            }
        } else {
            // Singles mode: singles = SOLID, doubles = DOTTED reference
            dotted.append((CGPoint(x: 0, y: 0), CGPoint(x: 0, y: L)))
            dotted.append((CGPoint(x: W, y: 0), CGPoint(x: W, y: L)))
            solid.append((CGPoint(x: xS1, y: 0), CGPoint(x: xS1, y: L)))
            solid.append((CGPoint(x: xS2, y: 0), CGPoint(x: xS2, y: L)))
        }

        // --- Baselines ---
        if mode == .singles {
            // Singles: baselines solid in the 5.18 m span, dotted on the trimmed ends
            addHorizontal(y: 0, singlesCenterStyleIsSolid: true,  mode: mode, solid: &solid, dotted: &dotted)
            addHorizontal(y: L, singlesCenterStyleIsSolid: true,  mode: mode, solid: &solid, dotted: &dotted)
        } else {
            if includeService {
                // Doubles service focus: baselines are reference → dotted full width
                dotted.append((CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0)))
                dotted.append((CGPoint(x: 0, y: L), CGPoint(x: W, y: L)))
            } else {
                // Regular doubles: baselines solid
                solid.append((CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0)))
                solid.append((CGPoint(x: 0, y: L), CGPoint(x: W, y: L)))
            }
        }

        // --- Net (mid-court, horizontal)
        if includeNet {
            addHorizontal(y: halfL, singlesCenterStyleIsSolid: true, mode: mode, solid: &solid, dotted: &dotted)
        }

        // --- Service markings
        if includeService {
            // Short service (±1.98 m from net)
            addHorizontal(y: halfL - sSvc, singlesCenterStyleIsSolid: true, mode: mode, solid: &solid, dotted: &dotted)
            addHorizontal(y: halfL + sSvc, singlesCenterStyleIsSolid: true, mode: mode, solid: &solid, dotted: &dotted)

            // Center line:
            // Singles: baseline ↔ short-service
            // Doubles: long-service ↔ short-service (depth ≈ 3.96 m)
            let yShortNear = halfL - sSvc
            let yShortFar  = halfL + sSvc
            let yBackNear  = (mode == .singles) ? 0.0 : dLong
            let yBackFar   = (mode == .singles) ? L   : (L - dLong)
            solid.append((CGPoint(x: halfW, y: yBackNear), CGPoint(x: halfW, y: yShortNear)))
            solid.append((CGPoint(x: halfW, y: yShortFar),  CGPoint(x: halfW, y: yBackFar)))

            // Long service lines
            if mode == .doubles {
                addHorizontal(y: dLong,     singlesCenterStyleIsSolid: true,  mode: mode, solid: &solid, dotted: &dotted)
                addHorizontal(y: L - dLong, singlesCenterStyleIsSolid: true,  mode: mode, solid: &solid, dotted: &dotted)
            } else {
                addHorizontal(y: dLong,     singlesCenterStyleIsSolid: false, mode: mode, solid: &solid, dotted: &dotted)
                addHorizontal(y: L - dLong, singlesCenterStyleIsSolid: false, mode: mode, solid: &solid, dotted: &dotted)
            }
        }

        return (solid, dotted)
    }

    /// Classify a world-space point as IN/OUT and whether it sits on a boundary line, accounting for line thickness.
    /// - Parameters:
    ///   - p: world coordinate (meters)
    ///   - mode: singles or doubles (affects lateral bounds)
    ///   - extraTolerance: additional tolerance (meters) to absorb calibration error (default half a line)
    /// - Returns: (inBounds, onLine)
    func classify(point p: CGPoint, mode: PlayMode, extraTolerance: Double = 0.02) -> (inBounds: Bool, onLine: Bool) {
        // Active lateral bounds
        let leftX: Double
        let rightX: Double
        switch mode {
        case .singles:
            leftX = xS1
            rightX = xS2
        case .doubles:
            leftX = 0.0
            rightX = W
        }
        let nearY: Double = 0.0
        let farY: Double = L
        // Effective tolerance: half line width + user-provided extra (for calibration imprecision)
        let tol = (lineWidth * 0.5) + extraTolerance
        let x = Double(p.x)
        let y = Double(p.y)
        // Distances to each boundary line (signed so negative means outside on that side)
        let dxLeft  = x - leftX
        let dxRight = rightX - x
        let dyNear  = y - nearY
        let dyFar   = farY - y
        // On-line checks (within half line width + extraTolerance of any boundary) while still not wildly outside the opposite side
        let onLeft  = abs(dxLeft) <= tol && dxRight >= -tol && dyNear >= -tol && dyFar >= -tol
        let onRight = abs(dxRight) <= tol && dxLeft >= -tol && dyNear >= -tol && dyFar >= -tol
        let onNear  = abs(dyNear) <= tol && dyFar >= -tol && dxLeft >= -tol && dxRight >= -tol
        let onFar   = abs(dyFar) <= tol && dyNear >= -tol && dxLeft >= -tol && dxRight >= -tol
        let onLine = onLeft || onRight || onNear || onFar
        // In-bounds if inside expanded rectangle (allow outside up to tol) but not clearly past all tolerance
        let inExpanded = (dxLeft >= -tol && dxRight >= -tol && dyNear >= -tol && dyFar >= -tol)
        // True in-bounds means point center is within the nominal rectangle OR within its tolerated boundary thickness
        let inBounds = inExpanded
        return (inBounds, onLine)
    }
    
    enum ShotStatus { case inside, onLine, outside }
    struct InOutResult { let status: ShotStatus; var isIn: Bool { status != .outside } }
    
    /// More detailed classification of a world-space point treating boundary paint as 40 mm wide.
    /// - Parameters:
    ///   - p: world coordinate (meters, x=width, y=length)
    ///   - mode: singles or doubles (affects lateral playable extent)
    ///   - tolerance: extra slack (meters) to absorb reprojection/calibration error (~1 cm default)
    ///   - useServiceLines: when true, classify using service-court bounds (short/long service lines)
    func classifyPlay(point p: CGPoint, mode: PlayMode, tolerance: Double = 0.01, useServiceLines: Bool = false) -> InOutResult {
        let halfPaint = lineWidth * 0.5
        let x = Double(p.x)
        let y = Double(p.y)

        // Long (y) boundaries for normal play
        let minYOuter = 0.0 - halfPaint
        let maxYOuter = L + halfPaint

        // Lateral playable span differs by mode
        let (minXInner, maxXInner): (Double, Double) = {
            switch mode {
            case .doubles: return (0.0, W)
            case .singles: return (xS1, xS2) // singles sidelines
            }
        }()
        let minXOuter = minXInner - halfPaint
        let maxXOuter = maxXInner + halfPaint

        if useServiceLines {
            // Service-court bounds (y) depend on mode
            let yShortNear = halfL - sSvc
            let yShortFar  = halfL + sSvc
            let yLongNear: Double = (mode == .singles) ? 0.0 : dLong
            let yLongFar: Double  = (mode == .singles) ? L   : (L - dLong)

            let tol = halfPaint + tolerance
            let inX = (x >= (minXInner - tol) && x <= (maxXInner + tol))
            let inServiceY = (y >= (yLongNear - tol) && y <= (yShortNear + tol)) ||
                             (y >= (yShortFar - tol)  && y <= (yLongFar + tol))
            if !inX || !inServiceY {
                return InOutResult(status: .outside)
            }

            let onPlayableXLine = (mode == .doubles)
                ? (abs(x - 0.0) <= tol || abs(x - W) <= tol)
                : (abs(x - xS1) <= tol || abs(x - xS2) <= tol)
            let onServiceShort = abs(y - yShortNear) <= tol || abs(y - yShortFar) <= tol
            let onServiceLong  = abs(y - yLongNear) <= tol || abs(y - yLongFar) <= tol
            let onCenterLine   = abs(x - halfW) <= tol

            if onPlayableXLine || onServiceShort || onServiceLong || onCenterLine {
                return InOutResult(status: .onLine)
            }
            return InOutResult(status: .inside)
        }

        // Quick rejection fully outside expanded paint rectangle (with tolerance)
        if x < (minXOuter - tolerance) || x > (maxXOuter + tolerance) ||
           y < (minYOuter - tolerance) || y > (maxYOuter + tolerance) {
            return InOutResult(status: .outside)
        }

        // Strict interior excludes the paint (halfPaint + tolerance inward from each playable edge)
        let strictlyInside = (x > (minXInner + halfPaint + tolerance)) && (x < (maxXInner - halfPaint - tolerance)) &&
                              (y > (0.0 + halfPaint + tolerance)) && (y < (L - halfPaint - tolerance))
        if strictlyInside { return InOutResult(status: .inside) }

        // Determine if we are on one of the in-play lines (singles sidelines or baselines)
        let onPlayableXLine: Bool = {
            if mode == .doubles {
                return abs(x - 0.0) <= (halfPaint + tolerance) || abs(x - W) <= (halfPaint + tolerance)
            } else {
                return abs(x - xS1) <= (halfPaint + tolerance) || abs(x - xS2) <= (halfPaint + tolerance)
            }
        }()
        let onBaseline = abs(y - 0.0) <= (halfPaint + tolerance) || abs(y - L) <= (halfPaint + tolerance)

        if onPlayableXLine || onBaseline { return InOutResult(status: .onLine) }

        // If singles mode and we are near OUTER doubles lines, those are out (already not strictly inside and not on playable line)
        return InOutResult(status: .outside)
    }
}
    
    // MARK: - Homography (planar projective transform)
    struct Homography {
        let h: simd_double3x3 // 3x3 row-major

        // world (X,Y) -> image (u,v)
        func project(_ p: CGPoint) -> CGPoint {
            let X = simd_double3(Double(p.x), Double(p.y), 1.0)
            let r = h * X
            let u = r.x / r.z
            let v = r.y / r.z
            return CGPoint(x: u, y: v)
        }

        // image (u,v) -> world (X,Y)
        func unproject(_ p: CGPoint) -> CGPoint? {
            let inv = h.inverse
            let U = simd_double3(Double(p.x), Double(p.y), 1.0)
            let r = inv * U
            let w = r.z
            guard abs(w) > 1e-12 else { return nil }
            return CGPoint(x: r.x / w, y: r.y / w)
        }

        static func estimate(world W: [CGPoint], image I: [CGPoint]) -> Homography? {
            guard W.count == 4, I.count == 4 else { return nil }
            var A = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
            var b = Array(repeating: 0.0, count: 8)

            for i in 0..<4 {
                let x = Double(W[i].x), y = Double(W[i].y)
                let u = Double(I[i].x), v = Double(I[i].y)
                let r1 = 2*i, r2 = 2*i+1
                A[r1][0] = x; A[r1][1] = y; A[r1][2] = 1
                A[r1][6] = -u * x; A[r1][7] = -u * y; b[r1] = u
                A[r2][3] = x; A[r2][4] = y; A[r2][5] = 1
                A[r2][6] = -v * x; A[r2][7] = -v * y; b[r2] = v
            }

            guard let hVec = gaussianSolve8x8(A: A, b: b) else { return nil }
            let h11 = hVec[0], h12 = hVec[1], h13 = hVec[2]
            let h21 = hVec[3], h22 = hVec[4], h23 = hVec[5]
            let h31 = hVec[6], h32 = hVec[7]
            let H = simd_double3x3(rows: [
                simd_double3(h11, h12, h13),
                simd_double3(h21, h22, h23),
                simd_double3(h31, h32, 1.0)
            ])
            return Homography(h: H)
        }
    }

    
    // MARK: - Simple Gaussian elimination for 8x8
    fileprivate func gaussianSolve8x8(A: [[Double]], b: [Double]) -> [Double]? {
        var M = A
        var y = b
        let n = 8
        
        // Forward elimination with partial pivoting
        for k in 0..<n {
            var pivotRow = k
            var maxVal = abs(M[k][k])
            for r in (k+1)..<n {
                if abs(M[r][k]) > maxVal { maxVal = abs(M[r][k]); pivotRow = r }
            }
            if maxVal < 1e-12 { return nil }
            if pivotRow != k { M.swapAt(k, pivotRow); y.swapAt(k, pivotRow) }
            
            let piv = M[k][k]
            for j in k..<n { M[k][j] /= piv }
            y[k] /= piv
            
            for i in (k+1)..<n {
                let f = M[i][k]; if f == 0 { continue }
                for j in k..<n { M[i][j] -= f * M[k][j] }
                y[i] -= f * y[k]
            }
        }
        
        // Back substitution
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n-1, through: 0, by: -1) {
            var sum = y[i]
            for j in (i+1)..<n { sum -= M[i][j] * x[j] }
            x[i] = sum
        }
        return x
    }
    
    // MARK: - Overlay: Draw court lines transformed to image space
    struct CourtOverlay: View {
        let size: CGSize
        let homography: Homography
        let court: BadmintonCourt
        let showSingles: Bool     // acts as the mode switch
        let showNet: Bool
        let showService: Bool
        
        var body: some View {
            Canvas { ctx, _ in
                let mode: PlayMode = showSingles ? .singles : .doubles
                let (solidSegs, dottedSegs) = court.styledSegments(
                    mode: mode,
                    includeNet: showNet,
                    includeService: showService
                )
                
                // SOLID (in-use lines)
                var solidPath = Path()
                for (p0, p1) in solidSegs {
                    let q0 = homography.project(p0)
                    let q1 = homography.project(p1)
                    solidPath.move(to: q0)
                    solidPath.addLine(to: q1)
                }
                ctx.stroke(solidPath, with: .color(.green), lineWidth: 3)
                
                // DOTTED (not-in-use/reference lines)
                var dottedPath = Path()
                for (p0, p1) in dottedSegs {
                    let q0 = homography.project(p0)
                    let q1 = homography.project(p1)
                    dottedPath.move(to: q0)
                    dottedPath.addLine(to: q1)
                }
                
                // Even if Service Lines toggle is OFF, still display them as dotted
                if !showService {
                    let mode: PlayMode = showSingles ? .singles : .doubles
                    for (p0, p1) in court.serviceSegments(mode: mode) {
                        let q0 = homography.project(p0)
                        let q1 = homography.project(p1)
                        dottedPath.move(to: q0)
                        dottedPath.addLine(to: q1)
                    }
                }
                
                ctx.stroke(
                    dottedPath,
                    with: .color(.yellow),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6])
                )
            }
            .allowsHitTesting(false)
        }
    }
    
    /// Overlay that darkens everything outside the active court rectangle (singles or doubles), using even-odd fill.
    struct CourtMaskOverlay: View {
        let size: CGSize
        let homography: Homography
        let court: BadmintonCourt
        let singles: Bool
        var body: some View {
            Canvas { ctx, _ in
                let leftX = singles ? court.xS1 : 0.0
                let rightX = singles ? court.xS2 : court.W
                let bottomY: Double = 0.0
                let topY: Double = court.L
                let world = [
                    CGPoint(x: leftX,  y: bottomY),
                    CGPoint(x: rightX, y: bottomY),
                    CGPoint(x: rightX, y: topY),
                    CGPoint(x: leftX,  y: topY)
                ]
                let imgPts = world.map { homography.project($0) }
                var path = Path()
                path.addRect(CGRect(origin: .zero, size: size))
                if let first = imgPts.first {
                    path.move(to: first)
                    path.addLines(imgPts)
                    path.closeSubpath()
                }
                ctx.fill(path, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
        }
    }
    
    // MARK: - Overlay: Draggable handles for calibration
    struct CalibrationHandlesOverlay: View {
        @Binding var taps: [CGPoint]
        var labels: [String] = ["BL", "BR", "TR", "TL"]
        var allowEditing: Bool = true

        private func labelOffset(for label: String) -> CGSize {
            switch label {
            case "BL": return CGSize(width: 15, height: -10)
            case "BR": return CGSize(width: -15, height: -10)
            case "TL": return CGSize(width: 15, height: 10)
            case "TR": return CGSize(width: -15, height: 10)
            case "NL", "N-L": return CGSize(width: -20, height: -12)
            case "NR", "N-R": return CGSize(width: 20, height: -12)
            default: return CGSize(width: 0, height: -12)
            }
        }

        var body: some View {
            ZStack {
                if !taps.isEmpty {
                    Path { path in
                        let courtPts = Array(taps.prefix(min(4, taps.count)))
                        if courtPts.count > 1 {
                            path.addLines(courtPts)
                            if courtPts.count == 4 { path.closeSubpath() }
                        }
                        if taps.count >= 6 {
                            path.move(to: taps[4])
                            path.addLine(to: taps[5])
                        }
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1.8, dash: [6, 6]))
                    .foregroundColor(.yellow)
                    .allowsHitTesting(false)
                }

                ForEach(Array(taps.enumerated()), id: \.offset) { idx, pt in
                    let label = labels.indices.contains(idx) ? labels[idx] : "\(idx+1)"
                    let offset = labelOffset(for: label)
                    ZStack {
                        Circle().fill(.blue.opacity(0.20)).frame(width: 14, height: 14)
                        Circle().fill(.white).frame(width: 8, height: 8)
                        Circle().fill(.blue).frame(width: 4, height: 4)
                    }
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .center) {
                        Text(label)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.76), in: Capsule())
                            .offset(x: offset.width, y: offset.height)
                    }
                    .contentShape(Circle())
                    .position(pt)
                    .allowsHitTesting(allowEditing)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard allowEditing else { return }
                                taps[idx] = value.location
                            }
                    )
                }
            }
        }
    }

    // MARK: - Camera Preview Boilerplate
    final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        @Published var isConfigured = false
        let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "camera_session_queue")
        
        func configure() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                sessionQueue.async { self.setupSession() }
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        self.sessionQueue.async { self.setupSession() }
                    }
                }
            default:
                print("Camera access denied in Settings")
                return
            }
        }
        
        private func setupSession() {
            session.beginConfiguration()
            session.sessionPreset = .high
            
            // Input
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            
            // Output
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: sessionQueue)
            
            if session.canAddOutput(output) {
                session.addOutput(output)
                // Optional: set video orientation if needed, but usually preview layer handles display orientation
                // and for processing we might need to handle rotation manually or here.
                // For now, let's just get the frames flowing.
            }
            
            session.commitConfiguration()
            
            if !session.isRunning {
                session.startRunning()
            }
            
            DispatchQueue.main.async {
                self.isConfigured = true
            }
        }
        
        // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            // This is where frames arrive on sessionQueue.
            // TODO: Feed this into YOLO / tracking pipeline.
            // print("Frame received") // Uncomment for debug
        }
    }
    
    struct CameraPreview: UIViewRepresentable {
        let session: AVCaptureSession
        func makeUIView(context: Context) -> PreviewView {
            let v = PreviewView()
            v.videoPreviewLayer.session = session
            v.videoPreviewLayer.videoGravity = .resizeAspectFill
            return v
        }
        func updateUIView(_ uiView: PreviewView, context: Context) {}
    }
    
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
