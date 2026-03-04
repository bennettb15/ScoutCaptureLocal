import Foundation
import Combine

extension Notification.Name {
    static let scoutClearLocalUICache = Notification.Name("scout.clearLocalUICache")
    static let scoutVerifySessionJSONSource = Notification.Name("scout.verifySessionJSONSource")
    static let scoutVerifyExportSessionJSONSource = Notification.Name("scout.verifyExportSessionJSONSource")
}

final class AppState: ObservableObject {
    enum PropertyCreationError: LocalizedError {
        case missingPropertyName
        case missingOrganization
        case noAvailableFolderID
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .missingPropertyName:
                return "Enter a property name."
            case .missingOrganization:
                return "Select an organization."
            case .noAvailableFolderID:
                return "No folder IDs are available. Please contact support."
            case .persistenceFailed:
                return "The property could not be saved."
            }
        }
    }

    struct HubPropertyMeta {
        let clientLine: String?
        let addressLine: String?
        let normalizedNameToken: String
        let normalizedClientToken: String
        let normalizedAddressToken: String
    }

    struct PropertyDataCounts {
        let sessions: Int
        let guided: Int
        let observations: Int

        var isEmpty: Bool {
            sessions == 0 && guided == 0 && observations == 0
        }
    }

    @Published var properties: [Property] = []
    @Published var organizations: [Organization] = []
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var sessionIndexByProperty: [UUID: [Session]] = [:]
    @Published private(set) var draftSessionByProperty: [UUID: Session] = [:]
    @Published private(set) var pendingExportSessionByProperty: [UUID: Session] = [:]
    @Published private(set) var hubMetaByProperty: [UUID: HubPropertyMeta] = [:]

    @Published var selectedPropertyID: UUID? {
        didSet {
            persistSelectedPropertyID()
        }
    }

    @Published var currentSession: Session? {
        didSet {
            logActiveSession(currentSession)
        }
    }

    var selectedProperty: Property? {
        guard let selectedPropertyID else { return nil }
        return properties.first { $0.id == selectedPropertyID }
    }

    private let localStore: LocalStore
    private let userDefaults: UserDefaults
    private let selectedPropertyDefaultsKey = "scoutcapture.selectedPropertyID"
    private let reExportWindowDays = 7
    private var didLoad = false

    init(
        localStore: LocalStore = LocalStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.localStore = localStore
        self.userDefaults = userDefaults

        if let rawID = userDefaults.string(forKey: selectedPropertyDefaultsKey) {
            self.selectedPropertyID = UUID(uuidString: rawID)
        } else {
            self.selectedPropertyID = nil
        }

        self.currentSession = nil
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        refreshProperties()
    }

    func warmLaunchReadiness(completion: @escaping () -> Void) {
        guard !didLoad else {
            completion()
            return
        }
        didLoad = true
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedProperties = (try? self.localStore.fetchProperties()) ?? []
            let fetchedOrganizations = (try? self.localStore.fetchOrganizations()) ?? []
            let caches = self.makeHubCaches(for: fetchedProperties)
            DispatchQueue.main.async {
                self.organizations = fetchedOrganizations
                self.applyHubCachePayload(properties: fetchedProperties, caches: caches)
                self.isLoading = false
                completion()
            }
        }
    }

    func refreshProperties() {
        isLoading = true
        do {
            let fetched = try localStore.fetchProperties()
            organizations = (try? localStore.fetchOrganizations()) ?? []
            let caches = makeHubCaches(for: fetched)
            applyHubCachePayload(properties: fetched, caches: caches)

            if let selectedPropertyID, properties.contains(where: { $0.id == selectedPropertyID }) == false {
                self.selectedPropertyID = nil
            }
        } catch {
            properties = []
            organizations = []
            sessionIndexByProperty = [:]
            draftSessionByProperty = [:]
            pendingExportSessionByProperty = [:]
            hubMetaByProperty = [:]
        }
        isLoading = false
    }

    @discardableResult
    func createProperty(
        organizationID: UUID,
        clientName: String,
        propertyName: String,
        address: String,
        street: String = "",
        city: String = "",
        state: String = "",
        zip: String = "",
        clientPhone: String = ""
    ) throws -> Property {
        let cleanedClientName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedZip = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPhone = clientPhone.filter(\.isNumber)

        guard !cleanedName.isEmpty else { throw PropertyCreationError.missingPropertyName }
        guard organizations.contains(where: { $0.id == organizationID }) else { throw PropertyCreationError.missingOrganization }

        do {
            let property = Property(
                id: UUID(),
                orgId: organizationID,
                clientName: cleanedClientName.isEmpty ? nil : cleanedClientName,
                clientPhone: cleanedPhone.isEmpty ? nil : cleanedPhone,
                name: cleanedName,
                address: cleanedAddress.isEmpty ? nil : cleanedAddress,
                street: cleanedStreet.isEmpty ? nil : cleanedStreet,
                city: cleanedCity.isEmpty ? nil : cleanedCity,
                state: cleanedState.isEmpty ? nil : cleanedState,
                zip: cleanedZip.isEmpty ? nil : cleanedZip
            )
            let created = try localStore.createProperty(property)
            properties.append(created)
            let caches = makeHubCaches(for: properties)
            applyHubCachePayload(properties: properties, caches: caches)
            if selectedPropertyID == nil {
                selectedPropertyID = created.id
            }
            return created
        } catch {
            if case LocalStore.StoreError.noAvailableFolderID = error {
                throw PropertyCreationError.noAvailableFolderID
            }
            throw PropertyCreationError.persistenceFailed
        }
    }

    @discardableResult
    func createOrganization(name: String) -> Organization? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        do {
            let created = try localStore.createOrganization(Organization(name: trimmedName))
            organizations = (try? localStore.fetchOrganizations()) ?? organizations
            return created
        } catch {
            return organizations.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame })
        }
    }

    func selectProperty(id: UUID) {
        selectedPropertyID = id
    }

    func propertyHasBaseline(_ propertyID: UUID) -> Bool {
        properties.first(where: { $0.id == propertyID })?.baselineSessionID != nil
    }

    @discardableResult
    func setPropertyBaselineSession(propertyID: UUID, sessionID: UUID) -> Bool {
        guard let index = properties.firstIndex(where: { $0.id == propertyID }) else { return false }
        var updated = properties[index]
        updated.baselineSessionID = sessionID
        do {
            let persisted = try localStore.updateProperty(updated)
            properties[index] = persisted
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func setPropertyArchived(id: UUID, archived: Bool) -> Bool {
        guard let property = properties.first(where: { $0.id == id }) else { return false }
        var updated = property
        updated.isArchived = archived
        do {
            let persisted = try localStore.updateProperty(updated)
            if let idx = properties.firstIndex(where: { $0.id == id }) {
                properties[idx] = persisted
            }
            if archived, selectedPropertyID == id {
                clearCurrentSession()
                selectedPropertyID = nil
            }
            let caches = makeHubCaches(for: properties)
            applyHubCachePayload(properties: properties, caches: caches)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func updatePropertyContact(
        id: UUID,
        organizationID: UUID?,
        propertyName: String?,
        clientName: String?,
        address: String?,
        street: String?,
        city: String?,
        state: String?,
        zip: String?,
        clientPhone: String?
    ) -> Bool {
        guard let index = properties.firstIndex(where: { $0.id == id }) else { return false }
        var updated = properties[index]
        let cleanedName = propertyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedClient = clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedStreet = street?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedCity = city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedState = state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedZip = zip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digitsOnlyPhone = (clientPhone ?? "").filter(\.isNumber)

        if let organizationID, organizations.contains(where: { $0.id == organizationID }) {
            updated.orgId = organizationID
        }
        if !cleanedName.isEmpty {
            updated.name = cleanedName
        }
        updated.clientName = cleanedClient.isEmpty ? nil : cleanedClient
        updated.address = cleanedAddress.isEmpty ? nil : cleanedAddress
        updated.street = cleanedStreet.isEmpty ? nil : cleanedStreet
        updated.city = cleanedCity.isEmpty ? nil : cleanedCity
        updated.state = cleanedState.isEmpty ? nil : cleanedState
        updated.zip = cleanedZip.isEmpty ? nil : cleanedZip
        updated.clientPhone = digitsOnlyPhone.isEmpty ? nil : digitsOnlyPhone

        do {
            let persisted = try localStore.updateProperty(updated)
            properties[index] = persisted
            let caches = makeHubCaches(for: properties)
            applyHubCachePayload(properties: properties, caches: caches)
            return true
        } catch {
            return false
        }
    }

    func propertyDataCounts(for propertyID: UUID) -> PropertyDataCounts {
        let sessions = (try? localStore.fetchSessions(propertyID: propertyID).count) ?? 0
        let guided = (try? localStore.fetchGuidedShots(propertyID: propertyID).count) ?? 0
        let observations = (try? localStore.fetchObservations(propertyID: propertyID).count) ?? 0
        return PropertyDataCounts(sessions: sessions, guided: guided, observations: observations)
    }

    @discardableResult
    func deletePropertyIfEmpty(id: UUID) -> Bool {
        let counts = propertyDataCounts(for: id)
        guard counts.isEmpty else { return false }
        do {
            try localStore.deleteProperty(id: id)
            properties.removeAll { $0.id == id }
            let caches = makeHubCaches(for: properties)
            applyHubCachePayload(properties: properties, caches: caches)
            if selectedPropertyID == id {
                selectedPropertyID = nil
                clearCurrentSession()
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteProperty(id: UUID) -> Bool {
        do {
            try localStore.deleteProperty(id: id)
            properties.removeAll { $0.id == id }
            let caches = makeHubCaches(for: properties)
            applyHubCachePayload(properties: properties, caches: caches)
            if selectedPropertyID == id {
                selectedPropertyID = nil
                clearCurrentSession()
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func startSession() -> Session? {
        guard let selectedPropertyID else { return nil }
        let sessionsForProperty = sessions(for: selectedPropertyID)
        let pendingDeliveryExists = sessionsForProperty.contains(where: { isPendingDelivery($0) })
        let reExportEligibleExists = sessionsForProperty.contains(where: { isReExportEligible($0) })
        if let currentSession, currentSession.status == .draft, currentSession.propertyID == selectedPropertyID {
            print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
            logActiveSession(currentSession)
            try? localStore.ensureSessionMetadata(for: currentSession)
            return currentSession
        }
        
        if let draft = try? localStore.latestDraftSession(propertyID: selectedPropertyID) {
            currentSession = draft
            print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
            try? localStore.ensureSessionMetadata(for: draft)
            return draft
        }

        let session = Session(propertyID: selectedPropertyID, startedAt: Date(), status: .draft, endedAt: nil, exportedAt: nil)
        currentSession = session
        print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: selectedPropertyID)
        return session
    }

    func saveDraftCurrentSession() {
        guard var session = currentSession else { return }
        session.status = .draft
        session.endedAt = nil
        session.exportedAt = nil
        if session.firstDeliveredAt == nil {
            session.isSealed = false
        }
        currentSession = session
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
    }

    func completeCurrentSession(markExported: Bool) {
        guard var session = currentSession else { return }
        session.status = .completed
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        session.isSealed = true
        if markExported {
            let now = Date()
            applyDeliverySuccess(to: &session, deliveredAt: now)
        } else {
            if session.exportedAt != nil {
                session.exportedAt = nil
            }
        }
        currentSession = session
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
    }
    
    func clearCurrentSession() {
        currentSession = nil
    }
    
    func draftSession(for propertyID: UUID) -> Session? {
        if let cached = draftSessionByProperty[propertyID] {
            return cached
        }
        return try? localStore.latestDraftSession(propertyID: propertyID)
    }
    
    func sessions(for propertyID: UUID) -> [Session] {
        if let cached = sessionIndexByProperty[propertyID] {
            return cached
        }
        let fetched = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
        var uniqueByID: [UUID: Session] = [:]
        for session in fetched {
            uniqueByID[session.id] = session
        }
        return uniqueByID.values.sorted { $0.startedAt < $1.startedAt }
    }

    func latestPendingExportSession(for propertyID: UUID) -> Session? {
        if let cached = pendingExportSessionByProperty[propertyID] {
            return cached
        }
        return sessions(for: propertyID)
            .filter { isPendingDelivery($0) }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }
    
    func pendingExportCountAcrossProperties() -> Int {
        if !pendingExportSessionByProperty.isEmpty {
            return Set(pendingExportSessionByProperty.values.map(\.id)).count
        }
        var pendingSessionIDs = Set<UUID>()
        for property in properties {
            for session in sessions(for: property.id) where isPendingDelivery(session) {
                pendingSessionIDs.insert(session.id)
            }
        }
        return pendingSessionIDs.count
    }
    
    func draftPropertyCount() -> Int {
        if !draftSessionByProperty.isEmpty {
            return draftSessionByProperty.count
        }
        return properties.filter { draftSession(for: $0.id) != nil }.count
    }
    
    func markCurrentSessionExported() {
        guard var session = currentSession else { return }
        guard session.status == .completed else { return }
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        let now = Date()
        if session.firstDeliveredAt != nil, !isReExportEligible(session, now: now) {
            print("[ExportEligibility] sessionID=\(session.id.uuidString) enabled=false reason=Re export window expired")
            return
        }
        applyDeliverySuccess(to: &session, deliveredAt: now)
        currentSession = session
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
    }

    func sealCurrentSessionForExportLater() {
        guard var session = currentSession else { return }
        session.status = .completed
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        session.exportedAt = nil
        session.isSealed = true
        print("[ExportSeal] action=export_later sessionID=\(session.id.uuidString) isSealed=true firstDeliveredAt=nil reExportExpiresAt=nil")
        currentSession = session
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
    }

    func sealCurrentSessionForExportNow() {
        guard var session = currentSession else { return }
        session.status = .completed
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        session.isSealed = true
        print("[ExportSeal] action=export_now sessionID=\(session.id.uuidString) isSealed=true")
        currentSession = session
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
    }
    
    func loadDraftSession(for propertyID: UUID) -> Session? {
        guard let draft = draftSession(for: propertyID) else { return nil }
        selectedPropertyID = propertyID
        currentSession = draft
        try? localStore.ensureSessionMetadata(for: draft)
        return draft
    }

    @discardableResult
    func markSessionExported(propertyID: UUID, sessionID: UUID) -> Bool {
        let allSessions = sessions(for: propertyID)
        guard var session = allSessions.first(where: { $0.id == sessionID }) else { return false }
        guard session.status == .completed else { return false }
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        let now = Date()
        if session.firstDeliveredAt != nil, !isReExportEligible(session, now: now) {
            print("[ExportEligibility] sessionID=\(session.id.uuidString) enabled=false reason=Re export window expired")
            return false
        }
        applyDeliverySuccess(to: &session, deliveredAt: now)
        if currentSession?.id == sessionID {
            currentSession = session
        }
        do {
            _ = try localStore.upsertSession(session)
            reloadSessionCache(for: propertyID)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteSession(propertyID: UUID, sessionID: UUID) -> Bool {
        do {
            try localStore.deleteSessionCascade(id: sessionID, propertyID: propertyID)
            if currentSession?.id == sessionID {
                clearCurrentSession()
            }
            reloadSessionCache(for: propertyID)
            return true
        } catch {
            return false
        }
    }

    func resetLocalSessionUIIndex() {
        clearLocalCacheOnly()
    }

    func clearLocalCacheOnly() {
        NotificationCenter.default.post(name: .scoutClearLocalUICache, object: nil)
        refreshProperties()
    }

    func nuclearResetLocalOnly() {
        do {
            try localStore.wipeAllLocalData()
        } catch {
            // Keep UI stable even when cleanup fails.
        }
        clearAllUserDefaults()
        selectedPropertyID = nil
        clearCurrentSession()
        properties = []
        sessionIndexByProperty = [:]
        draftSessionByProperty = [:]
        pendingExportSessionByProperty = [:]
        hubMetaByProperty = [:]
        refreshProperties()
        NotificationCenter.default.post(name: .scoutClearLocalUICache, object: nil)
    }

    private func persistSelectedPropertyID() {
        if let selectedPropertyID {
            userDefaults.set(selectedPropertyID.uuidString, forKey: selectedPropertyDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: selectedPropertyDefaultsKey)
        }
    }

    private func clearAllUserDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            userDefaults.removePersistentDomain(forName: bundleID)
            userDefaults.synchronize()
        } else {
            userDefaults.removeObject(forKey: selectedPropertyDefaultsKey)
        }
    }

    func hubMeta(for propertyID: UUID) -> HubPropertyMeta? {
        hubMetaByProperty[propertyID]
    }

    private struct HubCachePayload {
        let sessionIndex: [UUID: [Session]]
        let drafts: [UUID: Session]
        let pending: [UUID: Session]
        let meta: [UUID: HubPropertyMeta]
    }

    private func applyHubCachePayload(properties: [Property], caches: HubCachePayload) {
        self.properties = properties
        self.sessionIndexByProperty = caches.sessionIndex
        self.draftSessionByProperty = caches.drafts
        self.pendingExportSessionByProperty = caches.pending
        self.hubMetaByProperty = caches.meta
    }

    private func makeHubCaches(for properties: [Property]) -> HubCachePayload {
        var sessionIndex: [UUID: [Session]] = [:]
        var drafts: [UUID: Session] = [:]
        var pending: [UUID: Session] = [:]
        var meta: [UUID: HubPropertyMeta] = [:]

        for property in properties {
            let sessions = loadAndNormalizeSessions(propertyID: property.id)
            sessionIndex[property.id] = sessions

            if let draft = sessions
                .filter({ $0.status == .draft })
                .sorted(by: { $0.startedAt > $1.startedAt })
                .first {
                drafts[property.id] = draft
            }

            if let pendingSession = sessions
                .filter({ isPendingDelivery($0) })
                .sorted(by: { $0.startedAt > $1.startedAt })
                .first {
                pending[property.id] = pendingSession
            }

            let client = property.clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let address = normalizedAddressLine(property.address)
            let name = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
            meta[property.id] = HubPropertyMeta(
                clientLine: client.isEmpty ? nil : client,
                addressLine: address.isEmpty ? nil : address,
                normalizedNameToken: name.lowercased(),
                normalizedClientToken: client.lowercased(),
                normalizedAddressToken: address.lowercased()
            )
        }

        return HubCachePayload(
            sessionIndex: sessionIndex,
            drafts: drafts,
            pending: pending,
            meta: meta
        )
    }

    private func loadAndNormalizeSessions(propertyID: UUID) -> [Session] {
        let fetched = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
        var uniqueByID: [UUID: Session] = [:]
        for session in fetched {
            uniqueByID[session.id] = session
        }
        return uniqueByID.values.sorted { $0.startedAt < $1.startedAt }
    }

    private func normalizedAddressLine(_ rawAddress: String?) -> String {
        (rawAddress ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ", United States", with: "", options: [.caseInsensitive, .anchored, .backwards], range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadSessionCache(for propertyID: UUID) {
        let sessions = loadAndNormalizeSessions(propertyID: propertyID)
        sessionIndexByProperty[propertyID] = sessions

        draftSessionByProperty[propertyID] = sessions
            .filter { $0.status == .draft }
            .sorted { $0.startedAt > $1.startedAt }
            .first

        pendingExportSessionByProperty[propertyID] = sessions
            .filter { isPendingDelivery($0) }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func isPendingDelivery(_ session: Session) -> Bool {
        session.isSealed && session.firstDeliveredAt == nil
    }

    func isReExportEligible(_ session: Session, now: Date = Date()) -> Bool {
        guard session.firstDeliveredAt != nil else { return false }
        guard let expiresAt = session.reExportExpiresAt else { return false }
        return now < expiresAt
    }

    func sessionNeedsDeliveryOrReExport(_ session: Session, now: Date = Date()) -> Bool {
        isPendingDelivery(session) || isReExportEligible(session, now: now)
    }

    func sessionReExportWindowExpired(_ session: Session, now: Date = Date()) -> Bool {
        guard session.status == .completed else { return false }
        guard session.isSealed else { return false }
        guard session.firstDeliveredAt != nil else { return false }
        guard let expiresAt = session.reExportExpiresAt else { return false }
        return now >= expiresAt
    }

    private func applyDeliverySuccess(to session: inout Session, deliveredAt: Date) {
        session.isSealed = true
        session.exportedAt = deliveredAt
        if session.firstDeliveredAt == nil {
            session.firstDeliveredAt = deliveredAt
            print("[ExportDelivery] sessionID=\(session.id.uuidString) firstDeliveredAt=\(deliveredAt)")
        }
        if session.reExportExpiresAt == nil, let first = session.firstDeliveredAt {
            session.reExportExpiresAt = Calendar.current.date(byAdding: .day, value: reExportWindowDays, to: first)
            if let expiresAt = session.reExportExpiresAt {
                print("[ExportDelivery] sessionID=\(session.id.uuidString) reExportExpiresAt=\(expiresAt)")
            }
        }
        if let first = session.firstDeliveredAt, let expiresAt = session.reExportExpiresAt {
            let isPendingDelivery = self.isPendingDelivery(session)
            let isReExportEligible = deliveredAt < expiresAt
            print("[ExportEligibility] sessionID=\(session.id.uuidString) now=\(deliveredAt) firstDeliveredAt=\(first) reExportExpiresAt=\(expiresAt) eligible=\(isReExportEligible)")
            print("[DeliveryState] sessionID=\(session.id.uuidString) sealed=\(session.isSealed) firstDeliveredAt=\(String(describing: session.firstDeliveredAt)) reExportExpiresAt=\(String(describing: session.reExportExpiresAt)) exportedAt=\(String(describing: session.exportedAt)) isPendingDelivery=\(isPendingDelivery) isReExportEligible=\(isReExportEligible)")
        }
    }

    private func logActiveSession(_ session: Session?) {
        guard let session else {
            print("[ActiveSession] NONE")
            return
        }
        let isBaseline = properties.first(where: { $0.id == session.propertyID })?.baselineSessionID == session.id
        print(
            "[ActiveSession] propertyID=\(session.propertyID.uuidString) " +
            "sessionID=\(session.id.uuidString) " +
            "isBaseline=\(isBaseline) " +
            "startedAt=\(session.startedAt) " +
            "status=\(session.status.rawValue)"
        )
    }
}
