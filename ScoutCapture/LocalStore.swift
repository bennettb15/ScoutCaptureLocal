import Foundation
import UIKit

final class LocalStore {
    private let currentSessionSchemaVersion = 8
    private let fileIOQueue = DispatchQueue(label: "ScoutCapture.LocalStore.fileIO")
    private let fileIOQueueKey = DispatchSpecificKey<UInt8>()
    private let fileIOQueueValue: UInt8 = 1

    enum ShotUpsertMatchMode {
        case append
        case replaceGuidedKey
    }

    enum StoreError: Error {
        case propertyNotFound(UUID)
        case observationNotFound(UUID)
        case sessionNotFound(UUID)
    }

    struct ExportValidationReport {
        let phase: String
        let passed: Bool
        let failureCount: Int
        let reportText: String
    }

    struct ValidatedSessionExportArtifacts {
        let metadata: SessionMetadata
        let sessionData: Data
        let validationData: Data
        let prewritePassed: Bool
        let postwritePassed: Bool
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let activeRootURL: URL
    private let scoutRootURL: URL
    private let propertiesURL: URL
    private let propertyFoldersURL: URL
    private let observationsDirectoryURL: URL
    private let guidedShotsDirectoryURL: URL
    private let sessionsDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let appRoot = StorageRoot.prepareStorage()
        let scoutRoot = appRoot.appendingPathComponent("SCOUT", isDirectory: true)
        self.activeRootURL = appRoot
        self.scoutRootURL = scoutRoot
        self.propertiesURL = scoutRoot.appendingPathComponent("properties.json")
        self.propertyFoldersURL = scoutRoot.appendingPathComponent("Properties", isDirectory: true)
        self.observationsDirectoryURL = scoutRoot.appendingPathComponent("observations", isDirectory: true)
        self.guidedShotsDirectoryURL = scoutRoot.appendingPathComponent("guided-shots", isDirectory: true)
        self.sessionsDirectoryURL = scoutRoot.appendingPathComponent("sessions", isDirectory: true)
        self.fileIOQueue.setSpecific(key: fileIOQueueKey, value: fileIOQueueValue)

        try? createStorageDirectories(baseDirectoryURL: scoutRoot)
    }

    func validateExport(_ metadata: SessionMetadata, phase: String) -> ExportValidationReport {
        var failures: [String] = []
        let canonicalIssues = metadata.issues
        let activeIssues = canonicalIssues.filter {
            SessionMetadata.trimmedNonEmpty($0.issueStatus)?.lowercased() == "active"
        }
        let resolvedIssues = canonicalIssues.filter {
            SessionMetadata.trimmedNonEmpty($0.issueStatus)?.lowercased() == "resolved"
        }
        let derivedFlaggedIssues = metadata.flaggedIssues
        let reasonUpdatedEventsCount = canonicalIssues.reduce(into: 0) { count, issue in
            count += issue.historyEvents.filter { $0.type == "reason_updated" }.count
        }
        let shotsCount = metadata.shots.count
        let flaggedShotsCount = metadata.shots.filter(\.isFlagged).count
        let guidedShotsCount = metadata.shots.filter(\.isGuided).count
        let retakeShotsCount = metadata.shots.filter {
            SessionMetadata.trimmedNonEmpty($0.captureKind) == "retake"
        }.count
        let capturedShotsCount = metadata.shots.filter {
            SessionMetadata.trimmedNonEmpty($0.captureKind) == "captured"
        }.count
        let guidedRowsCount = metadata.guidedShots.count
        let guidedSkippedCount = metadata.guidedShots.filter { $0.skipReason != nil }.count
        let guidedRetiredCount = metadata.guidedShots.filter { $0.status == .retired }.count

        if derivedFlaggedIssues.count != activeIssues.count {
            failures.append("flaggedIssues count \(derivedFlaggedIssues.count) does not match active issues count \(activeIssues.count)")
        }

        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalIssues.map { ($0.issueID, $0) })
        for flaggedIssue in derivedFlaggedIssues {
            guard let canonical = canonicalByID[flaggedIssue.issueID] else {
                failures.append("flaggedIssues contains issueID \(flaggedIssue.issueID.uuidString) missing from issues[]")
                continue
            }

            if SessionMetadata.trimmedNonEmpty(canonical.issueStatus)?.lowercased() != "active" {
                failures.append("flaggedIssues issueID \(flaggedIssue.issueID.uuidString) is not active in issues[]")
            }

            if canonical.currentReason != flaggedIssue.currentReason ||
                canonical.previousReason != flaggedIssue.previousReason ||
                canonical.historyEvents != flaggedIssue.historyEvents {
                failures.append("flaggedIssues issueID \(flaggedIssue.issueID.uuidString) does not match canonical issues[] record")
            }
        }

        for issue in canonicalIssues {
            let reasonEvents = issue.historyEvents.filter { $0.type == "reason_updated" }
            if !reasonEvents.isEmpty {
                if SessionMetadata.trimmedNonEmpty(issue.previousReason) == nil {
                    failures.append("issueID \(issue.issueID.uuidString) has reason_updated history but missing previousReason")
                } else if let latestOldReason = reasonEvents.last?.details["oldReason"],
                          SessionMetadata.trimmedNonEmpty(issue.previousReason) != SessionMetadata.trimmedNonEmpty(latestOldReason) {
                    failures.append("issueID \(issue.issueID.uuidString) previousReason does not match latest reason_updated.oldReason")
                }
            }

            if SessionMetadata.trimmedNonEmpty(issue.currentReason) == nil {
                failures.append("issueID \(issue.issueID.uuidString) missing currentReason")
            }
        }

        for shot in metadata.shots where shot.isFlagged {
            if SessionMetadata.trimmedNonEmpty(shot.firstCaptureKind) == nil {
                failures.append("flagged shotID \(shot.shotID.uuidString) missing firstCaptureKind")
            }
            if SessionMetadata.trimmedNonEmpty(shot.captureKind) == "retake",
               SessionMetadata.trimmedNonEmpty(shot.firstCaptureKind) != "captured" {
                failures.append("flagged shotID \(shot.shotID.uuidString) has captureKind retake but firstCaptureKind is not captured")
            }
        }

        let statusLine = failures.isEmpty ? "PASS" : "FAIL"
        var lines: [String] = []
        lines.append("EXPORT VALIDATION SUMMARY (\(phase))")
        lines.append("Counts:")
        lines.append("  shots: \(shotsCount)")
        lines.append("  flaggedShots: \(flaggedShotsCount)")
        lines.append("  guidedShots: \(guidedShotsCount)")
        lines.append("  retakeShots: \(retakeShotsCount)")
        lines.append("  capturedShots: \(capturedShotsCount)")
        lines.append("")
        lines.append("  issues: \(canonicalIssues.count)")
        lines.append("  activeIssues: \(activeIssues.count)")
        lines.append("  resolvedIssues: \(resolvedIssues.count)")
        lines.append("  flaggedIssues: \(derivedFlaggedIssues.count)")
        lines.append("  reasonUpdatedEvents: \(reasonUpdatedEventsCount)")
        lines.append("")
        lines.append("  guidedRows: \(guidedRowsCount)")
        lines.append("  guidedSkipped: \(guidedSkippedCount)")
        lines.append("  guidedRetired: \(guidedRetiredCount)")
        lines.append("Result: \(statusLine)")
        if !failures.isEmpty {
            lines.append("Failures:")
            lines.append(contentsOf: failures.map { "- \($0)" })
        }

        return ExportValidationReport(
            phase: phase,
            passed: failures.isEmpty,
            failureCount: failures.count,
            reportText: lines.joined(separator: "\n")
        )
    }

    func validationText(
        for metadata: SessionMetadata,
        prewrite: ExportValidationReport,
        postwrite: ExportValidationReport,
        createdAt: Date = Date()
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let headerLines: [String] = [
            "SCOUT Export Validation",
            "schemaVersion: \(metadata.schemaVersion)",
            "appVersion: \(metadata.appVersion)",
            "sessionID: \(metadata.sessionID.uuidString)",
            "propertyID: \(metadata.propertyID.uuidString)",
            "isBaselineSession: \(metadata.isBaselineSession ? "true" : "false")",
            "createdAt: \(formatter.string(from: createdAt))"
        ]

        let finalResult = (prewrite.passed && postwrite.passed) ? "PASS" : "FAIL"
        return [
            headerLines.joined(separator: "\n"),
            prewrite.reportText,
            postwrite.reportText,
            "FINAL RESULT: \(finalResult)"
        ].joined(separator: "\n\n")
    }

    func validatedSessionExportArtifacts(for session: Session) throws -> ValidatedSessionExportArtifacts {
        try ensureSessionMetadata(for: session)
        let exportObject = try loadSessionMetadata(propertyID: session.propertyID, sessionID: session.id)
        let validationReportPre = validateExport(exportObject, phase: "prewrite")
        try saveSessionMetadataAtomically(
            propertyID: session.propertyID,
            sessionID: session.id,
            metadata: exportObject
        )
        let sessionURL = sessionJSONURL(propertyID: session.propertyID, sessionID: session.id)
        let sessionData = try Data(contentsOf: sessionURL)
        let exportObjectPost = try decoder.decode(SessionMetadata.self, from: sessionData)
        let validationReportPost = validateExport(exportObjectPost, phase: "postwrite")
        let validationData = Data(
            validationText(
                for: exportObjectPost,
                prewrite: validationReportPre,
                postwrite: validationReportPost
            ).utf8
        )

        return ValidatedSessionExportArtifacts(
            metadata: exportObjectPost,
            sessionData: sessionData,
            validationData: validationData,
            prewritePassed: validationReportPre.passed,
            postwritePassed: validationReportPost.passed
        )
    }

    func exportCSVFiles(for metadata: SessionMetadata) -> [(filename: String, data: Data)] {
        [
            ("sessions.csv", Data(buildSessionsCSV(metadata: metadata).utf8)),
            ("shots.csv", Data(buildShotsCSV(metadata: metadata).utf8)),
            ("issues.csv", Data(buildIssuesCSV(metadata: metadata).utf8)),
            ("issue_history.csv", Data(buildIssueHistoryCSV(metadata: metadata).utf8)),
            ("guided_rows.csv", Data(buildGuidedRowsCSV(metadata: metadata).utf8))
        ]
    }

    private func buildSessionsCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "session_id",
            "property_id",
            "property_name",
            "client_name",
            "client_phone",
            "property_address",
            "started_at_utc",
            "ended_at_utc",
            "is_baseline",
            "status",
            "schema_version",
            "app_version",
            "time_zone"
        ]

        let property = currentProperty(for: metadata.propertyID)
        let row = [
            metadata.sessionID.uuidString,
            metadata.propertyID.uuidString,
            metadata.propertyNameAtExport ?? metadata.propertyNameAtCapture ?? "",
            property?.clientName ?? "",
            metadata.propertyPhoneAtCapture ?? property?.clientPhone ?? "",
            metadata.propertyAddressAtCapture ?? "",
            iso8601String(metadata.startedAt),
            iso8601String(metadata.endedAt),
            boolString(metadata.isBaselineSession),
            metadata.status.rawValue,
            String(metadata.schemaVersion),
            metadata.appVersion,
            metadata.timeZoneIdentifierAtCapture
        ]
        return csvString(headers: headers, rows: [row])
    }

    private func buildShotsCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "shot_id",
            "session_id",
            "property_id",
            "building",
            "elevation",
            "detail_type",
            "angle_index",
            "shot_key",
            "capture_kind",
            "is_flagged",
            "is_guided",
            "issue_id",
            "captured_at_utc",
            "latitude",
            "longitude",
            "lens",
            "original_filename",
            "original_byte_size"
        ]

        let rows = metadata.shots.map { shot in
            [
                shot.shotID.uuidString,
                metadata.sessionID.uuidString,
                metadata.propertyID.uuidString,
                shot.building,
                shot.elevation,
                shot.detailType,
                String(max(1, shot.angleIndex)),
                shot.shotKey,
                normalizedCaptureKind(for: shot),
                boolString(shot.isFlagged),
                boolString(shot.isGuided),
                shot.issueID?.uuidString ?? "",
                iso8601String(shot.createdAt),
                decimalString(shot.latitude),
                decimalString(shot.longitude),
                shot.lens ?? "",
                shot.originalFilename,
                intString(shot.originalByteSize)
            ]
        }

        return csvString(headers: headers, rows: rows)
    }

    private func buildIssuesCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "issue_id",
            "property_id",
            "first_seen_session_id",
            "last_capture_session_id",
            "current_status",
            "current_reason",
            "previous_reason",
            "first_seen_at_utc",
            "last_seen_at_utc",
            "resolved_at_utc",
            "shot_key"
        ]

        let rows = metadata.issues.map { issue in
            let firstSeenSessionId = issue.historyEvents.sorted { $0.timestamp < $1.timestamp }.first?.sessionId?.uuidString ?? ""
            return [
                issue.issueID.uuidString,
                metadata.propertyID.uuidString,
                firstSeenSessionId,
                issue.lastCaptureSessionId?.uuidString ?? "",
                issue.issueStatus,
                issue.currentReason ?? "",
                issue.previousReason ?? "",
                iso8601String(issue.firstSeenAt),
                iso8601String(issue.lastSeenAt),
                iso8601String(issue.resolvedAt),
                issue.shotKey ?? ""
            ]
        }

        return csvString(headers: headers, rows: rows)
    }

    private func buildIssueHistoryCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "event_id",
            "issue_id",
            "session_id",
            "event_type",
            "timestamp_utc",
            "field_changed",
            "old_value",
            "new_value",
            "shot_id"
        ]

        let rows = metadata.issues.flatMap { issue in
            issue.historyEvents.sorted { $0.timestamp < $1.timestamp }.map { event in
                let fieldChanged = event.details["field"] ?? ""
                let oldValue = event.details["oldValue"] ?? event.details["oldReason"] ?? ""
                let newValue = event.details["newValue"] ?? event.details["newReason"] ?? ""
                let shotId = event.details["shotId"] ?? event.details["shotID"] ?? ""
                return [
                    event.id.uuidString,
                    issue.issueID.uuidString,
                    event.sessionId?.uuidString ?? "",
                    event.type,
                    iso8601String(event.timestamp),
                    fieldChanged,
                    oldValue,
                    newValue,
                    shotId
                ]
            }
        }

        return csvString(headers: headers, rows: rows)
    }

    private func buildGuidedRowsCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "guided_row_id",
            "session_id",
            "property_id",
            "building",
            "elevation",
            "detail_type",
            "angle_index",
            "status",
            "is_retired",
            "retired_at",
            "skip_reason",
            "skip_session_id"
        ]

        let rows = metadata.guidedShots.map { row in
            [
                row.id.uuidString,
                metadata.sessionID.uuidString,
                metadata.propertyID.uuidString,
                row.building ?? "",
                row.targetElevation ?? "",
                row.detailType ?? "",
                intString(row.angleIndex.map { max(1, $0) }),
                row.status.rawValue,
                boolString(row.isRetired),
                iso8601String(row.retiredAt),
                row.skipReason?.rawValue ?? "",
                row.skipSessionID?.uuidString ?? ""
            ]
        }

        return csvString(headers: headers, rows: rows)
    }

    private func normalizedCaptureKind(for shot: ShotMetadata) -> String {
        if let captureKind = SessionMetadata.trimmedNonEmpty(shot.captureKind) {
            return captureKind
        }
        if shot.isFlagged, let firstCaptureKind = SessionMetadata.trimmedNonEmpty(shot.firstCaptureKind) {
            return firstCaptureKind
        }
        return "captured"
    }

    private func csvString(headers: [String], rows: [[String]]) -> String {
        ([headers] + rows)
            .map { $0.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") || escaped.contains("\r") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private func iso8601String(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func intString(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private func decimalString(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    func performFileIOSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: fileIOQueueKey) == fileIOQueueValue {
            return try work()
        }
        return try fileIOQueue.sync {
            try work()
        }
    }

    // MARK: - Properties CRUD

    func fetchProperties() throws -> [Property] {
        try readProperties()
    }

    @discardableResult
    func createProperty(_ property: Property) throws -> Property {
        var properties = try readProperties()
        properties.append(property)
        try writeProperties(properties)
        return property
    }

    @discardableResult
    func updateProperty(_ property: Property) throws -> Property {
        var properties = try readProperties()
        guard let index = properties.firstIndex(where: { $0.id == property.id }) else {
            throw StoreError.propertyNotFound(property.id)
        }

        var updated = property
        updated.updatedAt = Date()
        properties[index] = updated
        try writeProperties(properties)
        return updated
    }

    func deleteProperty(id: UUID) throws {
        try performFileIOSync {
            let guided = try readGuidedShots(propertyID: id)
            let observations = try readObservations(propertyID: id)
            try cleanupReferenceFilesForGuidedShots(guided)
            let observationGuidedRefs = observations.flatMap { $0.guidedShots.compactMap(\.referenceImagePath) }
            try cleanupReferenceFiles(paths: observationGuidedRefs)

            var properties = try readProperties()
            properties.removeAll { $0.id == id }
            try writeProperties(properties)

            let propertyObservationURL = observationsFileURL(for: id)
            if fileManager.fileExists(atPath: propertyObservationURL.path) {
                try fileManager.removeItem(at: propertyObservationURL)
            }

            let propertyGuidedShotsURL = guidedShotsFileURL(for: id)
            if fileManager.fileExists(atPath: propertyGuidedShotsURL.path) {
                try fileManager.removeItem(at: propertyGuidedShotsURL)
            }

            let propertySessionsURL = sessionsFileURL(for: id)
            if fileManager.fileExists(atPath: propertySessionsURL.path) {
                try fileManager.removeItem(at: propertySessionsURL)
            }

            let propertyFolder = propertyFolderURL(propertyID: id)
            if fileManager.fileExists(atPath: propertyFolder.path) {
                try? fileManager.removeItem(at: propertyFolder)
            }
        }
    }

    // MARK: - Observations CRUD (per-property)

    func fetchObservations(propertyID: UUID) throws -> [Observation] {
        try ensurePropertyExists(propertyID)
        let observations = try readObservations(propertyID: propertyID)
        if try hasLegacyElevationValues(in: observationsFileURL(for: propertyID)) {
            try writeObservations(observations, propertyID: propertyID)
        }
        return observations
    }

    @discardableResult
    func createObservation(_ observation: Observation) throws -> Observation {
        try ensurePropertyExists(observation.propertyID)
        var observations = try readObservations(propertyID: observation.propertyID)
        observations.append(observation)
        try writeObservations(observations, propertyID: observation.propertyID)
        return observation
    }

    @discardableResult
    func updateObservation(_ observation: Observation) throws -> Observation {
        try ensurePropertyExists(observation.propertyID)
        var observations = try readObservations(propertyID: observation.propertyID)
        guard let index = observations.firstIndex(where: { $0.id == observation.id }) else {
            throw StoreError.observationNotFound(observation.id)
        }

        var updated = observation
        updated.updatedAt = Date()
        observations[index] = updated
        try writeObservations(observations, propertyID: observation.propertyID)
        return updated
    }

    func deleteObservation(id: UUID, propertyID: UUID) throws {
        try ensurePropertyExists(propertyID)
        var observations = try readObservations(propertyID: propertyID)
        observations.removeAll { $0.id == id }
        try writeObservations(observations, propertyID: propertyID)
    }

    // MARK: - Guided Shots CRUD (per-property)

    func fetchGuidedShots(propertyID: UUID) throws -> [GuidedShot] {
        try ensurePropertyExists(propertyID)
        let guidedShots = try readGuidedShots(propertyID: propertyID)
        if try hasLegacyElevationValues(in: guidedShotsFileURL(for: propertyID)) {
            try writeGuidedShots(guidedShots, propertyID: propertyID)
        }
        return guidedShots
    }

    func saveGuidedShots(_ guidedShots: [GuidedShot], propertyID: UUID) throws {
        try ensurePropertyExists(propertyID)
        try writeGuidedShots(guidedShots, propertyID: propertyID)
    }
    
    // MARK: - Sessions CRUD (per-property)
    
    func fetchSessions(propertyID: UUID) throws -> [Session] {
        try ensurePropertyExists(propertyID)
        return try readSessions(propertyID: propertyID)
    }
    
    @discardableResult
    func upsertSession(_ session: Session) throws -> Session {
        try ensurePropertyExists(session.propertyID)
        var sessions = try readSessions(propertyID: session.propertyID)
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sessions.sort { $0.startedAt < $1.startedAt }
        try writeSessions(sessions, propertyID: session.propertyID)
        try upsertSessionMetadataLifecycle(for: session)
        return session
    }

    func ensureSessionMetadata(for session: Session) throws {
        try upsertSessionMetadataLifecycle(for: session)
    }

    func upsertShotMetadata(_ shot: ShotMetadata) throws {
        try upsertShot(
            propertyID: shot.propertyID,
            sessionID: shot.sessionID,
            shot: shot,
            matchMode: .replaceGuidedKey
        )
    }

    func loadSessionMetadata(propertyID: UUID, sessionID: UUID) throws -> SessionMetadata {
        try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
    }

    func saveSessionMetadataAtomically(propertyID: UUID, sessionID: UUID, metadata: SessionMetadata) throws {
        var updated = metadata
        updated.schemaVersion = max(updated.schemaVersion, currentSessionSchemaVersion)
        updated.propertyID = propertyID
        updated.sessionID = sessionID
        updated.appVersion = appVersionString()
        updated.deviceModel = deviceModelString()
        updated.osVersion = osVersionString()
        updated = normalizeSessionMetadata(updated, propertyID: propertyID, sessionID: sessionID)
        try writeSessionMetadata(updated)
    }

    func syncGuidedShotsToSessionMetadata(
        propertyID: UUID,
        sessionID: UUID,
        guidedShots: [GuidedShot]
    ) throws {
        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        metadata.guidedShots = guidedShots
        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
    }

    func upsertShot(
        propertyID: UUID,
        sessionID: UUID,
        shot: ShotMetadata,
        matchMode: ShotUpsertMatchMode
    ) throws {
        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
        metadata.propertyID = propertyID
        metadata.sessionID = sessionID

        if let index = metadata.shots.firstIndex(where: { $0.shotID == shot.shotID }) {
            let existing = metadata.shots[index]
            var replacement = shot
            replacement = ShotMetadata(
                shotID: existing.shotID,
                propertyID: shot.propertyID,
                sessionID: shot.sessionID,
                createdAt: existing.createdAt,
                capturedAtLocal: existing.capturedAtLocal ?? shot.capturedAtLocal,
                updatedAt: shot.updatedAt,
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex,
                shotKey: shot.shotKey,
                isGuided: shot.isGuided,
                isFlagged: shot.isFlagged,
                issueID: shot.issueID,
                issueStatus: shot.issueStatus,
                captureKind: shot.captureKind,
                firstCaptureKind: existing.firstCaptureKind ?? shot.firstCaptureKind,
                noteText: shot.noteText,
                noteCategory: shot.noteCategory,
                originalFilename: shot.originalFilename,
                originalRelativePath: shot.originalRelativePath,
                originalByteSize: shot.originalByteSize,
                stampedFilename: shot.stampedFilename,
                stampedRelativePath: shot.stampedRelativePath,
                captureMode: shot.captureMode,
                lens: shot.lens,
                exifOrientation: shot.exifOrientation,
                orientation: shot.orientation,
                latitude: shot.latitude,
                longitude: shot.longitude,
                accuracyMeters: shot.accuracyMeters,
                imageWidth: shot.imageWidth,
                imageHeight: shot.imageHeight
            )
            metadata.shots[index] = replacement
        } else if matchMode == .replaceGuidedKey,
                  shot.isGuided,
                  let index = metadata.shots.firstIndex(where: {
                      $0.isGuided &&
                      $0.propertyID == shot.propertyID &&
                      $0.sessionID == shot.sessionID &&
                      (
                        $0.shotKey.caseInsensitiveCompare(shot.shotKey) == .orderedSame ||
                        (
                            $0.building.caseInsensitiveCompare(shot.building) == .orderedSame &&
                            CanonicalElevation.normalize($0.elevation) == CanonicalElevation.normalize(shot.elevation) &&
                            $0.detailType.caseInsensitiveCompare(shot.detailType) == .orderedSame &&
                            $0.angleIndex == shot.angleIndex
                        )
                      )
                  }) {
            let existing = metadata.shots[index]
            let replacement = ShotMetadata(
                shotID: existing.shotID,
                propertyID: shot.propertyID,
                sessionID: shot.sessionID,
                createdAt: existing.createdAt,
                capturedAtLocal: existing.capturedAtLocal ?? shot.capturedAtLocal,
                updatedAt: shot.updatedAt,
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex,
                shotKey: shot.shotKey,
                isGuided: shot.isGuided,
                isFlagged: shot.isFlagged,
                issueID: shot.issueID,
                issueStatus: shot.issueStatus,
                captureKind: shot.captureKind,
                firstCaptureKind: existing.firstCaptureKind ?? shot.firstCaptureKind,
                noteText: shot.noteText,
                noteCategory: shot.noteCategory,
                originalFilename: shot.originalFilename,
                originalRelativePath: shot.originalRelativePath,
                originalByteSize: shot.originalByteSize,
                stampedFilename: shot.stampedFilename,
                stampedRelativePath: shot.stampedRelativePath,
                captureMode: shot.captureMode,
                lens: shot.lens,
                exifOrientation: shot.exifOrientation,
                orientation: shot.orientation,
                latitude: shot.latitude,
                longitude: shot.longitude,
                accuracyMeters: shot.accuracyMeters,
                imageWidth: shot.imageWidth,
                imageHeight: shot.imageHeight
            )
            metadata.shots[index] = replacement
        } else {
            if matchMode == .replaceGuidedKey {
                print("Retake upsert fallback append: guided key match not found for session \(sessionID)")
            }
            metadata.shots.append(shot)
        }

        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
    }

    func removeShotMetadata(
        propertyID: UUID,
        sessionID: UUID,
        originalFileIdentifiers: [String]
    ) throws {
        try performFileIOSync {
            guard !originalFileIdentifiers.isEmpty else { return }
            var metadata = try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            let targets = Set(originalFileIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !targets.isEmpty else { return }
            metadata.shots.removeAll { shot in
                let original = shot.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
                let stem = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
                return targets.contains(original)
                    || targets.contains(stem)
                    || targets.contains("/\(stem).jpg")
                    || targets.contains("/\(stem).heic")
            }
            try writeSessionMetadata(metadata)
        }
    }

    func fetchShotMetadata(propertyID: UUID, sessionID: UUID) throws -> [ShotMetadata] {
        let metadata = try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        return metadata.shots
    }
    
    func latestDraftSession(propertyID: UUID) throws -> Session? {
        let sessions = try fetchSessions(propertyID: propertyID)
        return sessions
            .filter { $0.status == .draft }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func deleteSession(id: UUID, propertyID: UUID) throws {
        try performFileIOSync {
            try ensurePropertyExists(propertyID)
            var sessions = try readSessions(propertyID: propertyID)
            sessions.removeAll { $0.id == id }
            try writeSessions(sessions, propertyID: propertyID)
            let metadataFolder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: id)
            if fileManager.fileExists(atPath: metadataFolder.path) {
                try? fileManager.removeItem(at: metadataFolder)
            }
        }
    }

    func deleteSessionCascade(id: UUID, propertyID: UUID) throws {
        try performFileIOSync {
            try ensurePropertyExists(propertyID)
            let sessions = try readSessions(propertyID: propertyID)
            guard let target = sessions.first(where: { $0.id == id }) else {
                throw StoreError.sessionNotFound(id)
            }

            let start = target.startedAt
            let end = target.endedAt ?? Date.distantFuture

            var observations = try readObservations(propertyID: propertyID)
            let sessionMatched = observations.filter { $0.sessionID == target.id }
            let timeMatched = observations.filter { $0.sessionID == nil && $0.createdAt >= start && $0.createdAt <= end }
            let matchedObservationIDs = Set((sessionMatched + timeMatched).map(\.id))
            let matchedObservations = observations.filter { matchedObservationIDs.contains($0.id) }
            let matchedShotIDs = Set(matchedObservations.flatMap { obs in
                var ids = obs.shots.map(\.id)
                if let linked = obs.linkedShotID {
                    ids.append(linked)
                }
                return ids
            })

            let observationGuidedRefs = matchedObservations.flatMap { $0.guidedShots.compactMap(\.referenceImagePath) }
            try cleanupReferenceFiles(paths: observationGuidedRefs)
            observations.removeAll { matchedObservationIDs.contains($0.id) }
            try writeObservations(observations, propertyID: propertyID)

            var guided = try readGuidedShots(propertyID: propertyID)
            let guidedToDelete = guided.filter { shot in
                if let shotID = shot.shot?.id, matchedShotIDs.contains(shotID) {
                    return true
                }
                if let capturedAt = shot.shot?.capturedAt, capturedAt >= start && capturedAt <= end {
                    return true
                }
                return false
            }
            try cleanupReferenceFilesForGuidedShots(guidedToDelete)
            guided.removeAll { item in guidedToDelete.contains(where: { $0.id == item.id }) }
            try writeGuidedShots(guided, propertyID: propertyID)

            var updatedSessions = sessions
            updatedSessions.removeAll { $0.id == id }
            try writeSessions(updatedSessions, propertyID: propertyID)
            let metadataFolder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: id)
            if fileManager.fileExists(atPath: metadataFolder.path) {
                try? fileManager.removeItem(at: metadataFolder)
            }
        }
    }

    func ensureSessionFolders(propertyID: UUID, sessionID: UUID) throws {
        let propertyFolder = propertyFolderURL(propertyID: propertyID)
        if !fileManager.fileExists(atPath: propertyFolder.path) {
            try fileManager.createDirectory(at: propertyFolder, withIntermediateDirectories: true)
        }

        let sessionsFolder = sessionsFolderURL(propertyID: propertyID)
        if !fileManager.fileExists(atPath: sessionsFolder.path) {
            try fileManager.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        }

        let sessionFolder = sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: sessionFolder.path) {
            try fileManager.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        }

        let originals = originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: originals.path) {
            try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
        }

        let stamped = stampedFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: stamped.path) {
            try fileManager.createDirectory(at: stamped, withIntermediateDirectories: true)
        }
    }

    func ensureSessionFileStorage(propertyID: UUID, sessionID: UUID) throws {
        try ensureSessionFolders(propertyID: propertyID, sessionID: sessionID)
    }

    func rootURL() -> URL {
        scoutRootURL
    }

    func storageRootURL() -> URL {
        activeRootURL
    }

    func propertyFolderURL(propertyID: UUID) -> URL {
        propertyFoldersURL.appendingPathComponent(propertyID.uuidString, isDirectory: true)
    }

    func sessionsFolderURL(propertyID: UUID) -> URL {
        propertyFolderURL(propertyID: propertyID)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    func sessionFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionsFolderURL(propertyID: propertyID)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func originalsFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("Originals", isDirectory: true)
    }

    func stampedFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("Stamped", isDirectory: true)
    }

    func sessionJSONURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("session.json")
    }

    // Backward-compatible wrappers used by existing call sites.
    func originalsDirectoryURL(propertyID: UUID, sessionID: UUID) -> URL {
        originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    func stampedDirectoryURL(propertyID: UUID, sessionID: UUID) -> URL {
        stampedFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    func wipeAllLocalData() throws {
        try performFileIOSync {
            if fileManager.fileExists(atPath: scoutRootURL.path) {
                try fileManager.removeItem(at: scoutRootURL)
            }
            try createStorageDirectories(baseDirectoryURL: scoutRootURL)
        }
    }

    // MARK: - Private Helpers

    private func createStorageDirectories(baseDirectoryURL: URL) throws {
        if !fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: observationsDirectoryURL.path) {
            try fileManager.createDirectory(at: observationsDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: guidedShotsDirectoryURL.path) {
            try fileManager.createDirectory(at: guidedShotsDirectoryURL, withIntermediateDirectories: true)
        }
        
        if !fileManager.fileExists(atPath: sessionsDirectoryURL.path) {
            try fileManager.createDirectory(at: sessionsDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: propertyFoldersURL.path) {
            try fileManager.createDirectory(at: propertyFoldersURL, withIntermediateDirectories: true)
        }
    }

    private func ensurePropertyExists(_ propertyID: UUID) throws {
        let properties = try readProperties()
        guard properties.contains(where: { $0.id == propertyID }) else {
            throw StoreError.propertyNotFound(propertyID)
        }
    }

    private func readProperties() throws -> [Property] {
        guard fileManager.fileExists(atPath: propertiesURL.path) else {
            return []
        }

        let data = try Data(contentsOf: propertiesURL)
        return try decoder.decode([Property].self, from: data)
    }

    private func writeProperties(_ properties: [Property]) throws {
        let data = try encoder.encode(properties)
        try data.write(to: propertiesURL, options: .atomic)
    }

    private func observationsFileURL(for propertyID: UUID) -> URL {
        observationsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }

    private func guidedShotsFileURL(for propertyID: UUID) -> URL {
        guidedShotsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }
    
    private func sessionsFileURL(for propertyID: UUID) -> URL {
        sessionsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }

    private func readObservations(propertyID: UUID) throws -> [Observation] {
        let fileURL = observationsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Observation].self, from: data)
    }

    private func writeObservations(_ observations: [Observation], propertyID: UUID) throws {
        let data = try encoder.encode(observations)
        let fileURL = observationsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }

    private func readGuidedShots(propertyID: UUID) throws -> [GuidedShot] {
        let fileURL = guidedShotsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([GuidedShot].self, from: data)
    }

    private func writeGuidedShots(_ guidedShots: [GuidedShot], propertyID: UUID) throws {
        let data = try encoder.encode(guidedShots)
        let fileURL = guidedShotsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }
    
    private func readSessions(propertyID: UUID) throws -> [Session] {
        let fileURL = sessionsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Session].self, from: data)
    }
    
    private func writeSessions(_ sessions: [Session], propertyID: UUID) throws {
        let data = try encoder.encode(sessions)
        let fileURL = sessionsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }

    private func cleanupReferenceFilesForGuidedShots(_ guidedShots: [GuidedShot]) throws {
        let paths = guidedShots.compactMap(\.referenceImagePath)
        try cleanupReferenceFiles(paths: paths)
    }

    private func cleanupReferenceFiles(paths: [String]) throws {
        let unique = Set(paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        for path in unique {
            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    private func upsertSessionMetadataLifecycle(for session: Session) throws {
        var metadata = try readOrRecoverSessionMetadata(propertyID: session.propertyID, sessionID: session.id)
        metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
        metadata.propertyID = session.propertyID
        metadata.sessionID = session.id
        let currentProperty = currentProperty(for: session.propertyID)
        let propertyName = currentProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (metadata.propertyNameAtCapture ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !propertyName.isEmpty {
            metadata.propertyNameAtCapture = propertyName
        }
        if session.exportedAt != nil, !propertyName.isEmpty {
            metadata.propertyNameAtExport = propertyName
        }
        if metadata.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyAddressAtCapture = normalizedPropertyAddress(currentProperty?.address)
        }
        if metadata.propertyPhoneAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyPhoneAtCapture = normalizedPropertyPhone(currentProperty?.clientPhone)
        }
        let captureTimeZone = captureTimeZoneContext(for: session.startedAt)
        if metadata.timeZoneIdentifierAtCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata.timeZoneIdentifierAtCapture = captureTimeZone.identifier
        }
        metadata.timeZoneOffsetAtCapture = captureTimeZone.offsetString
        metadata.timeZoneOffsetMinutesAtCapture = captureTimeZone.offsetMinutes
        metadata.startedAt = session.startedAt
        metadata.sessionStartedAtLocal = localISO8601String(for: session.startedAt, timeZone: captureTimeZone.timeZone)
        metadata.endedAt = session.endedAt
        metadata.sessionEndedAtLocal = session.endedAt.map { localISO8601String(for: $0, timeZone: captureTimeZone.timeZone) }
        metadata.status = session.status
        metadata.isBaselineSession = isBaselineSession(sessionID: session.id, propertyID: session.propertyID)
        metadata.exportedAt = session.exportedAt
        metadata.isSealed = session.isSealed
        metadata.firstDeliveredAt = session.firstDeliveredAt
        metadata.reExportExpiresAt = session.reExportExpiresAt
        metadata.appVersion = appVersionString()
        metadata.deviceModel = deviceModelString()
        metadata.osVersion = osVersionString()
        let normalized = normalizeSessionMetadata(metadata, propertyID: session.propertyID, sessionID: session.id)
        try writeSessionMetadata(normalized)
    }

    private func readOrRecoverSessionMetadata(propertyID: UUID, sessionID: UUID) throws -> SessionMetadata {
        let fileURL = sessionMetadataFileURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: fileURL.path) {
            let now = Date()
            let captureTimeZone = captureTimeZoneContext(for: now)
            let property = currentProperty(for: propertyID)
            return SessionMetadata(
                schemaVersion: currentSessionSchemaVersion,
                propertyID: propertyID,
                sessionID: sessionID,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                propertyAddressAtCapture: normalizedPropertyAddress(property?.address),
                propertyPhoneAtCapture: normalizedPropertyPhone(property?.clientPhone),
                timeZoneIdentifierAtCapture: captureTimeZone.identifier,
                timeZoneOffsetAtCapture: captureTimeZone.offsetString,
                timeZoneOffsetMinutesAtCapture: captureTimeZone.offsetMinutes,
                startedAt: now,
                sessionStartedAtLocal: localISO8601String(for: now, timeZone: captureTimeZone.timeZone),
                endedAt: nil,
                sessionEndedAtLocal: nil,
                status: .draft,
                isBaselineSession: false,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                osVersion: osVersionString(),
                shots: [],
                issues: [],
                guidedShots: []
            )
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var metadata = try decoder.decode(SessionMetadata.self, from: data)
            metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
            metadata.propertyID = propertyID
            metadata.sessionID = sessionID
            metadata.appVersion = metadata.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? appVersionString()
                : metadata.appVersion
            metadata.deviceModel = metadata.deviceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? deviceModelString()
                : metadata.deviceModel
            metadata.osVersion = metadata.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? osVersionString()
                : metadata.osVersion
            return normalizeSessionMetadata(metadata, propertyID: propertyID, sessionID: sessionID)
        } catch {
            print("Recoverable session metadata decode failure for session \(sessionID): \(error)")
            let now = Date()
            let captureTimeZone = captureTimeZoneContext(for: now)
            let property = currentProperty(for: propertyID)
            return SessionMetadata(
                schemaVersion: currentSessionSchemaVersion,
                propertyID: propertyID,
                sessionID: sessionID,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                propertyAddressAtCapture: normalizedPropertyAddress(property?.address),
                propertyPhoneAtCapture: normalizedPropertyPhone(property?.clientPhone),
                timeZoneIdentifierAtCapture: captureTimeZone.identifier,
                timeZoneOffsetAtCapture: captureTimeZone.offsetString,
                timeZoneOffsetMinutesAtCapture: captureTimeZone.offsetMinutes,
                startedAt: now,
                sessionStartedAtLocal: localISO8601String(for: now, timeZone: captureTimeZone.timeZone),
                endedAt: nil,
                sessionEndedAtLocal: nil,
                status: .draft,
                isBaselineSession: false,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                osVersion: osVersionString(),
                shots: [],
                issues: [],
                guidedShots: []
            )
        }
    }

    private func writeSessionMetadata(_ metadata: SessionMetadata) throws {
        let normalized = normalizeSessionMetadata(metadata, propertyID: metadata.propertyID, sessionID: metadata.sessionID)
        let propertyID = normalized.propertyID
        let sessionID = normalized.sessionID
        let folder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try ensureSessionFileStorage(propertyID: propertyID, sessionID: sessionID)
        let fileURL = sessionMetadataFileURL(propertyID: propertyID, sessionID: sessionID)
        let tempURL = folder.appendingPathComponent("session-\(UUID().uuidString).tmp")
        let data = try encoder.encode(normalized)
        try data.write(to: tempURL, options: .atomic)

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
            throw error
        }
        let hasAddressSnapshot = !(normalized.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasTimeZoneOffset = !normalized.timeZoneOffsetAtCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        print("[SessionJSON] schemaVersion=\(normalized.schemaVersion) sessionID=\(sessionID.uuidString) shotsCount=\(normalized.shots.count) issuesCount=\(normalized.issues.count) hasAddressSnapshot=\(hasAddressSnapshot) hasTimeZoneOffset=\(hasTimeZoneOffset)")
        if let firstShot = normalized.shots.first {
            print("[SessionJSONTime] startedAt=\(normalized.startedAt) sessionStartedAtLocal=\(normalized.sessionStartedAtLocal) timeZoneIdentifierAtCapture=\(normalized.timeZoneIdentifierAtCapture) timeZoneOffsetAtCapture=\(normalized.timeZoneOffsetAtCapture) firstShotCreatedAt=\(firstShot.createdAt) firstShotCapturedAtLocal=\(firstShot.capturedAtLocal ?? "nil") firstShotExifOrientation=\(firstShot.exifOrientation ?? 0)")
        } else {
            print("[SessionJSONTime] startedAt=\(normalized.startedAt) sessionStartedAtLocal=\(normalized.sessionStartedAtLocal) timeZoneIdentifierAtCapture=\(normalized.timeZoneIdentifierAtCapture) timeZoneOffsetAtCapture=\(normalized.timeZoneOffsetAtCapture) firstShotCreatedAt=nil firstShotCapturedAtLocal=nil firstShotExifOrientation=0")
        }
    }

    private func sessionMetadataFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    private func sessionMetadataFileURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
    }

    private func appVersionString() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where !s.isEmpty && !b.isEmpty:
            return "\(s) (\(b))"
        case let (s?, _):
            return s
        case let (_, b?):
            return b
        default:
            return "unknown"
        }
    }

    private func deviceModelString() -> String {
        UIDevice.current.model
    }

    private func osVersionString() -> String {
        UIDevice.current.systemVersion
    }

    private func isBaselineSession(sessionID: UUID, propertyID: UUID) -> Bool {
        let properties = (try? readProperties()) ?? []
        return properties.first(where: { $0.id == propertyID })?.baselineSessionID == sessionID
    }

    private func currentPropertyName(for propertyID: UUID) -> String {
        let value = currentProperty(for: propertyID)?.name ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentProperty(for propertyID: UUID) -> Property? {
        let properties = (try? readProperties()) ?? []
        return properties.first(where: { $0.id == propertyID })
    }

    private func normalizeSessionMetadata(_ metadata: SessionMetadata, propertyID: UUID, sessionID: UUID) -> SessionMetadata {
        let property = currentProperty(for: propertyID)
        let propertyName = property?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let captureTimeZone = captureTimeZoneContext(
            identifier: metadata.timeZoneIdentifierAtCapture,
            offsetString: metadata.timeZoneOffsetAtCapture,
            offsetMinutes: metadata.timeZoneOffsetMinutesAtCapture,
            for: metadata.startedAt
        )
        let resolvedAddress = (metadata.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? normalizedPropertyAddress(property?.address)
            : metadata.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPhone = normalizedPropertyPhone(
            metadata.propertyPhoneAtCapture ?? property?.clientPhone
        )

        let normalizedShots = metadata.shots
            .map { normalizeShotMetadata($0, propertyID: propertyID, sessionID: sessionID, captureTimeZone: captureTimeZone) }
            .sorted { $0.createdAt < $1.createdAt }
        let normalizedIssues = metadata.issues
            .map { normalizeIssueMetadata($0, captureTimeZone: captureTimeZone) }
        let observations = (try? fetchObservations(propertyID: propertyID)) ?? []
        let mergedIssues = mergeIssuesWithCanonicalObservations(
            existingIssues: normalizedIssues,
            observations: observations,
            sessionID: sessionID,
            shots: normalizedShots,
            captureTimeZone: captureTimeZone
        )

        return SessionMetadata(
            schemaVersion: max(metadata.schemaVersion, currentSessionSchemaVersion),
            propertyID: propertyID,
            sessionID: sessionID,
            propertyNameAtCapture: trimmedNonEmpty(metadata.propertyNameAtCapture) ?? (propertyName.isEmpty ? nil : propertyName),
            propertyNameAtExport: trimmedNonEmpty(metadata.propertyNameAtExport),
            propertyAddressAtCapture: resolvedAddress,
            propertyPhoneAtCapture: resolvedPhone,
            timeZoneIdentifierAtCapture: captureTimeZone.identifier,
            timeZoneOffsetAtCapture: captureTimeZone.offsetString,
            timeZoneOffsetMinutesAtCapture: captureTimeZone.offsetMinutes,
            startedAt: metadata.startedAt,
            sessionStartedAtLocal: localISO8601String(for: metadata.startedAt, timeZone: captureTimeZone.timeZone),
            endedAt: metadata.endedAt,
            sessionEndedAtLocal: metadata.endedAt.map { end in
                localISO8601String(for: end, timeZone: captureTimeZone.timeZone)
            },
            status: metadata.status,
            isBaselineSession: metadata.isBaselineSession,
            exportedAt: metadata.exportedAt,
            isSealed: metadata.isSealed,
            firstDeliveredAt: metadata.firstDeliveredAt,
            reExportExpiresAt: metadata.reExportExpiresAt,
            appVersion: metadata.appVersion,
            deviceModel: metadata.deviceModel,
            osVersion: metadata.osVersion,
            shots: normalizedShots,
            issues: mergedIssues,
            guidedShots: metadata.guidedShots
        )
    }

    private func normalizeShotMetadata(
        _ shot: ShotMetadata,
        propertyID: UUID,
        sessionID: UUID,
        captureTimeZone: CaptureTimeZoneContext
    ) -> ShotMetadata {
        let fileName = URL(fileURLWithPath: shot.originalFilename).lastPathComponent
        let normalizedFilename = fileName.isEmpty ? shot.originalFilename : fileName
        let normalizedRelativePath = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Originals/\(normalizedFilename)"
            : shot.originalRelativePath
        let normalizedShotKey = shot.shotKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ShotMetadata.makeShotKey(
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex
            )
            : shot.shotKey
        let normalizedStampedFilename = shot.stampedFilename.map { URL(fileURLWithPath: $0).lastPathComponent }
        let normalizedStampedPath: String?
        if let stamped = shot.stampedRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines), !stamped.isEmpty {
            normalizedStampedPath = stamped
        } else if let stampedName = normalizedStampedFilename, !stampedName.isEmpty {
            normalizedStampedPath = "Stamped/\(stampedName)"
        } else {
            normalizedStampedPath = nil
        }
        return ShotMetadata(
            shotID: shot.shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: shot.createdAt,
            capturedAtLocal: localISO8601String(for: shot.createdAt, timeZone: captureTimeZone.timeZone),
            updatedAt: shot.updatedAt,
            building: shot.building,
            elevation: CanonicalElevation.normalize(shot.elevation) ?? shot.elevation,
            detailType: shot.detailType,
            angleIndex: max(1, shot.angleIndex),
            shotKey: normalizedShotKey,
            isGuided: shot.isGuided,
            isFlagged: shot.isFlagged,
            issueID: shot.issueID,
            issueStatus: shot.issueStatus,
            captureKind: shot.captureKind,
            firstCaptureKind: normalizedFirstCaptureKind(
                shot.firstCaptureKind,
                captureKind: shot.captureKind,
                isFlagged: shot.isFlagged
            ),
            noteText: shot.noteText,
            noteCategory: shot.noteCategory,
            originalFilename: normalizedFilename,
            originalRelativePath: normalizedRelativePath,
            originalByteSize: shot.originalByteSize,
            stampedFilename: normalizedStampedFilename,
            stampedRelativePath: normalizedStampedPath,
            captureMode: shot.captureMode,
            lens: shot.lens,
            exifOrientation: normalizeExifOrientation(rawValue: shot.exifOrientation, legacy: shot.orientation),
            orientation: shot.orientation,
            latitude: shot.latitude,
            longitude: shot.longitude,
            accuracyMeters: shot.accuracyMeters,
            imageWidth: shot.imageWidth,
            imageHeight: shot.imageHeight
        )
    }

    private func normalizeIssueMetadata(_ issue: IssueMetadata, captureTimeZone: CaptureTimeZoneContext) -> IssueMetadata {
        let firstSeenAt = issue.firstSeenAt
        let lastSeenAt = issue.lastSeenAt ?? issue.firstSeenAt
        let resolvedAt = issue.resolvedAt
        let previousReason = normalizedPreviousReason(
            issue.previousReason,
            from: issue.historyEvents
        )
        return IssueMetadata(
            issueID: issue.issueID,
            issueStatus: issue.issueStatus,
            currentReason: trimmedNonEmpty(issue.currentReason),
            previousReason: previousReason,
            firstSeenAt: firstSeenAt,
            firstSeenAtLocal: firstSeenAt.map {
                localISO8601String(for: $0, timeZone: captureTimeZone.timeZone)
            } ?? trimmedNonEmpty(issue.firstSeenAtLocal),
            lastSeenAt: lastSeenAt,
            lastSeenAtLocal: lastSeenAt.map {
                localISO8601String(for: $0, timeZone: captureTimeZone.timeZone)
            } ?? trimmedNonEmpty(issue.lastSeenAtLocal),
            resolvedAt: resolvedAt,
            resolvedAtLocal: resolvedAt.map {
                localISO8601String(for: $0, timeZone: captureTimeZone.timeZone)
            } ?? trimmedNonEmpty(issue.resolvedAtLocal),
            lastCaptureSessionId: issue.lastCaptureSessionId,
            detailNote: trimmedNonEmpty(issue.detailNote),
            shotKey: trimmedNonEmpty(issue.shotKey),
            historyEvents: issue.historyEvents
        )
    }

    private func normalizedFirstCaptureKind(_ value: String?, captureKind: String?, isFlagged: Bool) -> String? {
        let normalizedValue = trimmedNonEmpty(value)
        guard isFlagged else { return normalizedValue }
        let normalizedCaptureKind = trimmedNonEmpty(captureKind)
        if normalizedCaptureKind == "retake" || normalizedCaptureKind == "captured" {
            return normalizedValue ?? "captured"
        }
        if normalizedValue == nil {
            return normalizedValue ?? "captured"
        }
        return normalizedValue
    }

    private func mergeIssuesWithCanonicalObservations(
        existingIssues: [IssueMetadata],
        observations: [Observation],
        sessionID: UUID,
        shots: [ShotMetadata],
        captureTimeZone: CaptureTimeZoneContext
    ) -> [IssueMetadata] {
        var byID: [UUID: IssueMetadata] = [:]
        for existing in existingIssues {
            byID[existing.issueID] = existing
        }

        let relevantShotIDs = Set(shots.compactMap(\.issueID))
        let relevantObservations = observations.filter { observation in
            relevantShotIDs.contains(observation.id) ||
            observation.sessionID == sessionID ||
            observation.updatedInSessionID == sessionID ||
            observation.resolvedInSessionID == sessionID
        }

        for observation in relevantObservations {
            let linkedShotKey = shots
                .filter { $0.issueID == observation.id }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first?.shotKey
                ?? byID[observation.id]?.shotKey

            let lastCaptureSessionId = observation.resolvedInSessionID ?? observation.updatedInSessionID
            let exportedHistoryEvents = observation.historyEvents.map { exportHistoryEvent($0, observation: observation) }
            let issue = IssueMetadata(
                issueID: observation.id,
                issueStatus: observation.status == .resolved ? "resolved" : "active",
                currentReason: Observation.inferredCurrentReason(
                    note: observation.currentReason ?? observation.note,
                    statement: observation.statement
                ),
                previousReason: normalizedPreviousReason(
                    Observation.trimmedNonEmpty(observation.previousReason),
                    from: exportedHistoryEvents
                ) ?? latestPreviousReason(in: observation.historyEvents),
                firstSeenAt: observation.createdAt,
                firstSeenAtLocal: nil,
                lastSeenAt: observation.updatedAt,
                lastSeenAtLocal: nil,
                resolvedAt: observation.status == .resolved ? observation.updatedAt : nil,
                resolvedAtLocal: nil,
                lastCaptureSessionId: lastCaptureSessionId,
                detailNote: Observation.inferredCurrentReason(
                    note: observation.currentReason ?? observation.note,
                    statement: observation.statement
                ),
                shotKey: trimmedNonEmpty(linkedShotKey),
                historyEvents: exportedHistoryEvents
            )
            byID[observation.id] = issue
        }

        return byID.values
            .map { normalizeIssueMetadata($0, captureTimeZone: captureTimeZone) }
        .sorted(by: issueSortAscending)
    }

    private func exportHistoryEvent(_ event: ObservationHistoryEvent, observation: Observation) -> IssueHistoryEvent {
        var type: String
        switch event.kind {
        case .created:
            type = "created"
        case .captured:
            type = "captured"
        case .retake:
            type = "retake"
        case .reclassified:
            type = "reclassify"
        case .resolved:
            type = "resolve"
        case .reopened:
            type = "reopened"
        case .reasonUpdated:
            type = "reason_updated"
        case .titleUpdated:
            type = "title_updated"
        }

        var details: [String: String] = [:]
        if let field = trimmedNonEmpty(event.field) {
            details["field"] = field
        }
        if let before = trimmedNonEmpty(event.beforeValue) {
            details[event.kind == .reasonUpdated ? "oldReason" : "beforeValue"] = before
        }
        if let after = trimmedNonEmpty(event.afterValue) {
            details[event.kind == .reasonUpdated ? "newReason" : "afterValue"] = after
        }
        if let shotID = event.shotID?.uuidString {
            details["shotId"] = shotID
        }

        return IssueHistoryEvent(
            timestamp: event.timestamp,
            sessionId: event.sessionID,
            type: type,
            details: details
        )
    }

    private func normalizedPreviousReason(_ value: String?, from historyEvents: [IssueHistoryEvent]) -> String? {
        trimmedNonEmpty(value) ?? latestPreviousReason(in: historyEvents)
    }

    private func latestPreviousReason(in historyEvents: [IssueHistoryEvent]) -> String? {
        let latest = historyEvents
            .filter { $0.type == "reason_updated" }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            .last
        return trimmedNonEmpty(latest?.details["oldReason"])
    }

    private func latestPreviousReason(in historyEvents: [ObservationHistoryEvent]) -> String? {
        let latest = historyEvents
            .filter { $0.kind == .reasonUpdated }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            .last
        return trimmedNonEmpty(latest?.beforeValue)
    }

    private func issueSortAscending(_ lhs: IssueMetadata, _ rhs: IssueMetadata) -> Bool {
        let lhsDate = lhs.firstSeenAt ?? lhs.lastSeenAt ?? lhs.resolvedAt ?? Date.distantPast
        let rhsDate = rhs.firstSeenAt ?? rhs.lastSeenAt ?? rhs.resolvedAt ?? Date.distantPast
        if lhsDate == rhsDate {
            return lhs.issueID.uuidString < rhs.issueID.uuidString
        }
        return lhsDate < rhsDate
    }

    private func normalizedPropertyAddress(_ value: String?) -> String? {
        trimmedNonEmpty(value)
    }

    private func normalizedPropertyPhone(_ value: String?) -> String? {
        trimmedNonEmpty(value)
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func timeZoneOffsetString(secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT >= 0 ? "+" : "-"
        let absolute = abs(secondsFromGMT)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private func timeZoneFromOffsetString(_ offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6 else { return nil }
        let chars = Array(trimmed)
        guard (chars[0] == "+" || chars[0] == "-"), chars[3] == ":" else { return nil }
        let hourString = String(chars[1...2])
        let minuteString = String(chars[4...5])
        guard let hours = Int(hourString), let minutes = Int(minuteString) else { return nil }
        let multiplier = chars[0] == "-" ? -1 : 1
        let seconds = multiplier * ((hours * 3600) + (minutes * 60))
        return TimeZone(secondsFromGMT: seconds)
    }

    private struct CaptureTimeZoneContext {
        let identifier: String
        let timeZone: TimeZone
        let offsetMinutes: Int
        let offsetString: String
    }

    private func captureTimeZoneContext(for date: Date) -> CaptureTimeZoneContext {
        let timeZone = TimeZone.current
        let seconds = timeZone.secondsFromGMT(for: date)
        return CaptureTimeZoneContext(
            identifier: timeZone.identifier,
            timeZone: timeZone,
            offsetMinutes: seconds / 60,
            offsetString: timeZoneOffsetString(secondsFromGMT: seconds)
        )
    }

    private func captureTimeZoneContext(identifier: String, offsetString: String, offsetMinutes: Int?, for date: Date) -> CaptureTimeZoneContext {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredTimeZone = TimeZone(identifier: trimmedIdentifier)
        let resolvedTimeZone: TimeZone
        let resolvedOffsetMinutes: Int

        if let offsetMinutes {
            resolvedOffsetMinutes = offsetMinutes
            resolvedTimeZone = preferredTimeZone ?? TimeZone(secondsFromGMT: offsetMinutes * 60) ?? TimeZone.current
        } else if let fromOffset = timeZoneFromOffsetString(offsetString) {
            let seconds = fromOffset.secondsFromGMT()
            resolvedOffsetMinutes = seconds / 60
            resolvedTimeZone = preferredTimeZone ?? fromOffset
        } else if let preferredTimeZone {
            let seconds = preferredTimeZone.secondsFromGMT(for: date)
            resolvedOffsetMinutes = seconds / 60
            resolvedTimeZone = preferredTimeZone
        } else {
            let fallback = captureTimeZoneContext(for: date)
            return fallback
        }

        return CaptureTimeZoneContext(
            identifier: trimmedIdentifier.isEmpty ? resolvedTimeZone.identifier : trimmedIdentifier,
            timeZone: resolvedTimeZone,
            offsetMinutes: resolvedOffsetMinutes,
            offsetString: timeZoneOffsetString(secondsFromGMT: resolvedOffsetMinutes * 60)
        )
    }

    private func localISO8601String(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        let rendered = formatter.string(from: date)
        if rendered.hasSuffix("Z") {
            return String(rendered.dropLast()) + "+00:00"
        }
        return rendered
    }

    private func normalizeExifOrientation(rawValue: Int?, legacy: String?) -> Int? {
        if let rawValue, (1...8).contains(rawValue) {
            return rawValue
        }
        let trimmed = legacy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    private func hasLegacyElevationValues(in fileURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.range(
            of: #""targetElevation"\s*:\s*"(North|South|East|West)\s+Elevation""#,
            options: .regularExpression
        ) != nil
    }
}

#if DEBUG
extension LocalStore {
    func printSessionSchema() {
        let sampleSession = SessionMetadata(
            schemaVersion: 5,
            propertyID: UUID(),
            sessionID: UUID(),
            propertyNameAtCapture: nil,
            propertyNameAtExport: nil,
            startedAt: Date(),
            endedAt: nil,
            status: .draft,
            isBaselineSession: false,
            exportedAt: nil,
            appVersion: "debug",
            deviceModel: "debug",
            osVersion: "debug",
            shots: [],
            issues: []
        )

        let sampleShot = ShotMetadata(
            shotID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            building: "",
            elevation: "",
            detailType: "",
            angleIndex: 1,
            shotKey: "",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "",
            originalRelativePath: "",
            originalByteSize: nil,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            orientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        print("---- SessionMetadata Fields ----")
        for child in Mirror(reflecting: sampleSession).children {
            if let label = child.label {
                print(label)
            }
        }

        print("")
        print("---- ShotMetadata Fields ----")
        for child in Mirror(reflecting: sampleShot).children {
            if let label = child.label {
                print(label)
            }
        }
    }
}
#endif
