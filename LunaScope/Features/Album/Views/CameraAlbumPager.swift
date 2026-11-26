import AVFoundation
import SwiftUI
import UIKit

struct CameraAlbumPager: UIViewControllerRepresentable {
    let items: [CameraAlbumItem]
    let initialID: String
    let activeID: String
    let image: UIImage?
    let player: AVPlayer?
    /// 当前页是否支持长按触发实况播放。
    let allowsLivePhotoPress: Bool
    let poster: (CameraAlbumItem) -> UIImage?
    let onPageChange: (CameraAlbumItem) -> Void
    let onTap: () -> Void
    let onLivePhotoPress: () -> Void
    let onDismissProgress: (Double) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> CameraAlbumPagerController {
        CameraAlbumPagerController(presentation: self)
    }

    func updateUIViewController(_ controller: CameraAlbumPagerController, context: Context) {
        controller.update(self)
    }

    static func dismantleUIViewController(_ controller: CameraAlbumPagerController, coordinator: Void) {
        controller.detachPlayers()
    }
}

final class CameraAlbumPagerController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
    UIGestureRecognizerDelegate {
    private var presentation: CameraAlbumPager
    private let layout = UICollectionViewFlowLayout()
    private lazy var pages = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    private var index: Int
    private var pageSize: CGSize = .zero
    private var isClosing = false
    /// 实况按住及松手后短窗口内，吞掉会误触的单击/双击。
    private var suppressesTapUntil: TimeInterval = 0
    private lazy var livePress = UILongPressGestureRecognizer(target: self, action: #selector(handleLivePress(_:)))

    init(presentation: CameraAlbumPager) {
        self.presentation = presentation
        index = presentation.items.firstIndex { $0.id == presentation.initialID } ?? 0
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        pages.backgroundColor = .clear
        pages.frame = view.bounds
        pages.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pages.contentInsetAdjustmentBehavior = .never
        pages.showsHorizontalScrollIndicator = false
        pages.showsVerticalScrollIndicator = false
        pages.isPagingEnabled = true
        pages.isDirectionalLockEnabled = true
        pages.dataSource = self
        pages.delegate = self
        pages.accessibilityIdentifier = "album.preview.pager"
        pages.register(MediaPage.self, forCellWithReuseIdentifier: MediaPage.reuseID)
        view.addSubview(pages)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        livePress.minimumPressDuration = 0.2
        livePress.delegate = self
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(livePress)
        view.addGestureRecognizer(dismissPan)
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = self
        pages.panGestureRecognizer.require(toFail: dismissPan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = pages.bounds.size
        guard size.width > 0, size.height > 0, size != pageSize else { return }
        pageSize = size
        layout.invalidateLayout()
        pages.layoutIfNeeded()
        pages.setContentOffset(CGPoint(x: CGFloat(index) * size.width, y: 0), animated: false)
    }

    func update(_ presentation: CameraAlbumPager) {
        self.presentation = presentation
        guard isViewLoaded else { return }
        for cell in pages.visibleCells {
            guard let cell = cell as? MediaPage, let path = pages.indexPath(for: cell) else { continue }
            configure(cell, at: path)
        }
    }

    func detachPlayers() {
        guard isViewLoaded else { return }
        for case let cell as MediaPage in pages.visibleCells { cell.setPlayer(nil) }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        presentation.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaPage.reuseID, for: indexPath) as! MediaPage
        configure(cell, at: indexPath)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        (cell as? MediaPage)?.setPlayer(nil)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settlePage() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settlePage() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settlePage() }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let offset: Int
        switch direction {
        case .left, .next: offset = 1
        case .right, .previous: offset = -1
        default: return super.accessibilityScroll(direction)
        }
        let next = index + offset
        guard presentation.items.indices.contains(next) else { return false }
        pages.setContentOffset(CGPoint(x: CGFloat(next) * pageSize.width, y: 0), animated: true)
        return true
    }

    private var currentCell: MediaPage? {
        pages.cellForItem(at: IndexPath(item: index, section: 0)) as? MediaPage
    }

    private func settlePage() {
        guard pageSize.width > 0 else { return }
        let next = Int((pages.contentOffset.x / pageSize.width).rounded())
        guard presentation.items.indices.contains(next), next != index else { return }
        if suppressesTapUntil == .greatestFiniteMagnitude {
            suppressesTapUntil = 0
        }
        currentCell?.resetZoom()
        index = next
        pages.isScrollEnabled = true
        presentation.onPageChange(presentation.items[next])
    }

    private func configure(_ cell: MediaPage, at indexPath: IndexPath) {
        let item = presentation.items[indexPath.item]
        let active = presentation.activeID == item.id
        cell.accessibilityLabel = item.filename
        cell.canZoom = item.kind != .video
        cell.setImage((active ? presentation.image : nil) ?? presentation.poster(item))
        cell.setPlayer(active ? presentation.player : nil)
        cell.onZoom = { [weak self, weak cell] zoomed in
            guard let self, cell === self.currentCell else { return }
            self.pages.isScrollEnabled = !zoomed
        }
    }

    @objc private func handleTap() {
        guard !isClosing, CFAbsoluteTimeGetCurrent() >= suppressesTapUntil else { return }
        presentation.onTap()
    }

    @objc private func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        guard !isClosing, CFAbsoluteTimeGetCurrent() >= suppressesTapUntil, let currentCell else { return }
        currentCell.toggleZoom(at: tap.location(in: currentCell))
    }

    @objc private func handleLivePress(_ gesture: UILongPressGestureRecognizer) {
        guard presentation.allowsLivePhotoPress, !isClosing else { return }
        switch gesture.state {
        case .began:
            suppressesTapUntil = .greatestFiniteMagnitude
            presentation.onLivePhotoPress()
        case .ended, .cancelled, .failed:
            suppressesTapUntil = CFAbsoluteTimeGetCurrent() + 0.45
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === livePress {
            return presentation.allowsLivePhotoPress && !isClosing
        }
        guard gestureRecognizer === dismissPan else { return true }
        let velocity = dismissPan.velocity(in: view)
        return !isClosing && velocity.y > abs(velocity.x) * 1.5 && currentCell?.isAtTop != false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === dismissPan && otherGestureRecognizer === currentCell?.mediaPan
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let delta = pan.translation(in: view)
        let height = max(view.bounds.height, 1)
        switch pan.state {
        case .changed:
            applyDismissProgress(min(0.85, max(0, delta.y / (height * 0.52))))
        case .ended:
            let threshold = max(30, height * 0.05) * (currentCell?.isZoomed == true ? 1.6 : 0.55)
            if delta.y > threshold && delta.y > abs(delta.x) * 1.5 {
                isClosing = true
                UIView.animate(withDuration: 0.20, animations: { self.applyDismissProgress(1) }) { _ in
                    self.presentation.onDismiss()
                }
            } else {
                restoreAfterDrag()
            }
        case .cancelled, .failed:
            restoreAfterDrag()
        default:
            break
        }
    }

    private func restoreAfterDrag() {
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.applyDismissProgress(0)
        }
    }

    private func applyDismissProgress(_ progress: CGFloat) {
        let scale = 1 - progress * 0.12
        pages.transform = CGAffineTransform(translationX: 0, y: progress * view.bounds.height * 0.52)
            .scaledBy(x: scale, y: scale)
        pages.layer.cornerRadius = 16 * progress
        presentation.onDismissProgress(Double(progress))
    }
}

private final class MediaPage: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseID = "CameraAlbumMediaPage"

    private let zoom = MediaZoomScrollView()
    private let imageView = UIImageView()
    private let playerLayer = AVPlayerLayer()
    private var previousSize: CGSize = .zero
    var canZoom = true
    var onZoom: ((Bool) -> Void)?

    var mediaPan: UIPanGestureRecognizer { zoom.panGestureRecognizer }
    var isZoomed: Bool { zoom.zoomScale > 1.01 }
    var isAtTop: Bool { zoom.contentOffset.y <= -zoom.adjustedContentInset.top + 1 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .image
        zoom.delegate = self
        zoom.contentInsetAdjustmentBehavior = .never
        zoom.showsVerticalScrollIndicator = false
        zoom.showsHorizontalScrollIndicator = false
        zoom.maximumZoomScale = 8
        zoom.bouncesZoom = true
        zoom.addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(zoom)
        playerLayer.videoGravity = .resizeAspect
        contentView.layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = contentView.bounds
        guard previousSize != contentView.bounds.size else { return }
        previousSize = contentView.bounds.size
        resizePhoto()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onZoom = nil
        resetZoom()
        setImage(nil)
        setPlayer(nil)
    }

    func setPlayer(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
        playerLayer.isHidden = player == nil
        zoom.pinchGestureRecognizer?.isEnabled = canZoom && player == nil && imageView.image != nil
        // Keep the poster visible behind the player until the first frame is available.
        playerLayer.backgroundColor = UIColor.clear.cgColor
    }

    func setImage(_ image: UIImage?) {
        zoom.pinchGestureRecognizer?.isEnabled = canZoom && image != nil && playerLayer.player == nil
        guard imageView.image !== image else { return }
        let oldSize = imageView.image?.size
        imageView.image = image
        guard let oldSize, let image,
              abs(oldSize.width / max(oldSize.height, 1) - image.size.width / max(image.size.height, 1)) < 0.01 else {
            resizePhoto()
            return
        }
    }

    func toggleZoom(at point: CGPoint) {
        guard canZoom, imageView.image != nil, playerLayer.player == nil else { return }
        if isZoomed {
            zoom.setZoomScale(1, animated: true)
        } else {
            let target: CGFloat = 2.5
            let center = convert(point, to: imageView)
            let size = CGSize(width: zoom.bounds.width / target, height: zoom.bounds.height / target)
            zoom.zoom(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                 width: size.width, height: size.height), animated: true)
        }
    }

    func resetZoom() {
        zoom.setZoomScale(1, animated: false)
        centerPhoto()
    }

    private func resizePhoto() {
        let scale = zoom.zoomScale
        let oldContentPoint = imageView.convert(CGPoint(x: zoom.bounds.midX, y: zoom.bounds.midY), from: zoom)
        let oldSize = imageView.bounds.size
        zoom.setZoomScale(1, animated: false)
        zoom.frame = contentView.bounds
        let available = zoom.bounds.size
        let size = imageView.image?.size ?? available
        let ratio = min(available.width / max(size.width, 1), available.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        zoom.contentSize = fitted
        if scale > 1, oldSize.width > 0, oldSize.height > 0 {
            let viewport = CGSize(width: available.width / scale, height: available.height / scale)
            let center = CGPoint(x: fitted.width * oldContentPoint.x / oldSize.width,
                                 y: fitted.height * oldContentPoint.y / oldSize.height)
            zoom.zoom(to: CGRect(x: center.x - viewport.width / 2, y: center.y - viewport.height / 2,
                                 width: viewport.width, height: viewport.height), animated: false)
        }
        centerPhoto()
    }

    private func centerPhoto() {
        let horizontal = max(0, (zoom.bounds.width - zoom.contentSize.width) / 2)
        let vertical = max(0, (zoom.bounds.height - zoom.contentSize.height) / 2)
        let center = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if zoom.contentInset != center { zoom.contentInset = center }
        if !isZoomed { zoom.contentOffset = CGPoint(x: -horizontal, y: -vertical) }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canZoom ? imageView : nil }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPhoto()
        onZoom?(isZoomed)
    }
}

private final class MediaZoomScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer && zoomScale <= 1.01 { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
