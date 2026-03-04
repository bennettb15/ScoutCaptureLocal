//
//  ContentView.swift
//  ScoutCapture
//

import SwiftUI
import CoreLocation
import CoreMotion
import Combine
import UIKit
import AVKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

private func proportionalCircleGlyphSize(for diameter: CGFloat) -> CGFloat {
    min(30, max(18, (diameter * 0.5).rounded()))
}

private func proportionalCircleTextSize(for diameter: CGFloat) -> CGFloat {
    min(24, max(14, (diameter * 0.42).rounded()))
}


// MARK: - UIScreen compatibility helper (avoids iOS 26 UIScreen warnings)

extension UIScreen {
    static var currentScale: CGFloat {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return scene.screen.scale
        }
        return 3.0
    }
}



// MARK: - UIKit label button (native text rendering + reliable hit testing)

private struct UIKitCircleTextButton: UIViewRepresentable {

    let title: String
    let isActive: Bool
    let size: CGFloat
    let action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.backgroundColor = .clear
        button.clipsToBounds = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.setTitle(title, for: .normal)

        let fg = isActive ? UIColor.black : UIColor(white: 1.0, alpha: 0.92)
        button.setTitleColor(fg, for: .normal)

        button.layer.cornerRadius = size / 2.0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

// MARK: - Camera-style glass circle (darker, liquid-glass rim)

private struct CameraGlassCircle: ViewModifier {

    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .background(
                ZStack {
                    // Dark base so it never reads as gray
                    Circle().fill(Color.black.opacity(0.68))

                    // Light material just for "glass" feel
                    Circle().fill(.ultraThinMaterial).opacity(0.45)

                    // Edge darkening like Camera app
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.black.opacity(0.00),
                                    Color.black.opacity(0.65)
                                ],
                                center: .center,
                                startRadius: size * 0.25,
                                endRadius: size * 0.90
                            )
                        )

                    // Top highlight
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.20),
                                    Color.white.opacity(0.06),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)

                    // Outer liquid-glass rim
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )

                    // Inner faint rim
                    Circle()
                        .inset(by: 1)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)

                    // Subtle inner shadow depth
                    Circle()
                        .inset(by: 0.5)
                        .stroke(Color.black.opacity(0.75), lineWidth: 1)
                        .blur(radius: 1.2)
                        .opacity(0.7)
                        .blendMode(.overlay)
                }
            )
            .shadow(color: Color.black.opacity(0.65), radius: 18, x: 0, y: 12)
    }
}

private extension View {
    func cameraGlassCircle(size: CGFloat = 44) -> some View {
        modifier(CameraGlassCircle(size: size))
    }
}

private extension UIImage.Orientation {
    init(from orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Physical shutter buttons (Camera Control + volume buttons)

private struct CameraCaptureButtons: ViewModifier {

    let onPressBegan: (() -> Void)?
    let onCapture: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.2, *) {
            content
                // Treat any physical shutter source the same.
                // Haptic on .began, capture on .ended.
                .onCameraCaptureEvent(
                    isEnabled: true,
                    primaryAction: { event in
                        switch event.phase {
                        case .began:
                            onPressBegan?()
                        case .ended:
                            onCapture()
                        default:
                            break
                        }
                    },
                    secondaryAction: { event in
                        switch event.phase {
                        case .began:
                            onPressBegan?()
                        case .ended:
                            onCapture()
                        default:
                            break
                        }
                    }
                )
        } else {
            content
        }
    }
}

private extension View {
    func cameraCaptureButtons(
        onPressBegan: (() -> Void)? = nil,
        onCapture: @escaping () -> Void
    ) -> some View {
        modifier(CameraCaptureButtons(onPressBegan: onPressBegan, onCapture: onCapture))
    }
}

// MARK: - Asset Image Cache

final class AssetImageCache: ObservableObject {
    private let cache = NSCache<NSString, UIImage>()

    func requestThumbnail(for asset: ReportAsset, pixelSize: CGFloat, completion: @escaping (UIImage?) -> Void) {

        let key = "\(asset.localIdentifier)-\(Int(pixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: asset.fileURL),
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let target = CGSize(width: pixelSize, height: pixelSize)
            let renderer = UIGraphicsImageRenderer(size: target)
            let thumb = renderer.image { _ in
                let src = image.size
                guard src.width > 0, src.height > 0 else { return }
                let scale = max(target.width / src.width, target.height / src.height)
                let drawSize = CGSize(width: src.width * scale, height: src.height * scale)
                let origin = CGPoint(
                    x: (target.width - drawSize.width) * 0.5,
                    y: (target.height - drawSize.height) * 0.5
                )
                image.draw(in: CGRect(origin: origin, size: drawSize))
            }
            self?.cache.setObject(thumb, forKey: key)
            DispatchQueue.main.async {
                completion(thumb)
            }
        }
    }

    func requestFull(for asset: ReportAsset, completion: @escaping (UIImage?) -> Void) {

        let key = "\(asset.localIdentifier)-full" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: asset.fileURL),
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self?.cache.setObject(image, forKey: key)
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func invalidate(localIdentifier: String) {
        let trimmed = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fullKey = "\(trimmed)-full" as NSString
        cache.removeObject(forKey: fullKey)
    }

    func clearAll() {
        cache.removeAllObjects()
    }
}

// MARK: - Report Library Model (SCOUT file storage per property/session)

final class ReportLibraryModel: ObservableObject {
    enum SavePhotoError: Error {
        case missingCGImage
        case imageDestinationCreateFailed
        case imageDestinationFinalizeFailed
        case directoryMissing(String)
        case writeFailed(Error)
        case setAttributesFailed(Error)

        var shortReason: String {
            switch self {
            case .missingCGImage:
                return "Missing image"
            case .imageDestinationCreateFailed:
                return "Destination create"
            case .imageDestinationFinalizeFailed:
                return "Finalize"
            case .directoryMissing:
                return "Directory missing"
            case .writeFailed:
                return "Write"
            case .setAttributesFailed:
                return "Set attributes"
            }
        }
    }

    struct EmbeddedCaptureTime {
        let captureDate: Date
        let localDateTimeString: String
        let subsecString: String
        let tzOffsetString: String
        let iso8601WithOffset: String

        init(captureDate: Date) {
            self.captureDate = captureDate
            self.localDateTimeString = ReportLibraryModel.exifTimestampFormatter.string(from: captureDate)
            self.subsecString = ReportLibraryModel.exifSubsecFormatter.string(from: captureDate)
            self.tzOffsetString = ReportLibraryModel.exifOffsetString(for: captureDate)
            self.iso8601WithOffset = ReportLibraryModel.iso8601WithOffsetString(for: captureDate)
        }
    }

    struct EmbeddedMetadataContext {
        var propertyID: UUID?
        var propertyName: String?
        var propertyAddress: String?
        var sessionID: UUID?
        var shotID: UUID?
        var shotKey: String?
        var building: String?
        var elevation: String?
        var detailType: String?
        var angleIndex: Int?
        var isGuided: Bool?
        var isFlagged: Bool?
        var issueStatus: String?
        var detailNote: String?
        var captureMode: String?
        var lens: String?
        var orientation: String?
        var capturedExifOrientationRaw: UInt32?
        var latitude: Double?
        var longitude: Double?
        var accuracyMeters: Double?
        var appVersion: String?
        var osVersion: String?
        var deviceModel: String?
        var schemaVersion: Int?
    }

    static func cgOrientationRawFromDevice(_ orientation: UIDeviceOrientation) -> UInt32 {
        switch orientation {
        case .portrait:
            return CGImagePropertyOrientation.right.rawValue
        case .portraitUpsideDown:
            return CGImagePropertyOrientation.left.rawValue
        case .landscapeLeft:
            return CGImagePropertyOrientation.up.rawValue
        case .landscapeRight:
            return CGImagePropertyOrientation.down.rawValue
        default:
            return CGImagePropertyOrientation.right.rawValue
        }
    }

    @Published private(set) var assets: [ReportAsset] = []
    @Published private(set) var albumTitle: String = ""
    @Published private(set) var albumLocalId: String = ""
    @Published private(set) var activeIssueCount: Int = 0

    private let activeAlbumTitleKey = "scout.activeReport.albumTitle.v1"
    private let activeIssueCountsKey = "scout.activeReport.activeIssueCountsByTitle.v1"
    private let localStore = LocalStore()
    private let fileManager = FileManager.default
    private var propertyID: UUID?
    private var sessionID: UUID?

    init() {
        albumTitle = UserDefaults.standard.string(forKey: activeAlbumTitleKey) ?? ""
        activeIssueCount = loadActiveIssueCount(for: albumTitle)
    }

    func setActiveReportTitle(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if t != albumTitle {
            albumTitle = t
            activeIssueCount = loadActiveIssueCount(for: t)
            UserDefaults.standard.set(t, forKey: activeAlbumTitleKey)
        } else {
            albumTitle = t
            activeIssueCount = loadActiveIssueCount(for: t)
            UserDefaults.standard.set(t, forKey: activeAlbumTitleKey)
        }
    }

    func incrementActiveIssueCount() {
        let title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let updated = max(0, activeIssueCount + 1)
        activeIssueCount = updated
        storeActiveIssueCount(updated, for: title)
    }

    func setActiveIssueCount(_ count: Int) {
        let title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            activeIssueCount = max(0, count)
            return
        }
        let normalized = max(0, count)
        activeIssueCount = normalized
        storeActiveIssueCount(normalized, for: title)
    }

    func fetchMatchingReportAlbums(completion: @escaping ([String]) -> Void) {
        DispatchQueue.main.async {
            completion([])
        }
    }

    func setSessionContext(propertyID: UUID?, sessionID: UUID?) {
        self.propertyID = propertyID
        self.sessionID = sessionID
        reloadAssets()
    }

    func reloadAssets() {
        guard let propertyID, let sessionID else {
            assets = []
            return
        }
        let originals = localStore.originalsDirectoryURL(propertyID: propertyID, sessionID: sessionID)
        guard fileManager.fileExists(atPath: originals.path) else {
            assets = []
            return
        }
        let urls = (try? fileManager.contentsOfDirectory(at: originals, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let out: [ReportAsset] = urls.compactMap { url in
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
            let created = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
            let data = try? Data(contentsOf: url)
            let image = data.flatMap(UIImage.init)
            let width = image.map { Int($0.size.width) } ?? 0
            let height = image.map { Int($0.size.height) } ?? 0
            let localId = url.path
            return ReportAsset(
                localIdentifier: localId,
                fileURL: url,
                creationDate: created,
                pixelWidth: width,
                pixelHeight: height,
                originalFilename: url.lastPathComponent
            )
        }
        .sorted { lhs, rhs in
            (lhs.creationDate ?? .distantPast) < (rhs.creationDate ?? .distantPast)
        }

        DispatchQueue.main.async {
            self.assets = out
        }
    }

    func reloadSessionAssets(propertyID: UUID, sessionID: UUID) {
        setSessionContext(propertyID: propertyID, sessionID: sessionID)
        reloadAssets()
    }

    func warmUpAlbumIfAuthorized() {
        reloadAssets()
    }

    func savePhotoDataToSession(
        data: Data,
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID,
        captureDate: Date,
        metadataContext: EmbeddedMetadataContext? = nil,
        preferredFilename: String? = nil,
        completion: @escaping (Bool, String?, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let savedPath: String = try self.localStore.performFileIOSync {
                    try self.localStore.ensureSessionFolders(propertyID: propertyID, sessionID: sessionID)
                    let preferred = preferredFilename?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let preferredName = URL(fileURLWithPath: preferred).lastPathComponent
                    let filename: String
                    if preferred.isEmpty {
                        filename = "\(shotID.uuidString).heic"
                    } else {
                        let sanitized = preferredName.replacingOccurrences(of: "/", with: "-")
                        let stem = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
                        filename = stem.isEmpty ? "\(shotID.uuidString).heic" : "\(stem).heic"
                    }
                    let output = self.localStore
                        .sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
                        .appendingPathComponent("Originals", isDirectory: true)
                        .appendingPathComponent(filename, isDirectory: false)
                    let sessionFolder = self.localStore.sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
                    print("[iCloud] activeRoot=\(self.localStore.storageRootURL().path)")
                    print("[iCloud] sessionSaveFolder=\(sessionFolder.path)")
                    let parentDir = output.deletingLastPathComponent()
                    var isDir = ObjCBool(false)
                    var exists = self.fileManager.fileExists(atPath: parentDir.path, isDirectory: &isDir)
                    self.debugLogSaveStage("parentDir exists=\(exists) isDirectory=\(isDir.boolValue) path=\(parentDir.path)")
                    if !exists || !isDir.boolValue {
                        try self.fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                        isDir = ObjCBool(false)
                        exists = self.fileManager.fileExists(atPath: parentDir.path, isDirectory: &isDir)
                        self.debugLogSaveStage("parentDir recheck exists=\(exists) isDirectory=\(isDir.boolValue) path=\(parentDir.path)")
                        guard exists, isDir.boolValue else {
                            throw SavePhotoError.writeFailed(
                                NSError(
                                    domain: "ScoutCapture.Storage",
                                    code: 1005,
                                    userInfo: [NSLocalizedDescriptionKey: "Parent directory unavailable: \(parentDir.path)"]
                                )
                            )
                        }
                    }
                    let preEncodeItems = (try? self.fileManager.contentsOfDirectory(atPath: parentDir.path)) ?? []
                    self.debugLogSaveStage(
                        "dirList BEFORE encode count=\(preEncodeItems.count) items=\(preEncodeItems.sorted())"
                    )
                    let existingCreationDate: Date? = {
                        guard self.fileManager.fileExists(atPath: output.path),
                              let attrs = try? self.fileManager.attributesOfItem(atPath: output.path) else { return nil }
                        return attrs[.creationDate] as? Date
                    }()
                    self.debugLogSaveStage(
                        "save original start path=\(output.path) ext=\(output.pathExtension.lowercased()) type=\(UTType.heic.identifier)"
                    )
                    let heicData = try self.encodeImageData(
                        from: data,
                        outputType: .heic,
                        captureTime: EmbeddedCaptureTime(captureDate: captureDate),
                        metadataContext: metadataContext,
                        compressionQuality: 0.98
                    )
                    self.debugLogSaveStage("encodedBytes=\(heicData.count)")
                    let data = heicData as Data

                    let dirItemsBeforeRemove = (try? self.fileManager.contentsOfDirectory(atPath: parentDir.path)) ?? []
                    self.debugLogSaveStage(
                        "dirList BEFORE remove count=\(dirItemsBeforeRemove.count) items=\(dirItemsBeforeRemove.sorted())"
                    )

                    let existedBefore = self.fileManager.fileExists(atPath: output.path)
                    self.debugLogSaveStage("stage=remove existedBefore=\(existedBefore)")
                    if existedBefore {
                        try? self.fileManager.removeItem(at: output)
                    }
                    let dirItemsAfterRemove = (try? self.fileManager.contentsOfDirectory(atPath: parentDir.path)) ?? []
                    self.debugLogSaveStage(
                        "dirList AFTER remove count=\(dirItemsAfterRemove.count) items=\(dirItemsAfterRemove.sorted())"
                    )
                    self.debugLogSaveStage("stage=remove done")

                    self.debugLogSaveStage("stage=write begin bytes=\(data.count)")
                    self.debugLogSaveStage("dest hasDirectoryPath=\(output.hasDirectoryPath) dest=\(output.path)")
                    if output.hasDirectoryPath {
                        throw SavePhotoError.writeFailed(
                            NSError(
                                domain: "SavePhoto",
                                code: 99,
                                userInfo: [NSLocalizedDescriptionKey: "destinationURL is directory path"]
                            )
                        )
                    }

                    // Ensure parent exists every time using the exact parent path.
                    try self.fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    isDir = ObjCBool(false)
                    let parentExistsAfterMkdir = self.fileManager.fileExists(atPath: parentDir.path, isDirectory: &isDir)
                    self.debugLogSaveStage("parentExistsAfterMkdir=\(parentExistsAfterMkdir) isDir=\(isDir.boolValue)")
                    guard parentExistsAfterMkdir, isDir.boolValue else {
                        throw SavePhotoError.writeFailed(
                            NSError(
                                domain: "SavePhoto",
                                code: 97,
                                userInfo: [NSLocalizedDescriptionKey: "Parent directory unavailable after createDirectory"]
                            )
                        )
                    }

                    do {
                        try data.write(to: output, options: [.atomic])
                        self.debugLogSaveStage("stage=write success")
                    } catch {
                        self.debugLogSaveStage("stage=write ERROR \(error)")
                        throw SavePhotoError.writeFailed(error)
                    }

                    var finalIsDir = ObjCBool(false)
                    let existsAfter = self.fileManager.fileExists(atPath: output.path, isDirectory: &finalIsDir)
                    self.debugLogSaveStage("stage=verify existsAfter=\(existsAfter)")
                    if existsAfter {
                        let attrs = try self.fileManager.attributesOfItem(atPath: output.path)
                        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                        self.debugLogSaveStage("stage=verify size=\(size)")
                        if finalIsDir.boolValue || size <= 0 {
                            throw SavePhotoError.writeFailed(
                                NSError(
                                    domain: "SavePhoto",
                                    code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "final write verify failed"]
                                )
                            )
                        }
                        self.debugLogSaveStage("wrote=\(output.lastPathComponent) size=\(size)")
                        let dirItemsAfterWrite = (try? self.fileManager.contentsOfDirectory(atPath: parentDir.path)) ?? []
                        self.debugLogSaveStage(
                            "dirList AFTER write count=\(dirItemsAfterWrite.count) items=\(dirItemsAfterWrite.sorted())"
                        )
                        let heics = dirItemsAfterWrite.filter {
                            let lower = $0.lowercased()
                            return lower.hasSuffix(".heic") || lower.hasSuffix(".heif")
                        }
                        self.debugLogSaveStage(
                            "dirList count=\(dirItemsAfterWrite.count) heicCount=\(heics.count) items=\(dirItemsAfterWrite.sorted())"
                        )
                    } else {
                        let items = (try? self.fileManager.contentsOfDirectory(atPath: parentDir.path)) ?? []
                        self.debugLogSaveStage("stage=verify MISSING. parentDirItems=\(items)")
                        throw SavePhotoError.writeFailed(
                            NSError(
                                domain: "SavePhoto",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "missing after write"]
                            )
                        )
                    }

                    self.debugLogSaveStage("stage=setAttributes begin")
                    do {
                        let creationDate = existingCreationDate ?? captureDate
                        try self.fileManager.setAttributes(
                            [
                                .creationDate: creationDate,
                                .modificationDate: captureDate
                            ],
                            ofItemAtPath: output.path
                        )
                        self.debugLogSaveStage("stage=setAttributes success")
                        if let attrs = try? self.fileManager.attributesOfItem(atPath: output.path) {
                            let created = attrs[.creationDate] as? Date
                            let modified = attrs[.modificationDate] as? Date
                            self.debugLogSaveStage("stage=setAttributes readback creation=\(String(describing: created)) modification=\(String(describing: modified))")
                        }
                        self.debugLogWrittenImageProperties(at: output)
                    } catch {
                        self.debugLogSaveStage("stage=setAttributes ERROR \(error)")
                    }
                    return output.path
                }
                DispatchQueue.main.async {
                    self.reloadAssets()
                    completion(true, savedPath, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    let typed = (error as? SavePhotoError) ?? .writeFailed(error)
                    if case let .directoryMissing(path) = typed {
                        self.debugLogSaveStage("save original failed directory missing path=\(path)")
                    }
                    self.debugLogSaveStage("save original failed stage=\(typed.shortReason) error=\(error)")
                    if case .writeFailed = typed {
                        completion(false, nil, "Write \(error.localizedDescription)")
                    } else {
                        completion(false, nil, typed.shortReason)
                    }
                }
            }
        }
    }

    func saveStampedPhotoDataToSession(
        data: Data,
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID,
        captureDate: Date,
        metadataContext: EmbeddedMetadataContext? = nil,
        completion: @escaping (Bool, String?, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outputPath: String = try self.localStore.performFileIOSync {
                    try self.localStore.ensureSessionFolders(propertyID: propertyID, sessionID: sessionID)
                    let filename = "\(shotID.uuidString).jpg"
                    let output = self.localStore
                        .sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
                        .appendingPathComponent("Stamped", isDirectory: true)
                        .appendingPathComponent(filename, isDirectory: false)
                    let sessionFolder = self.localStore.sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
                    print("[iCloud] activeRoot=\(self.localStore.storageRootURL().path)")
                    print("[iCloud] sessionSaveFolder=\(sessionFolder.path)")
                    let parentDir = output.deletingLastPathComponent()
                    try self.fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    let parentExists = self.fileManager.fileExists(atPath: parentDir.path)
#if DEBUG
                    self.debugLogSaveStage("save stamped parentDir=\(parentDir.path) existsAfterCreate=\(parentExists ? "YES" : "NO")")
#endif
                    guard parentExists else {
                        throw SavePhotoError.directoryMissing(parentDir.path)
                    }
                    if self.fileManager.fileExists(atPath: output.path) {
                        try? self.fileManager.removeItem(at: output)
                    }
                    self.debugLogSaveStage(
                        "save stamped start path=\(output.path) ext=\(output.pathExtension.lowercased()) type=\(UTType.jpeg.identifier)"
                    )
                    let jpgData = try self.encodeImageData(
                        from: data,
                        outputType: .jpeg,
                        captureTime: EmbeddedCaptureTime(captureDate: captureDate),
                        metadataContext: metadataContext,
                        compressionQuality: 0.90
                    )
                    let encodedBytes = jpgData.count
                    do {
                        try jpgData.write(to: output, options: .atomic)
                    } catch {
                        throw SavePhotoError.writeFailed(error)
                    }
                    let exists = self.fileManager.fileExists(atPath: output.path)
                    let sizeBytes = self.fileSizeBytes(at: output)
                    let wroteBytes = sizeBytes
                    self.debugLogSaveStage("encodedBytes=\(encodedBytes) wroteBytes=\(wroteBytes) exists=\(exists ? "YES" : "NO") size=\(sizeBytes)")
                    self.debugLogSaveStage("save stamped wrote exists=\(exists ? "YES" : "NO") bytes=\(sizeBytes)")
                    if !exists || sizeBytes <= 0 {
                        throw SavePhotoError.writeFailed(
                            NSError(
                                domain: "ScoutCapture.Storage",
                                code: 1004,
                                userInfo: [NSLocalizedDescriptionKey: "Stamped file missing or zero bytes after write."]
                            )
                        )
                    }
                    do {
                        try self.fileManager.setAttributes(
                            [
                                .creationDate: captureDate,
                                .modificationDate: captureDate
                            ],
                            ofItemAtPath: output.path
                        )
                        if let attrs = try? self.fileManager.attributesOfItem(atPath: output.path) {
                            let created = attrs[.creationDate] as? Date
                            let modified = attrs[.modificationDate] as? Date
                            self.debugLogSaveStage("save stamped setAttributes readback creation=\(String(describing: created)) modification=\(String(describing: modified)) type=\(UTType.jpeg.identifier)")
                        }
                        self.debugLogWrittenImageProperties(at: output)
                    } catch {
                        throw SavePhotoError.setAttributesFailed(error)
                    }
                    return output.path
                }
                DispatchQueue.main.async {
                    completion(true, outputPath, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    let typed = (error as? SavePhotoError) ?? .writeFailed(error)
                    if case let .directoryMissing(path) = typed {
                        self.debugLogSaveStage("save stamped failed directory missing path=\(path)")
                    }
                    self.debugLogSaveStage("save stamped failed stage=\(typed.shortReason) error=\(error)")
                    completion(false, nil, typed.shortReason)
                }
            }
        }
    }

    private func encodeImageData(
        from sourceData: Data,
        outputType: UTType,
        captureTime: EmbeddedCaptureTime,
        metadataContext: EmbeddedMetadataContext?,
        compressionQuality: CGFloat
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let sourceCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SavePhotoError.missingCGImage
        }
        let sourceProps = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let sourceOrientationRaw = (sourceProps[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let capturedOrientationRaw = metadataContext?.capturedExifOrientationRaw
        let resolvedOrientationRaw = sourceOrientationRaw ?? capturedOrientationRaw ?? 1
        debugLogSaveStage(
            "orientation capturedRaw=\(capturedOrientationRaw.map(String.init) ?? "nil") sourceRaw=\(sourceOrientationRaw.map(String.init) ?? "nil") resolvedRaw=\(resolvedOrientationRaw)"
        )
        debugLogSaveStage("encode source pixelWidth=\(sourceCGImage.width) pixelHeight=\(sourceCGImage.height)")
        let image = normalizeToUprightPixels(sourceCGImage, orientationRaw: resolvedOrientationRaw)
        debugLogSaveStage("encode upright pixelWidth=\(image.width) pixelHeight=\(image.height)")
        var mergedProps = sourceProps
        var exif = (mergedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        var tiff = (mergedProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = captureTime.localDateTimeString
        exif[kCGImagePropertyExifDateTimeDigitized] = captureTime.localDateTimeString
        exif[kCGImagePropertyExifSubsecTimeOriginal] = captureTime.subsecString
        exif[kCGImagePropertyExifSubsecTimeDigitized] = captureTime.subsecString
        exif[kCGImagePropertyExifOffsetTimeOriginal] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifOffsetTimeDigitized] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifOffsetTime] = captureTime.tzOffsetString
        tiff[kCGImagePropertyTIFFDateTime] = captureTime.localDateTimeString
        if let userComment = scoutStructuredComment(
            captureTime: captureTime,
            metadataContext: metadataContext
        ) {
            exif[kCGImagePropertyExifUserComment] = userComment
        }
        mergedProps[kCGImagePropertyExifDictionary] = exif
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        mergedProps[kCGImagePropertyOrientation] = 1
        tiff[kCGImagePropertyTIFFOrientation] = 1
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        debugLogSaveStage("orientation writeTag exif/tiff=1")

        if let gps = makeGPSDictionary(
            latitude: metadataContext?.latitude,
            longitude: metadataContext?.longitude,
            altitude: nil,
            accuracyMeters: metadataContext?.accuracyMeters,
            captureTime: captureTime
        ) {
            mergedProps[kCGImagePropertyGPSDictionary] = gps
        }
        let descriptionLines = makeHumanReadableDescriptionLines(
            captureTime: captureTime,
            metadataContext: metadataContext
        )
        let descriptionText = descriptionLines.joined(separator: "\n")
        if !descriptionText.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription] = descriptionText
            mergedProps[kCGImagePropertyTIFFDictionary] = tiff
            var iptc = (mergedProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            iptc[kCGImagePropertyIPTCCaptionAbstract] = descriptionText
            let keywords = makeKeywordList(metadataContext: metadataContext)
            if !keywords.isEmpty {
                iptc[kCGImagePropertyIPTCKeywords] = keywords
            }
            mergedProps[kCGImagePropertyIPTCDictionary] = iptc
        }
        mergedProps[kCGImageDestinationLossyCompressionQuality] = compressionQuality

        debugLogMetadataKeys(mergedProps, captureTime: captureTime, metadataContext: metadataContext)

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            throw SavePhotoError.imageDestinationCreateFailed
        }

        if let xmpMetadata = buildXMPMetadata(
            from: source,
            captureTime: captureTime,
            metadataContext: metadataContext
        ) {
            CGImageDestinationAddImageAndMetadata(
                destination,
                image,
                xmpMetadata,
                mergedProps as CFDictionary
            )
        } else {
            CGImageDestinationAddImage(destination, image, mergedProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw SavePhotoError.imageDestinationFinalizeFailed
        }
        return destinationData as Data
    }

    private func normalizeToUprightPixels(_ image: CGImage, orientationRaw: UInt32) -> CGImage {
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        let uiOrientation = UIImage.Orientation(from: orientation)
        if uiOrientation == .up {
            return image
        }
        let uiImage = UIImage(cgImage: image, scale: 1.0, orientation: uiOrientation)
        let size = uiImage.size
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage ?? image
    }

    private static let exifTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let exifSubsecFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "SSS"
        return formatter
    }()

    private static func exifOffsetString(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private static func iso8601WithOffsetString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }

    private static let humanDescriptionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MM-dd-yyyy h:mm:ss a"
        return formatter
    }()

    private func makeGPSDictionary(
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        accuracyMeters: Double?,
        captureTime: EmbeddedCaptureTime
    ) -> [CFString: Any]? {
        guard let latitude, let longitude else { return nil }
        var gps: [CFString: Any] = [:]
        gps[kCGImagePropertyGPSLatitude] = abs(latitude)
        gps[kCGImagePropertyGPSLatitudeRef] = latitude >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude] = abs(longitude)
        gps[kCGImagePropertyGPSLongitudeRef] = longitude >= 0 ? "E" : "W"
        if let altitude {
            gps[kCGImagePropertyGPSAltitude] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = altitude >= 0 ? 0 : 1
        }
        if let accuracyMeters, accuracyMeters >= 0 {
            gps[kCGImagePropertyGPSHPositioningError] = accuracyMeters
        }
        gps[kCGImagePropertyGPSDateStamp] = Self.gpsDateFormatter.string(from: captureTime.captureDate)
        gps[kCGImagePropertyGPSTimeStamp] = Self.gpsTimeFormatter.string(from: captureTime.captureDate)
        return gps
    }

    private static let gpsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    private static let gpsTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func makeHumanReadableDescriptionLines(
        captureTime: EmbeddedCaptureTime,
        metadataContext: EmbeddedMetadataContext?
    ) -> [String] {
        guard let metadataContext else { return [] }
        var lines: [String] = []
        let propertyName = metadataContext.propertyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !propertyName.isEmpty {
            lines.append(propertyName)
        }
        let building = metadataContext.building?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let elevation = metadataContext.elevation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detailType = metadataContext.detailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let angle = metadataContext.angleIndex.map { "Angle \($0)" } ?? ""
        let line2Parts = [building, elevation, detailType, angle].filter { !$0.isEmpty }
        if !line2Parts.isEmpty {
            lines.append(line2Parts.joined(separator: " | "))
        }
        lines.append(Self.humanDescriptionDateFormatter.string(from: captureTime.captureDate))
        if metadataContext.isFlagged == true {
            let note = metadataContext.detailNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !note.isEmpty {
                lines.append(note)
            }
        }
        return lines
    }

    private func makeKeywordList(metadataContext: EmbeddedMetadataContext?) -> [String] {
        guard let metadataContext else { return [] }
        var keywords: [String] = ["SCOUT"]
        let maybeValues: [String?] = [
            metadataContext.propertyName,
            metadataContext.building,
            metadataContext.elevation,
            metadataContext.detailType
        ]
        for value in maybeValues {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                keywords.append(trimmed)
            }
        }
        if let angle = metadataContext.angleIndex {
            keywords.append("Angle \(angle)")
        }
        if metadataContext.isGuided == true {
            keywords.append("Guided")
        } else {
            keywords.append("Free")
        }
        if metadataContext.isFlagged == true {
            keywords.append("Flagged")
        }
        let issueStatus = metadataContext.issueStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if issueStatus.contains("resolved") {
            keywords.append("IssueResolved")
        } else if metadataContext.isFlagged == true {
            keywords.append("IssueActive")
        }
        return Array(NSOrderedSet(array: keywords)) as? [String] ?? keywords
    }

    private func scoutStructuredComment(
        captureTime: EmbeddedCaptureTime,
        metadataContext: EmbeddedMetadataContext?
    ) -> String? {
        guard let metadataContext else { return nil }
        var fields: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                fields[key] = trimmed
            }
        }
        put("propertyID", metadataContext.propertyID?.uuidString)
        put("propertyName", metadataContext.propertyName)
        put("propertyAddress", metadataContext.propertyAddress)
        put("sessionID", metadataContext.sessionID?.uuidString)
        put("shotID", metadataContext.shotID?.uuidString)
        put("shotKey", metadataContext.shotKey)
        put("building", metadataContext.building)
        put("elevation", metadataContext.elevation)
        put("detailType", metadataContext.detailType)
        put("angleIndex", metadataContext.angleIndex.map(String.init))
        put("isGuided", metadataContext.isGuided.map { $0 ? "true" : "false" })
        put("isFlagged", metadataContext.isFlagged.map { $0 ? "true" : "false" })
        put("captureMode", metadataContext.captureMode)
        put("lens", metadataContext.lens)
        put("orientation", metadataContext.orientation)
        put("appVersion", metadataContext.appVersion)
        put("osVersion", metadataContext.osVersion)
        put("deviceModel", metadataContext.deviceModel)
        put("schemaVersion", metadataContext.schemaVersion.map(String.init))
        put("issueStatus", metadataContext.issueStatus)
        put("issueNote", metadataContext.detailNote)
        put("captureDateLocal", captureTime.localDateTimeString)
        put("captureDateISO8601", captureTime.iso8601WithOffset)
        if let accuracy = metadataContext.accuracyMeters {
            put("gpsAccuracyMeters", String(format: "%.3f", accuracy))
        }
        guard !fields.isEmpty else { return nil }
        let ordered = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }
        return ordered.joined(separator: ";")
    }

    private func buildXMPMetadata(
        from source: CGImageSource?,
        captureTime: EmbeddedCaptureTime,
        metadataContext: EmbeddedMetadataContext?
    ) -> CGMutableImageMetadata? {
        guard let metadataContext else { return nil }
        let baseMetadata = source.flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
        let mutable = baseMetadata.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        var registrationError: Unmanaged<CFError>?
        _ = CGImageMetadataRegisterNamespaceForPrefix(
            mutable,
            "https://scoutcapture.app/ns/1.0/" as CFString,
            "scout" as CFString,
            &registrationError
        )
        setXMPTag(mutable, path: "xmp:CreateDate", value: captureTime.iso8601WithOffset)
        setXMPTag(mutable, path: "xmp:ModifyDate", value: captureTime.iso8601WithOffset)
        setXMPTag(mutable, path: "scout:propertyID", value: metadataContext.propertyID?.uuidString)
        setXMPTag(mutable, path: "scout:propertyName", value: metadataContext.propertyName)
        setXMPTag(mutable, path: "scout:propertyAddress", value: metadataContext.propertyAddress)
        setXMPTag(mutable, path: "scout:sessionID", value: metadataContext.sessionID?.uuidString)
        setXMPTag(mutable, path: "scout:shotID", value: metadataContext.shotID?.uuidString)
        setXMPTag(mutable, path: "scout:shotKey", value: metadataContext.shotKey)
        setXMPTag(mutable, path: "scout:building", value: metadataContext.building)
        setXMPTag(mutable, path: "scout:elevation", value: metadataContext.elevation)
        setXMPTag(mutable, path: "scout:detailType", value: metadataContext.detailType)
        setXMPTag(mutable, path: "scout:angleIndex", value: metadataContext.angleIndex.map(String.init))
        setXMPTag(mutable, path: "scout:isGuided", value: metadataContext.isGuided.map { $0 ? "true" : "false" })
        setXMPTag(mutable, path: "scout:isFlagged", value: metadataContext.isFlagged.map { $0 ? "true" : "false" })
        setXMPTag(mutable, path: "scout:captureMode", value: metadataContext.captureMode)
        setXMPTag(mutable, path: "scout:lens", value: metadataContext.lens)
        setXMPTag(mutable, path: "scout:orientation", value: metadataContext.orientation)
        setXMPTag(mutable, path: "scout:appVersion", value: metadataContext.appVersion)
        setXMPTag(mutable, path: "scout:osVersion", value: metadataContext.osVersion)
        setXMPTag(mutable, path: "scout:deviceModel", value: metadataContext.deviceModel)
        setXMPTag(mutable, path: "scout:schemaVersion", value: metadataContext.schemaVersion.map(String.init))
        setXMPTag(mutable, path: "scout:issueStatus", value: metadataContext.issueStatus)
        setXMPTag(mutable, path: "scout:issueNote", value: metadataContext.detailNote)
        if let accuracy = metadataContext.accuracyMeters {
            setXMPTag(mutable, path: "scout:gpsAccuracyMeters", value: String(format: "%.3f", accuracy))
        }
        return mutable
    }

    private func setXMPTag(_ metadata: CGMutableImageMetadata, path: String, value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        let components = path.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return }
        let prefix = components[0]
        let name = components[1]
        let namespace: String
        switch prefix {
        case "xmp":
            namespace = "http://ns.adobe.com/xap/1.0/"
        case "scout":
            namespace = "https://scoutcapture.app/ns/1.0/"
        default:
            return
        }
        guard let tag = CGImageMetadataTagCreate(
            namespace as CFString,
            prefix as CFString,
            name as CFString,
            .string,
            trimmed as CFString
        ) else {
            return
        }
        CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, tag)
    }

    private func debugLogSaveStage(_ message: String) {
#if DEBUG
        print("[SavePhoto] \(message)")
#endif
    }

    private func debugLogMetadataKeys(
        _ metadata: [CFString: Any],
        captureTime: EmbeddedCaptureTime,
        metadataContext: EmbeddedMetadataContext?
    ) {
#if DEBUG
        let topKeys = metadata.keys.map { $0 as String }.sorted()
        let exifKeys = ((metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String }.sorted()
        let tiffKeys = ((metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String }.sorted()
        let gpsKeys = ((metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String }.sorted()
        let exifDict = (metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let hasDateTimeOriginal = exifDict[kCGImagePropertyExifDateTimeOriginal] != nil
        let gpsDict = (metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]
        let hasGpsAccuracy = gpsDict[kCGImagePropertyGPSHPositioningError] != nil
        print("[SavePhoto] captureDate=\(captureTime.captureDate) localDateTimeString=\(captureTime.localDateTimeString) tzOffset=\(captureTime.tzOffsetString) iso8601WithOffset=\(captureTime.iso8601WithOffset)")
        let accuracyText = metadataContext?.accuracyMeters.map { String(format: "%.3f", $0) } ?? "nil"
        print("[SavePhoto] gps present=\(gpsDict.isEmpty ? "NO" : "YES") accuracyMeters=\(accuracyText)")
        print("[SavePhoto] metadata top-level keys: \(topKeys)")
        print("[SavePhoto] metadata EXIF keys: \(exifKeys)")
        print("[SavePhoto] metadata TIFF keys: \(tiffKeys)")
        print("[SavePhoto] metadata GPS keys: \(gpsKeys)")
        print("[SavePhoto] metadata has DateTimeOriginal=\(hasDateTimeOriginal) has GPSHPositioningError=\(hasGpsAccuracy)")
#endif
    }

    private func fileSizeBytes(at url: URL) -> Int {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    private func debugLogWrittenImageProperties(at url: URL) {
#if DEBUG
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            debugLogSaveStage("written image readback failed path=\(url.path)")
            return
        }
        let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
        debugLogSaveStage("written image props pixelWidth=\(pixelWidth) pixelHeight=\(pixelHeight) orientation=\(orientation)")
#endif
    }

    func deleteAssetsFromAlbum(localIdentifiers: [String], completion: @escaping (Bool) -> Void) {
        deleteFiles(localIdentifiers: localIdentifiers, completion: completion)
    }

    func deleteAssetsFromLibrary(localIdentifiers: [String], completion: @escaping (Bool) -> Void) {
        deleteFiles(localIdentifiers: localIdentifiers, completion: completion)
    }

    private func deleteFiles(localIdentifiers: [String], completion: @escaping (Bool) -> Void) {
        let ids = Array(Set(localIdentifiers))
        guard !ids.isEmpty else {
            completion(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var success = true
            self.localStore.performFileIOSync {
                for id in ids {
                    let path = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { continue }
                    if self.fileManager.fileExists(atPath: path) {
                        do {
                            try self.fileManager.removeItem(atPath: path)
                        } catch {
                            success = false
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.reloadAssets()
                completion(success)
            }
        }
    }

    private func loadActiveIssueCount(for reportTitle: String) -> Int {
        let key = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return 0 }
        let all = readIssueCountsByTitle()
        return max(0, all[key] ?? 0)
    }

    private func storeActiveIssueCount(_ count: Int, for reportTitle: String) {
        let key = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var all = readIssueCountsByTitle()
        all[key] = max(0, count)
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: activeIssueCountsKey)
    }

    private func readIssueCountsByTitle() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: activeIssueCountsKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }
}


 
// MARK: - Glass UI Helpers (single style language)

private struct GlassPill: ViewModifier {

    let height: CGFloat
    let horizontalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(.ultraThinMaterial, in: Capsule())
            // softer glass edge (less “solid ring”)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            // subtle internal highlight to feel more native
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
            )
            // lighter shadow so the border doesn’t read as harsh
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 5)
    }
}


private struct GlassCircle: ViewModifier {

    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            // softer glass edge (match GlassPill)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            // subtle internal highlight (match GlassPill)
            .overlay(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
            )
            // lighter shadow so it reads as glass, not a hard button
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 5)
    }
}


private extension View {
    func glassPill(height: CGFloat = 40, horizontalPadding: CGFloat = 16) -> some View {
        modifier(GlassPill(height: height, horizontalPadding: horizontalPadding))
    }

    func glassCircle(size: CGFloat = 40) -> some View {
        modifier(GlassCircle(size: size))
    }
}

// MARK: - Press feedback (native camera feel)

private struct PressScaleEffect: ViewModifier {
    let pressed: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.80), value: pressed)
    }
}

private extension View {
    func pressScaleEffect(_ pressed: Bool, scale: CGFloat = 0.95) -> some View {
        modifier(PressScaleEffect(pressed: pressed, scale: scale))
    }
}

// MARK: - Album preview circle button

private struct RecentAlbumPreviewCircleButton: View {

    let lastAsset: ReportAsset?
    let size: CGFloat
    let action: () -> Void

    @ObservedObject var cache: AssetImageCache
    let refreshToken: UUID

    @State private var thumb: UIImage? = nil
    @State private var lastId: String = ""

    // Tap preview animation
    @State private var pop: Bool = false

    var body: some View {
        Button(action: {
            action()
        }) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: size, height: size)

                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
            }
            .scaleEffect(pop ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onAppear { loadThumbIfNeeded() }
        .onChange(of: lastAsset?.localIdentifier ?? "") { _, _ in
            loadThumbIfNeeded()
        }
        .onChange(of: refreshToken) { _, _ in
            loadThumbIfNeeded(force: true)
        }
        .onChange(of: thumb != nil) { _, newValue in
            guard newValue else { return }
            popOnce()
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.70), value: pop)
    }

    private func popOnce() {
        pop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            pop = false
        }
    }

    private func loadThumbIfNeeded(force: Bool = false) {
        guard let asset = lastAsset else {
            thumb = nil
            lastId = ""
            return
        }

        if force {
            thumb = nil
            lastId = ""
        }
        if asset.localIdentifier == lastId, thumb != nil { return }
        lastId = asset.localIdentifier

        let scale = UIScreen.currentScale
        let px = max(260, size * scale * 3.0)

        cache.requestThumbnail(for: asset, pixelSize: px) { img in
            DispatchQueue.main.async { self.thumb = img }
        }
    }
}

// MARK: - Fullscreen Library (grid + contextual top bar)

// MARK: - Fullscreen viewer with swipe + filmstrip

private struct ReportPhotoViewer: View {

    let title: String
    let assets: [ReportAsset]
    let startIndex: Int
    let detailIdOverride: String?
    let metadataPropertyID: UUID?
    let metadataSessionID: UUID?
    @ObservedObject var cache: AssetImageCache
    let viewerToken: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    private let localStore = LocalStore()

    // Physical device orientation (UI is portrait locked, we rotate the content ourselves)
    @State private var lastValidOrientation: UIDeviceOrientation = .portrait

    private var isLandscape: Bool {
        lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight
    }

    private var rotationDegrees: Double {
        switch lastValidOrientation {
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return -90
        default:
            return 0
        }
    }

    private func refreshOrientation() {
        let o = UIDevice.current.orientation

        // IMPORTANT:
        // In a portrait-locked app, iOS can report `.portrait` while the phone is physically upside down.
        // If we accept upside-down as portrait, the viewer will snap back to portrait while you are inverted.
        // Photos-like behavior: stay in the last landscape until you return to a true upright portrait.
        if o == .portraitUpsideDown {
            return
        }

        let newValue: UIDeviceOrientation? = {
            switch o {
            case .portrait:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return o
            default:
                return nil
            }
        }()

        guard let newValue else { return }
        guard newValue != lastValidOrientation else { return }

        // Only force a rebuild when switching between portrait and landscape.
        // Rotating between landscapeLeft and landscapeRight should not reset zoom.
        let wasLandscape = (lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight)
        let willBeLandscape = (newValue == .landscapeLeft || newValue == .landscapeRight)

        lastValidOrientation = newValue

        if wasLandscape != willBeLandscape {
            orientationResetToken &+= 1
        }
    }

    @State private var index: Int
    @State private var barVisible: Bool = true
    @State private var barsManuallyHidden: Bool = false


    private func setBarsVisible(_ visible: Bool, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                barVisible = visible
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                barVisible = visible
            }
        }
    }

    // True while the user is actively swiping the main photo (TabView paging).
    // Used to prevent the filmstrip scrub logic from fighting the page swipe.
    @State private var isPagingDrag: Bool = false

    // Forces the zoom container to re-fit on device rotation
    @State private var orientationResetToken: Int = 0
    @State private var shotMetadataByKey: [String: ShotMetadata] = [:]
    @State private var shotMetadataByShotID: [UUID: ShotMetadata] = [:]

    // Per-page zoom reset tokens.
    // When you swipe away from a page, we increment that page's token so returning to it is back at fit.
    @State private var pageResetTokens: [Int: Int] = [:]

    init(
        title: String,
        assets: [ReportAsset],
        startIndex: Int,
        detailIdOverride: String? = nil,
        metadataPropertyID: UUID? = nil,
        metadataSessionID: UUID? = nil,
        cache: AssetImageCache,
        viewerToken: Int
    ) {
        self.title = title
        self.assets = assets
        self.startIndex = startIndex
        self.detailIdOverride = detailIdOverride
        self.metadataPropertyID = metadataPropertyID
        self.metadataSessionID = metadataSessionID
        self.cache = cache
        self.viewerToken = viewerToken
        _index = State(initialValue: min(max(0, startIndex), max(0, assets.count - 1)))
    }
       
   
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // When we rotate content inside a portrait locked app, swap the content frame.
            let contentW = isLandscape ? h : w
            let contentH = isLandscape ? w : h

            ZStack {
                Color.black.ignoresSafeArea()

                ZStack {
                    ZStack {
                        TabView(selection: $index) {
                            ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                                FullImage(
                                    asset: asset,
                                    assetId: asset.localIdentifier,
                                    cache: cache,
                                    resetToken: (orientationResetToken * 10_000) + (pageResetTokens[idx, default: 0]),
                                    onHideBars: {
                                        // Only auto-hide if user did NOT manually hide bars.
                                        if barVisible && !barsManuallyHidden {
                                            setBarsVisible(false, animated: false)
                                        }
                                    },
                                    onShowBars: {
                                        // Only auto-show if bars were hidden by zoom behavior, not manual tap.
                                        if !barVisible && !barsManuallyHidden {
                                            setBarsVisible(true, animated: false)
                                        }
                                    }
                                )
                                    .tag(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeOut(duration: 0.18)) {
                                            barVisible.toggle()
                                        }

                                        // Manual override flag
                                        if barVisible {
                                            barsManuallyHidden = false
                                        } else {
                                            barsManuallyHidden = true
                                        }
                                    }
                            }
                        }
                        .id("\(viewerToken)-\(orientationResetToken)")
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .ignoresSafeArea()
                        .animation(nil, value: barVisible)
                        
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { _ in
                                    // While swiping pages, suspend filmstrip-driven selection updates.
                                    if !isPagingDrag { isPagingDrag = true }
                                }
                                .onEnded { _ in
                                    // Let the page settle before re-enabling filmstrip scrub updates.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                        isPagingDrag = false
                                    }
                                }
                        )

                        .overlay(alignment: .bottom) {
                            if barVisible, assets.count > 1 {
                                filmStrip()
                                    .padding(.bottom, 18)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }

                    // Header overlay should NOT be a full-screen hit-testing layer.
                    // Keep it pinned to the top with its intrinsic height so swipes on the photo still page.
                    .overlay(alignment: .top) {
                        if barVisible {
                            headerOverlay()
                        }
                    }
                }
                .frame(width: contentW, height: contentH, alignment: .center)
                .rotationEffect(.degrees(rotationDegrees))
                .position(x: w * 0.5, y: h * 0.5)
            }
            .statusBarHidden(isLandscape)
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshOrientation()

                let v = min(max(0, startIndex), max(0, assets.count - 1))
                index = v
                loadShotMetadataCache()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                refreshOrientation()
            }
            
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
        .onChange(of: index) { oldValue, newValue in
            // When leaving a page, reset its zoom so returning to it is back at fit.
            if oldValue != newValue {
                pageResetTokens[oldValue, default: 0] &+= 1
            }
        }
        .onChange(of: startIndex) { _, newValue in
            let v = min(max(0, newValue), max(0, assets.count - 1))
            index = v
        }
        .onChange(of: viewerToken) { _, _ in
            loadShotMetadataCache()
        }
    }

    private func filmStrip() -> some View {
        FilmStrip(
            assets: assets,
            selectedIndex: $index,
            isPagingDrag: $isPagingDrag,
            cache: cache
        )
        .padding(.horizontal, 14)
    }

    private struct HeaderMeta {
        let propertyName: String
        let shotLabel: String
        let flaggedNote: String
        let photoCount: String
    }

    private var isPreviousMetadataMode: Bool {
        guard let metadataSessionID else { return false }
        guard let currentSessionID = appState.currentSession?.id else { return false }
        return metadataSessionID != currentSessionID
    }

    private func headerMeta(for asset: ReportAsset, index: Int) -> HeaderMeta {
        let propertyName = (appState.selectedProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (appState.selectedProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : title

        let metadata = metadataForAsset(asset)
        let shotLabel: String = {
            if isPreviousMetadataMode, let metadata {
                let building = metadata.building.trimmingCharacters(in: .whitespacesAndNewlines)
                let elevation = CanonicalElevation.normalize(metadata.elevation)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? metadata.elevation
                let detailType = metadata.detailType.trimmingCharacters(in: .whitespacesAndNewlines)
                let angle = max(1, metadata.angleIndex)
                var parts: [String] = []
                if !building.isEmpty { parts.append(building) }
                if !elevation.isEmpty { parts.append(elevation) }
                if !detailType.isEmpty { parts.append(detailType) }
                parts.append("Angle \(angle)")
                return parts.joined(separator: " | ")
            }
            var parts: [String] = []
            let building = metadata?.building.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let elevation = CanonicalElevation.normalize(metadata?.elevation)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detailType = metadata?.detailType.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !building.isEmpty { parts.append(building) }
            if !elevation.isEmpty { parts.append(elevation) }
            if !detailType.isEmpty { parts.append(detailType) }
            if !parts.isEmpty { return parts.joined(separator: "-") }
            let fallback = detailIdOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fallback.isEmpty ? "Shot" : fallback
        }()

        let flaggedNote: String = {
            guard let metadata, metadata.isFlagged else { return "" }
            let note = metadata.noteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return note
        }()

        let photoCount = "Photo \(index + 1) of \(max(assets.count, 1))"

        return HeaderMeta(propertyName: propertyName, shotLabel: shotLabel, flaggedNote: flaggedNote, photoCount: photoCount)
    }

    @ViewBuilder
    private func headerOverlay() -> some View {
        let safeIndex = min(max(0, index), max(0, assets.count - 1))
        let meta = assets.isEmpty ? HeaderMeta(propertyName: title, shotLabel: "Shot", flaggedNote: "", photoCount: "Photo 0 of 0")
                                : headerMeta(for: assets[safeIndex], index: safeIndex)

        ZStack(alignment: .top) {
            // Background gradient should never intercept gestures.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.92),
                    Color.black.opacity(0.70),
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.propertyName)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(meta.shotLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(meta.flaggedNote)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(height: 18, alignment: .leading)

                    Text(meta.photoCount)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .frame(minHeight: 42)
                        .padding(.horizontal, 14)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        // Critical: do NOT make this a full-screen view.
        // Keeping it to its intrinsic height prevents it from competing with TabView paging.
        .frame(height: 96, alignment: .top)
    }

    private func loadShotMetadataCache() {
        guard let propertyID = metadataPropertyID ?? appState.selectedPropertyID,
              let sessionID = metadataSessionID ?? appState.currentSession?.id else {
            shotMetadataByKey = [:]
            shotMetadataByShotID = [:]
            return
        }

        let entries = (try? localStore.fetchShotMetadata(propertyID: propertyID, sessionID: sessionID)) ?? []
        var map: [String: ShotMetadata] = [:]
        var idMap: [UUID: ShotMetadata] = [:]
        for entry in entries {
            idMap[entry.shotID] = entry
            let raw = entry.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }
            map[raw.lowercased()] = entry

            let url = URL(fileURLWithPath: raw)
            let filename = url.lastPathComponent.lowercased()
            if !filename.isEmpty { map[filename] = entry }

            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if !stem.isEmpty { map[stem] = entry }

            let originalRelative = entry.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !originalRelative.isEmpty { map[originalRelative] = entry }
            let stampedRelative = entry.stampedRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !stampedRelative.isEmpty { map[stampedRelative] = entry }
        }
        shotMetadataByKey = map
        shotMetadataByShotID = idMap
        if isPreviousMetadataMode {
            print("[PrevHeader] loaded previous shots count=\(entries.count)")
        }
    }

    private func shotIDFromAsset(_ asset: ReportAsset) -> UUID? {
        let pathStem = URL(fileURLWithPath: asset.localIdentifier).deletingPathExtension().lastPathComponent
        if let id = UUID(uuidString: pathStem) { return id }
        let filenameStem = URL(fileURLWithPath: asset.originalFilename).deletingPathExtension().lastPathComponent
        if let id = UUID(uuidString: filenameStem) { return id }
        return nil
    }

    private func metadataForAsset(_ asset: ReportAsset) -> ShotMetadata? {
        let itemKey = URL(fileURLWithPath: asset.localIdentifier).lastPathComponent
        if let shotID = shotIDFromAsset(asset), let entry = shotMetadataByShotID[shotID] {
            if isPreviousMetadataMode {
                let elevation = CanonicalElevation.normalize(entry.elevation) ?? entry.elevation
                print("[PrevHeader] itemKey=\(itemKey) matched=true shotID=\(entry.shotID.uuidString) building=\(entry.building) elevation=\(elevation) detailType=\(entry.detailType) angle=\(entry.angleIndex)")
            }
            return entry
        }

        let rawID = asset.localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFilename = asset.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            rawID.lowercased(),
            URL(fileURLWithPath: rawID).lastPathComponent.lowercased(),
            URL(fileURLWithPath: rawID).deletingPathExtension().lastPathComponent.lowercased(),
            rawFilename.lowercased(),
            URL(fileURLWithPath: rawFilename).lastPathComponent.lowercased(),
            URL(fileURLWithPath: rawFilename).deletingPathExtension().lastPathComponent.lowercased(),
            "originals/\(URL(fileURLWithPath: rawFilename).lastPathComponent.lowercased())"
        ].filter { !$0.isEmpty }

        for key in candidates {
            if let entry = shotMetadataByKey[key] {
                if isPreviousMetadataMode {
                    let elevation = CanonicalElevation.normalize(entry.elevation) ?? entry.elevation
                    print("[PrevHeader] itemKey=\(itemKey) matched=true shotID=\(entry.shotID.uuidString) building=\(entry.building) elevation=\(elevation) detailType=\(entry.detailType) angle=\(entry.angleIndex)")
                }
                return entry
            }
        }
        if isPreviousMetadataMode {
            print("[PrevHeader] itemKey=\(itemKey) matched=false fallbackUsed=true")
        }
        return nil
    }

    private struct FilmStrip: View {

        let assets: [ReportAsset]
        @Binding var selectedIndex: Int
        @Binding var isPagingDrag: Bool
        @ObservedObject var cache: AssetImageCache

        private let thumbSide: CGFloat = 36
        private let spacing: CGFloat = 2

        // Selected styling
        // Slightly larger when settled to match Photos feel.
        private let selectedScale: CGFloat = 1.28
        private let selectedExtraSidePadding: CGFloat = 10

        // While the user is dragging the strip, do NOT fight them with scrollTo.
        @State private var isUserDragging: Bool = false

        // Viewport width for proper end padding so the first/last thumb can reach center.
        @State private var viewportWidth: CGFloat = 0

        // Momentum haptics window (keeps ticking during deceleration)
        @State private var momentumHapticsUntil: Date = .distantPast
        @State private var lastHapticIndex: Int = -1
        // Avoid “random” haptics caused by layout/appearance updates (eg. bars reappearing on zoom-out).
        // We only tick haptics after the user has actually interacted with the filmstrip.
        @State private var hasUserInteractedWithStrip: Bool = false

        // Debounced "settle" so we do NOT kill momentum.
        // We only snap-to-center after scrolling activity has stopped.
        @State private var settleWorkItem: DispatchWorkItem? = nil

        // Haptic on each index change while the user is interacting with the strip.
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        private struct ItemMidXKey: PreferenceKey {
            static var defaultValue: [Int: CGFloat] = [:]
            static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
                value.merge(nextValue(), uniquingKeysWith: { $1 })
            }
        }

        var body: some View {
            ScrollViewReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.45))

                    GeometryReader { outerGeo in
                        let w = outerGeo.size.width
                        let maxThumbWidth = (thumbSide * selectedScale) + (selectedExtraSidePadding * 2)
                        let sidePad = max(0, (w - maxThumbWidth) * 0.5)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: spacing) {
                                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                                    let selected = (idx == selectedIndex)

                                    FilmThumb(
                                        asset: asset,
                                        isSelected: selected,
                                        cache: cache,
                                        side: thumbSide
                                    )
                                    .scaleEffect(selected ? selectedScale : 1.0)
                                    .padding(.horizontal, selected ? selectedExtraSidePadding : 0)
                                    .animation(.easeOut(duration: 0.10), value: selectedIndex)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Tap should jump immediately and center.
                                        isUserDragging = false
                                        momentumHapticsUntil = .distantPast
                                        selectedIndex = idx

                                        haptic.impactOccurred()
                                        haptic.prepare()
                                        lastHapticIndex = idx

                                        withAnimation(.easeOut(duration: 0.12)) {
                                            proxy.scrollTo(idx, anchor: .center)
                                        }
                                    }
                                    // Measure each thumb’s midX in the *visible viewport* coordinate space.
                                    .background(
                                        GeometryReader { itemGeo in
                                            Color.clear
                                                .preference(
                                                    key: ItemMidXKey.self,
                                                    value: [idx: itemGeo.frame(in: .named("filmstripViewport")).midX]
                                                )
                                        }
                                    )
                                }
                            }
                            // Critical: real padding so end items can reach the center.
                            .padding(.horizontal, sidePad)
                            .padding(.vertical, 6)
                        }
                        .scrollIndicators(.hidden)
                        .coordinateSpace(name: "filmstripViewport")
                        .onAppear {
                            viewportWidth = w

                            // Prime haptics and state. Doing a second prepare on the next run loop
                            // prevents the “first open has no haptics” behavior.
                            lastHapticIndex = selectedIndex
                            hasUserInteractedWithStrip = false
                            isUserDragging = false
                            momentumHapticsUntil = .distantPast

                            haptic.prepare()
                            DispatchQueue.main.async {
                                haptic.prepare()
                                proxy.scrollTo(selectedIndex, anchor: .center)
                            }
                        }
                        .onChange(of: w) { _, newW in
                            viewportWidth = newW
                        }
                        // Track user drag so programmatic centering does not fight their finger.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    // If the user is paging the main photo, do not let the filmstrip logic fight it.
                                    if isPagingDrag { return }

                                    if !isUserDragging {
                                        isUserDragging = true
                                        hasUserInteractedWithStrip = true

                                        // Re-prime haptics at the exact moment the user begins interacting.
                                        haptic.prepare()
                                    }

                                    // While finger is down, keep the momentum window alive.
                                    momentumHapticsUntil = Date().addingTimeInterval(0.90)

                                    // Cancel any pending settle snap while user is actively moving.
                                    settleWorkItem?.cancel()
                                    settleWorkItem = nil
                                }
                                .onEnded { _ in
                                    if isPagingDrag { return }

                                    // Finger lifted. Do NOT snap here. Let the scroll view decelerate naturally.
                                    isUserDragging = false
                                    momentumHapticsUntil = Date().addingTimeInterval(0.90)
                                },
                            including: .all
                        )
                        // This is the core behavior:
                        // As the strip scrolls (drag or momentum), pick the thumb closest to center.
                        .onPreferenceChange(ItemMidXKey.self) { midXs in
                            if isPagingDrag { return }
                            guard viewportWidth > 1 else { return }
                            guard !midXs.isEmpty else { return }

                            // Critical fix for the neighbor-page "blip":
                            // Only allow midX-driven selection changes when the user has actually interacted
                            // with the strip (dragging) or we're in momentum deceleration from that interaction.
                            // Layout / overlay transitions can fire preference updates; those must NOT change pages.
                            let allowSelectionUpdates = hasUserInteractedWithStrip && (isUserDragging || (Date() < momentumHapticsUntil))
                            if !allowSelectionUpdates {
                                return
                            }

                            let centerX = viewportWidth * 0.5

                            var bestIdx: Int = selectedIndex
                            var bestDist: CGFloat = .greatestFiniteMagnitude

                            for (idx, midX) in midXs {
                                let d = abs(midX - centerX)
                                if d < bestDist {
                                    bestDist = d
                                    bestIdx = idx
                                }
                            }

                            if bestIdx != selectedIndex {
                                selectedIndex = bestIdx

                                // Haptic per photo change while dragging AND during momentum deceleration.
                                if bestIdx != lastHapticIndex {
                                    haptic.impactOccurred()
                                    haptic.prepare()
                                    lastHapticIndex = bestIdx
                                }
                            }

                            // Debounced settle: do not fight momentum.
                            // When scrolling activity stops (no more midX updates), snap once to center.
                            settleWorkItem?.cancel()
                            let work = DispatchWorkItem {
                                // Only settle when finger is up.
                                guard !isUserDragging else { return }
                                withAnimation(.easeOut(duration: 0.14)) {
                                    proxy.scrollTo(selectedIndex, anchor: .center)
                                }
                            }
                            settleWorkItem = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                        }
                    }
                    .frame(height: thumbSide + 12)
                }
                .frame(height: thumbSide + 12)
                // If selection changes from outside (page swipe or tap), keep strip centered.
                // Do not fight active dragging or deceleration.
                .onChange(of: selectedIndex) { _, newValue in
                    // If selection changes from outside (page swipe or tap), keep strip centered.
                    // Do not fight active dragging, momentum, or page swipes.
                    if isPagingDrag { return }
                    if isUserDragging { return }
                    if Date() < momentumHapticsUntil { return }

                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }

        private struct FilmThumb: View {

            let asset: ReportAsset
            let isSelected: Bool
            @ObservedObject var cache: AssetImageCache
            let side: CGFloat

            @State private var img: UIImage? = nil

            var body: some View {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: side, height: side)

                    if let img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.10), lineWidth: isSelected ? 2 : 1)
                )
                .onAppear {
                    if img != nil { return }
                    let scale = UIScreen.currentScale
                    let px: CGFloat = max(220, side * 6) * scale
                    cache.requestThumbnail(for: asset, pixelSize: px) { im in
                        DispatchQueue.main.async { self.img = im }
                    }
                }
            }
        }
    }
private struct FullImage: View {

    let asset: ReportAsset
    let assetId: String
    @ObservedObject var cache: AssetImageCache
    let resetToken: Int
    let onHideBars: () -> Void
    let onShowBars: () -> Void

    @State private var full: UIImage? = nil
    @State private var thumb: UIImage? = nil

    // A stable key that changes whenever we need a hard reset, even if UIImage instances are reused.
    private var zoomKey: String { "\(assetId)-\(resetToken)" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let full {
                ZoomableScrollImage(
                    image: full,
                    imageKey: zoomKey,
                    onHideBars: onHideBars,
                    onShowBars: onShowBars
                )
                .id(zoomKey)
                .ignoresSafeArea()
            } else if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                // No spinner: avoid the “scroll wheel” flash during first fast scrub.
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            loadImagesIfNeeded()
        }
        .onChange(of: assetId) { _, _ in
            // Ensure we reset state if SwiftUI reuses the view.
            full = nil
            thumb = nil
            loadImagesIfNeeded()
        }
    }

    private func loadImagesIfNeeded() {
        // Kick a quick thumbnail first so scrubbing feels instant.
        if thumb == nil {
            let scale = UIScreen.currentScale
            let px: CGFloat = 420 * scale
            cache.requestThumbnail(for: asset, pixelSize: px) { im in
                DispatchQueue.main.async { self.thumb = im }
            }
        }

        if full != nil { return }
        cache.requestFull(for: asset) { im in
            DispatchQueue.main.async { self.full = im }
        }
    }
}

        private struct ZoomableScrollImage: UIViewRepresentable {

        let image: UIImage
        let imageKey: String
        let onHideBars: () -> Void
        let onShowBars: () -> Void

        func makeUIView(context: Context) -> PhotoZoomContainerView {
            let v = PhotoZoomContainerView()
            v.onHideBars = onHideBars
            v.onShowBars = onShowBars
            v.setImage(image, key: imageKey)
            return v
        }

        func updateUIView(_ uiView: PhotoZoomContainerView, context: Context) {
            uiView.onHideBars = onHideBars
            uiView.onShowBars = onShowBars
            uiView.setImage(image, key: imageKey)
        }

        final class PhotoZoomScrollView: UIScrollView, UIGestureRecognizerDelegate {

            /// Return true to allow the scroll view pan gesture to begin.
            /// We use this to let the parent TabView own horizontal paging when the image is at-fit.
            var shouldAllowPan: (() -> Bool)? = nil

            override init(frame: CGRect) {
                super.init(frame: frame)
                // Apple requirement: UIScrollViewPanGestureRecognizer delegate must be the scroll view.
                panGestureRecognizer.delegate = self
            }

            required init?(coder: NSCoder) {
                super.init(coder: coder)
                // Apple requirement: UIScrollViewPanGestureRecognizer delegate must be the scroll view.
                panGestureRecognizer.delegate = self
            }

            override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                if gestureRecognizer === panGestureRecognizer {
                    return shouldAllowPan?() ?? true
                }
                return true
            }
        }

        final class PhotoZoomContainerView: UIView, UIScrollViewDelegate {

            var onHideBars: (() -> Void)? = nil
            var onShowBars: (() -> Void)? = nil
            

            private let scrollView = PhotoZoomScrollView()
            private let imageView = UIImageView()
            private var currentImageKey: String? = nil
            private var needsInitialFit: Bool = true
            private var lastBoundsSize: CGSize = .zero

            private var barsAreHidden: Bool = false
            // True while the user is actively pinching (UIScrollView zoom gesture).
            private var isUserZooming: Bool = false
            // True while we are performing a programmatic zoom animation (double tap).
            // While this is true, we must NOT flip the paging/gesture handshake mid-animation,
            // or certain images (commonly those whose fitScale == 1.0) will “snap” at the end.
            private var isProgrammaticZooming: Bool = false

            // While zooming out to fit, suppress recent TabView/page swipes from affecting layout.
            // This prevents the adjacent page from flashing during the zoom-out animation.
            private var isZoomingOutToFit: Bool = false
            private var zoomOutBeganAt: CFTimeInterval = 0
            private let zoomOutBlockSeconds: CFTimeInterval = 0.22

            // Stable haptic gating: avoid any incidental feedback during zoom-out settle.
            private var pendingShowBarsAfterZoomOut: Bool = false

            // When we restore bars (header + filmstrip), SwiftUI can trigger a layout transaction
            // that briefly lets the TabView show an adjacent page snapshot. Suppress handshake churn
            // during that restore window.
            private var isRestoringBars: Bool = false
            private var restoreBarsBeganAt: CFTimeInterval = 0
            private let restoreBarsBlockSeconds: CFTimeInterval = 0.18

           

            override init(frame: CGRect) {
                super.init(frame: frame)
                commonInit()
            }

            required init?(coder: NSCoder) {
                super.init(coder: coder)
                commonInit()
            }

            private func commonInit() {
                backgroundColor = .black

                scrollView.backgroundColor = .black
                scrollView.showsHorizontalScrollIndicator = false
                scrollView.showsVerticalScrollIndicator = false
                scrollView.bouncesZoom = true
                scrollView.decelerationRate = .fast
                scrollView.delegate = self
                scrollView.alwaysBounceVertical = false
                scrollView.alwaysBounceHorizontal = false

                imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = .clear
                imageView.isUserInteractionEnabled = true

                addSubview(scrollView)
                scrollView.addSubview(imageView)

                let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
                doubleTap.numberOfTapsRequired = 2
                scrollView.addGestureRecognizer(doubleTap)
            }
            private func updatePagingHandshake() {
                let now = CACurrentMediaTime()

                // During programmatic zoom-out and immediately after bar restoration, do NOT let TabView
                // see a 1-finger horizontal gesture. We temporarily let the scroll view "own" the pan
                // (even at-fit) so TabView cannot peek the neighbor page for a frame.
                var blockPaging = false

                if isZoomingOutToFit {
                    let elapsed = now - zoomOutBeganAt
                    if elapsed < zoomOutBlockSeconds {
                        blockPaging = true
                    } else {
                        isZoomingOutToFit = false
                    }
                }

                if isRestoringBars {
                    let elapsed = now - restoreBarsBeganAt
                    if elapsed < restoreBarsBlockSeconds {
                        blockPaging = true
                    } else {
                        isRestoringBars = false
                    }
                }

                let tol: CGFloat = 0.03
                let atFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) <= tol

                // Always keep the scroll view enabled for pinch + double tap.
                scrollView.panGestureRecognizer.isEnabled = true
                scrollView.isScrollEnabled = true

                // Gesture ownership:
                // - Normal state at-fit: require 2 fingers so a 1-finger swipe pages the TabView.
                // - While blockPaging at-fit: require only 1 finger so the scroll view captures the gesture
                //   and TabView cannot page/peek during zoom-out or bar restore transactions.
                if atFit {
                    scrollView.panGestureRecognizer.minimumNumberOfTouches = blockPaging ? 1 : 2
                } else {
                    scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
                }

                // Bars behavior:
                if atFit {
                    if barsAreHidden {
                        if blockPaging || isProgrammaticZooming || isUserZooming {
                            pendingShowBarsAfterZoomOut = true
                        } else {
                            barsAreHidden = false
                            onShowBars?()
                        }
                    }
                } else {
                    if !barsAreHidden {
                        barsAreHidden = true
                        onHideBars?()
                    }
                }

                // Delegate gate:
                // - Normal at-fit: do not allow 1-finger panning inside the scroll view.
                // - While blockPaging: DO allow it so the scroll view can "eat" the gesture and prevent
                //   TabView from showing the adjacent page.
                let allowAtFitPanDuringBlock = blockPaging
                scrollView.shouldAllowPan = { [weak self] in
                    guard let self else { return true }
                    let tol: CGFloat = 0.03
                    let atFit = abs(self.scrollView.zoomScale - self.scrollView.minimumZoomScale) <= tol
                    if atFit {
                        return allowAtFitPanDuringBlock
                    }
                    return true
                }
            }

            func setImage(_ image: UIImage, key: String) {
                if currentImageKey != key {
                    currentImageKey = key

                    // Hard reset state for a new asset.
                    // IMPORTANT: do NOT set zoomScale to minimumZoomScale here because minimumZoomScale
                    // is not valid until we have bounds and compute fitScale in layoutSubviews.
                    needsInitialFit = true
                    barsAreHidden = false
                    isProgrammaticZooming = false
                    lastBoundsSize = .zero

                    imageView.image = image

                    // Reset to a neutral zoom immediately; layoutSubviews will apply the true fitScale.
                    scrollView.setZoomScale(1.0, animated: false)
                    scrollView.contentOffset = .zero

                    setNeedsLayout()
                } else {
                    // Same key: allow opportunistic -> HQ image swap without resetting zoom.
                    imageView.image = image
                }
            }

            override func layoutSubviews() {
                super.layoutSubviews()

                scrollView.frame = bounds

                let boundsSize = scrollView.bounds.size
                guard boundsSize.width > 1, boundsSize.height > 1 else { return }

                if boundsSize != lastBoundsSize {
                    lastBoundsSize = boundsSize
                    needsInitialFit = true
                }

                guard let img = imageView.image else { return }

                let imageSize = img.size

                // Base (unzoomed) image view size.
                // Do NOT force scrollView.contentSize here.
                // UIScrollView manages contentSize for zooming based on the zoomed view.
                imageView.frame = CGRect(origin: .zero, size: imageSize)

                let scaleW = boundsSize.width / max(imageSize.width, 1)
                let scaleH = boundsSize.height / max(imageSize.height, 1)
                let fitScaleUncapped = min(scaleW, scaleH)
                let fitScale = min(fitScaleUncapped, 1.0)

                scrollView.minimumZoomScale = fitScale
                scrollView.maximumZoomScale = max(fitScale * 6.0, 3.0)

                if needsInitialFit {
                    needsInitialFit = false

                    // Apply true fit now that minimumZoomScale is valid.
                    scrollView.setZoomScale(fitScale, animated: false)
                    scrollView.contentOffset = .zero

                    updatePagingHandshake()
                } else {
                    // Clamp into the new range if needed (eg after rotation).
                    if scrollView.zoomScale < scrollView.minimumZoomScale {
                        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                    }
                    if scrollView.zoomScale > scrollView.maximumZoomScale {
                        scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
                    }
                }

                centerImage()
            }

            func viewForZooming(in scrollView: UIScrollView) -> UIView? {
                imageView
            }
            
            func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
                isUserZooming = true
            }
            
            func scrollViewDidZoom(_ scrollView: UIScrollView) {
                centerImage()

                let tol: CGFloat = 0.03
                let atFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) <= tol

                // Hide bars as soon as we leave fit (pinch or programmatic).
                if !atFit {
                    if !barsAreHidden {
                        barsAreHidden = true
                        onHideBars?()
                    }
                    return
                }

                // We are at fit. Do NOT show bars during the zoom gesture or animation.
                // Defer bar restore until zoom ends to prevent TabView neighbor-page peeks.
                if barsAreHidden {
                    if isProgrammaticZooming || isUserZooming {
                        pendingShowBarsAfterZoomOut = true
                    } else {
                        barsAreHidden = false
                        onShowBars?()
                    }
                }
            }

            func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
                // Pinch session ended.
                isUserZooming = false

                // Programmatic zoom animation has finished; it is now safe to update the paging handshake.
                if isProgrammaticZooming {
                    isProgrammaticZooming = false

                    // If we were zooming out to fit, keep suppression briefly to avoid neighbor-page peek.
                    if isZoomingOutToFit {
                        zoomOutBeganAt = CACurrentMediaTime()
                    }
                }

                // If we deferred bar restoration (double tap or pinch back to fit), restore now.
                if pendingShowBarsAfterZoomOut {
                    pendingShowBarsAfterZoomOut = false
                    barsAreHidden = false

                    // Mark a short restore window to prevent TabView neighbor-page peeks
                    // during the SwiftUI overlay transition.
                    isRestoringBars = true
                    restoreBarsBeganAt = CACurrentMediaTime()

                    // Restore bars on the next run loop tick to avoid participating in the zoom transaction.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onShowBars?()
                    }
                }

                // Only update the paging handshake after the zoom transaction and any bar restore tick.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updatePagingHandshake()
                }
            }


            private func centerImage() {
                let boundsSize = scrollView.bounds.size
                let contentSize = imageView.frame.size

                let offsetX = max(0, (boundsSize.width - contentSize.width) * 0.5)
                let offsetY = max(0, (boundsSize.height - contentSize.height) * 0.5)

                imageView.center = CGPoint(
                    x: contentSize.width * 0.5 + offsetX,
                    y: contentSize.height * 0.5 + offsetY
                )
            }

            @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
                let minScale = scrollView.minimumZoomScale
                let maxScale = scrollView.maximumZoomScale

                let isAtMin = abs(scrollView.zoomScale - minScale) < 0.01

                if isAtMin {
                    // Zoom in around the tapped point.
                    let targetScale = min(minScale * 2.5, maxScale)

                    if !barsAreHidden {
                        barsAreHidden = true
                        onHideBars?()
                    }

                    let point = gr.location(in: imageView)

                    let w = scrollView.bounds.size.width / targetScale
                    let h = scrollView.bounds.size.height / targetScale
                    let x = point.x - (w * 0.5)
                    let y = point.y - (h * 0.5)

                    // Mark that we are starting a programmatic zoom animation.
                    isProgrammaticZooming = true
                    scrollView.zoom(to: CGRect(x: x, y: y, width: w, height: h), animated: true)
                } else {
                    // Mark that we are starting a programmatic zoom animation.
                    isProgrammaticZooming = true

                    // We are zooming out to fit. Suppress gesture-handshake churn briefly so TabView
                    // never peeks the adjacent page (the "second-to-last flashes" symptom).
                    isZoomingOutToFit = true
                    zoomOutBeganAt = CACurrentMediaTime()
                    pendingShowBarsAfterZoomOut = true

                    // Zooming out: use setZoomScale so it animates smoothly even when minScale == 1.0
                    scrollView.setZoomScale(minScale, animated: true)
                }
            }
        }
    }
}

// MARK: - Detail Types Model (persisted per mode)

private final class DetailTypesModel: ObservableObject {

    struct DetailTypeItem: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var name: String
    }

    @Published var interiorTypes: [DetailTypeItem] = []
    @Published var exteriorTypes: [DetailTypeItem] = []

    @Published var selectedInterior: String = ""
    @Published var selectedExterior: String = ""

    private let interiorTypesKey = "scout.detailTypes.interior.list.v3"
    private let exteriorTypesKey = "scout.detailTypes.exterior.list.v3"
    private let selectedInteriorKey = "scout.detailTypes.interior.selected.v3"
    private let selectedExteriorKey = "scout.detailTypes.exterior.selected.v3"

    private let legacyInteriorTypesKey = "scout.detailTypes.interior.list.v2"
    private let legacyExteriorTypesKey = "scout.detailTypes.exterior.list.v2"
    private let legacySelectedInteriorKey = "scout.detailTypes.interior.selected.v2"
    private let legacySelectedExteriorKey = "scout.detailTypes.exterior.selected.v2"

    private var pendingPersistInterior: DispatchWorkItem?
    private var pendingPersistExterior: DispatchWorkItem?
    private let persistDebounceSeconds: Double = 0.22

    init() {
        load()
        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func types(for mode: ContentView.LocationMode) -> [DetailTypeItem] {
        mode == .interior ? interiorTypes : exteriorTypes
    }

    func selected(for mode: ContentView.LocationMode) -> String {
        mode == .interior ? selectedInterior : selectedExterior
    }

    func setSelected(_ value: String, for mode: ContentView.LocationMode) {
        if mode == .interior { selectedInterior = value } else { selectedExterior = value }
        persistSelected()
    }

    @discardableResult
    func insertBlankItem(for mode: ContentView.LocationMode) -> UUID {
        let newItem = DetailTypeItem(name: "")
        if mode == .interior {
            interiorTypes.append(newItem)
            persistAll()
            return newItem.id
        } else {
            exteriorTypes.append(newItem)
            persistAll()
            return newItem.id
        }
    }

    func updateItem(_ value: String, id: UUID, for mode: ContentView.LocationMode) {
        let cleaned = value.trimmingCharacters(in: .newlines)

        if mode == .interior {
            guard let idx = interiorTypes.firstIndex(where: { $0.id == id }) else { return }
            interiorTypes[idx].name = cleaned
        } else {
            guard let idx = exteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            exteriorTypes[idx].name = cleaned
        }

        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func delete(at offsets: IndexSet, for mode: ContentView.LocationMode) {
        if mode == .interior {
            let deleting = offsets.compactMap { interiorTypes.indices.contains($0) ? interiorTypes[$0].name : nil }
            interiorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedInterior) { selectedInterior = interiorTypes.first?.name ?? "" }
        } else {
            let deleting = offsets.compactMap { exteriorTypes.indices.contains($0) ? exteriorTypes[$0].name : nil }
            exteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedExterior) { selectedExterior = exteriorTypes.first?.name ?? "" }
        }
        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func move(from source: IndexSet, to destination: Int, for mode: ContentView.LocationMode) {
        if mode == .interior {
            interiorTypes.move(fromOffsets: source, toOffset: destination)
            schedulePersist(for: .interior)
        } else {
            exteriorTypes.move(fromOffsets: source, toOffset: destination)
            schedulePersist(for: .exterior)
        }
    }

    private func schedulePersist(for mode: ContentView.LocationMode) {
        if mode == .interior {
            pendingPersistInterior?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.normalizeDefaultsIfNeeded()
                self.persistAll()
            }
            pendingPersistInterior = work
            DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
        } else {
            pendingPersistExterior?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.normalizeDefaultsIfNeeded()
                self.persistAll()
            }
            pendingPersistExterior = work
            DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
        }
    }

    private func load() {
        interiorTypes = loadItems(key: interiorTypesKey, legacyStringKey: legacyInteriorTypesKey)
        exteriorTypes = loadItems(key: exteriorTypesKey, legacyStringKey: legacyExteriorTypesKey)

        selectedInterior = UserDefaults.standard.string(forKey: selectedInteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedInteriorKey)
            ?? ""

        selectedExterior = UserDefaults.standard.string(forKey: selectedExteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedExteriorKey)
            ?? ""
    }

    private func persistAll() {
        saveItems(interiorTypes, key: interiorTypesKey)
        saveItems(exteriorTypes, key: exteriorTypesKey)
        persistSelected()
    }

    private func persistSelected() {
        UserDefaults.standard.set(selectedInterior, forKey: selectedInteriorKey)
        UserDefaults.standard.set(selectedExterior, forKey: selectedExteriorKey)
    }

    private func normalizeDefaultsIfNeeded() {
        let defaultInteriorTypes: [String] = [
            "Main Lobby",
            "Office Space",
            "Common Areas",
            "Restrooms",
            "Mechanical or Utility Rooms"
        ]

        let defaultExteriorTypes: [String] = [
            "General Elevation",
            "Window Detail",
            "Cladding Transition",
            "Entry Detail",
            "Roofline Detail"
        ]

        if interiorTypes.isEmpty { interiorTypes = defaultInteriorTypes.map { DetailTypeItem(name: $0) } }
        if exteriorTypes.isEmpty { exteriorTypes = defaultExteriorTypes.map { DetailTypeItem(name: $0) } }

        if selectedInterior.isEmpty { selectedInterior = firstNonEmpty(from: interiorTypes) ?? (interiorTypes.first?.name ?? "") }
        if selectedExterior.isEmpty { selectedExterior = firstNonEmpty(from: exteriorTypes) ?? (exteriorTypes.first?.name ?? "") }

        if !interiorTypes.contains(where: { $0.name == selectedInterior }) { selectedInterior = firstNonEmpty(from: interiorTypes) ?? (interiorTypes.first?.name ?? "") }
        if !exteriorTypes.contains(where: { $0.name == selectedExterior }) { selectedExterior = firstNonEmpty(from: exteriorTypes) ?? (exteriorTypes.first?.name ?? "") }
    }

    private func firstNonEmpty(from list: [DetailTypeItem]) -> String? {
        list.first(where: { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.name
    }

    private func loadItems(key: String, legacyStringKey: String) -> [DetailTypeItem] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DetailTypeItem].self, from: data) {
            return decoded
        }

        if let legacyData = UserDefaults.standard.data(forKey: legacyStringKey),
           let decodedStrings = try? JSONDecoder().decode([String].self, from: legacyData) {
            return decodedStrings.map { DetailTypeItem(name: $0) }
        }

        return []
    }

    private func saveItems(_ items: [DetailTypeItem], key: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    private let localStore = LocalStore()
    let onExitToHub: (() -> Void)?
    
    private let shutterHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let quickButtonHaptic = UIImpactFeedbackGenerator(style: .light)
    private let hdButtonHaptic = UIImpactFeedbackGenerator(style: .soft)
    
    @StateObject private var camera: CameraManager
    @StateObject private var levelModel = LevelMotionModel()
    @StateObject private var detailTypesModel = DetailTypesModel()
    @StateObject private var locationManager = LocationManager()
    
    @StateObject private var reportLibrary = ReportLibraryModel()
    @StateObject private var imageCache = AssetImageCache()
    
    @State private var elevation: String = "North"
    
    @State private var detailNote: String = ""
    @State private var showNotSavedToast: Bool = false
    @State private var notSavedToastReason: String = "Write"
    @State private var showNoFlaggedIssuesToast: Bool = false
    @State private var showResolutionModeToast: Bool = false
    @State private var showFlaggedActionToast: Bool = false
    @State private var flaggedActionToastText: String = ""
    @State private var flaggedActionToastToken: Int = 0
    @State private var isArmedIssueDetailNoteReadOnly: Bool = false
    
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusRing: Bool = false
    
    @State private var showDetailTypeSheet: Bool = false
    @State var locationMode: LocationMode = .exterior
    
    @State private var showQuickMenu: Bool = false
    @State private var manageContext: ManageContext? = nil
    @State private var showManageBuildingsSheet: Bool = false
    @State private var buildingOptions: [String] = ["B1", "B2", "B3", "B4", "B5", "Add"]
    @State private var selectedBuilding: String = "B1"
    @State private var showActiveIssuesSheet: Bool = false
    @State private var activeObservations: [Observation] = []
    @State private var activeSessionShotIDs: Set<UUID> = []
    @State private var carryoverIssueBadgeCount: Int = 0
    @State private var flaggedPendingCaptureCount: Int = 0
    @State private var guidedReferenceKeys: Set<String> = []
    @State private var flaggedReferenceIDs: Set<UUID> = []
    @State private var guidedUpdatedKeysThisSession: Set<String> = []
    @State private var flaggedUpdatedIDsThisSession: Set<UUID> = []
    @State private var showGuidedChecklist: Bool = false
    @State private var guidedShots: [GuidedShot] = []
    @State private var guidedResolvedThumbnailPathByID: [UUID: String] = [:]
    @State private var guidedReferencePathByID: [UUID: String] = [:]
    @State private var flaggedResolvedThumbnailPathByID: [UUID: String] = [:]
    @State private var flaggedReferencePathByID: [UUID: String] = [:]
    @State private var guidedThumbnailRefreshToken: UUID = UUID()
    @State private var gridThumbnailRefreshToken: UUID = UUID()
    @State private var armedGuidedShotID: UUID? = nil
    @State private var armedGuidedRetakeShotID: UUID? = nil
    @State private var retakeContext: RetakeContext? = nil
    @State private var guidedReferenceAssetLocalID: String? = nil
    @State private var guidedReferenceThumbnail: UIImage? = nil
    @State private var showGuidedAlignmentOverlay: Bool = false
    @State private var referenceOverlayOpacity: Double = 0.45
    @State private var armedUpdateObservationID: UUID? = nil
    @State private var armedIssueNoteText: String = ""
    @State private var armedIssueRevisedObservationText: String? = nil
    @State private var showArmedReferenceMenu: Bool = false
    @State private var armedReferenceViewerState: ArmedReferenceViewerState? = nil
    @State private var flaggedActionTargetObservation: Observation? = nil
    @State private var pendingFlaggedDecisionShot: Shot? = nil
    @State private var pendingFlaggedDecisionPhotoRef: String? = nil
    @State private var showFlaggedActionPrimaryChoice: Bool = false
    @State private var showFlaggedUpdateCommentChoice: Bool = false
    @State private var showFlaggedUpdatedObservationInput: Bool = false
    @State private var draftUpdatedObservation: String = ""
    @State private var resolutionTargetObservation: Observation? = nil
    @State private var resolutionCapturedShot: Shot? = nil
    @State private var resolutionCapturedPhotoRef: String? = nil
    @State private var resolutionCapturedImage: UIImage? = nil
    
    // Custom centered overlays for rotated dropdowns (used in landscape-with-portrait-lock UI)
    @State private var showLandscapeBuildingMenu: Bool = false
    @State private var showLandscapeElevationMenu: Bool = false
    @State private var showLandscapeDetailMenu: Bool = false
    
    @State private var lensToastText: String = ""
    @State private var showLensToast: Bool = false
    @State private var lensToastToken: Int = 0
    
    @State private var showGrid: Bool = false
    @State private var showLevel: Bool = false

    private let buildingOptionsDefaultsKey = "scout.capture.building.options.v1"

    @State private var currentCaptureIntent: CaptureIntent = .free

    private enum CaptureIntent {
        case guided(UUID)
        case flagged(UUID)
        case retake(UUID)
        case free
    }

    init(cameraManager: CameraManager = .shared, onExitToHub: (() -> Void)? = nil) {
        _camera = StateObject(wrappedValue: cameraManager)
        self.onExitToHub = onExitToHub
    }
    
    @State private var showHDEnabledToast: Bool = false
    @State private var hdEnabledToastText: String = "HD Enabled"
    @State private var hdEnabledToastToken: Int = 0
    
    // MARK: - Debug overlay
    
    @State private var debugEnabled: Bool = UserDefaults.standard.bool(forKey: "scout.debug.enabled.v1")
    
    private func setDebugEnabled(_ enabled: Bool) {
        debugEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "scout.debug.enabled.v1")
    }
    
    @State private var showDetailOverlay: Bool = false
    @State private var draftDetailNote: String = ""
    
    @State private var showLibraryFullscreen: Bool = false
    @State private var showSessionActionsSheet: Bool = false
    @State private var sessionActionsSummary: SessionActionsSummary? = nil
    @State private var isPreparingSessionExport: Bool = false
    @State private var pendingCaptureSaveCount: Int = 0
    @State private var deferredSessionActionsRequest: Bool = false
    @State private var sessionExportChecklist = ExportChecklistState()
    @State private var sessionExportFile: SessionExportFile? = nil
    @State private var awaitingSessionExportDismiss: Bool = false
    @State private var showSessionExportErrorPopup: Bool = false
    @State private var sessionExportErrorMessage: String? = nil
    @State private var didTriggerExitToHubForMissingSession: Bool = false

    private var headerPropertyName: String {
        let trimmed = appState.selectedProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No Property Selected" : trimmed
    }

    private var hasValidCurrentSession: Bool {
        guard let session = appState.currentSession else { return false }
        guard let selectedPropertyID = appState.selectedPropertyID else { return false }
        return session.propertyID == selectedPropertyID
    }

    private var shouldShowStartingCameraOverlay: Bool {
        guard hasValidCurrentSession else { return false }
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        guard auth == .authorized else { return false }
        return camera.isStartingPreview || !camera.isPreviewRunning
    }

    private var hasGuidedBaselineForSelectedProperty: Bool {
        let propertyID = appState.selectedPropertyID ?? appState.currentSession?.propertyID
        guard let propertyID else { return false }
        return persistedBaselineState(propertyID: propertyID).hasBaseline
    }

    private var shouldAllowChecklistReferenceFallback: Bool {
        hasGuidedBaselineForSelectedProperty
    }

    private var isCurrentSessionBaselineFromPersisted: Bool {
        guard let propertyID = appState.selectedPropertyID ?? appState.currentSession?.propertyID else { return false }
        guard let sessionID = appState.currentSession?.id else { return false }
        return persistedBaselineState(propertyID: propertyID).baselineSessionID == sessionID
    }

    private var guidedRemainingForCompass: Int {
        guard hasGuidedBaselineForSelectedProperty else { return 0 }
        guard !isCurrentSessionBaselineFromPersisted else { return 0 }
        let remaining = max(0, guidedReferenceKeys.subtracting(guidedUpdatedKeysThisSession).count)
        return remaining
    }

    private var shouldShowGuidedCompassBadge: Bool {
        guidedRemainingForCompass > 0
    }

    private func persistedBaselineState(propertyID: UUID) -> (baselineSessionID: UUID?, hasBaseline: Bool) {
        let persistedProperty = (try? localStore.fetchProperties().first(where: { $0.id == propertyID }))
        var baselineSessionID = persistedProperty?.baselineSessionID
        if baselineSessionID == nil {
            let sessions = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
            let inferred = sessions
                .filter { $0.status == .completed }
                .sorted { $0.startedAt < $1.startedAt }
                .first
            baselineSessionID = inferred?.id
        }
        let hasBaseline = baselineSessionID != nil
        return (baselineSessionID, hasBaseline)
    }

    private func guidedSessionCountSnapshot() -> (total: Int, captured: Int, remaining: Int) {
        let total = guidedShots.count
        let captured = guidedShots.reduce(into: 0) { partial, guidedShot in
            if isGuidedShotSkippedInCurrentSession(guidedShot) {
                return
            }
            if isShotCapturedInCurrentSession(guidedShot.shot) {
                partial += 1
            }
        }
        let skipped = guidedShots.filter { isGuidedShotSkippedInCurrentSession($0) }.count
        let remaining = max(0, total - captured - skipped)
        return (total, captured, remaining)
    }

    private var captureIntentDebugLabel: String {
        switch currentCaptureIntent {
        case .guided:
            return "guided"
        case .flagged:
            return "flagged"
        case .retake:
            return "retake"
        case .free:
            return "free"
        }
    }

    private var isDetailNoteEnabledForCapture: Bool {
        !detailNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func guidedKey(for guidedShot: GuidedShot) -> String {
        ShotMetadata.makeShotKey(
            building: guidedShot.building ?? "",
            elevation: guidedShot.targetElevation ?? "",
            detailType: guidedShot.detailType ?? "",
            angleIndex: max(1, guidedShot.angleIndex ?? 1)
        )
    }

    private func refreshReferenceSetsAndPendingCounts() {
        guard let propertyID = appState.selectedPropertyID,
              let currentSession = appState.currentSession else {
            guidedReferenceKeys = []
            flaggedReferenceIDs = []
            guidedUpdatedKeysThisSession = []
            flaggedUpdatedIDsThisSession = []
            flaggedPendingCaptureCount = 0
            print("[ReferenceSet] sessionID=NONE guidedRefCount=0 flaggedRefCount=0")
            print("[PendingUpdate] intent=\(captureIntentDebugLabel) guidedUpdated=0 flaggedUpdated=0")
            print("[BadgeCompute] guidedRemaining=0 flaggedRemaining=0")
            return
        }

        if persistedBaselineState(propertyID: propertyID).baselineSessionID == currentSession.id {
            guidedReferenceKeys = []
            flaggedReferenceIDs = []
            guidedUpdatedKeysThisSession = []
            flaggedUpdatedIDsThisSession = []
            flaggedPendingCaptureCount = 0
            print("[ReferenceSet] sessionID=\(currentSession.id.uuidString) guidedRefCount=0 flaggedRefCount=0")
            print("[PendingUpdate] intent=\(captureIntentDebugLabel) guidedUpdated=0 flaggedUpdated=0")
            print("[BadgeCompute] guidedRemaining=0 flaggedRemaining=0")
            return
        }

        let baselineState = persistedBaselineState(propertyID: propertyID)
        let orderedSessions = ((try? localStore.fetchSessions(propertyID: propertyID)) ?? []).sorted { $0.startedAt < $1.startedAt }
        let currentSessionMetadata = sessionMetadataForActiveSession(propertyID: propertyID, sessionID: currentSession.id)
        var metadataCache: [UUID: SessionMetadata] = [:]
        metadataCache[currentSession.id] = currentSessionMetadata

        var newGuidedReferenceKeys: Set<String> = []
        for guidedShot in guidedShots {
            let resolved = resolveGuidedRetakeReferenceForDisplay(
                propertyID: propertyID,
                currentSession: currentSession,
                baselineSessionID: baselineState.baselineSessionID,
                guidedShot: guidedShot,
                orderedSessions: orderedSessions,
                metadataCache: &metadataCache
            )
            if resolved.exists {
                newGuidedReferenceKeys.insert(guidedKey(for: guidedShot))
            }
        }

        let newGuidedUpdatedKeys = Set(
            guidedShots.compactMap { guidedShot -> String? in
                let key = guidedKey(for: guidedShot)
                guard newGuidedReferenceKeys.contains(key) else { return nil }
                if isGuidedShotSkippedInCurrentSession(guidedShot) {
                    return key
                }
                guard isShotCapturedInCurrentSession(guidedShot.shot) else { return nil }
                return key
            }
        )

        let allObservations = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
        let newFlaggedReferenceIDs = Set(
            allObservations.compactMap { observation -> UUID? in
                guard observation.createdAt < currentSession.startedAt else { return nil }
                if observation.status == .active || observation.updatedInSessionID == currentSession.id || observation.resolvedInSessionID == currentSession.id {
                    return observation.id
                }
                return nil
            }
        )
        let newFlaggedUpdatedIDs = Set(
            allObservations.compactMap { observation -> UUID? in
                guard newFlaggedReferenceIDs.contains(observation.id) else { return nil }
                if observation.updatedInSessionID == currentSession.id || observation.resolvedInSessionID == currentSession.id {
                    return observation.id
                }
                return nil
            }
        )

        guidedReferenceKeys = newGuidedReferenceKeys
        flaggedReferenceIDs = newFlaggedReferenceIDs
        guidedUpdatedKeysThisSession = newGuidedUpdatedKeys
        flaggedUpdatedIDsThisSession = newFlaggedUpdatedIDs
        flaggedPendingCaptureCount = max(0, newFlaggedReferenceIDs.subtracting(newFlaggedUpdatedIDs).count)

        print("[ReferenceSet] sessionID=\(currentSession.id.uuidString) guidedRefCount=\(guidedReferenceKeys.count) flaggedRefCount=\(flaggedReferenceIDs.count)")
        print("[PendingUpdate] intent=\(captureIntentDebugLabel) guidedUpdated=\(guidedUpdatedKeysThisSession.count) flaggedUpdated=\(flaggedUpdatedIDsThisSession.count)")
        print("[BadgeCompute] guidedRemaining=\(guidedRemainingForCompass) flaggedRemaining=\(flaggedPendingCaptureCount)")
    }

    private func shotMetadata(_ shot: ShotMetadata, matches guidedShot: GuidedShot, guidedKey: String) -> Bool {
        guard shot.isGuided else { return false }
        if shot.shotKey.caseInsensitiveCompare(guidedKey) == .orderedSame {
            return true
        }
        let guidedBuilding = (guidedShot.building ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let guidedElevation = CanonicalElevation.normalize(guidedShot.targetElevation) ?? (guidedShot.targetElevation ?? "")
        let guidedDetail = (guidedShot.detailType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let guidedAngle = max(1, guidedShot.angleIndex ?? 1)
        return shot.building.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == guidedBuilding &&
            (CanonicalElevation.normalize(shot.elevation) ?? shot.elevation) == guidedElevation &&
            shot.detailType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == guidedDetail &&
            shot.angleIndex == guidedAngle
    }

    private func guidedSnapshot(_ snapshot: GuidedShot, matches guidedShot: GuidedShot, guidedKey targetGuidedKey: String) -> Bool {
        if snapshot.id == guidedShot.id {
            return true
        }
        if guidedKey(for: snapshot).caseInsensitiveCompare(targetGuidedKey) == .orderedSame {
            return true
        }
        let snapshotBuilding = (snapshot.building ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let snapshotElevation = CanonicalElevation.normalize(snapshot.targetElevation) ?? (snapshot.targetElevation ?? "")
        let snapshotDetail = (snapshot.detailType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let snapshotAngle = max(1, snapshot.angleIndex ?? 1)
        let guidedBuilding = (guidedShot.building ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let guidedElevation = CanonicalElevation.normalize(guidedShot.targetElevation) ?? (guidedShot.targetElevation ?? "")
        let guidedDetail = (guidedShot.detailType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let guidedAngle = max(1, guidedShot.angleIndex ?? 1)
        return snapshotBuilding == guidedBuilding &&
            snapshotElevation == guidedElevation &&
            snapshotDetail == guidedDetail &&
            snapshotAngle == guidedAngle
    }

    private func resolvedGuidedSnapshotImagePath(_ guidedShot: GuidedShot) -> String? {
        let candidates = [
            guidedShot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            guidedShot.referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
            guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func metadataForSession(
        propertyID: UUID,
        sessionID: UUID,
        cache: inout [UUID: SessionMetadata]
    ) -> SessionMetadata? {
        if let cached = cache[sessionID] {
            return cached
        }
        guard let loaded = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID) else {
            return nil
        }
        cache[sessionID] = loaded
        return loaded
    }

    private func shotMetadataMatchKind(
        _ shot: ShotMetadata,
        observation: Observation,
        observationShotIDs: Set<UUID>
    ) -> String? {
        if let issueID = shot.issueID, issueID == observation.id {
            return "issueID"
        }
        if observationShotIDs.contains(shot.shotID) {
            return "shotID"
        }
        return nil
    }

    private func resolveFlaggedThumbnailForDisplay(
        propertyID: UUID,
        currentSession: Session?,
        baselineSessionID: UUID?,
        observation: Observation,
        currentSessionMetadata: SessionMetadata?,
        orderedSessions: [Session],
        metadataCache: inout [UUID: SessionMetadata]
    ) -> GuidedSessionThumbnailResolution {
        let currentSessionID = currentSession?.id
        let target = observation.id.uuidString
        let observationShotIDs = Set(observation.shots.map(\.id))

        func mostRecentMatchingShot(
            in metadata: SessionMetadata?
        ) -> (shot: ShotMetadata, matchBy: String)? {
            guard let metadata else { return nil }
            return metadata.shots
                .compactMap { shot -> (ShotMetadata, String)? in
                    guard let matchBy = shotMetadataMatchKind(shot, observation: observation, observationShotIDs: observationShotIDs) else {
                        return nil
                    }
                    return (shot, matchBy)
                }
                .sorted { lhs, rhs in
                    lhs.0.updatedAt > rhs.0.updatedAt
                }
                .first
        }

        if let currentSessionID,
           let currentMatch = mostRecentMatchingShot(in: currentSessionMetadata) {
            let resolved = resolvedSessionImagePath(
                for: currentMatch.shot,
                propertyID: propertyID,
                sessionID: currentSessionID
            )
            if let path = resolved.absolutePath {
                print("[FlagThumbResolve] matchBy=\(currentMatch.matchBy) target=\(target) chosenShotID=\(currentMatch.shot.shotID.uuidString) chosenSession=\(currentSessionID.uuidString) reason=matched source=\(resolved.source) pathExists=true")
                return GuidedSessionThumbnailResolution(source: .current, sessionID: currentSessionID, path: path, exists: true)
            }
        }

        let priorSessions: [Session] = {
            guard let currentSession else { return [] }
            return orderedSessions
                .filter { $0.id != currentSession.id && $0.startedAt < currentSession.startedAt }
                .sorted { $0.startedAt > $1.startedAt }
        }()

        for prior in priorSessions where prior.id != baselineSessionID {
            guard let priorMeta = metadataForSession(propertyID: propertyID, sessionID: prior.id, cache: &metadataCache),
                  let priorMatch = mostRecentMatchingShot(in: priorMeta) else {
                continue
            }
            let resolved = resolvedSessionImagePath(
                for: priorMatch.shot,
                propertyID: propertyID,
                sessionID: prior.id
            )
            if let path = resolved.absolutePath {
                print("[FlagThumbResolve] matchBy=\(priorMatch.matchBy) target=\(target) chosenShotID=\(priorMatch.shot.shotID.uuidString) chosenSession=\(prior.id.uuidString) reason=matched source=\(resolved.source) pathExists=true")
                return GuidedSessionThumbnailResolution(source: .prior, sessionID: prior.id, path: path, exists: true)
            }
        }

        if let baselineSessionID,
           baselineSessionID != currentSessionID,
           let baselineMeta = metadataForSession(propertyID: propertyID, sessionID: baselineSessionID, cache: &metadataCache),
           let baselineMatch = mostRecentMatchingShot(in: baselineMeta) {
            let resolved = resolvedSessionImagePath(
                for: baselineMatch.shot,
                propertyID: propertyID,
                sessionID: baselineSessionID
            )
            if let path = resolved.absolutePath {
                print("[FlagThumbResolve] matchBy=\(baselineMatch.matchBy) target=\(target) chosenShotID=\(baselineMatch.shot.shotID.uuidString) chosenSession=\(baselineSessionID.uuidString) reason=matched source=\(resolved.source) pathExists=true")
                return GuidedSessionThumbnailResolution(source: .baseline, sessionID: baselineSessionID, path: path, exists: true)
            }
        }

        let fallbackReference = observation.shots
            .sorted { $0.capturedAt < $1.capturedAt }
            .first?
            .imageLocalIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallbackReference.isEmpty, FileManager.default.fileExists(atPath: fallbackReference) {
            print("[FlagThumbResolve] matchBy=none target=\(target) chosenShotID=NONE chosenSession=NONE reason=referenceFallback source=reference pathExists=true")
            return GuidedSessionThumbnailResolution(source: .reference, sessionID: nil, path: fallbackReference, exists: true)
        }

        print("[FlagThumbResolve] matchBy=none target=\(target) chosenShotID=NONE chosenSession=NONE reason=noMatch source=none pathExists=false")
        return GuidedSessionThumbnailResolution(source: .none, sessionID: nil, path: nil, exists: false)
    }

    private func resolveGuidedThumbnailForDisplay(
        propertyID: UUID,
        currentSession: Session?,
        baselineSessionID: UUID?,
        guidedShot: GuidedShot,
        currentSessionMetadata: SessionMetadata?,
        orderedSessions: [Session],
        metadataCache: inout [UUID: SessionMetadata]
    ) -> GuidedSessionThumbnailResolution {
        let currentSessionID = currentSession?.id
        let key = guidedKey(for: guidedShot)

        if let currentSessionID,
           let currentShot = guidedShot.shot,
           activeSessionShotIDs.contains(currentShot.id) {
            let directPath = currentShot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !directPath.isEmpty, FileManager.default.fileExists(atPath: directPath) {
                print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID.uuidString) guidedKey=\(key) chosenSource=current chosenSessionID=\(currentSessionID.uuidString) chosenPath=\(directPath) exists=true")
                return GuidedSessionThumbnailResolution(source: .current, sessionID: currentSessionID, path: directPath, exists: true)
            }
        }

        if let currentSessionID,
           let currentSessionMetadata,
           let currentShotID = guidedShot.shot?.id,
           let currentShot = currentSessionMetadata.shots.first(where: { $0.shotID == currentShotID && shotMetadata($0, matches: guidedShot, guidedKey: key) }) {
            let resolved = resolvedSessionImagePath(
                for: currentShot,
                propertyID: propertyID,
                sessionID: currentSessionID
            )
            if let path = resolved.absolutePath {
                print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID.uuidString) guidedKey=\(key) chosenSource=current chosenSessionID=\(currentSessionID.uuidString) chosenPath=\(path) exists=true")
                return GuidedSessionThumbnailResolution(source: .current, sessionID: currentSessionID, path: path, exists: true)
            }
        }

        let priorSessions: [Session] = {
            guard let currentSession else { return [] }
            return orderedSessions
                .filter { $0.id != currentSession.id && $0.startedAt < currentSession.startedAt }
                .sorted { $0.startedAt > $1.startedAt }
        }()

        for prior in priorSessions where prior.id != baselineSessionID {
            guard let priorMeta = metadataForSession(propertyID: propertyID, sessionID: prior.id, cache: &metadataCache) else {
                continue
            }
            if let priorGuidedSnapshot = priorMeta.guidedShots.first(where: { guidedSnapshot($0, matches: guidedShot, guidedKey: key) }),
               let path = resolvedGuidedSnapshotImagePath(priorGuidedSnapshot) {
                print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID?.uuidString ?? "NONE") guidedKey=\(key) chosenSource=prior chosenSessionID=\(prior.id.uuidString) chosenPath=\(path) exists=true")
                return GuidedSessionThumbnailResolution(source: .prior, sessionID: prior.id, path: path, exists: true)
            }
            if let priorShot = priorMeta.shots.first(where: { shotMetadata($0, matches: guidedShot, guidedKey: key) }) {
                let resolved = resolvedSessionImagePath(
                    for: priorShot,
                    propertyID: propertyID,
                    sessionID: prior.id
                )
                if let path = resolved.absolutePath {
                    print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID?.uuidString ?? "NONE") guidedKey=\(key) chosenSource=prior chosenSessionID=\(prior.id.uuidString) chosenPath=\(path) exists=true")
                    return GuidedSessionThumbnailResolution(source: .prior, sessionID: prior.id, path: path, exists: true)
                }
            }
        }

        let fallbackReference = [
            guidedShot.referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        .first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) })

        if let fallbackReference {
            print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID?.uuidString ?? "NONE") guidedKey=\(key) chosenSource=reference chosenSessionID=NONE chosenPath=\(fallbackReference) exists=true")
            return GuidedSessionThumbnailResolution(source: .reference, sessionID: nil, path: fallbackReference, exists: true)
        }

        if let baselineSessionID,
           let baselineMeta = metadataForSession(propertyID: propertyID, sessionID: baselineSessionID, cache: &metadataCache) {
            if let baselineGuidedSnapshot = baselineMeta.guidedShots.first(where: { guidedSnapshot($0, matches: guidedShot, guidedKey: key) }),
               let path = resolvedGuidedSnapshotImagePath(baselineGuidedSnapshot) {
                print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID?.uuidString ?? "NONE") guidedKey=\(key) chosenSource=baseline chosenSessionID=\(baselineSessionID.uuidString) chosenPath=\(path) exists=true")
                return GuidedSessionThumbnailResolution(source: .baseline, sessionID: baselineSessionID, path: path, exists: true)
            }
            if let baselineShot = baselineMeta.shots.first(where: { shotMetadata($0, matches: guidedShot, guidedKey: key) }) {
                let resolved = resolvedSessionImagePath(
                    for: baselineShot,
                    propertyID: propertyID,
                    sessionID: baselineSessionID
                )
                if let path = resolved.absolutePath {
                    print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID?.uuidString ?? "NONE") guidedKey=\(key) chosenSource=baseline chosenSessionID=\(baselineSessionID.uuidString) chosenPath=\(path) exists=true")
                    return GuidedSessionThumbnailResolution(source: .baseline, sessionID: baselineSessionID, path: path, exists: true)
                }
            }
        }

        print("[GuidedThumbResolve] propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID?.uuidString ?? "NONE") guidedKey=\(key) chosenSource=none chosenSessionID=NONE chosenPath=NONE exists=false")
        return GuidedSessionThumbnailResolution(source: .none, sessionID: nil, path: nil, exists: false)
    }

    private func resolveFlaggedReferencePathForDisplay(
        propertyID: UUID,
        observation: Observation,
        currentSession: Session?,
        baselineSessionID: UUID?
    ) -> String? {
        let orderedSessions = ((try? localStore.fetchSessions(propertyID: propertyID)) ?? []).sorted { $0.startedAt < $1.startedAt }
        let currentSessionMetadata = sessionMetadataForActiveSession(propertyID: propertyID, sessionID: currentSession?.id)
        var metadataCache: [UUID: SessionMetadata] = [:]
        if let currentSessionMetadata, let currentSessionID = currentSession?.id {
            metadataCache[currentSessionID] = currentSessionMetadata
        }

        let currentSessionID = currentSession?.id
        let observationShotIDs = Set(observation.shots.map(\.id))

        func mostRecentMatchingShot(
            in metadata: SessionMetadata?
        ) -> ShotMetadata? {
            guard let metadata else { return nil }
            return metadata.shots
                .compactMap { shot -> ShotMetadata? in
                    guard shotMetadataMatchKind(shot, observation: observation, observationShotIDs: observationShotIDs) != nil else {
                        return nil
                    }
                    return shot
                }
                .sorted { lhs, rhs in
                    lhs.updatedAt > rhs.updatedAt
                }
                .first
        }

        let priorSessions: [Session] = {
            guard let currentSession else { return [] }
            return orderedSessions
                .filter { $0.id != currentSession.id && $0.startedAt < currentSession.startedAt }
                .sorted { $0.startedAt > $1.startedAt }
        }()

        for prior in priorSessions where prior.id != baselineSessionID {
            guard let priorMeta = metadataForSession(propertyID: propertyID, sessionID: prior.id, cache: &metadataCache),
                  let priorMatch = mostRecentMatchingShot(in: priorMeta) else {
                continue
            }
            let resolved = resolvedSessionImagePath(
                for: priorMatch,
                propertyID: propertyID,
                sessionID: prior.id
            )
            if let path = resolved.absolutePath {
                return path
            }
        }

        if let baselineSessionID,
           baselineSessionID != currentSessionID,
           let baselineMeta = metadataForSession(propertyID: propertyID, sessionID: baselineSessionID, cache: &metadataCache),
           let baselineMatch = mostRecentMatchingShot(in: baselineMeta) {
            let resolved = resolvedSessionImagePath(
                for: baselineMatch,
                propertyID: propertyID,
                sessionID: baselineSessionID
            )
            if let path = resolved.absolutePath {
                return path
            }
        }

        let fallbackReference = observation.shots
            .filter { shot in
                guard let currentSessionID else { return true }
                guard observation.updatedInSessionID == currentSessionID || observation.resolvedInSessionID == currentSessionID else {
                    return true
                }
                return !activeSessionShotIDs.contains(shot.id)
            }
            .sorted { $0.capturedAt < $1.capturedAt }
            .first?
            .imageLocalIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallbackReference.isEmpty, FileManager.default.fileExists(atPath: fallbackReference) {
            return fallbackReference
        }

        return nil
    }

    private func resolveGuidedRetakeReferenceForDisplay(
        propertyID: UUID,
        currentSession: Session?,
        baselineSessionID: UUID?,
        guidedShot: GuidedShot,
        orderedSessions: [Session],
        metadataCache: inout [UUID: SessionMetadata]
    ) -> GuidedSessionThumbnailResolution {
        let currentSessionID = currentSession?.id
        let key = guidedKey(for: guidedShot)

        let priorSessions: [Session] = {
            guard let currentSession else { return [] }
            return orderedSessions
                .filter { $0.id != currentSession.id && $0.startedAt < currentSession.startedAt }
                .sorted { $0.startedAt > $1.startedAt }
        }()

        for prior in priorSessions where prior.id != baselineSessionID {
            guard let priorMeta = metadataForSession(propertyID: propertyID, sessionID: prior.id, cache: &metadataCache) else {
                continue
            }
            if let priorGuidedSnapshot = priorMeta.guidedShots.first(where: { guidedSnapshot($0, matches: guidedShot, guidedKey: key) }),
               let path = resolvedGuidedSnapshotImagePath(priorGuidedSnapshot) {
                return GuidedSessionThumbnailResolution(source: .prior, sessionID: prior.id, path: path, exists: true)
            }
            if let priorShot = priorMeta.shots.first(where: { shotMetadata($0, matches: guidedShot, guidedKey: key) }) {
                let resolved = resolvedSessionImagePath(
                    for: priorShot,
                    propertyID: propertyID,
                    sessionID: prior.id
                )
                if let path = resolved.absolutePath {
                    return GuidedSessionThumbnailResolution(source: .prior, sessionID: prior.id, path: path, exists: true)
                }
            }
        }

        if let baselineSessionID,
           baselineSessionID != currentSessionID,
           let baselineMeta = metadataForSession(propertyID: propertyID, sessionID: baselineSessionID, cache: &metadataCache) {
            if let baselineGuidedSnapshot = baselineMeta.guidedShots.first(where: { guidedSnapshot($0, matches: guidedShot, guidedKey: key) }),
               let path = resolvedGuidedSnapshotImagePath(baselineGuidedSnapshot) {
                return GuidedSessionThumbnailResolution(source: .baseline, sessionID: baselineSessionID, path: path, exists: true)
            }
            if let baselineShot = baselineMeta.shots.first(where: { shotMetadata($0, matches: guidedShot, guidedKey: key) }) {
                let resolved = resolvedSessionImagePath(
                    for: baselineShot,
                    propertyID: propertyID,
                    sessionID: baselineSessionID
                )
                if let path = resolved.absolutePath {
                    return GuidedSessionThumbnailResolution(source: .baseline, sessionID: baselineSessionID, path: path, exists: true)
                }
            }
        }

        let fallbackReference = [
            guidedShot.referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        .first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) })

        if let fallbackReference {
            return GuidedSessionThumbnailResolution(source: .reference, sessionID: nil, path: fallbackReference, exists: true)
        }

        return GuidedSessionThumbnailResolution(source: .none, sessionID: nil, path: nil, exists: false)
    }

    private func resolveGuidedReferencePathForDisplay(
        propertyID: UUID,
        guidedShot: GuidedShot,
        currentSession: Session?,
        baselineSessionID: UUID?
    ) -> String? {
        let orderedSessions = ((try? localStore.fetchSessions(propertyID: propertyID)) ?? []).sorted { $0.startedAt < $1.startedAt }
        var metadataCache: [UUID: SessionMetadata] = [:]
        let resolved = resolveGuidedRetakeReferenceForDisplay(
            propertyID: propertyID,
            currentSession: currentSession,
            baselineSessionID: baselineSessionID,
            guidedShot: guidedShot,
            orderedSessions: orderedSessions,
            metadataCache: &metadataCache
        )
        guard resolved.source != .current else { return nil }
        guard let path = resolved.path, resolved.exists else { return nil }
        return path
    }

    private struct ArmedReferenceViewerState: Identifiable {
        let id = UUID()
        let title: String
        let detailId: String
        let localIdentifier: String
    }

    private enum GuidedThumbSource: String {
        case current
        case prior
        case baseline
        case reference
        case original
        case stamped
        case none
    }

    private struct GuidedThumbResolution {
        let sourceChosen: GuidedThumbSource
        let chosenPath: String?
        let referencePath: String?
        let referenceExists: Bool
        let originalPath: String?
        let originalExists: Bool
        let stampedPath: String?
        let stampedExists: Bool
    }

    private struct GuidedSessionThumbnailResolution {
        let source: GuidedThumbSource
        let sessionID: UUID?
        let path: String?
        let exists: Bool
    }

    private struct RetakeContext {
        let building: String
        let elevation: String
        let detailType: String
        let angleIndex: Int
        let existingShotID: UUID?
        let existingOriginalFilename: String?
    }

    private struct FlaggedHistoryDisplayEvent: Identifiable {
        let id: String
        let title: String
        let timestamp: Date
        let previousReason: String?
        let currentReason: String?
    }

    private var flaggedActionTargetObservationTextForPopup: String? {
        guard let observation = flaggedActionTargetObservation else { return nil }
        return Self.observationCurrentReasonText(observation)
    }

    private static func shortElevationLabel(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("north") { return "N" }
        if lower.contains("south") { return "S" }
        if lower.contains("east") { return "E" }
        if lower.contains("west") { return "W" }
        return raw
    }

    private static func conciseContextLabel(building: String?, elevation: String?, detailType: String?) -> String {
        let buildingPart = (building ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let elevationPart = shortElevationLabel(elevation)
        let detailPart = (detailType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [buildingPart, elevationPart, detailPart]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func observationCurrentReasonText(_ observation: Observation) -> String? {
        Observation.inferredCurrentReason(
            note: observation.currentReason ?? observation.note,
            statement: observation.statement
        )
    }

    private static func formatObservationHistoryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yy h:mm a"
        return formatter.string(from: date)
    }

    private static func observationHistoryEventTitle(_ event: ObservationHistoryEvent) -> String {
        switch event.kind {
        case .created:
            return "Created"
        case .captured:
            return "Captured"
        case .retake:
            return "Retake"
        case .reclassified:
            return "Reclassified"
        case .resolved:
            return "Resolved"
        case .reopened:
            return "Reopened"
        case .reasonUpdated:
            return "Reason Updated"
        case .titleUpdated:
            return "Title Updated"
        }
    }

    private static func observationHistoryEventSummary(_ event: ObservationHistoryEvent) -> String? {
        let before = event.beforeValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let after = event.afterValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !before.isEmpty && !after.isEmpty {
            return "\(before) -> \(after)"
        }
        if !after.isEmpty {
            return after
        }
        if !before.isEmpty {
            return before
        }
        return nil
    }

    private static func observationContextValue(building: String?, elevation: String?, detailType: String?) -> String? {
        let value = conciseContextLabel(building: building, elevation: elevation, detailType: detailType)
        return value.isEmpty ? nil : value
    }

    private func appendObservationHistoryEvent(
        _ event: ObservationHistoryEvent,
        to observation: inout Observation
    ) {
        observation.historyEvents.append(event)
        observation.historyEvents.sort { $0.timestamp < $1.timestamp }
    }

    private func upsertShot(_ shot: Shot, in observation: inout Observation) {
        if let index = observation.shots.firstIndex(where: { $0.id == shot.id }) {
            observation.shots[index] = shot
        } else {
            observation.shots.append(shot)
        }
    }

    private static func normalizedContextFilename(_ filename: String) -> String {
        var output = filename
        let replacements: [(String, String)] = [
            ("North Elevation", "N"),
            ("South Elevation", "S"),
            ("East Elevation", "E"),
            ("West Elevation", "W"),
            ("North", "N"),
            ("South", "S"),
            ("East", "E"),
            ("West", "W")
        ]
        for (source, target) in replacements {
            output = output.replacingOccurrences(of: source, with: target, options: .caseInsensitive)
        }
        output = output.replacingOccurrences(of: "Elevation", with: "", options: .caseInsensitive)
        output = output.replacingOccurrences(of: "__", with: "_")
        output = output.replacingOccurrences(of: "  ", with: " ")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reportAsset(from localIdentifier: String?) -> ReportAsset? {
        let trimmed = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let byPath = reportAsset(fromPath: trimmed) {
            return byPath
        }
        if let resolvedPath = resolveLegacyAssetPath(for: trimmed) {
            return reportAsset(fromPath: resolvedPath)
        }
        return nil
    }

    private static func reportAsset(fromPath path: String) -> ReportAsset? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
        let data = try? Data(contentsOf: url)
        let image = data.flatMap(UIImage.init)
        return ReportAsset(
            localIdentifier: url.path,
            fileURL: url,
            creationDate: created,
            pixelWidth: image.map { Int($0.size.width) } ?? 0,
            pixelHeight: image.map { Int($0.size.height) } ?? 0,
            originalFilename: url.lastPathComponent
        )
    }

    private static func resolveGuidedThumbnail(
        guidedShot: GuidedShot,
        isCapturedInCurrentSession: Bool,
        propertyHasBaseline: Bool
    ) -> GuidedThumbResolution {
        let fm = FileManager.default

        let rawReferencePath = guidedShot.referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawReferenceID = guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let referenceCandidates = [rawReferencePath, rawReferenceID].filter { !$0.isEmpty }
        let firstExistingReference = referenceCandidates.first(where: { fm.fileExists(atPath: $0) })
        let referencePath = firstExistingReference ?? referenceCandidates.first
        let referenceExists = referencePath.map { fm.fileExists(atPath: $0) } ?? false

        let rawShotPath = guidedShot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shotPath = rawShotPath.isEmpty ? nil : rawShotPath
        let shotExt = shotPath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let isStampedPath = shotExt == "jpg" || shotExt == "jpeg"
        let stampedPath = isStampedPath ? shotPath : nil
        let originalPath = isStampedPath ? nil : shotPath
        let stampedExists = stampedPath.map { fm.fileExists(atPath: $0) } ?? false
        let originalExists = originalPath.map { fm.fileExists(atPath: $0) } ?? false

        if isCapturedInCurrentSession {
            if stampedExists {
                return GuidedThumbResolution(
                    sourceChosen: .stamped,
                    chosenPath: stampedPath,
                    referencePath: referencePath,
                    referenceExists: referenceExists,
                    originalPath: originalPath,
                    originalExists: originalExists,
                    stampedPath: stampedPath,
                    stampedExists: stampedExists
                )
            }
            if originalExists {
                return GuidedThumbResolution(
                    sourceChosen: .original,
                    chosenPath: originalPath,
                    referencePath: referencePath,
                    referenceExists: referenceExists,
                    originalPath: originalPath,
                    originalExists: originalExists,
                    stampedPath: stampedPath,
                    stampedExists: stampedExists
                )
            }
        }

        if propertyHasBaseline, referenceExists {
            return GuidedThumbResolution(
                sourceChosen: .reference,
                chosenPath: referencePath,
                referencePath: referencePath,
                referenceExists: referenceExists,
                originalPath: originalPath,
                originalExists: originalExists,
                stampedPath: stampedPath,
                stampedExists: stampedExists
            )
        }

        return GuidedThumbResolution(
            sourceChosen: .none,
            chosenPath: nil,
            referencePath: referencePath,
            referenceExists: referenceExists,
            originalPath: originalPath,
            originalExists: originalExists,
            stampedPath: stampedPath,
            stampedExists: stampedExists
        )
    }

    private static func resolveLegacyAssetPath(for identifier: String) -> String? {
        let fm = FileManager.default
        let needle = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let needleStem = URL(fileURLWithPath: needle).deletingPathExtension().lastPathComponent
        guard !needleStem.isEmpty else { return nil }

        for scoutRoot in StorageRoot.scoutRootCandidates() {
            let propertiesRoot = scoutRoot.appendingPathComponent("Properties", isDirectory: true)
            guard let propertyDirs = try? fm.contentsOfDirectory(at: propertiesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }

            for propertyDir in propertyDirs {
                let sessionsDir = propertyDir.appendingPathComponent("Sessions", isDirectory: true)
                guard let sessionDirs = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                for sessionDir in sessionDirs {
                    let originals = sessionDir.appendingPathComponent("Originals", isDirectory: true)
                    guard let files = try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                        continue
                    }
                    if let match = files.first(where: { file in
                        let name = file.lastPathComponent
                        let stem = file.deletingPathExtension().lastPathComponent
                        return name == needle || stem == needle || stem == needleStem
                    }) {
                        return match.path
                    }
                }
            }
        }
        return nil
    }

    private struct SessionActionsSummary {
        let guidedRemainingCount: Int
        let flaggedRemainingCount: Int
        let hasBaseline: Bool
        let currentSessionCaptureCount: Int
        let isSessionSealed: Bool
        let firstDeliveredAt: Date?
        let reExportExpiresAt: Date?
        let reExportEligibleNow: Bool

        var isCompletionEligible: Bool {
            hasBaseline && guidedRemainingCount == 0 && flaggedRemainingCount == 0
        }

        var hasOutstandingChecklistItems: Bool {
            guidedRemainingCount > 0 || flaggedRemainingCount > 0
        }

        var canSealNow: Bool {
            if hasBaseline { return isCompletionEligible }
            return currentSessionCaptureCount > 0
        }

        var isSealedNotDelivered: Bool {
            isSessionSealed && firstDeliveredAt == nil
        }

        var exportActionTitle: String {
            if isSealedNotDelivered { return "Deliver" }
            if isSessionSealed && firstDeliveredAt != nil {
                return reExportEligibleNow ? "Re-export" : "Re-export Window Expired"
            }
            return "Export"
        }

        var isExportActionEnabled: Bool {
            if hasOutstandingChecklistItems { return false }
            if isSealedNotDelivered { return true }
            if isSessionSealed && firstDeliveredAt != nil {
                return reExportEligibleNow
            }
            return canSealNow
        }

        var isExportLaterEnabled: Bool {
            if hasOutstandingChecklistItems { return false }
            return !isSessionSealed && canSealNow
        }

        var exportDisabledReason: String? {
            if isSessionSealed && firstDeliveredAt != nil && !reExportEligibleNow {
                return "Re export window expired."
            }
            if canSealNow {
                return nil
            }
            if !hasBaseline && currentSessionCaptureCount == 0 {
                return "Export is disabled until at least one photo is captured."
            }
            if !hasBaseline {
                return "Export is disabled until at least one photo is captured."
            }
            return "Export is disabled until all guided and flagged items are complete."
        }
    }

    private struct SessionExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ExportChecklistState {
        var originalsComplete: Bool = false
        var sessionDataComplete: Bool = false
        var zipReady: Bool = false
    }
    
    // MARK: - Physical device rotation for glyphs (UI is locked to portrait)
    
    @State private var lastValidDeviceOrientation: UIDeviceOrientation = .portrait
    @State private var glyphAngleDegrees: Double = 0
    
    // Polling helps rotation start a touch sooner than UIDevice.orientationDidChangeNotification.
    // This is still discrete (0 / +90 / -90) and does NOT introduce continuous motion.
    @State private var isPollingDeviceOrientation: Bool = false
    
    // During certain UI actions (like swapping cameras), device orientation can briefly flicker.
    // This prevents multiple rotation animations.
    
    @State private var isSwappingCamera: Bool = false
    @State private var suppressRotationUpdatesUntil: Date? = nil
    
    // UI-side truth for which camera is active (used for the toast label)
    @State private var isFrontCameraUI: Bool = false
    
    // Simple toast shown above the Quick Menu sheet during camera swap
    @State private var showCameraSwapToast: Bool = false
    @State private var cameraSwapToastText: String = ""
    @State private var cameraSwapToastToken: Int = 0
    @State private var showCameraSwapBlackout: Bool = false
    @State private var displayedZoomSteps: [ZoomStep] = []
    @State private var zoomStepsWorkItem: DispatchWorkItem? = nil
    private let cameraSwapOverlayDuration: Double = 0.72
    
    private let deviceOrientationPoll = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    
    // Discrete rotation like the native Camera app: animate to 0, +90, or -90 and stop.
    // Slightly slower than before.
    private let glyphRotationAnimation = Animation.interactiveSpring(
        response: 0.48,
        dampingFraction: 0.90,
        blendDuration: 0.18
    )
    
    private var bottomGlyphRotationAngle: Angle {
        .degrees(glyphAngleDegrees)
    }
    
    private var isLandscapeUI: Bool {
        lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight
    }

    private var isCaptureTargetArmed: Bool {
        armedGuidedShotID != nil || armedUpdateObservationID != nil
    }

    private func buildingSelectorOverlay() -> some View {
        Button {
            showLandscapeElevationMenu = false
            showLandscapeDetailMenu = false
            showLandscapeBuildingMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selectedBuilding)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                ZStack {
                    Color.black.opacity(0.55)
                    Color.white.opacity(0.08)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCaptureTargetArmed)
    }

    private func elevationPillLabel() -> String {
        if locationMode == .interior { return "Interior" }
        return CanonicalElevation.normalize(elevation) ?? elevation
    }

    private var shouldShowElevationAlignmentDot: Bool {
        guard locationMode != .interior else { return false }
        let normalized = CanonicalElevation.normalize(elevation) ?? elevation
        switch normalized {
        case "North", "South", "East", "West":
            return true
        default:
            return false
        }
    }

    private var isElevationHeadingAligned: Bool {
        guard shouldShowElevationAlignmentDot else { return false }
        guard let rawHeading = locationManager.headingDegrees else { return false }
        let currentHeading = normalizedHeadingForAlignment(rawHeading)
        guard let ideal = idealFacingHeading(for: CanonicalElevation.normalize(elevation) ?? elevation) else { return false }
        // Use contiguous 90-degree sectors so adjacent elevations meet without dead zones.
        return angularDifferenceDegrees(currentHeading, ideal) <= 45
    }

    private func normalizedHeadingForAlignment(_ heading: Double) -> Double {
        // CLLocation heading is based on the device top edge. In landscape UI, compensate
        // so alignment represents the same camera-facing direction as portrait.
        let adjusted: Double
        switch lastValidDeviceOrientation {
        case .landscapeLeft:
            adjusted = heading + 90
        case .landscapeRight:
            adjusted = heading - 90
        case .portraitUpsideDown:
            adjusted = heading + 180
        default:
            adjusted = heading
        }
        let wrapped = adjusted.truncatingRemainder(dividingBy: 360)
        return wrapped >= 0 ? wrapped : wrapped + 360
    }

    private func idealFacingHeading(for normalizedElevation: String) -> Double? {
        switch normalizedElevation {
        case "North":
            return 180
        case "South":
            return 0
        case "East":
            return 270
        case "West":
            return 90
        default:
            return nil
        }
    }

    private func angularDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        let a = lhs.truncatingRemainder(dividingBy: 360)
        let b = rhs.truncatingRemainder(dividingBy: 360)
        let diff = abs(a - b)
        return min(diff, 360 - diff)
    }

    private func buildingCode(from option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let rawCode: String
        if let dashRange = trimmed.range(of: "-") {
            rawCode = String(trimmed[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            rawCode = trimmed
        }

        if rawCode.compare("add", options: .caseInsensitive) == .orderedSame {
            return "Add"
        }
        return rawCode.uppercased()
    }

    private func buildingDisplayName(for option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" - ") {
            return trimmed
        }

        let code = buildingCode(from: trimmed)
        if code == "Add" {
            return "Add - Additional"
        }
        if code.hasPrefix("B") {
            let suffix = code.dropFirst()
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                return "\(code) - Building \(suffix)"
            }
        }
        return code
    }

    private func loadBuildingOptions() {
        guard let data = UserDefaults.standard.data(forKey: buildingOptionsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        let cleaned = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            buildingOptions = cleaned
            let selectedCode = buildingCode(from: selectedBuilding)
            if buildingOptions.contains(where: { buildingCode(from: $0) == selectedCode }) == false {
                selectedBuilding = buildingCode(from: cleaned[0])
            } else {
                selectedBuilding = selectedCode
            }
        }
    }

    private func persistBuildingOptions() {
        let cleaned = buildingOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let final = cleaned.isEmpty ? ["B1", "B2", "B3", "B4", "B5", "Add"] : cleaned
        buildingOptions = final
        let selectedCode = buildingCode(from: selectedBuilding)
        if buildingOptions.contains(where: { buildingCode(from: $0) == selectedCode }) == false {
            selectedBuilding = buildingCode(from: final[0])
        } else {
            selectedBuilding = selectedCode
        }
        if let data = try? JSONEncoder().encode(final) {
            UserDefaults.standard.set(data, forKey: buildingOptionsDefaultsKey)
        }
    }
    
    private func debugOverlayInline() -> some View {
        Group {
            if !debugEnabled {
                EmptyView()
            } else {
                let actualDigits = camera.debugMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let targetClean = camera.debugTargetMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let actualText = actualDigits.isEmpty ? "--" : "\(actualDigits)MP"
                
                let targetCore = targetClean.hasPrefix("T") ? targetClean : ("T" + targetClean)
                let targetText = (targetClean.isEmpty || targetClean == "T--") ? "T--" : "\(targetCore)MP"
                
                HStack(spacing: 6) {
                    Text(actualText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.yellow)
                    
                    Text(targetText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.yellow.opacity(0.80))
                }
            }
        }
    }
    
    private func debugOverlayStacked() -> some View {
        Group {
            if !debugEnabled {
                EmptyView()
            } else {
                let actualDigits = camera.debugMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let targetClean = camera.debugTargetMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let actualText = actualDigits.isEmpty ? "--" : "\(actualDigits)MP"
                
                let targetCore = targetClean.hasPrefix("T") ? targetClean : ("T" + targetClean)
                let targetText = (targetClean.isEmpty || targetClean == "T--") ? "T--" : "\(targetCore)MP"
                
                VStack(spacing: 2) {
                    Text(actualText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.yellow)
                    
                    Text(targetText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.yellow.opacity(0.80))
                }
            }
        }
    }
    
    private func refreshBottomGlyphRotation() {
        if isSwappingCamera {
            return
        }
        if let until = suppressRotationUpdatesUntil, Date() < until {
            return
        }
        
        let o = UIDevice.current.orientation
        
        // Ignore transitional or invalid states.
        let newValue: UIDeviceOrientation? = {
            switch o {
            case .portrait, .portraitUpsideDown:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return o
            default:
                return nil
            }
        }()
        
        
        guard let newValue else { return }
        guard newValue != lastValidDeviceOrientation else { return }
        
        lastValidDeviceOrientation = newValue
        
        // Your spec:
        // Phone rotated to the left -> rotate glyphs 90 degrees to the right (clockwise)
        // Phone rotated to the right -> rotate glyphs 90 degrees to the left (counterclockwise)
        let target: Double
        switch newValue {
        case .landscapeLeft:
            target = 90
        case .landscapeRight:
            target = -90
        default:
            target = 0
        }
        
        withAnimation(glyphRotationAnimation) {
            glyphAngleDegrees = target
        }
    }
    
    // Helper to instantly sync the glyph rotation to the current device orientation, without animation.
    private func syncGlyphRotationWithoutAnimation() {
        let o = UIDevice.current.orientation
        
        // Ignore transitional or invalid states.
        let newValue: UIDeviceOrientation? = {
            switch o {
            case .portrait, .portraitUpsideDown:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return o
            default:
                return nil
            }
        }()
        
        guard let newValue else { return }
        
        let target: Double
        switch newValue {
        case .landscapeLeft:
            target = 90
        case .landscapeRight:
            target = -90
        default:
            target = 0
        }
        
        // Snap without animation.
        var tx = Transaction()
        tx.animation = nil
        withTransaction(tx) {
            lastValidDeviceOrientation = newValue
            glyphAngleDegrees = target
        }
    }
    
    
    private func swapCameraWithRotationFreeze() {
        // Prevent double taps
        if isSwappingCamera {
            return
        }
        
        // Freeze orientation updates long enough for the session reconfigure to settle
        isSwappingCamera = true
        suppressRotationUpdatesUntil = Date().addingTimeInterval(2.2)
        
        // Pause polling to prevent repeated refreshes
        isPollingDeviceOrientation = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            camera.toggleCamera()
            isFrontCameraUI.toggle()
        }
        CATransaction.commit()
        
        // Fixed-duration blackout + toast so behavior is consistent in both directions.
        cameraSwapToastToken += 1
        let toastToken = cameraSwapToastToken
        
        cameraSwapToastText = isFrontCameraUI ? "Front Camera" : "Rear Camera"
        showCameraSwapToast = true
        showCameraSwapBlackout = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + cameraSwapOverlayDuration) {
            guard toastToken == cameraSwapToastToken else { return }
            showCameraSwapToast = false
            showCameraSwapBlackout = false
        }
        
        // After the swap settles, snap to the current stable device orientation WITHOUT animation,
        // then re-enable rotation updates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            let o = UIDevice.current.orientation
            let stable: UIDeviceOrientation? = {
                switch o {
                case .portrait, .portraitUpsideDown:
                    return .portrait
                case .landscapeLeft, .landscapeRight:
                    return o
                default:
                    return nil
                }
            }()
            
            let newValue = stable ?? lastValidDeviceOrientation
            
            // Snap rotation state without animation.
            var tx = Transaction()
            tx.animation = nil
            withTransaction(tx) {
                lastValidDeviceOrientation = newValue
                
                let target: Double
                switch newValue {
                case .landscapeLeft:
                    target = 90
                case .landscapeRight:
                    target = -90
                default:
                    target = 0
                }
                glyphAngleDegrees = target
            }
            
            // Resume polling
            isPollingDeviceOrientation = true
            
            // Clear suppression shortly after we resume
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                suppressRotationUpdatesUntil = nil
                isSwappingCamera = false
            }
        }
    }
    
    enum LocationMode: String, CaseIterable, Identifiable {
        case interior = "Interior"
        case exterior = "Exterior"
        var id: String { rawValue }
    }
    
    fileprivate enum Direction: String, CaseIterable, Identifiable {
        case north = "North"
        case south = "South"
        case east  = "East"
        case west  = "West"
        
        var id: String { rawValue }
        
        var elevationValue: String {
            switch self {
            case .north: return "North"
            case .south: return "South"
            case .east:  return "East"
            case .west:  return "West"
            }
        }
        
        static func fromElevation(_ elevation: String) -> Direction {
            switch CanonicalElevation.normalize(elevation) ?? elevation {
            case "South": return .south
            case "East":  return .east
            case "West":  return .west
            default:      return .north
            }
        }
    }
    
    private struct ManageContext: Identifiable {
        let id = UUID()
        let mode: LocationMode
    }

    private enum ReportEditorMode {
        case editCurrent
        case newReport
    }

    private func showHDToast(_ text: String, duration: Double = 2.0) {
        hdEnabledToastToken += 1
        let token = hdEnabledToastToken
        hdEnabledToastText = text
        showHDEnabledToast = true

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard token == hdEnabledToastToken else { return }
            showHDEnabledToast = false
        }
    }

    private var hasDetailNote: Bool {
        !detailNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var currentDetailType: String {
        detailTypesModel.selected(for: locationMode)
    }

    // MARK: - SwiftUI View conformance
    var body: some View {
        contentBody
    }

    private var contentBody: some View {
        baseContentBody
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // 3-dot quick menu
            .sheet(isPresented: $showQuickMenu) {
                QuickMenuSheet(
                    glyphRotationAngle: bottomGlyphRotationAngle,
                    flashSetting: camera.flashSetting,
                    isFrontCamera: isFrontCameraUI,
                    selectedBuildingLabel: selectedBuilding,
                    isGridOn: $showGrid,
                    isLevelOn: $showLevel,
                    onBuildingList: {
                        showQuickMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            showLandscapeElevationMenu = false
                            showLandscapeDetailMenu = false
                            showManageBuildingsSheet = true
                        }
                    },
                    onInteriorList: {
                        showQuickMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            manageContext = ManageContext(mode: .interior)
                        }
                    },
                    onExteriorList: {
                        showQuickMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            manageContext = ManageContext(mode: .exterior)
                        }
                    },
                    onFlash: { camera.cycleFlash() },
                    onCameraSwap: { swapCameraWithRotationFreeze() }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .onDisappear {
                    showQuickMenu = false
                }
            }
            .sheet(isPresented: $showManageBuildingsSheet, onDismiss: {
                persistBuildingOptions()
            }) {
                ManageBuildingsSheet(
                    options: $buildingOptions,
                    selectedBuilding: $selectedBuilding,
                    buildingCodeForOption: buildingCode(from:),
                    buildingFullLabelForOption: buildingDisplayName(for:),
                    onClose: {
                        showManageBuildingsSheet = false
                    }
                )
            }
            .fullScreenCover(isPresented: $showLibraryFullscreen) {
                ReportLibraryFullscreen(
                    reportLibrary: reportLibrary,
                    cache: imageCache,
                    thumbnailRefreshToken: gridThumbnailRefreshToken,
                    onAfterDelete: {
                        refreshActiveIssues()
                        refreshGuidedShots()
                    }
                )
            }
            .sheet(item: $manageContext) { ctx in
                ManageDetailTypesView(mode: ctx.mode, model: detailTypesModel)
            }
            .fullScreenCover(isPresented: $showActiveIssuesSheet) {
                activeIssuesSheetView
            }
            .fullScreenCover(isPresented: $showGuidedChecklist) {
                guidedChecklistSheetView
            }
            .sheet(item: $sessionExportFile) { file in
                SessionDocumentExportPicker(
                    fileURL: file.url,
                    onComplete: { didExport in
                        if didExport {
                            appState.markCurrentSessionExported()
                        }
                        sessionExportFile = nil
                    }
                )
            }
            .onChange(of: sessionExportFile?.id) { oldValue, newValue in
                guard oldValue != nil, newValue == nil, awaitingSessionExportDismiss else { return }
                awaitingSessionExportDismiss = false
                appState.refreshProperties()
                onExitToHub?()
            }
            .fullScreenCover(item: $armedReferenceViewerState) { state in
                let assets = Self.reportAsset(from: state.localIdentifier).map { [$0] } ?? []
                ReportPhotoViewer(
                    title: state.title,
                    assets: assets,
                    startIndex: 0,
                    detailIdOverride: state.detailId,
                    cache: imageCache,
                    viewerToken: state.localIdentifier.hashValue
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .scoutClearLocalUICache)) { _ in
                handleLocalCacheClearSignal()
            }
    }

    @ViewBuilder
    private var baseContentBody: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { geo in
                layoutContent(in: geo)
            }
            .fullScreenCover(isPresented: $showDetailOverlay) {
                DetailNoteModal(
                    elevation: elevation,
                    detailType: currentDetailType,
                    existingNote: detailNote,
                    onCancel: {
                        showDetailOverlay = false
                    },
                    onSave: { newValue in
                        detailNote = newValue
                        showDetailOverlay = false
                    }
                )
                .presentationBackground(.clear)
            }
            .overlay {
                centeredLandscapeMenuOverlay()
            }
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshBottomGlyphRotation()

                camera.prepareForPreviewAsync()
                camera.ensurePreviewRunningAsync()

                locationManager.start()

                reportLibrary.warmUpAlbumIfAuthorized()
                reportLibrary.setSessionContext(
                    propertyID: appState.selectedPropertyID,
                    sessionID: appState.currentSession?.id
                )
                loadBuildingOptions()
                refreshActiveIssues()
                refreshGuidedShots()
                isPollingDeviceOrientation = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                refreshBottomGlyphRotation()
            }
            .onReceive(deviceOrientationPoll) { _ in
                guard isPollingDeviceOrientation else { return }
                refreshBottomGlyphRotation()
            }
            .onDisappear {
                isPollingDeviceOrientation = false
                locationManager.stop()
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            .onChange(of: appState.selectedPropertyID) { _, _ in
                reportLibrary.setSessionContext(
                    propertyID: appState.selectedPropertyID,
                    sessionID: appState.currentSession?.id
                )
                resetSelectionForSwitch()
                refreshActiveIssues()
                refreshGuidedShots()
            }
            .onChange(of: appState.currentSession?.id) { previousSessionID, nextSessionID in
                reportLibrary.setSessionContext(
                    propertyID: appState.selectedPropertyID,
                    sessionID: appState.currentSession?.id
                )
                let propertyIDText = appState.selectedPropertyID?.uuidString ?? "NONE"
                let baselineActive: Bool = {
                    guard let propertyID = appState.selectedPropertyID,
                          let nextSessionID else { return false }
                    return persistedBaselineState(propertyID: propertyID).baselineSessionID == nextSessionID
                }()
                print(
                    "[SessionSwitch] from=\(previousSessionID?.uuidString ?? "NONE") " +
                    "to=\(nextSessionID?.uuidString ?? "NONE") " +
                    "property=\(propertyIDText) baseline=\(baselineActive)"
                )
                ensureCameraSessionPrecondition()
                if hasValidCurrentSession {
                    camera.ensurePreviewRunningAsync()
                }
                resetSelectionForSwitch()
                refreshActiveIssues()
                refreshGuidedShots()
            }
            .onChange(of: appState.currentSession?.status) { _, _ in
                ensureCameraSessionPrecondition()
                if hasValidCurrentSession {
                    camera.ensurePreviewRunningAsync()
                }
                resetSelectionForSwitch()
                refreshActiveIssues()
            }
            .onChange(of: detailNote) { _, _ in
                camera.updateDetailNoteActive(hasDetailNote)
            }
            .onAppear {
                ensureCameraSessionPrecondition()
                if hasValidCurrentSession {
                    camera.ensurePreviewRunningAsync()
                }
            }

            if showSessionActionsSheet, let summary = sessionActionsSummary {
                SessionActionsSheet(
                    summary: summary,
                    isPreparingExport: isPreparingSessionExport,
                    onResume: {
                        showSessionActionsSheet = false
                    },
                    onSaveDraftAndExit: {
                        handleSaveDraftAndExit(summary: summary)
                    },
                    onExportNow: {
                        startExportNowFlow()
                    },
                    onExportLater: {
                        handleExportLaterAndExit(summary: summary)
                    }
                )
                .zIndex(500)
            }

            if isPreparingSessionExport {
                SessionExportChecklistOverlay(checklist: sessionExportChecklist)
                    .zIndex(700)
            }

            if showSessionExportErrorPopup {
                ExportErrorOverlay(
                    title: "Export Failed",
                    message: sessionExportErrorMessage ?? "Unable to build export ZIP.",
                    retryTitle: "Retry",
                    cancelTitle: "Cancel",
                    onRetry: {
                        showSessionExportErrorPopup = false
                        startExportNowFlow()
                    },
                    onCancel: {
                        showSessionExportErrorPopup = false
                    }
                )
                .zIndex(710)
            }
        }
    }

    private var activeIssuesSheetView: some View {
        ActiveIssuesSheet(
            observations: activeObservations,
            currentSessionID: appState.currentSession?.id,
            sessionShotIDs: activeSessionShotIDs,
            resolvedThumbnailPathByID: flaggedResolvedThumbnailPathByID,
            referencePathByID: flaggedReferencePathByID,
            allowReferenceFallback: shouldAllowChecklistReferenceFallback,
            buildingOptions: $buildingOptions,
            detailTypesModel: detailTypesModel,
            buildingCodeForOption: buildingCode(from:),
            buildingDisplayNameForOption: buildingDisplayName(for:),
            cache: imageCache,
            onRefresh: {
                refreshActiveIssues()
            },
            onSelectIssue: { observation in
                beginFlaggedIssueInteraction(observation)
            },
            onRetakeIssue: { observation in
                armFlaggedRetake(observation)
            },
            onReclassifyIssue: { observation, building, elevation, detailType in
                reclassifyObservation(
                    observation,
                    building: building,
                    elevation: elevation,
                    detailType: detailType
                )
            }
        )
    }

    private var guidedChecklistSheetView: some View {
        GuidedChecklistOverlay(
            guidedShots: guidedShots,
            resolvedThumbnailPathByID: guidedResolvedThumbnailPathByID,
            referencePathByID: guidedReferencePathByID,
            currentSessionID: appState.currentSession?.id,
            currentSessionStartedAt: appState.currentSession?.startedAt,
            currentSessionEndedAt: appState.currentSession?.endedAt,
            isBaselineSession: isCurrentSessionBaselineFromPersisted,
            allowReferenceFallback: shouldAllowChecklistReferenceFallback,
            buildingOptions: $buildingOptions,
            detailTypesModel: detailTypesModel,
            buildingCodeForOption: buildingCode(from:),
            buildingDisplayNameForOption: buildingDisplayName(for:),
            refreshToken: guidedThumbnailRefreshToken,
            cache: imageCache,
            onClose: {
                showGuidedChecklist = false
            },
            onRefresh: {
                refreshGuidedShots()
            },
            onSelectGuided: { guidedShot in
                armGuidedShot(guidedShot)
            },
            onSkip: { guidedShot, reason, otherNote in
                markGuidedShotSkipped(guidedShot, reason: reason, otherNote: otherNote)
            },
            onUndoSkip: { guidedShot in
                undoGuidedShotSkip(guidedShot)
            },
            onRetake: { guidedShot in
                armGuidedRetake(guidedShot)
            },
            onRetire: { guidedShot in
                retireGuidedShot(guidedShot)
            },
            onReclassify: { guidedShot, building, elevation, detailType in
                reclassifyGuidedShot(
                    guidedShot,
                    building: building,
                    elevation: elevation,
                    detailType: detailType
                )
            }
        )
    }

    @ViewBuilder
    private func layoutContent(in geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height

        // Top mask: fixed inset so layout is stable.
        let topInset: CGFloat = 30

        // Fine tune ONLY the internal content position.
        let topContentLift: CGFloat = -22

        // Compact header height.
        let topBarH: CGFloat = topInset + 56

        // Bottom mask should extend fully to the physical bottom of screen.
        let bottomBarH: CGFloat = 178

        let previewH: CGFloat = max(1, h - topBarH - bottomBarH)
        let baseToastTop: CGFloat = 10

        // Type erasure boundary so the compiler does not attempt to build one massive generic type.
        AnyView(
            VStack(spacing: 0) {
                topHeaderView(w: w, topInset: topInset, topContentLift: topContentLift, topBarH: topBarH)
                previewAreaView(w: w, previewH: previewH, baseToastTop: baseToastTop)
                bottomMaskView(bottomBarH: bottomBarH, containerWidth: w)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        )
    }

    private func topHeaderView(w: CGFloat, topInset: CGFloat, topContentLift: CGFloat, topBarH: CGFloat) -> some View {
        ZStack {
            Color.black

            let rowPadding: CGFloat = 16
            let controlH: CGFloat = 44
            let gap: CGFloat = 8
            let titleFontSize: CGFloat = isLandscapeUI ? 25 : 30
            let titleSideInset: CGFloat = isLandscapeUI ? 98 : 108

            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text(headerPropertyName)
                        .font(.system(size: titleFontSize, weight: .medium))
                        .tracking(0.4)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.54)
                        .truncationMode(.tail)
                        .padding(.horizontal, titleSideInset)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .overlay {
                            HStack(spacing: 0) {
                                if isLandscapeUI {
                                    Button {
                                        showLandscapeElevationMenu = false
                                        showLandscapeDetailMenu = false
                                        showLandscapeBuildingMenu.toggle()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(selectedBuilding)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(.white.opacity(0.95))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.85)
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.90))
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(height: controlH, alignment: .center)
                                        .background(
                                            ZStack {
                                                Color.black.opacity(0.55)
                                                Color.white.opacity(0.08)
                                            }
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                        )
                                        .rotationEffect(bottomGlyphRotationAngle)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isCaptureTargetArmed)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.leading, rowPadding)
                                }

                                Spacer(minLength: 0)

                                Button {
                                    presentSessionActionsSheet()
                                } label: {
                                    Group {
                                        if isLandscapeUI {
                                            VStack(spacing: 0) {
                                                Text("End")
                                                Text("Session")
                                            }
                                            .font(.system(size: 14, weight: .semibold))
                                            .multilineTextAlignment(.center)
                                        } else {
                                            Text("End Session")
                                                .font(.system(size: 16, weight: .semibold))
                                        }
                                    }
                                    .foregroundColor(.red.opacity(0.95))
                                    .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                                    .rotationEffect(isLandscapeUI ? bottomGlyphRotationAngle : .zero)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, rowPadding)
                            }
                        }
                }

                if !(lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight) {
                    HStack(spacing: gap) {
                        Button {
                            showLandscapeElevationMenu = false
                            showLandscapeDetailMenu = false
                            showLandscapeBuildingMenu.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedBuilding)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.90))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: controlH, alignment: .center)
                            .background(
                                ZStack {
                                    Color.black.opacity(0.55)
                                    Color.white.opacity(0.08)
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isCaptureTargetArmed)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            showLandscapeBuildingMenu = false
                            if locationMode == .interior {
                                return
                            }
                            showLandscapeDetailMenu = false
                            showLandscapeElevationMenu.toggle()
                        } label: {
                            let elevationLabel = elevationPillLabel()

                            HStack(spacing: 8) {
                                Text(elevationLabel)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)

                                if shouldShowElevationAlignmentDot {
                                    Circle()
                                        .fill(isElevationHeadingAligned ? Color.green : Color.white)
                                        .frame(width: 8, height: 8)
                                        .allowsHitTesting(false)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.90))
                            }
                            .padding(.horizontal, 14)
                            .frame(height: controlH, alignment: .center)
                            .background(
                                ZStack {
                                    Color.black.opacity(0.55)
                                    Color.white.opacity(0.08)
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(locationMode == .interior || isCaptureTargetArmed)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            showLandscapeBuildingMenu = false
                            showLandscapeElevationMenu = false
                            showLandscapeDetailMenu.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Text(currentDetailType.isEmpty ? "Select" : currentDetailType)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.90))
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: controlH, maxHeight: controlH, alignment: .center)
                            .background(
                                ZStack {
                                    Color.black.opacity(0.55)
                                    Color.white.opacity(0.08)
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isCaptureTargetArmed)
                    }
                    .padding(.horizontal, rowPadding)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, topInset)
            .padding(.bottom, 0)
            .padding(.horizontal, 10)
            .offset(y: topContentLift)
        }
        .frame(height: topBarH + (isLandscapeUI ? 0 : 6))
    }

    private func previewAreaView(w: CGFloat, previewH: CGFloat, baseToastTop: CGFloat) -> some View {
        ZStack {
            CameraPreviewView(
                session: camera.session,
                onTapDevicePoint: { devicePoint in
                    camera.focus(atDevicePoint: devicePoint)
                },
                onTapNormalizedPoint: { normalizedPoint in
                    let x = normalizedPoint.x * w
                    let y = normalizedPoint.y * previewH
                    focusPoint = CGPoint(x: x, y: y)
                    showFocusRing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        showFocusRing = false
                    }
                }
            )
            .cameraCaptureButtons(
                onPressBegan: {
                    shutterHaptic.impactOccurred()
                    shutterHaptic.prepare()
                },
                onCapture: {
                    capture()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(width: w, height: previewH)
            .background(Color.black)
            .clipped()
            .compositingGroup()
            .transaction { tx in
                tx.animation = nil
            }

            if showGrid {
                GridOverlay()
                    .stroke(Color.white.opacity(0.44), lineWidth: 1)
                    .frame(width: w, height: previewH)
                    .allowsHitTesting(false)
                    .zIndex(8)
            }

            if shouldShowStartingCameraOverlay {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("Starting camera...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.70))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .transition(.opacity)
                .zIndex(40)
            }

            if showLevel {
                LevelOverlay(
                    rollDegrees: levelModel.rollDegrees,
                    isLevel: levelModel.isLevel
                )
                .rotationEffect(bottomGlyphRotationAngle)
                .allowsHitTesting(false)
                .zIndex(6)
            }

            topLeftPreviewPlaceholders()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: lastValidDeviceOrientation == .landscapeRight ? .topTrailing : .topLeading
                )
                .padding(.top, 14)
                .padding(.leading, lastValidDeviceOrientation == .landscapeRight ? 0 : 14)
                .padding(.trailing, lastValidDeviceOrientation == .landscapeRight ? 14 : 0)
                .zIndex(12)

            if showGuidedAlignmentOverlay && isCaptureTargetArmed {
                if let reference = guidedReferenceThumbnail {
                    Group {
                        if isLandscapeUI {
                            Image(uiImage: reference)
                                .resizable()
                                .scaledToFill()
                                .frame(width: previewH, height: w)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .frame(width: w, height: previewH)
                                .clipped()
                        } else {
                            Image(uiImage: reference)
                                .resizable()
                                .scaledToFill()
                                .frame(width: w, height: previewH)
                                .clipped()
                        }
                    }
                    .opacity(referenceOverlayOpacity)
                    .allowsHitTesting(false)
                    .zIndex(10)
                } else {
                    Text("No reference available")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.62))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .rotationEffect(bottomGlyphRotationAngle)
                        .allowsHitTesting(false)
                        .zIndex(11)
                }
            }

            if showCameraSwapBlackout {
                Color.black
                    .frame(width: w, height: previewH)
                    .allowsHitTesting(false)
                    .zIndex(85)
            }

            if showCameraSwapToast {
                Text(cameraSwapToastText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, max(14, previewH * 0.18))
                    .zIndex(86)
            }

            if (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight) {
                let isLandscapeLeft = (lastValidDeviceOrientation == .landscapeLeft)
                let rotationDegrees: Double = isLandscapeLeft ? 90 : -90
                let alignment: Alignment = isLandscapeLeft ? .topTrailing : .topLeading
                let anchor: UnitPoint = isLandscapeLeft ? .topTrailing : .topLeading

                Color.clear
                    .frame(width: w, height: previewH)
                    .overlay(alignment: alignment) {
                        let xNudge: CGFloat = isLandscapeLeft ? -10 : 10
                        let yNudge: CGFloat = 200

                        landscapeDropdownStack()
                            .rotationEffect(.degrees(rotationDegrees), anchor: anchor)
                            .offset(x: xNudge, y: yNudge)
                            .compositingGroup()
                    }
                    .zIndex(80)
            }

            if showHDEnabledToast {
                Text(hdEnabledToastText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(26)
            }

            if hasDetailNote &&
                armedUpdateObservationID == nil &&
                !showFlaggedActionPrimaryChoice &&
                !showFlaggedUpdateCommentChoice &&
                !showFlaggedUpdatedObservationInput {
                let isLandscape = (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight)

                if isLandscape {
                    toastPill(text: detailNote)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 96)
                        .padding(.horizontal, 18)
                        .rotationEffect(bottomGlyphRotationAngle)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        .allowsHitTesting(false)
                        .zIndex(55)
                } else {
                    toastPill(text: detailNote)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, baseToastTop)
                        .padding(.horizontal, 18)
                        .allowsHitTesting(false)
                        .zIndex(55)
                }
            }

            zoomRowNativeCentered(inWidth: w)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
                .zIndex(20)

            if showGuidedAlignmentOverlay && isCaptureTargetArmed && guidedReferenceThumbnail != nil {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                        Slider(value: $referenceOverlayOpacity, in: 0.1...0.9)
                            .tint(.blue)
                        Image(systemName: "circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 26)
                .padding(.bottom, isLandscapeUI ? 94 : 74)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(21)
            }

            if showFocusRing, let fp = focusPoint {
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 74, height: 74)
                    .position(fp)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }

            if showNotSavedToast {
                Text("Save failed: \(notSavedToastReason)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, isLandscapeUI ? 44 : 0)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(25)
            }

            if showNoFlaggedIssuesToast {
                Text("No active flagged issues")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, isLandscapeUI ? 44 : 0)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(25)
            }

            if showFlaggedActionToast {
                Text(flaggedActionToastText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, isLandscapeUI ? 44 : 0)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(25)
            }

            if armedUpdateObservationID != nil &&
                !showFlaggedActionPrimaryChoice &&
                !showFlaggedUpdateCommentChoice &&
                !showFlaggedUpdatedObservationInput {
                let isLandscape = (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight)
                if isLandscape {
                    if !showGuidedAlignmentOverlay {
                        toastPill(text: armedIssueNoteText.isEmpty ? "Flagged issue armed" : armedIssueNoteText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 96)
                            .padding(.horizontal, 18)
                            .rotationEffect(bottomGlyphRotationAngle)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .allowsHitTesting(false)
                            .zIndex(26)
                    }
                } else {
                    toastPill(text: armedIssueNoteText.isEmpty ? "Flagged issue armed" : armedIssueNoteText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, baseToastTop)
                        .padding(.horizontal, 18)
                        .allowsHitTesting(false)
                        .zIndex(26)
                }
            }

            if showResolutionModeToast {
                Text("Resolution mode active. Capture a resolution photo.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, isLandscapeUI ? 44 : 0)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(25)
            }

            if showFlaggedActionPrimaryChoice {
                Color.black.opacity(0.62)
                    .frame(width: w, height: previewH)
                    .zIndex(96)

                VStack(spacing: 12) {
                    Text("Flagged Capture")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Apply this capture as an update or resolve this issue?")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)

                    VStack(spacing: 10) {
                        flaggedPopupActionButton(
                            "Update",
                            fill: Color.blue,
                            stroke: nil,
                            action: selectFlaggedPrimaryUpdate
                        )

                        flaggedPopupActionButton(
                            "Resolve",
                            fill: Color.white.opacity(0.10),
                            stroke: Color.white.opacity(0.16),
                            action: selectFlaggedPrimaryResolve
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(97)
            }

            if showFlaggedUpdateCommentChoice {
                Color.black.opacity(0.62)
                    .frame(width: w, height: previewH)
                    .zIndex(96)

                VStack(spacing: 12) {
                    Text("Update Observation")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Choose how to handle the observation text for this update.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)

                    if let original = flaggedActionTargetObservationTextForPopup {
                        Text(original)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(spacing: 10) {
                        flaggedPopupActionButton(
                            "Leave Observation Unchanged",
                            fontSize: 16,
                            fill: Color.blue,
                            stroke: nil,
                            action: selectFlaggedUpdateLeaveUnchanged
                        )

                        flaggedPopupActionButton(
                            "Revise Observation",
                            fontSize: 16,
                            fill: Color.white.opacity(0.10),
                            stroke: Color.white.opacity(0.16),
                            action: selectFlaggedUpdateRevise
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(97)
            }

            if showFlaggedUpdatedObservationInput {
                Color.black.opacity(0.62)
                    .frame(width: w, height: previewH)
                    .zIndex(96)

                VStack(spacing: 12) {
                    Text("Updated Observation")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Describe visible condition only. No measurements or structural conclusions.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.88))
                        .multilineTextAlignment(.center)

                    if let original = flaggedActionTargetObservationTextForPopup {
                        Text(original)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.94))
                            .lineLimit(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    TextField("Updated Observation", text: $draftUpdatedObservation, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.primary)

                    VStack(spacing: 10) {
                        flaggedPopupActionButton(
                            "Save and Capture",
                            fontSize: 16,
                            fill: draftUpdatedObservation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.blue.opacity(0.35) : Color.blue,
                            stroke: nil,
                            isEnabled: !draftUpdatedObservation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            action: commitFlaggedUpdatedObservationAndArm
                        )

                        flaggedPopupActionButton(
                            "Back",
                            fontSize: 16,
                            fill: Color.white.opacity(0.10),
                            stroke: Color.white.opacity(0.16),
                            action: {
                                showFlaggedUpdatedObservationInput = false
                                showFlaggedUpdateCommentChoice = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(97)
            }

            if showArmedReferenceMenu && isCaptureTargetArmed {
                armedReferenceActionOverlay()
                    .frame(width: w, height: previewH)
                    .zIndex(98)
            }

            if let freezeFrame = resolutionCapturedImage {
                Color.black.opacity(0.82)
                    .frame(width: w, height: previewH)
                    .zIndex(100)

                Image(uiImage: freezeFrame)
                    .resizable()
                    .scaledToFit()
                    .frame(width: w, height: previewH)
                    .clipped()
                    .zIndex(101)

                VStack(spacing: 12) {
                    Text("Confirm Resolution Photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    HStack(spacing: 10) {
                        Button("Retake") {
                            resetResolutionCapturePreview()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        Button("Confirm") {
                            confirmResolution()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(102)
            }

        }
        .clipped()
        .frame(height: previewH)
        .onAppear {
            shutterHaptic.prepare()
            quickButtonHaptic.prepare()
            hdButtonHaptic.prepare()
        }
        .onChange(of: showLevel) { _, newValue in
            if newValue { levelModel.start() } else { levelModel.stop() }
        }
    }

    @ViewBuilder
    private func flaggedPopupActionButton(
        _ title: String,
        fontSize: CGFloat = 18,
        fill: Color,
        stroke: Color?,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(.white.opacity(isEnabled ? 1.0 : 0.55))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if let stroke {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(stroke.opacity(isEnabled ? 1.0 : 0.55), lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .disabled(!isEnabled)
    }

    private func bottomMaskView(bottomBarH: CGFloat, containerWidth: CGFloat) -> some View {
        ZStack {
            Color.black

            VStack(spacing: 12) {
                HStack {
                    Spacer(minLength: 0)

                    Button(action: {
                        shutterHaptic.impactOccurred()
                        shutterHaptic.prepare()
                        capture()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 74, height: 74)
                                .shadow(radius: 2)
                                .overlay(
                                    Circle().stroke(Color.black.opacity(0.18), lineWidth: 1)
                                )

                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                .frame(width: 92, height: 92)

                            Circle()
                                .fill(Color.black.opacity(0.08))
                                .frame(width: 74, height: 74)
                        }
                    }
                    .disabled(camera.isCapturing)
                    .buttonStyle(.plain)
                    .offset(y: -13)
                    .overlay(alignment: .center) {
                        let hdOffsetX: CGFloat = -94
                        let leftEdgeX: CGFloat = -(containerWidth * 0.5)
                        let cancelOffsetX: CGFloat = (leftEdgeX + hdOffsetX) * 0.5

                        ZStack {
                            if isCaptureTargetArmed {
                                Button {
                                    fireQuickButtonHaptic()
                                    resetSelectionForSwitch()
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color.red.opacity(0.95))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "xmark")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .buttonStyle(.plain)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: cancelOffsetX, y: -12)
                            }

                            hdQuickButton(size: 44)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: hdOffsetX, y: -12)

                            detailNoteQuickButton(size: 44)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: 94, y: -12)

                            if isCaptureTargetArmed {
                                ZStack(alignment: .topTrailing) {
                                    guidedReferenceCard(size: 88)
                                        .rotationEffect(bottomGlyphRotationAngle)

                                    Button {
                                        fireQuickButtonHaptic()
                                        showArmedReferenceMenu = true
                                    } label: {
                                        Image(systemName: "ellipsis.circle.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.90))
                                            .background(
                                                Circle()
                                                    .fill(Color.black.opacity(0.45))
                                                    .frame(width: 18, height: 18)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                                .offset(x: 170, y: -12)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(alignment: .center) {
                    RecentAlbumPreviewCircleButton(
                        lastAsset: reportLibrary.assets.last,
                        size: 44,
                        action: {
                            fireQuickButtonHaptic()
                            showLibraryFullscreen = true
                        },
                        cache: imageCache,
                        refreshToken: gridThumbnailRefreshToken
                    )
                    .frame(width: 44, height: 44)
                    .rotationEffect(bottomGlyphRotationAngle)

                    Spacer(minLength: 0)

                    locationModeSlider()
                        .frame(height: 44)

                    Spacer(minLength: 0)

                    topRightEllipsisCircle()
                        .frame(width: 44, height: 44)
                        .rotationEffect(bottomGlyphRotationAngle)
                }
                .padding(.horizontal, 22)
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomBarH, alignment: .bottom)
            .padding(.bottom, 12)
        }
        .frame(height: bottomBarH)
    }
}

    

extension ContentView {
    
    // MARK: - Top right ellipsis circle
    
    private struct PopEllipsisButton: View {
        let size: CGFloat
        let onHaptic: () -> Void
        let onTap: () -> Void
        
        @State private var isPressed: Bool = false
        @State private var isPopping: Bool = false
        
        private func triggerPop() {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.08)) {
                isPopping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.08)) {
                    isPopping = false
                }
            }
        }
        
        var body: some View {
            Button(action: {
                onHaptic()
                triggerPop()
                onTap()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: size, height: size)
                    
                    Image(systemName: "ellipsis")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .scaleEffect(isPopping ? 1.12 : 1.0)
                .pressScaleEffect(isPressed)
            }
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        }
    }
    
    private func topRightEllipsisCircle(size: CGFloat = 44) -> some View {
        PopEllipsisButton(
            size: size,
            onHaptic: {
                fireQuickButtonHaptic()
            },
            onTap: {
                showQuickMenu = true
            }
        )
        .zIndex(50)
    }
    
    // MARK: - Lens toast control
    
    private func showLensToastNow(_ text: String) {
        lensToastToken += 1
        let token = lensToastToken
        
        lensToastText = text
        showLensToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard token == lensToastToken else { return }
            showLensToast = false
        }
    }
    
    // MARK: - UI pieces
    
    @ViewBuilder
    private func landscapeDropdownStack() -> some View {
        let controlH: CGFloat = 36
        let controlW: CGFloat = 190
        
        let elevationLabel = elevationPillLabel()
        let detailLabel = currentDetailType.isEmpty ? "Select" : currentDetailType
        
        VStack(alignment: .leading, spacing: 10) {
            
            // Elevation dropdown (compact) - custom (opens centered overlay)
            Button {
                showLandscapeBuildingMenu = false
                // Only allow elevation picking in exterior mode
                if locationMode == .interior {
                    return
                }
                showLandscapeDetailMenu = false
                showLandscapeElevationMenu.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(elevationLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    if shouldShowElevationAlignmentDot {
                        Circle()
                            .fill(isElevationHeadingAligned ? Color.green : Color.white)
                            .frame(width: 8, height: 8)
                            .allowsHitTesting(false)
                    }
                    
                    Spacer(minLength: 0)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.90))
                }
                .padding(.horizontal, 12)
                .frame(width: controlW, height: controlH, alignment: .center)
                .background(
                    ZStack {
                        Color.black.opacity(0.65)
                        Color.white.opacity(0.08)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(locationMode == .interior || isCaptureTargetArmed)
            
            // Detail type dropdown (compact) - custom (opens centered overlay)
            Button {
                showLandscapeBuildingMenu = false
                showLandscapeElevationMenu = false
                showLandscapeDetailMenu.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(detailLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    
                    Spacer(minLength: 0)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.90))
                }
                .padding(.horizontal, 12)
                .frame(width: controlW, height: controlH, alignment: .center)
                .background(
                    ZStack {
                        Color.black.opacity(0.65)
                        Color.white.opacity(0.08)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isCaptureTargetArmed)
        }
        .transaction { tx in
            tx.animation = nil
        }
    }
    
    // MARK: - Centered custom overlays for landscape dropdowns
    
    @ViewBuilder
    private func centeredLandscapeMenuOverlay() -> some View {
        let isShowing = showLandscapeBuildingMenu || showLandscapeElevationMenu || showLandscapeDetailMenu
        
        ZStack {
            if isShowing {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissLandscapeMenus()
                    }
                
                VStack(spacing: 12) {
                    if showLandscapeBuildingMenu {
                        centeredBuildingMenuContent()
                    }

                    if showLandscapeElevationMenu {
                        centeredElevationMenuContent()
                    }
                    
                    if showLandscapeDetailMenu {
                        centeredDetailMenuContent()
                    }
                }
                .rotationEffect(bottomGlyphRotationAngle)
                .padding(.horizontal, 18)
                .frame(maxWidth: 360)
            }
        }
        .allowsHitTesting(isShowing)
        .zIndex(500)
    }
    
    private func dismissLandscapeMenus() {
        showLandscapeBuildingMenu = false
        showLandscapeElevationMenu = false
        showLandscapeDetailMenu = false
    }

    @ViewBuilder
    private func centeredBuildingMenuContent() -> some View {
        VStack(spacing: 0) {
            centeredMenuHeader(title: "Building")

            VStack(spacing: 0) {
                ForEach(buildingOptions, id: \.self) { option in
                    let optionCode = buildingCode(from: option)
                    centeredMenuRow(title: buildingDisplayName(for: option), isSelected: selectedBuilding == optionCode) {
                        selectedBuilding = optionCode
                        dismissLandscapeMenus()
                    }

                    if option != buildingOptions.last {
                        centeredMenuDivider()
                    }
                }

                centeredMenuDivider()
                centeredMenuRow(title: "Manage...", isSelected: false) {
                    dismissLandscapeMenus()
                    showManageBuildingsSheet = true
                }
            }
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
    }
    
    @ViewBuilder
    private func centeredElevationMenuContent() -> some View {
        // Only relevant for exterior; if interior somehow triggers this, show nothing
        if locationMode == .interior {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                centeredMenuHeader(title: "Elevation")
                
                VStack(spacing: 0) {
                    centeredMenuRow(title: "North", isSelected: elevation == "North") {
                        elevation = "North"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "South", isSelected: elevation == "South") {
                        elevation = "South"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "East", isSelected: elevation == "East") {
                        elevation = "East"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "West", isSelected: elevation == "West") {
                        elevation = "West"
                        dismissLandscapeMenus()
                    }
                }
                .padding(.vertical, 6)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
        }
    }
    
    @ViewBuilder
    private func centeredDetailMenuContent() -> some View {
        let list = detailTypesModel.types(for: locationMode)
        
        VStack(spacing: 0) {
            centeredMenuHeader(title: locationMode == .interior ? "Interior Detail Type" : "Exterior Detail Type")
            
            // Scroll the selectable rows when the list gets long.
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(list) { item in
                        let name = item.name.isEmpty ? " " : item.name
                        let isSelected = (detailTypesModel.selected(for: locationMode) == item.name)
                        
                        centeredMenuRow(title: name, isSelected: isSelected) {
                            detailTypesModel.setSelected(item.name, for: locationMode)
                            dismissLandscapeMenus()
                        }
                        
                        if item.id != list.last?.id {
                            centeredMenuDivider()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // Keep the popup from growing off-screen.
            .frame(maxHeight: 320)
            
            centeredMenuDivider()
            
            centeredMenuRow(title: "Manage…", isSelected: false) {
                dismissLandscapeMenus()
                manageContext = ManageContext(mode: locationMode)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
    }
    
    private func centeredMenuHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
            Spacer()
            Button("Done") {
                dismissLandscapeMenus()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.92))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.20))
    }
    
    private func centeredMenuRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                
                Spacer(minLength: 0)
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
    
    private func centeredMenuDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
    
    private func toastPill(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
    private struct HDQuickButton: View {
        let size: CGFloat
        let isEnabled: Bool
        let isOn: Bool
        let onToggle: () -> Void
        let onHaptic: () -> Void
        
        @State private var isPressed: Bool = false
        @State private var isPopping: Bool = false
        
        private func triggerPop() {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.08)) {
                isPopping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.08)) {
                    isPopping = false
                }
            }
        }
        
        var body: some View {
            Button(action: {
                guard isEnabled else { return }
                onHaptic()
                triggerPop()
                onToggle()
            }) {
                ZStack {
                    Circle()
                        .fill(
                            isEnabled
                            ? (isOn ? Color.blue : Color.white.opacity(0.14))
                            : Color.white.opacity(0.08)
                        )
                        .frame(width: size, height: size)
                    
                    // Subtle glow ring when ON
                    Circle()
                        .stroke(
                            isEnabled && isOn ? Color.white.opacity(0.70) : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: size + 6, height: size + 6)
                        .opacity(isOn ? 1.0 : 0.0)
                    
                    Text("HD")
                        .font(.system(size: proportionalCircleTextSize(for: size), weight: .medium))
                        .foregroundColor(
                            isEnabled
                            ? (isOn ? .white : .white.opacity(0.92))
                            : .white.opacity(0.35)
                        )
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .scaleEffect(isPopping ? 1.12 : 1.0)
                .pressScaleEffect(isPressed)
            }
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            .disabled(!isEnabled)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        }
    }
    
    private func hdQuickButton(size: CGFloat = 44) -> some View {
        HDQuickButton(
            size: size,
            isEnabled: camera.hdSupported,
            isOn: camera.effectiveHDEnabled,
            onToggle: {
                let wasOn = camera.effectiveHDEnabled
                camera.manualHDEnabled.toggle()
                let isOnNow = camera.effectiveHDEnabled
                if !wasOn && isOnNow {
                    showHDToast("HD Enabled for Detail Capture")
                }
            },
            onHaptic: {
                fireHDButtonHaptic()
            }
        )
    }
    private struct PopDetailNoteButton: View {
        let size: CGFloat
        let hasDetailNote: Bool
        let onHaptic: () -> Void
        let onTap: () -> Void
        
        @State private var isPressed: Bool = false
        @State private var isPopping: Bool = false
        
        private func triggerPop() {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.08)) {
                isPopping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.08)) {
                    isPopping = false
                }
            }
        }
        
        var body: some View {
            Button(action: {
                onHaptic()
                triggerPop()
                onTap()
            }) {
                ZStack {
                    Circle()
                        .fill(hasDetailNote ? Color.blue : Color.white.opacity(0.14))
                        .frame(width: size, height: size)
                    
                    Circle()
                        .stroke(
                            hasDetailNote ? Color.white.opacity(0.70) : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: size + 6, height: size + 6)
                        .opacity(hasDetailNote ? 1.0 : 0.0)
                    
                    Image(systemName: "note.text")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(hasDetailNote ? .white : .white.opacity(0.92))
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .scaleEffect(isPopping ? 1.12 : 1.0)
                .pressScaleEffect(isPressed)
            }
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        }
    }
    
    private func detailNoteQuickButton(size: CGFloat = 44) -> some View {
        PopDetailNoteButton(
            size: size,
            hasDetailNote: hasDetailNote,
            onHaptic: {
                fireQuickButtonHaptic()
            },
            onTap: {
                guard !isArmedIssueDetailNoteReadOnly else { return }
                if case .guided = currentCaptureIntent {
                    clearGuidedAndRetakeArming()
                    guidedReferenceAssetLocalID = nil
                    guidedReferenceThumbnail = nil
                    showGuidedAlignmentOverlay = false
                    showArmedReferenceMenu = false
                    setCaptureIntent(.free)
                } else if case .retake = currentCaptureIntent {
                    clearGuidedAndRetakeArming()
                    guidedReferenceAssetLocalID = nil
                    guidedReferenceThumbnail = nil
                    showGuidedAlignmentOverlay = false
                    showArmedReferenceMenu = false
                    setCaptureIntent(.free)
                }
                draftDetailNote = detailNote
                showDetailOverlay = true
            }
        )
    }

    private func guidedReferenceCard(size: CGFloat = 88) -> some View {
        Button(action: {
            fireQuickButtonHaptic()
            showGuidedAlignmentOverlay.toggle()
        }) {
            Group {
                if let guidedReferenceThumbnail {
                    Image(uiImage: guidedReferenceThumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func armedReferenceActionOverlay() -> some View {
        let items = [
            SharedActionMenuItem(
                title: "View Reference Image",
                isEnabled: armedReferenceImageLocalIdentifier(isCaptured: false) != nil,
                action: {
                    showArmedReferenceMenu = false
                    showArmedReferenceImage(isCaptured: false)
                }
            ),
            SharedActionMenuItem(
                title: "View Captured Image",
                isEnabled: armedReferenceImageLocalIdentifier(isCaptured: true) != nil,
                action: {
                    showArmedReferenceMenu = false
                    showArmedReferenceImage(isCaptured: true)
                }
            )
        ]

        SharedActionMenuOverlay(
            rotation: bottomGlyphRotationAngle,
            items: items,
            onDismiss: { showArmedReferenceMenu = false }
        )
    }

    private func armedReferenceImageLocalIdentifier(isCaptured: Bool) -> String? {
        if let guidedID = armedGuidedShotID,
           let guided = guidedShots.first(where: { $0.id == guidedID }) {
            let raw = isCaptured
                ? guided.shot?.imageLocalIdentifier
                : guidedReferencePathByID[guided.id]
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isCaptured {
                guard isShotCapturedInCurrentSession(guided.shot) else { return nil }
                return trimmed.isEmpty ? nil : trimmed
            }
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let flaggedID = armedUpdateObservationID,
              let propertyID = appState.selectedPropertyID,
              let observations = try? localStore.fetchObservations(propertyID: propertyID),
              let observation = observations.first(where: { $0.id == flaggedID }) else {
            return nil
        }

        let sorted = observation.shots.sorted { $0.capturedAt < $1.capturedAt }
        let raw = isCaptured
            ? capturedImageLocalIdentifierForCurrentSession(observation)
            : {
                if let resolved = flaggedReferencePathByID[observation.id] {
                    return resolved
                }
                return sorted.first?.imageLocalIdentifier
            }()
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func armedReferenceDetailLabel() -> String {
        if let guidedID = armedGuidedShotID,
           let guided = guidedShots.first(where: { $0.id == guidedID }) {
            return Self.conciseContextLabel(
                building: guided.building,
                elevation: guided.targetElevation,
                detailType: guided.detailType
            )
        }
        if let flaggedID = armedUpdateObservationID,
           let propertyID = appState.selectedPropertyID,
           let observations = try? localStore.fetchObservations(propertyID: propertyID),
           let observation = observations.first(where: { $0.id == flaggedID }) {
            return Self.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            )
        }
        return ""
    }

    private func showArmedReferenceImage(isCaptured: Bool) {
        guard let localID = armedReferenceImageLocalIdentifier(isCaptured: isCaptured) else { return }
        armedReferenceViewerState = ArmedReferenceViewerState(
            title: isCaptured ? "Captured Image" : "Reference Image",
            detailId: armedReferenceDetailLabel(),
            localIdentifier: localID
        )
    }

    @discardableResult
    private func showIssueImagePreview(_ observation: Observation, isCaptured: Bool) -> Bool {
        let localID: String? = {
            if isCaptured {
                return capturedImageLocalIdentifierForCurrentSession(observation)
            }
            if let resolved = flaggedReferencePathByID[observation.id] {
                return resolved
            }
            let sorted = observation.shots.sorted { $0.capturedAt < $1.capturedAt }
            return sorted.first?.imageLocalIdentifier
        }()
        let trimmed = (localID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        armedReferenceViewerState = ArmedReferenceViewerState(
            title: isCaptured ? "Captured Image" : "Reference Image",
            detailId: Self.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            ),
            localIdentifier: trimmed
        )
        return true
    }

    private func performArmedReferenceRetake() {
        if let guidedID = armedGuidedShotID,
           let guided = guidedShots.first(where: { $0.id == guidedID }) {
            armGuidedRetake(guided)
            return
        }
        // Flagged captures are already armed for replacement; no extra mode switch needed.
    }

    private func topLeftPreviewPlaceholders() -> some View {
        VStack(spacing: 2) {
            activeIssuesFlagButton()

            guidedCompassButton {
                fireQuickButtonHaptic()
                let snapshot = guidedSessionCountSnapshot()
                let sessionIDText = appState.currentSession?.id.uuidString ?? "NONE"
                print("[GuidedCount] session=\(sessionIDText) guidedTotal=\(snapshot.total) capturedForSession=\(snapshot.captured) remaining=\(snapshot.remaining)")
                let liveGuidedCount = guidedRemainingForCompass
                print("[Badge] beforeOpen guidedCount=\(liveGuidedCount) flaggedCount=\(flaggedPendingCaptureCount)")
                showGuidedChecklist = true
                let liveGuidedCountAfter = guidedRemainingForCompass
                print("[Badge] afterOpen guidedCount=\(liveGuidedCountAfter) flaggedCount=\(flaggedPendingCaptureCount)")
            }
        }
    }

    private func activeIssuesFlagButton() -> some View {
        let hitArea: CGFloat = 44
        let symbolSize: CGFloat = 22
        let count = flaggedPendingCaptureCount
        let hasIssues = count > 0

        return Button(action: {
            fireQuickButtonHaptic()
            refreshActiveIssues()
            if !activeObservations.isEmpty {
                showActiveIssuesSheet = true
            } else {
                showNoFlaggedIssuesToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    showNoFlaggedIssuesToast = false
                }
            }
        }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "flag.fill")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundColor(hasIssues ? .red : .white)

                if hasIssues {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .rotationEffect(bottomGlyphRotationAngle)
            .frame(width: hitArea, height: hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitArea, height: hitArea)
    }

    private func placeholderQuickButton(
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        let hitArea: CGFloat = 44
        let symbolSize: CGFloat = 22
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .rotationEffect(bottomGlyphRotationAngle)
            .frame(width: hitArea, height: hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitArea, height: hitArea)
    }

    private func guidedCompassButton(action: @escaping () -> Void) -> some View {
        let hitArea: CGFloat = 44
        let symbolSize: CGFloat = 22
        let compassColor: Color = shouldShowGuidedCompassBadge ? .blue : .white
        let badgeCount = max(0, guidedRemainingForCompass)
        let badgeText = "\(badgeCount)"
        let badgeDiameter: CGFloat = badgeCount >= 10 ? 20 : 18

        return Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "safari")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(compassColor)

                if badgeCount > 0 {
                    Text(badgeText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(minWidth: badgeDiameter, minHeight: badgeDiameter)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .rotationEffect(bottomGlyphRotationAngle)
            .frame(width: hitArea, height: hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitArea, height: hitArea)
    }
    
    private func locationModeSlider() -> some View {
        LocationModeNativeSegmentedControl(selection: $locationMode)
        .frame(width: 190)
        .frame(height: 44) // force exact match with 44pt note button height
    }

    private struct LocationModeNativeSegmentedControl: UIViewRepresentable {
        @Binding var selection: LocationMode

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UISegmentedControl {
            let control = FixedHeightSegmentedControl(items: ["Interior", "Exterior"])
            control.forcedHeight = 44
            control.selectedSegmentIndex = index(for: selection)
            control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)

            // Keep native look with a blue active segment.
            control.selectedSegmentTintColor = UIColor.systemBlue

            let normalAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .font: UIFont.systemFont(ofSize: 19, weight: .medium)
            ]

            let selectedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 19, weight: .medium)
            ]

            control.setTitleTextAttributes(normalAttrs, for: .normal)
            control.setTitleTextAttributes(selectedAttrs, for: .selected)
            return control
        }

        func updateUIView(_ uiView: UISegmentedControl, context: Context) {
            let idx = index(for: selection)
            if uiView.selectedSegmentIndex != idx {
                uiView.selectedSegmentIndex = idx
            }
        }

        private func index(for mode: LocationMode) -> Int {
            switch mode {
            case .interior: return 0
            case .exterior: return 1
            }
        }

        private final class FixedHeightSegmentedControl: UISegmentedControl {
            var forcedHeight: CGFloat = 44

            override var intrinsicContentSize: CGSize {
                let size = super.intrinsicContentSize
                return CGSize(width: size.width, height: forcedHeight)
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                invalidateIntrinsicContentSize()
            }
        }

        final class Coordinator: NSObject {
            var parent: LocationModeNativeSegmentedControl

            init(parent: LocationModeNativeSegmentedControl) {
                self.parent = parent
            }

            @objc func changed(_ sender: UISegmentedControl) {
                parent.selection = (sender.selectedSegmentIndex == 0) ? .interior : .exterior
            }
        }
    }
    
    private func zoomRowNativeCentered(inWidth w: CGFloat) -> some View {
        let itemW: CGFloat = 36
        let spacing: CGFloat = 10
        
        let steps = displayedZoomSteps.isEmpty ? camera.zoomSteps : displayedZoomSteps
        let count = steps.count
        
        let selectedIndex: Int = {
            if let i = steps.firstIndex(where: { camera.isZoomSelected($0) }) { return i }
            return 0
        }()
        
        let totalW = CGFloat(count) * itemW + CGFloat(max(0, count - 1)) * spacing
        let leading = (w - totalW) / 2.0
        let selectedCenterX = leading + CGFloat(selectedIndex) * (itemW + spacing) + (itemW / 2.0)
        let offsetX = (w / 2.0) - selectedCenterX
        
        // Key used to animate reflow when the available zoom steps change (for example HD toggles).
        let stepsKey = steps.map { String(describing: $0.id) }.joined(separator: ",")
        
        let buttonTransition: AnyTransition = .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
        
        return HStack(spacing: spacing) {
            ForEach(steps) { step in
                let selected = camera.isZoomSelected(step)
                let base = (step.label == "1") ? "1" : step.label
                let label = selected ? "\(base)x" : base
                
                Button(action: { camera.setZoomStep(step) }) {
                    Text(label)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .white : Color.white.opacity(0.92))
                        .rotationEffect(bottomGlyphRotationAngle)
                        .frame(width: itemW, height: itemW)
                        .background(
                            Group {
                                if selected {
                                    // Active zoom uses blue fill with white text.
                                    Circle()
                                        .fill(Color.blue)
                                        .overlay(
                                            Circle().fill(Color.white.opacity(0.10)).blendMode(.overlay)
                                        )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                // Animate insert/remove (example: 2x and 8x disappear in HD)
                .transition(buttonTransition)
            }
        }
        // Keep selected zoom centered.
        .offset(x: offsetX)
        // Animate horizontal reflow and selection changes.
        .animation(zoomReflowAnimation, value: stepsKey)
        .animation(zoomReflowAnimation, value: camera.selectedZoomId)
        .frame(width: w, alignment: .center)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onAppear {
            syncDisplayedZoomSteps(immediate: true)
        }
        .onChange(of: camera.zoomSteps) { _, _ in
            syncDisplayedZoomSteps(immediate: false)
        }
    }

    private var zoomReflowAnimation: Animation {
        Animation.interactiveSpring(
            response: 0.34,
            dampingFraction: 0.88,
            blendDuration: 0.12
        )
    }

    private func syncDisplayedZoomSteps(immediate: Bool) {
        let target = camera.zoomSteps
        zoomStepsWorkItem?.cancel()
        zoomStepsWorkItem = nil

        guard !target.isEmpty else {
            displayedZoomSteps = []
            return
        }

        if immediate || displayedZoomSteps.isEmpty {
            displayedZoomSteps = target
            return
        }

        let current = displayedZoomSteps
        let currentIds = Set(current.map(\.id))
        let targetIds = Set(target.map(\.id))
        if currentIds == targetIds {
            withAnimation(zoomReflowAnimation) {
                displayedZoomSteps = target
            }
            return
        }

        // Phase 1: when the list shrinks, remove non-native/cropped steps first.
        if target.count < current.count {
            let nativeSet = Set(camera.nativeBackZoomStepIds)
            let removable = current.filter { step in
                !targetIds.contains(step.id) && !nativeSet.contains(step.id)
            }

            if !removable.isEmpty {
                let removableIds = Set(removable.map(\.id))
                withAnimation(zoomReflowAnimation) {
                    displayedZoomSteps = current.filter { !removableIds.contains($0.id) }
                }

                let work = DispatchWorkItem {
                    withAnimation(zoomReflowAnimation) {
                        displayedZoomSteps = target
                    }
                }
                zoomStepsWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
                return
            }
        }

        withAnimation(zoomReflowAnimation) {
            displayedZoomSteps = target
        }
    }
    
    private func directionSlider() -> some View {
        let selection = Binding<ContentView.Direction>(
            get: { ContentView.Direction.fromElevation(elevation) },
            set: { elevation = $0.elevationValue }
        )
        
        return DirectionSegmentedControl(selection: selection)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
    }
    
    private struct DirectionSegmentedControl: UIViewRepresentable {
        
        @Binding var selection: ContentView.Direction
        
        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }
        
        func makeUIView(context: Context) -> UISegmentedControl {
            let control = TallSegmentedControl(items: [
                "NORTH",
                "SOUTH",
                "EAST",
                "WEST"
            ])
            
            // Match selection
            control.selectedSegmentIndex = index(for: selection)
            control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
            
            // Even distribution like native pills
            control.apportionsSegmentWidthsByContent = false
            
            // Use native UIKit appearance (no custom background or border styling)
            
            // Typography + Photos-style selected blue
            let normalAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.88),
                .font: UIFont.systemFont(ofSize: 17, weight: .medium)
            ]
            
            let selectedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.systemBlue,
                .font: UIFont.systemFont(ofSize: 17, weight: .medium)
            ]
            
            control.setTitleTextAttributes(normalAttrs, for: .normal)
            control.setTitleTextAttributes(selectedAttrs, for: .selected)
            
            // Make it taller (Music-style) without custom drawing
            control.forcedHeight = 56
            
            return control
        }
        
        func updateUIView(_ uiView: UISegmentedControl, context: Context) {
            let idx = index(for: selection)
            if uiView.selectedSegmentIndex != idx {
                uiView.selectedSegmentIndex = idx
            }
        }
        
        private final class TallSegmentedControl: UISegmentedControl {
            var forcedHeight: CGFloat = 56
            
            override var intrinsicContentSize: CGSize {
                let size = super.intrinsicContentSize
                return CGSize(width: size.width, height: forcedHeight)
            }
            
            override func layoutSubviews() {
                super.layoutSubviews()
                // Ensure the control re-evaluates size after layout changes
                invalidateIntrinsicContentSize()
            }
        }
        
        private func index(for dir: ContentView.Direction) -> Int {
            switch dir {
            case .north: return 0
            case .south: return 1
            case .east:  return 2
            case .west:  return 3
            }
        }
        
        final class Coordinator: NSObject {
            var parent: DirectionSegmentedControl
            
            init(parent: DirectionSegmentedControl) {
                self.parent = parent
            }
            
            @objc func changed(_ sender: UISegmentedControl) {
                switch sender.selectedSegmentIndex {
                case 0: parent.selection = ContentView.Direction.north
                case 1: parent.selection = ContentView.Direction.south
                case 2: parent.selection = ContentView.Direction.east
                case 3: parent.selection = ContentView.Direction.west
                default: parent.selection = ContentView.Direction.north
                }
            }
        }
    }
    
    
    private func rightButtonsCluster() -> some View {
        let r: CGFloat = 24
        let gap: CGFloat = 14
        let xOffset: CGFloat = (r + gap)
        
        func circleIconButton(systemName: String, selected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.white : Color.white.opacity(0.18))
                        .frame(width: 52, height: 52)
                    
                    Image(systemName: systemName)
                        .font(.system(size: proportionalCircleGlyphSize(for: 52), weight: .medium))
                        .foregroundColor(selected ? .black : .white)
                }
                .contentShape(Circle())
                .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
        }
        
        let lastAsset = reportLibrary.assets.last
        
        return ZStack {
            circleIconButton(systemName: "note.text", selected: hasDetailNote) {
                draftDetailNote = detailNote
                showDetailOverlay = true
            }
            .offset(x: -xOffset, y: 0)
            
            RecentAlbumPreviewCircleButton(
                lastAsset: lastAsset,
                size: 52,
                action: { showLibraryFullscreen = true },
                cache: imageCache,
                refreshToken: gridThumbnailRefreshToken
            )
            .offset(x: xOffset, y: 0)
        }
    }
    
    private func fireQuickButtonHaptic() {
        quickButtonHaptic.impactOccurred()
        quickButtonHaptic.prepare()
    }
    
    private func fireHDButtonHaptic() {
        quickButtonHaptic.impactOccurred()
        quickButtonHaptic.prepare()
    }
    
    private func capture() {
        let noteAtCapture = detailNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let propertyID = appState.selectedPropertyID,
              let sessionID = appState.currentSession?.id else { return }
        let captureIntent = currentCaptureIntent
        let armedGuidedIDAtCapture: UUID? = {
            switch captureIntent {
            case .guided(let guidedID):
                return guidedID
            case .retake:
                return armedGuidedShotID
            default:
                return nil
            }
        }()
        let armedFlaggedIDAtCapture: UUID? = {
            switch captureIntent {
            case .flagged(let flaggedID):
                return flaggedID
            case .retake:
                return armedUpdateObservationID
            default:
                return nil
            }
        }()
        let armedRetakeShotIDAtCapture: UUID? = {
            if case .retake(let shotID) = captureIntent {
                return shotID
            }
            return nil
        }()
        print(
            "[Shutter] intent=\(captureIntentDebugLabel) " +
            "guidedID=\(armedGuidedIDAtCapture?.uuidString ?? "NONE") " +
            "flaggedID=\(armedFlaggedIDAtCapture?.uuidString ?? "NONE") " +
            "retakeShotID=\(armedRetakeShotIDAtCapture?.uuidString ?? "NONE") " +
            "guidedArmedKey=\(armedGuidedIDAtCapture.flatMap { id in guidedShots.first(where: { $0.id == id }).map(guidedKey(for:)) } ?? "NONE") " +
            "flagArmedID=\(armedFlaggedIDAtCapture?.uuidString ?? "NONE") " +
            "detailNoteEnabled=\(isDetailNoteEnabledForCapture) " +
            "sessionID=\(sessionID.uuidString)"
        )
        let activeRetakeContext: RetakeContext? = {
            guard case .retake = captureIntent else { return nil }
            guard let context = retakeContext else { return nil }
            if let armedGuidedID = armedGuidedShotID,
               let armedRetakeShotID = armedGuidedRetakeShotID {
                guard guidedShots.contains(where: { $0.id == armedGuidedID && $0.shot?.id == armedRetakeShotID }) else {
                    return nil
                }
                return context
            }
            if let armedObservationID = armedUpdateObservationID,
               let existingShotID = context.existingShotID,
               activeObservations.contains(where: { $0.id == armedObservationID && $0.linkedShotID == existingShotID }) {
                return context
            }
            return nil
        }()
        if activeRetakeContext == nil {
            // Defensive cleanup for stale retake state so normal captures always mint a new shot ID.
            armedGuidedRetakeShotID = nil
            retakeContext = nil
            if case .retake = currentCaptureIntent {
                currentCaptureIntent = .free
            }
        }
        let captureShotID = activeRetakeContext?.existingShotID ?? UUID()
        let preferredRetakeFilename = activeRetakeContext?.existingOriginalFilename
        pendingCaptureSaveCount += 1
        camera.capturePhoto { data in
            guard let data else {
                DispatchQueue.main.async {
                    if pendingCaptureSaveCount > 0 {
                        pendingCaptureSaveCount -= 1
                    }
                    if deferredSessionActionsRequest && pendingCaptureSaveCount == 0 {
                        deferredSessionActionsRequest = false
                        presentSessionActionsSheet()
                    }
                }
                return
            }
            let captureDate = Date()
            let captureTime = ReportLibraryModel.EmbeddedCaptureTime(captureDate: captureDate)
            let selectedProperty = appState.selectedProperty
            let normalizedElevation = CanonicalElevation.normalize(elevation) ?? elevation
            let captureDescriptionNote = noteAtCapture.isEmpty ? nil : noteAtCapture
            let captureAngleIndex = max(
                1,
                activeRetakeContext?.angleIndex
                    ?? armedGuidedIDAtCapture.flatMap { guidedID in guidedShots.first(where: { $0.id == guidedID })?.angleIndex }
                    ?? 1
            )
            let captureShotKey = ShotMetadata.makeShotKey(
                building: selectedBuilding,
                elevation: normalizedElevation,
                detailType: currentDetailType,
                angleIndex: captureAngleIndex
            )
            let captureLocation = locationManager.lastLocation
            let capturedExifOrientationRaw = ReportLibraryModel.cgOrientationRawFromDevice(lastValidDeviceOrientation)
            print("[SavePhoto] capture orientation device=\(lastValidDeviceOrientation.rawValue) exifRaw=\(capturedExifOrientationRaw)")
            let captureMetadataContext = ReportLibraryModel.EmbeddedMetadataContext(
                propertyID: propertyID,
                propertyName: selectedProperty?.name,
                propertyAddress: selectedProperty?.address,
                sessionID: sessionID,
                shotID: captureShotID,
                shotKey: captureShotKey,
                building: selectedBuilding,
                elevation: normalizedElevation,
                detailType: currentDetailType,
                angleIndex: captureAngleIndex,
                isGuided: nil,
                isFlagged: nil,
                issueStatus: nil,
                detailNote: captureDescriptionNote,
                captureMode: camera.effectiveHDEnabled ? "hd" : "normal",
                lens: camera.selectedZoomId,
                orientation: "exif:\(capturedExifOrientationRaw)",
                capturedExifOrientationRaw: capturedExifOrientationRaw,
                latitude: captureLocation?.coordinate.latitude,
                longitude: captureLocation?.coordinate.longitude,
                accuracyMeters: captureLocation?.horizontalAccuracy,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                osVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model,
                schemaVersion: 4
            )
            
            reportLibrary.savePhotoDataToSession(
                data: data,
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: captureShotID,
                captureDate: captureTime.captureDate,
                metadataContext: captureMetadataContext,
                preferredFilename: preferredRetakeFilename
            ) { success, photoRef, failureReason in
                DispatchQueue.main.async {
                    if pendingCaptureSaveCount > 0 {
                        pendingCaptureSaveCount -= 1
                    }
                    if success {
                        let wasGuidedRetakeCapture = (activeRetakeContext != nil)
                        let retakeExistingFilename = activeRetakeContext?.existingOriginalFilename
                        let shot = Shot(
                            id: captureShotID,
                            capturedAt: captureDate,
                            imageLocalIdentifier: photoRef,
                            note: noteAtCapture.isEmpty ? nil : noteAtCapture
                        )
                        let referenceImagePath = writeGuidedReferenceImage(data: data, guidedShotID: captureShotID)
                        let shouldApplyGuidedRoute: Bool = {
                            switch captureIntent {
                            case .guided:
                                return true
                            case .retake:
                                return armedGuidedIDAtCapture != nil
                            default:
                                return false
                            }
                        }()
                        let shouldApplyFlaggedRoute: Bool = {
                            switch captureIntent {
                            case .flagged:
                                return true
                            case .retake:
                                return armedFlaggedIDAtCapture != nil
                            default:
                                return false
                            }
                        }()
                        let didApplyGuidedShot = shouldApplyGuidedRoute
                            ? applyArmedGuidedShotIfNeeded(with: shot, referenceImagePath: referenceImagePath)
                            : false
                        let didApplyIssueUpdate = shouldApplyFlaggedRoute
                            ? applyArmedIssueCaptureIfNeeded(with: shot)
                            : false
                        let didQueueResolution = shouldApplyFlaggedRoute
                            ? queueResolutionCaptureIfNeeded(with: shot, data: data)
                            : false
                        var createdObservationID: UUID? = nil
                        if !didApplyGuidedShot && !didApplyIssueUpdate && !didQueueResolution {
                            if case .free = captureIntent {
                                if noteAtCapture.isEmpty {
                                    createGuidedAngleFromCaptureIfNeeded(with: shot, referenceImagePath: referenceImagePath)
                                } else {
                                    createdObservationID = createObservationFromCapturedDetailNote(noteAtCapture, shot: shot)
                                }
                            }
                        }
                        let captureIsGuided = didApplyGuidedShot || (createdObservationID == nil && noteAtCapture.isEmpty && {
                            if case .free = captureIntent { return true }
                            return false
                        }())
                        let captureIsFlagged = didApplyIssueUpdate || didQueueResolution || createdObservationID != nil
                        print(
                            "[CaptureRoute] writing shotKey=\(captureShotKey) " +
                            "isGuided=\(captureIsGuided) " +
                            "isFlagged=\(captureIsFlagged) " +
                            "sessionID=\(sessionID.uuidString) " +
                            "destination=\(shot.imageLocalIdentifier ?? "NONE")"
                        )
                        print(
                            "[CaptureComplete] newShotID=\(shot.id.uuidString) " +
                            "isGuided=\(captureIsGuided) " +
                            "isFlagged=\(captureIsFlagged)"
                        )
                        persistSessionMetadataForCapturedShot(
                            shot: shot,
                            imageData: data,
                            noteText: noteAtCapture,
                            isGuidedRetakeCapture: wasGuidedRetakeCapture,
                            retakeContext: activeRetakeContext,
                            isGuidedHint: captureIsGuided,
                            isFlaggedHint: captureIsFlagged,
                            issueIDHint: createdObservationID ?? flaggedActionTargetObservation?.id,
                            createdFlaggedObservationID: createdObservationID
                        )
                        refreshActiveIssues()
                        refreshGuidedShots()
                        if wasGuidedRetakeCapture {
                            refreshUIAfterRetakeSuccess(
                                existingFilename: retakeExistingFilename,
                                newLocalIdentifier: photoRef
                            )
                        }
                        refreshSessionActionsSummaryIfVisible()
                        if deferredSessionActionsRequest && pendingCaptureSaveCount == 0 {
                            deferredSessionActionsRequest = false
                            presentSessionActionsSheet()
                        }
                    } else {
                        notSavedToastReason = (failureReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                            ? (failureReason ?? "Write")
                            : "Write"
                        showNotSavedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                            showNotSavedToast = false
                        }
                        if deferredSessionActionsRequest && pendingCaptureSaveCount == 0 {
                            deferredSessionActionsRequest = false
                            presentSessionActionsSheet()
                        }
                    }
                }
            }
        }
    }

    private func createObservationFromCapturedDetailNote(_ noteText: String, shot: Shot) -> UUID? {
        guard !noteText.isEmpty else { return nil }
        guard let propertyID = appState.selectedPropertyID else { return nil }
        let reason = noteText.trimmingCharacters(in: .whitespacesAndNewlines)

        let observation = Observation(
            propertyID: propertyID,
            sessionID: appState.currentSession?.id,
            statement: reason,
            status: .active,
            linkedShotID: shot.id,
            updatedInSessionID: appState.currentSession?.id,
            building: selectedBuilding,
            targetElevation: elevation,
            detailType: currentDetailType,
            currentReason: reason,
            historyEvents: [
                ObservationHistoryEvent(
                    timestamp: shot.capturedAt,
                    sessionID: appState.currentSession?.id,
                    kind: .created,
                    afterValue: reason,
                    field: "reason",
                    shotID: shot.id
                ),
                ObservationHistoryEvent(
                    timestamp: shot.capturedAt,
                    sessionID: appState.currentSession?.id,
                    kind: .captured,
                    shotID: shot.id
                )
            ],
            note: reason,
            shots: [shot]
        )

        do {
            let created = try localStore.createObservation(observation)
            refreshActiveIssues()
            refreshReferenceSetsAndPendingCounts()
            detailNote = ""
            isArmedIssueDetailNoteReadOnly = false
            setCaptureIntent(.free)
            return created.id
        } catch {
            // Keep capture UX resilient if local observation persistence fails.
            return nil
        }
    }

    private func persistSessionMetadataForCapturedShot(
        shot: Shot,
        imageData: Data,
        noteText: String,
        isGuidedRetakeCapture: Bool,
        retakeContext: RetakeContext?,
        isGuidedHint: Bool,
        isFlaggedHint: Bool,
        issueIDHint: UUID?,
        createdFlaggedObservationID: UUID?
    ) {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard let session = appState.currentSession else { return }

        let imageSize = UIImage(data: imageData)?.size
        let width = imageSize.map { Int($0.width) }
        let height = imageSize.map { Int($0.height) }

        var buildingValue = selectedBuilding.trimmingCharacters(in: .whitespacesAndNewlines)
        var elevationValue = CanonicalElevation.normalize(elevation) ?? elevation
        var detailTypeValue = currentDetailType.trimmingCharacters(in: .whitespacesAndNewlines)
        var angleIndexValue = 1
        var isGuided = isGuidedHint
        var isFlagged = isFlaggedHint
        var issueID = issueIDHint
        var issueStatus: String?
        var captureKind: String?
        var firstCaptureKind: String?
        var noteValue = noteText.isEmpty ? nil : noteText

        if let retakeContext {
            buildingValue = retakeContext.building
            elevationValue = retakeContext.elevation
            detailTypeValue = retakeContext.detailType
            angleIndexValue = max(1, retakeContext.angleIndex)
            if isGuidedHint {
                isGuided = true
            }
        }

        if let guided = guidedShots.first(where: { $0.shot?.id == shot.id }) {
            let guidedBuilding = guided.building?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let guidedElevation = CanonicalElevation.normalize(guided.targetElevation) ?? ""
            let guidedDetail = guided.detailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !guidedBuilding.isEmpty { buildingValue = guidedBuilding }
            if !guidedElevation.isEmpty { elevationValue = guidedElevation }
            if !guidedDetail.isEmpty { detailTypeValue = guidedDetail }
            angleIndexValue = max(1, guided.angleIndex ?? 1)
            isGuided = true
        }

        if let propertyObservations = try? localStore.fetchObservations(propertyID: propertyID),
           let observation = propertyObservations.first(where: { obs in
               obs.linkedShotID == shot.id || obs.shots.contains(where: { $0.id == shot.id })
           }) {
            isFlagged = true
            issueID = observation.id
            let isNewFlaggedIssueCapture = createdFlaggedObservationID == observation.id
            if observation.status == .resolved || observation.resolvedInSessionID == session.id {
                issueStatus = "resolved"
                captureKind = "resolved_capture"
                firstCaptureKind = "captured"
            } else if isNewFlaggedIssueCapture {
                issueStatus = "active"
                captureKind = "captured"
                firstCaptureKind = "captured"
            } else if retakeContext != nil {
                issueStatus = "active"
                captureKind = "retake"
                firstCaptureKind = "captured"
            } else if observation.updatedInSessionID == session.id {
                issueStatus = "active"
                captureKind = "follow_up_capture"
                firstCaptureKind = "captured"
            } else {
                issueStatus = "active"
                captureKind = "reference"
                firstCaptureKind = "captured"
            }
            let obsBuilding = observation.building?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let obsElevation = CanonicalElevation.normalize(observation.targetElevation) ?? ""
            let obsDetail = observation.detailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !obsBuilding.isEmpty { buildingValue = obsBuilding }
            if !obsElevation.isEmpty { elevationValue = obsElevation }
            if !obsDetail.isEmpty { detailTypeValue = obsDetail }
            if noteValue == nil || noteValue?.isEmpty == true {
                let obsNote = Self.observationCurrentReasonText(observation) ?? ""
                noteValue = obsNote.isEmpty ? nil : obsNote
            }
        }

        if !appState.propertyHasBaseline(propertyID),
           retakeContext == nil,
           angleIndexValue <= 1 {
            angleIndexValue = max(
                1,
                nextSessionAngleIndexForBaselineCapture(
                    propertyID: propertyID,
                    sessionID: session.id,
                    building: buildingValue,
                    elevation: elevationValue,
                    detailType: detailTypeValue,
                    excludingShotID: shot.id
                )
            )
        }

        let localIdentifier = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fileNameFromIdentifier = URL(fileURLWithPath: localIdentifier).lastPathComponent
        let originalFilename = fileNameFromIdentifier.isEmpty ? "\(shot.id.uuidString).heic" : fileNameFromIdentifier
        let normalizedElevation = CanonicalElevation.normalize(elevationValue) ?? elevationValue
        let shotKey = ShotMetadata.makeShotKey(
            building: buildingValue,
            elevation: normalizedElevation,
            detailType: detailTypeValue,
            angleIndex: max(1, angleIndexValue)
        )
        let exifOrientation = Int(ReportLibraryModel.cgOrientationRawFromDevice(lastValidDeviceOrientation))
        let location = locationManager.lastLocation

        var metadata = ShotMetadata(
            shotID: shot.id,
            propertyID: propertyID,
            sessionID: session.id,
            createdAt: shot.capturedAt,
            updatedAt: shot.capturedAt,
            building: buildingValue,
            elevation: normalizedElevation,
            detailType: detailTypeValue,
            angleIndex: max(1, angleIndexValue),
            shotKey: shotKey,
            isGuided: isGuided,
            isFlagged: isFlagged,
            issueID: issueID,
            issueStatus: issueStatus,
            captureKind: captureKind,
            firstCaptureKind: firstCaptureKind,
            noteText: noteValue,
            noteCategory: nil,
            originalFilename: originalFilename,
            originalRelativePath: "Originals/\(originalFilename)",
            originalByteSize: imageData.count,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: camera.effectiveHDEnabled ? "hd" : "normal",
            lens: camera.selectedZoomId,
            exifOrientation: exifOrientation,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            accuracyMeters: location?.horizontalAccuracy,
            imageWidth: width,
            imageHeight: height
        )
        let readableStampedName = "\(readableStampedBaseName(for: metadata)).jpg"
        metadata.stampedFilename = readableStampedName
        metadata.stampedRelativePath = "Stamped/\(readableStampedName)"

        do {
            let matchMode: LocalStore.ShotUpsertMatchMode = (isGuidedRetakeCapture && isGuided)
                ? .replaceGuidedKey
                : .append
            try localStore.upsertShot(
                propertyID: propertyID,
                sessionID: session.id,
                shot: metadata,
                matchMode: matchMode
            )
            let updated = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: session.id)
            let originalsURL = localStore.originalsDirectoryURL(propertyID: propertyID, sessionID: session.id)
            let originalsItems = (try? FileManager.default.contentsOfDirectory(
                at: originalsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let originalsCount = originalsItems.filter {
                let lower = $0.lastPathComponent.lowercased()
                return lower.hasSuffix(".heic") || lower.hasSuffix(".heif")
            }.count
#if DEBUG
            print("[Session] shotsCount=\(updated.shots.count) originalsCount=\(originalsCount)")
#endif
        } catch {
            print("Recoverable shot metadata persistence failure: \(error)")
        }
    }

    private func nextSessionAngleIndexForBaselineCapture(
        propertyID: UUID,
        sessionID: UUID,
        building: String,
        elevation: String,
        detailType: String,
        excludingShotID: UUID
    ) -> Int {
        do {
            let metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            let normalizedElevation = CanonicalElevation.normalize(elevation) ?? elevation
            let normalizedBuilding = building.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedDetailType = detailType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let matchingAngles = metadata.shots.compactMap { existing -> Int? in
                guard existing.shotID != excludingShotID else { return nil }
                guard existing.building.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedBuilding else { return nil }
                guard (CanonicalElevation.normalize(existing.elevation) ?? existing.elevation) == normalizedElevation else { return nil }
                guard existing.detailType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedDetailType else { return nil }
                return max(1, existing.angleIndex)
            }
            return (matchingAngles.max() ?? 0) + 1
        } catch {
            return 1
        }
    }

    private func refreshGuidedShots() {
        guard let propertyID = appState.selectedPropertyID else {
            guidedShots = []
            guidedResolvedThumbnailPathByID = [:]
            guidedReferencePathByID = [:]
            activeSessionShotIDs = []
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            currentCaptureIntent = .free
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            showGuidedAlignmentOverlay = false
            showArmedReferenceMenu = false
            refreshReferenceSetsAndPendingCounts()
            return
        }

        let activeSessionID = appState.currentSession?.id
        let baselineState = persistedBaselineState(propertyID: propertyID)
        print(
            "[BaselineState] propertyID=\(propertyID.uuidString) baselineSessionID=\(baselineState.baselineSessionID?.uuidString ?? "NONE") hasBaseline=\(baselineState.hasBaseline)"
        )
        let sessionMetadata = sessionMetadataForActiveSession(propertyID: propertyID, sessionID: activeSessionID)
        var sessionShotIDs = Set((sessionMetadata?.shots ?? []).map(\.shotID))
        let isBaselineSessionActive = baselineState.baselineSessionID == activeSessionID
        let orderedSessions = ((try? localStore.fetchSessions(propertyID: propertyID)) ?? []).sorted { $0.startedAt < $1.startedAt }
        let currentSession = orderedSessions.first(where: { $0.id == activeSessionID }) ?? appState.currentSession
        var metadataCache: [UUID: SessionMetadata] = [:]
        if let currentSessionMetadata = sessionMetadata, let activeSessionID {
            metadataCache[activeSessionID] = currentSessionMetadata
        }

        var fetchedGuidedShots = loadGuidedChecklistForSession(
            propertyID: propertyID,
            sessionID: activeSessionID,
            baselineState: baselineState
        )
        var resolvedMap: [UUID: String] = [:]
        var referenceMap: [UUID: String] = [:]
        if !isBaselineSessionActive {
            let currentGuidedMetadataByID = Dictionary(
                uniqueKeysWithValues: (sessionMetadata?.shots ?? [])
                    .filter(\.isGuided)
                    .map { ($0.shotID, $0) }
            )

            for index in fetchedGuidedShots.indices {
                let guided = fetchedGuidedShots[index]
                if let existingShot = guided.shot,
                   let metadataShot = currentGuidedMetadataByID[existingShot.id],
                   let sessionID = activeSessionID {
                    let resolved = resolvedSessionImagePath(
                        for: metadataShot,
                        propertyID: propertyID,
                        sessionID: sessionID
                    )
                    if let localIdentifier = resolved.absolutePath {
                        fetchedGuidedShots[index].shot = Shot(
                            id: metadataShot.shotID,
                            capturedAt: metadataShot.updatedAt,
                            imageLocalIdentifier: localIdentifier,
                            note: metadataShot.noteText
                        )
                        fetchedGuidedShots[index].isCompleted = true
                    } else {
                        fetchedGuidedShots[index].shot = nil
                        fetchedGuidedShots[index].isCompleted = false
                    }
                } else if let existingShot = guided.shot {
                    // Preserve a locally persisted guided capture even if session metadata has not
                    // materialized the guided shot row yet.
                    let existingPath = existingShot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !existingPath.isEmpty, Self.reportAsset(from: existingPath) != nil {
                        fetchedGuidedShots[index].isCompleted = true
                        sessionShotIDs.insert(existingShot.id)
                    } else {
                        fetchedGuidedShots[index].shot = nil
                        fetchedGuidedShots[index].isCompleted = false
                    }
                } else {
                    fetchedGuidedShots[index].shot = nil
                    fetchedGuidedShots[index].isCompleted = false
                }
            }
        }

        for index in fetchedGuidedShots.indices {
            let guided = fetchedGuidedShots[index]
            if resolvedMap[guided.id] != nil {
                continue
            }
            let resolved = resolveGuidedThumbnailForDisplay(
                propertyID: propertyID,
                currentSession: currentSession,
                baselineSessionID: baselineState.baselineSessionID,
                guidedShot: guided,
                currentSessionMetadata: sessionMetadata,
                orderedSessions: orderedSessions,
                metadataCache: &metadataCache
            )
            if let chosenPath = resolved.path, resolved.exists {
                resolvedMap[guided.id] = chosenPath
                if resolved.source != .current {
                    fetchedGuidedShots[index].referenceImagePath = chosenPath
                    fetchedGuidedShots[index].referenceImageLocalIdentifier = chosenPath
                    referenceMap[guided.id] = chosenPath
                }
            }
            if referenceMap[guided.id] == nil,
               let referencePath = resolveGuidedReferencePathForDisplay(
                propertyID: propertyID,
                guidedShot: fetchedGuidedShots[index],
                currentSession: currentSession,
                baselineSessionID: baselineState.baselineSessionID
               ) {
                referenceMap[guided.id] = referencePath
            }
        }
        activeSessionShotIDs = sessionShotIDs
        guidedShots = fetchedGuidedShots
        guidedResolvedThumbnailPathByID = resolvedMap
        guidedReferencePathByID = referenceMap

        if let armedID = armedGuidedShotID, guidedShots.contains(where: { $0.id == armedID }) == false {
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            currentCaptureIntent = .free
            showArmedReferenceMenu = false
        }

        print(
            "[GuidedData] using sessionID=\(activeSessionID?.uuidString ?? "NONE") " +
            "shotsCount=\(sessionShotIDs.count) " +
            "flaggedCount=\(activeObservations.count) " +
            "guidedCount=\(guidedShots.count)"
        )
        let snapshot = guidedSessionCountSnapshot()
        print(
            "[GuidedCount] session=\(activeSessionID?.uuidString ?? "NONE") " +
            "guidedTotal=\(snapshot.total) capturedForSession=\(snapshot.captured) remaining=\(snapshot.remaining)"
        )
        refreshReferenceSetsAndPendingCounts()
    }

    private func loadGuidedChecklistForSession(
        propertyID: UUID,
        sessionID: UUID?,
        baselineState: (baselineSessionID: UUID?, hasBaseline: Bool)
    ) -> [GuidedShot] {
        if let existing = try? localStore.fetchGuidedShots(propertyID: propertyID), !existing.isEmpty {
            let normalized = Self.normalizedGuidedShotsWithStableAngles(existing)
            if normalized != existing {
                try? localStore.saveGuidedShots(normalized, propertyID: propertyID)
            }
            if let sessionID {
                try? localStore.syncGuidedShotsToSessionMetadata(
                    propertyID: propertyID,
                    sessionID: sessionID,
                    guidedShots: normalized
                )
            }
            return visibleGuidedShots(from: normalized)
        }

        guard let sessionID else {
            return []
        }
        guard baselineState.hasBaseline, let baselineSessionID = baselineState.baselineSessionID else {
            print("[GuidedSeed] session=\(sessionID.uuidString) seededCount=0")
            return []
        }

        guard let baselineMetadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: baselineSessionID) else {
            print("[GuidedSeed] session=\(sessionID.uuidString) seededCount=0")
            return []
        }

        let baselineSessionFolder = localStore.sessionFolderURL(propertyID: propertyID, sessionID: baselineSessionID)
        var seeded: [GuidedShot] = []
        seeded.reserveCapacity(baselineMetadata.shots.count)

        for shot in baselineMetadata.shots
            .filter(\.isGuided)
            .sorted(by: { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                if lhs.angleIndex != rhs.angleIndex { return lhs.angleIndex < rhs.angleIndex }
                return lhs.shotID.uuidString < rhs.shotID.uuidString
            }) {
            let stampedRelative = shot.stampedRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let originalRelative = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)

            var referencePath: String? = nil
            if !stampedRelative.isEmpty {
                let stampedURL = baselineSessionFolder.appendingPathComponent(stampedRelative, isDirectory: false)
                if FileManager.default.fileExists(atPath: stampedURL.path) {
                    referencePath = stampedURL.path
                }
            }
            if referencePath == nil, !originalRelative.isEmpty {
                let originalURL = baselineSessionFolder.appendingPathComponent(originalRelative, isDirectory: false)
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    referencePath = originalURL.path
                }
            }

            let title = Self.conciseContextLabel(
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType
            )

            let seededShot = GuidedShot(
                id: shot.shotID,
                title: title.isEmpty ? "Guided Shot" : title,
                building: shot.building,
                targetElevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: max(1, shot.angleIndex),
                referenceImageLocalIdentifier: referencePath,
                referenceImagePath: referencePath,
                shot: nil,
                isCompleted: false
            )
            seeded.append(seededShot)
        }

        let normalizedSeeded = Self.normalizedGuidedShotsWithStableAngles(seeded)
        if !normalizedSeeded.isEmpty {
            try? localStore.saveGuidedShots(normalizedSeeded, propertyID: propertyID)
            try? localStore.syncGuidedShotsToSessionMetadata(
                propertyID: propertyID,
                sessionID: sessionID,
                guidedShots: normalizedSeeded
            )
        }
        print("[GuidedSeed] session=\(sessionID.uuidString) seededCount=\(normalizedSeeded.count)")
        return visibleGuidedShots(from: normalizedSeeded)
    }

    private func refreshUIAfterRetakeSuccess(existingFilename: String?, newLocalIdentifier: String?) {
        if let newLocalIdentifier {
            imageCache.invalidate(localIdentifier: newLocalIdentifier)
        }

        if let propertyID = appState.selectedPropertyID,
           let sessionID = appState.currentSession?.id {
            if let existingFilename {
                let trimmed = existingFilename.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let existingPath = localStore
                        .originalsDirectoryURL(propertyID: propertyID, sessionID: sessionID)
                        .appendingPathComponent(trimmed)
                        .path
                    imageCache.invalidate(localIdentifier: existingPath)
                }
            }
            // Retake reuses the same identifier; clear cache to guarantee immediate thumbnail refresh.
            imageCache.clearAll()
            reportLibrary.reloadSessionAssets(propertyID: propertyID, sessionID: sessionID)
        }

        refreshGuidedShots()
        refreshActiveIssues()
        gridThumbnailRefreshToken = UUID()
        guidedThumbnailRefreshToken = UUID()
    }

    private func handleLocalCacheClearSignal() {
        imageCache.clearAll()
        if let propertyID = appState.selectedPropertyID,
           let sessionID = appState.currentSession?.id {
            reportLibrary.reloadSessionAssets(propertyID: propertyID, sessionID: sessionID)
        } else {
            reportLibrary.reloadAssets()
        }
        refreshGuidedShots()
        refreshActiveIssues()
        gridThumbnailRefreshToken = UUID()
        guidedThumbnailRefreshToken = UUID()
    }

    private func armGuidedShot(_ guidedShot: GuidedShot) {
        guard !isShotCapturedInCurrentSession(guidedShot.shot) else { return }
        resetSelectionForSwitch()
        retakeContext = nil
        if let building = guidedShot.building, !building.isEmpty {
            selectedBuilding = buildingCode(from: building)
        }
        if let targetElevation = guidedShot.targetElevation, !targetElevation.isEmpty {
            elevation = targetElevation
        } else if let inferredElevation = inferElevation(from: guidedShot.title) {
            elevation = inferredElevation
        }
        let detail = guidedShot.detailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty {
            detailTypesModel.setSelected(detail, for: locationMode)
        }
        loadGuidedArmedThumbnail(for: guidedShot)
        showGuidedAlignmentOverlay = false
        armedGuidedRetakeShotID = nil
        armedGuidedShotID = guidedShot.id
        setCaptureIntent(.guided(guidedShot.id))
        showGuidedChecklist = false
    }

    private func armGuidedRetake(_ guidedShot: GuidedShot) {
        guard isShotCapturedInCurrentSession(guidedShot.shot), let existingShot = guidedShot.shot else { return }
        resetSelectionForSwitch()
        if let building = guidedShot.building, !building.isEmpty {
            selectedBuilding = buildingCode(from: building)
        }
        if let targetElevation = guidedShot.targetElevation, !targetElevation.isEmpty {
            elevation = targetElevation
        } else if let inferredElevation = inferElevation(from: guidedShot.title) {
            elevation = inferredElevation
        }
        let detail = guidedShot.detailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty {
            detailTypesModel.setSelected(detail, for: locationMode)
        }
        var retakeReferencePath: String? = nil
        var retakeReferenceSource = "none"
        if let propertyID = appState.selectedPropertyID {
            let baselineState = persistedBaselineState(propertyID: propertyID)
            let orderedSessions = ((try? localStore.fetchSessions(propertyID: propertyID)) ?? []).sorted { $0.startedAt < $1.startedAt }
            let currentSession = orderedSessions.first(where: { $0.id == appState.currentSession?.id }) ?? appState.currentSession
            var metadataCache: [UUID: SessionMetadata] = [:]
            let resolved = resolveGuidedRetakeReferenceForDisplay(
                propertyID: propertyID,
                currentSession: currentSession,
                baselineSessionID: baselineState.baselineSessionID,
                guidedShot: guidedShot,
                orderedSessions: orderedSessions,
                metadataCache: &metadataCache
            )
            if let path = resolved.path, resolved.exists {
                retakeReferencePath = path
            }
            switch resolved.source {
            case .prior:
                retakeReferenceSource = "priorSession"
            case .baseline:
                retakeReferenceSource = "baseline"
            case .reference:
                retakeReferenceSource = "baseline"
            default:
                retakeReferenceSource = "none"
            }
        }
        print("[RetakeRef] session=\(appState.currentSession?.id.uuidString ?? "NONE") guidedKey=\(guidedKey(for: guidedShot)) chosenSource=\(retakeReferenceSource) chosenPath=\(retakeReferencePath ?? "NONE") exists=\(retakeReferencePath != nil)")
        loadGuidedArmedThumbnail(for: guidedShot, forcedPath: retakeReferencePath)
        showGuidedAlignmentOverlay = false
        let rawPath = existingShot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingFilename = rawPath.isEmpty ? nil : URL(fileURLWithPath: rawPath).lastPathComponent
        retakeContext = RetakeContext(
            building: (guidedShot.building ?? selectedBuilding).trimmingCharacters(in: .whitespacesAndNewlines),
            elevation: (CanonicalElevation.normalize(guidedShot.targetElevation) ?? elevation).trimmingCharacters(in: .whitespacesAndNewlines),
            detailType: (guidedShot.detailType ?? currentDetailType).trimmingCharacters(in: .whitespacesAndNewlines),
            angleIndex: max(1, guidedShot.angleIndex ?? 1),
            existingShotID: existingShot.id,
            existingOriginalFilename: existingFilename
        )
        armedGuidedRetakeShotID = existingShot.id
        armedGuidedShotID = guidedShot.id
        setCaptureIntent(.retake(existingShot.id))
        showGuidedChecklist = false
    }

    private func loadGuidedArmedThumbnail(for guidedShot: GuidedShot, forcedPath: String? = nil) {
        let sessionIDText = appState.currentSession?.id.uuidString ?? "NONE"
        let chosenPath = (forcedPath ?? guidedResolvedThumbnailPathByID[guidedShot.id])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosenExists = !chosenPath.isEmpty && FileManager.default.fileExists(atPath: chosenPath)
        let chosenSource = forcedPath == nil ? "resolved" : "retakeReference"
        print(
            "[SelectedThumbResolve] session=\(sessionIDText) guidedID=\(guidedShot.id.uuidString) " +
            "chosenSource=\(chosenPath.isEmpty ? "none" : chosenSource) chosenPath=\(chosenPath.isEmpty ? "NONE" : chosenPath) exists=\(chosenExists)"
        )

        guard !chosenPath.isEmpty, chosenExists, let image = UIImage(contentsOfFile: chosenPath) else {
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            return
        }
        guidedReferenceAssetLocalID = chosenPath
        guidedReferenceThumbnail = image
    }

    private func markGuidedShotSkipped(_ guidedShot: GuidedShot, reason: SkipReason, otherNote: String?) {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard !isShotCapturedInCurrentSession(guidedShot.shot) else { return }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == guidedShot.id }) else { return }

            allGuidedShots[idx].skipReason = reason
            allGuidedShots[idx].skipReasonNote = reason == .other ? otherNote?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            allGuidedShots[idx].skipSessionID = appState.currentSession?.id
            allGuidedShots[idx].isCompleted = false
            allGuidedShots[idx].shot = nil

            if armedGuidedShotID == guidedShot.id {
                armedGuidedShotID = nil
                armedGuidedRetakeShotID = nil
                retakeContext = nil
                currentCaptureIntent = .free
                guidedReferenceAssetLocalID = nil
                guidedReferenceThumbnail = nil
                showGuidedAlignmentOverlay = false
            }

            _ = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            refreshGuidedShots()
            guidedThumbnailRefreshToken = UUID()
            refreshSessionActionsSummaryIfVisible()
        } catch {
            print("Failed to mark guided shot skipped: \(error)")
        }
    }

    private func undoGuidedShotSkip(_ guidedShot: GuidedShot) {
        guard let propertyID = appState.selectedPropertyID else { return }
        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == guidedShot.id }) else { return }
            allGuidedShots[idx].skipReason = nil
            allGuidedShots[idx].skipReasonNote = nil
            allGuidedShots[idx].skipSessionID = nil
            _ = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            refreshGuidedShots()
            guidedThumbnailRefreshToken = UUID()
            refreshSessionActionsSummaryIfVisible()
        } catch {
            print("Failed to undo guided skip: \(error)")
        }
    }

    private func retireGuidedShot(_ guidedShot: GuidedShot) {
        guard let propertyID = appState.selectedPropertyID else { return }
        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == guidedShot.id }) else { return }
            allGuidedShots[idx].status = .retired
            allGuidedShots[idx].isRetired = true
            allGuidedShots[idx].retiredAt = Date()
            allGuidedShots[idx].retiredInSessionID = appState.currentSession?.id
            allGuidedShots[idx].skipReason = nil
            allGuidedShots[idx].skipReasonNote = nil
            allGuidedShots[idx].skipSessionID = nil

            if armedGuidedShotID == guidedShot.id {
                clearGuidedAndRetakeArming()
                retakeContext = nil
                currentCaptureIntent = .free
                guidedReferenceAssetLocalID = nil
                guidedReferenceThumbnail = nil
                showGuidedAlignmentOverlay = false
            }

            _ = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            refreshGuidedShots()
            guidedThumbnailRefreshToken = UUID()
            refreshSessionActionsSummaryIfVisible()
        } catch {
            print("Failed to retire guided shot: \(error)")
        }
    }

    private func reclassifyGuidedShot(
        _ guidedShot: GuidedShot,
        building: String,
        elevation: String,
        detailType: String
    ) {
        guard let propertyID = appState.selectedPropertyID else { return }

        let normalizedBuilding = building.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedElevation = (CanonicalElevation.normalize(elevation) ?? elevation).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetailType = detailType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBuilding.isEmpty, !normalizedElevation.isEmpty, !normalizedDetailType.isEmpty else { return }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == guidedShot.id }) else { return }

            let assignedAngle = nextAvailableGuidedAngleIndex(
                propertyID: propertyID,
                building: normalizedBuilding,
                elevation: normalizedElevation,
                detailType: normalizedDetailType,
                excludingGuidedShotID: guidedShot.id
            )

            allGuidedShots[idx].building = normalizedBuilding
            allGuidedShots[idx].targetElevation = normalizedElevation
            allGuidedShots[idx].detailType = normalizedDetailType
            allGuidedShots[idx].angleIndex = assignedAngle
            allGuidedShots[idx].title = guidedContextLabel(
                building: normalizedBuilding,
                elevation: normalizedElevation,
                detailType: normalizedDetailType
            )
            allGuidedShots[idx].reassignedAt = Date()
            allGuidedShots[idx].reassignedInSessionID = appState.currentSession?.id

            let updatedGuided = allGuidedShots[idx]
            _ = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            if let shotID = updatedGuided.shot?.id {
                updateShotMetadataLocation(
                    propertyID: propertyID,
                    shotID: shotID,
                    building: normalizedBuilding,
                    elevation: normalizedElevation,
                    detailType: normalizedDetailType,
                    angleIndex: assignedAngle,
                    isGuided: true
                )
            }
            refreshGuidedShots()
            guidedThumbnailRefreshToken = UUID()
            refreshSessionActionsSummaryIfVisible()
        } catch {
            print("Failed to reclassify guided shot: \(error)")
        }
    }

    private func nextAvailableGuidedAngleIndex(
        propertyID: UUID,
        building: String,
        elevation: String,
        detailType: String,
        excludingGuidedShotID: UUID?
    ) -> Int {
        let normalizedBuilding = Self.normalizeGuidedPart(building)
        let normalizedElevation = Self.normalizeGuidedPart(CanonicalElevation.normalize(elevation) ?? elevation)
        let normalizedDetailType = Self.normalizeGuidedPart(detailType)

        let guidedShots = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
        let usedAngles = Set(
            guidedShots.compactMap { item -> Int? in
                guard item.id != excludingGuidedShotID else { return nil }
                guard item.status != .retired, !item.isRetired else { return nil }
                guard Self.normalizeGuidedPart(item.building) == normalizedBuilding else { return nil }
                guard Self.normalizeGuidedPart(CanonicalElevation.normalize(item.targetElevation) ?? item.targetElevation) == normalizedElevation else { return nil }
                guard Self.normalizeGuidedPart(item.detailType) == normalizedDetailType else { return nil }
                return max(1, item.angleIndex ?? 1)
            }
        )

        var nextAngle = 1
        while usedAngles.contains(nextAngle) {
            nextAngle += 1
        }
        return nextAngle
    }

    private func reclassifyObservation(
        _ observation: Observation,
        building: String,
        elevation: String,
        detailType: String
    ) {
        guard let propertyID = appState.selectedPropertyID else { return }

        let normalizedBuilding = building.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedElevation = (CanonicalElevation.normalize(elevation) ?? elevation).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetailType = detailType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBuilding.isEmpty, !normalizedElevation.isEmpty, !normalizedDetailType.isEmpty else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard var updated = observations.first(where: { $0.id == observation.id }) else { return }

            let shotID = updated.linkedShotID ?? updated.shots.last?.id
            let beforeContext = Self.observationContextValue(
                building: updated.building,
                elevation: updated.targetElevation,
                detailType: updated.detailType
            )
            let assignedAngle = nextAvailableFlaggedAngleIndex(
                propertyID: propertyID,
                sessionID: appState.currentSession?.id,
                building: normalizedBuilding,
                elevation: normalizedElevation,
                detailType: normalizedDetailType,
                excludingShotID: shotID
            )

            updated.building = normalizedBuilding
            updated.targetElevation = normalizedElevation
            updated.detailType = normalizedDetailType
            updated.updatedAt = Date()
            updated.updatedInSessionID = appState.currentSession?.id
            appendObservationHistoryEvent(
                ObservationHistoryEvent(
                    timestamp: updated.updatedAt,
                    sessionID: appState.currentSession?.id,
                    kind: .reclassified,
                    beforeValue: beforeContext,
                    afterValue: Self.observationContextValue(
                        building: normalizedBuilding,
                        elevation: normalizedElevation,
                        detailType: normalizedDetailType
                    ),
                    field: "location",
                    shotID: shotID
                ),
                to: &updated
            )

            _ = try localStore.updateObservation(updated)
            if let shotID {
                updateShotMetadataLocation(
                    propertyID: propertyID,
                    shotID: shotID,
                    building: normalizedBuilding,
                    elevation: normalizedElevation,
                    detailType: normalizedDetailType,
                    angleIndex: assignedAngle,
                    isGuided: false,
                    issueID: updated.id,
                    issueStatus: updated.status == .resolved ? "resolved" : "active",
                    captureKind: "reclassified"
                )
            }
            showFlaggedActionToastNow("Issue reclassified")
            refreshActiveIssues()
        } catch {
            print("Failed to reclassify observation: \(error)")
        }
    }

    private func nextAvailableFlaggedAngleIndex(
        propertyID: UUID,
        sessionID: UUID?,
        building: String,
        elevation: String,
        detailType: String,
        excludingShotID: UUID?
    ) -> Int {
        guard let sessionID else { return 1 }
        let normalizedElevation = CanonicalElevation.normalize(elevation) ?? elevation
        let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        let usedAngles = Set(
            (metadata?.shots ?? []).compactMap { shot -> Int? in
                guard shot.shotID != excludingShotID else { return nil }
                guard shot.building.caseInsensitiveCompare(building) == .orderedSame else { return nil }
                guard (CanonicalElevation.normalize(shot.elevation) ?? shot.elevation) == normalizedElevation else { return nil }
                guard shot.detailType.caseInsensitiveCompare(detailType) == .orderedSame else { return nil }
                return max(1, shot.angleIndex)
            }
        )

        var nextAngle = 1
        while usedAngles.contains(nextAngle) {
            nextAngle += 1
        }
        return nextAngle
    }

    private func updateShotMetadataLocation(
        propertyID: UUID,
        shotID: UUID,
        building: String,
        elevation: String,
        detailType: String,
        angleIndex: Int,
        isGuided: Bool? = nil,
        issueID: UUID? = nil,
        issueStatus: String? = nil,
        captureKind: String? = nil
    ) {
        let sessions = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
        for session in sessions {
            guard var metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: session.id),
                  let idx = metadata.shots.firstIndex(where: { $0.shotID == shotID }) else { continue }

            metadata.shots[idx].building = building
            metadata.shots[idx].elevation = CanonicalElevation.normalize(elevation) ?? elevation
            metadata.shots[idx].detailType = detailType
            metadata.shots[idx].angleIndex = max(1, angleIndex)
            metadata.shots[idx].shotKey = ShotMetadata.makeShotKey(
                building: building,
                elevation: CanonicalElevation.normalize(elevation) ?? elevation,
                detailType: detailType,
                angleIndex: max(1, angleIndex)
            )
            metadata.shots[idx].updatedAt = Date()
            if let isGuided {
                metadata.shots[idx].isGuided = isGuided
                metadata.shots[idx].isFlagged = !isGuided
            }
            if let issueID {
                metadata.shots[idx].issueID = issueID
            }
            if let issueStatus {
                metadata.shots[idx].issueStatus = issueStatus
            }
            if let captureKind {
                metadata.shots[idx].captureKind = captureKind
            }
            if metadata.shots[idx].isFlagged,
               metadata.shots[idx].captureKind == "retake",
               metadata.shots[idx].firstCaptureKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                metadata.shots[idx].firstCaptureKind = "captured"
            }

            try? localStore.saveSessionMetadataAtomically(
                propertyID: propertyID,
                sessionID: session.id,
                metadata: metadata
            )
            return
        }
    }

    private func reassignGuidedShot(_ source: GuidedShot, to targetID: UUID) {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard source.id != targetID else { return }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let sourceIndex = allGuidedShots.firstIndex(where: { $0.id == source.id }),
                  let targetIndex = allGuidedShots.firstIndex(where: { $0.id == targetID }) else { return }

            let sourceShot = allGuidedShots[sourceIndex].shot
            let sourceCompleted = allGuidedShots[sourceIndex].isCompleted
            let sourceReferenceID = allGuidedShots[sourceIndex].referenceImageLocalIdentifier
            let sourceReferencePath = allGuidedShots[sourceIndex].referenceImagePath
            let now = Date()
            let sessionID = appState.currentSession?.id

            allGuidedShots[targetIndex].shot = sourceShot
            allGuidedShots[targetIndex].isCompleted = sourceCompleted
            allGuidedShots[targetIndex].skipReason = nil
            allGuidedShots[targetIndex].skipReasonNote = nil
            allGuidedShots[targetIndex].skipSessionID = nil
            if let sourceShot {
                allGuidedShots[targetIndex].referenceImageLocalIdentifier = sourceShot.imageLocalIdentifier ?? sourceReferenceID
                allGuidedShots[targetIndex].referenceImagePath = sourceShot.imageLocalIdentifier ?? sourceReferencePath
            }
            allGuidedShots[targetIndex].reassignedFromGuidedShotID = source.id
            allGuidedShots[targetIndex].reassignedAt = now
            allGuidedShots[targetIndex].reassignedInSessionID = sessionID

            allGuidedShots[sourceIndex].shot = nil
            allGuidedShots[sourceIndex].isCompleted = false
            allGuidedShots[sourceIndex].skipReason = nil
            allGuidedShots[sourceIndex].skipReasonNote = nil
            allGuidedShots[sourceIndex].skipSessionID = nil
            allGuidedShots[sourceIndex].reassignedToGuidedShotID = targetID
            allGuidedShots[sourceIndex].reassignedAt = now
            allGuidedShots[sourceIndex].reassignedInSessionID = sessionID

            if armedGuidedShotID == source.id {
                clearGuidedAndRetakeArming()
                retakeContext = nil
                currentCaptureIntent = .free
                guidedReferenceAssetLocalID = nil
                guidedReferenceThumbnail = nil
                showGuidedAlignmentOverlay = false
            }

            _ = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            refreshGuidedShots()
            guidedThumbnailRefreshToken = UUID()
            refreshSessionActionsSummaryIfVisible()
        } catch {
            print("Failed to reassign guided shot: \(error)")
        }
    }

    private func updateGuidedShotLabel(_ guidedShot: GuidedShot, detailLabel: String) {
        guard let propertyID = appState.selectedPropertyID else { return }
        let trimmed = detailLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == guidedShot.id }) else { return }
            allGuidedShots[idx].detailType = trimmed
            let recomputed = Self.conciseContextLabel(
                building: allGuidedShots[idx].building,
                elevation: allGuidedShots[idx].targetElevation,
                detailType: trimmed
            )
            allGuidedShots[idx].title = recomputed.isEmpty ? trimmed : recomputed
            allGuidedShots[idx].labelEditedAt = Date()
            allGuidedShots[idx].labelEditedInSessionID = appState.currentSession?.id

            _ = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            refreshGuidedShots()
            refreshSessionActionsSummaryIfVisible()
        } catch {
            print("Failed to update guided label: \(error)")
        }
    }

    private func applyArmedGuidedShotIfNeeded(with shot: Shot, referenceImagePath: String?) -> Bool {
        guard let armedID = armedGuidedShotID else { return false }
        guard let propertyID = appState.selectedPropertyID else {
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            retakeContext = nil
            currentCaptureIntent = .free
            return false
        }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == armedID }) else {
                armedGuidedShotID = nil
                armedGuidedRetakeShotID = nil
                retakeContext = nil
                currentCaptureIntent = .free
                return false
            }

            let isRetake = armedGuidedRetakeShotID != nil
            if isRetake {
                guard allGuidedShots[idx].shot?.id == armedGuidedRetakeShotID else {
                    armedGuidedShotID = nil
                    armedGuidedRetakeShotID = nil
                    retakeContext = nil
                    currentCaptureIntent = .free
                    return false
                }
            } else if isShotCapturedInCurrentSession(allGuidedShots[idx].shot) {
                armedGuidedShotID = nil
                armedGuidedRetakeShotID = nil
                retakeContext = nil
                currentCaptureIntent = .free
                return false
            }

            allGuidedShots[idx].shot = shot
            allGuidedShots[idx].isCompleted = true
            let existingReferencePath = allGuidedShots[idx].referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let existingReferenceID = allGuidedShots[idx].referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingReferencePath.isEmpty && existingReferenceID.isEmpty {
                let fallbackReference = (referenceImagePath ?? shot.imageLocalIdentifier)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !fallbackReference.isEmpty {
                    allGuidedShots[idx].referenceImageLocalIdentifier = fallbackReference
                    allGuidedShots[idx].referenceImagePath = fallbackReference
                }
            }
            allGuidedShots[idx].skipReason = nil
            allGuidedShots[idx].skipReasonNote = nil
            allGuidedShots[idx].skipSessionID = nil
            if allGuidedShots[idx].angleIndex == nil || allGuidedShots[idx].angleIndex == 0 {
                allGuidedShots[idx].angleIndex = 1
            }
            let normalizedGuidedShots = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            guidedShots = normalizedGuidedShots
            refreshSessionActionsSummaryIfVisible()

            if isRetake {
                refreshLinkedIssuePhotos(for: shot, propertyID: propertyID)
            }

            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            retakeContext = nil
            currentCaptureIntent = .free
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            showGuidedAlignmentOverlay = false
            return true
        } catch {
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            retakeContext = nil
            currentCaptureIntent = .free
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            showGuidedAlignmentOverlay = false
            return false
        }
    }

    private func createGuidedAngleFromCaptureIfNeeded(with shot: Shot, referenceImagePath: String?) {
        guard let propertyID = appState.selectedPropertyID else { return }

        let building = selectedBuilding.trimmingCharacters(in: .whitespacesAndNewlines)
        let elevationValue = elevation.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailTypeValue = currentDetailType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !building.isEmpty, !elevationValue.isEmpty, !detailTypeValue.isEmpty else { return }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)

            let matching = allGuidedShots.filter {
                Self.normalizeGuidedPart($0.building) == Self.normalizeGuidedPart(building) &&
                Self.normalizeGuidedPart($0.targetElevation) == Self.normalizeGuidedPart(elevationValue) &&
                Self.normalizeGuidedPart($0.detailType) == Self.normalizeGuidedPart(detailTypeValue)
            }

            let nextAngle = (matching.map { max(1, $0.angleIndex ?? 1) }.max() ?? 0) + 1
            let contextTitle = guidedContextLabel(building: building, elevation: elevationValue, detailType: detailTypeValue)

            let guided = GuidedShot(
                title: contextTitle,
                building: building,
                targetElevation: elevationValue,
                detailType: detailTypeValue,
                angleIndex: nextAngle,
                referenceImageLocalIdentifier: nil,
                referenceImagePath: nil,
                shot: shot,
                isCompleted: true
            )
            allGuidedShots.append(guided)
            let normalizedGuidedShots = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
            guidedShots = normalizedGuidedShots
        } catch {
            // Keep capture resilient if guided persistence fails.
        }
    }

    private func guidedContextLabel(building: String, elevation: String, detailType: String) -> String {
        Self.conciseContextLabel(
            building: building,
            elevation: elevation,
            detailType: detailType
        )
    }

    private static func normalizeGuidedPart(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func normalizedGuidedShotsWithStableAngles(_ guidedShots: [GuidedShot]) -> [GuidedShot] {
        var normalized = guidedShots
        let groupedIndices = Dictionary(grouping: normalized.indices) { index in
            let item = normalized[index]
            return [
                Self.normalizeGuidedPart(item.building),
                Self.normalizeGuidedPart(CanonicalElevation.normalize(item.targetElevation) ?? item.targetElevation),
                Self.normalizeGuidedPart(item.detailType)
            ].joined(separator: "|")
        }

        for indices in groupedIndices.values {
            guard !indices.isEmpty else { continue }

            let orderedIndices = indices.sorted { lhs, rhs in
                let left = normalized[lhs]
                let right = normalized[rhs]
                let leftAngle = max(0, left.angleIndex ?? 0)
                let rightAngle = max(0, right.angleIndex ?? 0)
                if leftAngle != rightAngle { return leftAngle < rightAngle }
                let leftCapturedAt = left.shot?.capturedAt ?? .distantPast
                let rightCapturedAt = right.shot?.capturedAt ?? .distantPast
                if leftCapturedAt != rightCapturedAt { return leftCapturedAt < rightCapturedAt }
                return left.id.uuidString < right.id.uuidString
            }

            var usedAngles = Set<Int>()
            var nextAngle = 1

            for index in orderedIndices {
                let currentAngle = normalized[index].angleIndex ?? 0
                let assignedAngle: Int
                if currentAngle > 0 && !usedAngles.contains(currentAngle) {
                    assignedAngle = currentAngle
                } else {
                    while usedAngles.contains(nextAngle) {
                        nextAngle += 1
                    }
                    assignedAngle = nextAngle
                }
                normalized[index].angleIndex = assignedAngle
                usedAngles.insert(assignedAngle)
            }
        }

        return normalized
    }

    private func visibleGuidedShots(from guidedShots: [GuidedShot]) -> [GuidedShot] {
        guidedShots.filter { !$0.isRetired && $0.status != .retired }
    }

    private func saveNormalizedGuidedShots(_ guidedShots: [GuidedShot], propertyID: UUID) throws -> [GuidedShot] {
        let normalized = Self.normalizedGuidedShotsWithStableAngles(guidedShots)
        try localStore.saveGuidedShots(normalized, propertyID: propertyID)
        if let sessionID = appState.currentSession?.id {
            try? localStore.syncGuidedShotsToSessionMetadata(
                propertyID: propertyID,
                sessionID: sessionID,
                guidedShots: normalized
            )
        }
        return normalized
    }

    private func writeGuidedReferenceImage(data: Data, guidedShotID: UUID) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.60) else { return nil }

        let fileManager = FileManager.default
        let base = localStore.rootURL()
        let referencesDir = base.appendingPathComponent("guided-references", isDirectory: true)
        let fileURL = referencesDir.appendingPathComponent("\(guidedShotID.uuidString).jpg")

        do {
            if !fileManager.fileExists(atPath: referencesDir.path) {
                try fileManager.createDirectory(at: referencesDir, withIntermediateDirectories: true)
            }
            try jpeg.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }

    private func refreshLinkedIssuePhotos(for shot: Shot, propertyID: UUID) {
        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            var didUpdate = false
            for existing in observations {
                let hasLinkedShot = existing.linkedShotID == shot.id
                let hasShotInHistory = existing.shots.contains(where: { $0.id == shot.id })
                guard hasLinkedShot || hasShotInHistory else { continue }

                var updated = existing
                var replaced = false
                for index in updated.shots.indices {
                    if updated.shots[index].id == shot.id {
                        updated.shots[index] = shot
                        replaced = true
                    }
                }
                if hasLinkedShot && !replaced {
                    updated.shots.append(shot)
                }

                _ = try localStore.updateObservation(updated)
                didUpdate = true
            }
            if didUpdate {
                refreshActiveIssues()
            }
        } catch {
            // Keep retake workflow resilient if issue-photo sync fails.
        }
    }

    private func inferElevation(from title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains(" n ") || lower.hasSuffix(" n") || lower.hasPrefix("n ") { return "North" }
        if lower.contains(" s ") || lower.hasSuffix(" s") || lower.hasPrefix("s ") { return "South" }
        if lower.contains(" e ") || lower.hasSuffix(" e") || lower.hasPrefix("e ") { return "East" }
        if lower.contains(" w ") || lower.hasSuffix(" w") || lower.hasPrefix("w ") { return "West" }
        if lower.contains("front") { return "North" }
        if lower.contains("rear") || lower.contains("back") { return "South" }
        if lower.contains("left") { return "West" }
        if lower.contains("right") { return "East" }
        return nil
    }

    private func loadGuidedReferenceThumbnail(referencePath: String?, localIdentifier: String?) {
        let path = referencePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty, let image = UIImage(contentsOfFile: path) {
            guidedReferenceAssetLocalID = path
            guidedReferenceThumbnail = image
            return
        }

        let id = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            return
        }
        guidedReferenceAssetLocalID = id
        guard let asset = Self.reportAsset(from: id) else {
            guidedReferenceThumbnail = nil
            return
        }
        let px = max(180, 88 * UIScreen.currentScale * 2.0)
        imageCache.requestThumbnail(for: asset, pixelSize: px) { image in
            DispatchQueue.main.async {
                guard guidedReferenceAssetLocalID == id else { return }
                guidedReferenceThumbnail = image
            }
        }
    }
    
    private func ensureCameraSessionPrecondition() {
        guard hasValidCurrentSession else {
            guard !didTriggerExitToHubForMissingSession else { return }
            didTriggerExitToHubForMissingSession = true
            DispatchQueue.main.async {
                onExitToHub?()
            }
            return
        }
        didTriggerExitToHubForMissingSession = false
    }

    private func presentSessionActionsSheet() {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard let currentSession = appState.currentSession else {
            print("[EndSession] no active session")
            return
        }
        if pendingCaptureSaveCount > 0 {
            deferredSessionActionsRequest = true
            print("[EndSession] waiting for pending saves count=\(pendingCaptureSaveCount)")
            return
        }

        let guided = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []

        let flaggedRemaining = flaggedPendingCaptureCount
        let persisted = persistedGuidedSummary(propertyID: propertyID, sessionID: currentSession.id)
        let guidedRemaining = guidedRemainingForCompass
        let hasBaseline = appState.propertyHasBaseline(propertyID)
        let currentSessionCaptureCount = currentSessionPhotoCount(propertyID: propertyID)
        let reExportEligibleNow = appState.isReExportEligible(currentSession)
        let isPendingDelivery = appState.isPendingDelivery(currentSession)

        print(
            "[EndSession] sessionID=\(currentSession.id.uuidString) " +
            "metadataShots=\(persisted.metadataShotCount) guidedCount=\(guided.count) guidedRemaining=\(guidedRemaining) flaggedRemaining=\(flaggedRemaining)"
        )
        let liveGuidedCount = guidedRemainingForCompass
        print("[Badge] beforeOpen guidedCount=\(liveGuidedCount) flaggedCount=\(flaggedPendingCaptureCount)")

        sessionActionsSummary = SessionActionsSummary(
            guidedRemainingCount: guidedRemaining,
            flaggedRemainingCount: flaggedRemaining,
            hasBaseline: hasBaseline,
            currentSessionCaptureCount: currentSessionCaptureCount,
            isSessionSealed: currentSession.isSealed,
            firstDeliveredAt: currentSession.firstDeliveredAt,
            reExportExpiresAt: currentSession.reExportExpiresAt,
            reExportEligibleNow: reExportEligibleNow
        )
        if let reason = sessionActionsSummary?.exportDisabledReason {
            print("[ExportEligibility] sessionID=\(currentSession.id.uuidString) enabled=false reason=\(reason)")
        } else {
            print("[ExportEligibility] sessionID=\(currentSession.id.uuidString) enabled=true")
        }
        print("[ExportUI] sessionID=\(currentSession.id.uuidString) isPendingDelivery=\(isPendingDelivery) isReExportEligible=\(reExportEligibleNow)")
        showSessionActionsSheet = true
        let liveGuidedCountAfter = guidedRemainingForCompass
        print("[Badge] afterOpen guidedCount=\(liveGuidedCountAfter) flaggedCount=\(flaggedPendingCaptureCount)")
    }

    private func carryoverFlaggedRemainingCount(observations: [Observation]) -> Int {
        guard let session = appState.currentSession else { return 0 }
        let sessionID = session.id
        return observations.filter { observation in
            observation.status == .active &&
            observation.createdAt < session.startedAt &&
            observation.updatedInSessionID != sessionID
        }.count
    }

    private func currentSessionPhotoCount(propertyID: UUID) -> Int {
        guard let sessionID = appState.currentSession?.id else { return 0 }
        let persisted = persistedGuidedSummary(propertyID: propertyID, sessionID: sessionID)
        return persisted.metadataShotCount
    }

    private func persistedGuidedSummary(propertyID: UUID, sessionID: UUID) -> (remaining: Int, metadataShotCount: Int) {
        guard let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID) else {
            let fallbackGuided = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
            let fallbackRemaining = fallbackGuided.filter {
                !isGuidedShotSkippedInCurrentSession($0) && !isShotCapturedInCurrentSession($0.shot)
            }.count
            return (fallbackRemaining, 0)
        }

        let sessionFolder = localStore.sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
        let capturedShotKeys = Set(metadata.shots.compactMap { shot -> String? in
            let originalRelative = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalRelative.isEmpty else { return nil }
            let originalURL = sessionFolder.appendingPathComponent(originalRelative, isDirectory: false)
            guard FileManager.default.fileExists(atPath: originalURL.path) else { return nil }
            return shot.shotKey
        })

        let guided = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
        let remaining = guided.filter { guidedShot in
            if isGuidedShotSkippedInCurrentSession(guidedShot) {
                return false
            }
            let angle = max(1, guidedShot.angleIndex ?? 1)
            let shotKey = ShotMetadata.makeShotKey(
                building: guidedShot.building ?? "",
                elevation: guidedShot.targetElevation ?? "",
                detailType: guidedShot.detailType ?? "",
                angleIndex: angle
            )
            return !capturedShotKeys.contains(shotKey)
        }.count

        return (remaining, metadata.shots.count)
    }

    private func isGuidedShotSkippedInCurrentSession(_ guidedShot: GuidedShot) -> Bool {
        guard let sessionID = appState.currentSession?.id else { return false }
        return guidedShot.skipReason != nil && guidedShot.skipSessionID == sessionID
    }

    private func isGuidedShotHandledInCurrentSession(_ guidedShot: GuidedShot) -> Bool {
        isShotCapturedInCurrentSession(guidedShot.shot) || isGuidedShotSkippedInCurrentSession(guidedShot)
    }

    private func capturedImageLocalIdentifierForCurrentSession(_ observation: Observation) -> String? {
        guard let currentSessionID = appState.currentSession?.id else { return nil }
        let hasCurrentSessionCapture = observation.updatedInSessionID == currentSessionID || observation.resolvedInSessionID == currentSessionID
        guard hasCurrentSessionCapture else { return nil }
        guard let linkedID = observation.linkedShotID else { return nil }
        let localID = observation.shots.first(where: { $0.id == linkedID })?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return localID.isEmpty ? nil : localID
    }

    private func refreshSessionActionsSummaryIfVisible() {
        guard showSessionActionsSheet else { return }
        presentSessionActionsSheet()
    }

    private func isShotCapturedInCurrentSession(_ shot: Shot?) -> Bool {
        guard let shot else { return false }
        guard activeSessionShotIDs.contains(shot.id) else { return false }
        let path = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, Self.reportAsset(from: path) != nil else {
            return false
        }
        return true
    }

    private func sessionShotIDsForActiveSession(propertyID: UUID, sessionID: UUID?) -> Set<UUID> {
        let filtered = sessionMetadataForActiveSession(propertyID: propertyID, sessionID: sessionID)?.shots ?? []
        return Set(filtered.map(\.shotID))
    }

    private func sessionMetadataForActiveSession(propertyID: UUID, sessionID: UUID?) -> SessionMetadata? {
        guard let sessionID else { return nil }
        let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        guard metadata?.propertyID == propertyID, metadata?.sessionID == sessionID else { return nil }
        return metadata
    }

    private func resolvedSessionImagePath(
        for shot: ShotMetadata,
        propertyID: UUID,
        sessionID: UUID
    ) -> (absolutePath: String?, source: String, relativePath: String, exists: Bool) {
        let sessionFolder = localStore.sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
        if let stamped = shot.stampedRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines), !stamped.isEmpty {
            let stampedURL = sessionFolder.appendingPathComponent(stamped)
            let stampedExists = FileManager.default.fileExists(atPath: stampedURL.path)
            if stampedExists {
                print("[StampedResolve] metadataPath=\(stamped) exists=true fallbackPath=NONE exists=false chosen=\(stampedURL.path)")
                return (stampedURL.path, "stamped", stamped, true)
            }
            let fallbackRelative = "Stamped/\(shot.shotID.uuidString).jpg"
            let fallbackURL = sessionFolder.appendingPathComponent(fallbackRelative)
            let fallbackExists = FileManager.default.fileExists(atPath: fallbackURL.path)
            if fallbackExists {
                print("[StampedResolve] metadataPath=\(stamped) exists=false fallbackPath=\(fallbackRelative) exists=true chosen=\(fallbackURL.path)")
                return (fallbackURL.path, "stamped", fallbackRelative, true)
            }
            print("[StampedResolve] metadataPath=\(stamped) exists=false fallbackPath=\(fallbackRelative) exists=false chosen=NONE")
        }

        let originalRelative = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !originalRelative.isEmpty {
            let originalURL = sessionFolder.appendingPathComponent(originalRelative)
            let originalExists = FileManager.default.fileExists(atPath: originalURL.path)
            if originalExists {
                return (originalURL.path, "original", originalRelative, true)
            }
            return (nil, "original", originalRelative, false)
        }

        return (nil, "placeholder", "", false)
    }

    private func startExportNowFlow() {
        guard !isPreparingSessionExport else { return }
        if let summary = sessionActionsSummary,
           (!summary.isExportActionEnabled || summary.hasOutstandingChecklistItems) {
            return
        }
        showSessionExportErrorPopup = false
        sessionExportErrorMessage = nil
        isPreparingSessionExport = true
        sessionExportChecklist = ExportChecklistState()
        prepareSessionExportReferences()
        appState.sealCurrentSessionForExportNow()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try buildSessionExportArchive(progress: { step in
                    DispatchQueue.main.async {
                        switch step {
                        case .originals:
                            sessionExportChecklist.originalsComplete = true
                        case .sessionData:
                            sessionExportChecklist.sessionDataComplete = true
                        case .zipReady:
                            sessionExportChecklist.zipReady = true
                        }
                    }
                })
                DispatchQueue.main.async {
                    isPreparingSessionExport = false
                    showSessionActionsSheet = false
                    awaitingSessionExportDismiss = true
                    sessionExportFile = SessionExportFile(url: url)
                }
            } catch {
                DispatchQueue.main.async {
                    isPreparingSessionExport = false
                    showSessionActionsSheet = false
                    sessionExportErrorMessage = error.localizedDescription
                    showSessionExportErrorPopup = true
                }
            }
        }
    }

    private func handleSaveDraftAndExit(summary: SessionActionsSummary) {
        _ = summary
        resetSelectionForSwitch()
        camera.updateDetailNoteActive(false)
        appState.saveDraftCurrentSession()
        appState.refreshProperties()
        showSessionActionsSheet = false
        onExitToHub?()
    }

    private func handleExportLaterAndExit(summary: SessionActionsSummary) {
        guard summary.isExportLaterEnabled else { return }
        appState.sealCurrentSessionForExportLater()
        appState.refreshProperties()
        showSessionActionsSheet = false
        onExitToHub?()
    }

    private func ensureGuidedReferencePaths(propertyID: UUID) {
        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            var didChange = false

            for index in allGuidedShots.indices {
                let existingPath = allGuidedShots[index].referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !existingPath.isEmpty { continue }

                let localID = (allGuidedShots[index].referenceImageLocalIdentifier ??
                               allGuidedShots[index].shot?.imageLocalIdentifier)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !localID.isEmpty else { continue }
                guard let imageData = originalImageData(for: localID) else { continue }
                guard let path = writeGuidedReferenceImage(data: imageData, guidedShotID: allGuidedShots[index].id) else { continue }

                allGuidedShots[index].referenceImagePath = path
                if allGuidedShots[index].referenceImageLocalIdentifier == nil {
                    allGuidedShots[index].referenceImageLocalIdentifier = localID
                }
                didChange = true
            }

            if didChange {
                let normalizedGuidedShots = try saveNormalizedGuidedShots(allGuidedShots, propertyID: propertyID)
                if appState.selectedPropertyID == propertyID {
                    guidedShots = normalizedGuidedShots
                }
            }
        } catch {
            // Keep export flow resilient if reference backfill fails.
        }
    }

    private func originalImageData(for localIdentifier: String) -> Data? {
        let trimmed = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: trimmed))
    }

    private func prepareSessionExportReferences() {
        _ = reportLibrary.assets.count
        guard let propertyID = appState.selectedPropertyID else { return }
        _ = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
        _ = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
    }

    private enum ExportChecklistStep {
        case originals
        case sessionData
        case zipReady
    }

    private func buildSessionExportArchive(progress: ((ExportChecklistStep) -> Void)? = nil) throws -> URL {
        let fileManager = FileManager.default
        let assets = reportLibrary.assets
        guard let propertyID = appState.selectedPropertyID,
              let session = appState.currentSession else {
            throw NSError(domain: "ScoutCapture.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active session for export."])
        }
        let sessionID = session.id
        let exportArtifacts = try localStore.validatedSessionExportArtifacts(for: session)
        let propertyFolderName = try localStore.exportPropertyFolderName(propertyID: propertyID)
        let exportRoot = try StorageRoot.makeSessionExportRootFolder(
            propertyFolderName: propertyFolderName,
            sessionID: sessionID
        )
        let originalsRoot = exportRoot.appendingPathComponent("Originals", isDirectory: true)
        try fileManager.createDirectory(at: originalsRoot, withIntermediateDirectories: true)

        var expectedPaths = Set([
            "session.json",
            "validation.txt",
            "sessions.csv",
            "shots.csv",
            "issues.csv",
            "issue_history.csv",
            "guided_rows.csv",
            "Originals/"
        ])
        for (index, asset) in assets.enumerated() {
            guard let data = requestSessionExportImageData(for: asset) else { continue }
            let filename = sessionExportFilename(for: asset, index: index + 1)
            let attrs = try? fileManager.attributesOfItem(atPath: asset.fileURL.path)
            let modifiedAt = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date)
            let destinationURL = originalsRoot.appendingPathComponent(filename)
            try data.write(to: destinationURL, options: .atomic)
            if let modifiedAt {
                try? fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationURL.path)
            }
            expectedPaths.insert("Originals/\(filename)")
        }
        try exportArtifacts.sessionData.write(to: exportRoot.appendingPathComponent("session.json"), options: .atomic)
        try exportArtifacts.validationData.write(to: exportRoot.appendingPathComponent("validation.txt"), options: .atomic)
        for csvFile in localStore.exportCSVFiles(for: exportArtifacts.metadata) {
            try csvFile.data.write(to: exportRoot.appendingPathComponent(csvFile.filename), options: .atomic)
        }
        progress?(.originals)

#if DEBUG
        let sourceURL = localStore.sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
        let exists = FileManager.default.fileExists(atPath: sourceURL.path)
        let sizeBytes = ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
        print("Export session.json path source: \(sourceURL.path)")
        print("Export source exists: \(exists ? "YES" : "NO"), bytes: \(sizeBytes)")
        let raw = String(data: exportArtifacts.sessionData, encoding: .utf8) ?? ""
        print("Export sessionData contains \"shotKey\": \(raw.contains("\"shotKey\"") ? "YES" : "NO")")
        print("Export sessionData contains \"originalRelativePath\": \(raw.contains("\"originalRelativePath\"") ? "YES" : "NO")")
        let debugDecoder = JSONDecoder()
        debugDecoder.dateDecodingStrategy = .iso8601
        if let decoded = try? debugDecoder.decode(SessionMetadata.self, from: exportArtifacts.sessionData),
           let first = decoded.shots.first {
            print("Export sessionStartedAt: \(decoded.startedAt)")
            print("Export sessionStartedAtLocal: \(decoded.sessionStartedAtLocal)")
            print("Export first shot shotKey: \(first.shotKey)")
            print("Export first shot createdAt: \(first.createdAt)")
            print("Export first shot createdAtLocal: \(first.capturedAtLocal ?? "nil")")
            print("Export first shot originalRelativePath: \(first.originalRelativePath)")
            if let delivered = decoded.firstDeliveredAt {
                print("Export firstDeliveredAt: \(delivered)")
            }
            if let expires = decoded.reExportExpiresAt {
                print("Export reExportExpiresAt: \(expires)")
            }
        }
        print("EXPORT ROOT: \(exportRoot.path)")
        print("EXPORT ROOT FILES: \((try? StorageRoot.exportRootFilenames(exportRoot)) ?? [])")
#endif
        progress?(.sessionData)

        let zipEntries = try StorageRoot.zipEntriesForExportRoot(exportRoot).map { ($0.path, $0.data, $0.modifiedAt) }
        let zipData = buildSessionExportZipData(entries: zipEntries)
        let finalURL = fileManager.temporaryDirectory.appendingPathComponent(sessionExportZipFilename())
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp.zip")
#if DEBUG
        print("Export ZIP temp path: \(tempURL.path)")
        print("Export ZIP final path: \(finalURL.path)")
#endif
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try zipData.write(to: tempURL, options: [.atomic])
        let tempExists = fileManager.fileExists(atPath: tempURL.path)
        let tempSize = ((try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("Export ZIP temp exists: \(tempExists ? "YES" : "NO"), bytes: \(tempSize)")
#endif
        guard tempExists, tempSize > 0 else {
            throw NSError(domain: "ScoutCapture.Export", code: 5, userInfo: [NSLocalizedDescriptionKey: "Temporary ZIP write failed."])
        }

        try fileManager.moveItem(at: tempURL, to: finalURL)
        let finalExists = fileManager.fileExists(atPath: finalURL.path)
        let finalSize = ((try? fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("Export ZIP final exists: \(finalExists ? "YES" : "NO"), bytes: \(finalSize)")
#endif
        guard finalExists, finalSize > 0 else {
            throw NSError(domain: "ScoutCapture.Export", code: 6, userInfo: [NSLocalizedDescriptionKey: "Final ZIP write failed."])
        }

        let listedEntries = try listSessionExportZipEntryPaths(at: finalURL)
#if DEBUG
        let preview = Array(listedEntries.prefix(12))
        print("Export ZIP entries count: \(listedEntries.count)")
        print("Export ZIP entries preview: \(preview)")
#endif
        let zipRootFolderName = exportRoot.deletingLastPathComponent().lastPathComponent
        let normalizedExpectedPaths = Set(expectedPaths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        let actualPaths = Set(listedEntries.compactMap { path -> String? in
            let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty else { return nil }
            if normalized == zipRootFolderName { return nil }
            let prefix = "\(zipRootFolderName)/"
            if normalized.hasPrefix(prefix) {
                return String(normalized.dropFirst(prefix.count))
            }
            return normalized
        })
        guard normalizedExpectedPaths.isSubset(of: actualPaths) else {
            throw NSError(domain: "ScoutCapture.Export", code: 7, userInfo: [NSLocalizedDescriptionKey: "ZIP integrity check failed."])
        }
#if DEBUG
        guard actualPaths.contains("session.json"), actualPaths.contains("validation.txt") else {
            assertionFailure("Export ZIP root missing session.json or validation.txt")
            throw NSError(domain: "ScoutCapture.Export", code: 10, userInfo: [NSLocalizedDescriptionKey: "ZIP root missing validation artifacts."])
        }
        if !exportArtifacts.prewritePassed || !exportArtifacts.postwritePassed {
            assertionFailure(String(data: exportArtifacts.validationData, encoding: .utf8) ?? "Export validation failed")
        }
#endif
        progress?(.zipReady)
        return finalURL
    }

    private func requestSessionExportImageData(for asset: ReportAsset) -> Data? {
        try? Data(contentsOf: asset.fileURL)
    }

    private func ensureSessionStampedJPEGs(
        propertyID: UUID,
        sessionID: UUID,
        propertyAddress: String?,
        assets: [ReportAsset]
    ) throws -> [String: URL] {
        let fileManager = FileManager.default
        let originalsByName = Dictionary(uniqueKeysWithValues: assets.map { ($0.originalFilename, $0) })
        var metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        var didUpdateMetadata = false
        var output: [String: URL] = [:]
        let selectedPropertyName = appState.selectedProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let propertyName = selectedPropertyName.isEmpty ? "Property" : selectedPropertyName
        var reservedNames = Set(
            ((try? fileManager.contentsOfDirectory(atPath: localStore.stampedDirectoryURL(propertyID: propertyID, sessionID: sessionID).path)) ?? [])
                .map { $0.lowercased() }
        )

        for index in metadata.shots.indices {
            let shot = metadata.shots[index]
            let originalName = shot.originalFilename
            guard let asset = originalsByName[originalName] else { continue }

            let existingStampedName = shot.stampedFilename?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let canonicalStampedName: String = {
                let existingLeaf = URL(fileURLWithPath: existingStampedName).lastPathComponent
                if !existingLeaf.isEmpty {
                    let normalized = existingLeaf.lowercased().hasSuffix(".jpg")
                        ? existingLeaf
                        : "\(URL(fileURLWithPath: existingLeaf).deletingPathExtension().lastPathComponent).jpg"
                    if !reservedNames.contains(normalized.lowercased()) {
                        reservedNames.insert(normalized.lowercased())
                        return normalized
                    }
                }
                return nextReadableStampedFilename(
                    shot: shot,
                    reservedNames: &reservedNames
                )
            }()
            if metadata.shots[index].stampedFilename != canonicalStampedName {
                metadata.shots[index].stampedFilename = canonicalStampedName
                didUpdateMetadata = true
            }
            let canonicalStampedRelative = "Stamped/\(canonicalStampedName)"
            if metadata.shots[index].stampedRelativePath != canonicalStampedRelative {
                metadata.shots[index].stampedRelativePath = canonicalStampedRelative
                didUpdateMetadata = true
            }
            if (metadata.shots[index].imageWidth ?? 0) <= 0 || (metadata.shots[index].imageHeight ?? 0) <= 0 {
                let sourceImage = UIImage(contentsOfFile: asset.fileURL.path)
                if let sourceImage {
                    metadata.shots[index].imageWidth = max(1, Int(sourceImage.size.width))
                    metadata.shots[index].imageHeight = max(1, Int(sourceImage.size.height))
                    didUpdateMetadata = true
                }
            }

            let stampedURL = localStore.stampedDirectoryURL(propertyID: propertyID, sessionID: sessionID)
                .appendingPathComponent(canonicalStampedName, isDirectory: false)
            let captureDate = metadata.shots[index].updatedAt
            try createStampedJPEGIfMissing(
                sourceURL: asset.fileURL,
                destinationURL: stampedURL,
                captureDate: captureDate,
                overlayLines: stampOverlayLines(
                    propertyName: propertyName,
                    shot: metadata.shots[index],
                    isBaselineSession: metadata.isBaselineSession
                ),
                metadataContext: stampedMetadataContext(
                    propertyID: propertyID,
                    sessionID: sessionID,
                    shot: metadata.shots[index],
                    propertyName: propertyName,
                    propertyAddress: propertyAddress,
                    schemaVersion: metadata.schemaVersion
                ),
                fileManager: fileManager
            )
            let metadataRelative = metadata.shots[index].stampedRelativePath ?? "nil"
            let sessionFolder = localStore.sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            let metadataURL = sessionFolder.appendingPathComponent(metadataRelative)
            let metadataPathExists = fileManager.fileExists(atPath: metadataURL.path)
            print("[Stamp] wrote stamped destination=\(stampedURL.path)")
            print("[Stamp] metadata stampedRelativePath=\(metadataRelative)")
            print("[Stamp] metadata resolved exists=\(metadataPathExists)")
            output[originalName] = stampedURL
        }

        if didUpdateMetadata {
            try localStore.saveSessionMetadataAtomically(
                propertyID: propertyID,
                sessionID: sessionID,
                metadata: metadata
            )
#if DEBUG
            if let firstStamped = metadata.shots.first?.stampedRelativePath {
                print("[Stamp] metadata stampedRelativePath sample=\(firstStamped)")
            }
#endif
        }

        return output
    }

    private func createStampedJPEGIfMissing(
        sourceURL: URL,
        destinationURL: URL,
        captureDate: Date,
        overlayLines: [String],
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path),
           ((try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0 > 0 {
            return
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let sourceData = try Data(contentsOf: sourceURL)
        let stampedData = try encodeStampedJPEGForExport(
            from: sourceData,
            captureDate: captureDate,
            overlayLines: overlayLines,
            metadataContext: metadataContext
        )
        try stampedData.write(to: destinationURL, options: [.atomic])

        let exists = fileManager.fileExists(atPath: destinationURL.path)
        let size = ((try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("[Stamp] destination=\(destinationURL.path) utType=\(UTType.jpeg.identifier) bytes=\(size)")
#endif
        guard exists, size > 0 else {
            throw NSError(domain: "ScoutCapture.Stamp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stamped JPEG write failed"])
        }

        try fileManager.setAttributes(
            [
                .creationDate: captureDate,
                .modificationDate: captureDate
            ],
            ofItemAtPath: destinationURL.path
        )
#if DEBUG
        if let attrs = try? fileManager.attributesOfItem(atPath: destinationURL.path) {
            let created = attrs[.creationDate] as? Date
            let modified = attrs[.modificationDate] as? Date
            print("[Stamp] readback creation=\(String(describing: created)) modification=\(String(describing: modified))")
        }
        if let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
            print("[Stamp] readback pixelWidth=\(width) pixelHeight=\(height) orientation=\(orientation)")
        }
#endif
    }

    private func encodeStampedJPEGForExport(
        from sourceData: Data,
        captureDate: Date,
        overlayLines: [String],
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw NSError(domain: "ScoutCapture.Stamp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing source image for stamped export"])
        }

        let sourceCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        let sourceProps = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let sourceOrientationRaw = (sourceProps[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let capturedOrientationRaw = metadataContext.capturedExifOrientationRaw
        let resolvedOrientationRaw = sourceOrientationRaw ?? capturedOrientationRaw ?? 1
        print("[Stamp] orientation capturedRaw=\(capturedOrientationRaw.map(String.init) ?? "nil") sourceRaw=\(sourceOrientationRaw.map(String.init) ?? "nil") resolvedRaw=\(resolvedOrientationRaw)")
        if let sourceCGImage {
            print("[Stamp] before encode pixelWidth=\(sourceCGImage.width) pixelHeight=\(sourceCGImage.height)")
        }
        let image = normalizedUprightCGImage(from: sourceData)
            ?? sourceCGImage
        guard let image else {
            throw NSError(domain: "ScoutCapture.Stamp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing source image for stamped export"])
        }
        print("[Stamp] after upright pixelWidth=\(image.width) pixelHeight=\(image.height)")
        var mergedProps = sourceProps
        var exif = (mergedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        var tiff = (mergedProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]

        let captureTime = ReportLibraryModel.EmbeddedCaptureTime(captureDate: captureDate)
        exif[kCGImagePropertyExifDateTimeOriginal] = captureTime.localDateTimeString
        exif[kCGImagePropertyExifDateTimeDigitized] = captureTime.localDateTimeString
        exif[kCGImagePropertyExifSubsecTimeOriginal] = captureTime.subsecString
        exif[kCGImagePropertyExifSubsecTimeDigitized] = captureTime.subsecString
        exif[kCGImagePropertyExifOffsetTimeOriginal] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifOffsetTimeDigitized] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifOffsetTime] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifUserComment] = scoutStructuredStampComment(captureTime: captureTime, metadataContext: metadataContext)
        tiff[kCGImagePropertyTIFFDateTime] = captureTime.localDateTimeString
        mergedProps[kCGImagePropertyExifDictionary] = exif
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        mergedProps[kCGImagePropertyOrientation] = 1
        tiff[kCGImagePropertyTIFFOrientation] = 1
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        mergedProps[kCGImageDestinationLossyCompressionQuality] = 0.90
        print("[Stamp] orientation writeTag exif/tiff=1")
        if let gps = makeStampedGPSDictionary(
            latitude: metadataContext.latitude,
            longitude: metadataContext.longitude,
            accuracyMeters: metadataContext.accuracyMeters,
            captureDate: captureDate
        ) {
            mergedProps[kCGImagePropertyGPSDictionary] = gps
        }
        let caption = overlayLines.joined(separator: "\n")
        if !caption.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription] = caption
            mergedProps[kCGImagePropertyTIFFDictionary] = tiff
            var iptc = (mergedProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            iptc[kCGImagePropertyIPTCCaptionAbstract] = caption
            iptc[kCGImagePropertyIPTCKeywords] = stampedKeywordList(metadataContext: metadataContext)
            mergedProps[kCGImagePropertyIPTCDictionary] = iptc
        }

        let stampedCGImage = drawStampOverlay(
            on: image,
            lines: overlayLines
        ) ?? image

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ScoutCapture.Stamp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create JPEG destination"])
        }
        if let xmpMetadata = buildStampedXMPMetadata(
            source: source,
            captureTime: captureTime,
            metadataContext: metadataContext
        ) {
            CGImageDestinationAddImageAndMetadata(
                destination,
                stampedCGImage,
                xmpMetadata,
                mergedProps as CFDictionary
            )
        } else {
            CGImageDestinationAddImage(destination, stampedCGImage, mergedProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ScoutCapture.Stamp", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize JPEG destination"])
        }
        return destinationData as Data
    }

    private func stampedMetadataContext(
        propertyID: UUID,
        sessionID: UUID,
        shot: ShotMetadata,
        propertyName: String,
        propertyAddress: String?,
        schemaVersion: Int
    ) -> ReportLibraryModel.EmbeddedMetadataContext {
        ReportLibraryModel.EmbeddedMetadataContext(
            propertyID: propertyID,
            propertyName: propertyName,
            propertyAddress: propertyAddress,
            sessionID: sessionID,
            shotID: shot.shotID,
            shotKey: shot.shotKey,
            building: shot.building,
            elevation: shot.elevation,
            detailType: shot.detailType,
            angleIndex: shot.angleIndex,
            isGuided: shot.isGuided,
            isFlagged: shot.isFlagged,
            issueStatus: shot.issueStatus,
            detailNote: shot.noteText,
            captureMode: shot.captureMode,
            lens: shot.lens,
            orientation: shot.exifOrientation.map { "exif:\($0)" } ?? shot.orientation,
            capturedExifOrientationRaw: shot.exifOrientation.flatMap(UInt32.init) ?? parseExifOrientationRaw(from: shot.orientation),
            latitude: shot.latitude,
            longitude: shot.longitude,
            accuracyMeters: shot.accuracyMeters,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            schemaVersion: schemaVersion
        )
    }

    private func parseExifOrientationRaw(from orientation: String?) -> UInt32? {
        let trimmed = orientation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let direct = UInt32(trimmed), direct >= 1, direct <= 8 {
            return direct
        }
        let prefix = "exif:"
        if trimmed.lowercased().hasPrefix(prefix),
           let value = UInt32(trimmed.dropFirst(prefix.count)),
           value >= 1, value <= 8 {
            return value
        }
        return nil
    }

    private func scoutStructuredStampComment(
        captureTime: ReportLibraryModel.EmbeddedCaptureTime,
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext
    ) -> String {
        var pairs: [String] = []
        func append(_ key: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                pairs.append("\(key)=\(trimmed)")
            }
        }
        append("propertyID", metadataContext.propertyID?.uuidString)
        append("propertyName", metadataContext.propertyName)
        append("propertyAddress", metadataContext.propertyAddress)
        append("sessionID", metadataContext.sessionID?.uuidString)
        append("shotID", metadataContext.shotID?.uuidString)
        append("shotKey", metadataContext.shotKey)
        append("building", metadataContext.building)
        append("elevation", metadataContext.elevation)
        append("detailType", metadataContext.detailType)
        append("angleIndex", metadataContext.angleIndex.map(String.init))
        append("captureMode", metadataContext.captureMode)
        append("lens", metadataContext.lens)
        append("orientation", metadataContext.orientation)
        append("captureDateLocal", captureTime.localDateTimeString)
        append("captureDateISO8601", captureTime.iso8601WithOffset)
        if let accuracy = metadataContext.accuracyMeters {
            append("gpsAccuracyMeters", String(format: "%.3f", accuracy))
        }
        return pairs.joined(separator: ";")
    }

    private func stampedKeywordList(metadataContext: ReportLibraryModel.EmbeddedMetadataContext) -> [String] {
        var keywords: [String] = ["SCOUT"]
        let values = [
            metadataContext.propertyName,
            metadataContext.building,
            metadataContext.elevation,
            metadataContext.detailType
        ]
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                keywords.append(trimmed)
            }
        }
        keywords.append(metadataContext.isGuided == true ? "Guided" : "Free")
        if metadataContext.isFlagged == true {
            keywords.append("Flagged")
        }
        if let angle = metadataContext.angleIndex {
            keywords.append("Angle \(angle)")
        }
        return Array(NSOrderedSet(array: keywords)) as? [String] ?? keywords
    }

    private func makeStampedGPSDictionary(
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?,
        captureDate: Date
    ) -> [CFString: Any]? {
        guard let latitude, let longitude else { return nil }
        var gps: [CFString: Any] = [:]
        gps[kCGImagePropertyGPSLatitude] = abs(latitude)
        gps[kCGImagePropertyGPSLatitudeRef] = latitude >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude] = abs(longitude)
        gps[kCGImagePropertyGPSLongitudeRef] = longitude >= 0 ? "E" : "W"
        gps[kCGImagePropertyGPSDateStamp] = Self.exportGPSDateFormatter.string(from: captureDate)
        gps[kCGImagePropertyGPSTimeStamp] = Self.exportGPSTimeFormatter.string(from: captureDate)
        if let accuracyMeters, accuracyMeters >= 0 {
            gps[kCGImagePropertyGPSHPositioningError] = accuracyMeters
        }
        return gps
    }

    private func buildStampedXMPMetadata(
        source: CGImageSource,
        captureTime: ReportLibraryModel.EmbeddedCaptureTime,
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext
    ) -> CGMutableImageMetadata? {
        let baseMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let mutable = baseMetadata.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        var registrationError: Unmanaged<CFError>?
        _ = CGImageMetadataRegisterNamespaceForPrefix(
            mutable,
            "https://scoutcapture.app/ns/1.0/" as CFString,
            "scout" as CFString,
            &registrationError
        )
        func setTag(_ path: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            let components = path.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return }
            let prefix = components[0]
            let name = components[1]
            let namespace: String
            switch prefix {
            case "xmp":
                namespace = "http://ns.adobe.com/xap/1.0/"
            case "scout":
                namespace = "https://scoutcapture.app/ns/1.0/"
            default:
                return
            }
            guard let tag = CGImageMetadataTagCreate(
                namespace as CFString,
                prefix as CFString,
                name as CFString,
                .string,
                trimmed as CFString
            ) else {
                return
            }
            CGImageMetadataSetTagWithPath(mutable, nil, path as CFString, tag)
        }
        setTag("xmp:CreateDate", captureTime.iso8601WithOffset)
        setTag("xmp:ModifyDate", captureTime.iso8601WithOffset)
        setTag("scout:propertyID", metadataContext.propertyID?.uuidString)
        setTag("scout:propertyName", metadataContext.propertyName)
        setTag("scout:propertyAddress", metadataContext.propertyAddress)
        setTag("scout:sessionID", metadataContext.sessionID?.uuidString)
        setTag("scout:shotID", metadataContext.shotID?.uuidString)
        setTag("scout:shotKey", metadataContext.shotKey)
        setTag("scout:building", metadataContext.building)
        setTag("scout:elevation", metadataContext.elevation)
        setTag("scout:detailType", metadataContext.detailType)
        setTag("scout:angleIndex", metadataContext.angleIndex.map(String.init))
        setTag("scout:isGuided", metadataContext.isGuided.map { $0 ? "true" : "false" })
        setTag("scout:isFlagged", metadataContext.isFlagged.map { $0 ? "true" : "false" })
        setTag("scout:captureMode", metadataContext.captureMode)
        setTag("scout:lens", metadataContext.lens)
        setTag("scout:orientation", metadataContext.orientation)
        setTag("scout:appVersion", metadataContext.appVersion)
        setTag("scout:osVersion", metadataContext.osVersion)
        setTag("scout:deviceModel", metadataContext.deviceModel)
        setTag("scout:schemaVersion", metadataContext.schemaVersion.map(String.init))
        setTag("scout:issueStatus", metadataContext.issueStatus)
        setTag("scout:issueNote", metadataContext.detailNote)
        if let accuracy = metadataContext.accuracyMeters {
            setTag("scout:gpsAccuracyMeters", String(format: "%.3f", accuracy))
        }
        return mutable
    }

    private static let exportGPSDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    private static let exportGPSTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func normalizedUprightCGImage(from sourceData: Data) -> CGImage? {
        guard let uiImage = UIImage(data: sourceData) else { return nil }
        let size = uiImage.size
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    private func drawStampOverlay(on image: CGImage, lines: [String]) -> CGImage? {
        guard !lines.isEmpty else { return image }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))

            let shortEdge = CGFloat(min(width, height))
            let sideInset = max(16, shortEdge * 0.025)
            let bottomInset = max(16, shortEdge * 0.025)
            let lineSpacing = max(2, shortEdge * 0.004)
            let cornerRadius = max(8, shortEdge * 0.016)
            let primarySize = max(14, shortEdge * 0.030)
            let secondarySize = max(12, shortEdge * 0.024)

            let styles: [(UIFont, UIColor)] = lines.enumerated().map { idx, _ in
                (idx == 0 ? UIFont.systemFont(ofSize: primarySize, weight: .semibold)
                          : UIFont.systemFont(ofSize: secondarySize, weight: .regular),
                 .white)
            }
            let attributed: [NSAttributedString] = zip(lines, styles).map { pair, style in
                NSAttributedString(
                    string: pair,
                    attributes: [
                        .font: style.0,
                        .foregroundColor: style.1
                    ]
                )
            }

            let maxTextWidth = size.width - (sideInset * 3)
            let lineSizes = attributed.map { text in
                text.boundingRect(
                    with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).integral.size
            }

            let textHeight = lineSizes.reduce(0) { $0 + $1.height } + (CGFloat(max(0, lineSizes.count - 1)) * lineSpacing)
            let textWidth = min(maxTextWidth, lineSizes.map(\.width).max() ?? maxTextWidth)
            let padX = max(8, shortEdge * 0.013)
            let padY = max(5, shortEdge * 0.009)
            let panelWidth = textWidth + (padX * 2)
            let panelHeight = textHeight + (padY * 2)
            let panelRect = CGRect(
                x: sideInset,
                y: size.height - bottomInset - panelHeight,
                width: panelWidth,
                height: panelHeight
            )

            let panelPath = UIBezierPath(roundedRect: panelRect, cornerRadius: cornerRadius)
            UIColor.black.withAlphaComponent(0.58).setFill()
            panelPath.fill()

            var y = panelRect.minY + padY
            for (idx, text) in attributed.enumerated() {
                let drawRect = CGRect(
                    x: panelRect.minX + padX,
                    y: y,
                    width: textWidth,
                    height: lineSizes[idx].height
                )
                text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += lineSizes[idx].height + lineSpacing
            }
        }

        return rendered.cgImage
    }

    private static let exportExifTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let exportExifSubsecFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "SSS"
        return formatter
    }()

    private static func exportExifOffsetString(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private func stampOverlayLines(propertyName: String, shot: ShotMetadata, isBaselineSession: Bool) -> [String] {
        let line1 = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [shot.building, shot.elevation, shot.detailType, "Angle \(max(1, shot.angleIndex))"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        let line3 = Self.exportOverlayDateFormatter.string(from: shot.updatedAt)
        let noteLine = (shot.noteText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line4 = (shot.isFlagged && !noteLine.isEmpty) ? noteLine : ""

        _ = isBaselineSession
        return [line1, detail, line3, line4].filter { !$0.isEmpty }
    }

    private func nextReadableStampedFilename(shot: ShotMetadata, reservedNames: inout Set<String>) -> String {
        let base = readableStampedBaseName(for: shot)
        var candidate = "\(base).jpg"
        var counter = 1
        while reservedNames.contains(candidate.lowercased()) {
            candidate = "\(base)_\(String(format: "%02d", counter)).jpg"
            counter += 1
        }
        reservedNames.insert(candidate.lowercased())
        return candidate
    }

    private func readableStampedBaseName(for shot: ShotMetadata) -> String {
        let datePart = Self.exportFilenameDateFormatter.string(from: shot.updatedAt)
        let anglePart = "A\(max(1, shot.angleIndex))"
        let parts = [
            sanitizeStampFilenamePart(shot.building),
            sanitizeStampFilenamePart(shot.elevation),
            sanitizeStampFilenamePart(shot.detailType),
            anglePart,
            datePart
        ].filter { !$0.isEmpty }
        let joined = parts.joined(separator: "_")
        return joined.isEmpty ? shot.shotID.uuidString : joined
    }

    private func sanitizeStampFilenamePart(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = normalized.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return String(collapsed.prefix(40))
    }

    private static let exportFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let exportOverlayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MM-dd-yyyy h:mm:ss a"
        return formatter
    }()

    private func sessionExportFilename(for asset: ReportAsset, index: Int) -> String {
        let fallback = "photo-\(index).heic"
        let original = asset.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = URL(fileURLWithPath: original).lastPathComponent
        let resolved = baseName.isEmpty ? fallback : baseName
        return resolved.replacingOccurrences(of: "/", with: "-")
    }

    private func sessionExportZipFilename() -> String {
        let propertyName = appState.selectedProperty?.name ?? reportLibrary.albumTitle
        let trimmedName = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty
            ? "ScoutCapture-Export"
            : trimmedName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
        let propertyPrefix = String((appState.selectedProperty?.id.uuidString ?? "unknown").prefix(8))
        let sessionPrefix = String((appState.currentSession?.id.uuidString ?? UUID().uuidString).prefix(8))
        return "\(safeName)_\(propertyPrefix)_\(sessionPrefix).zip"
    }

    private func buildSessionExportZipData(entries: [(path: String, data: Data, modifiedAt: Date?)]) -> Data {
        struct CentralRecord {
            let pathData: Data
            let crc32: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
            let dosTime: UInt16
            let dosDate: UInt16
        }

        var zip = Data()
        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            let crc = sessionExportCRC32(entry.data)
            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(zip.count)
            let (dosTime, dosDate) = dosDateTimeForSessionExport(entry.modifiedAt ?? Date())

            appendUInt32LEForSessionExport(0x04034B50, to: &zip)
            appendUInt16LEForSessionExport(20, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(dosTime, to: &zip)
            appendUInt16LEForSessionExport(dosDate, to: &zip)
            appendUInt32LEForSessionExport(crc, to: &zip)
            appendUInt32LEForSessionExport(size, to: &zip)
            appendUInt32LEForSessionExport(size, to: &zip)
            appendUInt16LEForSessionExport(UInt16(pathData.count), to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            zip.append(pathData)
            zip.append(entry.data)

            centralRecords.append(
                CentralRecord(
                    pathData: pathData,
                    crc32: crc,
                    size: size,
                    localHeaderOffset: localHeaderOffset,
                    dosTime: dosTime,
                    dosDate: dosDate
                )
            )
        }

        let centralDirectoryOffset = UInt32(zip.count)

        for record in centralRecords {
            appendUInt32LEForSessionExport(0x02014B50, to: &zip)
            appendUInt16LEForSessionExport(20, to: &zip)
            appendUInt16LEForSessionExport(20, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(record.dosTime, to: &zip)
            appendUInt16LEForSessionExport(record.dosDate, to: &zip)
            appendUInt32LEForSessionExport(record.crc32, to: &zip)
            appendUInt32LEForSessionExport(record.size, to: &zip)
            appendUInt32LEForSessionExport(record.size, to: &zip)
            appendUInt16LEForSessionExport(UInt16(record.pathData.count), to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt32LEForSessionExport(0, to: &zip)
            appendUInt32LEForSessionExport(record.localHeaderOffset, to: &zip)
            zip.append(record.pathData)
        }

        let centralDirectorySize = UInt32(zip.count) - centralDirectoryOffset
        let count = UInt16(centralRecords.count)

        appendUInt32LEForSessionExport(0x06054B50, to: &zip)
        appendUInt16LEForSessionExport(0, to: &zip)
        appendUInt16LEForSessionExport(0, to: &zip)
        appendUInt16LEForSessionExport(count, to: &zip)
        appendUInt16LEForSessionExport(count, to: &zip)
        appendUInt32LEForSessionExport(centralDirectorySize, to: &zip)
        appendUInt32LEForSessionExport(centralDirectoryOffset, to: &zip)
        appendUInt16LEForSessionExport(0, to: &zip)

        return zip
    }

    private func dosDateTimeForSessionExport(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = min(max(comps.year ?? 1980, 1980), 2107)
        let month = min(max(comps.month ?? 1, 1), 12)
        let day = min(max(comps.day ?? 1, 1), 31)
        let hour = min(max(comps.hour ?? 0, 0), 23)
        let minute = min(max(comps.minute ?? 0, 0), 59)
        let second = min(max(comps.second ?? 0, 0), 59)

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    private func listSessionExportZipEntryPaths(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard let eocdIndex = bytes.lastIndex(of: eocdSignature[0]).flatMap({ idx -> Int? in
            var i = idx
            while i >= 0 {
                if i + 3 < bytes.count && bytes[i...i+3].elementsEqual(eocdSignature) { return i }
                if i == 0 { break }
                i -= 1
            }
            return nil
        }) else {
            throw NSError(domain: "ScoutCapture.Export", code: 8, userInfo: [NSLocalizedDescriptionKey: "EOCD not found."])
        }

        func u16(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) |
            (Int(bytes[offset + 1]) << 8) |
            (Int(bytes[offset + 2]) << 16) |
            (Int(bytes[offset + 3]) << 24)
        }

        guard eocdIndex + 22 <= bytes.count else {
            throw NSError(domain: "ScoutCapture.Export", code: 9, userInfo: [NSLocalizedDescriptionKey: "EOCD truncated."])
        }

        let totalEntries = u16(eocdIndex + 10)
        let centralOffset = u32(eocdIndex + 16)
        var cursor = centralOffset
        var paths: [String] = []
        paths.reserveCapacity(totalEntries)

        while paths.count < totalEntries, cursor + 46 <= bytes.count {
            guard cursor + 3 < bytes.count,
                  bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B, bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else {
                break
            }
            let nameLength = u16(cursor + 28)
            let extraLength = u16(cursor + 30)
            let commentLength = u16(cursor + 32)
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { break }
            let nameBytes = Array(bytes[nameStart..<nameEnd])
            let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
            paths.append(name)
            cursor = nameEnd + extraLength + commentLength
        }

        return paths
    }

    private func sessionExportCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func appendUInt16LEForSessionExport(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func appendUInt32LEForSessionExport(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func applyArmedIssueCaptureIfNeeded(with shot: Shot) -> Bool {
        guard let armedID = armedUpdateObservationID else { return false }
        guard let propertyID = appState.selectedPropertyID else {
            cancelArmedIssueCapture()
            return false
        }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == armedID }) else {
                cancelArmedIssueCapture()
                return false
            }
            flaggedActionTargetObservation = existing
            pendingFlaggedDecisionShot = shot
            pendingFlaggedDecisionPhotoRef = shot.imageLocalIdentifier
            showFlaggedActionPrimaryChoice = true
            showFlaggedUpdateCommentChoice = false
            showFlaggedUpdatedObservationInput = false
            draftUpdatedObservation = ""
            return true
        } catch {
            cancelArmedIssueCapture()
            return false
        }
    }

    private func clearPendingFlaggedDecision() {
        flaggedActionTargetObservation = nil
        pendingFlaggedDecisionShot = nil
        pendingFlaggedDecisionPhotoRef = nil
        showFlaggedActionPrimaryChoice = false
        showFlaggedUpdateCommentChoice = false
        showFlaggedUpdatedObservationInput = false
        draftUpdatedObservation = ""
        showArmedReferenceMenu = false
    }

    private func clearArmedIssueState() {
        armedUpdateObservationID = nil
        armedIssueNoteText = ""
        armedIssueRevisedObservationText = nil
        guidedReferenceAssetLocalID = nil
        guidedReferenceThumbnail = nil
        showGuidedAlignmentOverlay = false
    }

    private func setCaptureIntent(_ intent: CaptureIntent) {
        currentCaptureIntent = intent
    }

    private func clearGuidedAndRetakeArming() {
        armedGuidedShotID = nil
        armedGuidedRetakeShotID = nil
        retakeContext = nil
    }

    private func clearFlaggedArming() {
        clearPendingFlaggedDecision()
        clearArmedIssueState()
        resolutionTargetObservation = nil
        resetResolutionCapturePreview()
        isArmedIssueDetailNoteReadOnly = false
        detailNote = ""
    }

    private func resetSelectionForSwitch() {
        flaggedActionToastToken += 1
        showFlaggedActionToast = false
        showResolutionModeToast = false
        showArmedReferenceMenu = false
        armedReferenceViewerState = nil
        resetResolutionCapturePreview()
        resolutionTargetObservation = nil
        clearPendingFlaggedDecision()
        clearArmedIssueState()
        armedGuidedShotID = nil
        armedGuidedRetakeShotID = nil
        retakeContext = nil
        currentCaptureIntent = .free
        isArmedIssueDetailNoteReadOnly = false
        detailNote = ""
    }

    private func cancelArmedIssueCapture() {
        clearPendingFlaggedDecision()
        clearArmedIssueState()
        currentCaptureIntent = .free
        isArmedIssueDetailNoteReadOnly = false
        detailNote = ""
    }

    private func finalizeArmedIssueCaptureAfterDecision() {
        clearPendingFlaggedDecision()
        clearArmedIssueState()
        currentCaptureIntent = .free
        isArmedIssueDetailNoteReadOnly = false
        detailNote = ""
    }

    private func beginFlaggedIssueInteraction(_ observation: Observation) {
        resetSelectionForSwitch()
        armIssueUpdate(observation, revisedObservationText: nil)
    }

    private func armFlaggedRetake(_ observation: Observation) {
        guard let propertyID = appState.selectedPropertyID,
              let sessionID = appState.currentSession?.id else { return }
        guard let linkedShotID = observation.linkedShotID,
              let existingShot = observation.shots.first(where: { $0.id == linkedShotID }) else { return }

        let existingPath = existingShot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !existingPath.isEmpty else { return }

        let existingFilename = URL(fileURLWithPath: existingPath).lastPathComponent
        let angleIndex: Int = {
            guard let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID),
                  let shotMetadata = metadata.shots.first(where: { $0.shotID == linkedShotID }) else {
                return 1
            }
            return max(1, shotMetadata.angleIndex)
        }()

        resetSelectionForSwitch()
        if let building = observation.building?.trimmingCharacters(in: .whitespacesAndNewlines), !building.isEmpty {
            selectedBuilding = buildingCode(from: building)
        }
        if let targetElevation = observation.targetElevation?.trimmingCharacters(in: .whitespacesAndNewlines), !targetElevation.isEmpty {
            elevation = targetElevation
        }
        if let detail = observation.detailType?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            detailTypesModel.setSelected(detail, for: locationMode)
        }
        armedIssueNoteText = Self.observationCurrentReasonText(observation) ?? ""
        detailNote = armedIssueNoteText
        isArmedIssueDetailNoteReadOnly = true
        if let resolvedFlaggedPath = flaggedResolvedThumbnailPathByID[observation.id],
           !resolvedFlaggedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadGuidedReferenceThumbnail(referencePath: resolvedFlaggedPath, localIdentifier: nil)
        } else if let localIdentifier = existingShot.imageLocalIdentifier {
            loadGuidedReferenceThumbnail(referencePath: nil, localIdentifier: localIdentifier)
        }
        showGuidedAlignmentOverlay = false
        armedUpdateObservationID = observation.id
        retakeContext = RetakeContext(
            building: (observation.building ?? selectedBuilding).trimmingCharacters(in: .whitespacesAndNewlines),
            elevation: (CanonicalElevation.normalize(observation.targetElevation) ?? elevation).trimmingCharacters(in: .whitespacesAndNewlines),
            detailType: (observation.detailType ?? currentDetailType).trimmingCharacters(in: .whitespacesAndNewlines),
            angleIndex: angleIndex,
            existingShotID: linkedShotID,
            existingOriginalFilename: existingFilename.isEmpty ? nil : existingFilename
        )
        setCaptureIntent(.retake(linkedShotID))
    }

    private func selectFlaggedPrimaryResolve() {
        applyPendingFlaggedResolve()
    }

    private func selectFlaggedPrimaryUpdate() {
        showFlaggedActionPrimaryChoice = false
        showFlaggedUpdateCommentChoice = true
    }

    private func selectFlaggedUpdateLeaveUnchanged() {
        applyPendingFlaggedUpdate(revisedObservationText: nil)
    }

    private func selectFlaggedUpdateRevise() {
        showFlaggedUpdateCommentChoice = false
        showFlaggedUpdatedObservationInput = true
        draftUpdatedObservation = ""
    }

    private func commitFlaggedUpdatedObservationAndArm() {
        let revised = draftUpdatedObservation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revised.isEmpty else { return }

        if containsMeasurementIndicator(in: revised) {
            showFlaggedActionToastNow("Reminder: SCOUT records visual observations only.")
        }

        applyPendingFlaggedUpdate(revisedObservationText: revised)
    }

    private func applyPendingFlaggedResolve() {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard let targetID = flaggedActionTargetObservation?.id else { return }
        guard let shot = pendingFlaggedDecisionShot else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == targetID }) else {
                finalizeArmedIssueCaptureAfterDecision()
                return
            }

            var updated = existing
            updated.status = .resolved
            updated.linkedShotID = shot.id
            upsertShot(shot, in: &updated)
            updated.resolutionPhotoRef = pendingFlaggedDecisionPhotoRef ?? shot.imageLocalIdentifier
            updated.resolutionStatement = "Condition no longer visibly present at time of documentation."
            updated.updatedInSessionID = appState.currentSession?.id
            updated.resolvedInSessionID = appState.currentSession?.id
            appendObservationHistoryEvent(
                ObservationHistoryEvent(
                    timestamp: shot.capturedAt,
                    sessionID: appState.currentSession?.id,
                    kind: retakeContext == nil ? .captured : .retake,
                    shotID: shot.id
                ),
                to: &updated
            )
            appendObservationHistoryEvent(
                ObservationHistoryEvent(
                    timestamp: Date(),
                    sessionID: appState.currentSession?.id,
                    kind: .resolved,
                    beforeValue: "active",
                    afterValue: "resolved",
                    field: "status",
                    shotID: shot.id
                ),
                to: &updated
            )

            _ = try localStore.updateObservation(updated)
            showFlaggedActionToastNow("Issue resolved")
            finalizeArmedIssueCaptureAfterDecision()
            refreshActiveIssues()
        } catch {
            finalizeArmedIssueCaptureAfterDecision()
        }
    }

    private func applyPendingFlaggedUpdate(revisedObservationText: String?) {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard let targetID = flaggedActionTargetObservation?.id else { return }
        guard let shot = pendingFlaggedDecisionShot else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == targetID }) else {
                finalizeArmedIssueCaptureAfterDecision()
                return
            }

            var updated = existing
            updated.linkedShotID = shot.id
            upsertShot(shot, in: &updated)
            updated.updatedInSessionID = appState.currentSession?.id
            if updated.building?.isEmpty ?? true {
                updated.building = selectedBuilding
            }
            if updated.targetElevation?.isEmpty ?? true {
                updated.targetElevation = elevation
            }
            if updated.detailType?.isEmpty ?? true {
                updated.detailType = currentDetailType
            }
            appendObservationHistoryEvent(
                ObservationHistoryEvent(
                    timestamp: shot.capturedAt,
                    sessionID: appState.currentSession?.id,
                    kind: retakeContext == nil ? .captured : .retake,
                    shotID: shot.id
                ),
                to: &updated
            )

            let revisedText = revisedObservationText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let revisedText, !revisedText.isEmpty {
                let priorReason = Self.observationCurrentReasonText(updated)
                updated.previousReason = priorReason
                updated.currentReason = revisedText
                updated.note = revisedText
                updated.statement = revisedText
                updated.updateHistory.append(
                    ObservationUpdateEntry(
                        kind: .revisedObservation,
                        text: revisedText,
                        shotID: shot.id
                    )
                )
                appendObservationHistoryEvent(
                    ObservationHistoryEvent(
                        timestamp: Date(),
                        sessionID: appState.currentSession?.id,
                        kind: .reasonUpdated,
                        beforeValue: priorReason,
                        afterValue: revisedText,
                        field: "reason",
                        shotID: shot.id
                    ),
                    to: &updated
                )
            } else {
                updated.updateHistory.append(
                    ObservationUpdateEntry(
                        kind: .followUpCapture,
                        text: nil,
                        shotID: shot.id
                    )
                )
            }

            _ = try localStore.updateObservation(updated)
            let note = Self.observationCurrentReasonText(updated) ?? ""
            if note.isEmpty {
                showFlaggedActionToastNow("Update captured")
            } else {
                let preview = String(note.prefix(36))
                showFlaggedActionToastNow("Update captured: \(preview)")
            }
            finalizeArmedIssueCaptureAfterDecision()
            refreshActiveIssues()
        } catch {
            finalizeArmedIssueCaptureAfterDecision()
        }
    }

    private func containsMeasurementIndicator(in text: String) -> Bool {
        let pattern = #"(?i)\b\d+(?:\.\d+)?\s?(ft|in|mm|cm|m|inch|inches|feet)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func resolveObservationFromChecklist(_ observation: Observation) {
        guard let propertyID = appState.selectedPropertyID else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == observation.id }) else { return }

            var updated = existing
            updated.status = .resolved
            updated.updatedInSessionID = appState.currentSession?.id
            updated.resolvedInSessionID = appState.currentSession?.id
            if updated.resolutionStatement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                updated.resolutionStatement = "Condition no longer visibly present at time of documentation."
            }
            appendObservationHistoryEvent(
                ObservationHistoryEvent(
                    timestamp: Date(),
                    sessionID: appState.currentSession?.id,
                    kind: .resolved,
                    beforeValue: "active",
                    afterValue: "resolved",
                    field: "status",
                    shotID: updated.linkedShotID
                ),
                to: &updated
            )

            _ = try localStore.updateObservation(updated)
            showFlaggedActionToastNow("Issue resolved")
            refreshActiveIssues()
        } catch {
            // Keep UI responsive if persistence fails.
        }
    }

    private func reassignObservation(_ source: Observation, to targetID: UUID) {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard source.id != targetID else { return }

        do {
            var observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let sourceIndex = observations.firstIndex(where: { $0.id == source.id }),
                  let targetIndex = observations.firstIndex(where: { $0.id == targetID }) else { return }
            guard let linkedShotID = observations[sourceIndex].linkedShotID,
                  let movedShot = observations[sourceIndex].shots.first(where: { $0.id == linkedShotID }) else { return }

            if observations[targetIndex].shots.contains(where: { $0.id == movedShot.id }) == false {
                observations[targetIndex].shots.append(movedShot)
            }
            observations[targetIndex].linkedShotID = movedShot.id
            observations[targetIndex].updatedInSessionID = appState.currentSession?.id

            let remainingSourceShots = observations[sourceIndex].shots.filter { $0.id != movedShot.id }
            observations[sourceIndex].linkedShotID = remainingSourceShots.last?.id
            observations[sourceIndex].updatedInSessionID = appState.currentSession?.id

            _ = try localStore.updateObservation(observations[targetIndex])
            _ = try localStore.updateObservation(observations[sourceIndex])
            showFlaggedActionToastNow("Issue photo reassigned")
            refreshActiveIssues()
        } catch {
            // Keep UI responsive if persistence fails.
        }
    }

    private func updateObservationLabel(_ observation: Observation, detailLabel: String) {
        guard let propertyID = appState.selectedPropertyID else { return }
        let trimmed = detailLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == observation.id }) else { return }

            var updated = existing
            updated.detailType = trimmed
            updated.updatedInSessionID = appState.currentSession?.id

            _ = try localStore.updateObservation(updated)
            refreshActiveIssues()
        } catch {
            // Keep UI responsive if persistence fails.
        }
    }

    private func showFlaggedActionToastNow(_ text: String) {
        flaggedActionToastToken += 1
        let token = flaggedActionToastToken
        flaggedActionToastText = text
        showFlaggedActionToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard token == flaggedActionToastToken else { return }
            showFlaggedActionToast = false
        }
    }

    private func queueResolutionCaptureIfNeeded(with shot: Shot, data: Data) -> Bool {
        guard resolutionTargetObservation != nil else { return false }
        resolutionCapturedShot = shot
        resolutionCapturedPhotoRef = shot.imageLocalIdentifier
        resolutionCapturedImage = UIImage(data: data)
        return true
    }

    private func refreshActiveIssues() {
        guard let propertyID = appState.selectedPropertyID else {
            activeObservations = []
            activeSessionShotIDs = []
            flaggedResolvedThumbnailPathByID = [:]
            flaggedReferencePathByID = [:]
            carryoverIssueBadgeCount = 0
            flaggedPendingCaptureCount = 0
            reportLibrary.setActiveIssueCount(0)
            print("[FlaggedData] using sessionID=\(appState.currentSession?.id.uuidString ?? "NONE") flaggedCount=0 sessionShotsCount=0")
            refreshReferenceSetsAndPendingCounts()
            print("[BadgeCounts] sessionID=\(appState.currentSession?.id.uuidString ?? "NONE") guidedPending=\(guidedRemainingForCompass) flaggedPending=\(flaggedPendingCaptureCount) carryoverIssues=0")
            return
        }

        let activeSessionID = appState.currentSession?.id
        let sessionShotIDs = sessionShotIDsForActiveSession(propertyID: propertyID, sessionID: activeSessionID)
        activeSessionShotIDs = sessionShotIDs
        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            let currentSessionID = activeSessionID
            let currentSessionStart = appState.currentSession?.startedAt

            activeObservations = observations
                .filter { observation in
                    if observation.status == .active {
                        return true
                    }
                    if observation.status == .resolved,
                       let currentSessionID,
                       observation.resolvedInSessionID == currentSessionID {
                        return true
                    }
                    return false
                }
                .sorted { $0.updatedAt > $1.updatedAt }

            let baselineState = persistedBaselineState(propertyID: propertyID)
            let orderedSessions = ((try? localStore.fetchSessions(propertyID: propertyID)) ?? []).sorted { $0.startedAt < $1.startedAt }
            let currentSession = orderedSessions.first(where: { $0.id == activeSessionID }) ?? appState.currentSession
            let currentSessionMetadata = sessionMetadataForActiveSession(propertyID: propertyID, sessionID: activeSessionID)
            var metadataCache: [UUID: SessionMetadata] = [:]
            if let currentSessionMetadata, let activeSessionID {
                metadataCache[activeSessionID] = currentSessionMetadata
            }
            var resolvedMap: [UUID: String] = [:]
            var referenceMap: [UUID: String] = [:]
            for observation in activeObservations {
                let resolved = resolveFlaggedThumbnailForDisplay(
                    propertyID: propertyID,
                    currentSession: currentSession,
                    baselineSessionID: baselineState.baselineSessionID,
                    observation: observation,
                    currentSessionMetadata: currentSessionMetadata,
                    orderedSessions: orderedSessions,
                    metadataCache: &metadataCache
                )
                if let path = resolved.path, resolved.exists {
                    resolvedMap[observation.id] = path
                }
                if let referencePath = resolveFlaggedReferencePathForDisplay(
                    propertyID: propertyID,
                    observation: observation,
                    currentSession: currentSession,
                    baselineSessionID: baselineState.baselineSessionID
                ) {
                    referenceMap[observation.id] = referencePath
                }
            }
            flaggedResolvedThumbnailPathByID = resolvedMap
            flaggedReferencePathByID = referenceMap

            if let currentSessionID, let currentSessionStart {
                carryoverIssueBadgeCount = observations.filter { observation in
                    observation.status == .active &&
                    observation.createdAt < currentSessionStart &&
                    observation.updatedInSessionID != currentSessionID
                }.count
            } else {
                carryoverIssueBadgeCount = 0
            }

            reportLibrary.setActiveIssueCount(activeObservations.count)
            print(
                "[FlaggedData] using sessionID=\(activeSessionID?.uuidString ?? "NONE") " +
                "flaggedCount=\(activeObservations.count) " +
                "sessionShotsCount=\(sessionShotIDs.count)"
            )
            refreshReferenceSetsAndPendingCounts()
            print(
                "[BadgeCounts] sessionID=\(activeSessionID?.uuidString ?? "NONE") " +
                "guidedPending=\(guidedRemainingForCompass) flaggedPending=\(flaggedPendingCaptureCount) carryoverIssues=\(carryoverIssueBadgeCount)"
            )
        } catch {
            activeObservations = []
            flaggedResolvedThumbnailPathByID = [:]
            flaggedReferencePathByID = [:]
            carryoverIssueBadgeCount = 0
            flaggedPendingCaptureCount = 0
            reportLibrary.setActiveIssueCount(0)
            print(
                "[FlaggedData] using sessionID=\(activeSessionID?.uuidString ?? "NONE") " +
                "flaggedCount=0 sessionShotsCount=0"
            )
            refreshReferenceSetsAndPendingCounts()
            print(
                "[BadgeCounts] sessionID=\(activeSessionID?.uuidString ?? "NONE") " +
                "guidedPending=\(guidedRemainingForCompass) flaggedPending=\(flaggedPendingCaptureCount) carryoverIssues=0"
            )
        }
    }

    private func armIssueUpdate(_ observation: Observation, revisedObservationText: String?) {
        showActiveIssuesSheet = false
        armedGuidedShotID = nil
        armedGuidedRetakeShotID = nil
        retakeContext = nil
        resolutionTargetObservation = nil
        resetResolutionCapturePreview()
        armedIssueRevisedObservationText = revisedObservationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        armedIssueNoteText = Self.observationCurrentReasonText(observation) ?? ""
        detailNote = armedIssueNoteText
        isArmedIssueDetailNoteReadOnly = true
        if let resolvedFlaggedPath = flaggedResolvedThumbnailPathByID[observation.id],
           !resolvedFlaggedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadGuidedReferenceThumbnail(referencePath: resolvedFlaggedPath, localIdentifier: nil)
        } else {
            let sortedShots = observation.shots.sorted { $0.capturedAt < $1.capturedAt }
            let referenceLocalID = sortedShots.first?.imageLocalIdentifier
            loadGuidedReferenceThumbnail(referencePath: nil, localIdentifier: referenceLocalID)
        }
        showGuidedAlignmentOverlay = false
        if let building = observation.building?.trimmingCharacters(in: .whitespacesAndNewlines), !building.isEmpty {
            selectedBuilding = buildingCode(from: building)
        }
        if let targetElevation = observation.targetElevation?.trimmingCharacters(in: .whitespacesAndNewlines), !targetElevation.isEmpty {
            elevation = targetElevation
        }
        if let detail = observation.detailType?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            detailTypesModel.setSelected(detail, for: locationMode)
        }
        armedUpdateObservationID = observation.id
        setCaptureIntent(.flagged(observation.id))
    }

    private func armIssueUpdate(_ observation: Observation) {
        armIssueUpdate(observation, revisedObservationText: nil)
    }

    private func enterResolutionMode(_ observation: Observation) {
        showActiveIssuesSheet = false
        armedUpdateObservationID = nil
        resolutionTargetObservation = observation
        setCaptureIntent(.flagged(observation.id))
        resetResolutionCapturePreview()
        showResolutionModeToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            showResolutionModeToast = false
        }
    }

    private func resetResolutionCapturePreview() {
        resolutionCapturedShot = nil
        resolutionCapturedPhotoRef = nil
        resolutionCapturedImage = nil
    }

    private func confirmResolution() {
        guard let target = resolutionTargetObservation else { return }
        guard let shot = resolutionCapturedShot else { return }
        guard let propertyID = appState.selectedPropertyID else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == target.id }) else { return }

            var updated = existing
            updated.status = .resolved
            updated.linkedShotID = shot.id
            upsertShot(shot, in: &updated)
            updated.resolutionPhotoRef = resolutionCapturedPhotoRef
            updated.resolutionStatement = "Condition no longer visibly present at time of documentation."
            updated.updatedInSessionID = appState.currentSession?.id
            updated.resolvedInSessionID = appState.currentSession?.id
            appendObservationHistoryEvent(
                ObservationHistoryEvent(
                    timestamp: shot.capturedAt,
                    sessionID: appState.currentSession?.id,
                    kind: .captured,
                    shotID: shot.id
                ),
                to: &updated
            )
            appendObservationHistoryEvent(
                ObservationHistoryEvent(
                    timestamp: Date(),
                    sessionID: appState.currentSession?.id,
                    kind: .resolved,
                    beforeValue: "active",
                    afterValue: "resolved",
                    field: "status",
                    shotID: shot.id
                ),
                to: &updated
            )
            _ = try localStore.updateObservation(updated)

            resolutionTargetObservation = nil
            resetResolutionCapturePreview()
            showFlaggedActionToastNow("Issue resolved")
            refreshActiveIssues()
        } catch {
            // Keep UI responsive if persistence fails.
        }
    }
    
    
    
    
    
    private struct SessionActionsSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        let summary: SessionActionsSummary
        let isPreparingExport: Bool
        let onResume: () -> Void
        let onSaveDraftAndExit: () -> Void
        let onExportNow: () -> Void
        let onExportLater: () -> Void

        private var neutralFill: Color {
            colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.65)
        }

        private var neutralStroke: Color {
            colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
        }

        private var neutralLabel: Color {
            colorScheme == .light ? Color.black.opacity(0.88) : .white
        }

        var body: some View {
            GeometryReader { geo in
                let constrainedHeight = geo.size.height < 620

                ZStack {
                    Color.black.opacity(0.52)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack {
                        Spacer(minLength: 0)

                        VStack(spacing: 14) {
                            Text("Session Actions")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)

                            VStack(spacing: 8) {
                                summaryRow(title: "Flagged Remaining", value: summary.flaggedRemainingCount)
                                summaryRow(title: "Guided Remaining", value: summary.guidedRemainingCount)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                            )

                            if constrainedHeight {
                                ScrollView(.vertical, showsIndicators: true) {
                                    actionButtonsStack
                                }
                                .frame(maxHeight: geo.size.height * 0.38)
                            } else {
                                actionButtonsStack
                            }
                        }
                        .padding(18)
                        .frame(width: min(max(310, geo.size.width * 0.84), 470))
                        .background(Color.black.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.20), lineWidth: 1)
                        )

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                }
            }
        }

        @ViewBuilder
        private func summaryRow(title: String, value: Int) -> some View {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Spacer(minLength: 0)
                Text("\(value)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
        }

        @ViewBuilder
        private var actionButtonsStack: some View {
            VStack(spacing: 10) {
                actionButton(
                    title: "Resume",
                    role: .primary,
                    isEnabled: !isPreparingExport,
                    action: onResume
                )
                actionButton(
                    title: isPreparingExport ? "Preparing Export..." : summary.exportActionTitle,
                    role: .secondary,
                    isEnabled: !isPreparingExport && summary.isExportActionEnabled,
                    action: onExportNow
                )
                actionButton(
                    title: "Export Later",
                    role: .tertiary,
                    isEnabled: !isPreparingExport && summary.isExportLaterEnabled,
                    action: onExportLater
                )
                actionButton(
                    title: "Save Draft and Exit",
                    role: .secondary,
                    isEnabled: !isPreparingExport,
                    action: onSaveDraftAndExit
                )

                if !summary.isExportActionEnabled || !summary.isExportLaterEnabled {
                    Text(disabledHintText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
        }

        private var disabledHintText: String {
            if summary.isSessionSealed && summary.firstDeliveredAt == nil {
                return "Session sealed. Use Deliver to complete first delivery."
            }
            if summary.isSessionSealed && summary.firstDeliveredAt != nil && !summary.reExportEligibleNow {
                return "Re export window expired."
            }
            if !summary.hasBaseline && summary.currentSessionCaptureCount == 0 {
                return "Export is disabled until at least one photo is captured."
            }
            return "Export and Export Later are disabled until all guided and flagged items are complete."
        }

        private enum ActionRole {
            case primary
            case secondary
            case tertiary
        }

        @ViewBuilder
        private func actionButton(
            title: String,
            role: ActionRole,
            isEnabled: Bool,
            action: @escaping () -> Void
        ) -> some View {
            let fill: Color = {
                switch role {
                case .primary:
                    return .blue
                case .secondary:
                    return neutralFill
                case .tertiary:
                    return Color.white.opacity(0.06)
                }
            }()
            let stroke: Color = {
                switch role {
                case .primary:
                    return .blue.opacity(0.85)
                case .secondary:
                    return neutralStroke
                case .tertiary:
                    return Color.white.opacity(0.20)
                }
            }()
            let label: Color = {
                switch role {
                case .primary:
                    return .white
                case .secondary:
                    return neutralLabel
                case .tertiary:
                    return .white.opacity(0.94)
                }
            }()

            Button(action: action) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isEnabled ? label : label.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(isEnabled ? fill : fill.opacity(0.45))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(isEnabled ? stroke : stroke.opacity(0.45), lineWidth: 1)
                    )
            }
            .opacity(isEnabled ? 1.0 : 0.72)
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }

    private struct ExportProgressOverlay: View {
        let title: String

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack(spacing: 14) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)

                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.15)
                    }
                    .padding(20)
                    .frame(width: min(max(290, geo.size.width * 0.80), 430))
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                }
            }
        }
    }

    private struct SessionExportChecklistOverlay: View {
        let checklist: ExportChecklistState

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack(spacing: 14) {
                        Text("Preparing Export")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)

                        VStack(spacing: 10) {
                            checklistRow(title: "Originals", isComplete: checklist.originalsComplete)
                            checklistRow(title: "Session Data", isComplete: checklist.sessionDataComplete)
                            checklistRow(title: "ZIP Ready", isComplete: checklist.zipReady)
                        }
                    }
                    .padding(20)
                    .frame(width: min(max(290, geo.size.width * 0.80), 430))
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                }
            }
        }

        @ViewBuilder
        private func checklistRow(title: String, isComplete: Bool) -> some View {
            HStack(spacing: 10) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isComplete ? .white : .white.opacity(0.55))
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.94))
                Spacer(minLength: 0)
            }
        }
    }

    private struct ExportErrorOverlay: View {
        let title: String
        let message: String
        let retryTitle: String
        let cancelTitle: String
        let onRetry: () -> Void
        let onCancel: () -> Void

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack(spacing: 14) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)

                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.90))
                            .multilineTextAlignment(.center)

                        HStack(spacing: 10) {
                            Button(action: onRetry) {
                                Text(retryTitle)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.blue.opacity(0.85), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Button(action: onCancel) {
                                Text(cancelTitle)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                    .frame(width: min(max(300, geo.size.width * 0.84), 460))
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                }
            }
        }
    }

    private struct SessionDocumentExportPicker: UIViewControllerRepresentable {
        let fileURL: URL
        let onComplete: (Bool) -> Void

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }

        func makeCoordinator() -> Coordinator {
            Coordinator(onComplete: onComplete)
        }

        final class Coordinator: NSObject, UIDocumentPickerDelegate {
            let onComplete: (Bool) -> Void

            init(onComplete: @escaping (Bool) -> Void) {
                self.onComplete = onComplete
            }

            func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                onComplete(!urls.isEmpty)
            }

            func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
                onComplete(false)
            }
        }
    }

    // MARK: - Report Library Fullscreen (Grid)
    
    private struct ReportLibraryFullscreen: View {
        
        @ObservedObject var reportLibrary: ReportLibraryModel
        @ObservedObject var cache: AssetImageCache
        let thumbnailRefreshToken: UUID
        let onAfterDelete: () -> Void
        @EnvironmentObject private var appState: AppState
        private let localStore = LocalStore()
        
        @Environment(\.dismiss) private var dismiss
        @State private var orientationResetToken: Int = 0
        // Physical device orientation (UI is portrait locked, we rotate the content ourselves)
        @State private var lastValidOrientation: UIDeviceOrientation = .portrait
        
        private var isLandscape: Bool {
            lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight
        }

        private var headerPropertyName: String {
            let trimmed = appState.selectedProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "No Property Selected" : trimmed
        }
        
        private var rotationDegrees: Double {
            switch lastValidOrientation {
            case .landscapeLeft:
                return 90
            case .landscapeRight:
                return -90
            default:
                return 0
            }
        }
        
        private func refreshOrientation() {
            let o = UIDevice.current.orientation
            
            // Accept only portrait (upright) and the two landscapes.
            // Explicitly ignore portraitUpsideDown so the UI does not snap back to portrait when the phone is inverted.
            // Also ignore transitional/invalid states (faceUp, faceDown, unknown).
            let newValue: UIDeviceOrientation? = {
                switch o {
                case .portrait:
                    return .portrait
                case .landscapeLeft, .landscapeRight:
                    return o
                default:
                    return nil
                }
            }()
            
            guard let newValue else { return }
            guard newValue != lastValidOrientation else { return }
            lastValidOrientation = newValue
            
            // Rebuild zoom view so it re-fits instead of keeping an old zoom scale
            orientationResetToken &+= 1
        }
        
        private struct ViewerState: Identifiable {
            let id = UUID()
            let startIndex: Int
        }
        
        private struct ExportFile: Identifiable {
            let id = UUID()
            let url: URL
        }
        
        private struct ExportAssetEntry: Codable {
            let localIdentifier: String
            let creationDate: Date?
            let pixelWidth: Int
            let pixelHeight: Int
            let originalFilename: String
        }
        
        private struct ExportSessionPayload: Codable {
            let exportedAt: Date
            let albumTitle: String
            let albumLocalId: String
            let property: Property?
            let session: Session?
            let activeIssueCount: Int
            let assets: [ExportAssetEntry]
            let observations: [Observation]
            let guidedShots: [GuidedShot]
        }

        private enum ExportError: LocalizedError {
            case zipCreationFailed

            var errorDescription: String? {
                switch self {
                case .zipCreationFailed:
                    return "Unable to create export ZIP."
                }
            }
        }

        private enum DragSelectionMode {
            case add
            case remove
        }

        private struct ThumbnailFramePreferenceKey: PreferenceKey {
            static var defaultValue: [String: CGRect] = [:]

            static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
                value.merge(nextValue(), uniquingKeysWith: { _, new in new })
            }
        }
        
        @State private var viewerState: ViewerState? = nil
        @State private var isSelectionMode: Bool = false
        @State private var selectedAssetIds: Set<String> = []
        @State private var isDeletingSelection: Bool = false
        @State private var showDeleteDialog: Bool = false
        @State private var isPreparingShare: Bool = false
        @State private var showShareSheet: Bool = false
        @State private var shareItems: [Any] = []
        @State private var isPreparingExport: Bool = false
        @State private var exportFile: ExportFile? = nil
        @State private var exportErrorMessage: String? = nil
        @State private var showExportError: Bool = false
        @State private var showHeaderOverflowMenu: Bool = false
        @State private var thumbnailFrames: [String: CGRect] = [:]
        @State private var isDragSelecting: Bool = false
        @State private var dragSelectionMode: DragSelectionMode? = nil
        @State private var dragAnchorAssetIndex: Int? = nil
        @State private var dragBaselineSelection: Set<String> = []
        @State private var dragCurrentAssetIndex: Int? = nil
        @State private var dragAutoScrollDirection: Int = 0
        @State private var dragAutoScrollWorkItem: DispatchWorkItem? = nil
        @State private var viewingCurrentSession: Bool = true
        
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                
                // When we rotate content inside a portrait locked app, swap the content frame.
                let contentW = isLandscape ? h : w
                let contentH = isLandscape ? w : h
                
                // Grid config
                let columnsCount: Int = isLandscape ? 5 : 3
                
                // Portrait should be tight (nearly touching), like landscape
                let spacing: CGFloat = isLandscape ? 2 : 2
                
                // Reduce portrait side padding so it reads closer to edge to edge
                let horizontalPadding: CGFloat = isLandscape ? 0 : 2
                
                let totalSpacing = CGFloat(max(0, columnsCount - 1)) * spacing
                let side = (contentW - (horizontalPadding * 2) - totalSpacing) / CGFloat(columnsCount)
                let headerH: CGFloat = 80
                
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    // Rotated content container
                    ZStack {
                        // Grid
                        ScrollViewReader { scrollProxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.fixed(side), spacing: spacing, alignment: .center), count: columnsCount),
                                    alignment: .center,
                                    spacing: spacing
                                ) {
                                    ForEach(Array(reportLibrary.assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                                        LibraryThumb(
                                            asset: asset,
                                            cache: cache,
                                            side: side,
                                            refreshToken: thumbnailRefreshToken,
                                            isSelectionMode: isSelectionMode,
                                            isSelected: selectedAssetIds.contains(asset.localIdentifier)
                                        )
                                            .id(asset.localIdentifier)
                                            .background(
                                                GeometryReader { proxy in
                                                    Color.clear.preference(
                                                        key: ThumbnailFramePreferenceKey.self,
                                                        value: [asset.localIdentifier: proxy.frame(in: .named("libraryGridSelectionSpace"))]
                                                    )
                                                }
                                            )
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                if isSelectionMode {
                                                    toggleAssetSelection(asset.localIdentifier)
                                                } else {
                                                    viewerState = ViewerState(startIndex: idx)
                                                }
                                            }
                                    }
                                }
                                .padding(.horizontal, horizontalPadding)
                                .padding(.top, headerH)
                                .padding(.bottom, isLandscape ? 0 : 8)
                            }
                            .scrollDisabled(isSelectionMode && isDragSelecting)
                            .coordinateSpace(name: "libraryGridSelectionSpace")
                            .onPreferenceChange(ThumbnailFramePreferenceKey.self) { frames in
                                thumbnailFrames = frames
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 8, coordinateSpace: .named("libraryGridSelectionSpace"))
                                    .onChanged { value in
                                        handleSelectionDragChanged(
                                            at: value.location,
                                            contentHeight: contentH,
                                            columnsCount: columnsCount,
                                            scrollProxy: scrollProxy
                                        )
                                    }
                                    .onEnded { _ in
                                        handleSelectionDragEnded()
                                    }
                            )
                        }
                        // In landscape, remove safe areas so the grid goes edge to edge.
                        .ignoresSafeArea(isLandscape ? .all : [])
                        
                        // Header overlay (Photos style): stays visible, content can scroll behind it.
                        headerOverlay()
                            .zIndex(50)
                        
                        if showHeaderOverflowMenu {
                            headerOverflowActionOverlay()
                                .zIndex(80)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        bottomSelectionActions(bottomInset: isLandscape ? 30 : 32)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        sessionSourceToggle(bottomInset: isLandscape ? 26 : 22)
                    }
                    .frame(width: contentW, height: contentH, alignment: .center)
                    .rotationEffect(.degrees(rotationDegrees))
                    .position(x: w * 0.5, y: h * 0.5)
                }
                // Hide the status bar only in landscape.
                .statusBarHidden(isLandscape)
                .onAppear {
                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                    refreshOrientation()
                    resetToCurrentSessionSource()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                    refreshOrientation()
                }
                .onChange(of: isSelectionMode) { _, newValue in
                    if newValue {
                        forceCurrentSessionSource(reason: "selectMode")
                    }
                }
                .onChange(of: appState.currentSession?.id) { _, _ in
                    forceCurrentSessionSource(reason: "sessionChanged")
                }
                .onDisappear {
                    UIDevice.current.endGeneratingDeviceOrientationNotifications()
                    handleSelectionDragEnded()
                    selectedAssetIds.removeAll()
                    isSelectionMode = false
                    showHeaderOverflowMenu = false
                    resetToCurrentSessionSource()
                    print("[PhotoGrid] exit reset viewingCurrent=true")
                }
            }
            .fullScreenCover(item: $viewerState) { state in
                let metadataSessionID = displayedGridSessionID()
                ReportPhotoViewer(
                    title: reportLibrary.albumTitle,
                    assets: reportLibrary.assets,
                    startIndex: state.startIndex,
                    metadataPropertyID: appState.selectedPropertyID,
                    metadataSessionID: metadataSessionID,
                    cache: cache,
                    viewerToken: state.startIndex
                )
            }
            .confirmationDialog(
                "Delete Selected Files",
                isPresented: $showDeleteDialog,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteSelectedAssets()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You selected \(selectedAssetIds.count) file\(selectedAssetIds.count == 1 ? "" : "s"). This permanently deletes local SCOUT files.")
            }
            .sheet(isPresented: $showShareSheet, onDismiss: {
                shareItems = []
            }) {
                ActivityShareSheet(activityItems: shareItems)
            }
            .sheet(item: $exportFile) { file in
                DocumentExportPicker(
                    fileURL: file.url,
                    onComplete: { didExport in
                        if didExport {
                            appState.markCurrentSessionExported()
                        }
                    }
                )
            }
            .overlay {
                if isPreparingExport {
                    ExportProgressOverlay(title: "Preparing Export")
                        .zIndex(920)
                }
                if showExportError {
                    ExportErrorOverlay(
                        title: "Export Failed",
                        message: exportErrorMessage ?? "Unable to export report ZIP.",
                        retryTitle: "Retry",
                        cancelTitle: "Cancel",
                        onRetry: {
                            showExportError = false
                            beginExport()
                        },
                        onCancel: {
                            showExportError = false
                        }
                    )
                    .zIndex(930)
                }
            }
        }
        
        @ViewBuilder
        private func headerOverlay() -> some View {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    // Opaque gradient that keeps header readable while allowing photos behind it.
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.92),
                            Color.black.opacity(0.70),
                            Color.black.opacity(0.35),
                            Color.black.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            VStack(alignment: .leading, spacing: 2) {
                            Text(headerPropertyName)
                                .font(.system(size: 38, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                                .allowsTightening(true)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                        }
                        }
                        
                        Spacer(minLength: 0)

                        Button {
                            guard viewingCurrentSession else { return }
                            withAnimation(.easeOut(duration: 0.18)) {
                                if isSelectionMode {
                                    isSelectionMode = false
                                    selectedAssetIds.removeAll()
                                } else {
                                    isSelectionMode = true
                                }
                            }
                        } label: {
                            Text(isSelectionMode ? "Cancel" : "Select")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.white)
                                .frame(minHeight: 42)
                                .padding(.horizontal, 14)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .opacity(viewingCurrentSession ? 1.0 : 0.45)
                        .allowsHitTesting(viewingCurrentSession)

                        Button {
                            guard viewingCurrentSession else { return }
                            showHeaderOverflowMenu = true
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .opacity(viewingCurrentSession ? 1.0 : 0.45)
                        .allowsHitTesting(viewingCurrentSession)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, isLandscape ? 8 : 6)
                    .padding(.bottom, 8)
                }
                .frame(height: 96)
                
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(true)
        }

        @ViewBuilder
        private func headerOverflowActionOverlay() -> some View {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showHeaderOverflowMenu = false
                    }

                VStack(spacing: 0) {
                    HStack {
                        Text("Actions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                        Spacer(minLength: 0)
                        Button("Done") {
                            showHeaderOverflowMenu = false
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.20))

                    VStack(spacing: 0) {
                        actionMenuRow(title: "Export") {
                            beginExport()
                            showHeaderOverflowMenu = false
                        }
                        .opacity(isPreparingExport ? 0.45 : 1.0)
                        .allowsHitTesting(!isPreparingExport)
                    }
                    .padding(.vertical, 6)
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
                .padding(.horizontal, 20)
                .frame(maxWidth: 360)
            }
            .zIndex(999)
        }

        private func actionMenuRow(title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }

        private func actionMenuDivider() -> some View {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 12)
        }

        @ViewBuilder
        private func bottomSelectionActions(bottomInset: CGFloat) -> some View {
            if isSelectionMode {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.00), location: 0.00),
                            .init(color: Color.black.opacity(0.22), location: 0.45),
                            .init(color: Color.black.opacity(0.52), location: 0.78),
                            .init(color: Color.black.opacity(0.72), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: isLandscape ? 130 : 185)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)

                    HStack {
                        circularActionButton(
                            systemName: "square.and.arrow.up",
                            isEnabled: !selectedAssetIds.isEmpty && !isPreparingShare && !isDeletingSelection,
                            tint: .white,
                            action: {
                                shareSelectedAssets()
                            }
                        )

                        Spacer(minLength: 0)

                        Text(selectedAssetIds.isEmpty ? "Select Items" : "\(selectedAssetIds.count) Selected")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Spacer(minLength: 0)

                        circularActionButton(
                            systemName: "trash",
                            isEnabled: !selectedAssetIds.isEmpty && !isDeletingSelection,
                            tint: .red,
                            action: {
                                showDeleteDialog = true
                            }
                        )
                    }
                    .padding(.horizontal, isLandscape ? 26 : 32)
                    .padding(.bottom, bottomInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
                .zIndex(60)
            }
        }

        @ViewBuilder
        private func sessionSourceToggle(bottomInset: CGFloat) -> some View {
            if !isSelectionMode, let currentSessionID = appState.currentSession?.id {
                let previousID = previousSessionID(currentSessionID: currentSessionID)
                if previousID != nil {
                    Button {
                        toggleSessionSource(currentSessionID: currentSessionID, previousSessionID: previousID)
                    } label: {
                        Text(viewingCurrentSession ? "Current" : "Previous")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 42)
                            .background(viewingCurrentSession ? Color.black.opacity(0.58) : Color.blue.opacity(0.85))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, isLandscape ? 20 : 16)
                    .padding(.bottom, bottomInset)
                }
            }
        }

        @ViewBuilder
        private func circularActionButton(
            systemName: String,
            isEnabled: Bool,
            tint: Color,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.58))
                        .frame(width: 50, height: 50)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.26), lineWidth: 1)
                        )

                    if isPreparingShare && systemName == "square.and.arrow.up" {
                        ProgressView()
                            .tint(.white.opacity(0.92))
                    } else {
                        Image(systemName: systemName)
                            .font(.system(size: proportionalCircleGlyphSize(for: 50) + 1, weight: .medium))
                            .foregroundColor(isEnabled ? tint : Color.white.opacity(0.40))
                            .frame(width: 22, height: 22, alignment: .center)
                            .offset(
                                x: systemName == "square.and.arrow.up" ? 0.5 : 0,
                                y: systemName == "square.and.arrow.up" ? -2.0 : 0
                            )
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }

        private func selectedAssetsInDisplayOrder() -> [ReportAsset] {
            reportLibrary.assets.filter { selectedAssetIds.contains($0.localIdentifier) }
        }

        private func displayedGridSessionID() -> UUID? {
            guard let currentSessionID = appState.currentSession?.id else { return nil }
            if viewingCurrentSession {
                return currentSessionID
            }
            return previousSessionID(currentSessionID: currentSessionID) ?? currentSessionID
        }

        private func previousSessionID(currentSessionID: UUID) -> UUID? {
            guard let propertyID = appState.selectedPropertyID else { return nil }
            let sessions = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
            let currentStart = appState.currentSession?.startedAt ?? .distantFuture
            let previous = sessions
                .filter {
                    $0.id != currentSessionID &&
                    $0.status == .completed &&
                    $0.startedAt < currentStart
                }
                .sorted { lhs, rhs in
                    let l = lhs.endedAt ?? lhs.startedAt
                    let r = rhs.endedAt ?? rhs.startedAt
                    return l > r
                }
                .first
            return previous?.id
        }

        private func toggleSessionSource(currentSessionID: UUID, previousSessionID: UUID?) {
            guard let propertyID = appState.selectedPropertyID else { return }
            guard let previousSessionID else {
                viewingCurrentSession = true
                print("[PhotoGrid] previousSession unavailable propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID.uuidString)")
                return
            }
            viewingCurrentSession.toggle()
            let displayedSessionID = viewingCurrentSession ? currentSessionID : previousSessionID
            reportLibrary.reloadSessionAssets(propertyID: propertyID, sessionID: displayedSessionID)
            print(
                "[PhotoGridToggle] propertyID=\(propertyID.uuidString) " +
                "currentSessionID=\(currentSessionID.uuidString) " +
                "previousSessionID=\(previousSessionID.uuidString) " +
                "displayingSessionID=\(displayedSessionID.uuidString)"
            )
        }

        private func forceCurrentSessionSource(reason: String) {
            guard let propertyID = appState.selectedPropertyID,
                  let currentSessionID = appState.currentSession?.id else {
                viewingCurrentSession = true
                return
            }
            if !viewingCurrentSession || reason == "sessionChanged" {
                viewingCurrentSession = true
                reportLibrary.reloadSessionAssets(propertyID: propertyID, sessionID: currentSessionID)
            }
        }

        private func resetToCurrentSessionSource() {
            guard let propertyID = appState.selectedPropertyID,
                  let currentSessionID = appState.currentSession?.id else {
                viewingCurrentSession = true
                return
            }
            viewingCurrentSession = true
            if previousSessionID(currentSessionID: currentSessionID) == nil {
                print("[PhotoGrid] previousSession unavailable propertyID=\(propertyID.uuidString) currentSessionID=\(currentSessionID.uuidString)")
            }
            reportLibrary.reloadSessionAssets(propertyID: propertyID, sessionID: currentSessionID)
        }

        private func shareSelectedAssets() {
            let selectedAssets = selectedAssetsInDisplayOrder()
            guard !selectedAssets.isEmpty else { return }
            isPreparingShare = true

            DispatchQueue.global(qos: .userInitiated).async {
                var images: [UIImage] = []
                images.reserveCapacity(selectedAssets.count)

                for asset in selectedAssets {
                    if let data = try? Data(contentsOf: asset.fileURL),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                }

                DispatchQueue.main.async {
                    isPreparingShare = false
                    guard !images.isEmpty else { return }
                    shareItems = images
                    showShareSheet = true
                }
            }
        }

        private func toggleAssetSelection(_ localId: String) {
            if selectedAssetIds.contains(localId) {
                selectedAssetIds.remove(localId)
            } else {
                selectedAssetIds.insert(localId)
            }
        }

        private func assetID(at location: CGPoint) -> String? {
            thumbnailFrames.first(where: { $0.value.contains(location) })?.key
        }

        private func handleSelectionDragChanged(
            at location: CGPoint,
            contentHeight: CGFloat,
            columnsCount: Int,
            scrollProxy: ScrollViewProxy
        ) {
            guard isSelectionMode else { return }
            guard let localId = assetID(at: location) else { return }
            guard let index = reportLibrary.assets.firstIndex(where: { $0.localIdentifier == localId }) else { return }

            if !isDragSelecting {
                isDragSelecting = true
                dragSelectionMode = selectedAssetIds.contains(localId) ? .remove : .add
                dragAnchorAssetIndex = index
                dragBaselineSelection = selectedAssetIds
            }

            dragCurrentAssetIndex = index
            applyDragRangeSelection(currentIndex: index)

            let edgeThreshold: CGFloat = 72
            let direction: Int
            if location.y <= edgeThreshold {
                direction = -1
            } else if location.y >= (contentHeight - edgeThreshold) {
                direction = 1
            } else {
                direction = 0
            }

            updateAutoScroll(
                direction: direction,
                columnsCount: columnsCount,
                scrollProxy: scrollProxy
            )
        }

        private func applyDragRangeSelection(currentIndex: Int) {
            guard let anchorIndex = dragAnchorAssetIndex else { return }
            guard let mode = dragSelectionMode else { return }

            let lower = min(anchorIndex, currentIndex)
            let upper = max(anchorIndex, currentIndex)
            let rangedIDs = Set(reportLibrary.assets[lower...upper].map(\.localIdentifier))

            switch mode {
            case .add:
                selectedAssetIds = dragBaselineSelection.union(rangedIDs)
            case .remove:
                selectedAssetIds = dragBaselineSelection.subtracting(rangedIDs)
            }
        }

        private func updateAutoScroll(
            direction: Int,
            columnsCount: Int,
            scrollProxy: ScrollViewProxy
        ) {
            guard direction != dragAutoScrollDirection else { return }
            dragAutoScrollDirection = direction
            dragAutoScrollWorkItem?.cancel()
            dragAutoScrollWorkItem = nil

            guard direction != 0 else { return }
            scheduleAutoScrollTick(columnsCount: columnsCount, scrollProxy: scrollProxy)
        }

        private func scheduleAutoScrollTick(columnsCount: Int, scrollProxy: ScrollViewProxy) {
            let work = DispatchWorkItem {
                guard isDragSelecting else { return }
                guard dragAutoScrollDirection != 0 else { return }
                guard !reportLibrary.assets.isEmpty else { return }

                let step = max(1, columnsCount)
                let currentIndex = dragCurrentAssetIndex ?? 0
                let maxIndex = reportLibrary.assets.count - 1
                let nextIndex = min(
                    max(0, currentIndex + (dragAutoScrollDirection * step)),
                    maxIndex
                )

                guard nextIndex != currentIndex else {
                    scheduleAutoScrollTick(columnsCount: columnsCount, scrollProxy: scrollProxy)
                    return
                }

                let nextId = reportLibrary.assets[nextIndex].localIdentifier
                dragCurrentAssetIndex = nextIndex
                applyDragRangeSelection(currentIndex: nextIndex)

                withAnimation(.linear(duration: 0.12)) {
                    scrollProxy.scrollTo(
                        nextId,
                        anchor: dragAutoScrollDirection > 0 ? .bottom : .top
                    )
                }

                scheduleAutoScrollTick(columnsCount: columnsCount, scrollProxy: scrollProxy)
            }

            dragAutoScrollWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }

        private func handleSelectionDragEnded() {
            isDragSelecting = false
            dragSelectionMode = nil
            dragAnchorAssetIndex = nil
            dragBaselineSelection.removeAll()
            dragCurrentAssetIndex = nil
            dragAutoScrollDirection = 0
            dragAutoScrollWorkItem?.cancel()
            dragAutoScrollWorkItem = nil
        }

        private func deleteSelectedAssets() {
            let ids = Array(selectedAssetIds)
            guard !ids.isEmpty else { return }
            let propertyID = appState.selectedPropertyID
            let sessionID = appState.currentSession?.id
            isDeletingSelection = true
            let completion: (Bool) -> Void = { success in
                isDeletingSelection = false
                if success {
                    if let propertyID, let sessionID {
                        try? localStore.removeShotMetadata(
                            propertyID: propertyID,
                            sessionID: sessionID,
                            originalFileIdentifiers: ids
                        )
                        cleanupLocalLinkedRecords(
                            propertyID: propertyID,
                            localIdentifiers: ids
                        )
                        onAfterDelete()
                    }
                    selectedAssetIds.removeAll()
                    isSelectionMode = false
                }
            }
            reportLibrary.deleteAssetsFromAlbum(localIdentifiers: ids, completion: completion)
        }

        private func cleanupLocalLinkedRecords(propertyID: UUID, localIdentifiers: [String]) {
            let normalized = Set(localIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !normalized.isEmpty else { return }
            let deletedShotIDs = Set(normalized.compactMap { path -> UUID? in
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                return UUID(uuidString: stem)
            })
            let isBaselineSession = !appState.propertyHasBaseline(propertyID)
            let currentSessionID = appState.currentSession?.id
            let baselineGuidedKeys = baselineGuidedTemplateKeys(propertyID: propertyID)
            let baselineFlaggedKeys = baselineFlaggedTemplateKeys(propertyID: propertyID)

            if var guided = try? localStore.fetchGuidedShots(propertyID: propertyID) {
                var didChangeGuided = false
                if isBaselineSession {
                    let before = guided.count
                    guided.removeAll { shot in
                        let imageID = shot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let shotID = shot.shot?.id
                        if normalized.contains(imageID) { return true }
                        if let shotID, deletedShotIDs.contains(shotID) { return true }
                        return false
                    }
                    didChangeGuided = guided.count != before
                } else {
                    var toRemoveIDs = Set<UUID>()
                    for index in guided.indices {
                        let imageID = guided[index].shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let shotID = guided[index].shot?.id
                        let matchesDeletedCapture = normalized.contains(imageID) || (shotID.map { deletedShotIDs.contains($0) } ?? false)
                        guard matchesDeletedCapture else { continue }
                        let key = checklistKey(
                            building: guided[index].building,
                            elevation: guided[index].targetElevation,
                            detailType: guided[index].detailType,
                            angleIndex: guided[index].angleIndex
                        )
                        let isExistingTemplateItem = key.map { baselineGuidedKeys.contains($0) } ?? false
                        if isExistingTemplateItem {
                            guided[index].shot = nil
                            guided[index].isCompleted = false
                            didChangeGuided = true
                        } else {
                            toRemoveIDs.insert(guided[index].id)
                            didChangeGuided = true
                        }
                    }
                    if !toRemoveIDs.isEmpty {
                        guided.removeAll { toRemoveIDs.contains($0.id) }
                    }
                }
                if didChangeGuided {
                    let normalizedGuided = normalizedGuidedShotsWithStableAngles(guided)
                    try? localStore.saveGuidedShots(normalizedGuided, propertyID: propertyID)
                }
            }

            if var observations = try? localStore.fetchObservations(propertyID: propertyID) {
                var didChangeObservations = false
                var deletedObservationIDs = Set<UUID>()
                if isBaselineSession {
                    observations.removeAll { observation in
                        guard observation.sessionID == currentSessionID else { return false }
                        let shouldDelete = observation.shots.contains(where: { shot in
                            let id = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if normalized.contains(id) { return true }
                            return deletedShotIDs.contains(shot.id)
                        })
                        if shouldDelete {
                            deletedObservationIDs.insert(observation.id)
                        }
                        return shouldDelete
                    }
                    didChangeObservations = !deletedObservationIDs.isEmpty
                } else {
                    var toRemoveObservationIDs = Set<UUID>()
                    for idx in observations.indices {
                        let removedShotIDsForObservation = Set(observations[idx].shots.compactMap { shot -> UUID? in
                            let id = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let matchedDeleted = normalized.contains(id) || deletedShotIDs.contains(shot.id)
                            return matchedDeleted ? shot.id : nil
                        })
                        let removedAnyForObservation = observations[idx].shots.contains(where: { shot in
                            let id = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            return normalized.contains(id) || deletedShotIDs.contains(shot.id)
                        })
                        guard removedAnyForObservation else { continue }
                        let removedLinked = observations[idx].shots.contains(where: { shot in
                            let id = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let matchedDeleted = normalized.contains(id) || deletedShotIDs.contains(shot.id)
                            return matchedDeleted && observations[idx].linkedShotID == shot.id
                        })
                        let beforeCount = observations[idx].shots.count
                        observations[idx].shots.removeAll { shot in
                            let id = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            return normalized.contains(id) || deletedShotIDs.contains(shot.id)
                        }
                        if observations[idx].shots.count != beforeCount {
                            if !removedShotIDsForObservation.isEmpty {
                                observations[idx].updateHistory.removeAll { entry in
                                    guard let shotID = entry.shotID else { return false }
                                    return removedShotIDsForObservation.contains(shotID)
                                }
                            }
                            didChangeObservations = true
                            if let linked = observations[idx].linkedShotID,
                               !observations[idx].shots.contains(where: { $0.id == linked }) {
                                observations[idx].linkedShotID = observations[idx].shots.last?.id
                            }
                            let wasCurrentSessionFlagUpdate = observations[idx].updatedInSessionID == currentSessionID || observations[idx].resolvedInSessionID == currentSessionID
                            let key = checklistKey(
                                building: observations[idx].building,
                                elevation: observations[idx].targetElevation,
                                detailType: observations[idx].detailType,
                                angleIndex: 1
                            )
                            let isExistingTemplateItem = key.map { baselineFlaggedKeys.contains($0) || baselineGuidedKeys.contains($0) } ?? false
                            let isNewThisSessionItem = observations[idx].sessionID == currentSessionID && !isExistingTemplateItem
                            if isNewThisSessionItem {
                                toRemoveObservationIDs.insert(observations[idx].id)
                                continue
                            }
                            if removedLinked || wasCurrentSessionFlagUpdate {
                                observations[idx].status = .active
                                observations[idx].resolvedInSessionID = nil
                                observations[idx].updatedInSessionID = nil
                                observations[idx].resolutionPhotoRef = nil
                                observations[idx].resolutionStatement = nil
                            }
                        }
                    }
                    if !toRemoveObservationIDs.isEmpty {
                        deletedObservationIDs.formUnion(toRemoveObservationIDs)
                        observations.removeAll { toRemoveObservationIDs.contains($0.id) }
                    }
                }
                if didChangeObservations {
                    for id in deletedObservationIDs {
                        try? localStore.deleteObservation(id: id, propertyID: propertyID)
                    }
                    for obs in observations {
                        _ = try? localStore.updateObservation(obs)
                    }
                }
            }
        }

        private func checklistKey(
            building: String?,
            elevation: String?,
            detailType: String?,
            angleIndex: Int?
        ) -> String? {
            let b = building?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let e = CanonicalElevation.normalize(elevation)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let d = detailType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let a = max(1, angleIndex ?? 1)
            guard !b.isEmpty, !e.isEmpty, !d.isEmpty else { return nil }
            return "\(b)|\(e)|\(d)|\(a)"
        }

        private func baselineGuidedTemplateKeys(propertyID: UUID) -> Set<String> {
            guard let baselineSessionID = appState.selectedProperty?.baselineSessionID else { return [] }
            let sessions = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
            let baselineSession = sessions.first(where: { $0.id == baselineSessionID })
            let start = baselineSession?.startedAt ?? .distantPast
            let end = baselineSession?.endedAt ?? .distantFuture
            let guided = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
            var keys = Set<String>()
            for item in guided {
                guard let key = checklistKey(
                    building: item.building,
                    elevation: item.targetElevation,
                    detailType: item.detailType,
                    angleIndex: item.angleIndex
                ) else { continue }
                let hasReference = !(item.referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(item.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let capturedInBaseline = (item.shot?.capturedAt ?? .distantPast) >= start && (item.shot?.capturedAt ?? .distantPast) <= end
                if hasReference || capturedInBaseline {
                    keys.insert(key)
                }
            }
            return keys
        }

        private func baselineFlaggedTemplateKeys(propertyID: UUID) -> Set<String> {
            guard let baselineSessionID = appState.selectedProperty?.baselineSessionID else { return [] }
            let observations = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
            var keys = Set<String>()
            for observation in observations where observation.sessionID == baselineSessionID {
                guard let key = checklistKey(
                    building: observation.building,
                    elevation: observation.targetElevation,
                    detailType: observation.detailType,
                    angleIndex: 1
                ) else { continue }
                keys.insert(key)
            }
            return keys
        }
        
        private func beginExport() {
            guard !isPreparingExport else { return }
            showExportError = false
            exportErrorMessage = nil
            isPreparingExport = true
            
            let assets = reportLibrary.assets
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let zipURL = try buildExportArchive(for: assets)
                    DispatchQueue.main.async {
                        isPreparingExport = false
                        exportFile = ExportFile(url: zipURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        isPreparingExport = false
                        exportErrorMessage = error.localizedDescription
                        showExportError = true
                    }
                }
            }
        }
        
        private func buildExportArchive(for assets: [ReportAsset]) throws -> URL {
            let fileManager = FileManager.default
            guard let propertyID = appState.selectedPropertyID,
                  let session = appState.currentSession else {
                throw ExportError.zipCreationFailed
            }
            let sessionID = session.id
            let exportArtifacts = try localStore.validatedSessionExportArtifacts(for: session)
            let propertyFolderName = try localStore.exportPropertyFolderName(propertyID: propertyID)
            let exportRoot = try StorageRoot.makeSessionExportRootFolder(
                propertyFolderName: propertyFolderName,
                sessionID: sessionID
            )
            let originalsRoot = exportRoot.appendingPathComponent("Originals", isDirectory: true)
            let stampedRoot = exportRoot.appendingPathComponent("Stamped", isDirectory: true)
            try fileManager.createDirectory(at: originalsRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stampedRoot, withIntermediateDirectories: true)

#if DEBUG
            let sourceURL = localStore.sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
            let exists = FileManager.default.fileExists(atPath: sourceURL.path)
            let sizeBytes = ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
            print("Export session.json path source: \(sourceURL.path)")
            print("Export source exists: \(exists ? "YES" : "NO"), bytes: \(sizeBytes)")
            let raw = String(data: exportArtifacts.sessionData, encoding: .utf8) ?? ""
            print("Export sessionData contains \"shotKey\": \(raw.contains("\"shotKey\"") ? "YES" : "NO")")
            print("Export sessionData contains \"originalRelativePath\": \(raw.contains("\"originalRelativePath\"") ? "YES" : "NO")")
            let debugDecoder = JSONDecoder()
            debugDecoder.dateDecodingStrategy = .iso8601
            if let decoded = try? debugDecoder.decode(SessionMetadata.self, from: exportArtifacts.sessionData),
               let first = decoded.shots.first {
                print("Export sessionStartedAt: \(decoded.startedAt)")
                print("Export sessionStartedAtLocal: \(decoded.sessionStartedAtLocal)")
                print("Export first shot shotKey: \(first.shotKey)")
                print("Export first shot createdAt: \(first.createdAt)")
                print("Export first shot createdAtLocal: \(first.capturedAtLocal ?? "nil")")
                print("Export first shot originalRelativePath: \(first.originalRelativePath)")
                if let delivered = decoded.firstDeliveredAt {
                    print("Export firstDeliveredAt: \(delivered)")
                }
                if let expires = decoded.reExportExpiresAt {
                    print("Export reExportExpiresAt: \(expires)")
                }
            }
            print("EXPORT ROOT: \(exportRoot.path)")
#endif
            try exportArtifacts.sessionData.write(to: exportRoot.appendingPathComponent("session.json"), options: .atomic)
            try exportArtifacts.validationData.write(to: exportRoot.appendingPathComponent("validation.txt"), options: .atomic)
            for csvFile in localStore.exportCSVFiles(for: exportArtifacts.metadata) {
                try csvFile.data.write(to: exportRoot.appendingPathComponent(csvFile.filename), options: .atomic)
            }
            
            for (index, asset) in assets.enumerated() {
                guard let imageData = requestOriginalImageData(for: asset) else { continue }
                let filename = makeArchiveFilename(for: asset, index: index + 1)
                try imageData.write(to: originalsRoot.appendingPathComponent(filename), options: .atomic)
                try imageData.write(to: stampedRoot.appendingPathComponent(filename), options: .atomic)
            }
#if DEBUG
            print("EXPORT ROOT FILES: \((try? StorageRoot.exportRootFilenames(exportRoot)) ?? [])")
#endif
            
            let zipEntries = try StorageRoot.zipEntriesForExportRoot(exportRoot).map { ($0.path, $0.data) }
            let zipData = buildZipData(entries: zipEntries)
            let zipURL = fileManager.temporaryDirectory.appendingPathComponent(exportZipFilename())
            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }
            try zipData.write(to: zipURL, options: .atomic)
            
            if !fileManager.fileExists(atPath: zipURL.path) {
                throw ExportError.zipCreationFailed
            }
#if DEBUG
            let zipPaths = Set(try listZipEntryPaths(at: zipURL))
            guard zipPaths.contains("session.json"), zipPaths.contains("validation.txt") else {
                assertionFailure("Export ZIP root missing session.json or validation.txt")
                throw ExportError.zipCreationFailed
            }
#endif
#if DEBUG
            if !exportArtifacts.prewritePassed || !exportArtifacts.postwritePassed {
                assertionFailure(String(data: exportArtifacts.validationData, encoding: .utf8) ?? "Export validation failed")
            }
#endif
            return zipURL
        }
        
        private func makeExportSessionPayload(from assets: [ReportAsset]) -> ExportSessionPayload {
            let entries = assets.enumerated().map { index, asset in
                ExportAssetEntry(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    originalFilename: makeArchiveFilename(for: asset, index: index + 1)
                )
            }
            
            let property = appState.selectedProperty
            let observations: [Observation]
            let guidedShots: [GuidedShot]
            if let propertyID = property?.id {
                observations = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
                guidedShots = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
            } else {
                observations = []
                guidedShots = []
            }
            
            return ExportSessionPayload(
                exportedAt: Date(),
                albumTitle: reportLibrary.albumTitle,
                albumLocalId: reportLibrary.albumLocalId,
                property: property,
                session: appState.currentSession,
                activeIssueCount: reportLibrary.activeIssueCount,
                assets: entries,
                observations: observations,
                guidedShots: guidedShots
            )
        }
        
        private func requestOriginalImageData(for asset: ReportAsset) -> Data? {
            try? Data(contentsOf: asset.fileURL)
        }
        
        private func makeArchiveFilename(for asset: ReportAsset, index: Int) -> String {
            let fallback = "photo-\(index).heic"
            let original = asset.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = URL(fileURLWithPath: original).lastPathComponent
            let resolved = baseName.isEmpty ? fallback : baseName
            return resolved.replacingOccurrences(of: "/", with: "-")
        }
        
        private func exportZipFilename() -> String {
            let propertyName = appState.selectedProperty?.name ?? reportLibrary.albumTitle
            let trimmedName = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = trimmedName.isEmpty
                ? "ScoutCapture-Export"
                : trimmedName
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
            let propertyPrefix = String((appState.selectedProperty?.id.uuidString ?? "unknown").prefix(8))
            let sessionPrefix = String((appState.currentSession?.id.uuidString ?? UUID().uuidString).prefix(8))
            return "\(safeName)_\(propertyPrefix)_\(sessionPrefix).zip"
        }
        
        private func buildZipData(entries: [(path: String, data: Data)]) -> Data {
            struct CentralRecord {
                let pathData: Data
                let crc32: UInt32
                let size: UInt32
                let localHeaderOffset: UInt32
            }
            
            var zip = Data()
            var centralRecords: [CentralRecord] = []
            centralRecords.reserveCapacity(entries.count)
            
            for entry in entries {
                let pathData = Data(entry.path.utf8)
                let crc = crc32(entry.data)
                let size = UInt32(entry.data.count)
                let localHeaderOffset = UInt32(zip.count)
                
                appendUInt32LE(0x04034B50, to: &zip)
                appendUInt16LE(20, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt32LE(crc, to: &zip)
                appendUInt32LE(size, to: &zip)
                appendUInt32LE(size, to: &zip)
                appendUInt16LE(UInt16(pathData.count), to: &zip)
                appendUInt16LE(0, to: &zip)
                zip.append(pathData)
                zip.append(entry.data)
                
                centralRecords.append(
                    CentralRecord(
                        pathData: pathData,
                        crc32: crc,
                        size: size,
                        localHeaderOffset: localHeaderOffset
                    )
                )
            }
            
            let centralDirectoryOffset = UInt32(zip.count)
            
            for record in centralRecords {
                appendUInt32LE(0x02014B50, to: &zip)
                appendUInt16LE(20, to: &zip)
                appendUInt16LE(20, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt32LE(record.crc32, to: &zip)
                appendUInt32LE(record.size, to: &zip)
                appendUInt32LE(record.size, to: &zip)
                appendUInt16LE(UInt16(record.pathData.count), to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt16LE(0, to: &zip)
                appendUInt32LE(0, to: &zip)
                appendUInt32LE(record.localHeaderOffset, to: &zip)
                zip.append(record.pathData)
            }
            
            let centralDirectorySize = UInt32(zip.count) - centralDirectoryOffset
            let count = UInt16(centralRecords.count)
            
            appendUInt32LE(0x06054B50, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(count, to: &zip)
            appendUInt16LE(count, to: &zip)
            appendUInt32LE(centralDirectorySize, to: &zip)
            appendUInt32LE(centralDirectoryOffset, to: &zip)
            appendUInt16LE(0, to: &zip)
            
            return zip
        }

        private func listZipEntryPaths(at url: URL) throws -> [String] {
            let data = try Data(contentsOf: url)
            let bytes = [UInt8](data)
            let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
            guard let eocdIndex = bytes.lastIndex(of: eocdSignature[0]).flatMap({ idx -> Int? in
                var i = idx
                while i >= 0 {
                    if i + 3 < bytes.count && bytes[i...i+3].elementsEqual(eocdSignature) { return i }
                    if i == 0 { break }
                    i -= 1
                }
                return nil
            }) else {
                throw ExportError.zipCreationFailed
            }

            func u16(_ offset: Int) -> Int {
                Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            }
            func u32(_ offset: Int) -> Int {
                Int(bytes[offset]) |
                (Int(bytes[offset + 1]) << 8) |
                (Int(bytes[offset + 2]) << 16) |
                (Int(bytes[offset + 3]) << 24)
            }

            guard eocdIndex + 22 <= bytes.count else {
                throw ExportError.zipCreationFailed
            }

            let totalEntries = u16(eocdIndex + 10)
            let centralDirectoryOffset = u32(eocdIndex + 16)
            var cursor = centralDirectoryOffset
            var paths: [String] = []
            paths.reserveCapacity(totalEntries)

            for _ in 0..<totalEntries {
                guard cursor + 46 <= bytes.count else { break }
                let signature = u32(cursor)
                guard signature == 0x02014B50 else { break }
                let nameLength = u16(cursor + 28)
                let extraLength = u16(cursor + 30)
                let commentLength = u16(cursor + 32)
                let nameStart = cursor + 46
                let nameEnd = nameStart + nameLength
                guard nameEnd <= bytes.count else { break }
                let path = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                paths.append(path)
                cursor = nameEnd + extraLength + commentLength
            }

            return paths
        }
        
        private func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    if (crc & 1) == 1 {
                        crc = (crc >> 1) ^ 0xEDB8_8320
                    } else {
                        crc >>= 1
                    }
                }
            }
            return crc ^ 0xFFFF_FFFF
        }
        
        private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { rawBuffer in
                data.append(contentsOf: rawBuffer)
            }
        }
        
        private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { rawBuffer in
                data.append(contentsOf: rawBuffer)
            }
        }
        
        private struct LibraryThumb: View {
            
            let asset: ReportAsset
            @ObservedObject var cache: AssetImageCache
            let side: CGFloat
            let refreshToken: UUID
            let isSelectionMode: Bool
            let isSelected: Bool
            
            @State private var img: UIImage? = nil
            
            var body: some View {
                ZStack {
                    Color.black
                    
                    if let img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .clipped()
                    } else {
                        Color.white.opacity(0.06)
                            .frame(width: side, height: side)
                    }

                    if isSelectionMode {
                        if isSelected {
                            Color.black.opacity(0.28)
                                .frame(width: side, height: side)
                        }

                        Circle()
                            .fill(isSelected ? Color.blue : Color.black.opacity(0.30))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 1.6)
                            )
                            .overlay(
                                Image(systemName: isSelected ? "checkmark" : "")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
                .frame(width: side, height: side)
                .clipped()
                .onAppear {
                    if img != nil { return }
                    let scale = UIScreen.currentScale
                    let px = max(300, side * 3) * scale
                    cache.requestThumbnail(for: asset, pixelSize: px) { im in
                        DispatchQueue.main.async {
                            self.img = im
                        }
                    }
                }
                .onChange(of: refreshToken) { _, _ in
                    let scale = UIScreen.currentScale
                    let px = max(300, side * 3) * scale
                    cache.requestThumbnail(for: asset, pixelSize: px) { im in
                        DispatchQueue.main.async {
                            self.img = im
                        }
                    }
                }
            }
        }

        private struct ActivityShareSheet: UIViewControllerRepresentable {
            let activityItems: [Any]

            func makeUIViewController(context: Context) -> UIActivityViewController {
                UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            }

            func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
        }
        
        private struct DocumentExportPicker: UIViewControllerRepresentable {
            let fileURL: URL
            let onComplete: (Bool) -> Void

            func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
                let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
                picker.delegate = context.coordinator
                return picker
            }

            func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }
            
            func makeCoordinator() -> Coordinator {
                Coordinator(onComplete: onComplete)
            }
            
            final class Coordinator: NSObject, UIDocumentPickerDelegate {
                let onComplete: (Bool) -> Void
                
                init(onComplete: @escaping (Bool) -> Void) {
                    self.onComplete = onComplete
                }
                
                func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                    onComplete(!urls.isEmpty)
                }
                
                func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
                    onComplete(false)
                }
            }
        }
    }

    // MARK: - Detail Note Modal (rotates + landscape keyboard)
    
    
    
    
    private struct DetailNoteModal: View {
        
        let elevation: String
        let detailType: String
        let existingNote: String
        
        let onCancel: () -> Void
        let onSave: (String) -> Void
        
        @State private var draft: String
        @FocusState private var isFocused: Bool
        
        init(
            elevation: String,
            detailType: String,
            existingNote: String,
            onCancel: @escaping () -> Void,
            onSave: @escaping (String) -> Void
        ) {
            self.elevation = elevation
            self.detailType = detailType
            self.existingNote = existingNote
            self.onCancel = onCancel
            self.onSave = onSave
            _draft = State(initialValue: existingNote)
        }
        
        private var hasExistingNote: Bool {
            !existingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        
        var body: some View {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isFocused = false
                        onCancel()
                    }
                
                VStack(spacing: 12) {
                    Text("\(elevation)  \(detailType)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                    
                    ZStack(alignment: .trailing) {
                        TextField("Enter detail note", text: $draft)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .padding(.trailing, draft.isEmpty ? 12 : 34)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .foregroundColor(.primary)
                            .focused($isFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                onSave(trimmed)
                            }
                        
                        if !draft.isEmpty {
                            Button { draft = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    HStack(spacing: 10) {
                        Button(action: {
                            isFocused = false
                            onCancel()
                        }) {
                            Text("Cancel")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white.opacity(0.90))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        
                        Button(action: {
                            isFocused = false
                            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(trimmed)
                        }) {
                            Text(hasExistingNote ? "Update" : "Save")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: 0)
            }
            .onAppear {
                // Focus immediately
                isFocused = true
            }
            // Keep the popup centered. Do not let SwiftUI move the layout to avoid the keyboard.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
    
    // MARK: - Manage Detail Types View

    private struct SheetControlTheme {
        let fill: Color
        let stroke: Color
        let label: Color

        static func forScheme(_ scheme: ColorScheme) -> SheetControlTheme {
            if scheme == .light {
                return SheetControlTheme(
                    fill: Color.white.opacity(0.90),
                    stroke: Color.black.opacity(0.14),
                    label: Color.black.opacity(0.88)
                )
            }
            return SheetControlTheme(
                fill: Color.black.opacity(0.55),
                stroke: Color.white.opacity(0.28),
                label: Color.white
            )
        }
    }

    private struct SharedActionMenuItem: Identifiable {
        let id = UUID()
        let title: String
        var isEnabled: Bool = true
        let action: () -> Void
    }

    private struct SharedActionMenuOverlay: View {
        let rotation: Angle
        let items: [SharedActionMenuItem]
        let onDismiss: () -> Void

        var body: some View {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismiss()
                    }

                VStack(spacing: 0) {
                    HStack {
                        Text("Actions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                        Spacer(minLength: 0)
                        Button("Done") {
                            onDismiss()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.20))

                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button(action: item.action) {
                                HStack(spacing: 10) {
                                    Text(item.title)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white.opacity(0.95))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.78)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .disabled(!item.isEnabled)
                            .opacity(item.isEnabled ? 1.0 : 0.45)

                            if index != items.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 1)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
                .padding(.horizontal, 20)
                .frame(maxWidth: 360)
                .rotationEffect(rotation)
            }
        }
    }

    private struct ManageDetailTypesView: View {
        
        let mode: ContentView.LocationMode
        @ObservedObject var model: DetailTypesModel
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        
        @Environment(\.dismiss) private var dismiss
        @State private var editModeState: EditMode = .inactive
        @FocusState private var focusedRow: UUID?
        
        private var titleText: String {
            mode == .interior ? "Interior Detail Types" : "Exterior Detail Types"
        }
        
        private var isEditing: Bool { editModeState == .active }
        
        var body: some View {
            NavigationStack {
                List {
                    let items = model.types(for: mode)
                    
                    ForEach(items) { item in
                        rowView(item: item)
                    }
                    .onDelete { offsets in
                        withAnimation(.none) { model.delete(at: offsets, for: mode) }
                    }
                    .onMove { source, destination in
                        withAnimation(.none) { model.move(from: source, to: destination, for: mode) } // fixed label for iOS 26
                    }
                }
                .environment(\.editMode, $editModeState)
                .listStyle(.insetGrouped)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
                            toolbarCapsuleLabel {
                                Text("Done")
                                    .font(.system(size: 17, weight: .medium))
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)

                        Text(titleText)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(theme.label)
                            .minimumScaleFactor(0.72)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        HStack(spacing: 0) {
                            Button {
                                if editModeState != .active { editModeState = .active }
                                let newId = model.insertBlankItem(for: mode)
                                DispatchQueue.main.async { focusedRow = newId }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 44, height: 42)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                if editModeState == .active {
                                    editModeState = .inactive
                                    focusedRow = nil
                                } else {
                                    editModeState = .active
                                }
                            } label: {
                                Group {
                                    if editModeState == .active {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 17, weight: .medium))
                                    } else {
                                        Text("Edit")
                                            .font(.system(size: 17, weight: .medium))
                                    }
                                }
                                .foregroundColor(theme.label)
                                .frame(width: 72, height: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(theme.fill)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .background(Color.clear)
                }
            }
        }

        @ViewBuilder
        private func toolbarCapsuleLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
            content()
                .foregroundColor(theme.label)
                .frame(minHeight: 42)
                .padding(.horizontal, 14)
                .padding(.vertical, 0)
                .background(theme.fill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(theme.stroke, lineWidth: 1)
                )
        }
        
        @ViewBuilder
        private func rowView(item: DetailTypesModel.DetailTypeItem) -> some View {
            if isEditing {
                TextField("Name", text: bindingForRow(id: item.id))
                    .focused($focusedRow, equals: item.id)
                    .submitLabel(.done)
                    .onSubmit { focusedRow = nil }
            } else {
                Text(item.name.isEmpty ? " " : item.name)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.primary)
            }
        }
        
        private func bindingForRow(id: UUID) -> Binding<String> {
            Binding(
                get: {
                    let items = model.types(for: mode)
                    return items.first(where: { $0.id == id })?.name ?? ""
                },
                set: { newValue in
                    withAnimation(.none) {
                        model.updateItem(newValue, id: id, for: mode)
                    }
                }
            )
        }
    }
    
    // MARK: - Report Sheets

    private struct ChecklistReclassifySheet: View {
        private enum DirectionChoice: String, CaseIterable, Identifiable {
            case interior = "Interior"
            case north = "North"
            case south = "South"
            case east = "East"
            case west = "West"

            var id: String { rawValue }

            var elevationValue: String { rawValue }

            var locationMode: ContentView.LocationMode {
                self == .interior ? .interior : .exterior
            }

            static func fromElevation(_ elevation: String?) -> DirectionChoice {
                let normalized = (CanonicalElevation.normalize(elevation) ?? elevation ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch normalized {
                case "South": return .south
                case "East": return .east
                case "West": return .west
                case "Interior": return .interior
                default: return .north
                }
            }
        }

        let title: String
        let initialBuilding: String?
        let initialElevation: String?
        let initialDetailType: String?
        @Binding var buildingOptions: [String]
        @ObservedObject var detailTypesModel: DetailTypesModel
        let buildingCodeForOption: (String) -> String
        let buildingDisplayNameForOption: (String) -> String
        let onCancel: () -> Void
        let onConfirm: (String, String, String) -> Void

        @State private var selectedBuilding: String = ""
        @State private var selectedDirection: DirectionChoice = .north
        @State private var selectedDetailType: String = ""
        @State private var showManageBuildingsSheet: Bool = false
        @State private var manageDetailMode: ContentView.LocationMode? = nil
        @State private var activePicker: PickerKind? = nil

        private enum PickerKind: Identifiable {
            case building
            case elevation
            case detail

            var id: Int {
                switch self {
                case .building: return 1
                case .elevation: return 2
                case .detail: return 3
                }
            }
        }

        private var availableDetailTypes: [DetailTypesModel.DetailTypeItem] {
            detailTypesModel.types(for: selectedDirection.locationMode)
        }

        private var canConfirm: Bool {
            !selectedBuilding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !selectedDetailType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var body: some View {
            NavigationStack {
                List {
                    Section {
                        selectorRow(
                            title: "Building",
                            value: buildingLabel(for: selectedBuilding)
                        ) {
                            activePicker = .building
                        }

                        selectorRow(
                            title: "Elevation",
                            value: selectedDirection.rawValue
                        ) {
                            activePicker = .elevation
                        }

                        selectorRow(
                            title: "Detail",
                            value: selectedDetailType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Select" : selectedDetailType
                        ) {
                            activePicker = .detail
                        }
                    } footer: {
                        Text("Angle is Auto. If the destination slot is occupied, the next available angle is assigned automatically.")
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Confirm") {
                            onConfirm(
                                selectedBuilding,
                                selectedDirection.elevationValue,
                                selectedDetailType
                            )
                        }
                        .disabled(!canConfirm)
                    }
                }
                .onAppear {
                    let trimmedBuilding = initialBuilding?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fallbackBuilding = buildingOptions.first.map(buildingCodeForOption) ?? "B1"
                    selectedBuilding = trimmedBuilding.isEmpty ? fallbackBuilding : trimmedBuilding
                    selectedDirection = DirectionChoice.fromElevation(initialElevation)
                    selectedDetailType = initialDetailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    normalizeDetailTypeSelection()
                }
                .onChange(of: selectedDirection) { _, _ in
                    normalizeDetailTypeSelection()
                }
                .onChange(of: buildingOptions) { _, _ in
                    let selectedCode = selectedBuilding.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !buildingOptions.contains(where: { buildingCodeForOption($0) == selectedCode }),
                       let fallback = buildingOptions.first {
                        selectedBuilding = buildingCodeForOption(fallback)
                    }
                }
                .sheet(isPresented: $showManageBuildingsSheet) {
                    ManageBuildingsSheet(
                        options: $buildingOptions,
                        selectedBuilding: $selectedBuilding,
                        buildingCodeForOption: buildingCodeForOption,
                        buildingFullLabelForOption: buildingDisplayNameForOption,
                        onClose: {
                            showManageBuildingsSheet = false
                        }
                    )
                }
                .sheet(item: $manageDetailMode) { mode in
                    ManageDetailTypesView(mode: mode, model: detailTypesModel)
                }
                .overlay {
                    pickerOverlay
                }
            }
        }

        private func selectorRow(
            title: String,
            value: String,
            action: @escaping () -> Void
        ) -> some View {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))

                Spacer(minLength: 0)

                Button(action: action) {
                    HStack(spacing: 8) {
                        Text(value)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }

        @ViewBuilder
        private var pickerOverlay: some View {
            if let activePicker {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.activePicker = nil
                        }

                    pickerContent(for: activePicker)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 360)
                }
                .transition(.opacity)
            }
        }

        @ViewBuilder
        private func pickerContent(for picker: PickerKind) -> some View {
            VStack(spacing: 0) {
                pickerHeader(title: pickerTitle(for: picker))

                switch picker {
                case .building:
                    VStack(spacing: 0) {
                        ForEach(buildingOptions, id: \.self) { option in
                            let optionCode = buildingCodeForOption(option)
                            pickerRow(
                                title: buildingDisplayNameForOption(option),
                                isSelected: selectedBuilding == optionCode
                            ) {
                                selectedBuilding = optionCode
                                activePicker = nil
                            }

                            if option != buildingOptions.last {
                                pickerDivider()
                            }
                        }
                        pickerDivider()
                        pickerRow(title: "Manage...", isSelected: false) {
                            activePicker = nil
                            showManageBuildingsSheet = true
                        }
                    }
                    .padding(.vertical, 6)

                case .elevation:
                    VStack(spacing: 0) {
                        ForEach(DirectionChoice.allCases) { option in
                            pickerRow(title: option.rawValue, isSelected: selectedDirection == option) {
                                selectedDirection = option
                                activePicker = nil
                            }
                            if option.id != DirectionChoice.allCases.last?.id {
                                pickerDivider()
                            }
                        }
                    }
                    .padding(.vertical, 6)

                case .detail:
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(availableDetailTypes) { item in
                                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !name.isEmpty {
                                    pickerRow(title: name, isSelected: selectedDetailType == name) {
                                        selectedDetailType = name
                                        activePicker = nil
                                    }
                                    if item.id != availableDetailTypes.last?.id {
                                        pickerDivider()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 320)

                    pickerDivider()
                    pickerRow(title: "Manage...", isSelected: false) {
                        activePicker = nil
                        manageDetailMode = selectedDirection.locationMode
                    }
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
        }

        private func pickerTitle(for picker: PickerKind) -> String {
            switch picker {
            case .building: return "Building"
            case .elevation: return "Elevation"
            case .detail: return "Detail"
            }
        }

        private func pickerHeader(title: String) -> some View {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
                Button("Done") {
                    activePicker = nil
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.20))
        }

        private func pickerRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }

        private func pickerDivider() -> some View {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 12)
        }

        private func buildingLabel(for code: String) -> String {
            guard let option = buildingOptions.first(where: { buildingCodeForOption($0) == code }) else {
                return code
            }
            return buildingDisplayNameForOption(option)
        }

        private func normalizeDetailTypeSelection() {
            let available = availableDetailTypes
                .map(\.name)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if available.contains(selectedDetailType) { return }
            selectedDetailType = available.first ?? ""
        }
    }

    private struct GuidedChecklistOverlay: View {
        let guidedShots: [GuidedShot]
        let resolvedThumbnailPathByID: [UUID: String]
        let referencePathByID: [UUID: String]
        let currentSessionID: UUID?
        let currentSessionStartedAt: Date?
        let currentSessionEndedAt: Date?
        let isBaselineSession: Bool
        let allowReferenceFallback: Bool
        @Binding var buildingOptions: [String]
        @ObservedObject var detailTypesModel: DetailTypesModel
        let buildingCodeForOption: (String) -> String
        let buildingDisplayNameForOption: (String) -> String
        let refreshToken: UUID
        @ObservedObject var cache: AssetImageCache
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        let onClose: () -> Void
        let onRefresh: () -> Void
        let onSelectGuided: (GuidedShot) -> Void
        let onSkip: (GuidedShot, SkipReason, String?) -> Void
        let onUndoSkip: (GuidedShot) -> Void
        let onRetake: (GuidedShot) -> Void
        let onRetire: (GuidedShot) -> Void
        let onReclassify: (GuidedShot, String, String, String) -> Void

        @State private var skipTarget: GuidedShot? = nil
        @State private var showSkipReasonDialog: Bool = false
        @State private var showSkipOtherSheet: Bool = false
        @State private var skipOtherText: String = ""
        @State private var retakeTarget: GuidedShot? = nil
        @State private var showRetakeConfirmation: Bool = false
        @State private var guidedViewerState: GuidedViewerState? = nil
        @State private var retireTarget: GuidedShot? = nil
        @State private var showRetireConfirmation: Bool = false
        @State private var reclassifyTarget: GuidedShot? = nil
        @State private var inlineToastText: String? = nil
        @State private var inlineToastToken: Int = 0
        @State private var lastValidOrientation: UIDeviceOrientation = .portrait

        private struct GuidedViewerState: Identifiable {
            let id = UUID()
            let title: String
            let detailId: String
            let assets: [ReportAsset]
            let startIndex: Int
            let viewerToken: Int
        }

        private var isLandscape: Bool {
            lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight
        }

        private var rotationDegrees: Double {
            switch lastValidOrientation {
            case .landscapeLeft:
                return 90
            case .landscapeRight:
                return -90
            default:
                return 0
            }
        }

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let contentW = isLandscape ? h : w
                let contentH = isLandscape ? w : h

                NavigationStack {
                    ZStack {
                        Color(uiColor: .secondarySystemGroupedBackground)
                            .ignoresSafeArea()

                        List(guidedShots) { item in
                            GuidedChecklistRow(
                                guidedShot: item,
                                resolvedThumbnailPath: resolvedThumbnailPathByID[item.id],
                                referencePath: referencePathByID[item.id],
                                currentSessionID: currentSessionID,
                                isBaselineSession: isBaselineSession,
                                allowReferenceFallback: allowReferenceFallback,
                                isCapturedInCurrentSession: isCapturedInCurrentSession(item),
                                onTapRow: {
                                    onSelectGuided(item)
                                },
                                refreshToken: refreshToken,
                                cache: cache,
                                onTapSkip: {
                                    skipTarget = item
                                    showSkipReasonDialog = true
                                },
                                onTapRetake: {
                                    retakeTarget = item
                                    showRetakeConfirmation = true
                                },
                                onTapUndoSkip: {
                                    onUndoSkip(item)
                                },
                                onTapViewReferenceImage: {
                                    showGuidedReferencePreview(for: item)
                                },
                                onTapViewCapturedImage: {
                                    showGuidedCapturedPreview(for: item)
                                },
                                onTapRetire: {
                                    retireTarget = item
                                    showRetireConfirmation = true
                                },
                                onTapReclassify: {
                                    reclassifyTarget = item
                                }
                            )
                        }
                        .listStyle(.insetGrouped)
                        .scrollIndicators(.hidden)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 10) {
                            Button(action: onRefresh) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 44, height: 42)
                                    .background(theme.fill)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(theme.stroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Spacer(minLength: 0)

                            Text("Guided Checklist")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(theme.label)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Button(action: onClose) {
                                Text("Done")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 72, height: 42)
                                    .background(theme.fill)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(theme.stroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    }
                    .confirmationDialog("Skip reason", isPresented: $showSkipReasonDialog, titleVisibility: .visible) {
                        Button("Inaccessible") {
                            submitSkip(.inaccessible)
                        }
                        Button("Obstructed") {
                            submitSkip(.obstructed)
                        }
                        Button("Active construction") {
                            submitSkip(.activeConstruction)
                        }
                        Button("Safety concern") {
                            submitSkip(.safetyConcern)
                        }
                        Button("Other") {
                            showSkipOtherSheet = true
                        }
                        Button("Cancel", role: .cancel) {
                            skipTarget = nil
                        }
                    }
                    .sheet(isPresented: $showSkipOtherSheet, onDismiss: {
                        skipOtherText = ""
                        skipTarget = nil
                    }) {
                        NavigationStack {
                            VStack(spacing: 14) {
                                Text("Enter skip reason")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                TextField("Reason", text: $skipOtherText, axis: .vertical)
                                    .font(.system(size: 16, weight: .regular))
                                    .lineLimit(3...6)
                                    .padding(12)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .navigationTitle("Other")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Cancel") {
                                        showSkipOtherSheet = false
                                    }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Save") {
                                        submitSkip(.other, otherNote: skipOtherText)
                                        showSkipOtherSheet = false
                                    }
                                    .disabled(skipOtherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                        .presentationDetents([.height(280)])
                    }
                    .confirmationDialog("Retake this guided shot?", isPresented: $showRetakeConfirmation, titleVisibility: .visible) {
                        Button("Retake") {
                            guard let item = retakeTarget else { return }
                            onRetake(item)
                            retakeTarget = nil
                        }
                        Button("Cancel", role: .cancel) {
                            retakeTarget = nil
                        }
                    }
                    .confirmationDialog("Retire this guided checkpoint?", isPresented: $showRetireConfirmation, titleVisibility: .visible) {
                        Button("Retire", role: .destructive) {
                            guard let item = retireTarget else { return }
                            onRetire(item)
                            retireTarget = nil
                        }
                        Button("Cancel", role: .cancel) {
                            retireTarget = nil
                        }
                    } message: {
                        Text("This removes the checkpoint from future guided sessions and records the change in SCOUT JSON.")
                    }
                    .sheet(item: $reclassifyTarget) { target in
                        ChecklistReclassifySheet(
                            title: "Reclassify",
                            initialBuilding: target.building,
                            initialElevation: target.targetElevation,
                            initialDetailType: target.detailType,
                            buildingOptions: $buildingOptions,
                            detailTypesModel: detailTypesModel,
                            buildingCodeForOption: buildingCodeForOption,
                            buildingDisplayNameForOption: buildingDisplayNameForOption,
                            onCancel: {
                                reclassifyTarget = nil
                            },
                            onConfirm: { building, elevation, detailType in
                                onReclassify(target, building, elevation, detailType)
                                reclassifyTarget = nil
                            }
                        )
                    }
                    .fullScreenCover(item: $guidedViewerState) { state in
                        ReportPhotoViewer(
                            title: state.title,
                            assets: state.assets,
                            startIndex: state.startIndex,
                            detailIdOverride: state.detailId,
                            cache: cache,
                            viewerToken: state.viewerToken
                        )
                    }
                    .overlay(alignment: .top) {
                        if let inlineToastText {
                            Text(inlineToastText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.black.opacity(0.72))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                                .padding(.top, 64)
                                .transition(.opacity)
                        }
                    }
                }
                .frame(width: contentW, height: contentH, alignment: .center)
                .rotationEffect(.degrees(rotationDegrees))
                .position(x: w * 0.5, y: h * 0.5)
                .statusBarHidden(isLandscape)
                .onAppear {
                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                    refreshOrientation()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                    refreshOrientation()
                }
                .onDisappear {
                    UIDevice.current.endGeneratingDeviceOrientationNotifications()
                }
            }
        }

        private func submitSkip(_ reason: SkipReason, otherNote: String? = nil) {
            guard let item = skipTarget else { return }
            onSkip(item, reason, otherNote)
            skipTarget = nil
            skipOtherText = ""
        }

        private func showImagePreview(localIdentifier: String?, title: String, detailId: String) {
            let trimmed = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }

            guard let asset = ContentView.reportAsset(from: trimmed) else { return }
            guidedViewerState = GuidedViewerState(
                title: title,
                detailId: detailId,
                assets: [asset],
                startIndex: 0,
                viewerToken: trimmed.hashValue
            )
        }

        private func showGuidedReferencePreview(for guidedShot: GuidedShot) {
            guard let source = referencePathByID[guidedShot.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty else {
                showInlineToast("No reference available")
                return
            }
            showImagePreview(
                localIdentifier: source,
                title: "Reference Image",
                detailId: guidedDisplayLabel(for: guidedShot)
            )
        }

        private func showGuidedCapturedPreview(for guidedShot: GuidedShot) {
            guard isCapturedInCurrentSession(guidedShot) else {
                showInlineToast("No captured image yet.")
                return
            }
            showImagePreview(
                localIdentifier: guidedShot.shot?.imageLocalIdentifier,
                title: "Captured Image",
                detailId: guidedDisplayLabel(for: guidedShot)
            )
        }

        private func showInlineToast(_ text: String) {
            inlineToastText = text
            inlineToastToken += 1
            let token = inlineToastToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard token == inlineToastToken else { return }
                inlineToastText = nil
            }
        }

        private func guidedDisplayLabel(for guidedShot: GuidedShot) -> String {
            let concise = ContentView.conciseContextLabel(
                building: guidedShot.building,
                elevation: guidedShot.targetElevation,
                detailType: guidedShot.detailType
            )
            if !concise.isEmpty { return concise }
            return guidedShot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func isCapturedInCurrentSession(_ guidedShot: GuidedShot) -> Bool {
            guard let shot = guidedShot.shot else { return false }
            guard let startedAt = currentSessionStartedAt else { return false }
            if shot.capturedAt < startedAt {
                return false
            }
            if let endedAt = currentSessionEndedAt, shot.capturedAt > endedAt {
                return false
            }
            let path = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty, ContentView.reportAsset(from: path) != nil else {
                return false
            }
            return true
        }

        private func refreshOrientation() {
            let o = UIDevice.current.orientation
            let newValue: UIDeviceOrientation? = {
                switch o {
                case .portrait:
                    return .portrait
                case .landscapeLeft, .landscapeRight:
                    return o
                default:
                    return nil
                }
            }()

            guard let newValue else { return }
            guard newValue != lastValidOrientation else { return }
            lastValidOrientation = newValue
        }
    }

    private struct GuidedReassignSheet: View {
        let source: GuidedShot
        let candidates: [GuidedShot]
        let onCancel: () -> Void
        let onSelect: (UUID) -> Void

        private func label(for guidedShot: GuidedShot) -> String {
            let concise = ContentView.conciseContextLabel(
                building: guidedShot.building,
                elevation: guidedShot.targetElevation,
                detailType: guidedShot.detailType
            )
            return concise.isEmpty ? guidedShot.title : concise
        }

        var body: some View {
            NavigationStack {
                List(candidates) { candidate in
                    Button {
                        onSelect(candidate.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(for: candidate))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                            Text("Angle \(max(1, candidate.angleIndex ?? 1))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle("Reassign To")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: onCancel)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Move photo association from")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(label(for: source))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .background(Color(uiColor: .systemBackground))
                }
            }
        }
    }

    private struct GuidedChecklistRow: View {
        enum RowStatus {
            case pending
            case captured
            case skipped
        }

        let guidedShot: GuidedShot
        let resolvedThumbnailPath: String?
        let referencePath: String?
        let currentSessionID: UUID?
        let isBaselineSession: Bool
        let allowReferenceFallback: Bool
        let isCapturedInCurrentSession: Bool
        let onTapRow: () -> Void
        let refreshToken: UUID
        @ObservedObject var cache: AssetImageCache
        let onTapSkip: () -> Void
        let onTapRetake: () -> Void
        let onTapUndoSkip: () -> Void
        let onTapViewReferenceImage: () -> Void
        let onTapViewCapturedImage: () -> Void
        let onTapRetire: () -> Void
        let onTapReclassify: () -> Void

        @State private var thumbnail: UIImage? = nil
        @State private var loadedID: String = ""

        private var status: RowStatus {
            if isSkippedInCurrentSession { return .skipped }
            if isCapturedInCurrentSession { return .captured }
            return .pending
        }

        private var isSkippedInCurrentSession: Bool {
            guard let sessionID = currentSessionID else { return false }
            return guidedShot.skipReason != nil && guidedShot.skipSessionID == sessionID
        }

        private var statusLabel: String {
            switch status {
            case .pending: return "Pending"
            case .captured: return "Captured"
            case .skipped:
                return guidedShot.skipReason.map(skipReasonTitle(for:)) ?? "Skipped"
            }
        }

        private var statusColor: Color {
            switch status {
            case .pending: return .orange
            case .captured: return .green
            case .skipped: return .gray
            }
        }

        private var fullContextLabel: String {
            let composed = ContentView.conciseContextLabel(
                building: guidedShot.building,
                elevation: guidedShot.targetElevation,
                detailType: guidedShot.detailType
            )
            if !composed.isEmpty { return composed }
            let fallback = guidedShot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? "Guided Shot" : fallback
        }

        private var angleLabel: String {
            "Angle \(max(1, guidedShot.angleIndex ?? 1))"
        }

        private var hasReferenceImage: Bool {
            let resolvedReferencePath = referencePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !resolvedReferencePath.isEmpty
        }

        var body: some View {
            rowContent
            .onTapGesture {
                guard status == .pending else { return }
                onTapRow()
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    onTapRetire()
                } label: {
                    Label("Retire", systemImage: "archivebox")
                }
                .tint(.red)

                Button {
                    onTapReclassify()
                } label: {
                    Label("Reclassify", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.mint)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if status == .captured {
                    Button {
                        onTapRetake()
                    } label: {
                        Label("Retake", systemImage: "camera.rotate")
                    }
                    .tint(.orange)

                    if !isBaselineSession && hasReferenceImage {
                        Button {
                            onTapViewReferenceImage()
                        } label: {
                            Label("View Reference", systemImage: "photo.on.rectangle")
                        }
                        .tint(.indigo)
                    }

                    Button {
                        onTapViewCapturedImage()
                    } label: {
                        Label("View Captured", systemImage: "photo")
                    }
                    .tint(.blue)
                } else if !isBaselineSession && hasReferenceImage {
                    Button {
                        onTapViewReferenceImage()
                    } label: {
                        Label("View Reference", systemImage: "photo.on.rectangle")
                    }
                    .tint(.indigo)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(Color.clear)
            .onAppear {
                loadThumbnailIfNeeded()
            }
            .onChange(of: guidedShot.shot?.imageLocalIdentifier ?? "") { _, _ in
                loadThumbnailIfNeeded()
            }
            .onChange(of: guidedShot.referenceImageLocalIdentifier ?? "") { _, _ in
                loadThumbnailIfNeeded()
            }
            .onChange(of: guidedShot.referenceImagePath ?? "") { _, _ in
                loadThumbnailIfNeeded()
            }
            .onChange(of: currentSessionID) { _, _ in
                loadedID = ""
                thumbnail = nil
                loadThumbnailIfNeeded()
            }
            .onChange(of: isCapturedInCurrentSession) { _, _ in
                loadedID = ""
                thumbnail = nil
                loadThumbnailIfNeeded()
            }
            .onChange(of: refreshToken) { _, _ in
                loadedID = ""
                thumbnail = nil
                loadThumbnailIfNeeded()
            }
        }

        private var rowContent: some View {
            HStack(spacing: 12) {
                thumbnailView
                textView
                Spacer(minLength: 0)
                trailingActions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }

        private var thumbnailView: some View {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "photo")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if status == .captured {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
                        .padding(4)
                }
            }
        }

        private var textView: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(fullContextLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(angleLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.86))

                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)

                if status == .skipped {
                    Button {
                        onTapUndoSkip()
                    } label: {
                        Text("Undo Skip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        @ViewBuilder
        private var trailingActions: some View {
            switch status {
            case .pending:
                if !isBaselineSession {
                    Button(action: onTapSkip) {
                        Text("Skip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            case .skipped:
                EmptyView()
            case .captured:
                EmptyView()
            }
        }

        private func loadThumbnailIfNeeded() {
            let sessionIDText = currentSessionID?.uuidString ?? "NONE"
            let chosenPath = resolvedThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sourceID = "chosen:\(sessionIDText):\(chosenPath)"
            guard sourceID != loadedID || thumbnail == nil else { return }
            loadedID = sourceID

            guard !chosenPath.isEmpty, let asset = ContentView.reportAsset(fromPath: chosenPath) else {
                thumbnail = nil
                return
            }

            let px = max(120, 56 * UIScreen.currentScale * 2.0)
            cache.requestThumbnail(for: asset, pixelSize: px) { image in
                DispatchQueue.main.async {
                    self.thumbnail = image
                }
            }
        }

        private func skipReasonTitle(for reason: SkipReason) -> String {
            switch reason {
            case .inaccessible: return "Skipped - Inaccessible"
            case .obstructed: return "Skipped - Obstructed"
            case .activeConstruction: return "Skipped - Active construction"
            case .safetyConcern: return "Skipped - Safety concern"
            case .other: return "Skipped - Other"
            case .notVisible: return "Skipped - Not visible"
            case .unsafe: return "Skipped - Unsafe"
            case .blocked: return "Skipped - Blocked"
            case .notApplicable: return "Skipped - Not applicable"
            }
        }
    }

    private struct ActiveIssuesSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        let observations: [Observation]
        let currentSessionID: UUID?
        let sessionShotIDs: Set<UUID>
        let resolvedThumbnailPathByID: [UUID: String]
        let referencePathByID: [UUID: String]
        let allowReferenceFallback: Bool
        @Binding var buildingOptions: [String]
        @ObservedObject var detailTypesModel: DetailTypesModel
        let buildingCodeForOption: (String) -> String
        let buildingDisplayNameForOption: (String) -> String
        let cache: AssetImageCache
        let onRefresh: () -> Void
        let onSelectIssue: (Observation) -> Void
        let onRetakeIssue: (Observation) -> Void
        let onReclassifyIssue: (Observation, String, String, String) -> Void
        @State private var lastValidOrientation: UIDeviceOrientation = .portrait
        @State private var reclassifyTargetObservation: Observation? = nil
        @State private var historyTargetObservation: Observation? = nil
        @State private var flaggedViewerState: FlaggedViewerState? = nil
        @State private var inlineToastText: String? = nil
        @State private var inlineToastToken: Int = 0

        private var theme: SheetControlTheme { .forScheme(colorScheme) }

        private struct FlaggedViewerState: Identifiable {
            let id = UUID()
            let title: String
            let detailId: String
            let asset: ReportAsset
            let viewerToken: Int
        }

        private var isLandscape: Bool {
            lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight
        }

        private var rotationDegrees: Double {
            switch lastValidOrientation {
            case .landscapeLeft:
                return 90
            case .landscapeRight:
                return -90
            default:
                return 0
            }
        }

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let contentW = isLandscape ? h : w
                let contentH = isLandscape ? w : h

                NavigationStack {
                    Group {
                        if observations.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "flag.slash")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text("No active issues")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(observations) { observation in
                                FlaggedIssueRow(
                                    observation: observation,
                                    currentSessionID: currentSessionID,
                                    resolvedThumbnailPath: resolvedThumbnailPathByID[observation.id],
                                    cache: cache,
                                    hasReferenceImage: referenceImageLocalID(for: observation) != nil,
                                    hasCapturedImage: capturedImageLocalID(for: observation) != nil,
                                    canRetake: canRetakeObservation(observation),
                                    onTapRow: {
                                        onSelectIssue(observation)
                                        dismiss()
                                    },
                                    onTapRetake: {
                                        onRetakeIssue(observation)
                                        dismiss()
                                    },
                                    onTapViewReferenceImage: {
                                        showIssueImagePreview(observation, isCaptured: false)
                                    },
                                    onTapViewCapturedImage: {
                                        showIssueImagePreview(observation, isCaptured: true)
                                    },
                                    onTapReclassify: {
                                        reclassifyTargetObservation = observation
                                    },
                                    onTapHistory: {
                                        historyTargetObservation = observation
                                    }
                                )
                            }
                            .listStyle(.insetGrouped)
                            .scrollIndicators(.hidden)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                        }
                    }
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground)
                            .ignoresSafeArea()
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 10) {
                            Button(action: onRefresh) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 44, height: 42)
                                    .background(theme.fill)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(theme.stroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Spacer(minLength: 0)

                            Text("Active Issues")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(theme.label)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Button(action: { dismiss() }) {
                                Text("Done")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 72, height: 42)
                                    .background(theme.fill)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(theme.stroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    }
                    .sheet(item: $reclassifyTargetObservation) { target in
                        ChecklistReclassifySheet(
                            title: "Reclassify",
                            initialBuilding: target.building,
                            initialElevation: target.targetElevation,
                            initialDetailType: target.detailType,
                            buildingOptions: $buildingOptions,
                            detailTypesModel: detailTypesModel,
                            buildingCodeForOption: buildingCodeForOption,
                            buildingDisplayNameForOption: buildingDisplayNameForOption,
                            onCancel: {
                                reclassifyTargetObservation = nil
                            },
                            onConfirm: { building, elevation, detailType in
                                onReclassifyIssue(target, building, elevation, detailType)
                                reclassifyTargetObservation = nil
                            }
                        )
                    }
                    .sheet(item: $historyTargetObservation) { target in
                        FlaggedHistorySheet(observation: target)
                    }
                    .overlay(alignment: .top) {
                        if let inlineToastText {
                            Text(inlineToastText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.black.opacity(0.72))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                                .padding(.top, 64)
                                .transition(.opacity)
                        }
                    }
                }
                .frame(width: contentW, height: contentH, alignment: .center)
                .rotationEffect(.degrees(rotationDegrees))
                .position(x: w * 0.5, y: h * 0.5)
                .statusBarHidden(isLandscape)
                .onAppear {
                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                    refreshOrientation()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                    refreshOrientation()
                }
                .onDisappear {
                    UIDevice.current.endGeneratingDeviceOrientationNotifications()
                }
            }
            .fullScreenCover(item: $flaggedViewerState) { state in
                ReportPhotoViewer(
                    title: state.title,
                    assets: [state.asset],
                    startIndex: 0,
                    detailIdOverride: state.detailId,
                    cache: cache,
                    viewerToken: state.viewerToken
                )
            }
        }

        private func referenceImageLocalID(for observation: Observation) -> String? {
            guard allowReferenceFallback else { return nil }
            let id = referencePathByID[observation.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return id.isEmpty ? nil : id
        }

        private func capturedImageLocalID(for observation: Observation) -> String? {
            guard let linkedID = observation.linkedShotID else { return nil }
            let id = observation.shots.first(where: { $0.id == linkedID })?.imageLocalIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return id.isEmpty ? nil : id
        }

        private func canRetakeObservation(_ observation: Observation) -> Bool {
            guard let currentSessionID else { return false }
            let hasCurrentSessionCapture = observation.updatedInSessionID == currentSessionID || observation.resolvedInSessionID == currentSessionID
            guard hasCurrentSessionCapture else { return false }
            guard let linkedID = observation.linkedShotID else { return false }
            return sessionShotIDs.contains(linkedID)
        }

        private func showIssueImagePreview(_ observation: Observation, isCaptured: Bool) {
            let localID = (isCaptured ? capturedImageLocalID(for: observation) : referenceImageLocalID(for: observation)) ?? ""
            let trimmed = localID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                showInlineToast(isCaptured ? "No captured image yet." : "No reference available")
                return
            }

            guard let asset = ContentView.reportAsset(from: trimmed) else {
                showInlineToast(isCaptured ? "No captured image yet." : "No reference available")
                return
            }

            flaggedViewerState = FlaggedViewerState(
                title: isCaptured ? "Captured Image" : "Reference Image",
                detailId: ContentView.conciseContextLabel(
                    building: observation.building,
                    elevation: observation.targetElevation,
                    detailType: observation.detailType
                ),
                asset: asset,
                viewerToken: trimmed.hashValue
            )
        }

        private func showInlineToast(_ text: String) {
            inlineToastText = text
            inlineToastToken += 1
            let token = inlineToastToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard token == inlineToastToken else { return }
                inlineToastText = nil
            }
        }

        private struct FlaggedReassignSheet: View {
            let source: Observation
            let candidates: [Observation]
            let onCancel: () -> Void
            let onSelect: (UUID) -> Void

            private func label(for observation: Observation) -> String {
                let concise = ContentView.conciseContextLabel(
                    building: observation.building,
                    elevation: observation.targetElevation,
                    detailType: observation.detailType
                )
                return concise.isEmpty ? (ContentView.observationCurrentReasonText(observation) ?? observation.statement) : concise
            }

            var body: some View {
                NavigationStack {
                    List(candidates) { candidate in
                        Button {
                            onSelect(candidate.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(for: candidate))
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(ContentView.observationCurrentReasonText(candidate) ?? candidate.statement)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .navigationTitle("Reassign To")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel", action: onCancel)
                        }
                    }
                }
            }
        }

        private struct FlaggedHistorySheet: View {
            @Environment(\.dismiss) private var dismiss
            let observation: Observation

            private var rawEvents: [ObservationHistoryEvent] {
                observation.historyEvents.sorted { lhs, rhs in
                    if lhs.timestamp == rhs.timestamp {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.timestamp < rhs.timestamp
                }
            }

            private var events: [FlaggedHistoryDisplayEvent] {
                var displayEvents: [FlaggedHistoryDisplayEvent] = []
                let captures = rawEvents.filter { $0.kind == .captured || $0.kind == .retake }
                let reasonsByShotID = Dictionary(
                    uniqueKeysWithValues: rawEvents.compactMap { event -> (UUID, ObservationHistoryEvent)? in
                        guard event.kind == .reasonUpdated, let shotID = event.shotID else { return nil }
                        return (shotID, event)
                    }
                )
                let createdEvent = rawEvents.first(where: { $0.kind == .created })
                if let createdEvent {
                    displayEvents.append(
                        FlaggedHistoryDisplayEvent(
                            id: createdEvent.id.uuidString,
                            title: "Created",
                            timestamp: createdEvent.timestamp,
                            previousReason: nil,
                            currentReason: createdEvent.afterValue
                        )
                    )
                }

                for capture in captures {
                    if let createdEvent,
                       capture.timestamp == createdEvent.timestamp,
                       capture.shotID == createdEvent.shotID {
                        continue
                    }
                    let reasonEvent = capture.shotID.flatMap { reasonsByShotID[$0] }
                    displayEvents.append(
                        FlaggedHistoryDisplayEvent(
                            id: capture.id.uuidString,
                            title: "Follow-Up Captured",
                            timestamp: capture.timestamp,
                            previousReason: reasonEvent?.beforeValue,
                            currentReason: reasonEvent?.afterValue
                        )
                    )
                }

                return displayEvents.sorted { $0.timestamp > $1.timestamp }
            }

            var body: some View {
                NavigationStack {
                    List {
                        if let currentReason = ContentView.observationCurrentReasonText(observation) {
                            Section("Current Reason") {
                                Text(currentReason)
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }

                        Section("History") {
                            if events.isEmpty {
                                Text("No history yet")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(events) { event in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(event.title)
                                                .font(.system(size: 15, weight: .semibold))
                                            Spacer(minLength: 0)
                                            Text(ContentView.formatObservationHistoryTimestamp(event.timestamp))
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }

                                        if let previousReason = event.previousReason {
                                            Text("Previous Reason: \(previousReason)")
                                                .font(.system(size: 13, weight: .regular))
                                                .foregroundColor(.primary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }

                                        if let currentReason = event.currentReason {
                                            Text("Current Reason: \(currentReason)")
                                                .font(.system(size: 13, weight: .regular))
                                                .foregroundColor(.primary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .navigationTitle("Issue History")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }

        private struct FlaggedIssueRow: View {
            let observation: Observation
            let currentSessionID: UUID?
            let resolvedThumbnailPath: String?
            let cache: AssetImageCache
            let hasReferenceImage: Bool
            let hasCapturedImage: Bool
            let canRetake: Bool
            let onTapRow: () -> Void
            let onTapRetake: () -> Void
            let onTapViewReferenceImage: () -> Void
            let onTapViewCapturedImage: () -> Void
            let onTapReclassify: () -> Void
            let onTapHistory: () -> Void

            @State private var thumbnail: UIImage? = nil
            @State private var loadedID: String = ""

            private var contextLabel: String {
                let composed = ContentView.conciseContextLabel(
                    building: observation.building,
                    elevation: observation.targetElevation,
                    detailType: observation.detailType
                )
                return composed.isEmpty ? "Flagged Issue" : composed
            }

            private var statusLabel: String {
                if observation.resolvedInSessionID == currentSessionID {
                    return "Resolved"
                }
                if observation.updatedInSessionID == currentSessionID {
                    if observation.sessionID == currentSessionID {
                        return "Active - Captured"
                    }
                    return "Active - Update Captured"
                }
                return "Active"
            }

            private var statusColor: Color {
                if observation.resolvedInSessionID == currentSessionID {
                    return .green
                }
                if observation.updatedInSessionID == currentSessionID {
                    return .green
                }
                return .orange
            }

            private var reasonText: String {
                ContentView.observationCurrentReasonText(observation) ?? "No reason"
            }

            var body: some View {
                HStack(spacing: 12) {
                    thumbnailView

                    VStack(alignment: .leading, spacing: 4) {
                        Text(contextLabel)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(observation.status == .resolved ? .secondary : .primary)
                            .lineLimit(1)

                        Text(statusLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(statusColor)

                        Text("\(Text("Reason: ").font(.system(size: 12, weight: .semibold)))\(Text(reasonText).font(.system(size: 12, weight: .regular)))")
                            .foregroundColor(.white.opacity(0.86))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .opacity(observation.status == .resolved ? 0.70 : 1.0)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
                .onTapGesture {
                    guard observation.status == .active else { return }
                    guard !canRetake else { return }
                    onTapRow()
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        onTapHistory()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .tint(.blue)

                    Button {
                        onTapReclassify()
                    } label: {
                        Label("Reclassify", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .tint(.mint)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canRetake {
                        Button {
                            onTapRetake()
                        } label: {
                            Label("Retake", systemImage: "camera.rotate")
                        }
                        .tint(.orange)

                        if hasReferenceImage {
                            Button {
                                onTapViewReferenceImage()
                            } label: {
                                Label("View Reference", systemImage: "photo.on.rectangle")
                            }
                            .tint(.indigo)
                        }

                        Button {
                            onTapViewCapturedImage()
                        } label: {
                            Label("View Captured", systemImage: "photo")
                        }
                        .tint(.blue)
                    } else if hasReferenceImage {
                        Button {
                            onTapViewReferenceImage()
                        } label: {
                            Label("View Reference", systemImage: "photo.on.rectangle")
                        }
                        .tint(.indigo)
                    }
                }
                .onAppear { loadThumbnailIfNeeded() }
                .onChange(of: observation.linkedShotID) { _, _ in
                    loadThumbnailIfNeeded()
                }
                .onChange(of: observation.updatedInSessionID) { _, _ in
                    loadThumbnailIfNeeded()
                }
                .onChange(of: observation.resolvedInSessionID) { _, _ in
                    loadThumbnailIfNeeded()
                }
                .onChange(of: observation.shots.count) { _, _ in
                    loadThumbnailIfNeeded()
                }
                .onChange(of: resolvedThumbnailPath ?? "") { _, _ in
                    loadedID = ""
                    thumbnail = nil
                    loadThumbnailIfNeeded()
                }
            }

            private var thumbnailView: some View {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "photo")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }

            private func loadThumbnailIfNeeded() {
                let shotKey = ShotMetadata.makeShotKey(
                    building: observation.building ?? "",
                    elevation: observation.targetElevation ?? "",
                    detailType: observation.detailType ?? "",
                    angleIndex: 1
                )
                let linkedIDText = observation.linkedShotID?.uuidString ?? "NONE"
                print("[FlagRow] rowID=\(observation.id.uuidString) issueID=\(observation.id.uuidString) shotID=\(linkedIDText) shotKey=\(shotKey)")
                let chosenID = resolvedThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !chosenID.isEmpty else {
                    thumbnail = nil
                    loadedID = ""
                    return
                }
                guard chosenID != loadedID || thumbnail == nil else { return }
                loadedID = chosenID

                guard let asset = ContentView.reportAsset(from: chosenID) else {
                    thumbnail = nil
                    return
                }
                let px = max(120, 56 * UIScreen.currentScale * 2.0)
                cache.requestThumbnail(for: asset, pixelSize: px) { image in
                    DispatchQueue.main.async {
                        self.thumbnail = image
                    }
                }
            }
        }

        private func refreshOrientation() {
            let o = UIDevice.current.orientation
            let newValue: UIDeviceOrientation? = {
                switch o {
                case .portrait:
                    return .portrait
                case .landscapeLeft, .landscapeRight:
                    return o
                default:
                    return nil
                }
            }()

            guard let newValue else { return }
            guard newValue != lastValidOrientation else { return }
            lastValidOrientation = newValue
        }
    }

    private struct ReportMenuSheet: View {
        let activeReportTitle: String
        let onSwitchReport: () -> Void
        let onNewReport: () -> Void
        let onEditCurrent: () -> Void

        var body: some View {
            NavigationStack {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text("Active Report")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(activeReportTitle)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)

                    reportActionRow(
                        icon: "arrow.left.arrow.right",
                        title: "Switch Report",
                        action: onSwitchReport
                    )

                    reportActionRow(
                        icon: "plus.circle",
                        title: "New Report",
                        action: onNewReport
                    )

                    reportActionRow(
                        icon: "pencil",
                        title: "Edit Current Report",
                        action: onEditCurrent
                    )

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .navigationTitle("Report")
                .navigationBarTitleDisplayMode(.inline)
            }
        }

        @ViewBuilder
        private func reportActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                    Text(title)
                        .font(.system(size: 18, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private struct ReportSwitcherSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        @Environment(\.dismiss) private var dismiss
        let activeReportTitle: String
        let reports: [String]
        let isLoading: Bool
        let onRefresh: () -> Void
        let onBack: () -> Void
        let onSelectReport: (String) -> Void

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        iconCapsuleButton(systemName: "chevron.left", action: onBack)

                        Spacer(minLength: 0)

                        HStack(spacing: 0) {
                            Button(action: onRefresh) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 44, height: 42)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                dismiss()
                            } label: {
                                Text("Done")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 72, height: 42)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(theme.fill)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    Text("Switch Report")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    Group {
                        if isLoading {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Loading reports...")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if reports.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "tray")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text("No matching report albums found.")
                                    .font(.system(size: 16, weight: .medium))
                                Text("Only albums matching your report ID format are shown.")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 18)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(reports, id: \.self) { title in
                                Button {
                                    onSelectReport(title)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(title)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(.primary)

                                        Spacer(minLength: 0)

                                        if title == activeReportTitle {
                                            Text("Active")
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.green.opacity(0.16))
                                                .foregroundColor(.green)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .disabled(title == activeReportTitle)
                            }
                            .listStyle(.insetGrouped)
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }

        @ViewBuilder
        private func iconCapsuleButton(systemName: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(theme.label)
                    .frame(width: 44, height: 42)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(theme.stroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }

    }

    private struct ReportIdEditorSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        let mode: ReportEditorMode
        let onCancel: () -> Void
        let onSave: (String, Bool, Int, Int, Bool, Bool, Bool) -> Void

        @State private var prefix: String
        @State private var includeYear: Bool
        @State private var yearText: String
        @State private var sequenceText: String
        @State private var prefixLocked: Bool
        @State private var yearLocked: Bool
        @State private var sequenceLocked: Bool

        init(
            mode: ReportEditorMode,
            prefix: String,
            includeYear: Bool,
            year: Int,
            sequence: Int,
            prefixLocked: Bool,
            yearLocked: Bool,
            sequenceLocked: Bool,
            onCancel: @escaping () -> Void,
            onSave: @escaping (String, Bool, Int, Int, Bool, Bool, Bool) -> Void
        ) {
            self.mode = mode
            self.onCancel = onCancel
            self.onSave = onSave
            _prefix = State(initialValue: prefix)
            _includeYear = State(initialValue: includeYear)
            _yearText = State(initialValue: String(year))
            _sequenceText = State(initialValue: String(sequence))
            _prefixLocked = State(initialValue: prefixLocked)
            _yearLocked = State(initialValue: yearLocked)
            _sequenceLocked = State(initialValue: sequenceLocked)
        }

        private var saveTitle: String {
            switch mode {
            case .editCurrent:
                return "Save"
            case .newReport:
                return "Create"
            }
        }

        private var normalizedPrefix: String {
            let filtered = prefix.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            return filtered.isEmpty ? "SC" : String(filtered.prefix(8))
        }

        private var normalizedYear: Int {
            let parsed = Int(yearText) ?? Calendar.current.component(.year, from: Date())
            return min(9999, max(2000, parsed))
        }

        private var normalizedSequence: Int {
            let parsed = Int(sequenceText) ?? 0
            return min(99999, max(0, parsed))
        }

        private var normalizedSequenceString: String {
            if normalizedSequence < 100 {
                return String(format: "%03d", normalizedSequence)
            }
            return String(normalizedSequence)
        }

        private var previewId: String {
            if includeYear {
                return "\(normalizedPrefix)-\(normalizedYear)-\(normalizedSequenceString)"
            }
            return "\(normalizedPrefix)-\(normalizedSequenceString)"
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 16) {
                    HStack(spacing: 10) {
                        iconCapsuleButton(systemName: "chevron.left") {
                            onCancel()
                        }

                        Spacer(minLength: 0)

                        textCapsuleButton(title: saveTitle) {
                            onSave(
                                normalizedPrefix,
                                includeYear,
                                normalizedYear,
                                normalizedSequence,
                                prefixLocked,
                                yearLocked,
                                sequenceLocked
                            )
                        }
                    }
                    .padding(.top, 12)

                    VStack(spacing: 4) {
                        Text("Preview")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(previewId)
                            .font(.system(size: 30, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)

                    VStack(spacing: 12) {
                        editorRow(
                            label: "Prefix",
                            value: $prefix,
                            keyboard: .asciiCapable,
                            isLocked: $prefixLocked
                        )

                        HStack(spacing: 10) {
                            Text("Year")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 120, alignment: .leading)

                            Toggle("", isOn: $includeYear)
                                .labelsHidden()
                                .disabled(yearLocked)

                            if includeYear {
                                TextField("", text: $yearText)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 16, weight: .medium))
                                    .disabled(yearLocked)
                                    .padding(.horizontal, 10)
                                    .frame(height: 40)
                                    .background(Color(UIColor.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                Text("Off")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 2)
                            }

                            lockButton(isLocked: $yearLocked)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        editorRow(
                            label: "Report Number",
                            value: $sequenceText,
                            keyboard: .numberPad,
                            isLocked: $sequenceLocked
                        )
                    }

                    Text("Number supports 0 to 99999. Values under 100 display with 3 digits.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .toolbar(.hidden, for: .navigationBar)
            }
            .onChange(of: prefix) { _, newValue in
                let filtered = newValue.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                if filtered != newValue {
                    prefix = filtered
                }
            }
            .onChange(of: yearText) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    yearText = filtered
                }
                if yearText.count > 4 {
                    yearText = String(yearText.prefix(4))
                }
            }
            .onChange(of: sequenceText) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    sequenceText = filtered
                }
                if sequenceText.count > 5 {
                    sequenceText = String(sequenceText.prefix(5))
                }
            }
        }

        @ViewBuilder
        private func iconCapsuleButton(systemName: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(theme.label)
                    .frame(width: 44, height: 42)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(theme.stroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder
        private func textCapsuleButton(title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.label)
                    .frame(minHeight: 42)
                    .padding(.horizontal, 14)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(theme.stroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder
        private func editorRow(
            label: String,
            value: Binding<String>,
            keyboard: UIKeyboardType,
            isLocked: Binding<Bool>
        ) -> some View {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 120, alignment: .leading)

                TextField("", text: value)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .keyboardType(keyboard)
                    .font(.system(size: 16, weight: .medium))
                    .disabled(isLocked.wrappedValue)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                lockButton(isLocked: isLocked)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        @ViewBuilder
        private func lockButton(isLocked: Binding<Bool>) -> some View {
            Button {
                isLocked.wrappedValue.toggle()
            } label: {
                Image(systemName: isLocked.wrappedValue ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: proportionalCircleGlyphSize(for: 36), weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(isLocked.wrappedValue ? Color.orange.opacity(0.9) : Color.blue.opacity(0.9))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Quick Menu Sheet
    
    private struct QuickMenuSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        
        let glyphRotationAngle: Angle
        let flashSetting: CameraManager.FlashSetting
        
        // Current active camera (provided by ContentView)
        let isFrontCamera: Bool
        let selectedBuildingLabel: String
        
        @Binding var isGridOn: Bool
        @Binding var isLevelOn: Bool

        let onBuildingList: () -> Void
        let onInteriorList: () -> Void
        let onExteriorList: () -> Void
        let onFlash: () -> Void
        
        // Pass the target camera: true = front, false = rear
        let onCameraSwap: () -> Void
        
        var body: some View {
            GeometryReader { geo in
                let spacing: CGFloat = 12
                
                // During sheet presentation / rotation, GeometryReader can briefly report 0 or non-finite sizes.
                // Clamp everything so we never pass a negative or non-finite width into `.frame(width:)`.
                let rawContentW = geo.size.width - 36
                let contentW: CGFloat = rawContentW.isFinite ? max(0, rawContentW) : 0
                
                let rawBtnW = (contentW - (spacing * 2)) / 3.0
                let btnW: CGFloat = rawBtnW.isFinite ? max(0, rawBtnW) : 0
                let rawTopBtnW = (contentW - (spacing * 2)) / 3.0
                let topBtnW: CGFloat = rawTopBtnW.isFinite ? max(0, rawTopBtnW) : 0
                
                let bottomInset: CGFloat = (btnW / 2.0) + (spacing / 2.0)
                
                NavigationStack {
                    ZStack {
                        Color.clear
                            .ignoresSafeArea()
                        
                        VStack(spacing: 18) {
                            
                            HStack(spacing: spacing) {
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "building.2",
                                    title: "BUILDINGS",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onBuildingList
                                )
                                .frame(width: topBtnW)

                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "list.bullet",
                                    title: "INTERIOR",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onInteriorList
                                )
                                    .frame(width: topBtnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "list.bullet",
                                    title: "EXTERIOR",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onExteriorList
                                )
                                .frame(width: topBtnW)
                            }

                            Rectangle()
                                .fill(theme.stroke.opacity(0.55))
                                .frame(height: 1)
                                .padding(.horizontal, 10)
                                .padding(.top, 2)
                                .padding(.bottom, 8)
                            
                            HStack(spacing: spacing) {
                                let flashIcon: String = {
                                    switch flashSetting {
                                    case .off: return "bolt.slash"
                                    case .auto: return "bolt.badge.a"
                                    case .on: return "bolt"
                                    }
                                }()
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: flashIcon,
                                    title: "FLASH",
                                    isSelected: flashSetting != .off,
                                    selectedStyle: true,
                                    theme: theme,
                                    action: onFlash
                                )
                                    .frame(width: btnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "square.grid.3x3",
                                    title: "GRID",
                                    isSelected: isGridOn,
                                    selectedStyle: true,
                                    theme: theme
                                ) {
                                    isGridOn.toggle()
                                }
                                .frame(width: btnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "level",
                                    title: "LEVEL",
                                    isSelected: isLevelOn,
                                    selectedStyle: true,
                                    theme: theme
                                ) {
                                    isLevelOn.toggle()
                                }
                                .frame(width: btnW)
                            }
                            .padding(.horizontal, bottomInset)
                            
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "camera.rotate",
                                    title: "CAMERA",
                                    isSelected: isFrontCamera,
                                    selectedStyle: true,
                                    theme: theme,
                                    action: onCameraSwap
                                )
                                .frame(width: btnW)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                            
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 18)
                        .padding(.horizontal, 18)
                    }
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private struct ManageBuildingsSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        @Environment(\.editMode) private var editMode

        @Binding var options: [String]
        @Binding var selectedBuilding: String
        let buildingCodeForOption: (String) -> String
        let buildingFullLabelForOption: (String) -> String
        let onClose: () -> Void
        @State private var editModeState: EditMode = .inactive
        @FocusState private var focusedIndex: Int?

        var body: some View {
            NavigationStack {
                List {
                    ForEach(Array(options.indices), id: \.self) { index in
                        if editModeState == .active {
                            TextField("Building", text: Binding(
                                get: {
                                    guard options.indices.contains(index) else { return "" }
                                    return options[index]
                                },
                                set: { newValue in
                                    guard options.indices.contains(index) else { return }
                                    options[index] = newValue
                                }
                            ))
                            .focused($focusedIndex, equals: index)
                            .submitLabel(.done)
                        } else {
                            let option = options[index]
                            Button {
                                selectedBuilding = buildingCodeForOption(option)
                                onClose()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(buildingFullLabelForOption(option))
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)

                                    Spacer(minLength: 0)

                                    if selectedBuilding == buildingCodeForOption(option) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { offsets in
                        options.remove(atOffsets: offsets)
                    }
                    .onMove { source, destination in
                        options.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, $editModeState)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 10) {
                        Button(action: onClose) {
                            Text("Done")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(theme.label)
                                .frame(minHeight: 42)
                                .padding(.horizontal, 14)
                                .background(theme.fill)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(theme.stroke, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)

                        Text("Buildings")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(theme.label)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        HStack(spacing: 0) {
                            Button {
                                if editModeState != .active { editModeState = .active }
                                options.append("New Building")
                                focusedIndex = max(0, options.count - 1)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 44, height: 42)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                if editModeState == .active {
                                    editModeState = .inactive
                                    focusedIndex = nil
                                } else {
                                    editModeState = .active
                                }
                            } label: {
                                Group {
                                    if editModeState == .active {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 17, weight: .medium))
                                    } else {
                                        Text("Edit")
                                            .font(.system(size: 17, weight: .medium))
                                    }
                                }
                                .foregroundColor(theme.label)
                                .frame(width: 72, height: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(theme.fill)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                .onDisappear {
                    let cleaned = options
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    options = cleaned.isEmpty ? ["B1", "B2", "B3", "B4", "B5", "Add"] : cleaned
                    let selectedCode = buildingCodeForOption(selectedBuilding)
                    if options.contains(where: { buildingCodeForOption($0) == selectedCode }) == false {
                        selectedBuilding = buildingCodeForOption(options[0])
                    } else {
                        selectedBuilding = selectedCode
                    }
                }
            }
        }
    }
    
    private struct QuickMenuButton: View {
        let glyphRotationAngle: Angle
        let icon: String
        let title: String
        let isSelected: Bool
        let selectedStyle: Bool
        let theme: SheetControlTheme
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                VStack(spacing: 10) {
                    let bg: Color = {
                        if isSelected {
                            return theme.fill.opacity(0.96)
                        }
                        return selectedStyle ? theme.fill.opacity(0.82) : theme.fill
                    }()
                    
                    let fg: Color = {
                        if isSelected {
                            return .blue
                        }
                        return selectedStyle ? theme.label.opacity(0.92) : theme.label
                    }()
                    
                    let ring: Color = isSelected ? Color.blue.opacity(0.72) : theme.stroke.opacity(0.70)
                    let titleColor: Color = isSelected ? Color.blue.opacity(0.96) : theme.label.opacity(0.88)
                    
                    VStack(spacing: 10) {
                        Circle()
                            .fill(bg)
                            .frame(width: 74, height: 74)
                            .overlay(
                                Circle()
                                    .stroke(ring, lineWidth: 1)
                            )
                            .overlay(
                                Image(systemName: icon)
                                    .font(.system(size: proportionalCircleGlyphSize(for: 74), weight: .medium))
                                    .foregroundColor(fg)
                            )
                        
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(titleColor)
                    }
                    .rotationEffect(glyphRotationAngle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Grid Overlay
    
    private struct GridOverlay: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            
            let x1 = rect.minX + rect.width / 3
            let x2 = rect.minX + 2 * rect.width / 3
            let y1 = rect.minY + rect.height / 3
            let y2 = rect.minY + 2 * rect.height / 3
            
            p.move(to: CGPoint(x: x1, y: rect.minY))
            p.addLine(to: CGPoint(x: x1, y: rect.maxY))
            
            p.move(to: CGPoint(x: x2, y: rect.minY))
            p.addLine(to: CGPoint(x: x2, y: rect.maxY))
            
            p.move(to: CGPoint(x: rect.minX, y: y1))
            p.addLine(to: CGPoint(x: rect.maxX, y: y1))
            
            p.move(to: CGPoint(x: rect.minX, y: y2))
            p.addLine(to: CGPoint(x: rect.maxX, y: y2))
            
            return p
        }
    }
    
    // MARK: - Level Overlay
    
    private struct LevelOverlay: View {
        
        let rollDegrees: Double
        let isLevel: Bool
        
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let size: CGFloat = min(w, h) * 0.46
                
                Rectangle()
                    .fill(isLevel ? Color.green : Color.white)
                    .frame(width: size * 0.72, height: 3)
                    .rotationEffect(.degrees(rollDegrees))
                    .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    // MARK: - Level / Horizon model (stable in portrait-locked UI)
    
    final class LevelMotionModel: ObservableObject {
        
        @Published var rollDegrees: Double = 0
        @Published var isLevel: Bool = false
        
        private let motion = CMMotionManager()
        
        // Filtering + hysteresis
        private var filteredDegrees: Double = 0
        private let alpha: Double = 0.18
        private let levelOnThreshold: Double = 1.0
        private let levelOffThreshold: Double = 1.4
        
        private(set) var isRunning: Bool = false
        
        func start() {
            guard !isRunning else { return }
            guard motion.isDeviceMotionAvailable else { return }
            
            isRunning = true
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
                guard let self else { return }
                guard let m else { return }
                
                let gx = m.gravity.x
                let gy = m.gravity.y
                
                // Decide portrait vs landscape from gravity (NOT UIDevice.orientation)
                let usePortraitAxis = abs(gy) >= abs(gx)
                
                var angleRad: Double
                
                if usePortraitAxis {
                    angleRad = m.attitude.roll
                    if gy < 0 { angleRad = -angleRad }
                } else {
                    angleRad = m.attitude.pitch
                    if gx > 0 { angleRad = -angleRad }
                }
                
                var deg = angleRad * 180.0 / .pi
                
                if deg > 90 { deg = 90 }
                if deg < -90 { deg = -90 }
                
                // Low-pass smoothing
                self.filteredDegrees += self.alpha * (deg - self.filteredDegrees)
                self.rollDegrees = self.filteredDegrees
                
                // Hysteresis for green state
                let absDeg = abs(self.filteredDegrees)
                if self.isLevel {
                    if absDeg > self.levelOffThreshold {
                        self.isLevel = false
                    }
                } else {
                    if absDeg < self.levelOnThreshold {
                        self.isLevel = true
                    }
                }
            }
        }
        
        func stop() {
            guard isRunning else { return }
            isRunning = false
            motion.stopDeviceMotionUpdates()
            filteredDegrees = 0
            rollDegrees = 0
            isLevel = false
        }
    }
    // MARK: - Glyph Rotation Motion Model
    
    private final class GlyphRotationMotionModel: ObservableObject {
        
        @Published var angleDegrees: Double = 0
        
        private let manager = CMMotionManager()
        
        // Low pass smoothing to match Apple camera feel
        private var filtered: Double = 0
        private let alpha: Double = 0.18
        
        func start() {
            guard manager.isDeviceMotionAvailable else { return }
            
            manager.deviceMotionUpdateInterval = 1.0 / 60.0
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self else { return }
                guard let m = motion else { return }
                
                let g = m.gravity
                
                // Map gravity to a continuous angle in portrait coordinate space.
                // Portrait upright yields 0.
                // Rotate device left yields about +90 for glyphs.
                // Rotate device right yields about -90 for glyphs.
                let rawRad = atan2(g.x, -g.y)
                let rawDeg = rawRad * 180.0 / Double.pi
                
                // Invert so glyphs rotate opposite the physical roll.
                var target = -rawDeg
                
                // Keep it in a stable range so it does not flip.
                if target > 90 { target = 90 }
                if target < -90 { target = -90 }
                
                filtered = (alpha * target) + ((1.0 - alpha) * filtered)
                angleDegrees = filtered
            }
        }
        
        func stop() {
            manager.stopDeviceMotionUpdates()
        }
    }
}
//Testing batch upload
