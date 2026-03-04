//
//  ScoutCaptureApp.swift
//  ScoutCapture
//
//  Created by Brian Bennett on 2/3/26.
//

import SwiftUI
import UIKit
import MapKit
import Combine
import ImageIO
import UniformTypeIdentifiers

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // Keep the app in portrait.
        return .portrait
    }
}

@main
struct ScoutCaptureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appState)
        }
    }
}

private struct AppRootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sessionHubReady: Bool = false
    @State private var cameraPreviewReady: Bool = false
    @State private var minimumLaunchDelayMet: Bool = false
    @State private var didStartWarmup: Bool = false

    private var isAppReady: Bool {
        sessionHubReady && cameraPreviewReady && minimumLaunchDelayMet
    }

    var body: some View {
        Group {
            if !isAppReady {
                LoadingView()
            } else {
                SessionHubView()
            }
        }
        .onReceive(CameraManager.shared.$isReadyForPreview.removeDuplicates()) { ready in
            if ready {
                cameraPreviewReady = true
            }
        }
        .task {
            guard !didStartWarmup else { return }
            didStartWarmup = true

            _ = StorageRoot.prepareStorage()

            async let minDelay: Void = {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    minimumLaunchDelayMet = true
                }
            }()

            CameraManager.prewarm()
            if CameraManager.shared.isReadyForPreview {
                cameraPreviewReady = true
            }

            await withCheckedContinuation { continuation in
                appState.warmLaunchReadiness {
                    sessionHubReady = true
                    continuation.resume()
                }
            }

            _ = await minDelay
            AddPropertyWarmup.prewarm()
            OptionalDetailNoteWarmup.prewarm()
        }
    }
}

struct SessionHubView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    private let localStore = LocalStore()
    @State private var path: [HubRoute] = []
    @State private var showAddProperty: Bool = false
    @State private var pressedPropertyID: UUID? = nil
    @State private var isEditMode: Bool = false
    @State private var showArchivedProperties: Bool = false
    @State private var propertyToArchive: Property? = nil
    @State private var propertyToDelete: Property? = nil
    @State private var editContactProperty: Property? = nil
    @State private var manageSessionsProperty: Property? = nil
    @State private var pendingExportPromptSession: Session? = nil
    @State private var pendingExportPromptProperty: Property? = nil
    @State private var isPreparingPendingExport: Bool = false
    @State private var pendingExportFile: PendingExportFile? = nil
    @State private var pendingExportChecklist = ExportChecklistState()
    @State private var pendingExportErrorMessage: String? = nil
    @State private var showPendingExportError: Bool = false
    @State private var mapLookupPropertyID: UUID? = nil
    @State private var showMapsErrorToast: Bool = false
    @State private var mapsErrorToastToken: Int = 0
    @State private var showPhoneNumberErrorToast: Bool = false
    @State private var phoneErrorToastToken: Int = 0
    @State private var isSearchExpanded: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    @State private var propertyListFilter: PropertyListFilter = .all
    @State private var showCalendarComingSoonPopup: Bool = false
#if DEBUG
    @State private var showDebugTools: Bool = false
#endif

    private let selectionHaptic = UIImpactFeedbackGenerator(style: .light)

    private enum HubRoute: Hashable {
        case propertySession(propertyID: UUID, resumeDraft: Bool)
    }

    private enum PropertyListFilter {
        case all
        case drafts
        case pendingExport
    }

    private struct PendingExportFile: Identifiable {
        let id = UUID()
        let propertyID: UUID
        let sessionID: UUID
        let url: URL
    }

    private struct ExportChecklistState {
        var originalsComplete: Bool = false
        var sessionDataComplete: Bool = false
        var zipReady: Bool = false
    }

    private enum ExportChecklistStep {
        case originals
        case sessionData
        case zipReady
    }
    
    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.85)
    }
    
    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }
    
    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }
    
    private var headerPrimaryLabel: Color {
        colorScheme == .light ? .black : .white
    }

    private var draftCount: Int {
        appState.draftPropertyCount()
    }

    private var pendingExportCount: Int {
        appState.pendingExportCountAcrossProperties()
    }

    private var activeProperties: [Property] {
        appState.properties.filter { !$0.isArchived }
    }

    private var archivedProperties: [Property] {
        appState.properties.filter { $0.isArchived }
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredActiveProperties: [Property] {
        activeProperties
            .filter(matchesSearch(_:))
            .filter(matchesPropertyFilter(_:))
    }

    private var filteredArchivedProperties: [Property] {
        archivedProperties
            .filter(matchesSearch(_:))
            .filter(matchesPropertyFilter(_:))
    }

    private var isCompactSearchMode: Bool {
        (isSearchExpanded && isSearchFieldFocused) || !normalizedSearchQuery.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                let showArchivedSection = isEditMode && showArchivedProperties
                let hasNoMatches = filteredActiveProperties.isEmpty && (!showArchivedSection || filteredArchivedProperties.isEmpty)
                let hasNoPropertiesAtAll = activeProperties.isEmpty && (!showArchivedSection || archivedProperties.isEmpty)
                if hasNoPropertiesAtAll {
                    ContentUnavailableView(
                        "No Properties",
                        systemImage: "house",
                        description: Text("Add a property to start a session.")
                    )
                } else {
                    List {
                        if !filteredActiveProperties.isEmpty {
                            Section {
                                ForEach(filteredActiveProperties) { property in
                                    propertyRow(property)
                                }
                            }
                        }

                        if showArchivedSection && !filteredArchivedProperties.isEmpty {
                            Section("Archived") {
                                ForEach(filteredArchivedProperties) { property in
                                    propertyRow(property)
                                }
                            }
                        }

                        if hasNoMatches {
                            Section {
                                Text("No matching properties")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                countersHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                debugToolsBottomBar
            }
            .navigationDestination(for: HubRoute.self) { route in
                switch route {
                case let .propertySession(propertyID, resumeDraft):
                    PropertySessionView(propertyID: propertyID, resumeDraft: resumeDraft)
                        .environmentObject(appState)
                }
            }
            .fullScreenCover(isPresented: $showAddProperty) {
                HubAddPropertySheet()
                    .environmentObject(appState)
            }
            .sheet(item: $manageSessionsProperty) { property in
                PropertySessionsManagerView(property: property)
                    .environmentObject(appState)
            }
            .sheet(item: $editContactProperty) { property in
                EditContactSheet(property: property)
                    .environmentObject(appState)
            }
            .sheet(item: $pendingExportFile) { file in
                HubSessionDocumentExportPicker(
                    fileURL: file.url,
                    onComplete: { didExport in
                        print("[DeliverResult] sessionID=\(file.sessionID.uuidString) success=\(didExport)")
                        if didExport {
                            _ = appState.markSessionExported(propertyID: file.propertyID, sessionID: file.sessionID)
                            if let updated = appState.sessions(for: file.propertyID).first(where: { $0.id == file.sessionID }) {
                                let pending = appState.isPendingDelivery(updated)
                                let reExportEligible = appState.isReExportEligible(updated)
                                print("[DeliveryState] sessionID=\(updated.id.uuidString) firstDeliveredAt=\(String(describing: updated.firstDeliveredAt)) reExportExpiresAt=\(String(describing: updated.reExportExpiresAt)) pending=\(pending) reExportEligible=\(reExportEligible)")
                            }
                        }
                        pendingExportFile = nil
                        isPreparingPendingExport = false
                        appState.refreshProperties()
                    }
                )
            }
#if DEBUG
            .fullScreenCover(isPresented: $showDebugTools) {
                DebugToolsView()
                    .environmentObject(appState)
            }
#endif
            .onAppear {
                if appState.properties.isEmpty {
                    appState.refreshProperties()
                }
                selectionHaptic.prepare()
            }
            .alert("Archive Property?", isPresented: Binding(
                get: { propertyToArchive != nil },
                set: { if !$0 { propertyToArchive = nil } }
            )) {
                Button("Archive") {
                    guard let property = propertyToArchive else { return }
                    _ = appState.setPropertyArchived(id: property.id, archived: true)
                    propertyToArchive = nil
                }
                Button("Cancel", role: .cancel) {
                    propertyToArchive = nil
                }
            } message: {
                Text("This will hide \"\(propertyToArchive?.name ?? "Property")\" from the main list. You can show it again from Archived.")
            }
            .alert("Delete Property?", isPresented: Binding(
                get: { propertyToDelete != nil },
                set: { if !$0 { propertyToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    guard let property = propertyToDelete else { return }
                    _ = appState.deleteProperty(id: property.id)
                    propertyToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    propertyToDelete = nil
                }
            } message: {
                Text("This will permanently delete all sessions, guided shots, issues, and references for this property. This cannot be undone and will not be recoverable.")
            }
            .alert("Export Failed", isPresented: $showPendingExportError) {
                Button("Retry") {
                    guard let property = pendingExportPromptProperty, let session = pendingExportPromptSession else { return }
                    beginPendingExport(for: property, session: session)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(pendingExportErrorMessage ?? "Unable to prepare export.")
            }
            .overlay {
                if pendingExportPromptSession != nil, pendingExportPromptProperty != nil {
                    pendingExportPromptOverlay
                }
            }
            .overlay {
                if isPreparingPendingExport {
                    preparingExportOverlay
                }
            }
            .overlay {
                if showCalendarComingSoonPopup {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showCalendarComingSoonPopup = false
                            }

                        VStack(spacing: 14) {
                            Text("Calendar")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)

                            Text("Calendar integration coming soon.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .multilineTextAlignment(.center)

                            customCapsuleToolbarButton(
                                title: "OK",
                                isEnabled: true,
                                fill: .blue,
                                stroke: .blue.opacity(0.9),
                                label: .white
                            ) {
                                showCalendarComingSoonPopup = false
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 430)
                        .background(Color.black.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    }
                    .animation(.easeInOut(duration: 0.18), value: showCalendarComingSoonPopup)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if showMapsErrorToast {
                        toastCapsule("Unable to open Maps for this address.")
                    }
                    if showPhoneNumberErrorToast {
                        toastCapsule("No phone number on file")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func propertyRow(_ property: Property) -> some View {
        let isPressed = pressedPropertyID == property.id
        let draft = appState.draftSession(for: property.id)
        let sessionsForProperty = appState.sessions(for: property.id).sorted { $0.startedAt > $1.startedAt }
        let hasPendingExport = sessionsForProperty.contains(where: { appState.isPendingDelivery($0) })
        let latestReExportSession = reExportCandidateSession(for: property.id)
        let hasReExportGlyph = latestReExportSession != nil
        let clientLine = propertyClientLine(property)
        let addressLine = propertyAddressLine(property)
        let hasMapsButton = mapsAddressQuery(for: property) != nil
        let hasPhoneActions = hasValidPhoneNumber(property)
        let hasStatusRow = draft != nil || hasPendingExport || hasReExportGlyph || isEditMode
        let _ = {
            let firstDelivered = latestReExportSession?.firstDeliveredAt
            let expiresAt = latestReExportSession?.reExportExpiresAt
            print("[ReExportEligibility] propertyID=\(property.id.uuidString) firstDeliveredAt=\(String(describing: firstDelivered)) reExportExpiresAt=\(String(describing: expiresAt)) eligible=\(hasReExportGlyph)")
        }()

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if hasReExportGlyph {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color.green.opacity(0.92))
                    }
                    Text(property.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                if let clientLine {
                    Text(clientLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let addressLine {
                    Text(addressLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if hasStatusRow {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 8) {
                            if draft != nil {
                                chipLabel("Draft", tint: .orange)
                            }

                            if hasPendingExport {
                                chipLabel("Pending Export", tint: .blue)
                            }
                        }

                    }
                }

                if isEditMode {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Menu {
                            Button("Manage Sessions") {
                                manageSessionsProperty = property
                            }
                            Button("Edit Contact") {
                                editContactProperty = property
                            }
                            if property.isArchived {
                                Button("Unarchive Property") {
                                    _ = appState.setPropertyArchived(id: property.id, archived: false)
                                }
                            } else {
                                Button("Archive Property") {
                                    propertyToArchive = property
                                }
                            }
                            Button("Delete Property", role: .destructive) {
                                requestDeleteProperty(property)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.16))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: (addressLine != nil ? (clientLine != nil ? 58 : 40) : 24), alignment: .top)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isPressed ? Color.primary.opacity(colorScheme == .light ? 0.08 : 0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isPressed ? Color.primary.opacity(0.18) : .clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditMode else { return }
            handlePropertyTap(property)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isEditMode {
                if hasMapsButton {
                    Button {
                        openMaps(for: property)
                    } label: {
                        Label("Maps", systemImage: "map.fill")
                    }
                    .tint(.blue)
                }

                if hasPhoneActions {
                    Button {
                        triggerPhoneAction(.message, for: property)
                    } label: {
                        Label("Message", systemImage: "message.fill")
                    }
                    .tint(.green)

                    Button {
                        triggerPhoneAction(.call, for: property)
                    } label: {
                        Label("Call", systemImage: "phone.fill")
                    }
                    .tint(.green)
                }

            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isEditMode, hasReExportGlyph, let reExportSession = latestReExportSession {
                Button {
                    print("[ReExportInvoke] propertyID=\(property.id.uuidString) sessionID=\(reExportSession.id.uuidString) source=leadingSwipe")
                    beginPendingExport(for: property, session: reExportSession)
                } label: {
                    Label("Re-export", systemImage: "clock.arrow.circlepath")
                }
                .tint(.green)
            }
        }
    }

    private func propertyClientLine(_ property: Property) -> String? {
        appState.hubMeta(for: property.id)?.clientLine
    }

    private func propertyAddressLine(_ property: Property) -> String? {
        appState.hubMeta(for: property.id)?.addressLine
    }

    private func mapsAddressQuery(for property: Property) -> String? {
        let rawAddress = property.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleaned = rawAddress
            .replacingOccurrences(of: ", United States", with: "", options: [.caseInsensitive, .anchored, .backwards], range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func hasValidPhoneNumber(_ property: Property) -> Bool {
        let digits = (property.clientPhone ?? "").filter(\.isNumber)
        return digits.count >= 7
    }

    private func openMaps(for property: Property) {
        guard mapLookupPropertyID == nil else { return }
        guard let address = mapsAddressQuery(for: property) else { return }
        mapLookupPropertyID = property.id

        Task {
            do {
                if #available(iOS 26.0, *) {
                    guard let request = MKGeocodingRequest(addressString: address) else {
                        throw NSError(domain: "SessionHubView.Geocoding", code: 1)
                    }
                    let items = try await request.mapItems
                    guard let first = items.first else {
                        throw NSError(domain: "SessionHubView.Geocoding", code: 2)
                    }
                    _ = first
                } else {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = address
                    let response = try await MKLocalSearch(request: request).start()
                    guard let first = response.mapItems.first else {
                        throw NSError(domain: "SessionHubView.Geocoding", code: 3)
                    }
                    _ = first
                }
                await MainActor.run {
                    mapLookupPropertyID = nil
                    openAppleMapsSearch(address: address)
                }
            } catch {
                await MainActor.run {
                    mapLookupPropertyID = nil
                    showMapsErrorToastNow()
                }
            }
        }
    }

    private func openAppleMapsSearch(address: String) {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !encoded.isEmpty, let url = URL(string: "http://maps.apple.com/?q=\(encoded)") else {
            showMapsErrorToastNow()
            return
        }
        UIApplication.shared.open(url)
    }

    private func showMapsErrorToastNow() {
        mapsErrorToastToken += 1
        let token = mapsErrorToastToken
        showMapsErrorToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard token == mapsErrorToastToken else { return }
            showMapsErrorToast = false
        }
    }

    private enum PhoneQuickAction {
        case call
        case message
    }

    private func triggerPhoneAction(_ action: PhoneQuickAction, for property: Property) {
        let digits = (property.clientPhone ?? "").filter(\.isNumber)
        guard digits.count >= 7 else {
            showPhoneNumberErrorToastNow()
            return
        }

        let scheme: String
        switch action {
        case .call:
            scheme = "tel://\(digits)"
        case .message:
            scheme = "sms://\(digits)"
        }
        guard let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) else {
            showPhoneNumberErrorToastNow()
            return
        }
        UIApplication.shared.open(url)
    }

    private func showPhoneNumberErrorToastNow() {
        phoneErrorToastToken += 1
        let token = phoneErrorToastToken
        showPhoneNumberErrorToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard token == phoneErrorToastToken else { return }
            showPhoneNumberErrorToast = false
        }
    }

    @ViewBuilder
    private func toastCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.78))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.top, 10)
            .transition(.opacity)
    }

    @ViewBuilder
    private func chipLabel(_ text: String, tint: Color, systemImage: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.15))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }

    private var countersHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                HStack {
                    if !isEditMode {
                        Button {
                            showCalendarComingSoonPopup = true
                        } label: {
                            Image(systemName: "calendar")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(buttonLabel)
                                .frame(width: 42, height: 42)
                                .background(buttonFill)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(buttonStroke, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if isEditMode {
#if DEBUG
                        customCapsuleToolbarButton(
                            title: "Debug",
                            isEnabled: true,
                            fill: .red.opacity(0.92),
                            stroke: .red.opacity(0.95),
                            label: .white
                        ) {
                            showDebugTools = true
                        }
#endif
                    }

                    Spacer(minLength: 0)
                    customCapsuleToolbarButton(
                        title: isEditMode ? "Done" : "Edit",
                        isEnabled: true,
                        fill: isEditMode ? .blue : nil,
                        stroke: isEditMode ? .blue.opacity(0.9) : nil,
                        label: isEditMode ? .white : nil
                    ) {
                        isEditMode.toggle()
                        if !isEditMode {
                            showArchivedProperties = false
                        }
                    }
                }
            }

            if !isCompactSearchMode {
                Image(colorScheme == .light ? "ScoutCaptureLogoBlue" : "ScoutCaptureLogoWhite")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 58)
                    .accessibilityHidden(true)
                
                Text("Session View")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)

                HStack(spacing: 12) {
                    counterCard(
                        title: "Drafts",
                        value: draftCount,
                        tint: .orange,
                        isActive: propertyListFilter == .drafts
                    ) {
                        togglePropertyFilter(.drafts)
                    }
                    counterCard(
                        title: "Pending Export",
                        value: pendingExportCount,
                        tint: .blue,
                        isActive: propertyListFilter == .pendingExport
                    ) {
                        togglePropertyFilter(.pendingExport)
                    }
                }
                
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("Select a property below to continue")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(headerPrimaryLabel)
                        .opacity(0.72)
                        .fixedSize(horizontal: true, vertical: true)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
            }

            propertiesSearchRow
        }
        .padding(.horizontal, 16)
        .padding(.top, isCompactSearchMode ? 4 : 6)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground))
        .animation(.easeInOut(duration: 0.18), value: isSearchExpanded)
        .animation(.easeInOut(duration: 0.18), value: isCompactSearchMode)
    }

    private var propertiesSearchRow: some View {
        HStack(spacing: 10) {
            Text("Properties")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer(minLength: 0)

            if isSearchExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    TextField("Search name or address", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFieldFocused)
                        .font(.system(size: 15, weight: .medium))

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            DispatchQueue.main.async {
                                isSearchFieldFocused = true
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))

                Button("Cancel") {
                    collapseSearch()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

                addCircleButton
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSearchExpanded = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isSearchFieldFocused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(buttonLabel)
                        .frame(width: 34, height: 34)
                        .background(buttonFill)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(buttonStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))

                addCircleButton
            }
        }
    }

    @ViewBuilder
    private var addCircleButton: some View {
        Button {
            showAddProperty = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(buttonLabel)
                .frame(width: 34, height: 34)
                .background(buttonFill)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(buttonStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func collapseSearch() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSearchExpanded = false
            searchQuery = ""
        }
        isSearchFieldFocused = false
    }

    private func togglePropertyFilter(_ filter: PropertyListFilter) {
        if propertyListFilter == filter {
            propertyListFilter = .all
        } else {
            propertyListFilter = filter
        }
    }

    private func propertyHasDraft(_ property: Property) -> Bool {
        appState.draftSession(for: property.id) != nil
    }

    private func propertyHasPendingExport(_ property: Property) -> Bool {
        appState.sessions(for: property.id).contains(where: { appState.isPendingDelivery($0) })
    }

    private func reExportCandidateSession(for propertyID: UUID) -> Session? {
        appState.sessions(for: propertyID)
            .filter { appState.isReExportEligible($0) }
            .sorted { lhs, rhs in
                let l = lhs.firstDeliveredAt ?? .distantPast
                let r = rhs.firstDeliveredAt ?? .distantPast
                return l > r
            }
            .first
    }

    private func matchesPropertyFilter(_ property: Property) -> Bool {
        switch propertyListFilter {
        case .all:
            return true
        case .drafts:
            return propertyHasDraft(property)
        case .pendingExport:
            return propertyHasPendingExport(property)
        }
    }

    @ViewBuilder
    private var debugToolsBottomBar: some View {
        if isEditMode {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer(minLength: 0)
                    customCapsuleToolbarButton(
                        title: showArchivedProperties ? "Hide Archived" : "Show Archived",
                        isEnabled: true
                    ) {
                        showArchivedProperties.toggle()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    @ViewBuilder
    private func counterCard(
        title: String,
        value: Int,
        tint: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isActive ? .white : headerPrimaryLabel)
                Text("\(value)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(isActive ? .white : tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isActive ? tint.opacity(0.86) : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? tint : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var pendingExportPromptOverlay: some View {
        let actionTitle = "Deliver Now"
        let titleText = "Delivery required"
        let messageText = "This property has a completed session waiting to be delivered. Deliver it now to start a new session."
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text(titleText)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                Text(messageText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    customCapsuleToolbarButton(title: "Cancel", isEnabled: true) {
                        if let session = pendingExportPromptSession {
                            print("[DeliverPrompt] sessionID=\(session.id.uuidString) userAction=cancel")
                        }
                        dismissPendingExportPrompt()
                    }
                    customCapsuleToolbarButton(
                        title: actionTitle,
                        isEnabled: true,
                        fill: .blue,
                        stroke: .blue.opacity(0.9),
                        label: .white
                    ) {
                        guard let property = pendingExportPromptProperty, let session = pendingExportPromptSession else { return }
                        print("[DeliverPrompt] sessionID=\(session.id.uuidString) userAction=deliver")
                        beginPendingExport(for: property, session: session)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: 430)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
        .animation(.easeInOut(duration: 0.18), value: isSearchExpanded)
    }

    private func matchesSearch(_ property: Property) -> Bool {
        let query = normalizedSearchQuery
        guard !query.isEmpty else { return true }
        if let meta = appState.hubMeta(for: property.id) {
            return meta.normalizedNameToken.contains(query) ||
                meta.normalizedClientToken.contains(query) ||
                meta.normalizedAddressToken.contains(query)
        }
        let name = property.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let client = property.clientName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let address = property.address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return name.contains(query) || client.contains(query) || address.contains(query)
    }

    @ViewBuilder
    private var preparingExportOverlay: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Preparing Export")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                VStack(spacing: 10) {
                    checklistRow(title: "Originals", isComplete: pendingExportChecklist.originalsComplete)
                    checklistRow(title: "Session Data", isComplete: pendingExportChecklist.sessionDataComplete)
                    checklistRow(title: "ZIP Ready", isComplete: pendingExportChecklist.zipReady)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(minWidth: 280)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
        .allowsHitTesting(true)
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

    private func openProperty(_ property: Property) {
        appState.selectProperty(id: property.id)
        if appState.draftSession(for: property.id) != nil {
            _ = appState.loadDraftSession(for: property.id)
            path.append(.propertySession(propertyID: property.id, resumeDraft: true))
        } else {
            _ = appState.startSession()
            path.append(.propertySession(propertyID: property.id, resumeDraft: false))
        }
    }

    private func handlePropertyTap(_ property: Property) {
        selectionHaptic.impactOccurred()
        pressedPropertyID = property.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let sessions = appState.sessions(for: property.id).sorted { $0.startedAt > $1.startedAt }
            let latest = sessions.first
            let pendingSession = appState.latestPendingExportSession(for: property.id)
            let pending = pendingSession != nil
            let latestID = latest?.id.uuidString ?? "NONE"
            let isBaseline = latest.map { property.baselineSessionID == $0.id } ?? false
            let sealed = latest?.isSealed ?? false
            let firstDelivered = latest?.firstDeliveredAt.map { "\($0)" } ?? "nil"
            let action = pending ? "promptDeliver" : "openCamera"
            print("[PropertyTap] propertyID=\(property.id.uuidString) latestSessionID=\(latestID) isBaseline=\(isBaseline) sealed=\(sealed) firstDeliveredAt=\(firstDelivered) pending=\(pending) action=\(action)")
            if let pendingSession {
                pendingExportPromptProperty = property
                pendingExportPromptSession = pendingSession
                return
            }
            openProperty(property)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if pressedPropertyID == property.id {
                pressedPropertyID = nil
            }
        }
    }

    private func dismissPendingExportPrompt() {
        pendingExportPromptProperty = nil
        pendingExportPromptSession = nil
    }

    private func beginPendingExport(for property: Property, session: Session) {
        guard !isPreparingPendingExport else { return }
        pendingExportErrorMessage = nil
        showPendingExportError = false
        isPreparingPendingExport = true
        pendingExportChecklist = ExportChecklistState()
        dismissPendingExportPrompt()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try buildPendingSessionExportArchive(
                    property: property,
                    session: session,
                    progress: { step in
                        DispatchQueue.main.async {
                            switch step {
                            case .originals:
                                pendingExportChecklist.originalsComplete = true
                            case .sessionData:
                                pendingExportChecklist.sessionDataComplete = true
                            case .zipReady:
                                pendingExportChecklist.zipReady = true
                            }
                        }
                    }
                )
                DispatchQueue.main.async {
                    isPreparingPendingExport = false
                    pendingExportFile = PendingExportFile(
                        propertyID: property.id,
                        sessionID: session.id,
                        url: url
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isPreparingPendingExport = false
                    pendingExportErrorMessage = error.localizedDescription
                    showPendingExportError = true
                    pendingExportPromptProperty = property
                    pendingExportPromptSession = session
                }
            }
        }
    }

    private func buildPendingSessionExportArchive(
        property: Property,
        session: Session,
        progress: ((ExportChecklistStep) -> Void)? = nil
    ) throws -> URL {
        struct SessionExportAssetEntry: Codable {
            let localIdentifier: String
            let creationDate: Date?
            let pixelWidth: Int
            let pixelHeight: Int
            let originalFilename: String
        }

        struct SessionExportPayload: Codable {
            let exportedAt: Date
            let albumTitle: String
            let albumLocalId: String
            let orgId: UUID?
            let orgName: String?
            let folderId: String?
            let propertyId: UUID
            let propertyName: String
            let primaryContactName: String?
            let primaryContactPhone: String?
            let propertyAddress: String?
            let propertyStreet: String
            let propertyCity: String
            let propertyState: String
            let propertyZip: String
            let property: Property?
            let session: Session?
            let activeIssueCount: Int
            let assets: [SessionExportAssetEntry]
            let observations: [Observation]
            let guidedShots: [GuidedShot]
        }

        let validationArtifacts = try localStore.validatedSessionExportArtifacts(for: session)
        let observations = (try? localStore.fetchObservations(propertyID: property.id)) ?? []
        let guidedShots = (try? localStore.fetchGuidedShots(propertyID: property.id)) ?? []

        let start = session.startedAt
        let end = session.endedAt ?? Date.distantFuture
        let sessionObservations = observations.filter { obs in
            if obs.sessionID == session.id { return true }
            return obs.sessionID == nil && obs.createdAt >= start && obs.createdAt <= end
        }

        let shotIDs = Set(sessionObservations.flatMap { obs in
            var ids = obs.shots.map(\.id)
            if let linked = obs.linkedShotID {
                ids.append(linked)
            }
            return ids
        })

        let sessionGuidedShots = guidedShots.filter { guided in
            if let shotID = guided.shot?.id, shotIDs.contains(shotID) {
                return true
            }
            if let capturedAt = guided.shot?.capturedAt, capturedAt >= start && capturedAt <= end {
                return true
            }
            return false
        }

        var orderedIDs: [String] = []
        var seen = Set<String>()
        func appendLocalID(_ value: String?) {
            let id = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            orderedIDs.append(id)
        }

        for observation in sessionObservations {
            for shot in observation.shots {
                appendLocalID(shot.imageLocalIdentifier)
            }
        }
        for guided in sessionGuidedShots {
            appendLocalID(guided.shot?.imageLocalIdentifier)
        }

        var assetEntries: [SessionExportAssetEntry] = []
        let propertyFolderName = try localStore.exportPropertyFolderName(propertyID: property.id)
        let exportRoot = try StorageRoot.makeSessionExportRootFolder(
            propertyFolderName: propertyFolderName,
            sessionID: session.id
        )
        let originalsRoot = exportRoot.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsRoot, withIntermediateDirectories: true)
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
        let sessionMetadata = try localStore.loadSessionMetadata(propertyID: property.id, sessionID: session.id)
#if DEBUG
        print("Pending export sessionStartedAt: \(sessionMetadata.startedAt)")
        print("Pending export sessionStartedAtLocal: \(sessionMetadata.sessionStartedAtLocal)")
        if let firstShot = sessionMetadata.shots.sorted(by: { $0.createdAt < $1.createdAt }).first {
            print("Pending export first shot createdAt: \(firstShot.createdAt)")
            print("Pending export first shot createdAtLocal: \(firstShot.capturedAtLocal ?? "nil")")
        }
        if let firstDeliveredAt = sessionMetadata.firstDeliveredAt {
            print("Pending export firstDeliveredAt: \(firstDeliveredAt)")
        }
        if let reExportExpiresAt = sessionMetadata.reExportExpiresAt {
            print("Pending export reExportExpiresAt: \(reExportExpiresAt)")
        }
#endif
        for (index, localID) in orderedIDs.enumerated() {
            let trimmed = localID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fileURL = URL(fileURLWithPath: trimmed)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            guard let data = requestImageData(for: fileURL) else { continue }
            let filename = exportFilename(for: fileURL, index: index + 1)
            let image = UIImage(data: data)
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let modifiedAt = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date)
            assetEntries.append(
                SessionExportAssetEntry(
                    localIdentifier: trimmed,
                    creationDate: attrs?[.creationDate] as? Date,
                    pixelWidth: image.map { Int($0.size.width) } ?? 0,
                    pixelHeight: image.map { Int($0.size.height) } ?? 0,
                    originalFilename: filename
                )
            )
            let destinationURL = originalsRoot.appendingPathComponent(filename)
            try data.write(to: destinationURL, options: .atomic)
            if let modifiedAt {
                try? FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationURL.path)
            }
            expectedPaths.insert("Originals/\(filename)")
        }
        progress?(.originals)

        let payload = SessionExportPayload(
            exportedAt: Date(),
            albumTitle: property.name,
            albumLocalId: "",
            orgId: property.orgId,
            orgName: appState.organizations.first(where: { $0.id == property.orgId })?.name,
            folderId: property.folderId,
            propertyId: property.id,
            propertyName: property.name,
            primaryContactName: property.clientName,
            primaryContactPhone: property.clientPhone,
            propertyAddress: property.address,
            propertyStreet: property.street ?? "",
            propertyCity: property.city ?? "",
            propertyState: property.state ?? "",
            propertyZip: property.zip ?? "",
            property: property,
            session: session,
            activeIssueCount: sessionObservations.filter { $0.status == .active }.count,
            assets: assetEntries,
            observations: sessionObservations,
            guidedShots: sessionGuidedShots
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sessionData = try encoder.encode(payload)
        try sessionData.write(to: exportRoot.appendingPathComponent("session.json"), options: .atomic)
        try validationArtifacts.validationData.write(to: exportRoot.appendingPathComponent("validation.txt"), options: .atomic)
        for csvFile in localStore.exportCSVFiles(for: validationArtifacts.metadata) {
            try csvFile.data.write(to: exportRoot.appendingPathComponent(csvFile.filename), options: .atomic)
        }
#if DEBUG
        print("EXPORT ROOT: \(exportRoot.path)")
        print("EXPORT ROOT FILES: \((try? StorageRoot.exportRootFilenames(exportRoot)) ?? [])")
#endif
        progress?(.sessionData)

        let zipEntries = try StorageRoot.zipEntriesForExportRoot(exportRoot).map { ($0.path, $0.data, $0.modifiedAt) }
        let zipData = buildZipData(entries: zipEntries)
        let fileManager = FileManager.default
        let finalURL = fileManager.temporaryDirectory.appendingPathComponent(exportZipFilename(for: property, session: session))
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp.zip")
#if DEBUG
        print("Pending export ZIP temp path: \(tempURL.path)")
        print("Pending export ZIP final path: \(finalURL.path)")
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
        print("Pending export ZIP temp exists: \(tempExists ? "YES" : "NO"), bytes: \(tempSize)")
#endif
        guard tempExists, tempSize > 0 else {
            throw NSError(domain: "ScoutCapture.PendingExport", code: 5, userInfo: [NSLocalizedDescriptionKey: "Temporary ZIP write failed."])
        }

        try fileManager.moveItem(at: tempURL, to: finalURL)
        let finalExists = fileManager.fileExists(atPath: finalURL.path)
        let finalSize = ((try? fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("Pending export ZIP final exists: \(finalExists ? "YES" : "NO"), bytes: \(finalSize)")
#endif
        guard finalExists, finalSize > 0 else {
            throw NSError(domain: "ScoutCapture.PendingExport", code: 6, userInfo: [NSLocalizedDescriptionKey: "Final ZIP write failed."])
        }

        let listedEntries = try listPendingExportZipEntryPaths(at: finalURL)
#if DEBUG
        let preview = Array(listedEntries.prefix(12))
        print("Pending export ZIP entries count: \(listedEntries.count)")
        print("Pending export ZIP entries preview: \(preview)")
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
            throw NSError(domain: "ScoutCapture.PendingExport", code: 7, userInfo: [NSLocalizedDescriptionKey: "ZIP integrity check failed."])
        }
#if DEBUG
        guard actualPaths.contains("session.json"), actualPaths.contains("validation.txt") else {
            assertionFailure("Pending export ZIP root missing session.json or validation.txt")
            throw NSError(domain: "ScoutCapture.PendingExport", code: 10, userInfo: [NSLocalizedDescriptionKey: "ZIP root missing validation artifacts."])
        }
        if !validationArtifacts.prewritePassed || !validationArtifacts.postwritePassed {
            assertionFailure(String(data: validationArtifacts.validationData, encoding: .utf8) ?? "Export validation failed")
        }
#endif
        progress?(.zipReady)
        return finalURL
    }

    private func requestImageData(for fileURL: URL) -> Data? {
        try? Data(contentsOf: fileURL)
    }

    private func ensurePendingStampedJPEGs(
        propertyID: UUID,
        sessionID: UUID,
        propertyName: String,
        propertyAddress: String?,
        sessionMetadata: SessionMetadata
    ) throws -> [String: URL] {
        let fileManager = FileManager.default
        var metadata = sessionMetadata
        var didUpdateMetadata = false
        var output: [String: URL] = [:]
        var reservedNames = Set(
            ((try? fileManager.contentsOfDirectory(atPath: localStore.stampedDirectoryURL(propertyID: propertyID, sessionID: sessionID).path)) ?? [])
                .map { $0.lowercased() }
        )

        for index in metadata.shots.indices {
            let shot = metadata.shots[index]
            let originalURL = localStore.originalsDirectoryURL(propertyID: propertyID, sessionID: sessionID)
                .appendingPathComponent(shot.originalFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: originalURL.path) else { continue }

            let stampedName = nextReadablePendingStampedFilename(shot: shot, reservedNames: &reservedNames)
            if metadata.shots[index].stampedFilename != stampedName {
                metadata.shots[index].stampedFilename = stampedName
                didUpdateMetadata = true
            }
            let stampedRelative = "Stamped/\(stampedName)"
            if metadata.shots[index].stampedRelativePath != stampedRelative {
                metadata.shots[index].stampedRelativePath = stampedRelative
                didUpdateMetadata = true
            }
            if (metadata.shots[index].imageWidth ?? 0) <= 0 || (metadata.shots[index].imageHeight ?? 0) <= 0 {
                let sourceImage = UIImage(contentsOfFile: originalURL.path)
                if let sourceImage {
                    metadata.shots[index].imageWidth = max(1, Int(sourceImage.size.width))
                    metadata.shots[index].imageHeight = max(1, Int(sourceImage.size.height))
                    didUpdateMetadata = true
                }
            }

            let stampedURL = localStore.stampedDirectoryURL(propertyID: propertyID, sessionID: sessionID)
                .appendingPathComponent(stampedName, isDirectory: false)
            try createPendingStampedJPEGIfMissing(
                sourceURL: originalURL,
                destinationURL: stampedURL,
                captureDate: shot.updatedAt,
                overlayLines: pendingStampOverlayLines(
                    propertyName: propertyName,
                    shot: shot,
                    isBaselineSession: metadata.isBaselineSession
                ),
                metadataContext: pendingStampedMetadataContext(
                    propertyID: propertyID,
                    propertyName: propertyName,
                    propertyAddress: propertyAddress,
                    sessionID: sessionID,
                    shot: shot,
                    schemaVersion: metadata.schemaVersion
                ),
                fileManager: fileManager
            )
            output[shot.originalFilename] = stampedURL
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

    private func createPendingStampedJPEGIfMissing(
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
        let stampedData = try encodePendingStampedJPEG(
            from: sourceData,
            captureDate: captureDate,
            overlayLines: overlayLines,
            metadataContext: metadataContext
        )
        try stampedData.write(to: destinationURL, options: [.atomic])

        let size = ((try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("[Stamp] destination=\(destinationURL.path) utType=\(UTType.jpeg.identifier) bytes=\(size)")
#endif
        guard fileManager.fileExists(atPath: destinationURL.path), size > 0 else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stamped JPEG write failed"])
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

    private func encodePendingStampedJPEG(
        from sourceData: Data,
        captureDate: Date,
        overlayLines: [String],
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing source image for pending stamped export"])
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
        let image = normalizedPendingUprightCGImage(from: sourceData)
            ?? sourceCGImage
        guard let image else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing source image for pending stamped export"])
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
        exif[kCGImagePropertyExifUserComment] = pendingStructuredComment(
            captureTime: captureTime,
            metadataContext: metadataContext
        )
        tiff[kCGImagePropertyTIFFDateTime] = captureTime.localDateTimeString
        mergedProps[kCGImagePropertyExifDictionary] = exif
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        mergedProps[kCGImagePropertyOrientation] = 1
        tiff[kCGImagePropertyTIFFOrientation] = 1
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        mergedProps[kCGImageDestinationLossyCompressionQuality] = 0.90
        print("[Stamp] orientation writeTag exif/tiff=1")
        if let gps = makePendingGPSDictionary(
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
            iptc[kCGImagePropertyIPTCKeywords] = pendingKeywordList(metadataContext: metadataContext)
            mergedProps[kCGImagePropertyIPTCDictionary] = iptc
        }

#if DEBUG
        let topKeys = mergedProps.keys.map { $0 as String }.sorted()
        let exifKeys = ((mergedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String }.sorted()
        let gpsKeys = ((mergedProps[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String }.sorted()
        let hasDateTimeOriginal = ((mergedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:])[kCGImagePropertyExifDateTimeOriginal] != nil
        let hasGpsAccuracy = ((mergedProps[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:])[kCGImagePropertyGPSHPositioningError] != nil
        print("[Stamp] captureDate=\(captureTime.captureDate) localDateTimeString=\(captureTime.localDateTimeString) tzOffset=\(captureTime.tzOffsetString) iso8601WithOffset=\(captureTime.iso8601WithOffset)")
        let accuracyText = metadataContext.accuracyMeters.map { String(format: "%.3f", $0) } ?? "nil"
        print("[Stamp] gps present=\(gpsKeys.isEmpty ? "NO" : "YES") accuracyMeters=\(accuracyText)")
        print("[Stamp] metadata top-level keys: \(topKeys)")
        print("[Stamp] metadata EXIF keys: \(exifKeys)")
        print("[Stamp] metadata GPS keys: \(gpsKeys)")
        print("[Stamp] metadata has DateTimeOriginal=\(hasDateTimeOriginal) has GPSHPositioningError=\(hasGpsAccuracy)")
#endif

        let stampedCGImage = drawPendingStampOverlay(on: image, lines: overlayLines) ?? image

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create JPEG destination"])
        }
        if let xmpMetadata = buildPendingXMPMetadata(
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
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize JPEG destination"])
        }
        return destinationData as Data
    }

    private func pendingStampedMetadataContext(
        propertyID: UUID,
        propertyName: String,
        propertyAddress: String?,
        sessionID: UUID,
        shot: ShotMetadata,
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
            capturedExifOrientationRaw: shot.exifOrientation.flatMap(UInt32.init) ?? pendingParseExifOrientationRaw(from: shot.orientation),
            latitude: shot.latitude,
            longitude: shot.longitude,
            accuracyMeters: shot.accuracyMeters,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            schemaVersion: schemaVersion
        )
    }

    private func pendingParseExifOrientationRaw(from orientation: String?) -> UInt32? {
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

    private func pendingStructuredComment(
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

    private func pendingKeywordList(metadataContext: ReportLibraryModel.EmbeddedMetadataContext) -> [String] {
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

    private func makePendingGPSDictionary(
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
        gps[kCGImagePropertyGPSDateStamp] = Self.pendingExportGPSDateFormatter.string(from: captureDate)
        gps[kCGImagePropertyGPSTimeStamp] = Self.pendingExportGPSTimeFormatter.string(from: captureDate)
        if let accuracyMeters, accuracyMeters >= 0 {
            gps[kCGImagePropertyGPSHPositioningError] = accuracyMeters
        }
        return gps
    }

    private func buildPendingXMPMetadata(
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

    private func normalizedPendingUprightCGImage(from sourceData: Data) -> CGImage? {
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

    private func drawPendingStampOverlay(on image: CGImage, lines: [String]) -> CGImage? {
        guard !lines.isEmpty else { return image }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))

            let shortEdge = CGFloat(min(width, height))
            let sideInset = max(16, shortEdge * 0.025)
            let bottomInset = max(16, shortEdge * 0.025)
            let lineSpacing = max(2, shortEdge * 0.004)
            let cornerRadius = max(8, shortEdge * 0.016)
            let primarySize = max(14, shortEdge * 0.030)
            let secondarySize = max(12, shortEdge * 0.024)

            let styled: [NSAttributedString] = lines.enumerated().map { idx, line in
                NSAttributedString(
                    string: line,
                    attributes: [
                        .font: idx == 0
                            ? UIFont.systemFont(ofSize: primarySize, weight: .semibold)
                            : UIFont.systemFont(ofSize: secondarySize, weight: .regular),
                        .foregroundColor: UIColor.white
                    ]
                )
            }
            let maxTextWidth = size.width - (sideInset * 3)
            let lineSizes = styled.map { text in
                text.boundingRect(
                    with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).integral.size
            }
            let textHeight = lineSizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, lineSizes.count - 1)) * lineSpacing
            let textWidth = min(maxTextWidth, lineSizes.map(\.width).max() ?? maxTextWidth)
            let padX = max(8, shortEdge * 0.013)
            let padY = max(5, shortEdge * 0.009)
            let panelRect = CGRect(
                x: sideInset,
                y: size.height - bottomInset - (textHeight + padY * 2),
                width: textWidth + (padX * 2),
                height: textHeight + (padY * 2)
            )

            let panelPath = UIBezierPath(roundedRect: panelRect, cornerRadius: cornerRadius)
            UIColor.black.withAlphaComponent(0.58).setFill()
            panelPath.fill()

            var y = panelRect.minY + padY
            for (idx, text) in styled.enumerated() {
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

    private static let pendingExportExifTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let pendingExportExifSubsecFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "SSS"
        return formatter
    }()

    private static let pendingExportGPSDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    private static let pendingExportGPSTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func pendingExportExifOffsetString(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private func pendingStampOverlayLines(propertyName: String, shot: ShotMetadata, isBaselineSession: Bool) -> [String] {
        let line1 = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let line2 = [
            shot.building,
            shot.elevation,
            shot.detailType,
            "Angle \(max(1, shot.angleIndex))"
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
        let line3 = Self.pendingOverlayDateFormatter.string(from: shot.updatedAt)
        let noteLine = (shot.noteText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line4 = (shot.isFlagged && !noteLine.isEmpty) ? noteLine : ""
        _ = isBaselineSession
        return [line1, line2, line3, line4].filter { !$0.isEmpty }
    }

    private func nextReadablePendingStampedFilename(shot: ShotMetadata, reservedNames: inout Set<String>) -> String {
        let base = readablePendingStampedBaseName(for: shot)
        var candidate = "\(base).jpg"
        var counter = 1
        while reservedNames.contains(candidate.lowercased()) {
            candidate = "\(base)_\(String(format: "%02d", counter)).jpg"
            counter += 1
        }
        reservedNames.insert(candidate.lowercased())
        return candidate
    }

    private func readablePendingStampedBaseName(for shot: ShotMetadata) -> String {
        let datePart = Self.pendingFilenameDateFormatter.string(from: shot.updatedAt)
        let parts = [
            sanitizePendingStampFilenamePart(shot.building),
            sanitizePendingStampFilenamePart(shot.elevation),
            sanitizePendingStampFilenamePart(shot.detailType),
            "A\(max(1, shot.angleIndex))",
            datePart
        ].filter { !$0.isEmpty }
        let base = parts.joined(separator: "_")
        return base.isEmpty ? shot.shotID.uuidString : base
    }

    private func sanitizePendingStampFilenamePart(_ raw: String) -> String {
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

    private static let pendingFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let pendingOverlayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MM-dd-yyyy h:mm:ss a"
        return formatter
    }()

    private func exportFilename(for fileURL: URL, index: Int) -> String {
        let fallback = "photo-\(index).jpg"
        let original = fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = original.isEmpty ? fallback : normalizedContextFilename(original)
        return String(format: "%04d-%@", index, base.replacingOccurrences(of: "/", with: "-"))
    }

    private func normalizedContextFilename(_ filename: String) -> String {
        var output = filename
        let replacements: [(String, String)] = [
            ("North Elevation", "N"),
            ("South Elevation", "S"),
            ("East Elevation", "E"),
            ("West Elevation", "W")
        ]
        for (source, target) in replacements {
            output = output.replacingOccurrences(of: source, with: target, options: .caseInsensitive)
        }
        output = output.replacingOccurrences(of: "Elevation", with: "", options: .caseInsensitive)
        output = output.replacingOccurrences(of: "__", with: "_")
        output = output.replacingOccurrences(of: "  ", with: " ")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func exportZipFilename(for property: Property, session: Session) -> String {
        let safeProperty = sanitizedExportName(property.name, fallback: "ScoutCapture-Export")
        let propertyPrefix = String(property.id.uuidString.prefix(8))
        let sessionPrefix = String(session.id.uuidString.prefix(8))
        return "\(safeProperty)_\(propertyPrefix)_\(sessionPrefix).zip"
    }

    private func sanitizedExportName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let compact = cleaned.replacingOccurrences(of: "  ", with: " ")
        return compact.isEmpty ? fallback : compact
    }

    private func buildZipData(entries: [(path: String, data: Data, modifiedAt: Date?)]) -> Data {
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
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(zip.count)
            let (dosTime, dosDate) = dosDateTime(entry.modifiedAt ?? Date())

            appendUInt32LE(0x04034B50, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(dosTime, to: &zip)
            appendUInt16LE(dosDate, to: &zip)
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
                    localHeaderOffset: localHeaderOffset,
                    dosTime: dosTime,
                    dosDate: dosDate
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
            appendUInt16LE(record.dosTime, to: &zip)
            appendUInt16LE(record.dosDate, to: &zip)
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

    private func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
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

    private func listPendingExportZipEntryPaths(at url: URL) throws -> [String] {
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
            throw NSError(domain: "ScoutCapture.PendingExport", code: 8, userInfo: [NSLocalizedDescriptionKey: "EOCD not found."])
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
            throw NSError(domain: "ScoutCapture.PendingExport", code: 9, userInfo: [NSLocalizedDescriptionKey: "EOCD truncated."])
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

    private func crc32(_ data: Data) -> UInt32 {
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

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func requestDeleteProperty(_ property: Property) {
        propertyToDelete = property
    }
    
    @ViewBuilder
    private func customCapsuleToolbarButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 42)
                .padding(.horizontal, 14)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .tint(.clear)
        .disabled(!isEnabled)
    }
}

private struct HubSessionDocumentExportPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .formSheet
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

private struct HubAddPropertySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var selectedOrganizationID: UUID? = nil
    @State private var showAddOrganizationPrompt: Bool = false
    @State private var newOrganizationName: String = ""
    @State private var propertyCreationErrorMessage: String? = nil
    @State private var showPropertyCreationError: Bool = false
    @State private var clientName: String = ""
    @State private var clientPhone: String = ""
    @State private var propertyName: String = ""
    @State private var streetAddress: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    @State private var normalizedAddress: String = ""
    @StateObject private var propertyNameAutocomplete = AddressAutocompleteModel(resultTypes: [.pointOfInterest, .address])
    @StateObject private var addressAutocomplete = AddressAutocompleteModel(resultTypes: .address)
    @FocusState private var focusedField: Field?
    @State private var hasAppliedInitialFocus: Bool = false
    private let addOrganizationToken = "__add_new_organization__"

    private enum Field: Int, CaseIterable {
        case clientName
        case clientPhone
        case propertyName
        case streetAddress
        case city
        case state
        case zipCode
    }
    
    private var canSave: Bool {
        !propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPropertyNameResults: Bool {
        focusedField == .propertyName &&
        !propertyNameAutocomplete.completions.isEmpty &&
        !propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAddressResults: Bool {
        focusedField == .streetAddress &&
        !addressAutocomplete.completions.isEmpty &&
        !streetAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }
    
    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }
    
    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    private var primaryButtonFill: Color { .blue }
    private var primaryButtonStroke: Color { .blue.opacity(0.85) }
    private var primaryButtonLabel: Color { .white }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Cancel", isEnabled: true) {
                    dismiss()
                }

                Spacer(minLength: 0)

                Text("Add Property")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(buttonLabel)

                Spacer(minLength: 0)

                customCapsuleButton(
                    title: "Save",
                    isEnabled: canSave,
                    fill: primaryButtonFill,
                    stroke: primaryButtonStroke,
                    label: primaryButtonLabel
                ) {
                    submitProperty()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            Form {
                Section("Organization") {
                    Picker("Organization", selection: organizationSelectionToken) {
                        ForEach(appState.organizations) { organization in
                            Text(organization.name)
                                .tag(organization.id.uuidString)
                        }
                        Text("Add new organization")
                            .tag(addOrganizationToken)
                    }
                }

                Section("Primary Contact") {
                    TextField("Primary Contact Name", text: $clientName)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .clientName)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .clientPhone
                        }

                    TextField("Phone (optional)", text: $clientPhone)
                        .focused($focusedField, equals: .clientPhone)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .propertyName
                        }
                        .keyboardType(.phonePad)
                        .onChange(of: clientPhone) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            let limited = String(filtered.prefix(15))
                            if limited != clientPhone {
                                clientPhone = limited
                            }
                        }
                }

                Section("Property") {
                    TextField("Property name", text: $propertyName)
                        .focused($focusedField, equals: .propertyName)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .streetAddress
                        }
                        .onChange(of: propertyName) { _, newValue in
                            propertyNameAutocomplete.update(query: newValue)
                        }
                    if hasPropertyNameResults {
                        ForEach(propertyNameAutocomplete.completions, id: \.id) { completion in
                            autocompleteRow(completion) {
                                selectPropertyNameCompletion(completion)
                            }
                        }
                    }
                    TextField("Address", text: $streetAddress)
                        .focused($focusedField, equals: .streetAddress)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .city
                        }
                        .onChange(of: streetAddress) { _, newValue in
                            addressAutocomplete.update(query: newValue)
                            syncNormalizedAddress()
                        }
                    if hasAddressResults {
                        ForEach(addressAutocomplete.completions, id: \.id) { completion in
                            autocompleteRow(completion) {
                                selectAddressCompletion(completion)
                            }
                        }
                    }
                    TextField("City", text: $city)
                        .focused($focusedField, equals: .city)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .state
                        }
                        .onChange(of: city) { _, _ in
                            syncNormalizedAddress()
                        }
                    TextField("State", text: $state)
                        .focused($focusedField, equals: .state)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .zipCode
                        }
                        .textInputAutocapitalization(.characters)
                        .onChange(of: state) { _, newValue in
                            let filtered = newValue.uppercased().filter(\.isLetter)
                            let limited = String(filtered.prefix(2))
                            if limited != state {
                                state = limited
                            }
                            syncNormalizedAddress()
                        }
                    TextField("Zip Code", text: $zipCode)
                        .focused($focusedField, equals: .zipCode)
                        .submitLabel(.go)
                        .keyboardType(.numberPad)
                        .onSubmit {
                            if canSave {
                                submitProperty()
                            } else {
                                focusFirstInvalidField()
                            }
                        }
                        .onChange(of: zipCode) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            let limited = String(filtered.prefix(5))
                            if limited != zipCode {
                                zipCode = limited
                            }
                            syncNormalizedAddress()
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            syncSelectedOrganizationIfNeeded()
            applyInitialClientFocusIfNeeded()
        }
        .onChange(of: appState.organizations) { _, _ in
            syncSelectedOrganizationIfNeeded()
        }
        .alert("Add Organization", isPresented: $showAddOrganizationPrompt) {
            TextField("Organization Name", text: $newOrganizationName)
            Button("Save") {
                saveOrganization()
            }
            Button("Cancel", role: .cancel) {
                syncSelectedOrganizationIfNeeded()
            }
        } message: {
            Text("Enter the organization name.")
        }
        .alert("Unable to Save Property", isPresented: $showPropertyCreationError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(propertyCreationErrorMessage ?? "The property could not be saved.")
        }
    }

    private var organizationSelectionToken: Binding<String> {
        Binding(
            get: { selectedOrganizationID?.uuidString ?? appState.organizations.first?.id.uuidString ?? "" },
            set: { newValue in
                if newValue == addOrganizationToken {
                    showAddOrganizationPrompt = true
                    return
                }
                selectedOrganizationID = UUID(uuidString: newValue)
            }
        )
    }

    private var formattedAddress: String {
        let street = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let locality = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let postal = zipCode.trimmingCharacters(in: .whitespacesAndNewlines)

        let regionPostal = [region, postal]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [street, locality, regionPostal]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var addressForStorage: String {
        let normalized = normalizedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? formattedAddress : normalized
    }

    private var orderedFields: [Field] {
        Field.allCases
    }

    private var previousField: Field? {
        guard let focusedField else { return nil }
        guard let index = orderedFields.firstIndex(of: focusedField), index > 0 else { return nil }
        return orderedFields[index - 1]
    }

    private var nextField: Field? {
        guard let focusedField else { return orderedFields.first }
        guard let index = orderedFields.firstIndex(of: focusedField), index < orderedFields.count - 1 else { return nil }
        return orderedFields[index + 1]
    }

    private func moveFocusToPreviousField() {
        focusedField = previousField
    }

    private func moveFocusToNextField() {
        focusedField = nextField
    }

    private func applyInitialClientFocusIfNeeded() {
        guard !hasAppliedInitialFocus else { return }
        hasAppliedInitialFocus = true

        focusedField = .clientName

        // Modal and pushed presentations can race first responder assignment.
        // Re-apply once after presentation settles so keyboard appears consistently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if focusedField == nil {
                focusedField = .clientName
            }
        }
    }

    private func focusFirstInvalidField() {
        if propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .propertyName
            return
        }
        focusedField = .streetAddress
    }

    private func submitProperty() {
        guard canSave else {
            focusFirstInvalidField()
            return
        }
        guard let selectedOrganizationID else {
            propertyCreationErrorMessage = "Select an organization."
            showPropertyCreationError = true
            return
        }

        do {
            let created = try appState.createProperty(
                organizationID: selectedOrganizationID,
                clientName: clientName,
                propertyName: propertyName,
                address: addressForStorage,
                street: streetAddress,
                city: city,
                state: state,
                zip: zipCode,
                clientPhone: clientPhone
            )
            appState.selectProperty(id: created.id)
            dismiss()
        } catch {
            propertyCreationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showPropertyCreationError = true
        }
    }

    private func syncSelectedOrganizationIfNeeded() {
        if let selectedOrganizationID,
           appState.organizations.contains(where: { $0.id == selectedOrganizationID }) {
            return
        }
        selectedOrganizationID = appState.organizations.first?.id
    }

    private func saveOrganization() {
        let trimmedName = newOrganizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            syncSelectedOrganizationIfNeeded()
            return
        }
        if let organization = appState.createOrganization(name: trimmedName) {
            selectedOrganizationID = organization.id
        } else {
            syncSelectedOrganizationIfNeeded()
        }
        newOrganizationName = ""
    }

    @ViewBuilder
    private func autocompleteRow(
        _ completion: AddressAutocompleteModel.CompletionItem,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func selectPropertyNameCompletion(_ completion: AddressAutocompleteModel.CompletionItem) {
        Task { @MainActor in
            propertyName = completion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            propertyNameAutocomplete.clearResults()
            if let components = await propertyNameAutocomplete.resolve(completion: completion) {
                streetAddress = components.street
                city = components.city
                state = components.state
                zipCode = components.zip
                normalizedAddress = components.normalized
                addressAutocomplete.clearResults()
            }
            focusedField = nil
        }
    }

    private func selectAddressCompletion(_ completion: AddressAutocompleteModel.CompletionItem) {
        Task { @MainActor in
            guard let components = await addressAutocomplete.resolve(completion: completion) else { return }
            streetAddress = components.street
            city = components.city
            state = components.state
            zipCode = components.zip
            normalizedAddress = components.normalized
            addressAutocomplete.clearResults()
            focusedField = nil
        }
    }

    private func syncNormalizedAddress() {
        let normalized = normalizedAddressString(
            street: streetAddress,
            city: city,
            state: state,
            zip: zipCode
        )
        normalizedAddress = normalized
    }

    private func normalizedAddressString(street: String, city: String, state: String, zip: String) -> String {
        let trimmedStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedState = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedZip = zip.trimmingCharacters(in: .whitespacesAndNewlines)

        let stateZip = [trimmedState, trimmedZip]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [trimmedStreet, trimmedCity, stateZip]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
    
    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 42)
                .padding(.horizontal, 14)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct EditContactSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let property: Property

    @State private var selectedOrganizationID: UUID? = nil
    @State private var showAddOrganizationPrompt: Bool = false
    @State private var newOrganizationName: String = ""
    @State private var propertyName: String = ""
    @State private var clientName: String = ""
    @State private var streetAddress: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    @State private var phoneInput: String = ""
    @State private var showPendingExportRenameConfirm: Bool = false
    private let addOrganizationToken = "__add_new_organization__"

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }

    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }

    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    private var primaryButtonFill: Color { .blue }
    private var primaryButtonStroke: Color { .blue.opacity(0.85) }
    private var primaryButtonLabel: Color { .white }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Cancel", isEnabled: true) {
                    dismiss()
                }

                Spacer(minLength: 0)

                Text("Edit Property")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(buttonLabel)

                Spacer(minLength: 0)

                customCapsuleButton(
                    title: "Save",
                    isEnabled: true,
                    fill: primaryButtonFill,
                    stroke: primaryButtonStroke,
                    label: primaryButtonLabel
                ) {
                    saveChanges()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            Form {
                Section("Organization") {
                    Picker("Organization", selection: organizationSelectionToken) {
                        ForEach(appState.organizations) { organization in
                            Text(organization.name)
                                .tag(organization.id.uuidString)
                        }
                        Text("Add new organization")
                            .tag(addOrganizationToken)
                    }
                }

                Section("Primary Contact") {
                    TextField("Primary Contact Name", text: $clientName)
                        .textInputAutocapitalization(.words)

                    TextField("Phone (optional)", text: $phoneInput)
                        .keyboardType(.phonePad)
                        .onChange(of: phoneInput) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            let limited = String(digits.prefix(15))
                            let formatted = formatPhoneDisplay(limited)
                            if formatted != phoneInput {
                                phoneInput = formatted
                            }
                        }
                }

                Section("Property") {
                    TextField("Property name", text: $propertyName)
                        .textInputAutocapitalization(.words)

                    TextField("Address", text: $streetAddress)
                        .textInputAutocapitalization(.words)

                    TextField("City", text: $city)
                        .textInputAutocapitalization(.words)

                    TextField("State", text: $state)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: state) { _, newValue in
                            let filtered = newValue.uppercased().filter(\.isLetter)
                            let limited = String(filtered.prefix(2))
                            if limited != state {
                                state = limited
                            }
                        }

                    TextField("Zip Code", text: $zipCode)
                        .keyboardType(.numberPad)
                        .onChange(of: zipCode) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            let limited = String(filtered.prefix(5))
                            if limited != zipCode {
                                zipCode = limited
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            loadFromProperty()
        }
        .onChange(of: appState.organizations) { _, _ in
            syncSelectedOrganizationIfNeeded()
        }
        .alert("Add Organization", isPresented: $showAddOrganizationPrompt) {
            TextField("Organization Name", text: $newOrganizationName)
            Button("Save") {
                saveOrganization()
            }
            Button("Cancel", role: .cancel) {
                syncSelectedOrganizationIfNeeded()
            }
        } message: {
            Text("Enter the organization name.")
        }
        .alert("Rename Pending Export Property?", isPresented: $showPendingExportRenameConfirm) {
            Button("Continue") {
                persistChanges()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This property has pending exports. Export filenames will use the updated property name.")
        }
    }

    private var composedAddress: String {
        let trimmedStreet = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedState = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedZip = zipCode.trimmingCharacters(in: .whitespacesAndNewlines)

        let stateZip = [trimmedState, trimmedZip]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [trimmedStreet, trimmedCity, stateZip]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var organizationSelectionToken: Binding<String> {
        Binding(
            get: {
                selectedOrganizationID?.uuidString
                    ?? property.orgId?.uuidString
                    ?? appState.organizations.first?.id.uuidString
                    ?? ""
            },
            set: { newValue in
                if newValue == addOrganizationToken {
                    showAddOrganizationPrompt = true
                    return
                }
                selectedOrganizationID = UUID(uuidString: newValue)
            }
        )
    }

    private func saveChanges() {
        if shouldConfirmPendingExportRename() {
            showPendingExportRenameConfirm = true
            return
        }
        persistChanges()
    }

    private func persistChanges() {
        let digits = phoneInput.filter(\.isNumber)
        _ = appState.updatePropertyContact(
            id: property.id,
            organizationID: selectedOrganizationID,
            propertyName: propertyName,
            clientName: clientName,
            address: composedAddress,
            street: streetAddress,
            city: city,
            state: state,
            zip: zipCode,
            clientPhone: digits
        )
        dismiss()
    }

    private func shouldConfirmPendingExportRename() -> Bool {
        let trimmedOriginal = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUpdated = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUpdated.isEmpty, trimmedUpdated != trimmedOriginal else { return false }
        return appState.sessions(for: property.id).contains(where: { appState.isPendingDelivery($0) })
    }

    private func loadFromProperty() {
        syncSelectedOrganizationIfNeeded()
        selectedOrganizationID = property.orgId ?? appState.organizations.first?.id
        propertyName = property.name
        clientName = property.clientName ?? ""
        if property.street != nil || property.city != nil || property.state != nil || property.zip != nil {
            streetAddress = property.street ?? ""
            city = property.city ?? ""
            state = property.state ?? ""
            zipCode = property.zip ?? ""
        } else {
            let parsed = parseAddress(property.address)
            streetAddress = parsed.street
            city = parsed.city
            state = parsed.state
            zipCode = parsed.zip
        }
        phoneInput = formatPhoneDisplay((property.clientPhone ?? "").filter(\.isNumber))
    }

    private func syncSelectedOrganizationIfNeeded() {
        if let selectedOrganizationID,
           appState.organizations.contains(where: { $0.id == selectedOrganizationID }) {
            return
        }
        selectedOrganizationID = property.orgId ?? appState.organizations.first?.id
    }

    private func saveOrganization() {
        let trimmedName = newOrganizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            syncSelectedOrganizationIfNeeded()
            return
        }
        if let organization = appState.createOrganization(name: trimmedName) {
            selectedOrganizationID = organization.id
        } else {
            syncSelectedOrganizationIfNeeded()
        }
        newOrganizationName = ""
    }

    private func parseAddress(_ raw: String?) -> (street: String, city: String, state: String, zip: String) {
        let cleaned = (raw ?? "")
            .replacingOccurrences(of: ", United States", with: "", options: [.caseInsensitive, .anchored, .backwards], range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("", "", "", "") }

        let parts = cleaned
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let street = parts.first ?? ""
        let city = parts.count > 1 ? parts[1] : ""
        let stateZip = parts.count > 2 ? parts[2] : ""
        let tokens = stateZip.split(separator: " ").map(String.init)
        let state = tokens.first.map { String($0.uppercased().prefix(2)) } ?? ""
        let zip = tokens.dropFirst().joined(separator: "").filter(\.isNumber)
        return (street, city, state, String(zip.prefix(5)))
    }

    private func formatPhoneDisplay(_ digits: String) -> String {
        if digits.count <= 3 { return digits }
        if digits.count <= 6 {
            let area = digits.prefix(3)
            let rest = digits.dropFirst(3)
            return "(\(area)) \(rest)"
        }
        if digits.count <= 10 {
            let area = digits.prefix(3)
            let mid = digits.dropFirst(3).prefix(3)
            let end = digits.dropFirst(6)
            return "(\(area)) \(mid)-\(end)"
        }
        return digits
    }

    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 42)
                .padding(.horizontal, 14)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

@MainActor
private final class AddressAutocompleteModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    struct CompletionItem {
        let id: String
        let title: String
        let subtitle: String
        let completion: MKLocalSearchCompletion
    }

    @Published private(set) var completions: [CompletionItem] = []
    private let completer: MKLocalSearchCompleter
    private static var warmupRetainer: [AddressAutocompleteModel] = []

    init(resultTypes: MKLocalSearchCompleter.ResultType) {
        let completer = MKLocalSearchCompleter()
        completer.resultTypes = resultTypes
        self.completer = completer
        super.init()
        self.completer.delegate = self
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completions = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    func clearResults() {
        completions = []
    }

    func resolve(completion: CompletionItem) async -> AddressAutocompleteComponents? {
        let request = MKLocalSearch.Request(completion: completion.completion)
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let mapItem = response.mapItems.first else { return nil }
            return AddressAutocompleteComponents(mapItem: mapItem)
        } catch {
            return nil
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results.map { result in
            CompletionItem(
                id: "\(result.title)|\(result.subtitle)",
                title: result.title,
                subtitle: result.subtitle,
                completion: result
            )
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = []
    }

    static func prewarm() {
        guard warmupRetainer.isEmpty else { return }
        let propertyName = AddressAutocompleteModel(resultTypes: [.pointOfInterest, .address])
        let address = AddressAutocompleteModel(resultTypes: .address)
        propertyName.update(query: "")
        address.update(query: "")
        warmupRetainer = [propertyName, address]
    }
}

private enum AddPropertyWarmup {
    private static var didPrewarm = false

    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        DispatchQueue.main.async {
            AddressAutocompleteModel.prewarm()
        }
    }
}

private enum OptionalDetailNoteWarmup {
    private static var didPrewarm = false

    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        // Detail note sheet does not require heavy setup today.
        // Keep this as a no-op hook so it never blocks launch.
    }
}

private struct AddressAutocompleteComponents {
    let street: String
    let city: String
    let state: String
    let zip: String
    let normalized: String

    init(mapItem: MKMapItem) {
        let fullAddress = mapItem.address?.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortAddress = mapItem.address?.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawAddress = fullAddress.isEmpty ? shortAddress : fullAddress

        let lines = rawAddress
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallbackParts = rawAddress
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let streetCandidate = Self.extractStreet(from: rawAddress, lines: lines, fallbackParts: fallbackParts, mapItemName: mapItem.name)
        street = streetCandidate

        let contextLine = lines.dropFirst().first
            ?? mapItem.addressRepresentations?.cityWithContext
            ?? (fallbackParts.count > 1 ? fallbackParts[1] : "")
        let parsedCityState = Self.parseCityState(from: contextLine)
        let cityFromLine = parsedCityState.city.isEmpty && fallbackParts.count > 1 ? fallbackParts[1] : parsedCityState.city
        let stateFromLine = parsedCityState.state
        city = cityFromLine

        state = String(stateFromLine.uppercased().filter(\.isLetter).prefix(2))
        let postalCodeHint: String? = nil
        let extractedZip = Self.extractZip(from: rawAddress, postalCodeHint: postalCodeHint)
        zip = String(extractedZip.filter(\.isNumber).prefix(5))

        let stateZip = [state, zip]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        normalized = [street, city, stateZip]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func parseCityState(from text: String) -> (city: String, state: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        let parts = trimmed.split(separator: ",", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let city = parts.first ?? ""
        let rhs = parts.count > 1 ? parts[1] : ""
        let state = rhs
            .split(separator: " ")
            .map(String.init)
            .first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) ?? ""
        return (city, state)
    }

    private static func extractStreet(
        from rawAddress: String,
        lines: [String],
        fallbackParts: [String],
        mapItemName: String?
    ) -> String {
        let singleLine = lines.first ?? fallbackParts.first ?? rawAddress
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return completionSafeText(mapItemName)
        }

        if let firstComma = trimmed.firstIndex(of: ",") {
            let candidate = String(trimmed[..<firstComma]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"^(.+?),\s*[^,]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?(?:,\s*.*)?$"#) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range),
               match.numberOfRanges > 1,
               let streetRange = Range(match.range(at: 1), in: trimmed) {
                return String(trimmed[streetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }

    private static func extractZip(from text: String, postalCodeHint: String?) -> String {
        let hinted = (postalCodeHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !hinted.isEmpty {
            return hinted
        }

        if let stateZipRegex = try? NSRegularExpression(pattern: #"\b[A-Z]{2}\s+(\d{5}(?:-\d{4})?)\b"#) {
            let uppercaseText = text.uppercased()
            let range = NSRange(uppercaseText.startIndex..<uppercaseText.endIndex, in: uppercaseText)
            if let match = stateZipRegex.firstMatch(in: uppercaseText, options: [], range: range),
               match.numberOfRanges > 1,
               let zipRange = Range(match.range(at: 1), in: uppercaseText) {
                return String(uppercaseText[zipRange])
            }
        }

        guard let regex = try? NSRegularExpression(pattern: #"\b\d{5}(?:-\d{4})?\b"#) else {
            return ""
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard let match = matches.last,
              let zipRange = Range(match.range, in: text) else {
            return ""
        }
        return String(text[zipRange])
    }

    private static func completionSafeText(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PropertySessionsManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let property: Property

    @State private var sessions: [Session] = []
    @State private var deleteTarget: Session? = nil
    @State private var showPendingExportWarning: Bool = false
    @State private var showDeleteConfirm: Bool = false

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }

    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }

    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    private var destructiveFill: Color { Color.red.opacity(0.86) }
    private var destructiveStroke: Color { Color.red.opacity(0.90) }
    private var destructiveLabel: Color { .white }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Done", isEnabled: true) {
                    dismiss()
                }

                Spacer(minLength: 0)

                VStack(spacing: 2) {
                    Text("Manage Sessions")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(buttonLabel)
                    Text(property.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(buttonLabel.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                customCapsuleButton(title: "Refresh", isEnabled: true) {
                    reloadSessions()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "tray",
                    description: Text("No sessions found for this property.")
                )
            } else {
                List(sessions) { session in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.status == .draft ? "Draft Session" : "Completed Session")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            if appState.isPendingDelivery(session) {
                                Text("Pending Export")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                        }

                        Spacer(minLength: 0)

                        customCapsuleButton(
                            title: "Delete",
                            isEnabled: true,
                            fill: destructiveFill,
                            stroke: destructiveStroke,
                            label: destructiveLabel
                        ) {
                            handleDeleteTap(session)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            reloadSessions()
        }
        .alert("Pending Export Session", isPresented: $showPendingExportWarning) {
            Button("Continue") {
                showDeleteConfirm = true
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This completed session is pending export. Deleting it will permanently remove its local export state. Tap Continue to review deletion confirmation.")
        }
        .alert(deleteConfirmationTitle, isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var deleteConfirmationTitle: String {
        guard let target = deleteTarget else { return "Delete Session?" }
        if target.status == .draft {
            return "Delete Draft Session?"
        }
        return "Delete Completed Session?"
    }

    private var deleteConfirmationMessage: String {
        guard let target = deleteTarget else { return "This cannot be undone." }
        if target.status == .draft {
            return "This will permanently delete this draft session and its local records. This cannot be undone or recovered."
        }
        if appState.isPendingDelivery(target) {
            return "This session is pending export. Deleting it will permanently remove this session, its local records, and pending export state. This cannot be undone or recovered."
        }
        return "This will permanently delete this completed session and its local records. This cannot be undone or recovered."
    }

    private func reloadSessions() {
        sessions = appState.sessions(for: property.id).sorted { $0.startedAt > $1.startedAt }
    }

    private func handleDeleteTap(_ session: Session) {
        deleteTarget = session
        if appState.isPendingDelivery(session) {
            showPendingExportWarning = true
            return
        }
        showDeleteConfirm = true
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }
        _ = appState.deleteSession(propertyID: property.id, sessionID: target.id)
        deleteTarget = nil
        appState.refreshProperties()
        reloadSessions()
    }

    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 38)
                .padding(.horizontal, 12)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

#if DEBUG
private struct DebugToolsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let localStore = LocalStore()
    @State private var showNuclearConfirm: Bool = false
    @State private var showClearCacheConfirm: Bool = false

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }

    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }

    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Done", isEnabled: true) {
                    dismiss()
                }
                Spacer(minLength: 0)
                Text("Debug Tools")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(buttonLabel)
                Spacer(minLength: 0)
                Color.clear.frame(width: 72, height: 42)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            ScrollView {
                VStack(spacing: 14) {
                    debugActionCard(
                        title: "Nuclear Reset (Local Only)",
                        detail: "Wipes all local app data: properties, sessions, guided, observations, references, and indexes. Does NOT modify iCloud Drive library data.",
                        role: .destructive
                    ) {
                        showNuclearConfirm = true
                    }

                    debugActionCard(
                        title: "Clear Local Index / UI Cache (Local Only)",
                        detail: "Clears in-memory image/UI caches and reloads thumbnails from local SCOUT files. Does NOT delete Originals, Stamped, session.json, or iCloud Drive data.",
                        role: .normal
                    ) {
                        showClearCacheConfirm = true
                    }

                    debugActionCard(
                        title: "Print Metadata Schema",
                        detail: "Prints SessionMetadata and ShotMetadata field names to the Xcode console.",
                        role: .normal,
                        buttonTitle: "Print Metadata Schema"
                    ) {
                        localStore.printSessionSchema()
                    }

                    debugActionCard(
                        title: "Verify session.json source",
                        detail: "Prints on-disk session.json path, existence, size, schemaVersion, shot count, and shotKey/originalRelativePath presence.",
                        role: .normal,
                        buttonTitle: "Verify session.json source"
                    ) {
                        verifySessionJSONSource()
                    }

                    debugActionCard(
                        title: "Verify export session.json source",
                        detail: "Prints export session.json source path and key presence checks used by export.",
                        role: .normal,
                        buttonTitle: "Verify export source"
                    ) {
                        verifyExportSessionJSONSource()
                    }
                }
                .padding(14)
            }
        }
        .alert("Nuclear Reset (Local Only)?", isPresented: $showNuclearConfirm) {
            Button("Reset", role: .destructive) {
                appState.nuclearResetLocalOnly()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently erase all local app data and cannot be recovered. iCloud Drive library data will not be touched.")
        }
        .alert("Clear Local Index / UI Cache?", isPresented: $showClearCacheConfirm) {
            Button("Clear") {
                appState.clearLocalCacheOnly()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears local UI/image cache only and reloads from local SCOUT storage. It does not delete Originals, Stamped, session.json, or iCloud Drive data.")
        }
    }

    private enum DebugRole {
        case normal
        case destructive
    }

    @ViewBuilder
    private func debugActionCard(
        title: String,
        detail: String,
        role: DebugRole,
        buttonTitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let fill = role == .destructive ? Color.red.opacity(0.86) : buttonFill
        let stroke = role == .destructive ? Color.red.opacity(0.90) : buttonStroke
        let label = role == .destructive ? Color.white : buttonLabel
        let resolvedButtonTitle = buttonTitle ?? (role == .destructive ? "Run Nuclear Reset" : "Clear Cache")

        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            customCapsuleButton(
                title: resolvedButtonTitle,
                isEnabled: true,
                fill: fill,
                stroke: stroke,
                label: label,
                action: action
            )
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 38)
                .padding(.horizontal, 12)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func verifySessionJSONSource() {
        guard let propertyID = appState.selectedPropertyID,
              let sessionID = appState.currentSession?.id else {
            print("Verify session.json source: missing selected property or current session.")
            return
        }

        let url = localStore.sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let sizeBytes: Int = {
            guard exists,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.intValue
        }()

        print("Expected session.json path: \(url.path)")
        print("File exists: \(exists ? "YES" : "NO")")
        print("File size bytes: \(sizeBytes)")

        guard exists, let data = try? Data(contentsOf: url) else {
            print("Unable to read session.json data.")
            return
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        print("Raw contains \"\\\"shotKey\\\"\": \(raw.contains("\"shotKey\"") ? "YES" : "NO")")
        print("Raw contains \"\\\"originalRelativePath\\\"\": \(raw.contains("\"originalRelativePath\"") ? "YES" : "NO")")

        do {
            let metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            print("schemaVersion: \(metadata.schemaVersion)")
            print("shots count: \(metadata.shots.count)")
            if let first = metadata.shots.first {
                print("first shot shotKey: \(first.shotKey)")
                print("first shot originalRelativePath: \(first.originalRelativePath)")
            }
        } catch {
            print("Decode failed: \(error)")
        }
    }

    private func verifyExportSessionJSONSource() {
        guard let propertyID = appState.selectedPropertyID,
              let sessionID = appState.currentSession?.id else {
            print("Verify export session.json source: missing selected property or current session.")
            return
        }

        let url = localStore.sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let sizeBytes: Int = {
            guard exists,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.intValue
        }()
        print("Export session.json path source: \(url.path)")
        print("Export source exists: \(exists ? "YES" : "NO")")
        print("Export source size bytes: \(sizeBytes)")

        guard exists, let data = try? Data(contentsOf: url) else {
            print("Export source read failed.")
            return
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        print("Export raw contains \"shotKey\": \(raw.contains("\"shotKey\"") ? "YES" : "NO")")
        print("Export raw contains \"originalRelativePath\": \(raw.contains("\"originalRelativePath\"") ? "YES" : "NO")")

        do {
            let metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            if let first = metadata.shots.first {
                print("Export first shot shotKey: \(first.shotKey)")
                print("Export first shot originalRelativePath: \(first.originalRelativePath)")
            } else {
                print("Export first shot: none")
            }
        } catch {
            print("Export source decode failed: \(error)")
        }
    }
}
#endif

struct PropertySessionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let propertyID: UUID
    let resumeDraft: Bool

    @State private var didSetup: Bool = false
    @State private var showCameraContent: Bool = false
    @State private var showOpenCameraTimeout: Bool = false
    @State private var didStartOpenFlow: Bool = false
    @State private var openFlowToken: Int = 0

    private let camera = CameraManager.shared
    private let timeoutSeconds: Double = 4.0

    var body: some View {
        ZStack {
            if showCameraContent {
                ContentView(onExitToHub: {
                    dismiss()
                })
                .transition(.opacity)
            } else {
                openingCameraInterstitial
                    .transition(.opacity)
            }
        }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .onReceive(camera.$isPreviewRunning.removeDuplicates()) { isRunning in
                if isRunning {
                    completeOpenFlow()
                }
            }
            .onAppear {
                guard !didSetup else { return }
                didSetup = true
                appState.selectProperty(id: propertyID)
                if resumeDraft {
                    if appState.currentSession?.propertyID != propertyID || appState.currentSession?.status != .draft {
                        _ = appState.loadDraftSession(for: propertyID)
                    }
                } else {
                    _ = appState.startSession()
                }
                beginOpenFlow()
            }
    }

    @ViewBuilder
    private var openingCameraInterstitial: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 14) {
                if showOpenCameraTimeout {
                    Text("Unable to open camera")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text("Please try again or go back.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.86))

                    HStack(spacing: 10) {
                        Button {
                            beginOpenFlow(forceRetry: true)
                        } label: {
                            Text("Retry")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            dismiss()
                        } label: {
                            Text("Back")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Opening camera...")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 360)
            .background(Color.black.opacity(0.80))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
    }

    private func beginOpenFlow(forceRetry: Bool = false) {
        if !forceRetry, didStartOpenFlow { return }
        didStartOpenFlow = true
        showOpenCameraTimeout = false
        openFlowToken += 1
        let token = openFlowToken

        camera.prepareForPreviewAsync()
        camera.ensurePreviewRunningAsync()

        if camera.isPreviewRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                guard token == openFlowToken else { return }
                completeOpenFlow()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            guard token == openFlowToken else { return }
            guard !camera.isPreviewRunning else {
                completeOpenFlow()
                return
            }
            showOpenCameraTimeout = true
        }
    }

    private func completeOpenFlow() {
        guard !showCameraContent else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            showCameraContent = true
        }
    }
}
