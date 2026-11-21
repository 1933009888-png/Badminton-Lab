import SwiftUI

/// UIScrollView wrapper that:
/// - zooms/pans SwiftUI content,
/// - delivers tap locations in content coordinates,
/// - hard-limits zoom to [minZoom, maxZoom],
/// - double-tap to reset to minZoom,
/// - keeps SwiftUI <-> UIScrollView zoom in sync without touching state in updateUIView.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let minZoom: CGFloat
    let maxZoom: CGFloat
    @Binding var zoomScale: CGFloat
    let onSingleTap: (CGPoint) -> Void
    let content: Content

    init(minZoom: CGFloat = 1,
         maxZoom: CGFloat = 6,
         zoomScale: Binding<CGFloat> = .constant(1),
         onSingleTap: @escaping (CGPoint) -> Void,
         @ViewBuilder content: () -> Content) {
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self._zoomScale = zoomScale
        self.onSingleTap = onSingleTap
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = minZoom
        scroll.maximumZoomScale = maxZoom
        scroll.zoomScale = zoomScale.clamped(minZoom...maxZoom)

        // No overshoot / rubber-banding
        scroll.bouncesZoom = false
        scroll.bounces = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false

        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.delaysContentTouches = false

        // Container that actually gets zoomed
        let container = context.coordinator.container
        container.frame = scroll.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(container)

        // Host SwiftUI content inside container
        let hosted = context.coordinator.hosting
        hosted.view.frame = container.bounds
        hosted.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosted.view.backgroundColor = .clear
        container.addSubview(hosted.view)

        // Gestures
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.resetZoom))
        doubleTap.numberOfTapsRequired = 2
        container.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap) // prefer double tap if it happens
        singleTap.cancelsTouchesInView = false
        container.addGestureRecognizer(singleTap)

        context.coordinator.scroll = scroll
        context.coordinator.centerContent(in: scroll)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        // Update the SwiftUI content
        context.coordinator.hosting.rootView = content

        // Push SwiftUI -> UIScrollView (read-only for the binding here)
        let target = zoomScale.clamped(minZoom...maxZoom)
        if abs(target - scroll.zoomScale) > 0.0001 {
            scroll.setZoomScale(target, animated: false)
        }

        context.coordinator.centerContent(in: scroll)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        let hosting: UIHostingController<Content>
        let container = UIView()
        weak var scroll: UIScrollView?
        private var lastSentZoom: CGFloat = .nan

        init(_ parent: ZoomableScrollView) {
            self.parent = parent
            self.hosting = UIHostingController(rootView: parent.content)
            super.init()
        }

        // MARK: UIScrollViewDelegate
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Clamp in case UIKit overshoots
            var s = scrollView.zoomScale
            if s < parent.minZoom { s = parent.minZoom }
            if s > parent.maxZoom { s = parent.maxZoom }
            if s != scrollView.zoomScale { scrollView.setZoomScale(s, animated: false) }

            // Send zoom back to SwiftUI (outside updateUIView)
            if s != lastSentZoom {
                lastSentZoom = s
                parent.zoomScale = s
            }
            centerContent(in: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // Ensure final value is reflected
            parent.zoomScale = scale.clamped(parent.minZoom...parent.maxZoom)
            centerContent(in: scrollView)
        }

        // Keep content visually centered when smaller than the scroll view
        func centerContent(in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            let size = container.bounds.size
            let scale = scrollView.zoomScale

            let contentW = size.width  * scale
            let contentH = size.height * scale

            let insetX = max(0, (bounds.width  - contentW) * 0.5)
            let insetY = max(0, (bounds.height - contentH) * 0.5)

            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        // MARK: Gestures
        @objc func resetZoom() {
            guard let scroll = scroll else { return }
            let z = parent.minZoom
            scroll.setZoomScale(z, animated: true)
            parent.zoomScale = z
        }

        @objc func handleSingleTap(_ gr: UITapGestureRecognizer) {
            // Point in content coordinates (independent of current zoom)
            let p = gr.location(in: container)
            parent.onSingleTap(p)
        }
    }
}

// Small helper
private extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
