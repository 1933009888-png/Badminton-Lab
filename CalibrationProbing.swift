//
//  CalibrationProbing.swift
//  Badminton Lab
//
//  Created by Kyle on 30/10/2025.
//

import SwiftUI
import simd
import CoreGraphics

// 1) Safer (X,Y) pill that never leaves the visible area
// Helpers to measure the pill size
private struct _SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
private struct _MeasureSize: ViewModifier {
    @Binding var size: CGSize
    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: _SizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(_SizeKey.self) { self.size = $0 }
    }
}
private extension View { func _measureSize(_ s: Binding<CGSize>) -> some View { modifier(_MeasureSize(size: s)) } }

// === Smart callout with clamped pill
struct ProbeOverlayClamped: View {
    let imagePoint: CGPoint
    let label: String
    let color: Color
    let containerSize: CGSize
    var bottomExclusion: CGFloat = 0 // extra space to keep clear at bottom (e.g., control panel)

    // Tunables
    private let margin: CGFloat = 8
    private let defaultSide: CGFloat = 72
    private let defaultVert: CGFloat = 28
    private let edgeThreshold: CGFloat = 96

    @State private var pillSize: CGSize = .zero

    private enum Dock { case above, below, left, right }

    private func chooseDock(for p: CGPoint) -> Dock {
        if p.x < edgeThreshold { return .right }
        if p.x > containerSize.width - edgeThreshold { return .left }
        if p.y < edgeThreshold { return .below }
        return .above
    }

    private func clampCenter(_ pos: CGPoint, pill: CGSize) -> CGPoint {
        let halfW = pill.width  / 2
        let halfH = pill.height / 2
        let x = min(max(pos.x, margin + halfW), containerSize.width  - margin - halfW)
        let y = min(
            max(pos.y, margin + halfH),
            containerSize.height - bottomExclusion - margin - halfH
        )
        return CGPoint(x: x, y: y)
    }

    private func dockedCenter(from p: CGPoint, pill: CGSize) -> CGPoint {
        switch chooseDock(for: p) {
        case .above: return CGPoint(x: p.x, y: p.y - defaultVert)
        case .below: return CGPoint(x: p.x, y: p.y + defaultVert)
        case .left:  return CGPoint(x: p.x - defaultSide, y: p.y)
        case .right: return CGPoint(x: p.x + defaultSide, y: p.y)
        }
    }

    var body: some View {
        return ZStack {
            // Crosshair
            Path { path in
                let r: CGFloat = 18
                path.move(to: CGPoint(x: imagePoint.x - r, y: imagePoint.y))
                path.addLine(to: CGPoint(x: imagePoint.x + r, y: imagePoint.y))
                path.move(to: CGPoint(x: imagePoint.x, y: imagePoint.y - r))
                path.addLine(to: CGPoint(x: imagePoint.x, y: imagePoint.y + r))
            }
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6,4]))

            // Dot at the chosen coordinate
            Circle().strokeBorder(color, lineWidth: 2)
                .background(Circle().fill(.black.opacity(0.25)))
                .frame(width: 10, height: 10)
                .position(imagePoint)

            // Pill (measured + clamped)
            if !label.isEmpty {
                let pillCenter = clampCenter(dockedCenter(from: imagePoint, pill: pillSize), pill: pillSize)
                Text(label)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(color.opacity(0.85), lineWidth: 1))
                    .position(pillCenter)
                    ._measureSize($pillSize)
            }
        }
        .allowsHitTesting(false)
    }
}





// 2) LS homography that accepts N≥4 correspondences
struct HomoLS {
    let H: simd_double3x3

    func unproject(_ p: CGPoint) -> CGPoint? {
        let inv = H.inverse
        let U = simd_double3(Double(p.x), Double(p.y), 1.0)
        let r = inv * U
        let w = r.z
        guard abs(w) > 1e-12 else { return nil }
        return CGPoint(x: r.x / w, y: r.y / w)
    }

    func project(_ p: CGPoint) -> CGPoint {
        let X = simd_double3(Double(p.x), Double(p.y), 1.0)
        let r = H * X
        return CGPoint(x: r.x / r.z, y: r.y / r.z)
    }

    static func estimate(imagePts: [CGPoint], worldPts: [CGPoint]) -> HomoLS? {
        let N = min(imagePts.count, worldPts.count)
        guard N >= 4 else { return nil }

        // Build normal equations for 8 unknowns (h11..h32, h33=1)
        var A = Array(repeating: Array(repeating: 0.0, count: 8), count: 2*N)
        var b = Array(repeating: 0.0, count: 2*N)
        for i in 0..<N {
            let u = Double(imagePts[i].x), v = Double(imagePts[i].y)
            let X = Double(worldPts[i].x), Y = Double(worldPts[i].y)
            let r0 = 2*i, r1 = r0+1
            A[r0][0] = X; A[r0][1] = Y; A[r0][2] = 1
            A[r0][6] = -u*X; A[r0][7] = -u*Y; b[r0] = u
            A[r1][3] = X; A[r1][4] = Y; A[r1][5] = 1
            A[r1][6] = -v*X; A[r1][7] = -v*Y; b[r1] = v
        }

        var ATA = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
        var ATb = Array(repeating: 0.0, count: 8)
        for r in 0..<2*N {
            for c in 0..<8 {
                ATb[c] += A[r][c] * b[r]
                for c2 in 0..<8 { ATA[c][c2] += A[r][c] * A[r][c2] }
            }
        }

        guard let h = gaussianSolve(ATA, ATb) else { return nil }
        let H = simd_double3x3(rows: [
            simd_double3(h[0], h[1], h[2]),
            simd_double3(h[3], h[4], h[5]),
            simd_double3(h[6], h[7], 1.0)
        ])
        return HomoLS(H: H)
    }

    private static func gaussianSolve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var M = A, rhs = b
        for k in 0..<n {
            var p = k; var best = abs(M[k][k])
            for r in k+1..<n { if abs(M[r][k]) > best { best = abs(M[r][k]); p = r } }
            if best < 1e-12 { return nil }
            if p != k { M.swapAt(k,p); rhs.swapAt(k,p) }
            let akk = M[k][k]
            for r in k+1..<n {
                let f = M[r][k]/akk; if f == 0 { continue }
                for c in k..<n { M[r][c] -= f*M[k][c] }
                rhs[r] -= f*rhs[k]
            }
        }
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n-1, through: 0, by: -1) {
            var s = rhs[i]
            for j in i+1..<n { s -= M[i][j]*x[j] }
            let aii = M[i][i]; if abs(aii) < 1e-12 { return nil }
            x[i] = s/aii
        }
        return x
    }
}

// 3) Which anchor the user is adding (corners)
enum CourtAnchor: String, CaseIterable, Identifiable {
    case BL, BR, TR, TL
    var id: String { rawValue }
    // meters internally
    func worldMeters() -> CGPoint {
        switch self {
        case .BL: return CGPoint(x: 0.00, y: 0.00)
        case .BR: return CGPoint(x: 6.10, y: 0.00)
        case .TR: return CGPoint(x: 6.10, y: 13.40)
        case .TL: return CGPoint(x: 0.00, y: 13.40)
        }
    }
}

// Stereo-specific 6-point anchor model.
// Keep this separate from CourtAnchor so the original single-camera flow stays untouched.
enum StereoCourtAnchor: String, CaseIterable, Identifiable {
    case BL, BR, TR, TL
    case NetLeftTop, NetRightTop

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .BL: return "BL"
        case .BR: return "BR"
        case .TR: return "TR"
        case .TL: return "TL"
        case .NetLeftTop: return "Net-L"
        case .NetRightTop: return "Net-R"
        }
    }

    func worldMeters2D() -> CGPoint {
        switch self {
        case .BL: return CGPoint(x: 0.00, y: 0.00)
        case .BR: return CGPoint(x: 6.10, y: 0.00)
        case .TR: return CGPoint(x: 6.10, y: 13.40)
        case .TL: return CGPoint(x: 0.00, y: 13.40)
        case .NetLeftTop: return CGPoint(x: 0.00, y: 6.70)
        case .NetRightTop: return CGPoint(x: 6.10, y: 6.70)
        }
    }

    func worldMeters3D(netHeight: Float = 1.55) -> simd_float3 {
        let p = worldMeters2D()
        switch self {
        case .NetLeftTop, .NetRightTop:
            return simd_float3(Float(p.x), Float(p.y), netHeight)
        default:
            return simd_float3(Float(p.x), Float(p.y), 0)
        }
    }
}

// Generic anchor pair with display label
struct AnchorPair { let image: CGPoint; let world: CGPoint; let name: String }

// H-grid anchors across the court lines (7 horizontals x 5 verticals = 35 points, H0..H34)
struct AnchorDef: Identifiable { let id: Int; let label: String; let world: CGPoint }

extension AnchorDef {
    static func gridAnchors(court: BadmintonCourt) -> [AnchorDef] {
    let Xs: [CGFloat] = [court.x0, court.xS1cg, court.xMid, court.xS2cg, court.xW]
        let Ys: [CGFloat] = [court.y0, court.yDoublesNear, court.yShortNear, court.yNet, court.yShortFar, court.yDoublesFar, court.yL]
        var defs: [AnchorDef] = []
        var idx = 0
        for y in Ys {
            for x in Xs {
                defs.append(AnchorDef(id: idx, label: "H\(idx)", world: CGPoint(x: x, y: y)))
                idx += 1
            }
        }
        return defs
    }
}
