import Photos
import SceneKit
import SwiftUI

struct ConstellationScene: UIViewRepresentable {
    let nodes: [ConstellationNode]
    let highlighted: Set<String>
    let selectedID: String?
    let command: CameraCommand
    let photoService: PhotoLibraryService
    let reduceMotion: Bool
    let onSelect: (String?) -> Void

    struct CameraCommand: Equatable {
        enum Action { case home, zoomIn, zoomOut, rotateLeft, rotateRight }
        var action = Action.home
        var serial = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var view: SCNView?
        private let scene = SCNScene()
        private let orbit = SCNNode()
        private let camera = SCNNode()
        private let stars = SCNNode()
        private var input: ConstellationScene?
        private var thumbnails: [String: SCNNode] = [:]
        private var requests: [String: PHImageRequestID] = [:]
        private var refreshTask: Task<Void, Never>?
        private var homeCenter = SIMD3<Float>.zero
        private var radius: Float = 10
        private var yaw: Float = 0
        private var pitch: Float = 0
        private var lastThumbnailTransform: simd_float4x4?
        private var lastViewport = CGSize.zero

        func install(in view: SCNView) {
            self.view = view
            view.scene = scene
            view.backgroundColor = UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1)
            view.antialiasingMode = .multisampling4X
            view.preferredFramesPerSecond = 60
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.01
            camera.camera?.zFar = 10000
            camera.camera?.fieldOfView = 55
            orbit.addChildNode(camera)
            scene.rootNode.addChildNode(orbit)
            scene.rootNode.addChildNode(stars)
            view.pointOfView = camera
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pan.delegate = self
            pinch.delegate = self
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            view.isAccessibilityElement = true
            view.accessibilityLabel = "照片三维星团"
            view.accessibilityHint = "可使用上方相机控制和照片列表浏览"
            view.accessibilityIdentifier = "constellationScene"
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    self?.refreshThumbnails()
                }
            }
        }

        func stop() {
            refreshTask?.cancel()
            refreshTask = nil
            for id in Array(thumbnails.keys) { removeThumbnail(id) }
            input = nil
            view?.scene = nil
        }

        func update(_ next: ConstellationScene) {
            let previous = input
            input = next
            if previous?.nodes != next.nodes || previous?.highlighted != next.highlighted || previous?.selectedID != next.selectedID {
                buildStars()
                let ids = Set(next.nodes.map(\.id))
                for id in Array(thumbnails.keys) where !ids.contains(id) || !next.highlighted.contains(id) {
                    removeThumbnail(id)
                }
                if previous?.nodes.isEmpty != false, !next.nodes.isEmpty { home() }
                if previous?.selectedID != next.selectedID,
                   let selected = next.nodes.first(where: { $0.id == next.selectedID }) {
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = next.reduceMotion ? 0 : 0.4
                    orbit.simdPosition = selected.position
                    camera.position.z = max(radius * 0.9, 1)
                    SCNTransaction.commit()
                }
                view?.accessibilityValue = "\(next.nodes.count) 张照片，\(next.highlighted.count) 张高亮"
                refreshThumbnails()
            }
            if let previous, previous.command != next.command {
                switch next.command.action {
                case .home: home()
                case .zoomIn: zoom(0.7)
                case .zoomOut: zoom(1.4)
                case .rotateLeft: yaw -= .pi / 8; rotate()
                case .rotateRight: yaw += .pi / 8; rotate()
                }
                refreshThumbnails()
            }
        }

        private func buildStars() {
            lastThumbnailTransform = nil
            guard let input, !input.nodes.isEmpty else { stars.geometry = nil; return }
            let vertices = input.nodes.map { SCNVector3($0.position) }
            let colors: [SIMD4<Float>] = input.nodes.map { node in
                if node.id == input.selectedID { return SIMD4(1, 0.76, 0.35, 1) }
                return input.highlighted.contains(node.id) ? SIMD4(0.69, 0.83, 1, 0.9) : SIMD4(0.35, 0.42, 0.55, 0.14)
            }
            let colorData = colors.withUnsafeBytes { Data($0) }
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                               usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                                               dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let points = SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .point)
            points.pointSize = 3
            points.minimumPointScreenSpaceRadius = 1.5
            points.maximumPointScreenSpaceRadius = 3
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), colorSource], elements: [points])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.blendMode = .alpha
            geometry.materials = [material]
            stars.geometry = geometry
        }

        private func home() {
            guard let nodes = input?.nodes, !nodes.isEmpty else { return }
            let lower = nodes.reduce(nodes[0].position) { simd_min($0, $1.position) }
            let upper = nodes.reduce(nodes[0].position) { simd_max($0, $1.position) }
            homeCenter = (lower + upper) / 2
            radius = max(simd_length(upper - lower) / 2, 2)
            orbit.simdPosition = homeCenter
            yaw = 0; pitch = 0
            rotate()
            let aspect = Float((view?.bounds.width ?? 1) / max(view?.bounds.height ?? 1, 1))
            camera.position.z = radius / (sin(27.5 * .pi / 180) * max(0.4, min(aspect, 1))) * 1.1
            camera.camera?.zFar = Double(max(radius * 100, 1000))
        }

        private func rotate() { orbit.eulerAngles = SCNVector3(pitch, yaw, 0) }
        private func zoom(_ factor: Float) { camera.position.z = min(max(camera.position.z * factor, radius * 0.08), radius * 12) }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            if gesture.numberOfTouches >= 2 {
                let scale = camera.position.z / Float(max(view.bounds.height, 1))
                let offset = SIMD3(-Float(delta.x) * scale, Float(delta.y) * scale, 0)
                orbit.simdPosition += orbit.simdOrientation.act(offset)
            } else {
                yaw += Float(delta.x) * 0.006
                pitch = min(max(pitch + Float(delta.y) * 0.006, -1.45), 1.45)
                rotate()
            }
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            zoom(1 / Float(gesture.scale))
            gesture.scale = 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            guard let view, let input else { return }
            let location = gesture.location(in: view)
            if let hit = view.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
                .first(where: { $0.node.name != nil }), let id = hit.node.name {
                input.onSelect(id)
                return
            }
            var nearest: (id: String, distance: CGFloat)?
            for node in input.nodes {
                let point = view.projectPoint(SCNVector3(node.position))
                guard point.z >= 0, point.z <= 1 else { continue }
                let distance = hypot(CGFloat(point.x) - location.x, CGFloat(point.y) - location.y)
                if distance < 24, distance < (nearest?.distance ?? .infinity) { nearest = (node.id, distance) }
            }
            input.onSelect(nearest?.id)
        }

        private func refreshThumbnails() {
            guard let view, let input, view.window != nil, view.bounds.width > 0 else { return }
            let transform = camera.presentation.simdWorldTransform
            guard transform != lastThumbnailTransform || view.bounds.size != lastViewport else { return }
            lastThumbnailTransform = transform
            lastViewport = view.bounds.size
            let eye = camera.presentation.simdWorldPosition
            let candidates = input.nodes.filter { input.highlighted.contains($0.id) || $0.id == input.selectedID }
                .sorted {
                    if $0.id == input.selectedID { return true }
                    if $1.id == input.selectedID { return false }
                    return simd_distance_squared($0.position, eye) < simd_distance_squared($1.position, eye)
                }
            let limit = camera.position.z < radius * 1.5 ? 36 : 12
            var occupied: [CGPoint] = []
            var chosen = Set<String>()
            for node in candidates {
                let p = view.projectPoint(SCNVector3(node.position))
                let screen = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                guard p.z > 0, p.z < 1, view.bounds.insetBy(dx: 28, dy: 28).contains(screen),
                      !occupied.contains(where: { hypot($0.x - screen.x, $0.y - screen.y) < 64 }) else { continue }
                occupied.append(screen)
                chosen.insert(node.id)
                let size = CGFloat(simd_distance(node.position, eye)) * (node.id == input.selectedID ? 0.13 : 0.085)
                if let thumbnail = thumbnails[node.id], let plane = thumbnail.geometry as? SCNPlane {
                    plane.width = size; plane.height = size
                    plane.cornerRadius = size * 0.08
                    thumbnail.simdPosition = node.position
                } else {
                    addThumbnail(node, size: size)
                }
                if chosen.count == limit { break }
            }
            for id in Array(thumbnails.keys) where !chosen.contains(id) { removeThumbnail(id) }
        }

        private func addThumbnail(_ node: ConstellationNode, size: CGFloat) {
            guard let input, let asset = input.photoService.asset(for: node.id) else { return }
            let plane = SCNPlane(width: size, height: size)
            plane.cornerRadius = size * 0.08
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.diffuse.contents = UIColor(white: 0.16, alpha: 1)
            plane.materials = [material]
            let thumbnail = SCNNode(geometry: plane)
            thumbnail.name = node.id
            thumbnail.simdPosition = node.position
            thumbnail.constraints = [SCNBillboardConstraint()]
            thumbnails[node.id] = thumbnail
            scene.rootNode.addChildNode(thumbnail)
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            requests[node.id] = input.photoService.cachingManager.requestImage(for: asset, targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill, options: options) { [weak self, weak thumbnail] image, _ in
                    Task { @MainActor [weak self, weak thumbnail] in
                        guard let self, let thumbnail, self.thumbnails[node.id] === thumbnail, let image else { return }
                        thumbnail.geometry?.firstMaterial?.diffuse.contents = image
                    }
                }
        }

        private func removeThumbnail(_ id: String) {
            if let request = requests.removeValue(forKey: id) { input?.photoService.cachingManager.cancelImageRequest(request) }
            thumbnails.removeValue(forKey: id)?.removeFromParentNode()
        }
    }
}
