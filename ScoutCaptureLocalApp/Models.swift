import Foundation
import UIKit

enum CanonicalElevation {
    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        if lowered == "north elevation" || lowered == "north" { return "North" }
        if lowered == "south elevation" || lowered == "south" { return "South" }
        if lowered == "east elevation" || lowered == "east" { return "East" }
        if lowered == "west elevation" || lowered == "west" { return "West" }
        return trimmed
    }
}

struct SessionMetadata: Codable {
    var schemaVersion: Int
    var propertyID: UUID
    var sessionID: UUID
    var orgID: UUID?
    var orgNameAtCapture: String?
    var folderIDAtCapture: String?
    var propertyNameAtCapture: String?
    var propertyNameAtExport: String?
    var primaryContactNameAtCapture: String?
    var propertyAddressAtCapture: String?
    var propertyStreetAtCapture: String?
    var propertyCityAtCapture: String?
    var propertyStateAtCapture: String?
    var propertyZipAtCapture: String?
    var propertyPhoneAtCapture: String?
    var timeZoneIdentifierAtCapture: String
    var timeZoneOffsetAtCapture: String
    var timeZoneOffsetMinutesAtCapture: Int?
    var startedAt: Date
    var sessionStartedAtLocal: String
    var endedAt: Date?
    var sessionEndedAtLocal: String?
    var status: Session.Status
    var isBaselineSession: Bool
    var exportedAt: Date?
    var isSealed: Bool
    var firstDeliveredAt: Date?
    var reExportExpiresAt: Date?
    var appVersion: String
    var deviceModel: String
    var osVersion: String
    var shots: [ShotMetadata]
    var issues: [IssueMetadata]
    var guidedShots: [GuidedShot]

    var flaggedIssues: [IssueMetadata] {
        issues.filter {
            SessionMetadata.trimmedNonEmpty($0.issueStatus)?.lowercased() == "active"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case propertyID
        case propertyId
        case sessionID
        case orgID
        case orgId
        case orgNameAtCapture
        case orgName
        case folderIDAtCapture
        case folderId
        case propertyNameAtCapture
        case propertyName
        case propertyNameAtExport
        case primaryContactNameAtCapture
        case primaryContactName
        case propertyAddressAtCapture
        case propertyAddress
        case propertyStreetAtCapture
        case propertyStreet
        case propertyCityAtCapture
        case propertyCity
        case propertyStateAtCapture
        case propertyState
        case propertyZipAtCapture
        case propertyZip
        case propertyPhoneAtCapture
        case primaryContactPhone
        case timeZoneIdentifierAtCapture
        case timeZoneOffsetAtCapture
        case timeZoneOffsetMinutesAtCapture
        case startedAt
        case sessionStartedAtLocal
        case endedAt
        case sessionEndedAtLocal
        case status
        case isBaselineSession
        case exportedAt
        case isSealed
        case firstDeliveredAt
        case reExportExpiresAt
        case appVersion
        case deviceModel
        case osVersion
        case shots
        case issues
        case flaggedIssues
        case guidedShots
    }

    init(
        schemaVersion: Int,
        propertyID: UUID,
        sessionID: UUID,
        orgID: UUID? = nil,
        orgNameAtCapture: String? = nil,
        folderIDAtCapture: String? = nil,
        propertyNameAtCapture: String?,
        propertyNameAtExport: String?,
        primaryContactNameAtCapture: String? = nil,
        propertyAddressAtCapture: String? = nil,
        propertyStreetAtCapture: String? = nil,
        propertyCityAtCapture: String? = nil,
        propertyStateAtCapture: String? = nil,
        propertyZipAtCapture: String? = nil,
        propertyPhoneAtCapture: String? = nil,
        timeZoneIdentifierAtCapture: String = TimeZone.current.identifier,
        timeZoneOffsetAtCapture: String = "+00:00",
        timeZoneOffsetMinutesAtCapture: Int? = nil,
        startedAt: Date,
        sessionStartedAtLocal: String = "",
        endedAt: Date?,
        sessionEndedAtLocal: String? = nil,
        status: Session.Status,
        isBaselineSession: Bool,
        exportedAt: Date?,
        isSealed: Bool = false,
        firstDeliveredAt: Date? = nil,
        reExportExpiresAt: Date? = nil,
        appVersion: String,
        deviceModel: String,
        osVersion: String,
        shots: [ShotMetadata],
        issues: [IssueMetadata],
        guidedShots: [GuidedShot] = []
    ) {
        self.schemaVersion = schemaVersion
        self.propertyID = propertyID
        self.sessionID = sessionID
        self.orgID = orgID
        self.orgNameAtCapture = SessionMetadata.trimmedNonEmpty(orgNameAtCapture)
        self.folderIDAtCapture = SessionMetadata.trimmedNonEmpty(folderIDAtCapture)
        self.propertyNameAtCapture = propertyNameAtCapture
        self.propertyNameAtExport = propertyNameAtExport
        self.primaryContactNameAtCapture = SessionMetadata.trimmedNonEmpty(primaryContactNameAtCapture)
        self.propertyAddressAtCapture = SessionMetadata.trimmedNonEmpty(propertyAddressAtCapture)
        self.propertyStreetAtCapture = SessionMetadata.trimmedNonEmpty(propertyStreetAtCapture)
        self.propertyCityAtCapture = SessionMetadata.trimmedNonEmpty(propertyCityAtCapture)
        self.propertyStateAtCapture = SessionMetadata.trimmedNonEmpty(propertyStateAtCapture)
        self.propertyZipAtCapture = SessionMetadata.trimmedNonEmpty(propertyZipAtCapture)
        self.propertyPhoneAtCapture = SessionMetadata.trimmedNonEmpty(propertyPhoneAtCapture)
        self.timeZoneIdentifierAtCapture = timeZoneIdentifierAtCapture.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeZoneOffsetAtCapture = timeZoneOffsetAtCapture.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeZoneOffsetMinutesAtCapture = timeZoneOffsetMinutesAtCapture
        self.startedAt = startedAt
        self.sessionStartedAtLocal = sessionStartedAtLocal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endedAt = endedAt
        self.sessionEndedAtLocal = SessionMetadata.trimmedNonEmpty(sessionEndedAtLocal)
        self.status = status
        self.isBaselineSession = isBaselineSession
        self.exportedAt = exportedAt
        self.isSealed = isSealed
        self.firstDeliveredAt = firstDeliveredAt
        self.reExportExpiresAt = reExportExpiresAt
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.shots = shots
        self.issues = issues
        self.guidedShots = guidedShots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        propertyID = try c.decodeIfPresent(UUID.self, forKey: .propertyID)
            ?? c.decode(UUID.self, forKey: .propertyId)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        orgID = try c.decodeIfPresent(UUID.self, forKey: .orgID)
            ?? c.decodeIfPresent(UUID.self, forKey: .orgId)
        orgNameAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .orgNameAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .orgName)
        )
        folderIDAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .folderIDAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .folderId)
        )
        propertyNameAtCapture = try c.decodeIfPresent(String.self, forKey: .propertyNameAtCapture)
            ?? c.decodeIfPresent(String.self, forKey: .propertyName)
        propertyNameAtExport = try c.decodeIfPresent(String.self, forKey: .propertyNameAtExport)
        primaryContactNameAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .primaryContactNameAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .primaryContactName)
        )
        propertyAddressAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .propertyAddressAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .propertyAddress)
        )
        propertyStreetAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .propertyStreetAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .propertyStreet)
        )
        propertyCityAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .propertyCityAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .propertyCity)
        )
        propertyStateAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .propertyStateAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .propertyState)
        )
        propertyZipAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .propertyZipAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .propertyZip)
        )
        propertyPhoneAtCapture = SessionMetadata.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .propertyPhoneAtCapture)
                ?? c.decodeIfPresent(String.self, forKey: .primaryContactPhone)
        )
        timeZoneIdentifierAtCapture = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifierAtCapture)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? TimeZone.current.identifier
        timeZoneOffsetAtCapture = try c.decodeIfPresent(String.self, forKey: .timeZoneOffsetAtCapture)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "+00:00"
        timeZoneOffsetMinutesAtCapture = try c.decodeIfPresent(Int.self, forKey: .timeZoneOffsetMinutesAtCapture)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        sessionStartedAtLocal = try c.decodeIfPresent(String.self, forKey: .sessionStartedAtLocal)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        sessionEndedAtLocal = SessionMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .sessionEndedAtLocal))
        status = try c.decodeIfPresent(Session.Status.self, forKey: .status) ?? .draft
        isBaselineSession = try c.decodeIfPresent(Bool.self, forKey: .isBaselineSession) ?? false
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        let decodedIsSealed = try c.decodeIfPresent(Bool.self, forKey: .isSealed)
        isSealed = decodedIsSealed ?? (status == .completed)
        firstDeliveredAt = try c.decodeIfPresent(Date.self, forKey: .firstDeliveredAt) ?? exportedAt
        if let explicitExpiry = try c.decodeIfPresent(Date.self, forKey: .reExportExpiresAt) {
            reExportExpiresAt = explicitExpiry
        } else if let deliveredAt = firstDeliveredAt {
            reExportExpiresAt = Calendar.current.date(byAdding: .day, value: 7, to: deliveredAt)
        } else {
            reExportExpiresAt = nil
        }
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel) ?? "unknown"
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion) ?? "unknown"
        shots = try c.decodeIfPresent([ShotMetadata].self, forKey: .shots) ?? []
        let decodedFlaggedIssues = try c.decodeIfPresent([IssueMetadata].self, forKey: .flaggedIssues)
        issues = try c.decodeIfPresent([IssueMetadata].self, forKey: .issues) ?? decodedFlaggedIssues ?? []
        guidedShots = try c.decodeIfPresent([GuidedShot].self, forKey: .guidedShots) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encode(propertyID, forKey: .propertyId)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(orgID, forKey: .orgID)
        try c.encodeIfPresent(orgID, forKey: .orgId)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(orgNameAtCapture), forKey: .orgNameAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(orgNameAtCapture), forKey: .orgName)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(folderIDAtCapture), forKey: .folderIDAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(folderIDAtCapture), forKey: .folderId)
        try c.encodeIfPresent(propertyNameAtCapture, forKey: .propertyNameAtCapture)
        try c.encodeIfPresent(propertyNameAtExport ?? propertyNameAtCapture, forKey: .propertyName)
        try c.encodeIfPresent(propertyNameAtExport, forKey: .propertyNameAtExport)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(primaryContactNameAtCapture), forKey: .primaryContactNameAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(primaryContactNameAtCapture), forKey: .primaryContactName)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyAddressAtCapture), forKey: .propertyAddressAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyAddressAtCapture), forKey: .propertyAddress)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyStreetAtCapture), forKey: .propertyStreetAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyStreetAtCapture), forKey: .propertyStreet)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyCityAtCapture), forKey: .propertyCityAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyCityAtCapture), forKey: .propertyCity)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyStateAtCapture), forKey: .propertyStateAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyStateAtCapture), forKey: .propertyState)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyZipAtCapture), forKey: .propertyZipAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyZipAtCapture), forKey: .propertyZip)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyPhoneAtCapture), forKey: .propertyPhoneAtCapture)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(propertyPhoneAtCapture), forKey: .primaryContactPhone)
        try c.encode(timeZoneIdentifierAtCapture.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .timeZoneIdentifierAtCapture)
        try c.encode(timeZoneOffsetAtCapture.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .timeZoneOffsetAtCapture)
        try c.encodeIfPresent(timeZoneOffsetMinutesAtCapture, forKey: .timeZoneOffsetMinutesAtCapture)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(sessionStartedAtLocal.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .sessionStartedAtLocal)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(SessionMetadata.trimmedNonEmpty(sessionEndedAtLocal), forKey: .sessionEndedAtLocal)
        try c.encode(status, forKey: .status)
        try c.encode(isBaselineSession, forKey: .isBaselineSession)
        try c.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try c.encode(isSealed, forKey: .isSealed)
        try c.encodeIfPresent(firstDeliveredAt, forKey: .firstDeliveredAt)
        try c.encodeIfPresent(reExportExpiresAt, forKey: .reExportExpiresAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(shots, forKey: .shots)
        try c.encode(issues, forKey: .issues)
        try c.encode(flaggedIssues, forKey: .flaggedIssues)
        try c.encode(guidedShots, forKey: .guidedShots)
    }

    static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct Organization: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case orgId
        case name
        case orgName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
            ?? c.decode(UUID.self, forKey: .orgId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decode(String.self, forKey: .orgName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(id, forKey: .orgId)
        try c.encode(name, forKey: .name)
        try c.encode(name, forKey: .orgName)
    }
}

struct ShotMetadata: Codable, Identifiable, Equatable {
    let shotID: UUID
    // Deprecated duplication kept for backwards compatibility with existing readers.
    let propertyID: UUID
    // Deprecated duplication kept for backwards compatibility with existing readers.
    let sessionID: UUID
    let createdAt: Date
    var capturedAtLocal: String?
    var updatedAt: Date
    var building: String
    var elevation: String
    var detailType: String
    var angleIndex: Int
    var shotKey: String
    var isGuided: Bool
    var isFlagged: Bool
    var issueID: UUID?
    var issueStatus: String?
    var captureKind: String?
    var firstCaptureKind: String?
    var noteText: String?
    var noteCategory: String?
    var originalFilename: String
    var originalRelativePath: String
    var originalByteSize: Int?
    var stampedFilename: String?
    var stampedRelativePath: String?
    var captureMode: String?
    var lens: String?
    var exifOrientation: Int?
    // Legacy orientation string retained only for backwards decode compatibility.
    var orientation: String?
    var latitude: Double?
    var longitude: Double?
    var accuracyMeters: Double?
    var imageWidth: Int?
    var imageHeight: Int?

    var id: UUID { shotID }
    var logicalShotIdentity: String {
        let normalizedKey = shotKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ShotMetadata.makeShotKey(
                building: building,
                elevation: CanonicalElevation.normalize(elevation) ?? elevation,
                detailType: detailType,
                angleIndex: max(1, angleIndex)
            ).lowercased()
            : shotKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lane: String
        let flaggedLane = isFlagged
            || issueID != nil
            || ShotMetadata.trimmedNonEmpty(issueStatus) != nil
            || ShotMetadata.trimmedNonEmpty(captureKind) != nil
        if flaggedLane {
            let issueComponent = issueID?.uuidString.lowercased() ?? "no-issue"
            lane = "flagged|\(issueComponent)"
        } else {
            lane = "normal"
        }
        return "\(sessionID.uuidString.lowercased())|\(lane)|\(normalizedKey)"
    }

    private enum CodingKeys: String, CodingKey {
        case shotID
        case propertyID
        case sessionID
        case createdAt
        case capturedAtLocal
        case shotCreatedAtLocal // legacy
        case updatedAt
        case shotUpdatedAtLocal // legacy
        case building
        case elevation
        case detailType
        case angleIndex
        case shotKey
        case isGuided
        case isFlagged
        case issueID
        case issueStatus
        case captureKind
        case firstCaptureKind
        case noteText
        case noteCategory
        case originalFilename
        case originalRelativePath
        case originalByteSize
        case stampedFilename
        case stampedRelativePath
        case captureMode
        case lens
        case exifOrientation
        case orientation // legacy
        case latitude
        case longitude
        case accuracyMeters
        case imageWidth
        case imageHeight
        case logicalShotIdentity
    }

    init(
        shotID: UUID,
        propertyID: UUID,
        sessionID: UUID,
        createdAt: Date,
        capturedAtLocal: String? = nil,
        updatedAt: Date,
        building: String,
        elevation: String,
        detailType: String,
        angleIndex: Int,
        shotKey: String,
        isGuided: Bool,
        isFlagged: Bool,
        issueID: UUID?,
        issueStatus: String?,
        captureKind: String? = nil,
        firstCaptureKind: String? = nil,
        noteText: String?,
        noteCategory: String?,
        originalFilename: String,
        originalRelativePath: String,
        originalByteSize: Int?,
        stampedFilename: String?,
        stampedRelativePath: String?,
        captureMode: String?,
        lens: String?,
        exifOrientation: Int?,
        orientation: String? = nil,
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?,
        imageWidth: Int?,
        imageHeight: Int?
    ) {
        self.shotID = shotID
        self.propertyID = propertyID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.capturedAtLocal = ShotMetadata.trimmedNonEmpty(capturedAtLocal)
        self.updatedAt = updatedAt
        self.building = building
        self.elevation = elevation
        self.detailType = detailType
        self.angleIndex = angleIndex
        self.shotKey = shotKey
        self.isGuided = isGuided
        self.isFlagged = isFlagged
        self.issueID = issueID
        self.issueStatus = issueStatus
        self.captureKind = ShotMetadata.trimmedNonEmpty(captureKind)
        self.firstCaptureKind = ShotMetadata.trimmedNonEmpty(firstCaptureKind)
        self.noteText = noteText
        self.noteCategory = noteCategory
        self.originalFilename = originalFilename
        self.originalRelativePath = originalRelativePath
        self.originalByteSize = originalByteSize
        self.stampedFilename = stampedFilename
        self.stampedRelativePath = stampedRelativePath
        self.captureMode = captureMode
        self.lens = lens
        self.exifOrientation = ShotMetadata.validExifOrientation(exifOrientation)
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shotID = try c.decode(UUID.self, forKey: .shotID)
        propertyID = try c.decodeIfPresent(UUID.self, forKey: .propertyID) ?? UUID()
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let explicitCapturedLocal = ShotMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .capturedAtLocal))
        let legacyCreatedLocal = ShotMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .shotCreatedAtLocal))
        let legacyUpdatedLocal = ShotMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .shotUpdatedAtLocal))
        capturedAtLocal = explicitCapturedLocal ?? legacyUpdatedLocal ?? legacyCreatedLocal
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        building = try c.decodeIfPresent(String.self, forKey: .building) ?? ""
        elevation = CanonicalElevation.normalize(try c.decodeIfPresent(String.self, forKey: .elevation)) ?? ""
        detailType = try c.decodeIfPresent(String.self, forKey: .detailType) ?? ""
        angleIndex = max(1, try c.decodeIfPresent(Int.self, forKey: .angleIndex) ?? 1)
        let decodedShotKey = try c.decodeIfPresent(String.self, forKey: .shotKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        shotKey = decodedShotKey.isEmpty
            ? ShotMetadata.makeShotKey(building: building, elevation: elevation, detailType: detailType, angleIndex: angleIndex)
            : decodedShotKey
        isGuided = try c.decodeIfPresent(Bool.self, forKey: .isGuided) ?? false
        isFlagged = try c.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false
        issueID = try c.decodeIfPresent(UUID.self, forKey: .issueID)
        issueStatus = try c.decodeIfPresent(String.self, forKey: .issueStatus)
        captureKind = ShotMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .captureKind))
        firstCaptureKind = ShotMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .firstCaptureKind))
        noteText = try c.decodeIfPresent(String.self, forKey: .noteText)
        noteCategory = try c.decodeIfPresent(String.self, forKey: .noteCategory)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename) ?? ""
        let decodedRelative = try c.decodeIfPresent(String.self, forKey: .originalRelativePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if decodedRelative.isEmpty {
            let fallbackName = URL(fileURLWithPath: originalFilename).lastPathComponent
            originalRelativePath = fallbackName.isEmpty ? "" : "Originals/\(fallbackName)"
        } else {
            originalRelativePath = decodedRelative
        }
        originalByteSize = try c.decodeIfPresent(Int.self, forKey: .originalByteSize)
        stampedFilename = try c.decodeIfPresent(String.self, forKey: .stampedFilename)
        let decodedStampedRelative = try c.decodeIfPresent(String.self, forKey: .stampedRelativePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if decodedStampedRelative.isEmpty, let stampedFilename {
            let fallbackName = URL(fileURLWithPath: stampedFilename).lastPathComponent
            stampedRelativePath = fallbackName.isEmpty ? nil : "Stamped/\(fallbackName)"
        } else {
            stampedRelativePath = decodedStampedRelative.isEmpty ? nil : decodedStampedRelative
        }
        captureMode = try c.decodeIfPresent(String.self, forKey: .captureMode)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        orientation = try c.decodeIfPresent(String.self, forKey: .orientation)
        let explicitExifOrientation = try c.decodeIfPresent(Int.self, forKey: .exifOrientation)
        exifOrientation = ShotMetadata.validExifOrientation(explicitExifOrientation) ?? ShotMetadata.parseLegacyExifOrientation(orientation)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        accuracyMeters = try c.decodeIfPresent(Double.self, forKey: .accuracyMeters)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shotID, forKey: .shotID)
        // Legacy fields propertyID/sessionID are intentionally omitted from new schema output.
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(ShotMetadata.trimmedNonEmpty(capturedAtLocal), forKey: .capturedAtLocal)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(building, forKey: .building)
        try c.encode(CanonicalElevation.normalize(elevation) ?? elevation, forKey: .elevation)
        try c.encode(detailType, forKey: .detailType)
        try c.encode(max(1, angleIndex), forKey: .angleIndex)
        let encodedKey = shotKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(encodedKey.isEmpty ? ShotMetadata.makeShotKey(building: building, elevation: elevation, detailType: detailType, angleIndex: angleIndex) : encodedKey, forKey: .shotKey)
        try c.encode(isGuided, forKey: .isGuided)
        try c.encode(isFlagged, forKey: .isFlagged)
        try c.encodeIfPresent(issueID, forKey: .issueID)
        try c.encodeIfPresent(ShotMetadata.trimmedNonEmpty(captureKind), forKey: .captureKind)
        try c.encodeIfPresent(ShotMetadata.trimmedNonEmpty(firstCaptureKind), forKey: .firstCaptureKind)
        try c.encodeIfPresent(noteText, forKey: .noteText)
        try c.encodeIfPresent(noteCategory, forKey: .noteCategory)
        try c.encode(originalFilename, forKey: .originalFilename)
        try c.encode(originalRelativePath, forKey: .originalRelativePath)
        try c.encodeIfPresent(originalByteSize, forKey: .originalByteSize)
        try c.encodeIfPresent(stampedFilename, forKey: .stampedFilename)
        try c.encodeIfPresent(stampedRelativePath, forKey: .stampedRelativePath)
        try c.encodeIfPresent(captureMode, forKey: .captureMode)
        try c.encodeIfPresent(lens, forKey: .lens)
        try c.encodeIfPresent(ShotMetadata.validExifOrientation(exifOrientation), forKey: .exifOrientation)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(accuracyMeters, forKey: .accuracyMeters)
        try c.encodeIfPresent(imageWidth, forKey: .imageWidth)
        try c.encodeIfPresent(imageHeight, forKey: .imageHeight)
        try c.encode(logicalShotIdentity, forKey: .logicalShotIdentity)
    }

    static func makeShotKey(building: String, elevation: String, detailType: String, angleIndex: Int) -> String {
        let normalizedBuilding = normalizeKeyPart(building)
        let normalizedElevation = normalizeKeyPart(CanonicalElevation.normalize(elevation) ?? elevation)
        let normalizedDetailType = normalizeKeyPart(detailType)
        let normalizedAngle = String(max(1, angleIndex))
        return "\(normalizedBuilding)|\(normalizedElevation)|\(normalizedDetailType)|\(normalizedAngle)"
    }

    private static func normalizeKeyPart(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validExifOrientation(_ value: Int?) -> Int? {
        guard let value, (1...8).contains(value) else { return nil }
        return value
    }

    private static func parseLegacyExifOrientation(_ orientation: String?) -> Int? {
        let trimmed = orientation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let direct = Int(trimmed), (1...8).contains(direct) {
            return direct
        }
        let prefix = "exif:"
        if trimmed.lowercased().hasPrefix(prefix),
           let parsed = Int(trimmed.dropFirst(prefix.count)),
           (1...8).contains(parsed) {
            return parsed
        }
        return nil
    }
}

struct IssueMetadata: Codable, Identifiable, Equatable {
    let issueID: UUID
    var issueStatus: String
    var currentReason: String?
    var previousReason: String?
    var firstSeenAt: Date?
    var firstSeenAtLocal: String?
    var lastSeenAt: Date?
    var lastSeenAtLocal: String?
    var resolvedAt: Date?
    var resolvedAtLocal: String?
    var lastCaptureSessionId: UUID?
    var detailNote: String?
    var shotKey: String?
    var historyEvents: [IssueHistoryEvent]

    var id: UUID { issueID }

    private enum CodingKeys: String, CodingKey {
        case issueID
        case issueStatus
        case currentReason
        case previousReason
        case firstSeenAt
        case firstSeenAtLocal
        case lastSeenAt
        case lastSeenAtLocal
        case resolvedAt
        case resolvedAtLocal
        case lastCaptureSessionId
        case detailNote
        case shotKey
        case historyEvents
        case status
        case statement
    }

    init(
        issueID: UUID,
        issueStatus: String = "active",
        currentReason: String? = nil,
        previousReason: String? = nil,
        firstSeenAt: Date? = nil,
        firstSeenAtLocal: String? = nil,
        lastSeenAt: Date? = nil,
        lastSeenAtLocal: String? = nil,
        resolvedAt: Date? = nil,
        resolvedAtLocal: String? = nil,
        lastCaptureSessionId: UUID? = nil,
        detailNote: String? = nil,
        shotKey: String? = nil,
        historyEvents: [IssueHistoryEvent] = []
    ) {
        self.issueID = issueID
        self.issueStatus = IssueMetadata.normalizedStatus(issueStatus)
        self.currentReason = IssueMetadata.trimmedNonEmpty(currentReason)
        self.previousReason = IssueMetadata.trimmedNonEmpty(previousReason)
        self.firstSeenAt = firstSeenAt
        self.firstSeenAtLocal = IssueMetadata.trimmedNonEmpty(firstSeenAtLocal)
        self.lastSeenAt = lastSeenAt
        self.lastSeenAtLocal = IssueMetadata.trimmedNonEmpty(lastSeenAtLocal)
        self.resolvedAt = resolvedAt
        self.resolvedAtLocal = IssueMetadata.trimmedNonEmpty(resolvedAtLocal)
        self.lastCaptureSessionId = lastCaptureSessionId
        self.detailNote = IssueMetadata.trimmedNonEmpty(detailNote)
        self.shotKey = IssueMetadata.trimmedNonEmpty(shotKey)
        self.historyEvents = historyEvents.sorted { $0.timestamp < $1.timestamp }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issueID = try c.decode(UUID.self, forKey: .issueID)

        if let raw = try c.decodeIfPresent(String.self, forKey: .issueStatus) {
            issueStatus = IssueMetadata.normalizedStatus(raw)
        } else if let raw = try c.decodeIfPresent(String.self, forKey: .status) {
            issueStatus = IssueMetadata.normalizedStatus(raw)
        } else if let legacyStatus = try c.decodeIfPresent(Observation.Status.self, forKey: .status) {
            issueStatus = legacyStatus == .resolved ? "resolved" : "active"
        } else {
            issueStatus = "active"
        }

        currentReason = IssueMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .currentReason))
        previousReason = IssueMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .previousReason))
        firstSeenAt = try c.decodeIfPresent(Date.self, forKey: .firstSeenAt)
        firstSeenAtLocal = IssueMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .firstSeenAtLocal))
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        lastSeenAtLocal = IssueMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .lastSeenAtLocal))
        resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        resolvedAtLocal = IssueMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .resolvedAtLocal))
        lastCaptureSessionId = try c.decodeIfPresent(UUID.self, forKey: .lastCaptureSessionId)
        if let note = try c.decodeIfPresent(String.self, forKey: .detailNote) {
            detailNote = IssueMetadata.trimmedNonEmpty(note)
        } else {
            detailNote = IssueMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .statement))
        }
        shotKey = IssueMetadata.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .shotKey))
        historyEvents = try c.decodeIfPresent([IssueHistoryEvent].self, forKey: .historyEvents) ?? []
        if currentReason == nil {
            currentReason = detailNote
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(issueID, forKey: .issueID)
        try c.encode(IssueMetadata.normalizedStatus(issueStatus), forKey: .issueStatus)
        try c.encode(IssueMetadata.normalizedStatus(issueStatus), forKey: .status)
        try c.encodeIfPresent(IssueMetadata.trimmedNonEmpty(currentReason), forKey: .currentReason)
        try c.encodeIfPresent(IssueMetadata.trimmedNonEmpty(previousReason), forKey: .previousReason)
        try c.encodeIfPresent(firstSeenAt, forKey: .firstSeenAt)
        try c.encodeIfPresent(IssueMetadata.trimmedNonEmpty(firstSeenAtLocal), forKey: .firstSeenAtLocal)
        try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try c.encodeIfPresent(IssueMetadata.trimmedNonEmpty(lastSeenAtLocal), forKey: .lastSeenAtLocal)
        try c.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try c.encodeIfPresent(IssueMetadata.trimmedNonEmpty(resolvedAtLocal), forKey: .resolvedAtLocal)
        try c.encodeIfPresent(lastCaptureSessionId, forKey: .lastCaptureSessionId)
        try c.encodeIfPresent(IssueMetadata.trimmedNonEmpty(detailNote ?? currentReason), forKey: .detailNote)
        try c.encodeIfPresent(IssueMetadata.trimmedNonEmpty(shotKey), forKey: .shotKey)
        try c.encode(historyEvents.sorted { $0.timestamp < $1.timestamp }, forKey: .historyEvents)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedStatus(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered == "resolved" ? "resolved" : "active"
    }
}

struct Property: Codable, Identifiable, Equatable {
    let id: UUID
    var orgId: UUID?
    var folderId: String?
    var clientName: String?
    var clientPhone: String?
    var name: String
    var address: String?
    var street: String?
    var city: String?
    var state: String?
    var zip: String?
    var baselineSessionID: UUID?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        orgId: UUID? = nil,
        folderId: String? = nil,
        clientName: String? = nil,
        clientPhone: String? = nil,
        name: String,
        address: String? = nil,
        street: String? = nil,
        city: String? = nil,
        state: String? = nil,
        zip: String? = nil,
        baselineSessionID: UUID? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.orgId = orgId
        self.folderId = folderId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientName = clientName
        self.clientPhone = clientPhone
        self.name = name
        self.address = address
        self.street = street?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.city = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.state = state?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.zip = zip?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baselineSessionID = baselineSessionID
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case orgId
        case folderId
        case clientName
        case clientPhone
        case name
        case address
        case street
        case city
        case state
        case zip
        case baselineSessionID
        case isArchived
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        orgId = try c.decodeIfPresent(UUID.self, forKey: .orgId)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)?.trimmingCharacters(in: .whitespacesAndNewlines)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName)
        clientPhone = try c.decodeIfPresent(String.self, forKey: .clientPhone)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        street = try c.decodeIfPresent(String.self, forKey: .street)?.trimmingCharacters(in: .whitespacesAndNewlines)
        city = try c.decodeIfPresent(String.self, forKey: .city)?.trimmingCharacters(in: .whitespacesAndNewlines)
        state = try c.decodeIfPresent(String.self, forKey: .state)?.trimmingCharacters(in: .whitespacesAndNewlines)
        zip = try c.decodeIfPresent(String.self, forKey: .zip)?.trimmingCharacters(in: .whitespacesAndNewlines)
        baselineSessionID = try c.decodeIfPresent(UUID.self, forKey: .baselineSessionID)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(orgId, forKey: .orgId)
        try c.encodeIfPresent(folderId?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .folderId)
        try c.encodeIfPresent(clientName, forKey: .clientName)
        try c.encodeIfPresent(clientPhone, forKey: .clientPhone)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encodeIfPresent(street?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .street)
        try c.encodeIfPresent(city?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .city)
        try c.encodeIfPresent(state?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .state)
        try c.encodeIfPresent(zip?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .zip)
        try c.encodeIfPresent(baselineSessionID, forKey: .baselineSessionID)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct Session: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case draft
        case completed
    }

    let id: UUID
    let propertyID: UUID
    var startedAt: Date
    var status: Status
    var endedAt: Date?
    var exportedAt: Date?
    var isSealed: Bool
    var firstDeliveredAt: Date?
    var reExportExpiresAt: Date?
    var notes: String?

    init(
        id: UUID = UUID(),
        propertyID: UUID,
        startedAt: Date = Date(),
        status: Status = .draft,
        endedAt: Date? = nil,
        exportedAt: Date? = nil,
        isSealed: Bool = false,
        firstDeliveredAt: Date? = nil,
        reExportExpiresAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.propertyID = propertyID
        self.startedAt = startedAt
        self.status = status
        self.endedAt = endedAt
        self.exportedAt = exportedAt
        self.isSealed = isSealed
        self.firstDeliveredAt = firstDeliveredAt
        self.reExportExpiresAt = reExportExpiresAt
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case propertyID
        case startedAt
        case status
        case endedAt
        case exportedAt
        case isSealed
        case firstDeliveredAt
        case reExportExpiresAt
        case notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        propertyID = try c.decode(UUID.self, forKey: .propertyID)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        let decodedIsSealed = try c.decodeIfPresent(Bool.self, forKey: .isSealed)
        firstDeliveredAt = try c.decodeIfPresent(Date.self, forKey: .firstDeliveredAt) ?? exportedAt
        if let explicitExpiry = try c.decodeIfPresent(Date.self, forKey: .reExportExpiresAt) {
            reExportExpiresAt = explicitExpiry
        } else if let deliveredAt = firstDeliveredAt {
            reExportExpiresAt = Calendar.current.date(byAdding: .day, value: 7, to: deliveredAt)
        } else {
            reExportExpiresAt = nil
        }
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        if let decodedStatus = try c.decodeIfPresent(Status.self, forKey: .status) {
            status = decodedStatus
        } else {
            // Legacy migration for existing sessions persisted before explicit status existed.
            status = (endedAt == nil) ? .draft : .completed
        }
        isSealed = decodedIsSealed ?? (status == .completed)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try c.encode(isSealed, forKey: .isSealed)
        try c.encodeIfPresent(firstDeliveredAt, forKey: .firstDeliveredAt)
        try c.encodeIfPresent(reExportExpiresAt, forKey: .reExportExpiresAt)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

enum SkipReason: String, Codable, CaseIterable {
    case inaccessible
    case obstructed
    case activeConstruction
    case safetyConcern
    case other

    // Legacy values retained for backwards compatibility with existing saved data.
    case notVisible
    case unsafe
    case blocked
    case notApplicable
}

enum GuidedCheckpointStatus: String, Codable {
    case active
    case retired
}

struct Shot: Codable, Identifiable, Equatable {
    let id: UUID
    var capturedAt: Date
    var imageLocalIdentifier: String?
    var note: String?

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        imageLocalIdentifier: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.imageLocalIdentifier = imageLocalIdentifier
        self.note = note
    }
}

struct GuidedShot: Codable, Identifiable, Equatable {
    let id: UUID
    var status: GuidedCheckpointStatus
    var title: String
    var building: String?
    var targetElevation: String?
    var detailType: String?
    var angleIndex: Int?
    var referenceImageLocalIdentifier: String?
    var referenceImagePath: String?
    var shot: Shot?
    var isCompleted: Bool
    var skipReason: SkipReason?
    var skipReasonNote: String?
    var skipSessionID: UUID?
    var isRetired: Bool
    var retiredAt: Date?
    var retiredInSessionID: UUID?
    var reassignedFromGuidedShotID: UUID?
    var reassignedToGuidedShotID: UUID?
    var reassignedAt: Date?
    var reassignedInSessionID: UUID?
    var labelEditedAt: Date?
    var labelEditedInSessionID: UUID?

    init(
        id: UUID = UUID(),
        status: GuidedCheckpointStatus = .active,
        title: String,
        building: String? = nil,
        targetElevation: String? = nil,
        detailType: String? = nil,
        angleIndex: Int? = nil,
        referenceImageLocalIdentifier: String? = nil,
        referenceImagePath: String? = nil,
        shot: Shot? = nil,
        isCompleted: Bool = false,
        skipReason: SkipReason? = nil,
        skipReasonNote: String? = nil,
        skipSessionID: UUID? = nil,
        isRetired: Bool = false,
        retiredAt: Date? = nil,
        retiredInSessionID: UUID? = nil,
        reassignedFromGuidedShotID: UUID? = nil,
        reassignedToGuidedShotID: UUID? = nil,
        reassignedAt: Date? = nil,
        reassignedInSessionID: UUID? = nil,
        labelEditedAt: Date? = nil,
        labelEditedInSessionID: UUID? = nil
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.building = building
        self.targetElevation = targetElevation
        self.detailType = detailType
        self.angleIndex = angleIndex
        self.referenceImageLocalIdentifier = referenceImageLocalIdentifier
        self.referenceImagePath = referenceImagePath
        self.shot = shot
        self.isCompleted = isCompleted
        self.skipReason = skipReason
        self.skipReasonNote = skipReasonNote
        self.skipSessionID = skipSessionID
        self.isRetired = isRetired
        self.retiredAt = retiredAt
        self.retiredInSessionID = retiredInSessionID
        self.reassignedFromGuidedShotID = reassignedFromGuidedShotID
        self.reassignedToGuidedShotID = reassignedToGuidedShotID
        self.reassignedAt = reassignedAt
        self.reassignedInSessionID = reassignedInSessionID
        self.labelEditedAt = labelEditedAt
        self.labelEditedInSessionID = labelEditedInSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case title
        case building
        case targetElevation
        case detailType
        case angleIndex
        case referenceImageLocalIdentifier
        case referenceImagePath
        case shot
        case isCompleted
        case skipReason
        case skipReasonNote
        case skipSessionID
        case isRetired
        case retiredAt
        case retiredInSessionID
        case reassignedFromGuidedShotID
        case reassignedToGuidedShotID
        case reassignedAt
        case reassignedInSessionID
        case labelEditedAt
        case labelEditedInSessionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        status = try c.decodeIfPresent(GuidedCheckpointStatus.self, forKey: .status) ?? .active
        title = try c.decode(String.self, forKey: .title)
        building = try c.decodeIfPresent(String.self, forKey: .building)
        targetElevation = CanonicalElevation.normalize(try c.decodeIfPresent(String.self, forKey: .targetElevation))
        detailType = try c.decodeIfPresent(String.self, forKey: .detailType)
        angleIndex = try c.decodeIfPresent(Int.self, forKey: .angleIndex)
        referenceImageLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .referenceImageLocalIdentifier)
        referenceImagePath = try c.decodeIfPresent(String.self, forKey: .referenceImagePath)
        shot = try c.decodeIfPresent(Shot.self, forKey: .shot)
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        skipReason = try c.decodeIfPresent(SkipReason.self, forKey: .skipReason)
        skipReasonNote = try c.decodeIfPresent(String.self, forKey: .skipReasonNote)
        skipSessionID = try c.decodeIfPresent(UUID.self, forKey: .skipSessionID)
        isRetired = try c.decodeIfPresent(Bool.self, forKey: .isRetired) ?? false
        retiredAt = try c.decodeIfPresent(Date.self, forKey: .retiredAt)
        retiredInSessionID = try c.decodeIfPresent(UUID.self, forKey: .retiredInSessionID)
        reassignedFromGuidedShotID = try c.decodeIfPresent(UUID.self, forKey: .reassignedFromGuidedShotID)
        reassignedToGuidedShotID = try c.decodeIfPresent(UUID.self, forKey: .reassignedToGuidedShotID)
        reassignedAt = try c.decodeIfPresent(Date.self, forKey: .reassignedAt)
        reassignedInSessionID = try c.decodeIfPresent(UUID.self, forKey: .reassignedInSessionID)
        labelEditedAt = try c.decodeIfPresent(Date.self, forKey: .labelEditedAt)
        labelEditedInSessionID = try c.decodeIfPresent(UUID.self, forKey: .labelEditedInSessionID)
        if isRetired {
            status = .retired
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(status, forKey: .status)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(building, forKey: .building)
        try c.encodeIfPresent(CanonicalElevation.normalize(targetElevation), forKey: .targetElevation)
        try c.encodeIfPresent(detailType, forKey: .detailType)
        try c.encodeIfPresent(angleIndex, forKey: .angleIndex)
        try c.encodeIfPresent(referenceImageLocalIdentifier, forKey: .referenceImageLocalIdentifier)
        try c.encodeIfPresent(referenceImagePath, forKey: .referenceImagePath)
        try c.encodeIfPresent(shot, forKey: .shot)
        try c.encode(isCompleted, forKey: .isCompleted)
        try c.encodeIfPresent(skipReason, forKey: .skipReason)
        try c.encodeIfPresent(skipReasonNote, forKey: .skipReasonNote)
        try c.encodeIfPresent(skipSessionID, forKey: .skipSessionID)
        try c.encode(isRetired, forKey: .isRetired)
        try c.encodeIfPresent(retiredAt, forKey: .retiredAt)
        try c.encodeIfPresent(retiredInSessionID, forKey: .retiredInSessionID)
        try c.encodeIfPresent(reassignedFromGuidedShotID, forKey: .reassignedFromGuidedShotID)
        try c.encodeIfPresent(reassignedToGuidedShotID, forKey: .reassignedToGuidedShotID)
        try c.encodeIfPresent(reassignedAt, forKey: .reassignedAt)
        try c.encodeIfPresent(reassignedInSessionID, forKey: .reassignedInSessionID)
        try c.encodeIfPresent(labelEditedAt, forKey: .labelEditedAt)
        try c.encodeIfPresent(labelEditedInSessionID, forKey: .labelEditedInSessionID)
    }
}

struct Observation: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case active = "Active"
        case resolved = "Resolved"
    }

    let id: UUID
    let propertyID: UUID
    let sessionID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var statement: String
    var status: Status
    var linkedShotID: UUID?
    var resolutionPhotoRef: String?
    var resolutionStatement: String?
    var updatedInSessionID: UUID?
    var resolvedInSessionID: UUID?
    var building: String?
    var targetElevation: String?
    var detailType: String?
    var currentReason: String?
    var previousReason: String?
    var historyEvents: [ObservationHistoryEvent]
    var updateHistory: [ObservationUpdateEntry]
    var note: String?
    var shots: [Shot]
    var guidedShots: [GuidedShot]

    init(
        id: UUID = UUID(),
        propertyID: UUID,
        sessionID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        statement: String = "",
        status: Status = .active,
        linkedShotID: UUID? = nil,
        resolutionPhotoRef: String? = nil,
        resolutionStatement: String? = nil,
        updatedInSessionID: UUID? = nil,
        resolvedInSessionID: UUID? = nil,
        building: String? = nil,
        targetElevation: String? = nil,
        detailType: String? = nil,
        currentReason: String? = nil,
        previousReason: String? = nil,
        historyEvents: [ObservationHistoryEvent] = [],
        updateHistory: [ObservationUpdateEntry] = [],
        note: String? = nil,
        shots: [Shot] = [],
        guidedShots: [GuidedShot] = []
    ) {
        self.id = id
        self.propertyID = propertyID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statement = statement
        self.status = status
        self.linkedShotID = linkedShotID
        self.resolutionPhotoRef = resolutionPhotoRef
        self.resolutionStatement = resolutionStatement
        self.updatedInSessionID = updatedInSessionID
        self.resolvedInSessionID = resolvedInSessionID
        self.building = building
        self.targetElevation = targetElevation
        self.detailType = detailType
        self.currentReason = Observation.trimmedNonEmpty(currentReason)
        self.previousReason = Observation.trimmedNonEmpty(previousReason)
        self.historyEvents = historyEvents.sorted { $0.timestamp < $1.timestamp }
        self.updateHistory = updateHistory
        self.note = Observation.trimmedNonEmpty(note)
        self.shots = shots
        self.guidedShots = guidedShots
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case propertyID
        case sessionID
        case createdAt
        case updatedAt
        case statement
        case status
        case linkedShotID
        case resolutionPhotoRef
        case resolutionStatement
        case updatedInSessionID
        case resolvedInSessionID
        case building
        case targetElevation
        case detailType
        case currentReason
        case previousReason
        case historyEvents
        case updateHistory
        case note
        case shots
        case guidedShots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        propertyID = try c.decode(UUID.self, forKey: .propertyID)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        statement = try c.decode(String.self, forKey: .statement)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .active
        linkedShotID = try c.decodeIfPresent(UUID.self, forKey: .linkedShotID)
        resolutionPhotoRef = try c.decodeIfPresent(String.self, forKey: .resolutionPhotoRef)
        resolutionStatement = try c.decodeIfPresent(String.self, forKey: .resolutionStatement)
        updatedInSessionID = try c.decodeIfPresent(UUID.self, forKey: .updatedInSessionID)
        resolvedInSessionID = try c.decodeIfPresent(UUID.self, forKey: .resolvedInSessionID)
        building = try c.decodeIfPresent(String.self, forKey: .building)
        targetElevation = CanonicalElevation.normalize(try c.decodeIfPresent(String.self, forKey: .targetElevation))
        detailType = try c.decodeIfPresent(String.self, forKey: .detailType)
        let decodedNote = try c.decodeIfPresent(String.self, forKey: .note)
        currentReason = Observation.trimmedNonEmpty(
            try c.decodeIfPresent(String.self, forKey: .currentReason)
        ) ?? Observation.inferredCurrentReason(note: decodedNote, statement: statement)
        previousReason = Observation.trimmedNonEmpty(try c.decodeIfPresent(String.self, forKey: .previousReason))
        note = Observation.trimmedNonEmpty(decodedNote)
        updateHistory = try c.decodeIfPresent([ObservationUpdateEntry].self, forKey: .updateHistory) ?? []
        historyEvents = try c.decodeIfPresent([ObservationHistoryEvent].self, forKey: .historyEvents)
            ?? Observation.legacyHistoryEvents(
                createdAt: createdAt,
                sessionID: sessionID,
                from: updateHistory,
                currentReason: currentReason
            )
        shots = try c.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        guidedShots = try c.decodeIfPresent([GuidedShot].self, forKey: .guidedShots) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(statement, forKey: .statement)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(linkedShotID, forKey: .linkedShotID)
        try c.encodeIfPresent(resolutionPhotoRef, forKey: .resolutionPhotoRef)
        try c.encodeIfPresent(resolutionStatement, forKey: .resolutionStatement)
        try c.encodeIfPresent(updatedInSessionID, forKey: .updatedInSessionID)
        try c.encodeIfPresent(resolvedInSessionID, forKey: .resolvedInSessionID)
        try c.encodeIfPresent(building, forKey: .building)
        try c.encodeIfPresent(CanonicalElevation.normalize(targetElevation), forKey: .targetElevation)
        try c.encodeIfPresent(detailType, forKey: .detailType)
        try c.encodeIfPresent(Observation.trimmedNonEmpty(currentReason), forKey: .currentReason)
        try c.encodeIfPresent(Observation.trimmedNonEmpty(previousReason), forKey: .previousReason)
        try c.encode(historyEvents.sorted { $0.timestamp < $1.timestamp }, forKey: .historyEvents)
        try c.encode(updateHistory, forKey: .updateHistory)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(shots, forKey: .shots)
        try c.encode(guidedShots, forKey: .guidedShots)
    }

    static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func inferredCurrentReason(note: String?, statement: String) -> String? {
        trimmedNonEmpty(note) ?? trimmedNonEmpty(statement)
    }

    private static func legacyHistoryEvents(
        createdAt: Date,
        sessionID: UUID?,
        from updateHistory: [ObservationUpdateEntry],
        currentReason: String?
    ) -> [ObservationHistoryEvent] {
        var events: [ObservationHistoryEvent] = []
        events.append(
            ObservationHistoryEvent(
                timestamp: createdAt,
                sessionID: sessionID,
                kind: .created,
                afterValue: currentReason,
                field: currentReason == nil ? nil : "reason",
                shotID: nil
            )
        )
        events.append(contentsOf: updateHistory.compactMap { entry in
            switch entry.kind {
            case .followUpCapture:
                return ObservationHistoryEvent(
                    timestamp: entry.createdAt,
                    sessionID: nil,
                    kind: .captured,
                    beforeValue: nil,
                    afterValue: nil,
                    field: nil,
                    shotID: entry.shotID
                )
            case .revisedObservation:
                let revised = trimmedNonEmpty(entry.text)
                return ObservationHistoryEvent(
                    timestamp: entry.createdAt,
                    sessionID: nil,
                    kind: .reasonUpdated,
                    beforeValue: nil,
                    afterValue: revised ?? currentReason,
                    field: "reason",
                    shotID: entry.shotID
                )
            }
        })
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}

struct ObservationUpdateEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case followUpCapture
        case revisedObservation
    }

    let id: UUID
    let createdAt: Date
    var kind: Kind
    var text: String?
    var shotID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: Kind,
        text: String? = nil,
        shotID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.shotID = shotID
    }
}

struct ObservationHistoryEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case created
        case captured
        case retake
        case reclassified
        case resolved
        case reopened
        case reasonUpdated = "reason_updated"
        case titleUpdated = "title_updated"
    }

    let id: UUID
    let timestamp: Date
    var sessionID: UUID?
    var kind: Kind
    var beforeValue: String?
    var afterValue: String?
    var field: String?
    var shotID: UUID?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID? = nil,
        kind: Kind,
        beforeValue: String? = nil,
        afterValue: String? = nil,
        field: String? = nil,
        shotID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.kind = kind
        self.beforeValue = Observation.trimmedNonEmpty(beforeValue)
        self.afterValue = Observation.trimmedNonEmpty(afterValue)
        self.field = Observation.trimmedNonEmpty(field)
        self.shotID = shotID
    }
}

struct IssueHistoryEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    var sessionId: UUID?
    var type: String
    var details: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date,
        sessionId: UUID?,
        type: String,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.type = type
        self.details = details
    }
}

struct ReportAsset: Identifiable, Equatable {
    let localIdentifier: String
    let fileURL: URL
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let originalFilename: String

    var id: String { localIdentifier }
}
