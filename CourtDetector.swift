import Vision
import UIKit

struct CourtDetector {
    static let context = CIContext()

    /// Applies background extraction / edge detection to highlight court lines.
    static func enhanceImage(_ image: UIImage) -> UIImage? {
        guard let ciIn = CIImage(image: image) else { return nil }
        let gray = ciIn.applyingFilter("CIPhotoEffectMono")
        let edges = gray.applyingFilter("CILineOverlay")
        let morphed = edges
            .applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": 1.0, "inputHeight": 1.0])
            .applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": 3.0, "inputHeight": 3.0])
        
        guard let cg = context.createCGImage(morphed, from: morphed.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Detects the most prominent rectangle in the given image.
    /// Returns 4 corners in image coordinates (TL, TR, BR, BL) - Note: Vision returns normalized coordinates with origin at bottom-left.
    /// We will convert them to image coordinates (pixels) with origin at top-left (standard UIKit/SwiftUI).
    static func detectCourt(in image: UIImage) async -> [CGPoint]? {
        // 1. Pre-process to highlight lines
        guard let enhanced = enhanceImage(image) else { return nil }
        guard let cgImage = enhanced.cgImage else { return nil }
        
        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                if let error = error {
                    print("Vision error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                
                guard let results = request.results as? [VNRectangleObservation],
                      let best = results.first else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Vision coordinates are normalized (0..1) with origin at bottom-left.
                // We need to convert to image pixels with origin at top-left.
                let w = CGFloat(cgImage.width)
                let h = CGFloat(cgImage.height)
                
                func convert(_ p: CGPoint) -> CGPoint {
                    // Vision: (x, y) where y is from bottom
                    // Image: (x, h - y*h)
                    return CGPoint(x: p.x * w, y: (1.0 - p.y) * h)
                }
                
                // VNRectangleObservation corners: topLeft, topRight, bottomRight, bottomLeft
                // But wait, Vision's "topLeft" is relative to its coordinate system (bottom-left origin).
                // Actually, VNRectangleObservation properties are:
                // topLeft, topRight, bottomLeft, bottomRight
                // Let's just map them all and then sort/organize them if needed.
                // However, we want specific order for our app: BL, BR, TR, TL.
                
                let p1 = convert(best.bottomLeft)  // Vision BL -> Image BL (large y)
                let p2 = convert(best.bottomRight) // Vision BR -> Image BR (large y)
                let p3 = convert(best.topRight)    // Vision TR -> Image TR (small y)
                let p4 = convert(best.topLeft)     // Vision TL -> Image TL (small y)
                
                // Our app expects: BL, BR, TR, TL
                // Let's verify if Vision's "bottom" corresponds to our "bottom" (high Y in UIKit).
                // Vision Y=0 is bottom, Y=1 is top.
                // UIKit Y=0 is top, Y=h is bottom.
                // So Vision Bottom (y=0) -> UIKit Bottom (y=h). Correct.
                
                continuation.resume(returning: [p1, p2, p3, p4])
            }
            
            // Configuration
            request.minimumConfidence = 0.3
            request.minimumAspectRatio = 0.1 // Allow extreme perspective distortion
            request.maximumObservations = 1
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("Handler error: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }
}
