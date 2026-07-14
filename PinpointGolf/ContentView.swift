import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import ContactsUI
import MessageUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var roundArchive = RoundArchive()
    @StateObject private var playerSettings = PlayerSettings()
    @StateObject private var courseFavorites = CourseFavorites()
    @StateObject private var goalArchive = GoalArchive()
    @StateObject private var clubYardages = ClubYardageStore()
    @StateObject private var handicapHistory = HandicapHistoryStore()
    @StateObject private var scorecardStore = CourseScorecardStore()
    @StateObject private var firebaseAccount = FirebaseAccountService()
    @StateObject private var firebaseSocial = FirebaseSocialService()
    @StateObject private var firebaseRoundSync = FirebaseRoundSyncService()
    @StateObject private var websiteSeasonSync = WebsiteSeasonSyncService()
    @AppStorage("pinpoint.profileImageData") private var profileImageData: Data = Data()
    @AppStorage("precision.profileName") private var profileName = ""
    @AppStorage("precision.profileHomeClub") private var profileHomeClub = ""
    @AppStorage("precision.profileOnboardingComplete") private var profileOnboardingComplete = false
    @AppStorage("precision.appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage("precision.seenSocialActivity") private var seenSocialActivitySignature = ""
    @State private var selectedTab: Tab = .home
    @State private var selectedCourse = CourseDatabase.courses[0]
    @State private var selectedTee = CourseDatabase.courses[0].tees[0]
    @State private var isRoundActive = false
    @State private var isRoundFlowPresented = false
    @State private var isRoundReviewPresented = false
    @State private var currentHoleIndex = 0
    @State private var roundHandicap = 0.0
    @State private var pendingSharedRoundId: String?
    @State private var pendingRoundType: NewRoundGameType = .individual
    @State private var pendingMatchplayFriend: FirebaseFriendProfile?
    @State private var pendingStablefordGroup: FirebaseGolfGroup?
    @State private var sideMatch = MatchplaySideGame()
    @State private var didRestoreCloudDataForCurrentUser = false
    @State private var allowSignedOutOfflineMode = false
    @State private var entries = DemoData.holes.map {
        ContentView.defaultEntry(for: $0)
    }
    private let activeRoundDraftKey = "pinpoint.activeRoundDraft"

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            if firebaseAccount.user == nil && profileOnboardingComplete && !allowSignedOutOfflineMode {
                SignedOutAccountView(account: firebaseAccount) {
                    allowSignedOutOfflineMode = true
                }
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    TabBar(selectedTab: $selectedTab)
                }
            }
        }
        .preferredColorScheme(AppearanceMode(rawValue: appearanceMode)?.colorScheme)
        .fullScreenCover(isPresented: $isRoundFlowPresented) {
            roundFlow
        }
        .sheet(isPresented: onboardingBinding) {
            ProfileOnboardingView(
                profileName: $profileName,
                profileHomeClub: $profileHomeClub,
                playerSettings: playerSettings,
                firebaseAccount: firebaseAccount,
                complete: {
                    profileOnboardingComplete = true
                }
            )
            .interactiveDismissDisabled()
        }
        .onAppear {
            restoreActiveRoundDraft()
            Task {
                await PushNotificationService.shared.requestPermissionAndRegister()
                await restoreAndSyncCloudDataIfNeeded(force: false)
                await firebaseSocial.refresh()
                await websiteSeasonSync.retryPendingSync()
            }
        }
        .onChange(of: firebaseAccount.user?.uid) { _, uid in
            Task {
                if uid == nil {
                    didRestoreCloudDataForCurrentUser = false
                    allowSignedOutOfflineMode = false
                    await firebaseRoundSync.refreshCloudCount()
                    await firebaseSocial.refresh()
                } else {
                    didRestoreCloudDataForCurrentUser = false
                    allowSignedOutOfflineMode = false
                    await restoreAndSyncCloudDataIfNeeded(force: true)
                    await firebaseSocial.refresh()
                    await firebaseRoundSync.sync(rounds: roundArchive.rounds)
                    await websiteSeasonSync.sync(backup: makePrecisionBackup())
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .precisionOpenSharedRound)) { notification in
            guard let roundId = notification.userInfo?["sharedRoundId"] as? String else { return }
            pendingSharedRoundId = roundId
            selectedTab = .friends
        }
        .onReceive(NotificationCenter.default.publisher(for: .precisionOpenFriends)) { _ in
            selectedTab = .friends
            Task {
                await firebaseSocial.refresh()
            }
        }
        .onChange(of: entries) { _, _ in
            saveActiveRoundDraft()
        }
        .onChange(of: currentHoleIndex) { _, _ in
            saveActiveRoundDraft()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                saveActiveRoundDraft()
                Task {
                    await syncCloudAppData()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .home:
                HomeView(
                    savedRounds: roundArchive.rounds,
                    entries: entries,
                    recentRounds: recentRounds,
                    handicapHistory: handicapHistory.records,
                    isRoundActive: isRoundActive,
                    currentHandicap: playerSettings.handicap,
                    profileName: profileName,
                    profileHomeClub: profileHomeClub,
                    profileImageData: $profileImageData,
                    notificationCount: socialActivitySignature == seenSocialActivitySignature ? 0 : firebaseSocial.notifications.count + firebaseSocial.incomingRequests.count + firebaseSocial.groupInvites.count,
                    openNotifications: {
                        seenSocialActivitySignature = socialActivitySignature
                        selectedTab = .friends
                        Task { await firebaseSocial.refresh() }
                    },
                    openAllRounds: {
                        selectedTab = .insights
                    },
                    startRound: {
                        openRoundFlow()
                    },
                    discardRound: discardCurrentRound,
                    deleteRound: deleteSavedRound,
                    updateRound: updateSavedRound
                )
        case .yardages:
            YardagesView(store: clubYardages)
        case .insights:
            RecentRoundsView(
                savedRounds: roundArchive.rounds,
                currentHandicap: playerSettings.handicap,
                startRound: openRoundFlow,
                deleteRound: deleteSavedRound,
                updateRound: updateSavedRound
            )
        case .goals:
            GoalsView(savedRounds: roundArchive.rounds, goalArchive: goalArchive)
        case .friends:
            FriendsView(
                account: firebaseAccount,
                social: firebaseSocial,
                openSharedRoundId: $pendingSharedRoundId
            )
        case .settings:
            SettingsView(
                playerSettings: playerSettings,
                savedRounds: roundArchive.rounds,
                roundArchive: roundArchive,
                courseFavorites: courseFavorites,
                goalArchive: goalArchive,
                clubYardages: clubYardages,
                handicapHistory: handicapHistory,
                scorecardStore: scorecardStore,
                firebaseAccount: firebaseAccount,
                firebaseSocial: firebaseSocial,
                firebaseRoundSync: firebaseRoundSync,
                profileName: $profileName,
                profileHomeClub: $profileHomeClub
            )
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !profileOnboardingComplete },
            set: { isPresented in
                if !isPresented {
                    profileOnboardingComplete = true
                }
            }
        )
    }

    private var socialActivitySignature: String {
        let ids = firebaseSocial.notifications.map(\.id)
            + firebaseSocial.incomingRequests.map(\.id)
            + firebaseSocial.groupInvites.map(\.id)
        return ids.sorted().joined(separator: "|")
    }

    @MainActor
    private func restoreAndSyncCloudDataIfNeeded(force: Bool) async {
        guard firebaseAccount.user != nil else { return }
        if didRestoreCloudDataForCurrentUser && !force {
            await firebaseRoundSync.refreshCloudCount()
            return
        }

        didRestoreCloudDataForCurrentUser = true

        async let cloudRoundsResult = firebaseRoundSync.restoreRounds()
        async let cloudAppDataResult = firebaseRoundSync.restoreAppData()

        if let cloudRounds = await cloudRoundsResult {
            mergeCloudRounds(cloudRounds)
        }

        if let cloudAppData = await cloudAppDataResult {
            applyCloudAppData(cloudAppData)
        }

        await firebaseRoundSync.sync(rounds: roundArchive.rounds)
        await syncCloudAppData()
    }

    @MainActor
    private func mergeCloudRounds(_ cloudRounds: [SavedRound]) {
        guard !cloudRounds.isEmpty else { return }

        var mergedByID = Dictionary(uniqueKeysWithValues: cloudRounds.map { ($0.id, $0) })
        for localRound in roundArchive.rounds {
            mergedByID[localRound.id] = localRound
        }

        roundArchive.replace(with: Array(mergedByID.values))
    }

    @MainActor
    private func applyCloudAppData(_ cloudData: PrecisionCloudAppData) {
        playerSettings.replaceHandicap(cloudData.handicap)

        let mergedFavorites = courseFavorites.favoriteKeys.union(Set(cloudData.favoriteCourseKeys))
        courseFavorites.replace(with: mergedFavorites)

        let mergedGoals = mergeCustomGoals(local: goalArchive.customGoals, cloud: cloudData.customGoals)
        goalArchive.replace(with: mergedGoals)

        if !cloudData.clubYardages.isEmpty {
            clubYardages.replace(with: mergeClubYardages(local: clubYardages.clubs, cloud: cloudData.clubYardages))
        }

        let mergedHandicapHistory = mergeHandicapHistory(local: handicapHistory.records, cloud: cloudData.handicapHistory)
        handicapHistory.replace(with: mergedHandicapHistory)

        let mergedScorecards = mergeScorecards(local: scorecardStore.overrides, cloud: cloudData.courseScorecards)
        scorecardStore.replace(with: mergedScorecards)
    }

    private func mergeCustomGoals(local: [CustomGoal], cloud: [CustomGoal]) -> [CustomGoal] {
        var merged = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        for goal in local {
            if let cloudGoal = merged[goal.id] {
                merged[goal.id] = CustomGoal(
                    id: goal.id,
                    title: goal.title.isEmpty ? cloudGoal.title : goal.title,
                    isComplete: goal.isComplete || cloudGoal.isComplete,
                    createdAt: min(goal.createdAt, cloudGoal.createdAt)
                )
            } else {
                merged[goal.id] = goal
            }
        }
        return Array(merged.values).sorted { $0.createdAt > $1.createdAt }
    }

    private func mergeClubYardages(local: [ClubYardage], cloud: [ClubYardage]) -> [ClubYardage] {
        var merged = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        for club in local {
            if club.yards != nil || club.isInBag {
                merged[club.id] = club
            }
        }
        return Array(merged.values)
    }

    private func mergeHandicapHistory(local: [HandicapRecord], cloud: [HandicapRecord]) -> [HandicapRecord] {
        var recordsByID = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        for record in local {
            recordsByID[record.id] = record
        }
        return Array(recordsByID.values).sorted { $0.date > $1.date }
    }

    private func mergeScorecards(local: [CourseScorecardOverride], cloud: [CourseScorecardOverride]) -> [CourseScorecardOverride] {
        var scorecardsByKey = Dictionary(uniqueKeysWithValues: cloud.map { ($0.courseKey, $0) })
        for scorecard in local {
            if let cloudScorecard = scorecardsByKey[scorecard.courseKey],
               cloudScorecard.updatedAt > scorecard.updatedAt {
                continue
            }
            scorecardsByKey[scorecard.courseKey] = scorecard
        }
        return Array(scorecardsByKey.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func syncCloudAppData() async {
        guard firebaseAccount.user != nil else { return }
        await firebaseRoundSync.syncAppData(makeCloudAppData())
    }

    private func makeCloudAppData() -> PrecisionCloudAppData {
        PrecisionCloudAppData(
            version: 1,
            updatedAt: Date(),
            handicap: playerSettings.handicap,
            favoriteCourseKeys: Array(courseFavorites.favoriteKeys).sorted(),
            customGoals: goalArchive.customGoals,
            clubYardages: clubYardages.clubs,
            handicapHistory: handicapHistory.records,
            courseScorecards: scorecardStore.overrides
        )
    }

    private func beginRound() {
        currentHoleIndex = 0
        entries = selectedTee.holes.map {
            Self.defaultEntry(for: $0)
        }
        sideMatch = MatchplaySideGame()
        isRoundActive = true
        isRoundFlowPresented = true
        saveActiveRoundDraft()
        startSelectedRoundGame()
    }

    private func finishRound() {
        isRoundReviewPresented = true
    }

    private func saveReviewedRound() {
        let savedRound = roundArchive.save(course: selectedCourse, tee: selectedTee, handicap: roundHandicap, entries: entries)
        let sharedGroupIds = pendingRoundType == .groupStableford ? [pendingStablefordGroup?.id].compactMap { $0 } : []
        handicapHistory.record(roundHandicap)
        let websiteBackup = makePrecisionBackup()
        Task {
            await firebaseRoundSync.sync(round: savedRound)
            await syncCloudAppData()
            await firebaseSocial.publishCompletedRound(savedRound, ownerProfile: firebaseAccount.profile, groupIds: sharedGroupIds)
            await firebaseSocial.finishMatchplayRound(course: selectedCourse, tee: selectedTee, entries: entries)
            await websiteSeasonSync.sync(backup: websiteBackup)
        }
        isRoundActive = false
        isRoundFlowPresented = false
        isRoundReviewPresented = false
        currentHoleIndex = 0
        sideMatch = MatchplaySideGame()
        resetPendingRoundGame()
        selectedTab = .home
        clearActiveRoundDraft()
    }

    private func updateSavedRound(_ round: SavedRound) {
        roundArchive.update(round)
        let websiteBackup = makePrecisionBackup()
        Task {
            await firebaseRoundSync.sync(round: round)
            await websiteSeasonSync.sync(backup: websiteBackup)
            await syncCloudAppData()
        }
    }

    private func makePrecisionBackup() -> PrecisionBackup {
        PrecisionBackup(
            version: 1,
            exportedAt: Date(),
            handicap: playerSettings.handicap,
            rounds: roundArchive.rounds,
            favoriteCourseKeys: Array(courseFavorites.favoriteKeys).sorted(),
            customGoals: goalArchive.customGoals,
            clubYardages: clubYardages.clubs,
            handicapHistory: handicapHistory.records,
            courseScorecards: scorecardStore.overrides
        )
    }

    private func deleteSavedRound(_ round: SavedRound) {
        roundArchive.delete(roundID: round.id)
        Task {
            await firebaseRoundSync.delete(roundID: round.id)
            await syncCloudAppData()
        }
    }

    private func openRoundFlow() {
        if !isRoundActive {
            roundHandicap = playerSettings.handicap
        }
        isRoundFlowPresented = true
    }

    private func discardCurrentRound() {
        isRoundActive = false
        isRoundFlowPresented = false
        currentHoleIndex = 0
        entries = selectedTee.holes.map {
            Self.defaultEntry(for: $0)
        }
        sideMatch = MatchplaySideGame()
        resetPendingRoundGame()
        selectedTab = .home
        clearActiveRoundDraft()
    }

    private func startSelectedRoundGame() {
        switch pendingRoundType {
        case .individual:
            break
        case .matchplay:
            guard let friend = pendingMatchplayFriend else { return }
            Task {
                await firebaseSocial.startMatchplay(
                    with: friend,
                    course: selectedCourse,
                    tee: selectedTee,
                    playerProfile: firebaseAccount.profile,
                    courseHandicap: currentCourseHandicap
                )
            }
        case .groupStableford:
            guard let group = pendingStablefordGroup else { return }
            Task {
                await firebaseSocial.createStablefordGame(for: group)
            }
        }
    }

    private func resetPendingRoundGame() {
        pendingRoundType = .individual
        pendingMatchplayFriend = nil
        pendingStablefordGroup = nil
    }

    private var currentCourseHandicap: Int {
        let adjusted = (roundHandicap * Double(selectedTee.slope) / 113.0) + (selectedTee.rating - Double(selectedTee.par))
        return max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
    }

    private var recentRounds: [RoundSummary] {
        Array(roundArchive.roundSummaries.prefix(6))
    }

    private static func defaultEntry(for hole: Hole) -> RoundHoleEntry {
        RoundHoleEntry(
            hole: hole,
            score: 0,
            putts: 0,
            pickedUp: false,
            fairway: .notTracked,
            green: .notTracked,
            teeClub: hole.par == 3 ? .iron : .driver,
            approachRange: hole.yards < 350 ? .yards100to150 : .yards150to200,
            approachProximity: nil,
            firstPuttDistance: .feet10to20,
            penalties: 0,
            penaltyType: .none,
            bunker: false,
            upAndDown: false,
            sandSave: false,
            recovery: false,
            note: ""
        )
    }

    private func saveActiveRoundDraft() {
        guard isRoundActive else { return }

        let draft = ActiveRoundDraft(
            courseKey: selectedCourse.favoriteKey,
            teeName: selectedTee.name,
            handicap: roundHandicap,
            currentHoleIndex: currentHoleIndex,
            entries: entries.map { ActiveRoundHoleDraft(entry: $0) }
        )

        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: activeRoundDraftKey)
        }
    }

    private func restoreActiveRoundDraft() {
        guard !isRoundActive,
              let data = UserDefaults.standard.data(forKey: activeRoundDraftKey),
              let draft = try? JSONDecoder().decode(ActiveRoundDraft.self, from: data),
              let course = availableCourses.first(where: { $0.favoriteKey == draft.courseKey }),
              let tee = course.tees.first(where: { $0.name == draft.teeName })
        else {
            return
        }

        selectedCourse = course
        selectedTee = tee
        roundHandicap = draft.handicap ?? playerSettings.handicap
        entries = tee.holes.map { hole in
            if let draftEntry = draft.entries.first(where: { $0.holeNumber == hole.number }) {
                return draftEntry.roundEntry(for: hole)
            }
            return Self.defaultEntry(for: hole)
        }
        currentHoleIndex = min(max(0, draft.currentHoleIndex), max(0, entries.count - 1))
        isRoundActive = true
        isRoundFlowPresented = false
        selectedTab = .home
    }

    private func clearActiveRoundDraft() {
        UserDefaults.standard.removeObject(forKey: activeRoundDraftKey)
    }

    private var availableCourses: [GolfCourse] {
        scorecardStore.courses(from: CourseDatabase.courses)
    }

    private func refreshSelectedCourseFromOverrides() {
        guard let updatedCourse = availableCourses.first(where: { $0.favoriteKey == selectedCourse.favoriteKey }) else { return }
        selectedCourse = updatedCourse
        if let updatedTee = updatedCourse.tees.first(where: { $0.name == selectedTee.name }) {
            selectedTee = updatedTee
        } else if let firstTee = updatedCourse.tees.first {
            selectedTee = firstTee
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct ActiveRoundDraft: Codable {
    let courseKey: String
    let teeName: String
    let handicap: Double?
    let currentHoleIndex: Int
    let entries: [ActiveRoundHoleDraft]
}

private struct ActiveRoundHoleDraft: Codable {
    let holeNumber: Int
    let score: Int
    let putts: Int
    let pickedUp: Bool
    let fairway: MissDirection
    let green: MissDirection
    let teeClub: TeeClub
    let approachRange: ApproachRange
    let approachProximity: ApproachProximity?
    let firstPuttDistance: FirstPuttDistance
    let penalties: Int
    let penaltyType: PenaltyType
    let bunker: Bool
    let upAndDown: Bool
    let sandSave: Bool
    let recovery: Bool
    let note: String

    enum CodingKeys: String, CodingKey {
        case holeNumber
        case score
        case putts
        case pickedUp
        case fairway
        case green
        case teeClub
        case approachRange
        case approachProximity
        case firstPuttDistance
        case penalties
        case penaltyType
        case bunker
        case upAndDown
        case sandSave
        case recovery
        case note
    }

    init(entry: RoundHoleEntry) {
        holeNumber = entry.hole.number
        score = entry.score
        putts = entry.putts
        pickedUp = entry.pickedUp
        fairway = entry.fairway
        green = entry.green
        teeClub = entry.teeClub
        approachRange = entry.approachRange
        approachProximity = entry.approachProximity
        firstPuttDistance = entry.firstPuttDistance
        penalties = entry.penalties
        penaltyType = entry.penaltyType
        bunker = entry.bunker
        upAndDown = entry.upAndDown
        sandSave = entry.sandSave
        recovery = entry.recovery
        note = entry.note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        holeNumber = try container.decode(Int.self, forKey: .holeNumber)
        score = try container.decode(Int.self, forKey: .score)
        putts = try container.decode(Int.self, forKey: .putts)
        pickedUp = try container.decodeIfPresent(Bool.self, forKey: .pickedUp) ?? false
        fairway = try container.decode(MissDirection.self, forKey: .fairway)
        green = try container.decode(MissDirection.self, forKey: .green)
        teeClub = try container.decode(TeeClub.self, forKey: .teeClub)
        approachRange = try container.decode(ApproachRange.self, forKey: .approachRange)
        approachProximity = try container.decodeIfPresent(ApproachProximity.self, forKey: .approachProximity)
        firstPuttDistance = try container.decode(FirstPuttDistance.self, forKey: .firstPuttDistance)
        penalties = try container.decode(Int.self, forKey: .penalties)
        penaltyType = try container.decode(PenaltyType.self, forKey: .penaltyType)
        bunker = try container.decode(Bool.self, forKey: .bunker)
        upAndDown = try container.decode(Bool.self, forKey: .upAndDown)
        sandSave = try container.decode(Bool.self, forKey: .sandSave)
        recovery = try container.decode(Bool.self, forKey: .recovery)
        note = try container.decode(String.self, forKey: .note)
    }

    func roundEntry(for hole: Hole) -> RoundHoleEntry {
        RoundHoleEntry(
            hole: hole,
            score: score,
            putts: putts,
            pickedUp: pickedUp,
            fairway: fairway,
            green: green,
            teeClub: teeClub,
            approachRange: approachRange,
            approachProximity: green == .hit ? approachProximity : nil,
            firstPuttDistance: firstPuttDistance,
            penalties: penalties,
            penaltyType: penaltyType,
            bunker: bunker,
            upAndDown: upAndDown,
            sandSave: sandSave,
            recovery: recovery,
            note: note
        )
    }
}

extension ContentView {
    var roundFlow: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                if isRoundActive {
                    LiveRoundView(
                        selectedCourse: selectedCourse,
                        selectedTee: selectedTee,
                        currentHoleIndex: $currentHoleIndex,
                        entries: $entries,
                        handicap: roundHandicap,
                        friends: firebaseSocial.friends,
                        firebaseSocial: firebaseSocial,
                        currentUserId: firebaseAccount.user?.uid,
                        playerProfile: firebaseAccount.profile,
                        roundGameType: pendingRoundType,
                        sideMatch: $sideMatch,
                        finishRound: finishRound,
                        discardRound: discardCurrentRound
                    )
                } else {
                    NewRoundSetupView(
                        selectedCourse: $selectedCourse,
                        selectedTee: $selectedTee,
                        roundHandicap: $roundHandicap,
                        courseFavorites: courseFavorites,
                        scorecardStore: scorecardStore,
                        firebaseSocial: firebaseSocial,
                        selectedGameType: $pendingRoundType,
                        selectedMatchplayFriend: $pendingMatchplayFriend,
                        selectedStablefordGroup: $pendingStablefordGroup,
                        courses: availableCourses,
                        refreshSelectedCourse: refreshSelectedCourseFromOverrides
                    ) {
                        beginRound()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        isRoundFlowPresented = false
                    }
                    .foregroundStyle(AppTheme.mint)
                }
            }
            .sheet(isPresented: $isRoundReviewPresented) {
                RoundReviewView(
                    course: selectedCourse,
                    tee: selectedTee,
                    handicap: roundHandicap,
                    entries: entries,
                    saveRound: saveReviewedRound
                )
            }
        }
    }
}

struct SignedOutAccountView: View {
    @ObservedObject var account: FirebaseAccountService
    let continueOffline: () -> Void
    @State private var showEmailForm = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                loginBackground
                    .blur(radius: 3)
                    .scaleEffect(1.04)

                LinearGradient(
                    colors: [
                        Color(red: 0.0, green: 0.08, blue: 0.05).opacity(0.82),
                        Color(red: 0.0, green: 0.12, blue: 0.08).opacity(0.78),
                        Color.black.opacity(0.9)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: max(76, proxy.safeAreaInsets.top + 52))

                    VStack(spacing: 18) {
                        VStack(spacing: 10) {
                            Text("PRECISION GOLF")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .tracking(4)
                                .foregroundStyle(.white.opacity(0.92))

                            Text("Welcome back")
                                .font(.system(size: 32, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.38), radius: 12, x: 0, y: 6)

                            Text("Sign in to continue tracking and improving\nyour golf game.")
                                .font(.system(size: 18, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }

                        VStack(spacing: 14) {
                            BrandedLoginButton(
                                title: "Sign in with Email",
                                systemImage: "envelope.fill",
                                style: .outline
                            ) {
                                showEmailForm = true
                            }
                            .disabled(account.isWorking)

                            BrandedLoginButton(
                                title: "Sign in with Google",
                                customIcon: "G",
                                style: .light
                            ) {
                                Task {
                                    await account.signInWithGoogle()
                                }
                            }
                            .disabled(account.isWorking)

                            BrandedLoginButton(
                                title: "Sign in with Apple",
                                systemImage: "apple.logo",
                                style: .black
                            ) {
                                Task {
                                    await account.signInWithApple()
                                }
                            }
                            .disabled(account.isWorking)
                        }

                        if account.isWorking {
                            ProgressView()
                                .tint(.white)
                                .padding(.top, 2)
                        }

                        if let status = account.statusMessage {
                            Text(status)
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(status.localizedCaseInsensitiveContains("error") ? Color(red: 1.0, green: 0.42, blue: 0.42) : .white.opacity(0.78))
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .padding(.horizontal, 10)
                        }

                        HStack(spacing: 16) {
                            Rectangle()
                                .fill(.white.opacity(0.22))
                                .frame(height: 1)
                            Text("OR")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Rectangle()
                                .fill(.white.opacity(0.22))
                                .frame(height: 1)
                        }
                        .padding(.top, 4)

                        HStack(spacing: 5) {
                            Text("Don't have an account?")
                                .foregroundStyle(.white.opacity(0.76))
                            Button("Create account") {
                                showEmailForm = true
                            }
                            .foregroundStyle(Color(red: 0.56, green: 0.84, blue: 0.18))
                        }
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .buttonStyle(.plain)

                        Button {
                            continueOffline()
                        } label: {
                            Text("Use offline mode")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    .padding(22)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.0, green: 0.08, blue: 0.05).opacity(0.86))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.44), radius: 24, x: 0, y: 14)
                    .padding(.horizontal, 22)
                    .padding(.bottom, max(28, proxy.safeAreaInsets.bottom + 20))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.0, green: 0.08, blue: 0.05).ignoresSafeArea())
        .sheet(isPresented: $showEmailForm) {
            EmailAuthSheet(account: account)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var loginBackground: some View {
        if let image = UIImage(named: "LaunchScreenImage") {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.18, blue: 0.12),
                    Color(red: 0.0, green: 0.06, blue: 0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

private enum BrandedLoginButtonStyle {
    case outline
    case light
    case black
}

private struct BrandedLoginButton: View {
    let title: String
    var systemImage: String?
    var customIcon: String?
    let style: BrandedLoginButtonStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: style == .outline ? 1.5 : 1))

                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                HStack {
                    icon
                    Spacer()
                }
                .padding(.horizontal, 22)
            }
            .frame(height: 58)
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch style {
        case .outline: return Color.black.opacity(0.16)
        case .light: return .white
        case .black: return .black
        }
    }

    private var border: Color {
        switch style {
        case .outline: return Color(red: 0.55, green: 0.82, blue: 0.19)
        case .light: return .white.opacity(0.88)
        case .black: return .white.opacity(0.16)
        }
    }

    private var textColor: Color {
        switch style {
        case .outline, .black: return .white
        case .light: return .black
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(style == .outline ? Color(red: 0.55, green: 0.82, blue: 0.19) : textColor)
                .frame(width: 30)
        } else if let customIcon {
            Text(customIcon)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .red, .yellow, .green],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30)
        }
    }
}

private struct EmailAuthSheet: View {
    @ObservedObject var account: FirebaseAccountService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Email account")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Sign in, create an account, or reset your password.")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }

                VStack(spacing: 10) {
                    TextField("Email", text: $account.email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .font(.system(.headline, design: .rounded).weight(.medium))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

                    SecureField("Password", text: $account.password)
                        .font(.system(.headline, design: .rounded).weight(.medium))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await account.signIn()
                            if account.user != nil {
                                dismiss()
                            }
                        }
                    } label: {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))
                    .disabled(account.isWorking)

                    Button {
                        Task {
                            await account.createAccount()
                            if account.user != nil {
                                dismiss()
                            }
                        }
                    } label: {
                        Text("Create")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
                    .disabled(account.isWorking)
                }

                Button {
                    Task {
                        await account.sendPasswordReset()
                    }
                } label: {
                    Text("Forgot Password?")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.mint)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(account.isWorking)

                if account.isWorking {
                    ProgressView()
                        .tint(AppTheme.mint)
                }

                if let status = account.statusMessage {
                    Text(status)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(status.localizedCaseInsensitiveContains("error") ? Color.red : AppTheme.softText)
                        .lineSpacing(3)
                }

                Spacer()
            }
            .padding(20)
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.mint)
                }
            }
        }
    }
}

enum Tab: String, CaseIterable {
    case home = "Home"
    case yardages = "Yardages"
    case insights = "Rounds"
    case goals = "Goals"
    case friends = "Friends"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .yardages: "ruler.fill"
        case .insights: "list.bullet.rectangle.portrait.fill"
        case .goals: "target"
        case .friends: "person.2.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct AppTheme {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let background = LinearGradient(
        colors: [
            adaptive(light: UIColor(red: 0.965, green: 0.978, blue: 0.968, alpha: 1), dark: UIColor(red: 0.012, green: 0.042, blue: 0.028, alpha: 1)),
            adaptive(light: UIColor(red: 0.925, green: 0.955, blue: 0.932, alpha: 1), dark: UIColor(red: 0.018, green: 0.082, blue: 0.054, alpha: 1)),
            adaptive(light: UIColor(red: 0.985, green: 0.988, blue: 0.985, alpha: 1), dark: UIColor(red: 0.005, green: 0.022, blue: 0.016, alpha: 1))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let panel = adaptive(light: UIColor.white, dark: UIColor(red: 0.045, green: 0.105, blue: 0.076, alpha: 1))
    static let panelStrong = adaptive(light: UIColor(red: 0.91, green: 0.95, blue: 0.92, alpha: 1), dark: UIColor(red: 0.067, green: 0.145, blue: 0.102, alpha: 1))
    static let elevated = adaptive(light: UIColor(red: 0.975, green: 0.982, blue: 0.976, alpha: 1), dark: UIColor(red: 0.085, green: 0.145, blue: 0.112, alpha: 1))
    static let subtleFill = adaptive(light: UIColor(red: 0.90, green: 0.93, blue: 0.91, alpha: 1), dark: UIColor(white: 1, alpha: 0.10))
    static let ink = adaptive(light: UIColor(red: 0.025, green: 0.105, blue: 0.065, alpha: 1), dark: UIColor.white)
    static let softText = adaptive(light: UIColor(red: 0.28, green: 0.38, blue: 0.31, alpha: 1), dark: UIColor(red: 0.74, green: 0.80, blue: 0.75, alpha: 1))
    static let mint = adaptive(light: UIColor(red: 0.04, green: 0.46, blue: 0.19, alpha: 1), dark: UIColor(red: 0.48, green: 0.91, blue: 0.40, alpha: 1))
    static let mintWash = adaptive(light: UIColor(red: 0.86, green: 0.94, blue: 0.88, alpha: 1), dark: UIColor(red: 0.08, green: 0.25, blue: 0.14, alpha: 1))
    static let controlGreen = Color(red: 0.035, green: 0.40, blue: 0.16)
    static let tabInactive = adaptive(light: UIColor(red: 0.30, green: 0.40, blue: 0.33, alpha: 1), dark: UIColor(red: 0.68, green: 0.75, blue: 0.70, alpha: 1))
    static let tabBar = adaptive(light: UIColor(red: 0.94, green: 0.965, blue: 0.945, alpha: 0.98), dark: UIColor(red: 0.01, green: 0.04, blue: 0.03, alpha: 0.98))
    static let performanceCard = adaptive(light: UIColor(red: 0.07, green: 0.25, blue: 0.13, alpha: 1), dark: UIColor(red: 0.025, green: 0.08, blue: 0.052, alpha: 1))
    static let lime = Color(red: 0.64, green: 0.96, blue: 0.37)
    static let gold = Color(red: 0.94, green: 0.66, blue: 0.28)
    static let border = adaptive(light: UIColor(red: 0.72, green: 0.79, blue: 0.74, alpha: 0.72), dark: UIColor(white: 1, alpha: 0.18))
    static let shadow = adaptive(light: UIColor(white: 0, alpha: 0.12), dark: UIColor(white: 0, alpha: 0.38))
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let glassGradient = LinearGradient(
        colors: [
            panelStrong,
            panel
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct HomeView: View {
    let savedRounds: [SavedRound]
    let entries: [RoundHoleEntry]
    let recentRounds: [RoundSummary]
    let handicapHistory: [HandicapRecord]
    let isRoundActive: Bool
    let currentHandicap: Double
    let profileName: String
    let profileHomeClub: String
    @Binding var profileImageData: Data
    let notificationCount: Int
    let openNotifications: () -> Void
    let openAllRounds: () -> Void
    let startRound: () -> Void
    let discardRound: () -> Void
    let deleteRound: (SavedRound) -> Void
    let updateRound: (SavedRound) -> Void
    @State private var selectedRound: SavedRound?
    @State private var showDiscardRoundAlert = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                PremiumScreenHeader(
                    title: "Precision Golf",
                    subtitle: greetingLine,
                    actionIcon: "bell.fill",
                    badgeCount: notificationCount,
                    action: openNotifications
                )

                PerformanceOverview(
                    rounds: savedRounds,
                    isRoundActive: isRoundActive,
                    currentHandicap: currentHandicap,
                    startRound: startRound,
                    discardRound: { showDiscardRoundAlert = true }
                )

                PremiumHandicapTrendCard(records: handicapHistory)

                PremiumHomeRecentRounds(
                    rounds: Array(savedRounds.prefix(3)),
                    viewAllRounds: openAllRounds,
                    viewRound: { selectedRound = $0 }
                )

                InsightsDashboardContent(entries: entries, savedRounds: savedRounds, isRoundActive: isRoundActive, currentHandicap: currentHandicap)

            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .sheet(item: $selectedRound) { round in
            SavedRoundDetailView(round: round, currentHandicap: currentHandicap, updateRound: updateRound)
        }
        .alert("Delete current round?", isPresented: $showDiscardRoundAlert) {
            Button("Keep Round", role: .cancel) { }
            Button("Delete Round", role: .destructive) {
                discardRound()
            }
        } message: {
            Text("This will stop the live round and remove all unsaved scores and stats from this card.")
        }
    }

    private var greetingLine: String {
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "Player" : trimmedName
        let club = profileHomeClub.trimmingCharacters(in: .whitespacesAndNewlines)
        return club.isEmpty ? "Welcome back, \(name)" : "\(name) - \(club)"
    }
}

struct PremiumScreenHeader: View {
    let title: String
    let subtitle: String
    let actionIcon: String
    var badgeCount: Int = 0
    var action: () -> Void = { }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            Spacer()

            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: actionIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppTheme.ink)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(AppTheme.subtleFill))
                        .overlay(Circle().stroke(AppTheme.border))
                    if badgeCount > 0 {
                        Text(badgeCount > 9 ? "9+" : "\(badgeCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Capsule().fill(AppTheme.danger))
                            .offset(x: 2, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(badgeCount > 0 ? "Notifications, \(badgeCount) unread" : "Notifications")
        }
    }
}

struct PremiumHandicapTrendCard: View {
    let records: [HandicapRecord]

    private var orderedRecords: [HandicapRecord] {
        Array(records.sorted { $0.date < $1.date }.suffix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Handicap Index Trend")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("Last 20 changes")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            }

            if orderedRecords.isEmpty {
                Text("Record a handicap change in Settings to start tracking your index.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .padding(.vertical, 16)
            } else {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f", orderedRecords.last?.handicap ?? 0))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.mint)
                        Text("current index")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                        if let lowest = orderedRecords.map(\.handicap).min() {
                            Text("Low \(String(format: "%.1f", lowest))")
                                .font(.system(.caption2, design: .rounded).weight(.medium))
                                .foregroundStyle(AppTheme.softText)
                        }
                    }
                    PremiumHandicapLineChart(records: orderedRecords)
                        .frame(height: 136)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }
}

struct PremiumHandicapLineChart: View {
    let records: [HandicapRecord]

    private var values: [Double] { records.map(\.handicap) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let minimum = max(floor((values.min() ?? 0) - 1), 0)
            let maximum = ceil((values.max() ?? 1) + 1)
            let range = max(maximum - minimum, 1)
            let originX: CGFloat = 26
            let plotWidth = max(size.width - originX - 4, 1)
            let plotHeight = max(size.height - 24, 1)

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let fraction = CGFloat(index) / 2
                    let y = 5 + fraction * plotHeight
                    Text(String(format: "%.1f", maximum - Double(fraction) * range))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                        .position(x: 12, y: y)
                    Rectangle()
                        .fill(AppTheme.border.opacity(0.72))
                        .frame(width: plotWidth, height: 1)
                        .position(x: originX + plotWidth / 2, y: y)
                }

                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = originX + (values.count == 1 ? plotWidth / 2 : CGFloat(index) / CGFloat(values.count - 1) * plotWidth)
                        let y = 5 + plotHeight - CGFloat((value - minimum) / range) * plotHeight
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(AppTheme.mint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    let x = originX + (values.count == 1 ? plotWidth / 2 : CGFloat(index) / CGFloat(values.count - 1) * plotWidth)
                    let y = 5 + plotHeight - CGFloat((record.handicap - minimum) / range) * plotHeight
                    Circle()
                        .fill(AppTheme.panel)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AppTheme.mint, lineWidth: 2))
                        .position(x: x, y: y)
                }

                if let first = records.first, let last = records.last {
                    Text(Self.shortDateFormatter.string(from: first.date))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                        .position(x: originX, y: size.height - 4)
                    Text(Self.shortDateFormatter.string(from: last.date))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                        .position(x: originX + plotWidth, y: size.height - 4)
                }
            }
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}

struct PremiumHomeRecentRounds: View {
    let rounds: [SavedRound]
    let viewAllRounds: () -> Void
    let viewRound: (SavedRound) -> Void

    var body: some View {
        if !rounds.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent Rounds")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    Button(action: viewAllRounds) {
                        Text("View all")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.mint)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 0) {
                    ForEach(rounds) { round in
                        Button {
                            viewRound(round)
                        } label: {
                            PremiumRecentRoundRow(round: round)
                        }
                        .buttonStyle(.plain)

                        if round.id != rounds.last?.id {
                            Divider().overlay(AppTheme.border)
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
                .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
            }
        }
    }
}

struct PremiumRecentRoundRow: View {
    let round: SavedRound

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.38, blue: 0.16), AppTheme.lime.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                Image(systemName: "flag.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(dateText)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                Text(round.courseName)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    RoundSplitChip(title: "F9", value: frontNineScore)
                    RoundSplitChip(title: "B9", value: backNineScore)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(round.totalScore)")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(scoreToParText)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(scoreToPar <= 0 ? AppTheme.mint : AppTheme.softText)
                }
                Label("View round", systemImage: "chevron.right")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.mint)
            }
        }
        .padding(.vertical, 10)
    }

    private var scoreToPar: Int {
        round.totalScore - round.totalPar
    }

    private var scoreToParText: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }

    private var frontNineScore: String {
        "\(round.holes.filter { $0.holeNumber <= 9 }.reduce(0) { $0 + $1.score })"
    }

    private var backNineScore: String {
        let back = round.holes.filter { $0.holeNumber > 9 }
        return back.isEmpty ? "-" : "\(back.reduce(0) { $0 + $1.score })"
    }

    private var dateText: String {
        Self.formatter.string(from: round.date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

struct RoundSplitChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.095)))
        .overlay(Capsule().stroke(AppTheme.border.opacity(0.8)))
    }
}

struct RecentRoundsView: View {
    let savedRounds: [SavedRound]
    let currentHandicap: Double
    let startRound: () -> Void
    let deleteRound: (SavedRound) -> Void
    let updateRound: (SavedRound) -> Void
    @State private var selectedRound: SavedRound?
    @State private var visibleRecentRoundCount = 8
    @State private var roundPendingDelete: SavedRound?

    private var visibleRecentRounds: ArraySlice<SavedRound> {
        savedRounds.prefix(visibleRecentRoundCount)
    }

    private var canLoadMoreRounds: Bool {
        visibleRecentRoundCount < savedRounds.count
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HeaderBlock(
                    title: "Rounds",
                    subtitle: savedRounds.isEmpty ? "Completed scorecards will live here." : "\(savedRounds.count) saved scorecard\(savedRounds.count == 1 ? "" : "s")"
                )

                VStack(spacing: 10) {
                    if savedRounds.isEmpty {
                        EmptyRoundsCard(startRound: startRound)
                    } else {
                        ForEach(visibleRecentRounds) { round in
                            SavedRoundRow(
                                round: round,
                                viewRound: { selectedRound = round },
                                deleteRound: { roundPendingDelete = round }
                            )
                        }

                        if canLoadMoreRounds {
                            Button {
                                visibleRecentRoundCount = min(visibleRecentRoundCount + 8, savedRounds.count)
                            } label: {
                                HStack {
                                    Text("Load More Rounds")
                                    Spacer()
                                    Text("\(min(savedRounds.count - visibleRecentRoundCount, 8)) more")
                                    Image(systemName: "chevron.down")
                                }
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(AppTheme.mint)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .sheet(item: $selectedRound) { round in
            SavedRoundDetailView(round: round, currentHandicap: currentHandicap, updateRound: updateRound)
        }
        .alert("Delete this round?", isPresented: Binding(
            get: { roundPendingDelete != nil },
            set: { if !$0 { roundPendingDelete = nil } }
        )) {
            Button("Keep Round", role: .cancel) { roundPendingDelete = nil }
            Button("Delete Round", role: .destructive) {
                if let roundPendingDelete { deleteRound(roundPendingDelete) }
                roundPendingDelete = nil
            }
        } message: {
            Text("This permanently removes the scorecard and its statistics. This cannot be undone.")
        }
    }
}

struct HomeFloatingRoundButton: View {
    let isRoundActive: Bool
    let startRound: () -> Void
    let discardRound: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRoundActive {
                Button(action: discardRound) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.red.opacity(0.82))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white))
                        .overlay(Circle().stroke(Color.red.opacity(0.15)))
                        .shadow(color: AppTheme.shadow, radius: 10, x: 0, y: 5)
                }
                .buttonStyle(.plain)
            }

            Button(action: startRound) {
                HStack(spacing: 8) {
                    Image(systemName: isRoundActive ? "flag.fill" : "plus")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(AppTheme.controlGreen)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().stroke(Color.white.opacity(0.72), lineWidth: 1))
                    Text(isRoundActive ? "Resume" : "New Round")
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
                .foregroundStyle(Color.white)
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .frame(minWidth: isRoundActive ? 118 : 142)
                .frame(height: 52)
                .background(
                    Capsule()
                        .fill(AppTheme.controlGreen)
                )
                .overlay(Capsule().stroke(Color.white.opacity(0.36), lineWidth: 1))
                .shadow(color: AppTheme.controlGreen.opacity(0.3), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRoundActive ? "Resume current round" : "Start new round")
        }
    }
}

struct PlayerProfileCard: View {
    let rounds: [SavedRound]
    let profileName: String
    let profileHomeClub: String
    @Binding var profileImageData: Data
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        ProfileAvatar(imageData: profileImageData)

                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 25, height: 25)
                            .background(Circle().fill(AppTheme.mint))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 7) {
                    Text(displayName)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                    Text(homeClubText)
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        PlayerBadge(icon: "flag.fill", text: rounds.isEmpty ? "First card waiting" : "\(rounds.count) rounds logged", color: AppTheme.mint)
                        PlayerBadge(icon: "chart.line.uptrend.xyaxis", text: formBadgeText, color: AppTheme.ink)
                    }
                }
            }

            HStack(spacing: 10) {
                ProfileMiniStat(title: "Best Gross", value: bestGross)
                ProfileMiniStat(title: "Best Points", value: bestStableford)
                ProfileMiniStat(title: "Latest", value: latestScore)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
        .onChange(of: selectedPhoto) { _, newItem in
            Task {
                guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
                profileImageData = data
            }
        }
    }

    private var homeClubText: String {
        let trimmedHomeClub = profileHomeClub.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHomeClub.isEmpty {
            return trimmedHomeClub
        }
        guard let mostPlayed = rounds.reduce(into: [String: Int](), { counts, round in
            counts[round.courseName, default: 0] += 1
        }).max(by: { $0.value < $1.value })?.key else {
            return "Build your playing profile"
        }
        return mostPlayed
    }

    private var displayName: String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player" : trimmed
    }

    private var bestGross: String {
        rounds.map(\.totalScore).min().map(String.init) ?? "-"
    }

    private var bestStableford: String {
        rounds.compactMap(\.stablefordPoints).max().map(String.init) ?? "-"
    }

    private var latestScore: String {
        rounds.first.map { "\($0.totalScore)" } ?? "-"
    }

    private var formBadgeText: String {
        guard let latest = rounds.first else { return "Ready to play" }
        let scoreToPar = latest.totalScore - latest.totalPar
        if scoreToPar <= 9 { return "Strong card" }
        if latest.stablefordPoints ?? 0 >= 36 { return "Points day" }
        return "Card saved"
    }
}

struct ProfileMiniStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border.opacity(0.7)))
    }
}

struct ProfileAvatar: View {
    let imageData: Data

    var body: some View {
        Group {
            if let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.mint, AppTheme.lime],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("J")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 3))
        .shadow(color: AppTheme.shadow, radius: 10, x: 0, y: 6)
    }
}

struct PlayerBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(AppTheme.border.opacity(0.75)))
    }
}

struct RoundTimelineSection: View {
    let rounds: [SavedRound]
    let viewRound: (SavedRound) -> Void

    private var groupedRounds: [(title: String, rounds: [SavedRound])] {
        let grouped = Dictionary(grouping: rounds) { round in
            Self.monthFormatter.string(from: round.date)
        }
        return grouped
            .map { (title: $0.key, rounds: $0.value.sorted { $0.date > $1.date }) }
            .sorted { ($0.rounds.first?.date ?? .distantPast) > ($1.rounds.first?.date ?? .distantPast) }
    }

    var body: some View {
        if !rounds.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Playing History", actionTitle: "\(rounds.count) latest")

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedRounds, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.system(.caption, design: .rounded).weight(.heavy))
                                .foregroundStyle(AppTheme.softText)
                                .textCase(.uppercase)

                            VStack(spacing: 8) {
                                ForEach(group.rounds) { round in
                                    RoundTimelineRow(round: round, viewRound: { viewRound(round) })
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
            }
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}

struct RoundTimelineRow: View {
    let round: SavedRound
    let viewRound: () -> Void

    var body: some View {
        Button(action: viewRound) {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(Self.dayFormatter.string(from: round.date))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                    Text(Self.weekdayFormatter.string(from: round.date))
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.softText)
                }
                .frame(width: 48, height: 54)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

                VStack(alignment: .leading, spacing: 3) {
                    Text(round.courseName)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Text("\(round.teeName) tees - \(stablefordText)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(round.totalScore)")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(scoreToParLabel)
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .foregroundStyle(scoreToPar <= 4 ? AppTheme.mint : AppTheme.gold)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill.opacity(0.62)))
        }
        .buttonStyle(.plain)
    }

    private var scoreToPar: Int {
        round.totalScore - round.totalPar
    }

    private var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }

    private var stablefordText: String {
        round.stablefordPoints.map { "\($0) pts" } ?? "No Stableford"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

struct PerformanceOverview: View {
    let rounds: [SavedRound]
    let isRoundActive: Bool
    let currentHandicap: Double
    let startRound: () -> Void
    let discardRound: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Performance Summary")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.mint)
                            .textCase(.uppercase)

                        Text("Scoring Average")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("\(String(seasonYear)) season • \(roundCountLabel)")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(.white.opacity(0.78))
                    }

                    Spacer()

                    HomeFloatingRoundButton(
                        isRoundActive: isRoundActive,
                        startRound: startRound,
                        discardRound: discardRound
                    )
                }

                HStack(spacing: 0) {
                    SummaryMetric(title: "Handicap", value: handicapText, caption: "Current index")
                    Divider().overlay(Color.white.opacity(0.18)).padding(.vertical, 10)
                    SummaryMetric(title: "Scoring Avg", value: scoringAverage, caption: "Gross")
                    Divider().overlay(Color.white.opacity(0.18)).padding(.vertical, 10)
                    SummaryMetric(title: "Last Round", value: latestRoundScore, caption: latestRoundDate)
                }
            }
            .padding(20)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(AppTheme.performanceCard)
                    FairwayCardBackdrop()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    LinearGradient(
                        colors: [Color.black.opacity(0.38), Color.black.opacity(0.04)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                PremiumDashboardMetric(icon: "flag.circle", title: "Fairways Hit", value: "\(fairwayPercent)%", caption: "vs season", trend: "+6%", tint: AppTheme.mint)
                PremiumDashboardMetric(icon: "target", title: "GIR", value: "\(girPercent)%", caption: "greens in regulation", trend: "+4%", tint: AppTheme.mint)
                PremiumDashboardMetric(icon: "figure.golf", title: "Putts", value: averagePutts, caption: "per round", trend: "-1.3", tint: AppTheme.mint)
                PremiumDashboardMetric(icon: "waveform.path.ecg", title: "Scrambling", value: "\(scramblePercent)%", caption: "up and downs", trend: "+3%", tint: AppTheme.mint)
            }

            ScoringMixStrip(
                birdies: averageBirdies,
                pars: averagePars,
                bogeys: averageBogeys,
                doubles: averageDoublesOrWorse
            )
        }
        .padding(0)
    }

    private var seasonRounds: [SavedRound] {
        rounds.filter { Calendar.current.component(.year, from: $0.date) == seasonYear }
    }

    private var seasonYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var scoringAverage: String {
        guard !seasonRounds.isEmpty else { return "-" }
        let average = Double(seasonRounds.reduce(0) { $0 + $1.totalScore }) / Double(seasonRounds.count)
        return String(format: "%.1f", average)
    }

    private var handicapText: String {
        String(format: "%.1f", currentHandicap)
    }

    private var latestRoundScore: String {
        seasonRounds.sorted { $0.date > $1.date }.first.map { "\($0.totalScore)" } ?? "-"
    }

    private var latestRoundDate: String {
        guard let latest = seasonRounds.sorted(by: { $0.date > $1.date }).first else {
            return "No rounds"
        }
        return Self.shortDateFormatter.string(from: latest.date)
    }

    private var roundCountLabel: String {
        seasonRounds.isEmpty ? "no rounds" : "\(seasonRounds.count) \(seasonRounds.count == 1 ? "round" : "rounds")"
    }

    private var fairwayPercent: Int {
        let hit = seasonRounds.reduce(0) { $0 + $1.fairwaysHit }
        let total = seasonRounds.reduce(0) { $0 + $1.fairwaysTotal }
        guard total > 0 else { return 0 }
        return Int((Double(hit) / Double(total)) * 100)
    }

    private var girPercent: Int {
        let holes = seasonRounds.flatMap(\.holes)
        let hit = holes.filter { $0.green == .hit }.count
        let total = holes.filter { $0.green != .notTracked }.count
        guard total > 0 else { return 0 }
        return Int((Double(hit) / Double(total)) * 100)
    }

    private var scramblePercent: Int {
        let made = seasonRounds.reduce(0) { $0 + $1.scrambles }
        let total = seasonRounds.reduce(0) { $0 + $1.scramblingOpportunities }
        guard total > 0 else { return 0 }
        return Int((Double(made) / Double(total) * 100).rounded())
    }

    private var averagePutts: String {
        guard !seasonRounds.isEmpty else { return "-" }
        let average = Double(seasonRounds.reduce(0) { $0 + $1.totalPutts }) / Double(seasonRounds.count)
        return String(format: "%.1f", average)
    }

    private var averageStableford: String {
        guard !seasonRounds.isEmpty else { return "-" }
        let points = seasonRounds.compactMap(\.stablefordPoints)
        guard !points.isEmpty else { return "-" }
        let average = Double(points.reduce(0, +)) / Double(points.count)
        return String(format: "%.1f", average)
    }

    private var averagePenalties: String {
        guard !seasonRounds.isEmpty else { return "-" }
        let average = Double(seasonRounds.reduce(0) { $0 + $1.penalties }) / Double(seasonRounds.count)
        return String(format: "%.1f", average)
    }

    private var averageDoublesOrWorse: String {
        averageScoringHoles { $0.score >= $0.par + 2 }
    }

    private var averageBirdies: String {
        averageScoringHoles { $0.score == $0.par - 1 }
    }

    private var averagePars: String {
        averageScoringHoles { $0.score == $0.par }
    }

    private var averageBogeys: String {
        averageScoringHoles { $0.score == $0.par + 1 }
    }

    private func averageScoringHoles(matching predicate: (SavedHoleEntry) -> Bool) -> String {
        guard !seasonRounds.isEmpty else { return "-" }
        let total = seasonRounds.flatMap(\.holes).filter(predicate).count
        let average = Double(total) / Double(seasonRounds.count)
        return String(format: "%.1f", average)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

struct SummaryMetric: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 35, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FairwayCardBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.23, blue: 0.11), Color(red: 0.01, green: 0.07, blue: 0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.055 : 0.025))
                    .frame(width: 240, height: 34)
                    .rotationEffect(.degrees(-12))
                    .offset(x: CGFloat(index * 42) - 140, y: CGFloat(index * 21) - 30)
            }

            Circle()
                .fill(AppTheme.lime.opacity(0.16))
                .blur(radius: 22)
                .frame(width: 130, height: 130)
                .offset(x: 130, y: -40)
        }
    }
}

struct PremiumDashboardMetric: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let trend: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(tint.opacity(0.22)))
                    .overlay(Circle().stroke(tint.opacity(0.28)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(value)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                Text(caption)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                Text(trend)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(18, proxy.size.width * 0.58))
                }
            }
            .frame(height: 7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
        .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
    }
}

struct ScoringMixStrip: View {
    let birdies: String
    let pars: String
    let bogeys: String
    let doubles: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scoring Mix")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("avg per round")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            }

            HStack(spacing: 10) {
                ScoringMixPill(title: "Birdies", value: birdies, tint: Color(red: 0.88, green: 0.16, blue: 0.20))
                ScoringMixPill(title: "Pars", value: pars, tint: AppTheme.mint)
                ScoringMixPill(title: "Bogeys", value: bogeys, tint: AppTheme.gold)
                ScoringMixPill(title: "Doubles+", value: doubles, tint: Color(red: 0.42, green: 0.22, blue: 0.58))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border.opacity(0.7)))
    }
}

struct HoleAverageCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "flag.fill")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(value)
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 104)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), tint.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.26)))
        .shadow(color: AppTheme.shadow, radius: 14, x: 0, y: 8)
    }
}

struct CompactMetricPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule()
                .fill(tint)
                .frame(width: 28, height: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(value)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 70)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), tint.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.24)))
        .shadow(color: AppTheme.shadow, radius: 10, x: 0, y: 6)
    }
}

struct ScoringMixPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.065)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.22)))
        .shadow(color: AppTheme.shadow, radius: 9, x: 0, y: 5)
    }
}

struct DesignedMetric: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.82))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.16)))
    }
}

struct MiniMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct PersonalBestStrip: View {
    let rounds: [SavedRound]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Personal Bests", actionTitle: rounds.isEmpty ? nil : "\(rounds.count) cards")
            HStack(spacing: 10) {
                MiniMetric(title: "Best Gross", value: bestGross)
                MiniMetric(title: "Best Stableford", value: bestStableford)
                MiniMetric(title: "Lowest Putts", value: lowestPutts)
            }
        }
    }

    private var bestGross: String {
        rounds.map(\.totalScore).min().map(String.init) ?? "-"
    }

    private var bestStableford: String {
        rounds.compactMap(\.stablefordPoints).max().map(String.init) ?? "-"
    }

    private var lowestPutts: String {
        rounds.map(\.totalPutts).min().map(String.init) ?? "-"
    }
}

struct CourseFormSection: View {
    let rounds: [SavedRound]

    private var courseStats: [CourseFormStat] {
        let grouped = Dictionary(grouping: rounds, by: \.courseName)
        return grouped.map { courseName, rounds in
            CourseFormStat(courseName: courseName, rounds: rounds)
        }
        .sorted {
            if $0.roundCount == $1.roundCount {
                return $0.courseName.localizedCaseInsensitiveCompare($1.courseName) == .orderedAscending
            }
            return $0.roundCount > $1.roundCount
        }
    }

    var body: some View {
        if !courseStats.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Course Form", actionTitle: nil)
                VStack(spacing: 8) {
                    ForEach(courseStats.prefix(4)) { stat in
                        CourseFormRow(stat: stat)
                    }
                }
            }
        }
    }
}

struct CourseFormStat: Identifiable {
    let id: String
    let courseName: String
    let roundCount: Int
    let averageScore: Double
    let bestScore: Int
    let averageStableford: Double?
    let lastScore: Int

    init(courseName: String, rounds: [SavedRound]) {
        id = courseName
        self.courseName = courseName
        roundCount = rounds.count
        averageScore = Double(rounds.reduce(0) { $0 + $1.totalScore }) / Double(max(rounds.count, 1))
        bestScore = rounds.map(\.totalScore).min() ?? 0
        let stableford = rounds.compactMap(\.stablefordPoints)
        averageStableford = stableford.isEmpty ? nil : Double(stableford.reduce(0, +)) / Double(stableford.count)
        lastScore = rounds.sorted { $0.date > $1.date }.first?.totalScore ?? 0
    }
}

struct CourseFormRow: View {
    let stat: CourseFormStat

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stat.courseName)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text("\(stat.roundCount) round\(stat.roundCount == 1 ? "" : "s") - best \(stat.bestScore) - last \(stat.lastScore)")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.1f", stat.averageScore))
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text(stat.averageStableford.map { String(format: "%.1f pts", $0) } ?? "no pts")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.softText)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }
}

struct StartRoundPanel: View {
    let isRoundActive: Bool
    let startRound: () -> Void
    let discardRound: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: startRound) {
                HStack(spacing: 14) {
                    Image(systemName: isRoundActive ? "flag.fill" : "plus")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(AppTheme.mint))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(isRoundActive ? "Resume Round" : "New Round")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                        Text(isRoundActive ? "Continue your live scorecard" : "Search the course database or enter one manually")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.softText)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.mint.opacity(0.22)))
                .shadow(color: AppTheme.shadow, radius: 12, x: 0, y: 6)
            }

            HStack(spacing: 10) {
                QuickStartButton(icon: isRoundActive ? "flag.fill" : "magnifyingglass", title: isRoundActive ? "Live Card" : "Course Search", detail: isRoundActive ? "Resume" : "Database", action: startRound)
                QuickStartButton(icon: "square.and.pencil", title: isRoundActive ? "Finish First" : "Manual Entry", detail: isRoundActive ? "Active round" : "Add course", action: startRound)
            }

            if isRoundActive {
                Button(role: .destructive, action: discardRound) {
                    Label("Stop and Delete Current Round", systemImage: "trash")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(Color.red)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.06)))
            }
        }
    }
}

struct QuickStartButton: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppTheme.gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(detail)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        }
    }
}

struct SectionHeader: View {
    let title: String
    let actionTitle: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
            Spacer()
            if let actionTitle {
                Text(actionTitle)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.mint)
            }
        }
    }
}

struct RecentRoundRow: View {
    let round: RoundSummary

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 3) {
                Text("\(round.score)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text(round.scoreToParLabel)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(round.scoreToPar <= 4 ? AppTheme.mint : AppTheme.gold)
            }
            .frame(width: 60, height: 64)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(round.courseName)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    Text(round.dateLabel)
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.softText)
                }
                Text("\(round.teeName) tees - \(round.greensInRegulation) GIR - \(round.putts) putts")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                Text(round.note)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
    }
}

struct EmptyRoundsCard: View {
    let startRound: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "scorecard")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppTheme.mint)
            Text("No completed rounds yet")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
            Text("Finish a round and it will appear here with full scoring, putting, fairway, GIR, penalty and note data.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .lineSpacing(3)
            Button(action: startRound) {
                HStack {
                    Text("Start First Round")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.white)
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mint))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }
}

struct SavedRoundRow: View {
    let round: SavedRound
    let viewRound: () -> Void
    let deleteRound: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: viewRound) {
                HStack(spacing: 14) {
                    VStack(spacing: 3) {
                        Text("\(round.totalScore)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                        Text(scoreToParLabel)
                            .font(.system(.caption, design: .rounded).weight(.heavy))
                            .foregroundStyle(scoreToPar <= 4 ? AppTheme.mint : AppTheme.gold)
                    }
                    .frame(width: 58, height: 60)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(round.courseName)
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(round.summary.dateLabel)
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                                    .foregroundStyle(AppTheme.softText)
                                Text(handicapText)
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
                            }
                        }
                        HStack(spacing: 6) {
                            TeeMarkerSwatch(marker: round.teeMarkerColor ?? TeeMarkerColor.inferred(from: round.teeName), size: 10)
                            Text("\(round.teeName) tees - \(round.greensInRegulation) GIR - \(round.totalPutts) putts\(stablefordText)")
                                .font(.system(.caption, design: .rounded).weight(.medium))
                                .foregroundStyle(AppTheme.softText)
                        }
                        HStack(spacing: 8) {
                            RoundSplitChip(title: "F9", value: frontNineScore)
                            RoundSplitChip(title: "B9", value: backNineScore)
                            RoundSplitChip(title: "Total", value: "\(round.totalScore)")
                        }
                        Text("Tap to review full hole-by-hole stats")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(AppTheme.softText)
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: deleteRound) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.gold)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.subtleFill))
            }
            .accessibilityLabel("Delete round")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var scoreToPar: Int {
        round.totalScore - round.totalPar
    }

    private var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }

    private var stablefordText: String {
        guard let points = round.stablefordPoints else { return "" }
        return " - \(points) pts"
    }

    private var frontNineScore: String {
        "\(round.holes.filter { $0.holeNumber <= 9 }.reduce(0) { $0 + $1.score })"
    }

    private var backNineScore: String {
        let back = round.holes.filter { $0.holeNumber > 9 }
        return back.isEmpty ? "-" : "\(back.reduce(0) { $0 + $1.score })"
    }

    private var handicapText: String {
        guard let handicap = round.handicap else { return "HI -" }
        return "HI \(String(format: "%.1f", handicap))"
    }
}

struct SavedRoundDetailView: View {
    let round: SavedRound
    let currentHandicap: Double
    let updateRound: (SavedRound) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showHoleBreakdown = false
    @State private var isEditingRound = false
    @State private var sharePayload: RoundSharePayload?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(round.courseName)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                        HStack(spacing: 7) {
                            TeeMarkerSwatch(marker: round.teeMarkerColor ?? TeeMarkerColor.inferred(from: round.teeName), size: 12)
                            Text("\(round.location) - \(round.teeName) tees")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(AppTheme.softText)
                        }
                    }

                    VisualScorecard(round: round)

                    ShareableRoundSummaryCard(round: round)

                    RoundShortGameSection(round: round)

                    RoundShotPatternSection(pattern: shotPattern)

                    RoundApproachProximitySection(round: round)

                    DisclosureGroup(isExpanded: $showHoleBreakdown) {
                        VStack(spacing: 8) {
                            ForEach(round.holes) { hole in
                                HoleBreakdownRow(hole: hole)

                                if !hole.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(hole.note)
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundStyle(AppTheme.softText)
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("Hole Breakdown")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                    }
                    .tint(AppTheme.mint)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit") { isEditingRound = true }
                        .foregroundStyle(AppTheme.mint)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        sharePayload = RoundSharePayload.savedRound(round)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(AppTheme.mint)

                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
            }
        }
        .sheet(isPresented: $isEditingRound) {
            SavedRoundEditorView(round: round) { updatedRound in
                updateRound(updatedRound)
                isEditingRound = false
                dismiss()
            }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityShareView(activityItems: payload.items)
        }
    }

    private var shotPattern: RoundShotPattern {
        RoundShotPattern(round: round)
    }
}

struct RoundShotPattern {
    let fairwaysHit: Int
    let fairwaysTracked: Int
    let fairwayMisses: [MissDirection]
    let greensHit: Int
    let greensTracked: Int
    let approachMisses: [MissDirection]

    init(round: SavedRound) {
        let trackedTeeShots = round.holes.filter { $0.par > 3 && $0.fairway != .notTracked }
        fairwaysHit = trackedTeeShots.filter { $0.fairway == .hit }.count
        fairwaysTracked = trackedTeeShots.count
        fairwayMisses = trackedTeeShots
            .map(\.fairway)
            .filter { [.left, .right].contains($0) }

        let trackedApproaches = round.holes.filter { $0.green != .notTracked }
        greensHit = trackedApproaches.filter { $0.green == .hit }.count
        greensTracked = trackedApproaches.count
        approachMisses = trackedApproaches
            .map(\.green)
            .filter { [.short, .long, .left, .right].contains($0) }
    }

    var fairwayPercent: Int {
        percent(fairwaysHit, fairwaysTracked)
    }

    var girPercent: Int {
        percent(greensHit, greensTracked)
    }

    func count(_ direction: MissDirection, in misses: [MissDirection]) -> Int {
        misses.filter { $0 == direction }.count
    }

    func missPercent(_ direction: MissDirection, in misses: [MissDirection], tracked: Int) -> Int {
        percent(count(direction, in: misses), tracked)
    }

    private func percent(_ value: Int, _ total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(value) / Double(total) * 100).rounded())
    }
}

struct RoundShotPatternSection: View {
    let pattern: RoundShotPattern

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shot Pattern")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("Directional misses from this round")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Text(leakLabel)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.mint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            VStack(spacing: 12) {
                RoundShotPatternCard(
                    title: "Drives",
                    icon: "location.north.line.fill",
                    trackedLabel: "\(pattern.fairwaysTracked) tracked tee shots",
                    hitLabel: "\(pattern.fairwayPercent)% fairways",
                    misses: pattern.fairwayMisses,
                    trackedCount: pattern.fairwaysTracked,
                    directions: [.left, .right],
                    pattern: pattern
                )

                RoundShotPatternCard(
                    title: "Approaches",
                    icon: "scope",
                    trackedLabel: "\(pattern.greensTracked) tracked approaches",
                    hitLabel: "\(pattern.girPercent)% GIR",
                    misses: pattern.approachMisses,
                    trackedCount: pattern.greensTracked,
                    directions: [.short, .long, .left, .right],
                    pattern: pattern
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white, AppTheme.subtleFill, AppTheme.mintWash],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.8), radius: 14, x: 0, y: 7)
    }

    private var leakLabel: String {
        guard let topMiss else { return "No miss bias" }
        return "\(topMiss.area) \(topMiss.direction.rawValue)"
    }

    private var topMiss: (area: String, direction: MissDirection, count: Int)? {
        let drive = topMiss(in: pattern.fairwayMisses, area: "Drive", directions: [.left, .right])
        let approach = topMiss(in: pattern.approachMisses, area: "Approach", directions: [.short, .long, .left, .right])
        return [drive, approach]
            .compactMap { $0 }
            .max { $0.count < $1.count }
    }

    private func topMiss(in misses: [MissDirection], area: String, directions: [MissDirection]) -> (area: String, direction: MissDirection, count: Int)? {
        directions
            .map { (area: area, direction: $0, count: pattern.count($0, in: misses)) }
            .filter { $0.count > 0 }
            .max { $0.count < $1.count }
    }
}

struct RoundShotPatternCard: View {
    let title: String
    let icon: String
    let trackedLabel: String
    let hitLabel: String
    let misses: [MissDirection]
    let trackedCount: Int
    let directions: [MissDirection]
    let pattern: RoundShotPattern

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.mint.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("\(trackedLabel) - \(hitLabel)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
            }

            if trackedCount == 0 {
                Text("No tracked \(title.lowercased()) for this round.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            } else {
                VStack(spacing: 10) {
                    ForEach(directions, id: \.self) { direction in
                        RoundDirectionBar(
                            direction: direction,
                            count: pattern.count(direction, in: misses),
                            percent: pattern.missPercent(direction, in: misses, tracked: trackedCount)
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.8)))
    }
}

struct RoundShortGameSection: View {
    let round: SavedRound

    private var missedGreenHoles: [SavedHoleEntry] {
        round.holes.filter { $0.green != .hit && $0.green != .notTracked }
    }

    private var bogeyRecoveries: Int {
        missedGreenHoles.filter { $0.score - $0.par == 1 }.count
    }

    private var costlyMisses: Int {
        missedGreenHoles.filter { $0.score - $0.par >= 2 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Short Game")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("Scrambles, bunker saves and missed-green damage")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Image(systemName: "flag.checkered")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.mintWash))
            }

            HStack(spacing: 8) {
                RoundShortGameMetricTile(
                    title: "Scramble",
                    value: "\(round.scramblePercent)%",
                    caption: "\(round.scrambles)/\(round.scramblingOpportunities)",
                    accent: AppTheme.mint
                )
                RoundShortGameMetricTile(
                    title: "Sand Save",
                    value: "\(round.sandSavePercent)%",
                    caption: "\(round.sandSaves)/\(round.bunkerHoles)",
                    accent: AppTheme.gold
                )
                RoundShortGameMetricTile(
                    title: "Bunkers",
                    value: "\(round.bunkerHoles)",
                    caption: round.bunkerHoles == 1 ? "visit" : "visits",
                    accent: AppTheme.ink
                )
            }

            VStack(spacing: 10) {
                RoundShortGameBar(label: "Saved par or better", count: round.scrambles, total: round.scramblingOpportunities, color: AppTheme.mint)
                RoundShortGameBar(label: "Dropped one", count: bogeyRecoveries, total: round.scramblingOpportunities, color: AppTheme.gold)
                RoundShortGameBar(label: "Dropped two+", count: costlyMisses, total: round.scramblingOpportunities, color: .red)
            }

            if round.scramblingOpportunities == 0 {
                Text("No tracked missed greens in this round.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white, AppTheme.subtleFill.opacity(0.8), AppTheme.mintWash.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.75), radius: 14, x: 0, y: 7)
    }
}

struct RoundShortGameMetricTile: View {
    let title: String
    let value: String
    let caption: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(size: 25, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(caption)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
    }
}

struct RoundShortGameBar: View {
    let label: String
    let count: Int
    let total: Int
    let color: Color

    private var percent: Int {
        guard total > 0 else { return 0 }
        return Int((Double(count) / Double(total) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("\(count) - \(percent)%")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(count == 0 ? AppTheme.softText : color)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.subtleFill)
                    Capsule()
                        .fill(count == 0 ? AppTheme.border : color)
                        .frame(width: barWidth(in: proxy.size.width))
                }
            }
            .frame(height: 8)
        }
    }

    private func barWidth(in width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(8, width * CGFloat(percent) / 100)
    }
}

struct RoundDirectionBar: View {
    let direction: MissDirection
    let count: Int
    let percent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(count == 0 ? AppTheme.softText : AppTheme.gold)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill((count == 0 ? AppTheme.subtleFill : AppTheme.gold.opacity(0.14))))
                Text(direction.rawValue)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("\(count) - \(percent)%")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(count == 0 ? AppTheme.softText : AppTheme.mint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.subtleFill)
                    Capsule()
                        .fill(count == 0 ? AppTheme.border : AppTheme.mint)
                        .frame(width: barWidth(in: proxy.size.width))
                }
            }
            .frame(height: 8)
        }
    }

    private var iconName: String {
        switch direction {
        case .left:
            return "arrow.left.circle.fill"
        case .right:
            return "arrow.right.circle.fill"
        case .short:
            return "arrow.down.circle.fill"
        case .long:
            return "arrow.up.circle.fill"
        default:
            return "circle.fill"
        }
    }

    private func barWidth(in width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(8, width * CGFloat(percent) / 100)
    }
}

struct RoundApproachProximitySection: View {
    let round: SavedRound

    private var proximities: [ApproachProximity] {
        round.girProximities
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Approach Proximity")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("Only counted when GIR is hit")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Text(averageText)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.mint)
            }

            if proximities.isEmpty {
                Text("No GIR proximity recorded for this round yet.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            } else {
                HStack(spacing: 8) {
                    ProximitySummaryTile(title: "Avg", value: averageText, caption: "\(proximities.count) GIR", accent: AppTheme.mint)
                    ProximitySummaryTile(title: "Best", value: round.bestGirProximity?.rawValue ?? "-", caption: "closest bucket", accent: AppTheme.gold)
                    ProximitySummaryTile(title: "Inside 10", value: "\(inside10Count)", caption: "\(inside10Percent)%", accent: AppTheme.mint)
                }

                VStack(spacing: 8) {
                    ForEach(ApproachProximity.allCases) { proximity in
                        ProximityDistributionBar(
                            proximity: proximity,
                            count: count(proximity),
                            percent: percent(proximity)
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
    }

    private var averageText: String {
        guard let average = round.averageGirProximityFeet else { return "-" }
        return "\(Int(average.rounded())) ft"
    }

    private var inside10Count: Int {
        proximities.filter { $0.midpointFeet <= 10 }.count
    }

    private var inside10Percent: Int {
        guard !proximities.isEmpty else { return 0 }
        return Int((Double(inside10Count) / Double(proximities.count) * 100).rounded())
    }

    private func count(_ proximity: ApproachProximity) -> Int {
        proximities.filter { $0 == proximity }.count
    }

    private func percent(_ proximity: ApproachProximity) -> Int {
        guard !proximities.isEmpty else { return 0 }
        return Int((Double(count(proximity)) / Double(proximities.count) * 100).rounded())
    }
}

struct ProximityDistributionBar: View {
    let proximity: ApproachProximity
    let count: Int
    let percent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(proximity.rawValue)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("\(count) - \(percent)%")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(count == 0 ? AppTheme.softText : AppTheme.mint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.subtleFill)
                    Capsule()
                        .fill(count == 0 ? AppTheme.border : AppTheme.mint)
                        .frame(width: barWidth(in: proxy.size.width))
                }
            }
            .frame(height: 8)
        }
    }

    private func barWidth(in width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(8, width * CGFloat(percent) / 100)
    }
}

struct ProximitySummaryTile: View {
    let title: String
    let value: String
    let caption: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(caption)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct SavedRoundEditorView: View {
    let round: SavedRound
    let saveRound: (SavedRound) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var handicapText: String
    @State private var holes: [EditableSavedHole]

    init(round: SavedRound, saveRound: @escaping (SavedRound) -> Void) {
        self.round = round
        self.saveRound = saveRound
        _handicapText = State(initialValue: round.handicap.map { String(format: "%.1f", $0) } ?? "")
        _holes = State(initialValue: round.holes.map(EditableSavedHole.init))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HeaderBlock(title: "Edit Round", subtitle: "\(round.courseName) - \(round.teeName) tees")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Handicap Used")
                            .font(.system(.caption, design: .rounded).weight(.heavy))
                            .foregroundStyle(AppTheme.softText)
                        TextField("No handicap", text: $handicapText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))

                    VStack(spacing: 8) {
                        ForEach($holes) { $hole in
                            EditableHoleRow(hole: $hole)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveRound(editedRound)
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.mint)
                }
            }
        }
    }

    private var editedRound: SavedRound {
        SavedRound(
            id: round.id,
            date: round.date,
            courseName: round.courseName,
            location: round.location,
            teeName: round.teeName,
            teeMarkerColor: round.teeMarkerColor,
            teeYards: round.teeYards,
            teeRating: round.teeRating,
            teeSlope: round.teeSlope,
            handicap: Double(handicapText.replacingOccurrences(of: ",", with: ".")),
            holes: holes.map { $0.savedHole }
        )
    }
}

struct EditableSavedHole: Identifiable {
    let id: UUID
    let holeNumber: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int
    var score: Int
    var putts: Int
    var pickedUp: Bool
    var fairway: MissDirection
    var green: MissDirection
    let teeClub: TeeClub?
    let approachRange: ApproachRange?
    var approachProximity: ApproachProximity?
    let firstPuttDistance: FirstPuttDistance?
    var penalties: Int
    let penaltyType: PenaltyType?
    let bunker: Bool?
    let upAndDown: Bool?
    let sandSave: Bool?
    let recovery: Bool?
    let note: String

    init(hole: SavedHoleEntry) {
        id = hole.id
        holeNumber = hole.holeNumber
        par = hole.par
        yards = hole.yards
        strokeIndex = hole.strokeIndex
        score = hole.score
        putts = hole.putts
        pickedUp = hole.pickedUp
        fairway = hole.fairway
        green = hole.green
        teeClub = hole.teeClub
        approachRange = hole.approachRange
        approachProximity = hole.approachProximity
        firstPuttDistance = hole.firstPuttDistance
        penalties = hole.penalties
        penaltyType = hole.penaltyType
        bunker = hole.bunker
        upAndDown = hole.upAndDown
        sandSave = hole.sandSave
        recovery = hole.recovery
        note = hole.note
    }

    var savedHole: SavedHoleEntry {
        SavedHoleEntry(
            id: id,
            holeNumber: holeNumber,
            par: par,
            yards: yards,
            strokeIndex: strokeIndex,
            score: score,
            putts: putts,
            pickedUp: pickedUp,
            fairway: fairway,
            green: green,
            teeClub: teeClub,
            approachRange: approachRange,
            approachProximity: green == .hit ? approachProximity : nil,
            firstPuttDistance: firstPuttDistance,
            penalties: penalties,
            penaltyType: penaltyType,
            bunker: bunker,
            upAndDown: upAndDown,
            sandSave: sandSave,
            recovery: recovery,
            note: note
        )
    }
}

struct EditableHoleRow: View {
    @Binding var hole: EditableSavedHole

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hole \(hole.holeNumber)")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("Par \(hole.par) - SI \(hole.strokeIndex)")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.softText)
            }

            HStack(spacing: 8) {
                StepperMini(title: "Score", value: $hole.score, range: 1...12, accent: AppTheme.gold)
                StepperMini(title: "Putts", value: $hole.putts, range: 0...6, accent: AppTheme.mint)
                StepperMini(title: "Pen", value: $hole.penalties, range: 0...4, accent: AppTheme.gold)
            }
            Toggle(isOn: $hole.pickedUp) {
                Label("Picked up", systemImage: "flag.checkered")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
            }
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                StatMenu(title: "Fairway", selection: $hole.fairway, choices: [.notTracked, .hit, .left, .right])
                StatMenu(title: "GIR", selection: $hole.green, choices: [.notTracked, .hit, .left, .right, .short, .long])
            }

            if hole.green == .hit {
                OptionalStatMenu(title: "Approach Proximity", selection: $hole.approachProximity, choices: ApproachProximity.allCases)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }
}

struct StepperMini: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accent: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            HStack(spacing: 8) {
                Button { value = max(range.lowerBound, value - 1) } label: {
                    Image(systemName: "minus")
                }
                Text("\(value)")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(accent)
                    .frame(width: 26)
                Button { value = min(range.upperBound, value + 1) } label: {
                    Image(systemName: "plus")
                }
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(AppTheme.ink)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct StatMenu: View {
    let title: String
    @Binding var selection: MissDirection
    let choices: [MissDirection]

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                Button(choice.rawValue) {
                    selection = choice
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.softText)
                    Text(selection.rawValue)
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.softText)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        }
    }
}

struct OptionalStatMenu<Option: Identifiable & RawRepresentable & Hashable>: View where Option.RawValue == String {
    let title: String
    @Binding var selection: Option?
    let choices: [Option]

    var body: some View {
        Menu {
            Button("Not set") {
                selection = nil
            }
            ForEach(choices) { choice in
                Button(choice.rawValue) {
                    selection = choice
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.softText)
                    Text(selection?.rawValue ?? "Not set")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.softText)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        }
    }
}

struct RoundAnalysisTile: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct ShareableRoundSummaryCard: View {
    let round: SavedRound

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Precision Golf")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.mint)
                        .textCase(.uppercase)
                    Text(round.courseName)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(round.teeName) tees - \(round.summary.dateLabel)")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                TeeMarkerSwatch(marker: round.teeMarkerColor ?? TeeMarkerColor.inferred(from: round.teeName), size: 18)
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("\(round.totalScore)")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text(scoreToParLabel)
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .foregroundStyle(scoreToPar <= 4 ? AppTheme.mint : AppTheme.gold)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(stablefordText)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.mint)
                    Text(handicapText)
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.softText)
                }
            }

            HStack(spacing: 10) {
                SummaryPill(title: "Pars", value: "\(round.pars)")
                SummaryPill(title: "GIR", value: "\(round.greensInRegulation)")
                SummaryPill(title: "Putts", value: "\(round.totalPutts)")
                SummaryPill(title: "FW", value: "\(round.fairwaysHit)")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.panel)
                .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }

    private var scoreToPar: Int {
        round.totalScore - round.totalPar
    }

    private var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }

    private var stablefordText: String {
        round.stablefordPoints.map { "\($0) pts" } ?? "- pts"
    }

    private var handicapText: String {
        round.handicap.map { "HI \(String(format: "%.1f", $0))" } ?? "HI -"
    }
}

struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

protocol VisualScorecardHole: Identifiable {
    var holeNumber: Int { get }
    var par: Int { get }
    var yards: Int { get }
    var strokeIndex: Int { get }
    var score: Int { get }
    var putts: Int { get }
    var pickedUp: Bool { get }
}

extension SavedHoleEntry: VisualScorecardHole {}
extension FirebaseSharedHoleEntry: VisualScorecardHole {}

struct VisualScorecard: View {
    let round: SavedRound

    private var frontNine: [SavedHoleEntry] {
        round.holes.filter { $0.holeNumber <= 9 }
    }

    private var backNine: [SavedHoleEntry] {
        round.holes.filter { $0.holeNumber > 9 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(round.courseName)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Digital Scorecard - \(round.teeName) tees - \(round.summary.dateLabel)")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Text("\(round.totalScore)")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.mint)
            }

            GeometryReader { proxy in
                let metrics = ScorecardMetrics(containerWidth: proxy.size.width)
                VStack(alignment: .leading, spacing: 12) {
                    ScorecardTable(title: "Out", holes: frontNine, metrics: metrics, stablefordValues: stablefordValues(for: frontNine))
                    ScorecardTable(title: "In", holes: backNine, metrics: metrics, stablefordValues: stablefordValues(for: backNine))
                    ScorecardTotalRow(round: round)
                }
            }
            .frame(height: 460)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.panel)
                .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
    }

    private func stablefordValues(for holes: [SavedHoleEntry]) -> [String]? {
        guard let handicap = round.handicap else { return nil }
        let courseHandicap = round.courseHandicap(using: handicap)
        return holes.map { "\($0.stablefordPoints(using: Double(courseHandicap)))" }
    }
}

struct ScorecardMetrics {
    let labelWidth: CGFloat
    let holeWidth: CGFloat
    let totalWidth: CGFloat
    let spacing: CGFloat = 4

    init(containerWidth: CGFloat) {
        let label = max(34, min(42, containerWidth * 0.12))
        let total = max(32, min(40, containerWidth * 0.11))
        let remaining = containerWidth - label - total - (spacing * 10)
        labelWidth = label
        totalWidth = total
        holeWidth = max(22, remaining / 9)
    }
}

struct ScorecardTable<Hole: VisualScorecardHole>: View {
    let title: String
    let holes: [Hole]
    let metrics: ScorecardMetrics
    let stablefordValues: [String]?

    var body: some View {
        VStack(spacing: 4) {
            ScorecardHoleHeader(holes: holes, total: title, metrics: metrics)
            ScorecardInfoRow(label: "SI", values: holes.map { "\($0.strokeIndex)" }, total: "", metrics: metrics)
            ScorecardInfoRow(label: "Par", values: holes.map { "\($0.par)" }, total: "\(holes.reduce(0) { $0 + $1.par })", metrics: metrics)
            ScorecardInfoRow(label: "Yds", values: holes.map { "\($0.yards)" }, total: "\(holes.reduce(0) { $0 + $1.yards })", metrics: metrics)
            ScorecardScoreRow(holes: holes, total: "\(holes.reduce(0) { $0 + $1.score })", metrics: metrics)
            if let stablefordValues {
                ScorecardInfoRow(label: "Pts", values: stablefordValues, total: "\(stablefordValues.compactMap(Int.init).reduce(0, +))", metrics: metrics)
            }
            ScorecardInfoRow(label: "Putts", values: holes.map { $0.pickedUp ? "-" : "\($0.putts)" }, total: "\(holes.reduce(0) { $0 + ($1.pickedUp ? 0 : $1.putts) })", metrics: metrics)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill.opacity(0.7)))
    }
}

struct ScorecardTotalRow: View {
    let round: SavedRound

    var body: some View {
        HStack(spacing: 6) {
            ScorecardFooterCell(title: "CH", value: courseHandicapText, accent: AppTheme.mint)
            ScorecardFooterCell(title: "Score", value: "\(round.totalScore)/\(round.totalPar)", accent: AppTheme.mint)
            ScorecardFooterCell(title: "Slope", value: "\(round.teeSlope)")
            ScorecardFooterCell(title: "Putts", value: "\(round.totalPutts)")
            ScorecardFooterCell(title: "Scr", value: "\(round.scramblePercent)%", accent: AppTheme.mint)
            ScorecardFooterCell(title: "Points", value: stablefordText, accent: AppTheme.gold)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
    }

    private var courseHandicapText: String {
        round.handicap.map { "\(round.courseHandicap(using: $0))" } ?? "-"
    }

    private var stablefordText: String {
        round.stablefordPoints.map { "\($0) pts" } ?? "- pts"
    }
}

struct ScorecardHoleHeader<Hole: VisualScorecardHole>: View {
    let holes: [Hole]
    let total: String
    let metrics: ScorecardMetrics

    var body: some View {
        HStack(spacing: metrics.spacing) {
            ScorecardBandCell(text: "Hole", width: metrics.labelWidth, isTotal: false)
            ForEach(holes) { hole in
                ScorecardBandCell(text: "\(hole.holeNumber)", width: metrics.holeWidth, isTotal: false)
            }
            ScorecardBandCell(text: total, width: metrics.totalWidth, isTotal: true)
        }
    }
}

struct ScorecardInfoRow: View {
    let label: String
    let values: [String]
    let total: String
    let metrics: ScorecardMetrics

    var body: some View {
        HStack(spacing: metrics.spacing) {
            ScorecardPlainCell(text: label, width: metrics.labelWidth, isLabel: true)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                ScorecardPlainCell(text: value, width: metrics.holeWidth)
            }
            ScorecardPlainCell(text: total, width: metrics.totalWidth, isLabel: true)
        }
    }
}

struct ScorecardScoreRow<Hole: VisualScorecardHole>: View {
    let holes: [Hole]
    let total: String
    let metrics: ScorecardMetrics

    var body: some View {
        HStack(spacing: metrics.spacing) {
            ScorecardPlainCell(text: "Score", width: metrics.labelWidth, isLabel: true)
            ForEach(holes) { hole in
                ScorecardResultCell(hole: hole, width: metrics.holeWidth)
            }
            ScorecardPlainCell(text: total, width: metrics.totalWidth, isLabel: true, accent: AppTheme.mint)
        }
    }
}

struct ScorecardBandCell: View {
    let text: String
    let width: CGFloat
    let isTotal: Bool

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(.heavy))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: width, height: 24)
            .background(
                RoundedRectangle(cornerRadius: isTotal ? 10 : 6)
                    .fill(AppTheme.mint)
            )
    }
}

struct ScorecardPlainCell: View {
    let text: String
    let width: CGFloat
    var isLabel = false
    var accent: Color?

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(isLabel || accent != nil ? .heavy : .bold))
            .foregroundStyle(accent ?? (isLabel ? AppTheme.ink : AppTheme.softText))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: width, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isLabel ? Color.white : AppTheme.panel)
            )
    }
}

struct ScorecardResultCell<Hole: VisualScorecardHole>: View {
    let hole: Hole
    let width: CGFloat

    var body: some View {
        Text("\(hole.score)")
            .font(.system(.caption, design: .rounded).weight(.heavy))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width, height: 22)
            .background(
                Group {
                    if useCircle {
                        Circle().fill(fill)
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(fill)
                    }
                }
            )
    }

    private var delta: Int {
        hole.score - hole.par
    }

    private var fill: Color {
        if delta <= -2 { return Color(red: 0.08, green: 0.40, blue: 0.78) }
        if delta == -1 { return Color(red: 0.95, green: 0.08, blue: 0.16) }
        if delta == 0 { return AppTheme.panel }
        if delta == 1 { return Color(red: 0.95, green: 0.66, blue: 0.14) }
        return Color(red: 0.06, green: 0.28, blue: 0.47)
    }

    private var foreground: Color {
        delta == 0 ? AppTheme.ink : .white
    }

    private var useCircle: Bool {
        delta == -1 || delta == 1
    }
}

struct ScorecardFooterCell: View {
    let title: String
    let value: String
    var accent: Color?

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(accent ?? AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
    }
}

struct HoleBreakdownRow: View {
    let hole: SavedHoleEntry

    var body: some View {
        HStack(spacing: 10) {
            Text("\(hole.holeNumber)")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(hole.pickedUp ? "Picked up for \(hole.score)" : "Score \(hole.score) on par \(hole.par)")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text("\(hole.yards) yds - SI \(hole.strokeIndex) - \(hole.pickedUp ? "no putts" : "\(hole.putts) putts") - \(hole.penalties) pen")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                Text(holeInsightLine)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
            }
            Spacer()
            Text(scoreLabel)
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(scoreDelta <= 0 ? AppTheme.mint : AppTheme.gold)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }

    private var scoreDelta: Int {
        hole.score - hole.par
    }

    private var scoreLabel: String {
        scoreDelta == 0 ? "E" : scoreDelta > 0 ? "+\(scoreDelta)" : "\(scoreDelta)"
    }

    private var holeInsightLine: String {
        var parts = [
            "Tee \(hole.teeClub?.rawValue ?? "Not set")",
            "Approach \(hole.green.rawValue)",
            "1st putt \(hole.firstPuttDistance?.rawValue ?? "Not set")"
        ]
        if hole.green == .hit, let proximity = hole.approachProximity {
            parts.append("Prox \(proximity.rawValue)")
        }
        if hole.bunker == true { parts.append("Bunker") }
        if hole.bunker == true && hole.score <= hole.par { parts.append("Sand save") }
        if hole.penalties > 0, let penaltyType = hole.penaltyType {
            parts.append(penaltyType.rawValue)
        }
        return parts.joined(separator: " - ")
    }
}

enum NewRoundEntryMode: String, CaseIterable {
    case database = "Course Search"
    case manual = "Manual"
}

enum NewRoundGameType: String, CaseIterable, Identifiable {
    case individual
    case matchplay
    case groupStableford

    var id: String { rawValue }

    var title: String {
        switch self {
        case .individual: return "Individual"
        case .matchplay: return "Matchplay"
        case .groupStableford: return "Group Stableford"
        }
    }

    var detail: String {
        switch self {
        case .individual: return "Score your own round"
        case .matchplay: return "Live side match"
        case .groupStableford: return "Group leaderboard"
        }
    }

    var icon: String {
        switch self {
        case .individual: return "figure.golf"
        case .matchplay: return "flag.2.crossed.fill"
        case .groupStableford: return "person.3.fill"
        }
    }
}

struct ManualHoleInput: Identifiable {
    let id = UUID()
    let number: Int
    var par: String
    var yards: String
    var strokeIndex: String
}

struct NewRoundSetupView: View {
    @Binding var selectedCourse: GolfCourse
    @Binding var selectedTee: TeeBox
    @Binding var roundHandicap: Double
    @ObservedObject var courseFavorites: CourseFavorites
    @ObservedObject var scorecardStore: CourseScorecardStore
    @ObservedObject var firebaseSocial: FirebaseSocialService
    @Binding var selectedGameType: NewRoundGameType
    @Binding var selectedMatchplayFriend: FirebaseFriendProfile?
    @Binding var selectedStablefordGroup: FirebaseGolfGroup?
    let courses: [GolfCourse]
    let refreshSelectedCourse: () -> Void
    let startRound: () -> Void

    @StateObject private var courseSearch = CourseSearchViewModel()
    @State private var editingCourse: GolfCourse?
    @State private var entryMode: NewRoundEntryMode = .database
    @State private var roundHandicapText = ""
    @State private var searchText = ""
    @State private var manualCourseName = ""
    @State private var manualLocation = ""
    @State private var manualTeeName = "White"
    @State private var manualTeeMarkerColor: TeeMarkerColor = .white
    @State private var manualYards = "6200"
    @State private var manualPar = "72"
    @State private var manualHoles = NewRoundSetupView.defaultManualHoles()
    @State private var setupWarning: String?

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - 40)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBlock(title: "New Round", subtitle: "Choose a course from the database or enter a scorecard manually.")

                    roundTypeCard

                    handicapCard

                    modePicker

                    if entryMode == .database {
                        databaseSearch
                    } else {
                        manualEntry
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .clipped()
            }
            .frame(width: proxy.size.width)
            .clipped()
        }
        .onAppear {
            syncRoundHandicapText()
        }
        .onChange(of: courseSearch.results) { _, results in
            cacheVerifiedSearchResults(results)
        }
        .sheet(item: $editingCourse) { course in
            CourseScorecardEditorView(
                course: course,
                existingOverride: scorecardStore.override(for: course)
            ) { override in
                scorecardStore.save(override)
                refreshSelectedCourse()
            }
        }
    }

    private var roundTypeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Round Type", actionTitle: selectedGameType.title)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(NewRoundGameType.allCases) { type in
                    Button {
                        selectedGameType = type
                        sanitizeGameSelection()
                    } label: {
                        NewRoundTypeTile(type: type, isSelected: selectedGameType == type)
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedGameType == .matchplay {
                matchplayFriendPicker
            } else if selectedGameType == .groupStableford {
                stablefordGroupPicker
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
        .onAppear {
            sanitizeGameSelection()
        }
    }

    private var matchplayFriendPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose opponent")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)

            if firebaseSocial.friends.isEmpty {
                Text("Add a friend first, then come back to start a matchplay round.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            } else {
                Menu {
                    ForEach(firebaseSocial.friends) { friend in
                        Button(friend.displayName) {
                            selectedMatchplayFriend = friend
                        }
                    }
                } label: {
                    selectorLabel(
                        title: selectedMatchplayFriend?.displayName ?? "Select friend",
                        icon: "person.crop.circle.badge.checkmark"
                    )
                }
            }
        }
    }

    private var stablefordGroupPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose group")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)

            if firebaseSocial.groups.isEmpty {
                Text("Create or join a group first. This will run a live Stableford leaderboard for everyone in that group.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            } else {
                Menu {
                    ForEach(firebaseSocial.groups) { group in
                        Button(group.name) {
                            selectedStablefordGroup = group
                        }
                    }
                } label: {
                    selectorLabel(
                        title: selectedStablefordGroup?.name ?? "Select group",
                        icon: "person.3.fill"
                    )
                }
            }
        }
    }

    private func selectorLabel(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(AppTheme.mint)
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.72)))
    }

    private var handicapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's Handicap Index")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Saved with this round and used for Stableford.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Text("CH \(courseHandicapPreview)")
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.mint)
            }

            HStack(spacing: 10) {
                Button {
                    roundHandicap = max(0, roundedHandicap(roundHandicap - 0.1))
                    syncRoundHandicapText()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(CounterButtonStyle())

                TextField("0.0", text: $roundHandicapText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                    .onChange(of: roundHandicapText) { _, newValue in
                        updateRoundHandicap(from: newValue)
                    }

                Button {
                    roundHandicap = min(54, roundedHandicap(roundHandicap + 0.1))
                    syncRoundHandicapText()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(CounterButtonStyle())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(NewRoundEntryMode.allCases, id: \.self) { mode in
                Button {
                    entryMode = mode
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: mode == .database ? "magnifyingglass" : "square.and.pencil")
                        Text(mode.rawValue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(entryMode == mode ? AppTheme.mint : AppTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 8).fill(entryMode == mode ? Color.white : AppTheme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(entryMode == mode ? AppTheme.mint.opacity(0.5) : AppTheme.border.opacity(0.65)))
                    .shadow(color: entryMode == mode ? AppTheme.shadow.opacity(0.7) : .clear, radius: 10, x: 0, y: 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
        .shadow(color: AppTheme.shadow.opacity(0.58), radius: 12, x: 0, y: 6)
    }

    private var databaseSearch: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button {
                    Task { await courseSearch.search(query: searchText, localCourses: courses) }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.softText)
                }
                TextField("Course, town, city or county", text: $searchText)
                    .textInputAutocapitalization(.words)
                    .foregroundStyle(AppTheme.ink)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await courseSearch.search(query: searchText, localCourses: courses) }
                    }
            }
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))

            Button {
                Task { await courseSearch.searchNearCurrentLocation(localCourses: courses) }
            } label: {
                HStack {
                    Image(systemName: "location.fill")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Use Current Location")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                        Text(courseSearch.locationSearchLabel.map { "Last searched near \($0)" } ?? "Find courses near your town or city")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(AppTheme.ink)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.6)))
            }

            if courseSearch.isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(AppTheme.mint)
                    Text("Searching courses")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                    Spacer()
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
            }

            if let errorMessage = courseSearch.errorMessage {
                Text(errorMessage)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
            }

            if let setupWarning {
                Text(setupWarning)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.gold)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
            }

            if !courseSearch.results.isEmpty {
                CourseSearchSourceBadge(source: courseSearch.resultSource)
                if let diagnostics = courseSearch.diagnostics {
                    CourseSearchDebugPanel(
                        diagnostics: diagnostics,
                        cachedResultCount: courseSearch.results.filter { scorecardStore.override(for: $0) != nil }.count
                    )
                }
            }

            SectionHeader(title: sectionTitle, actionTitle: filteredCourses.isEmpty ? nil : "\(filteredCourses.count)")

            if filteredCourses.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "star")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(AppTheme.gold)
                    Text(emptyCourseListTitle)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text(emptyCourseListMessage)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                        .lineSpacing(3)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                .shadow(color: AppTheme.shadow.opacity(0.52), radius: 10, x: 0, y: 5)
            } else {
                ForEach(filteredCourses) { course in
                    CourseSetupCard(
                        course: course,
                        selectedCourse: $selectedCourse,
                        selectedTee: $selectedTee,
                        isFavorite: courseFavorites.isFavorite(course),
                        isCached: scorecardStore.override(for: course) != nil,
                        toggleFavorite: { toggleFavoriteCourse(course) },
                        startRound: startConfiguredRound,
                        editScorecard: { editingCourse = course },
                        setupScorecard: prefillManualScorecard
                    )
                }
            }
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            ManualField(title: "Course Name", placeholder: "e.g. Moorland Pines", text: $manualCourseName)
            ManualField(title: "Location", placeholder: "Town or club area", text: $manualLocation)

            HStack(spacing: 10) {
                ManualField(title: "Tee", placeholder: "White", text: $manualTeeName)
                ManualField(title: "Yards", placeholder: "6200", text: $manualYards, keyboard: .numberPad)
                ManualField(title: "Par", placeholder: "72", text: $manualPar, keyboard: .numberPad)
            }

            TeeMarkerColorPicker(selection: $manualTeeMarkerColor) { marker in
                manualTeeName = marker.rawValue
            }

            SectionHeader(title: "Scorecard", actionTitle: "18 holes")

            VStack(spacing: 8) {
                HStack {
                    Text("Hole")
                        .frame(width: 42, alignment: .leading)
                    Text("Par")
                        .frame(width: 54, alignment: .leading)
                    Text("Yards")
                        .frame(width: 76, alignment: .leading)
                    Text("SI")
                        .frame(width: 54, alignment: .leading)
                    Spacer()
                }
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)

                ForEach($manualHoles) { $hole in
                    HStack(spacing: 9) {
                        Text("\(hole.number)")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .frame(width: 42, alignment: .leading)
                        CompactManualField(text: $hole.par)
                            .frame(width: 54)
                        CompactManualField(text: $hole.yards)
                            .frame(width: 76)
                        CompactManualField(text: $hole.strokeIndex)
                            .frame(width: 54)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))

            Button {
                createManualCourseAndStart()
            } label: {
                HStack {
                    Image(systemName: "flag.2.crossed.fill")
                    Text("Start Manual Round")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.white)
                .padding(17)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.ink))
            }
            .disabled(manualCourseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(manualCourseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
    }

    private var filteredCourses: [GolfCourse] {
        let isShowingSearchResults = !courseSearch.results.isEmpty
        let sourceCourses = isShowingSearchResults ? courseSearch.results.map(scorecardStore.courseWithKnownStrokeIndexes) : courses.filter(courseFavorites.isFavorite)
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = term.isEmpty ? sourceCourses : sourceCourses.filter {
            $0.name.lowercased().contains(term) || $0.location.lowercased().contains(term)
        }
        return isShowingSearchResults ? courseFavorites.sorted(filtered) : filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var sectionTitle: String {
        if !courseSearch.results.isEmpty {
            return "Verified Scorecards"
        }
        return "Favourite Courses"
    }

    private var emptyCourseListTitle: String {
        courseSearch.results.isEmpty ? "No favourite courses yet" : "No matching courses"
    }

    private var emptyCourseListMessage: String {
        if courseSearch.results.isEmpty {
            return "Search for a course, tap the star to save it, and it will appear here next time you start a round."
        }
        return "Try a different course, town, city or county search."
    }

    private var courseHandicapPreview: Int {
        let adjusted = (roundHandicap * Double(selectedTee.slope) / 113.0) + (selectedTee.rating - Double(selectedTee.par))
        return max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
    }

    private func roundedHandicap(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func syncRoundHandicapText() {
        roundHandicapText = String(format: "%.1f", roundHandicap)
    }

    private func updateRoundHandicap(from text: String) {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return }
        roundHandicap = min(54, max(0, roundedHandicap(value)))
    }

    private func prefillManualScorecard(from course: GolfCourse) {
        manualCourseName = course.name
        manualLocation = course.location
        manualTeeName = "White"
        manualTeeMarkerColor = .white
        manualYards = "6200"
        manualPar = "72"
        manualHoles = Self.defaultManualHoles()
        entryMode = .manual
    }

    private func toggleFavoriteCourse(_ course: GolfCourse) {
        if !courseFavorites.isFavorite(course) {
            scorecardStore.save(CourseScorecardOverride(course: scorecardStore.courseWithKnownStrokeIndexes(course)))
        }
        courseFavorites.toggle(course)
    }

    private func cacheVerifiedSearchResults(_ results: [GolfCourse]) {
        for course in results where course.hasVerifiedScorecard && !course.tees.isEmpty {
            scorecardStore.save(CourseScorecardOverride(course: scorecardStore.courseWithKnownStrokeIndexes(course)))
        }
    }

    private func createManualCourseAndStart() {
        let par = Int(manualPar) ?? 72
        let yards = Int(manualYards) ?? 6200
        let holes = manualHoles.map { hole in
            Hole(
                number: hole.number,
                par: Int(hole.par) ?? 4,
                yards: Int(hole.yards) ?? 350,
                strokeIndex: Int(hole.strokeIndex) ?? hole.number
            )
        }
        let tee = TeeBox(
            name: manualTeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "White" : manualTeeName,
            markerColor: manualTeeMarkerColor,
            yards: yards,
            par: par,
            slope: 125,
            rating: Double(par),
            holes: holes
        )
        selectedCourse = GolfCourse(
            name: manualCourseName.trimmingCharacters(in: .whitespacesAndNewlines),
            distance: "Manual",
            location: manualLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom course" : manualLocation,
            tees: [tee],
            hasVerifiedScorecard: true
        )
        selectedTee = tee
        startConfiguredRound()
    }

    private func startConfiguredRound() {
        setupWarning = nil
        sanitizeGameSelection()

        if selectedGameType == .matchplay, selectedMatchplayFriend == nil {
            setupWarning = "Choose a friend before starting matchplay."
            return
        }

        if selectedGameType == .groupStableford, selectedStablefordGroup == nil {
            setupWarning = "Choose a group before starting a live Stableford game."
            return
        }

        startRound()
    }

    private func sanitizeGameSelection() {
        switch selectedGameType {
        case .individual:
            selectedMatchplayFriend = nil
            selectedStablefordGroup = nil
        case .matchplay:
            if let selectedMatchplayFriend, firebaseSocial.friends.contains(where: { $0.uid == selectedMatchplayFriend.uid }) {
                selectedStablefordGroup = nil
                return
            }
            selectedMatchplayFriend = firebaseSocial.friends.first
            selectedStablefordGroup = nil
        case .groupStableford:
            if let selectedStablefordGroup, firebaseSocial.groups.contains(where: { $0.id == selectedStablefordGroup.id }) {
                selectedMatchplayFriend = nil
                return
            }
            selectedStablefordGroup = firebaseSocial.groups.first
            selectedMatchplayFriend = nil
        }
    }

    static func defaultManualHoles() -> [ManualHoleInput] {
        DemoData.holes.map {
            ManualHoleInput(
                number: $0.number,
                par: "\($0.par)",
                yards: "\($0.yards)",
                strokeIndex: "\($0.strokeIndex)"
            )
        }
    }
}

struct CourseSearchSourceBadge: View {
    let source: CourseSearchSource

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .heavy))
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.heavy))
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.18)))
    }

    private var icon: String {
        switch source {
        case .onDevice:
            return "checkmark.circle.fill"
        case .sessionCache:
            return "clock.arrow.circlepath"
        case .api:
            return "arrow.down.circle.fill"
        case .none:
            return "info.circle.fill"
        }
    }

    private var title: String {
        switch source {
        case .onDevice:
            return "Saved on device"
        case .sessionCache:
            return "Recent search"
        case .api:
            return "Fetched then saved"
        case .none:
            return "Search results"
        }
    }

    private var detail: String {
        switch source {
        case .onDevice:
            return "No API call"
        case .sessionCache:
            return "No new API call"
        case .api:
            return "Now cached"
        case .none:
            return "Verified"
        }
    }

    private var tint: Color {
        switch source {
        case .api:
            return AppTheme.gold
        default:
            return AppTheme.mint
        }
    }

    private var background: Color {
        switch source {
        case .api:
            return AppTheme.gold.opacity(0.12)
        default:
            return AppTheme.mintWash
        }
    }
}

struct NewRoundTypeTile: View {
    let type: NewRoundGameType
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: type.icon)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(isSelected ? .white : AppTheme.mint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(isSelected ? AppTheme.mint : AppTheme.mintWash))

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(isSelected ? AppTheme.lime : AppTheme.softText.opacity(0.55))
            }

            Text(type.title)
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(type.detail)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? AppTheme.mintWash : AppTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? AppTheme.mint.opacity(0.5) : AppTheme.border.opacity(0.7), lineWidth: isSelected ? 1.5 : 1))
    }
}

struct CourseSearchDebugPanel: View {
    let diagnostics: CourseSearchDiagnostics
    let cachedResultCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Search Details", systemImage: "info.circle.fill")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text(sourceLabel)
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(sourceTint)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(sourceTint.opacity(0.12)))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                SearchDebugMetric(title: "Area", value: diagnostics.searchLabel)
                SearchDebugMetric(title: "Range", value: radiusText)
                SearchDebugMetric(title: "Queries", value: "\(diagnostics.queryCount)")
                SearchDebugMetric(title: "Results", value: "\(diagnostics.resultCount)")
                SearchDebugMetric(title: "Verified", value: "\(diagnostics.verifiedCount)")
                SearchDebugMetric(title: "Cached", value: "\(cachedResultCount)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.8)))
    }

    private var sourceLabel: String {
        switch diagnostics.source {
        case .onDevice:
            return "Device"
        case .api:
            return "API"
        case .sessionCache:
            return "Recent"
        case .none:
            return "None"
        }
    }

    private var sourceTint: Color {
        diagnostics.source == .api ? AppTheme.gold : AppTheme.mint
    }

    private var radiusText: String {
        guard let radiusMeters = diagnostics.radiusMeters else { return "Course name" }
        let miles = Double(radiusMeters) / 1609.344
        return "\(Int(miles.rounded())) mi"
    }
}

struct SearchDebugMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct CourseSetupCard: View {
    let course: GolfCourse
    @Binding var selectedCourse: GolfCourse
    @Binding var selectedTee: TeeBox
    let isFavorite: Bool
    let isCached: Bool
    let toggleFavorite: () -> Void
    let startRound: () -> Void
    let editScorecard: () -> Void
    let setupScorecard: (GolfCourse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(course.name)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(course.location) - \(course.distance)")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if isCached {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Saved scorecard")
                        }
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.mint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(AppTheme.mintWash))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isFavorite ? AppTheme.gold : AppTheme.softText)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(AppTheme.subtleFill))
                }
                .accessibilityLabel(isFavorite ? "Remove favourite course" : "Favourite course")
                if selectedCourse == course {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.mint)
                        .font(.title2)
                }
            }

            if course.hasVerifiedScorecard {
                HStack {
                    Text("Choose tees")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.mint)
                    Spacer()
                    if isCourseSelected {
                        Text("\(selectedTee.name) selected")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(AppTheme.softText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                    ForEach(course.tees) { tee in
                        Button {
                            selectedCourse = course
                            selectedTee = tee
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 7) {
                                    TeeMarkerSwatch(marker: tee.markerColor, size: 12)
                                    Text(tee.name)
                                        .font(.system(.headline, design: .rounded))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                                Text("Par \(tee.par) - \(tee.rating, specifier: "%.1f")")
                                Text("\(tee.yards) yds")
                                Text("Slope \(tee.slope)")
                            }
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.ink)
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected(tee) ? AppTheme.mintWash : AppTheme.subtleFill))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected(tee) ? AppTheme.mint.opacity(0.55) : AppTheme.border, lineWidth: isSelected(tee) ? 1.5 : 1))
                        }
                    }
                }

            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.gold)
                    Text("Course needs hole pars, yardages and stroke indexes before scoring.")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            }

            Button(action: editScorecard) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("Edit Scorecard")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            }

            Button {
                if course.hasVerifiedScorecard {
                    guard let firstTee = course.tees.first else {
                        setupScorecard(course)
                        return
                    }
                    selectedCourse = course
                    if !isCourseSelected {
                        selectedTee = firstTee
                    }
                    startRound()
                } else {
                    setupScorecard(course)
                }
            } label: {
                HStack {
                    Text(primaryButtonTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Image(systemName: primaryButtonIcon)
                }
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.white)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mint))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.mint.opacity(0.18)))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var isCourseSelected: Bool {
        selectedCourse.favoriteKey == course.favoriteKey && course.tees.contains { $0.name == selectedTee.name }
    }

    private var primaryButtonTitle: String {
        if !course.hasVerifiedScorecard {
            return "Add Scorecard"
        }
        let teeName = isCourseSelected ? selectedTee.name : course.tees.first?.name
        return "Start Round\(teeName.map { " from \($0) Tees" } ?? "")"
    }

    private var primaryButtonIcon: String {
        course.hasVerifiedScorecard ? "chevron.right" : "hand.tap.fill"
    }

    private func isSelected(_ tee: TeeBox) -> Bool {
        isCourseSelected && selectedTee.name == tee.name
    }
}

struct CourseScorecardEditorView: View {
    let saveOverride: (CourseScorecardOverride) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var override: CourseScorecardOverride
    @State private var selectedTeeIndex = 0

    init(course: GolfCourse, existingOverride: CourseScorecardOverride?, saveOverride: @escaping (CourseScorecardOverride) -> Void) {
        self.saveOverride = saveOverride
        _override = State(initialValue: existingOverride ?? CourseScorecardOverride(course: course))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBlock(title: "Edit Scorecard", subtitle: override.name)

                    if !override.tees.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(override.tees.indices, id: \.self) { index in
                                    Button {
                                        selectedTeeIndex = index
                                    } label: {
                                        Text(override.tees[index].name)
                                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                                            .foregroundStyle(selectedTeeIndex == index ? AppTheme.mint : AppTheme.ink)
                                            .padding(.horizontal, 14)
                                            .frame(height: 40)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(selectedTeeIndex == index ? AppTheme.mintWash : AppTheme.subtleFill))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedTeeIndex == index ? AppTheme.mint.opacity(0.45) : Color.clear))
                                    }
                                }
                            }
                        }

                        teeEditor
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        recalculateSelectedTeeTotals()
                        saveOverride(override)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AppTheme.mint)
                }
            }
        }
    }

    private var teeEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IntEditField(title: "Slope", value: $override.tees[selectedTeeIndex].slope)
                DoubleEditField(title: "Rating", value: $override.tees[selectedTeeIndex].rating)
                IntEditField(title: "Par", value: $override.tees[selectedTeeIndex].par)
            }

            VStack(spacing: 8) {
                HStack {
                    Text("Hole").frame(width: 42, alignment: .leading)
                    Text("Par").frame(width: 54, alignment: .leading)
                    Text("Yards").frame(width: 76, alignment: .leading)
                    Text("SI").frame(width: 54, alignment: .leading)
                    Spacer()
                }
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)

                ForEach($override.tees[selectedTeeIndex].holes) { $hole in
                    HStack(spacing: 9) {
                        Text("\(hole.number)")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .frame(width: 42, alignment: .leading)
                        IntEditField(title: "", value: $hole.par)
                            .frame(width: 54)
                        IntEditField(title: "", value: $hole.yards)
                            .frame(width: 76)
                        IntEditField(title: "", value: $hole.strokeIndex)
                            .frame(width: 54)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
        }
    }

    private func recalculateSelectedTeeTotals() {
        guard override.tees.indices.contains(selectedTeeIndex) else { return }
        override.tees[selectedTeeIndex].par = override.tees[selectedTeeIndex].holes.reduce(0) { $0 + $1.par }
        override.tees[selectedTeeIndex].yards = override.tees[selectedTeeIndex].holes.reduce(0) { $0 + $1.yards }
    }
}

struct IntEditField: View {
    let title: String
    @Binding var value: Int

    private var text: Binding<String> {
        Binding(
            get: { "\(value)" },
            set: { value = Int($0.filter(\.isNumber)) ?? 0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
            }
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        }
    }
}

struct DoubleEditField: View {
    let title: String
    @Binding var value: Double

    private var text: Binding<String> {
        Binding(
            get: { String(format: "%.1f", value) },
            set: { value = Double($0.replacingOccurrences(of: ",", with: ".")) ?? value }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            TextField("0.0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        }
    }
}

struct ManualField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.words)
                .foregroundStyle(AppTheme.ink)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        }
    }
}

struct TeeMarkerColorPicker: View {
    @Binding var selection: TeeMarkerColor
    let selectMarker: (TeeMarkerColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tee Marker Colour")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
                ForEach(TeeMarkerColor.allCases) { marker in
                    Button {
                        selection = marker
                        selectMarker(marker)
                    } label: {
                        VStack(spacing: 7) {
                            TeeMarkerSwatch(marker: marker, size: 22)
                            Text(marker.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(selection == marker ? .white : AppTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selection == marker ? AppTheme.mint : AppTheme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
                    }
                }
            }
        }
    }
}

struct TeeMarkerSwatch: View {
    let marker: TeeMarkerColor
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(marker.color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(marker == .white ? AppTheme.border : AppTheme.border.opacity(0.9), lineWidth: 1))
            .overlay(Circle().stroke(marker == .black ? AppTheme.border : Color.clear, lineWidth: 1))
    }
}

struct CompactManualField: View {
    @Binding var text: String

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(AppTheme.ink)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct YardagesView: View {
    @ObservedObject var store: ClubYardageStore
    @State private var newClubName = ""
    @State private var isBagSetupExpanded = false

    private var activeClubs: [ClubYardage] {
        store.clubs.filter(\.isInBag)
    }

    private var mappedCount: Int {
        activeClubs.filter { $0.yards != nil }.count
    }

    private var mappedClubs: [ClubYardage] {
        activeClubs
            .filter { $0.yards != nil }
            .sorted { ($0.yards ?? 0) > ($1.yards ?? 0) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                YardageHeroCard(
                    activeCount: activeClubs.count,
                    mappedCount: mappedCount
                )

                ClubGappingSection(clubs: store.clubs)

                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            isBagSetupExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bag Setup")
                                    .font(.system(.title2, design: .rounded).weight(.heavy))
                                    .foregroundStyle(AppTheme.ink)
                                Text(isBagSetupExpanded ? "Edit clubs and carry numbers" : "Tap to edit clubs and carries")
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .foregroundStyle(AppTheme.softText)
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(AppTheme.mint)
                                .rotationEffect(.degrees(isBagSetupExpanded ? 180 : 0))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(AppTheme.mintWash))
                        }
                    }
                    .buttonStyle(.plain)

                    if isBagSetupExpanded {
                        HStack(spacing: 10) {
                            TextField("Add club, e.g. 5W", text: $newClubName)
                                .textInputAutocapitalization(.characters)
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(AppTheme.ink)
                                .padding(.vertical, 11)
                                .padding(.horizontal, 13)
                                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))

                            Button {
                                store.addCustomClub(named: newClubName)
                                newClubName = ""
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .heavy))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mint))
                            }
                            .disabled(newClubName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(newClubName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                        }

                        VStack(spacing: 10) {
                            ForEach($store.clubs) { $club in
                                YardageSetupRow(
                                    club: $club,
                                    removeClub: { store.removeClub(id: club.id) }
                                )
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
                .shadow(color: AppTheme.shadow.opacity(0.72), radius: 18, x: 0, y: 10)
            }
            .padding(20)
            .padding(.bottom, 20)
        }
    }
}

struct YardageHeroCard: View {
    let activeCount: Int
    let mappedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Yardages")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                    Text("Build your bag map and spot distance gaps quickly.")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "ruler.fill")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(AppTheme.mintWash))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panelStrong))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 1))
        .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
    }
}

struct YardageSummaryMetric: View {
    let title: String
    let value: String
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(accent.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(title)
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.72)))
        .shadow(color: AppTheme.shadow.opacity(0.55), radius: 12, x: 0, y: 6)
    }
}

struct YardageReferenceRow: View {
    let club: ClubYardage
    let maxYardage: Int

    private var progress: CGFloat {
        guard let yards = club.yards else { return 0 }
        return CGFloat(yards) / CGFloat(max(maxYardage, 1))
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(club.name)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 54, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.subtleFill)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.gold.opacity(0.86), AppTheme.mint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, proxy.size.width * progress))
                        .opacity(club.yards == nil ? 0 : 1)
                }
            }
            .frame(height: 12)

            Text(club.yards.map { "\($0) yds" } ?? "-")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(club.yards == nil ? AppTheme.softText : AppTheme.ink)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

struct YardageSetupRow: View {
    @Binding var club: ClubYardage
    let removeClub: () -> Void

    private var yardageBinding: Binding<String> {
        Binding(
            get: { club.yardageText },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                club.yards = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                club.isInBag.toggle()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: club.isInBag ? "checkmark" : "plus")
                        .font(.system(size: 12, weight: .heavy))
                    Text(club.isInBag ? "In" : "Out")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(club.isInBag ? Color.white : AppTheme.softText)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 8).fill(club.isInBag ? AppTheme.mint : AppTheme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(club.isInBag ? AppTheme.mint.opacity(0.12) : AppTheme.border.opacity(0.75)))
            }
            .accessibilityLabel(club.isInBag ? "Remove \(club.name) from bag" : "Add \(club.name) to bag")

            TextField("Club", text: $club.name)
                .textInputAutocapitalization(.characters)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 62, alignment: .leading)

            Spacer()

            TextField("-", text: yardageBinding)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 70)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))

            Text("yds")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
                .frame(width: 32, alignment: .trailing)

            Button(action: removeClub) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(AppTheme.softText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.subtleFill))
            }
            .accessibilityLabel("Remove \(club.name)")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(club.isInBag ? AppTheme.mintWash.opacity(0.58) : AppTheme.subtleFill.opacity(0.65)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(club.isInBag ? AppTheme.mint.opacity(0.14) : AppTheme.border.opacity(0.7)))
        .opacity(club.isInBag ? 1 : 0.62)
    }
}

struct CourseSelectionView: View {
    @Binding var selectedCourse: GolfCourse
    @Binding var selectedTee: TeeBox
    @ObservedObject var courseFavorites: CourseFavorites

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Select Course", subtitle: courseFavorites.favoriteKeys.isEmpty ? "Verified database courses with editable scorecards." : "Favourite courses are shown first.")

                ForEach(courseFavorites.sorted(CourseDatabase.courses)) { course in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(course.name)
                                    .font(.system(size: 21, weight: .bold, design: .rounded))
                                    .foregroundStyle(AppTheme.ink)
                                Text("\(course.location) - \(course.distance)")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(AppTheme.softText)
                            }
                            Spacer()
                            Button {
                                courseFavorites.toggle(course)
                            } label: {
                                Image(systemName: courseFavorites.isFavorite(course) ? "star.fill" : "star")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(courseFavorites.isFavorite(course) ? AppTheme.gold : AppTheme.softText)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(AppTheme.subtleFill))
                            }
                            .accessibilityLabel(courseFavorites.isFavorite(course) ? "Remove favourite course" : "Favourite course")
                            if selectedCourse == course {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(AppTheme.mint)
                                    .font(.title2)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(course.tees) { tee in
                                    Button {
                                        selectedCourse = course
                                        selectedTee = tee
                                    } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(tee.name)
                                                .font(.system(.headline, design: .rounded))
                                            HStack(spacing: 6) {
                                                TeeMarkerSwatch(marker: tee.markerColor, size: 10)
                                                Text(tee.markerColor.rawValue)
                                            }
                                            Text("\(tee.yards) yds")
                                            Text("Slope \(tee.slope) - \(tee.rating, specifier: "%.1f")")
                                        }
                                        .font(.system(.caption, design: .rounded).weight(.medium))
                                        .foregroundStyle(AppTheme.ink)
                                        .padding(14)
                                        .frame(width: 132, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(selectedTee == tee ? AppTheme.mint.opacity(0.25) : AppTheme.subtleFill))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedTee == tee ? AppTheme.mint : AppTheme.ink.opacity(0.1)))
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                }

                ScorecardPreview(tee: selectedTee)
            }
            .padding(20)
            .padding(.bottom, 20)
        }
    }
}

struct MatchplaySideGame: Equatable {
    var isActive = false
    var opponentId = ""
    var opponentName = ""
    var opponentHandicap = 0.0
    var useHandicap = true
    var opponentScores: [Int?] = []

    mutating func start(against friend: FirebaseFriendProfile, holeCount: Int) {
        isActive = true
        opponentId = friend.uid
        opponentName = friend.displayName
        opponentHandicap = friend.handicap
        opponentScores = Array(repeating: nil, count: holeCount)
    }

    mutating func stop() {
        self = MatchplaySideGame()
    }

    mutating func ensureHoleCount(_ holeCount: Int) {
        if opponentScores.count < holeCount {
            opponentScores.append(contentsOf: Array(repeating: nil, count: holeCount - opponentScores.count))
        } else if opponentScores.count > holeCount {
            opponentScores = Array(opponentScores.prefix(holeCount))
        }
    }
}

struct CloudMatchplaySideCard: View {
    let friends: [FirebaseFriendProfile]
    let selectedCourse: GolfCourse
    let selectedTee: TeeBox
    let courseHandicap: Int
    let entries: [RoundHoleEntry]
    let currentHoleIndex: Int
    let currentUserId: String?
    let playerProfile: FirebaseUserProfile?
    @ObservedObject var social: FirebaseSocialService

    private var activeMatch: FirebaseMatchplayMatch? {
        social.liveMatchplayMatches.first {
            $0.courseName == selectedCourse.name && $0.teeName == selectedTee.name
        } ?? social.liveMatchplayMatches.first
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "flag.2.crossed.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(AppTheme.mint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white))

            if let activeMatch, let currentUserId {
                activeContent(match: activeMatch, currentUserId: currentUserId)
            } else {
                inactiveContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color.white, AppTheme.mintWash], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.38), radius: 7, x: 0, y: 4)
    }

    private var inactiveContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud Matchplay")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Text("Each player enters their own score")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(friends) { friend in
                    Button(friend.displayName) {
                        Task {
                            await social.startMatchplay(
                                with: friend,
                                course: selectedCourse,
                                tee: selectedTee,
                                playerProfile: playerProfile,
                                courseHandicap: courseHandicap
                            )
                        }
                    }
                }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(AppTheme.mint))
            }
            .disabled(friends.isEmpty || currentUserId == nil)
        }
    }

    private func activeContent(match: FirebaseMatchplayMatch, currentUserId: String) -> some View {
        let opponentId = match.opponentId(for: currentUserId)
        let opponentName = opponentId.flatMap { match.players[$0]?.displayName } ?? "Friend"
        let userScore = match.score(for: currentUserId, holeIndex: currentHoleIndex)
        let opponentScore = opponentId.map { match.score(for: $0, holeIndex: currentHoleIndex) } ?? 0

        return Group {
            Text(statusText(for: match, currentUserId: currentUserId, opponentId: opponentId, opponentName: opponentName))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(statusAccent(for: match, currentUserId: currentUserId, opponentId: opponentId))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.62)))

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Text("Y \(scoreText(userScore))")
                    .foregroundStyle(AppTheme.mint)
                Text("|")
                    .foregroundStyle(AppTheme.softText.opacity(0.65))
                Text("\(opponentInitial(opponentName)) \(scoreText(opponentScore))")
                    .foregroundStyle(AppTheme.gold)
            }
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.92)))
            .lineLimit(1)

            Text(match.useHandicap ? "Net" : "Gross")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.mint)
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(Capsule().fill(Color.white))

            Button {
                Task {
                    await social.cancelMatchplay(match)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(AppTheme.softText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
    }

    private func scoreText(_ score: Int) -> String {
        score > 0 ? "\(score)" : "-"
    }

    private func shortName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? "Friend"
    }

    private func opponentInitial(_ name: String) -> String {
        String(shortName(name).prefix(1)).uppercased()
    }

    private func statusText(for match: FirebaseMatchplayMatch, currentUserId: String, opponentId: String?, opponentName: String) -> String {
        let score = matchScore(for: match, currentUserId: currentUserId, opponentId: opponentId)
        let completed = completedHoleCount(for: match, currentUserId: currentUserId, opponentId: opponentId)
        guard completed > 0 else { return "Pending" }
        let holesLeft = max(0, entries.count - completed)
        if abs(score) > holesLeft {
            return score > 0 ? "Won \(abs(score))&\(holesLeft)" : "\(opponentInitial(opponentName)) won \(abs(score))&\(holesLeft)"
        }
        if score == 0 { return "AS thru \(completed)" }
        return score > 0 ? "You \(abs(score))UP" : "\(opponentInitial(opponentName)) \(abs(score))UP"
    }

    private func statusAccent(for match: FirebaseMatchplayMatch, currentUserId: String, opponentId: String?) -> Color {
        let score = matchScore(for: match, currentUserId: currentUserId, opponentId: opponentId)
        if score > 0 { return AppTheme.mint }
        if score < 0 { return AppTheme.gold }
        return AppTheme.softText
    }

    private func completedHoleCount(for match: FirebaseMatchplayMatch, currentUserId: String, opponentId: String?) -> Int {
        guard let opponentId else { return 0 }
        return entries.indices.filter { index in
            match.score(for: currentUserId, holeIndex: index) > 0 && match.score(for: opponentId, holeIndex: index) > 0
        }.count
    }

    private func matchScore(for match: FirebaseMatchplayMatch, currentUserId: String, opponentId: String?) -> Int {
        guard let opponentId else { return 0 }
        return entries.indices.reduce(0) { total, index in
            let userScore = match.score(for: currentUserId, holeIndex: index)
            let opponentScore = match.score(for: opponentId, holeIndex: index)
            guard userScore > 0, opponentScore > 0 else { return total }
            let hole = entries[index].hole
            let userNet = userScore - match.strokes(for: currentUserId, hole: hole)
            let opponentNet = opponentScore - match.strokes(for: opponentId, hole: hole)
            if userNet < opponentNet { return total + 1 }
            if opponentNet < userNet { return total - 1 }
            return total
        }
    }
}

struct LiveRoundView: View {
    let selectedCourse: GolfCourse
    let selectedTee: TeeBox
    @Binding var currentHoleIndex: Int
    @Binding var entries: [RoundHoleEntry]
    let handicap: Double
    let friends: [FirebaseFriendProfile]
    @ObservedObject var firebaseSocial: FirebaseSocialService
    let currentUserId: String?
    let playerProfile: FirebaseUserProfile?
    let roundGameType: NewRoundGameType
    @Binding var sideMatch: MatchplaySideGame
    let finishRound: () -> Void
    let discardRound: () -> Void
    @State private var scoringStep: LiveScoringStep = .score
    @State private var showIncompleteScoreAlert = false
    @State private var showMissingPuttsAlert = false
    @State private var showDiscardRoundAlert = false
    @State private var confirmedPuttsHoleIndexes: Set<Int> = []

    var body: some View {
        let currentGross = grossScoreThroughCurrentHole
        let currentStableford = stablefordThroughCurrentHole
        let entry = Binding(
            get: { entries[currentHoleIndex] },
            set: { entries[currentHoleIndex] = $0 }
        )
        let score = Binding<Int>(
            get: { entry.wrappedValue.score },
            set: { newValue in
                entry.wrappedValue.score = newValue
                entry.wrappedValue.pickedUp = false
                if newValue > 0 {
                    scoringStep = .stats
                }
            }
        )
        let putts = Binding<Int>(
            get: { entry.wrappedValue.putts },
            set: { newValue in
                entry.wrappedValue.putts = newValue
                entry.wrappedValue.pickedUp = false
                confirmedPuttsHoleIndexes.insert(currentHoleIndex)
            }
        )

        VStack(spacing: 6) {
            LiveRoundHeaderCard(
                courseName: selectedCourse.name,
                holeNumber: entry.wrappedValue.hole.number,
                par: entry.wrappedValue.hole.par,
                yards: entry.wrappedValue.hole.yards,
                strokeIndex: entry.wrappedValue.hole.strokeIndex,
                courseHandicap: courseHandicap,
                gross: currentGross,
                scoreToPar: scoreToParThroughCurrentHole,
                stableford: currentStableford
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)

            LiveHoleNavigator(
                currentHole: currentHoleIndex + 1,
                totalHoles: entries.count,
                goPrevious: { moveToHole(currentHoleIndex - 1) },
                goNext: { moveToHole(currentHoleIndex + 1) }
            )
            .padding(.horizontal, 16)

            LiveScoringStepPill(step: $scoringStep)
                .padding(.horizontal, 16)

            if roundGameType == .matchplay || activeCloudMatch != nil {
                CloudMatchplaySideCard(
                    friends: friends,
                    selectedCourse: selectedCourse,
                    selectedTee: selectedTee,
                    courseHandicap: courseHandicap,
                    entries: entries,
                    currentHoleIndex: currentHoleIndex,
                    currentUserId: currentUserId,
                    playerProfile: playerProfile,
                    social: firebaseSocial
                )
                .padding(.horizontal, 16)
            }

            if let liveGroupGame = activeLiveGroupGame {
                LiveGroupScoringSummary(game: liveGroupGame, currentUserId: currentUserId)
                    .padding(.horizontal, 16)
            }

            Group {
                if scoringStep == .score {
                    ScoreKeypadPanel(
                        hole: entry.wrappedValue.hole,
                        score: score,
                        pickedUp: entry.wrappedValue.pickedUp,
                        pickupScore: pickupScore(for: entry.wrappedValue),
                        markPickedUp: {
                            markCurrentHolePickedUp(entry)
                            scoringStep = .stats
                        }
                    )
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(spacing: 8) {
                        CompactStepperPanel(title: "Putts", subtitle: "Total putts", value: putts, range: 0...6, accent: AppTheme.mint)
                        QuickStatsPanel(
                            showFairway: entry.wrappedValue.hole.par > 3,
                            fairway: entry.fairway,
                            green: entry.green,
                            approachProximity: entry.approachProximity,
                            penalties: entry.penalties,
                            penaltyType: entry.penaltyType,
                            bunker: entry.bunker
                        )
                    }
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 12) {
                Button {
                    if scoringStep == .stats {
                        scoringStep = .score
                    } else {
                        moveToHole(currentHoleIndex - 1)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RoundActionStyle(isPrimary: false))
                .disabled(currentHoleIndex == 0 && scoringStep == .score)

                Button {
                    if scoringStep == .score {
                        if entry.wrappedValue.score == 0 {
                            showIncompleteScoreAlert = true
                        } else {
                            scoringStep = .stats
                        }
                    } else {
                        guard puttsAreComplete(for: currentHoleIndex) else {
                            showMissingPuttsAlert = true
                            return
                        }

                        if currentHoleIndex == entries.count - 1 {
                            if entries.contains(where: { $0.score == 0 }) {
                                showIncompleteScoreAlert = true
                            } else if let missingPuttsIndex = firstHoleMissingPutts() {
                                currentHoleIndex = missingPuttsIndex
                                scoringStep = .stats
                                showMissingPuttsAlert = true
                            } else {
                                finishRound()
                            }
                        } else {
                            moveToHole(currentHoleIndex + 1)
                        }
                    }
                } label: {
                    Text(primaryActionTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RoundActionStyle(isPrimary: true))
            }
            .padding(.horizontal, 20)

            Button(role: .destructive) {
                showDiscardRoundAlert = true
            } label: {
                Label("Stop and Delete Round", systemImage: "trash")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .alert("Scores missing", isPresented: $showIncompleteScoreAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(scoringStep == .score ? "Enter a score for this hole before adding stats." : "Enter a score for every hole before finishing the round.")
        }
        .alert("Putts missing", isPresented: $showMissingPuttsAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add the putts for this hole before moving on. If you holed out from off the green, tap the putts control once so 0 putts is recorded.")
        }
        .alert("Delete current round?", isPresented: $showDiscardRoundAlert) {
            Button("Keep Round", role: .cancel) { }
            Button("Delete Round", role: .destructive) {
                discardRound()
            }
        } message: {
            Text("This will stop the live round and remove all unsaved scores and stats from this card.")
        }
        .onChange(of: currentHoleIndex) { _, newValue in
            if entries[newValue].score == 0 {
                scoringStep = .score
            }
            syncCurrentCloudMatchScore()
            syncCurrentLiveGroupGames()
        }
        .onChange(of: entries) { _, _ in
            syncCurrentCloudMatchScore()
            syncCurrentLiveGroupGames()
        }
    }

    private var activeCloudMatch: FirebaseMatchplayMatch? {
        firebaseSocial.liveMatchplayMatches.first {
            $0.courseName == selectedCourse.name && $0.teeName == selectedTee.name
        } ?? firebaseSocial.liveMatchplayMatches.first
    }

    private var activeLiveGroupGames: [FirebaseLiveGroupGame] {
        guard let currentUserId else { return [] }
        return firebaseSocial.liveGroupGames.filter { game in
            game.status == "active"
            && game.format == "stableford"
            && game.memberIds.contains(currentUserId)
            && (game.courseName.isEmpty || game.courseName == selectedCourse.name)
            && (game.teeName.isEmpty || game.teeName == selectedTee.name)
        }
    }

    private var activeLiveGroupGame: FirebaseLiveGroupGame? {
        activeLiveGroupGames.first
    }

    private var primaryActionTitle: String {
        if scoringStep == .score { return "Stats" }
        return currentHoleIndex == entries.count - 1 ? "Finish Round" : "Next Hole"
    }

    private func moveToHole(_ index: Int) {
        let nextIndex = min(max(0, index), entries.count - 1)
        guard nextIndex != currentHoleIndex else { return }
        currentHoleIndex = nextIndex
        if entries[nextIndex].score == 0 {
            scoringStep = .score
        }
    }

    private func puttsAreComplete(for index: Int) -> Bool {
        guard entries.indices.contains(index) else { return true }
        let holeEntry = entries[index]
        guard holeEntry.score > 0 else { return true }
        return holeEntry.pickedUp || confirmedPuttsHoleIndexes.contains(index)
    }

    private func firstHoleMissingPutts() -> Int? {
        entries.indices.first { !puttsAreComplete(for: $0) }
    }

    private func stablefordPoints(for entry: RoundHoleEntry) -> Int {
        if entry.pickedUp { return 0 }
        guard entry.score > 0 else { return 0 }
        let strokes = courseHandicap / 18 + (entry.hole.strokeIndex <= courseHandicap % 18 ? 1 : 0)
        let netScore = entry.score - strokes
        return max(0, 2 + (entry.hole.par - netScore))
    }

    private func markCurrentHolePickedUp(_ entry: Binding<RoundHoleEntry>) {
        entry.wrappedValue.score = pickupScore(for: entry.wrappedValue)
        entry.wrappedValue.putts = 0
        entry.wrappedValue.green = .notTracked
        entry.wrappedValue.approachProximity = nil
        entry.wrappedValue.pickedUp = true
        confirmedPuttsHoleIndexes.insert(currentHoleIndex)
    }

    private func pickupScore(for entry: RoundHoleEntry) -> Int {
        entry.hole.par + handicapStrokes(for: entry.hole) + 2
    }

    private func handicapStrokes(for hole: Hole) -> Int {
        courseHandicap / 18 + (hole.strokeIndex <= courseHandicap % 18 ? 1 : 0)
    }

    private var courseHandicap: Int {
        let adjusted = (handicap * Double(selectedTee.slope) / 113.0) + (selectedTee.rating - Double(selectedTee.par))
        return max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
    }

    private func syncCurrentCloudMatchScore() {
        guard let match = activeCloudMatch else { return }
        let score = entries[currentHoleIndex].score
        Task {
            await firebaseSocial.syncMatchplayScore(match, holeIndex: currentHoleIndex, score: score, holes: selectedTee.holes)
        }
    }

    private func syncCurrentLiveGroupGames() {
        guard !activeLiveGroupGames.isEmpty else { return }
        Task {
            await firebaseSocial.syncLiveGroupStableford(
                course: selectedCourse,
                tee: selectedTee,
                entries: entries,
                currentHoleIndex: currentHoleIndex,
                courseHandicap: courseHandicap,
                playerProfile: playerProfile
            )
        }
    }

    private var scoredEntriesThroughCurrentHole: [RoundHoleEntry] {
        Array(entries.prefix(currentHoleIndex + 1))
    }

    private var completedEntriesThroughCurrentHole: [RoundHoleEntry] {
        scoredEntriesThroughCurrentHole.filter { $0.score > 0 }
    }

    private var grossScoreThroughCurrentHole: Int {
        scoredEntriesThroughCurrentHole.reduce(0) { $0 + $1.score }
    }

    private var scoreToParThroughCurrentHole: Int {
        completedEntriesThroughCurrentHole.reduce(0) { $0 + ($1.score - $1.hole.par) }
    }

    private var stablefordThroughCurrentHole: Int {
        scoredEntriesThroughCurrentHole.reduce(0) { $0 + stablefordPoints(for: $1) }
    }
}

struct LiveGroupScoringSummary: View {
    let game: FirebaseLiveGroupGame
    let currentUserId: String?

    private var leaders: [FirebaseLiveGroupPlayer] {
        Array(game.players.prefix(3))
    }

    private var currentPlayer: FirebaseLiveGroupPlayer? {
        guard let currentUserId else { return nil }
        return game.players.first { $0.userId == currentUserId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.mint))

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.groupName)
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Text("Live Stableford")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.softText)
                }

                Spacer(minLength: 8)

                if let currentPlayer {
                    Text("You \(currentPlayer.stableford)")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.mint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white))
                }
            }

            if leaders.isEmpty {
                Text("Leaderboard starts when players enter scores.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(leaders.enumerated()), id: \.element.id) { index, player in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(index == 0 ? "Lead" : "#\(index + 1)")
                                .font(.system(.caption2, design: .rounded).weight(.heavy))
                                .foregroundStyle(AppTheme.softText)
                            Text(player.displayName)
                                .font(.system(.caption, design: .rounded).weight(.heavy))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(1)
                            Text("\(player.stableford) pts • \(player.throughText)")
                                .font(.system(.caption2, design: .rounded).weight(.bold))
                                .foregroundStyle(AppTheme.mint)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.84)))
                    }
                }
            }

            if let event = game.events.first {
                LiveGroupEventRow(event: event)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [AppTheme.mintWash, Color.white], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.34), radius: 7, x: 0, y: 4)
    }
}

struct MatchplaySideCard: View {
    let friends: [FirebaseFriendProfile]
    let selectedTee: TeeBox
    let courseHandicap: Int
    let entries: [RoundHoleEntry]
    let currentHoleIndex: Int
    @Binding var match: MatchplaySideGame

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if match.isActive {
                activeMatchContent
            } else {
                inactiveMatchContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color.white, AppTheme.mintWash], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.38), radius: 7, x: 0, y: 4)
        .onAppear {
            match.ensureHoleCount(entries.count)
        }
        .onChange(of: entries.count) { _, newValue in
            match.ensureHoleCount(newValue)
        }
    }

    private var inactiveMatchContent: some View {
        HStack(spacing: 9) {
            Image(systemName: "flag.2.crossed.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(AppTheme.mint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white))

            VStack(alignment: .leading, spacing: 2) {
                Text("Side Matchplay")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Text("Run a live side match")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(friends) { friend in
                    Button(friend.displayName) {
                        match.start(against: friend, holeCount: entries.count)
                    }
                }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(AppTheme.mint))
            }
        }
    }

    private var activeMatchContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.2.crossed.fill")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(AppTheme.mint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white))

            VStack(alignment: .leading, spacing: 1) {
                Text("vs \(match.opponentName)")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(statusText)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(statusAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 4)

            Menu {
                ForEach(1...12, id: \.self) { score in
                    Button("\(score)") {
                        setOpponentScore(score)
                    }
                }
                Button("Clear") {
                    clearOpponentScore()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("You \(userScoreText)")
                        .foregroundStyle(AppTheme.mint)
                    Text("|")
                        .foregroundStyle(AppTheme.softText.opacity(0.65))
                    Text("\(opponentShortName) \(opponentScoreText)")
                        .foregroundStyle(AppTheme.gold)
                }
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                    .lineLimit(1)
            }

            Button {
                match.useHandicap.toggle()
            } label: {
                Text(match.useHandicap ? "Net" : "Gross")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.mint)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)

            Button {
                match.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(AppTheme.softText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
    }

    private func matchScoreCell(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.18)))
    }

    private var opponentScoreControls: some View {
        HStack(spacing: 6) {
            Button {
                changeOpponentScore(by: -1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(currentOpponentScore == nil)

            Button {
                changeOpponentScore(by: 1)
            } label: {
                Image(systemName: "plus")
            }

            Button {
                clearOpponentScore()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .disabled(currentOpponentScore == nil)
        }
        .font(.system(size: 13, weight: .heavy))
        .foregroundStyle(AppTheme.mint)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.9)))
    }

    private var userScoreText: String {
        let score = entries[currentHoleIndex].score
        return score > 0 ? "\(score)" : "-"
    }

    private var opponentScoreText: String {
        guard let score = currentOpponentScore else { return "-" }
        return "\(score)"
    }

    private var opponentShortName: String {
        match.opponentName.split(separator: " ").first.map(String.init) ?? "Opp"
    }

    private var currentOpponentScore: Int? {
        guard currentHoleIndex < match.opponentScores.count else { return nil }
        return match.opponentScores[currentHoleIndex]
    }

    private func changeOpponentScore(by delta: Int) {
        match.ensureHoleCount(entries.count)
        let startingScore = entries[currentHoleIndex].hole.par
        let current = match.opponentScores[currentHoleIndex] ?? startingScore
        match.opponentScores[currentHoleIndex] = min(12, max(1, current + delta))
    }

    private func setOpponentScore(_ score: Int) {
        match.ensureHoleCount(entries.count)
        match.opponentScores[currentHoleIndex] = min(12, max(1, score))
    }

    private func clearOpponentScore() {
        guard currentHoleIndex < match.opponentScores.count else { return }
        match.opponentScores[currentHoleIndex] = nil
    }

    private var completedHoleResults: [Int] {
        entries.enumerated().compactMap { index, entry in
            guard index < match.opponentScores.count, entry.score > 0, let opponentScore = match.opponentScores[index] else {
                return nil
            }
            let hole = entry.hole
            let userNet = entry.score - strokes(for: hole, courseHandicap: match.useHandicap ? courseHandicap : 0)
            let opponentNet = opponentScore - strokes(for: hole, courseHandicap: match.useHandicap ? opponentCourseHandicap : 0)
            if userNet < opponentNet { return 1 }
            if opponentNet < userNet { return -1 }
            return 0
        }
    }

    private var matchScore: Int {
        completedHoleResults.reduce(0, +)
    }

    private var statusText: String {
        let completed = completedHoleResults.count
        guard completed > 0 else { return "Match not started" }
        let holesLeft = max(0, entries.count - completed)
        if abs(matchScore) > holesLeft {
            return matchScore > 0 ? "You won \(abs(matchScore)) & \(holesLeft)" : "\(match.opponentName) won \(abs(matchScore)) & \(holesLeft)"
        }
        if matchScore == 0 { return "All square through \(completed)" }
        let leader = matchScore > 0 ? "You" : match.opponentName
        return "\(leader) \(abs(matchScore)) UP through \(completed)"
    }

    private var statusAccent: Color {
        if matchScore > 0 { return AppTheme.mint }
        if matchScore < 0 { return AppTheme.gold }
        return AppTheme.softText
    }

    private var opponentCourseHandicap: Int {
        let adjusted = (match.opponentHandicap * Double(selectedTee.slope) / 113.0) + (selectedTee.rating - Double(selectedTee.par))
        return max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
    }

    private func strokes(for hole: Hole, courseHandicap: Int) -> Int {
        courseHandicap / 18 + (hole.strokeIndex <= courseHandicap % 18 ? 1 : 0)
    }
}

struct RoundReviewView: View {
    let course: GolfCourse
    let tee: TeeBox
    let handicap: Double
    let entries: [RoundHoleEntry]
    let saveRound: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var metrics: RoundReviewMetrics {
        RoundReviewMetrics(tee: tee, handicap: handicap, entries: entries)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Round Review")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                        HStack(spacing: 7) {
                            TeeMarkerSwatch(marker: tee.markerColor, size: 12)
                            Text("\(course.name) - \(tee.name) tees")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(AppTheme.softText)
                        }
                    }

                    HStack(spacing: 10) {
                        ReviewHeroMetric(title: "Gross", value: "\(metrics.gross)", caption: metrics.scoreToParLabel, accent: AppTheme.ink)
                        ReviewHeroMetric(title: "Stableford", value: "\(metrics.stableford)", caption: "CH \(metrics.courseHandicap)", accent: AppTheme.mint)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        RoundAnalysisTile(title: "Birdies", value: "\(metrics.birdies)", accent: AppTheme.mint)
                        RoundAnalysisTile(title: "Pars", value: "\(metrics.pars)", accent: AppTheme.ink)
                        RoundAnalysisTile(title: "Bogeys", value: "\(metrics.bogeys)", accent: AppTheme.gold)
                        RoundAnalysisTile(title: "Doubles+", value: "\(metrics.doublesOrWorse)", accent: AppTheme.gold)
                        RoundAnalysisTile(title: "Putts", value: "\(metrics.putts)", accent: AppTheme.ink)
                        RoundAnalysisTile(title: "Penalties", value: "\(metrics.penalties)", accent: AppTheme.gold)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Card Check", actionTitle: nil)
                        ReviewStatLine(title: "Fairways", value: "\(metrics.fairwaysHit)/\(metrics.fairwaysTotal)", detail: metrics.fairwayDetail)
                        ReviewStatLine(title: "GIR", value: "\(metrics.greensHit)/18", detail: metrics.greenDetail)
                        ReviewStatLine(title: "Putting", value: String(format: "%.1f", metrics.puttsPerHole), detail: "\(metrics.threePutts) three-putt holes")
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))

                    FocusCard(title: "Main Takeaway", headline: metrics.takeawayHeadline, detail: metrics.takeawayDetail)

                    Button(action: saveRound) {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                            Text("Save Round")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mint))
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back to Card") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
            }
        }
    }
}

struct RoundReviewMetrics {
    let tee: TeeBox
    let handicap: Double
    let entries: [RoundHoleEntry]

    var gross: Int { entries.reduce(0) { $0 + $1.score } }
    var par: Int { entries.reduce(0) { $0 + $1.hole.par } }
    var scoreToPar: Int { gross - par }
    var puttingEntries: [RoundHoleEntry] { entries.filter { !$0.pickedUp } }
    var putts: Int { puttingEntries.reduce(0) { $0 + $1.putts } }
    var penalties: Int { entries.reduce(0) { $0 + $1.penalties } }
    var fairwaysHit: Int { drivingEntries.filter { $0.fairway == .hit }.count }
    var fairwaysTotal: Int { drivingEntries.filter { $0.fairway != .notTracked }.count }
    var greensHit: Int { entries.filter { $0.green == .hit }.count }
    var threePutts: Int { puttingEntries.filter { $0.putts >= 3 }.count }
    var birdies: Int { entries.filter { $0.score - $0.hole.par == -1 }.count }
    var pars: Int { entries.filter { $0.score == $0.hole.par }.count }
    var bogeys: Int { entries.filter { $0.score - $0.hole.par == 1 }.count }
    var doublesOrWorse: Int { entries.filter { $0.score - $0.hole.par >= 2 }.count }
    var puttsPerHole: Double { puttingEntries.isEmpty ? 0 : Double(putts) / Double(puttingEntries.count) }

    var courseHandicap: Int {
        let adjusted = (handicap * Double(tee.slope) / 113.0) + (tee.rating - Double(tee.par))
        return max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
    }

    var stableford: Int {
        entries.reduce(0) { total, entry in
            if entry.pickedUp { return total }
            guard entry.score > 0 else { return total }
            let strokes = courseHandicap / 18 + (entry.hole.strokeIndex <= courseHandicap % 18 ? 1 : 0)
            let netScore = entry.score - strokes
            return total + max(0, 2 + (entry.hole.par - netScore))
        }
    }

    var scoreToParLabel: String {
        scoreToPar == 0 ? "Even" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }

    var fairwayDetail: String {
        guard fairwaysTotal > 0 else { return "No fairways tracked" }
        let percent = Int((Double(fairwaysHit) / Double(fairwaysTotal) * 100).rounded())
        return "\(percent)% hit"
    }

    var greenDetail: String {
        let percent = Int((Double(greensHit) / Double(max(entries.count, 1)) * 100).rounded())
        return "\(percent)% GIR"
    }

    var takeawayHeadline: String {
        if penalties > 0 { return "Penalties cost the card" }
        if threePutts > 1 { return "Putting is the fastest gain" }
        if doublesOrWorse > pars { return "Limit the big numbers" }
        if birdies > 0 { return "Scoring chances are there" }
        return "Clean baseline saved"
    }

    var takeawayDetail: String {
        if penalties > 0 {
            return "\(penalties) penalty shot\(penalties == 1 ? "" : "s") went on the card. Reducing those is the simplest next-round target."
        }
        if threePutts > 1 {
            return "\(threePutts) holes had three or more putts. Pace control should be the next practice focus."
        }
        if doublesOrWorse > pars {
            return "\(doublesOrWorse) doubles or worse against \(pars) pars. Protecting bogey will move the average quickly."
        }
        if birdies > 0 {
            return "\(birdies) birdie chance\(birdies == 1 ? "" : "s") converted with \(greensHit) greens hit."
        }
        return "This round is ready to save and add into your trend data."
    }

    private var drivingEntries: [RoundHoleEntry] {
        entries.filter { $0.hole.par > 3 }
    }
}

struct ReviewHeroMetric: View {
    let title: String
    let value: String
    let caption: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
            Text(caption)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }
}

struct ReviewStatLine: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text(detail)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            }
            Spacer()
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct TeeClubInsight {
    let attempts: Int
    let fairways: Int
    let scoreToPar: Int

    var fairwayPercent: Int {
        attempts == 0 ? 0 : Int((Double(fairways) / Double(attempts) * 100).rounded())
    }
}

struct InsightSnapshot {
    let score: Int
    let par: Int
    let roundCount: Int
    let holeCount: Int
    let putts: Int
    let fairwaysHit: Int
    let fairwaysTotal: Int
    let greensHit: Int
    let greensTotal: Int
    let penalties: Int
    let fairwayMisses: [MissDirection]
    let greenMisses: [MissDirection]
    let girProximities: [ApproachProximity]
    let threePutts: Int
    let onePutts: Int
    let twoPutts: Int
    let scrambles: Int
    let scrambleOpportunities: Int
    let sandSaves: Int
    let bunkerHoles: Int
    let birdies: Int
    let pars: Int
    let bogeys: Int
    let doublesOrWorse: Int
    let par3Score: Int
    let par3Count: Int
    let par4Score: Int
    let par4Count: Int
    let par5Score: Int
    let par5Count: Int
    let penaltyTypes: [PenaltyType]
    let teeClubInsights: [TeeClub: TeeClubInsight]

    var scoreToPar: Int { score - par }
    var averageScore: Double { roundCount == 0 ? 0 : Double(score) / Double(roundCount) }
    var puttsPerRound: Double { roundCount == 0 ? 0 : Double(putts) / Double(roundCount) }
    var puttsPerHole: Double { holeCount == 0 ? 0 : Double(putts) / Double(holeCount) }
    var birdiesPerRound: Double { averagePerRound(birdies) }
    var parsPerRound: Double { averagePerRound(pars) }
    var bogeysPerRound: Double { averagePerRound(bogeys) }
    var doublesOrWorsePerRound: Double { averagePerRound(doublesOrWorse) }
    var threePuttsPerRound: Double { averagePerRound(threePutts) }
    var girPercent: Int { greensTotal == 0 ? 0 : percent(greensHit, greensTotal) }
    var fairwayPercent: Int { fairwaysTotal == 0 ? 0 : percent(fairwaysHit, fairwaysTotal) }
    var fairwayMissLeftPercent: Int { missPercent(.left, in: fairwayMisses, total: fairwaysTotal) }
    var fairwayMissRightPercent: Int { missPercent(.right, in: fairwayMisses, total: fairwaysTotal) }
    var greenMissShortPercent: Int { missPercent(.short, in: greenMisses, total: greensTotal) }
    var greenMissLeftPercent: Int { missPercent(.left, in: greenMisses, total: greensTotal) }
    var greenMissRightPercent: Int { missPercent(.right, in: greenMisses, total: greensTotal) }
    var greenMissLongPercent: Int { missPercent(.long, in: greenMisses, total: greensTotal) }
    var averageGirProximity: Double? {
        guard !girProximities.isEmpty else { return nil }
        return Double(girProximities.reduce(0) { $0 + $1.midpointFeet }) / Double(girProximities.count)
    }
    var inside10ProximityPercent: Int {
        guard !girProximities.isEmpty else { return 0 }
        let inside10 = girProximities.filter { $0.midpointFeet <= 10 }.count
        return percent(inside10, girProximities.count)
    }
    var scramblePercent: Int { scrambleOpportunities == 0 ? 0 : percent(scrambles, scrambleOpportunities) }
    var sandSavePercent: Int { bunkerHoles == 0 ? 0 : percent(sandSaves, bunkerHoles) }
    var par3Average: Double? { averageScore(par3Score, par3Count) }
    var par4Average: Double? { averageScore(par4Score, par4Count) }
    var par5Average: Double? { averageScore(par5Score, par5Count) }

    var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }

    private func percent(_ value: Int, _ total: Int) -> Int {
        Int((Double(value) / Double(total) * 100).rounded())
    }

    private func averagePerRound(_ value: Int) -> Double {
        roundCount == 0 ? 0 : Double(value) / Double(roundCount)
    }

    private func averageScore(_ score: Int, _ count: Int) -> Double? {
        count == 0 ? nil : Double(score) / Double(count)
    }

    private func missPercent(_ direction: MissDirection, in misses: [MissDirection], total: Int) -> Int {
        guard total > 0 else { return 0 }
        let count = misses.filter { $0 == direction }.count
        return percent(count, total)
    }
}

enum InsightRange: String, CaseIterable, Identifiable {
    case last5 = "Last 5"
    case last15 = "Last 15"
    case all = "All"

    var id: String { rawValue }
}

struct InsightsDashboardContent: View {
    let entries: [RoundHoleEntry]
    let savedRounds: [SavedRound]
    let isRoundActive: Bool
    let currentHandicap: Double
    @State private var selectedRange: InsightRange = .all
    @State private var selectedInsightPage = 0

    var body: some View {
        let snapshot = selectedSnapshot

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Insights")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text(snapshot.roundCount == 0 ? "Finish a round to unlock personalised patterns." : "\(snapshot.roundCount) round baseline - \(snapshot.holeCount) holes tracked")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
            }

            PremiumInsightRangePicker(selection: $selectedRange)

            ScoringTrendInsightCard(snapshot: snapshot, rounds: selectedRounds, showNodeValues: selectedRange == .last5)

            TabView(selection: $selectedInsightPage) {
                StrengthWeaknessPremiumCard(snapshot: snapshot, currentHandicap: currentHandicap, averageScore: formatAverage(snapshot.averageScore), puttsPerRound: formatAverage(snapshot.puttsPerRound))
                    .tag(0)
                FairwayPremiumCard(snapshot: snapshot)
                    .tag(1)
                PuttingPremiumCard(snapshot: snapshot, puttsPerRound: formatAverage(snapshot.puttsPerRound))
                    .tag(2)
                ApproachPremiumCard(snapshot: snapshot, averageProximity: formatFeet(snapshot.averageGirProximity))
                    .tag(3)
                ShortGamePremiumCard(snapshot: snapshot)
                    .tag(4)
                PenaltyPremiumCard(
                    snapshot: snapshot,
                    penaltyTypes: trackedPenaltyTypes.map { ($0.rawValue, penaltyCount($0, in: snapshot), penaltyPercent($0, in: snapshot)) }
                )
                .tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 535)

            PremiumPageDots(count: 6, selection: $selectedInsightPage)
                .frame(maxWidth: .infinity)

        }
    }

    private var selectedRounds: [SavedRound] {
        let ordered = savedRounds.sorted { $0.date < $1.date }
        switch selectedRange {
        case .last5:
            return Array(ordered.suffix(5))
        case .last15:
            return Array(ordered.suffix(15))
        case .all:
            return ordered
        }
    }

    private var selectedSnapshot: InsightSnapshot {
        if !selectedRounds.isEmpty {
            return snapshot(from: selectedRounds)
        }

        return activeRoundSnapshot
    }

    private var insightSnapshot: InsightSnapshot {
        if !savedRounds.isEmpty {
            return snapshot(from: savedRounds)
        }

        return activeRoundSnapshot
    }

    private var currentYearSnapshot: InsightSnapshot {
        let currentYear = Calendar.current.component(.year, from: Date())
        let yearRounds = savedRounds.filter { Calendar.current.component(.year, from: $0.date) == currentYear }
        if !yearRounds.isEmpty {
            return snapshot(from: yearRounds)
        }

        return savedRounds.isEmpty && isRoundActive ? activeRoundSnapshot : emptySnapshot
    }

    private func snapshot(from savedRounds: [SavedRound]) -> InsightSnapshot {
        if !savedRounds.isEmpty {
            let holes = savedRounds.flatMap(\.holes)
            let puttingHoles = holes.filter { !$0.pickedUp }
            let drivingHoles = holes.filter { $0.par > 3 }
            let trackedDrivingHoles = drivingHoles.filter { $0.fairway != .notTracked }
            let trackedGreens = holes.filter { $0.green != .notTracked }
            let par3s = holes.filter { $0.par == 3 }
            let par4s = holes.filter { $0.par == 4 }
            let par5s = holes.filter { $0.par == 5 }
            return InsightSnapshot(
                score: savedRounds.reduce(0) { $0 + $1.totalScore },
                par: savedRounds.reduce(0) { $0 + $1.totalPar },
                roundCount: savedRounds.count,
                holeCount: holes.count,
                putts: savedRounds.reduce(0) { $0 + $1.totalPutts },
                fairwaysHit: drivingHoles.filter { $0.fairway == .hit }.count,
                fairwaysTotal: trackedDrivingHoles.count,
                greensHit: holes.filter { $0.green == .hit }.count,
                greensTotal: trackedGreens.count,
                penalties: holes.reduce(0) { $0 + $1.penalties },
                fairwayMisses: trackedDrivingHoles.map(\.fairway).filter { $0 != .hit },
                greenMisses: trackedGreens.map(\.green).filter { $0 != .hit },
                girProximities: holes.compactMap { $0.green == .hit ? $0.approachProximity : nil },
                threePutts: puttingHoles.filter { $0.putts >= 3 }.count,
                onePutts: puttingHoles.filter { $0.putts == 1 }.count,
                twoPutts: puttingHoles.filter { $0.putts == 2 }.count,
                scrambles: trackedGreens.filter { $0.green != .hit && $0.score <= $0.par }.count,
                scrambleOpportunities: trackedGreens.filter { $0.green != .hit }.count,
                sandSaves: holes.filter { $0.bunker == true && $0.score <= $0.par }.count,
                bunkerHoles: holes.filter { $0.bunker == true }.count,
                birdies: holes.filter { $0.score - $0.par == -1 }.count,
                pars: holes.filter { $0.score == $0.par }.count,
                bogeys: holes.filter { $0.score == $0.par + 1 }.count,
                doublesOrWorse: holes.filter { $0.score >= $0.par + 2 }.count,
                par3Score: par3s.reduce(0) { $0 + $1.score },
                par3Count: par3s.count,
                par4Score: par4s.reduce(0) { $0 + $1.score },
                par4Count: par4s.count,
                par5Score: par5s.reduce(0) { $0 + $1.score },
                par5Count: par5s.count,
                penaltyTypes: penaltyTypes(from: holes),
                teeClubInsights: teeClubInsights(from: drivingHoles)
            )
        }

        return emptySnapshot
    }

    private var activeRoundSnapshot: InsightSnapshot {
        let drivingEntries = entries.filter { $0.hole.par > 3 }
        let puttingEntries = entries.filter { !$0.pickedUp }
        let trackedDrivingEntries = drivingEntries.filter { $0.fairway != .notTracked }
        let trackedGreenEntries = entries.filter { $0.green != .notTracked }
        let par3s = entries.filter { $0.hole.par == 3 }
        let par4s = entries.filter { $0.hole.par == 4 }
        let par5s = entries.filter { $0.hole.par == 5 }
        return InsightSnapshot(
            score: entries.reduce(0) { $0 + $1.score },
            par: entries.reduce(0) { $0 + $1.hole.par },
            roundCount: isRoundActive ? 1 : 0,
            holeCount: entries.count,
            putts: puttingEntries.reduce(0) { $0 + $1.putts },
            fairwaysHit: drivingEntries.filter { $0.fairway == .hit }.count,
            fairwaysTotal: trackedDrivingEntries.count,
            greensHit: entries.filter { $0.green == .hit }.count,
            greensTotal: trackedGreenEntries.count,
            penalties: entries.reduce(0) { $0 + $1.penalties },
            fairwayMisses: trackedDrivingEntries.map(\.fairway).filter { $0 != .hit },
            greenMisses: trackedGreenEntries.map(\.green).filter { $0 != .hit },
            girProximities: entries.compactMap { $0.green == .hit ? $0.approachProximity : nil },
            threePutts: puttingEntries.filter { $0.putts >= 3 }.count,
            onePutts: puttingEntries.filter { $0.putts == 1 }.count,
            twoPutts: puttingEntries.filter { $0.putts == 2 }.count,
            scrambles: trackedGreenEntries.filter { $0.green != .hit && $0.score <= $0.hole.par }.count,
            scrambleOpportunities: trackedGreenEntries.filter { $0.green != .hit }.count,
            sandSaves: entries.filter { $0.bunker && $0.score <= $0.hole.par }.count,
            bunkerHoles: entries.filter(\.bunker).count,
            birdies: entries.filter { $0.score - $0.hole.par == -1 }.count,
            pars: entries.filter { $0.score == $0.hole.par }.count,
            bogeys: entries.filter { $0.score == $0.hole.par + 1 }.count,
            doublesOrWorse: entries.filter { $0.score >= $0.hole.par + 2 }.count,
            par3Score: par3s.reduce(0) { $0 + $1.score },
            par3Count: par3s.count,
            par4Score: par4s.reduce(0) { $0 + $1.score },
            par4Count: par4s.count,
            par5Score: par5s.reduce(0) { $0 + $1.score },
            par5Count: par5s.count,
            penaltyTypes: penaltyTypes(from: entries),
            teeClubInsights: teeClubInsights(from: drivingEntries)
        )
    }

    private var emptySnapshot: InsightSnapshot {
        InsightSnapshot(
            score: 0,
            par: 0,
            roundCount: 0,
            holeCount: 0,
            putts: 0,
            fairwaysHit: 0,
            fairwaysTotal: 0,
            greensHit: 0,
            greensTotal: 0,
            penalties: 0,
            fairwayMisses: [],
            greenMisses: [],
            girProximities: [],
            threePutts: 0,
            onePutts: 0,
            twoPutts: 0,
            scrambles: 0,
            scrambleOpportunities: 0,
            sandSaves: 0,
            bunkerHoles: 0,
            birdies: 0,
            pars: 0,
            bogeys: 0,
            doublesOrWorse: 0,
            par3Score: 0,
            par3Count: 0,
            par4Score: 0,
            par4Count: 0,
            par5Score: 0,
            par5Count: 0,
            penaltyTypes: [],
            teeClubInsights: [:]
        )
    }

    private var trackedPenaltyTypes: [PenaltyType] {
        PenaltyType.allCases.filter { $0 != .none }
    }

    private func penaltyTypes(from holes: [SavedHoleEntry]) -> [PenaltyType] {
        holes.flatMap { hole -> [PenaltyType] in
            guard hole.penalties > 0, let type = hole.penaltyType, type != .none else { return [] }
            return Array(repeating: type, count: hole.penalties)
        }
    }

    private func penaltyTypes(from entries: [RoundHoleEntry]) -> [PenaltyType] {
        entries.flatMap { entry -> [PenaltyType] in
            guard entry.penalties > 0, entry.penaltyType != .none else { return [] }
            return Array(repeating: entry.penaltyType, count: entry.penalties)
        }
    }

    private func penaltyCount(_ type: PenaltyType, in snapshot: InsightSnapshot) -> Int {
        snapshot.penaltyTypes.filter { $0 == type }.count
    }

    private func penaltyPercent(_ type: PenaltyType, in snapshot: InsightSnapshot) -> Int {
        let count = penaltyCount(type, in: snapshot)
        guard snapshot.penalties > 0 else { return 0 }
        return Int((Double(count) / Double(snapshot.penalties) * 100).rounded())
    }

    private func penaltyValue(_ type: PenaltyType, in snapshot: InsightSnapshot) -> String {
        "\(penaltyCount(type, in: snapshot)) (\(penaltyPercent(type, in: snapshot))%)"
    }

    private func penaltyCaption(_ type: PenaltyType, in snapshot: InsightSnapshot) -> String {
        guard snapshot.penalties > 0 else { return "no penalties" }
        return "of \(snapshot.penalties) penalties"
    }

    private func formatAverage(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func formatOptionalAverage(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
    }

    private func formatFeet(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(Int(value.rounded())) ft"
    }

    private func missCount(_ direction: MissDirection, in misses: [MissDirection]) -> Int {
        misses.filter { $0 == direction }.count
    }

    private func strongestArea(_ snapshot: InsightSnapshot) -> String {
        if snapshot.roundCount == 0 {
            return "Round data will build here"
        }
        if snapshot.doublesOrWorsePerRound >= 3 {
            return "Big numbers are the main leak"
        }
        if snapshot.threePuttsPerRound >= 2 {
            return "Putting pace needs attention"
        }
        if snapshot.girPercent < 30 && snapshot.greensTotal > 0 {
            return "Approach play is the next gain"
        }
        if snapshot.fairwayPercent < 35 && snapshot.fairwaysTotal > 0 {
            return "Tee accuracy is costing shots"
        }
        return "Scoring mix is building nicely"
    }

    private func scoringDetail(for snapshot: InsightSnapshot) -> String {
        "Avg \(String(format: "%.1f", snapshot.averageScore)). Par 3 \(average(snapshot.par3Score, snapshot.par3Count)), Par 4 \(average(snapshot.par4Score, snapshot.par4Count)), Par 5 \(average(snapshot.par5Score, snapshot.par5Count))."
    }

    private func greenDetail(for snapshot: InsightSnapshot) -> String {
        guard let miss = mostCommon(snapshot.greenMisses) else {
            return "No dominant approach miss recorded yet."
        }
        let count = snapshot.greenMisses.filter { $0 == miss }.count
        return "\(count) missed greens finished \(miss.rawValue.lowercased()). \(snapshot.greensHit)/\(snapshot.greensTotal) greens hit."
    }

    private func teeDetail(for snapshot: InsightSnapshot) -> String {
        let clubLine = bestTeeClub(from: snapshot).map { "Best club: \($0.rawValue) at \(snapshot.teeClubInsights[$0]?.fairwayPercent ?? 0)%." } ?? "No tee club pattern yet."
        guard let miss = mostCommon(snapshot.fairwayMisses) else {
            return "\(clubLine) No dominant tee miss recorded."
        }
        let count = snapshot.fairwayMisses.filter { $0 == miss }.count
        return "\(clubLine) \(count) tee misses finished \(miss.rawValue.lowercased())."
    }

    private func shortGameDetail(for snapshot: InsightSnapshot) -> String {
        "\(snapshot.scrambles)/\(snapshot.scrambleOpportunities) scrambles, \(snapshot.sandSavePercent)% sand saves."
    }

    private func puttingDetail(for snapshot: InsightSnapshot) -> String {
        "\(snapshot.onePutts) one-putts, \(snapshot.twoPutts) two-putts, \(snapshot.threePutts) three-putts. \(String(format: "%.2f", snapshot.puttsPerHole)) per hole."
    }

    private func mistakesDetail(for snapshot: InsightSnapshot) -> String {
        let penalty = mostCommon(snapshot.penaltyTypes)?.rawValue ?? "No dominant penalty"
        return "\(penalty). \(snapshot.doublesOrWorse) doubles or worse."
    }

    private func practiceHeadline(for snapshot: InsightSnapshot) -> String {
        if snapshot.penalties >= 2 {
            return "Penalty-free tee targets"
        }
        if snapshot.threePutts >= 2 {
            return "Lag putting pace ladder"
        }
        if snapshot.scrambleOpportunities > 0 && snapshot.scramblePercent < 35 {
            return "Short-game conversion"
        }
        if mostCommon(snapshot.greenMisses) != nil {
            return "Approach start-line control"
        }
        return "Keep building the baseline"
    }

    private func practiceDetail(for snapshot: InsightSnapshot) -> String {
        if snapshot.penalties >= 2 {
            return "Pick conservative landing zones for driver and fairway wood. Track one round with zero penalty shots as the target."
        }
        if snapshot.threePutts >= 2 {
            return "Spend 20 minutes from 25, 35 and 45 feet. Score every ball by whether the second putt is inside three feet."
        }
        if snapshot.scrambleOpportunities > 0 && snapshot.scramblePercent < 35 {
            return "You are converting \(snapshot.scramblePercent)% of missed greens into par or better. Build a block around chip-and-putt games from rough, fringe and bunker lies."
        }
        if let miss = mostCommon(snapshot.greenMisses) {
            return "Your common approach miss is \(miss.rawValue.lowercased()). Work through 10-ball blocks with alignment sticks and one clear start line."
        }
        return "Finish another round to sharpen the recommendation."
    }

    private func mostCommon(_ values: [MissDirection]) -> MissDirection? {
        values.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }
        .max { $0.value < $1.value }?
        .key
    }

    private func mostCommon(_ values: [PenaltyType]) -> PenaltyType? {
        values.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }
        .max { $0.value < $1.value }?
        .key
    }

    private func average(_ score: Int, _ count: Int) -> String {
        count == 0 ? "-" : String(format: "%.1f", Double(score) / Double(count))
    }

    private func bestTeeClub(from snapshot: InsightSnapshot) -> TeeClub? {
        snapshot.teeClubInsights
            .filter { $0.value.attempts >= 1 }
            .max {
                if $0.value.fairwayPercent == $1.value.fairwayPercent {
                    return $0.value.scoreToPar > $1.value.scoreToPar
                }
                return $0.value.fairwayPercent < $1.value.fairwayPercent
            }?
            .key
    }

    private func teeClubInsights(from holes: [SavedHoleEntry]) -> [TeeClub: TeeClubInsight] {
        Dictionary(uniqueKeysWithValues: TeeClub.allCases.compactMap { club in
            let clubHoles = holes.filter { $0.teeClub == club }
            guard !clubHoles.isEmpty else { return nil }
            return (
                club,
                TeeClubInsight(
                    attempts: clubHoles.count,
                    fairways: clubHoles.filter { $0.fairway == .hit }.count,
                    scoreToPar: clubHoles.reduce(0) { $0 + ($1.score - $1.par) }
                )
            )
        })
    }

    private func teeClubInsights(from entries: [RoundHoleEntry]) -> [TeeClub: TeeClubInsight] {
        Dictionary(uniqueKeysWithValues: TeeClub.allCases.compactMap { club in
            let clubEntries = entries.filter { $0.teeClub == club }
            guard !clubEntries.isEmpty else { return nil }
            return (
                club,
                TeeClubInsight(
                    attempts: clubEntries.count,
                    fairways: clubEntries.filter { $0.fairway == .hit }.count,
                    scoreToPar: clubEntries.reduce(0) { $0 + ($1.score - $1.hole.par) }
                )
            )
        })
    }
}

struct PremiumInsightRangePicker: View {
    @Binding var selection: InsightRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InsightRange.allCases) { range in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selection = range
                    }
                } label: {
                    Text(range.rawValue)
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .foregroundStyle(selection == range ? Color(red: 0.02, green: 0.07, blue: 0.04) : AppTheme.softText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            Capsule()
                                .fill(selection == range ? AppTheme.mint : Color.clear)
                                .shadow(color: selection == range ? AppTheme.mint.opacity(0.22) : .clear, radius: 12, x: 0, y: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().stroke(AppTheme.border.opacity(0.65)))
        .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
    }
}

struct ScoringTrendInsightCard: View {
    let snapshot: InsightSnapshot
    let rounds: [SavedRound]
    let showNodeValues: Bool

    private var trendRounds: [SavedRound] {
        Array(rounds.sorted { $0.date < $1.date }.suffix(15))
    }

    private var averageScore: String {
        guard snapshot.roundCount > 0 else { return "-" }
        return String(format: "%.1f", snapshot.averageScore)
    }

    private var previousDelta: Double? {
        guard rounds.count >= 4 else { return nil }
        let ordered = rounds.sorted { $0.date < $1.date }
        let comparisonCount = min(5, ordered.count / 2)
        let recent = Array(ordered.suffix(comparisonCount))
        let previous = Array(ordered.dropLast(comparisonCount).suffix(comparisonCount))
        guard !recent.isEmpty, !previous.isEmpty else { return nil }
        let recentAverage = Double(recent.reduce(0) { $0 + $1.totalScore }) / Double(recent.count)
        let previousAverage = Double(previous.reduce(0) { $0 + $1.totalScore }) / Double(previous.count)
        return recentAverage - previousAverage
    }

    private var frontNineAverage: String {
        formatAverage(for: rounds.flatMap { $0.holes.filter { $0.holeNumber <= 9 } })
    }

    private var backNineAverage: String {
        formatAverage(for: rounds.flatMap { $0.holes.filter { $0.holeNumber > 9 } })
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Scoring Average Trend")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.ink.opacity(0.88))
                    .textCase(.uppercase)

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(averageScore)
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.mint)
                            .lineLimit(1)
                        Text("\(max(trendRounds.count, snapshot.roundCount)) round average")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                        Text(deltaText)
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(deltaColor)
                    }
                    .frame(width: 112, alignment: .leading)

                    PremiumLineChart(rounds: trendRounds, showNodeValues: showNodeValues)
                        .frame(height: 156)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))

            VStack(spacing: 12) {
                PremiumFrontBackCard(
                    front: frontNineAverage,
                    back: backNineAverage,
                    frontPoints: stablefordAverage(frontNine: true),
                    backPoints: stablefordAverage(frontNine: false),
                    caption: frontBackCaption
                )
                PremiumParPerformanceCard(
                    par3: formatOptional(snapshot.par3Average),
                    par4: formatOptional(snapshot.par4Average),
                    par5: formatOptional(snapshot.par5Average)
                )
            }
        }
    }

    private var deltaText: String {
        guard let previousDelta else { return "Build a few more rounds" }
        let sign = previousDelta > 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.1f", abs(previousDelta))) strokes"
    }

    private var deltaColor: Color {
        guard let previousDelta else { return AppTheme.softText }
        return previousDelta <= 0 ? AppTheme.mint : AppTheme.danger
    }

    private var frontBackCaption: String {
        guard let front = Double(frontNineAverage), let back = Double(backNineAverage) else {
            return "Need more completed rounds"
        }
        let delta = abs(back - front)
        if delta < 0.3 { return "Balanced scoring" }
        return back > front ? "Back 9 needs focus" : "Front 9 needs focus"
    }

    private func formatAverage(for holes: [SavedHoleEntry]) -> String {
        guard !rounds.isEmpty else { return "-" }
        let total = holes.reduce(0) { $0 + $1.score }
        return String(format: "%.1f", Double(total) / Double(rounds.count))
    }

    private func stablefordAverage(frontNine: Bool) -> String {
        let totals = rounds.compactMap { round -> Int? in
            guard let handicap = round.handicap else { return nil }
            let courseHandicap = round.courseHandicap(using: handicap)
            let holes = round.holes.filter { frontNine ? $0.holeNumber <= 9 : $0.holeNumber > 9 }
            guard !holes.isEmpty else { return nil }
            return holes.reduce(0) { $0 + $1.stablefordPoints(using: Double(courseHandicap)) }
        }
        guard !totals.isEmpty else { return "-" }
        return String(format: "%.1f pts", Double(totals.reduce(0, +)) / Double(totals.count))
    }

    private func formatOptional(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f", value)
    }
}

struct PremiumLineChart: View {
    let rounds: [SavedRound]
    let showNodeValues: Bool

    private var chartValues: [Double] {
        rounds.isEmpty ? [0, 0] : rounds.map { Double($0.totalScore) }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let minValue = max(floor((chartValues.min() ?? 0) / 5) * 5 - 5, 0)
            let maxValue = ceil((chartValues.max() ?? 1) / 5) * 5 + 5
            let range = max(maxValue - minValue, 1)
            let plotOriginX: CGFloat = 30
            let plotWidth = max(size.width - plotOriginX - 4, 1)
            let plotHeight = max(size.height - 28, 1)

            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let fraction = CGFloat(index) / 3
                    let y = fraction * plotHeight
                    let labelValue = maxValue - (Double(fraction) * range)
                    Text("\(Int(labelValue.rounded()))")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                        .position(x: 12, y: y + 5)
                    Rectangle()
                        .fill(AppTheme.border.opacity(0.72))
                        .frame(width: plotWidth, height: 1)
                        .position(x: plotOriginX + plotWidth / 2, y: y + 5)
                }

                if !rounds.isEmpty {
                    ForEach(Array(xAxisItems.enumerated()), id: \.offset) { _, item in
                        Text(Self.shortDateFormatter.string(from: item.1))
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(AppTheme.softText)
                            .position(
                                x: plotOriginX + CGFloat(item.0) / CGFloat(max(rounds.count - 1, 1)) * plotWidth,
                                y: size.height - 5
                            )
                    }
                }

                Path { path in
                    for (index, value) in chartValues.enumerated() {
                        let x = plotOriginX + (chartValues.count == 1 ? plotWidth / 2 : CGFloat(index) / CGFloat(chartValues.count - 1) * plotWidth)
                        let y = 5 + plotHeight - CGFloat((value - minValue) / range) * plotHeight
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(AppTheme.mint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(Array(chartValues.enumerated()), id: \.offset) { index, value in
                    let x = plotOriginX + (chartValues.count == 1 ? plotWidth / 2 : CGFloat(index) / CGFloat(chartValues.count - 1) * plotWidth)
                    let y = 5 + plotHeight - CGFloat((value - minValue) / range) * plotHeight
                    ZStack {
                        Circle()
                            .fill(AppTheme.panel)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(AppTheme.mint, lineWidth: 2))
                        if showNodeValues {
                            Text("\(Int(value))")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.ink)
                                .padding(.horizontal, 4)
                                .frame(height: 16)
                                .background(Capsule().fill(AppTheme.elevated))
                                .overlay(Capsule().stroke(AppTheme.border))
                                .offset(y: y < 24 ? 14 : -14)
                        }
                    }
                    .position(x: x, y: y)
                }
            }
        }
    }

    private var xAxisItems: [(Int, Date)] {
        guard !rounds.isEmpty else { return [] }
        let indexes = Array(Set([0, rounds.count / 2, rounds.count - 1])).sorted()
        return indexes.map { ($0, rounds[$0].date) }
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}

struct PremiumFrontBackCard: View {
    let front: String
    let back: String
    let frontPoints: String
    let backPoints: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Front 9 vs Back 9")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.ink.opacity(0.88))
                .textCase(.uppercase)

            HStack(spacing: 12) {
                splitMetric(title: "Front 9 Avg", value: front, points: frontPoints)
                Divider().overlay(AppTheme.border).padding(.vertical, 4)
                splitMetric(title: "Back 9 Avg", value: back, points: backPoints)
            }

            Text(caption)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
    }

    private func splitMetric(title: String, value: String, points: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
            Text(points)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.mint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PremiumParPerformanceCard: View {
    let par3: String
    let par4: String
    let par5: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Par Performance")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.ink.opacity(0.88))
                .textCase(.uppercase)

            HStack(spacing: 10) {
                parMetric(title: "Par 3", value: par3)
                Divider().overlay(AppTheme.border).padding(.vertical, 4)
                parMetric(title: "Par 4", value: par4)
                Divider().overlay(AppTheme.border).padding(.vertical, 4)
                parMetric(title: "Par 5", value: par5)
            }

            Text("Hole scoring by par")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
    }

    private func parMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PremiumPageDots: View {
    let count: Int
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selection = index
                    }
                } label: {
                    Capsule()
                        .fill(selection == index ? AppTheme.mint : AppTheme.softText.opacity(0.28))
                        .frame(width: selection == index ? 22 : 8, height: 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(AppTheme.border.opacity(0.55)))
        .shadow(color: AppTheme.shadow, radius: 10, x: 0, y: 5)
        .accessibilityLabel("Insight pages")
    }
}

struct PremiumStatsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Circle()
                    .fill(AppTheme.mint)
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            content
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, minHeight: 410, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.11), Color.white.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
        .padding(.horizontal, 2)
    }
}

struct StrengthWeaknessPremiumCard: View {
    let snapshot: InsightSnapshot
    let currentHandicap: Double
    let averageScore: String
    let puttsPerRound: String

    private var benchmark: HandicapBenchmark {
        HandicapBenchmark(handicap: currentHandicap)
    }

    var body: some View {
        PremiumStatsCard(title: "Strengths & Weaknesses") {
            VStack(alignment: .leading, spacing: 13) {
                Text("Benchmarked against an average \(benchmark.handicapLabel) handicap golfer.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)

                PremiumBenchmarkRow(title: "Gross avg.", value: averageScore, percent: lowerIsBetterPercent(snapshot.averageScore, benchmark: benchmark.grossAverage, betterSpan: 6, worseSpan: 10), targetLabel: benchmark.grossAverageLabel)
                PremiumBenchmarkRow(title: "Fairways", value: "\(snapshot.fairwayPercent)%", percent: higherIsBetterPercent(Double(snapshot.fairwayPercent), benchmark: benchmark.fairwayPercent, worseSpan: 20, betterSpan: 12), targetLabel: benchmark.fairwayPercentLabel)
                PremiumBenchmarkRow(title: "GIR", value: "\(snapshot.girPercent)%", percent: higherIsBetterPercent(Double(snapshot.girPercent), benchmark: benchmark.girPercent, worseSpan: 18, betterSpan: 14), targetLabel: benchmark.girPercentLabel)
                PremiumBenchmarkRow(title: "Up & Downs", value: "\(snapshot.scramblePercent)%", percent: higherIsBetterPercent(Double(snapshot.scramblePercent), benchmark: benchmark.scramblePercent, worseSpan: 18, betterSpan: 14), targetLabel: benchmark.scramblePercentLabel)
                PremiumBenchmarkRow(title: "Putts / round", value: puttsPerRound, percent: lowerIsBetterPercent(snapshot.puttsPerRound, benchmark: benchmark.puttsPerRound, betterSpan: 5, worseSpan: 8), targetLabel: benchmark.puttsPerRoundLabel)
            }
        }
    }

    private func higherIsBetterPercent(_ value: Double, benchmark: Double, worseSpan: Double, betterSpan: Double) -> Int {
        guard value > 0 else { return 0 }
        if value < benchmark {
            return clampPercent(50 - ((benchmark - value) / worseSpan) * 50)
        }
        return clampPercent(50 + ((value - benchmark) / betterSpan) * 50)
    }

    private func lowerIsBetterPercent(_ value: Double, benchmark: Double, betterSpan: Double, worseSpan: Double) -> Int {
        guard value > 0 else { return 0 }
        if value < benchmark {
            return clampPercent(50 + ((benchmark - value) / betterSpan) * 50)
        }
        return clampPercent(50 - ((value - benchmark) / worseSpan) * 50)
    }

    private func clampPercent(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }
}

struct HandicapBenchmark {
    let handicap: Double

    init(handicap: Double) {
        self.handicap = min(54, max(0, handicap))
    }

    var handicapLabel: String {
        String(format: "%.1f", handicap)
    }

    var grossAverage: Double {
        74.8 + handicap
    }

    var fairwayPercent: Double {
        clamp(56.2 - (handicap * 0.70), lower: 24, upper: 62)
    }

    var girPercent: Double {
        clamp(54.8 - (handicap * 1.80), lower: 8, upper: 62)
    }

    var scramblePercent: Double {
        clamp(41.8 - handicap, lower: 10, upper: 52)
    }

    var puttsPerRound: Double {
        clamp(31.7 + (handicap * 0.20), lower: 29.5, upper: 40)
    }

    var grossAverageLabel: String {
        "\(Int(grossAverage.rounded()))"
    }

    var fairwayPercentLabel: String {
        "\(Int(fairwayPercent.rounded()))%"
    }

    var girPercentLabel: String {
        "\(Int(girPercent.rounded()))%"
    }

    var scramblePercentLabel: String {
        "\(Int(scramblePercent.rounded()))%"
    }

    var puttsPerRoundLabel: String {
        String(format: "%.1f", puttsPerRound)
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}

struct FairwayPremiumCard: View {
    let snapshot: InsightSnapshot

    var body: some View {
        PremiumStatsCard(title: "Fairways") {
            VStack(spacing: 22) {
                ZStack {
                    FairwayFanShape()
                        .stroke(AppTheme.border.opacity(0.8), lineWidth: 1.5)
                        .frame(height: 175)

                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 126, height: 82)
                            .background(
                                UnevenRoundedRectangle(topLeadingRadius: 64, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 64)
                                    .fill(AppTheme.mint)
                            )
                        HStack(spacing: 14) {
                            PremiumDirectionPill(title: "LEFT", value: "\(snapshot.fairwayMissLeftPercent)%", color: .red)
                            PremiumDirectionPill(title: "CENTER", value: "\(snapshot.fairwayPercent)%", color: AppTheme.mint)
                            PremiumDirectionPill(title: "RIGHT", value: "\(snapshot.fairwayMissRightPercent)%", color: .red)
                        }
                    }
                    .padding(.top, 44)
                }

                Text("\(snapshot.fairwaysHit)/\(max(snapshot.fairwaysTotal, 0)) tracked tee shots")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)

                Divider()

                HStack(spacing: 18) {
                    PremiumBottomMetric(title: "Score with hit", value: hitScoreText, accent: AppTheme.mint)
                    PremiumBottomMetric(title: "Common miss", value: commonMissText, accent: .red)
                }
            }
        }
    }

    private var hitScoreText: String {
        snapshot.fairwaysTotal == 0 ? "-" : "\(snapshot.fairwayPercent)%"
    }

    private var commonMissText: String {
        snapshot.fairwayMissLeftPercent >= snapshot.fairwayMissRightPercent ? "Left" : "Right"
    }
}

struct PuttingPremiumCard: View {
    let snapshot: InsightSnapshot
    let puttsPerRound: String

    var body: some View {
        PremiumStatsCard(title: "Putts") {
            VStack(spacing: 20) {
                PremiumDonutChart(
                    segments: [
                        PremiumChartSegment(value: Double(snapshot.onePutts), color: Color(red: 0.54, green: 0.78, blue: 0.54), label: "1 PUTT"),
                        PremiumChartSegment(value: Double(snapshot.twoPutts), color: AppTheme.mint, label: "2 PUTTS"),
                        PremiumChartSegment(value: Double(snapshot.threePutts), color: .red, label: "3 PUTTS")
                    ],
                    centerTitle: puttsPerRound,
                    centerSubtitle: "Putts / round"
                )
                .frame(width: 190, height: 190)

                PremiumLegend(segments: [
                    PremiumChartSegment(value: Double(snapshot.onePutts), color: Color(red: 0.54, green: 0.78, blue: 0.54), label: "1 PUTT"),
                    PremiumChartSegment(value: Double(snapshot.twoPutts), color: AppTheme.mint, label: "2 PUTTS"),
                    PremiumChartSegment(value: Double(snapshot.threePutts), color: .red, label: "3 PUTTS")
                ])

                Divider()

                HStack(spacing: 18) {
                    PremiumBottomMetric(title: "Putts Per Hole", value: String(format: "%.2f", snapshot.puttsPerHole), accent: AppTheme.mint)
                    PremiumBottomMetric(title: "3-Putts / Round", value: String(format: "%.1f", snapshot.threePuttsPerRound), accent: .red)
                }
            }
        }
    }
}

struct ApproachPremiumCard: View {
    let snapshot: InsightSnapshot
    let averageProximity: String

    var body: some View {
        PremiumStatsCard(title: "Approach Play") {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    PremiumBottomMetric(title: "GIR", value: "\(snapshot.girPercent)%", accent: AppTheme.mint)
                    PremiumBottomMetric(title: "Avg Proximity", value: averageProximity, accent: AppTheme.mint)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Approach miss pattern")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    PremiumHorizontalBar(label: "Short", value: snapshot.greenMissShortPercent, color: AppTheme.gold)
                    PremiumHorizontalBar(label: "Left", value: snapshot.greenMissLeftPercent, color: .red)
                    PremiumHorizontalBar(label: "Right", value: snapshot.greenMissRightPercent, color: .red)
                    PremiumHorizontalBar(label: "Long", value: snapshot.greenMissLongPercent, color: AppTheme.gold)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("GIR proximity")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    ForEach(ApproachProximity.allCases) { proximity in
                        PremiumHorizontalBar(label: proximity.rawValue.replacingOccurrences(of: " ft", with: ""), value: proximityPercent(proximity), color: AppTheme.mint)
                    }
                }
            }
        }
    }

    private func proximityPercent(_ proximity: ApproachProximity) -> Int {
        guard !snapshot.girProximities.isEmpty else { return 0 }
        let count = snapshot.girProximities.filter { $0 == proximity }.count
        return Int((Double(count) / Double(snapshot.girProximities.count) * 100).rounded())
    }
}

struct ShortGamePremiumCard: View {
    let snapshot: InsightSnapshot

    var body: some View {
        PremiumStatsCard(title: "Short Game") {
            VStack(spacing: 20) {
                PremiumDonutChart(
                    segments: [
                        PremiumChartSegment(value: Double(snapshot.scrambles), color: AppTheme.mint, label: "SAVED"),
                        PremiumChartSegment(value: Double(max(snapshot.scrambleOpportunities - snapshot.scrambles, 0)), color: Color(red: 0.54, green: 0.78, blue: 0.54), label: "MISSED")
                    ],
                    centerTitle: "\(snapshot.scramblePercent)%",
                    centerSubtitle: "Scramble"
                )
                .frame(width: 190, height: 190)

                PremiumLegend(segments: [
                    PremiumChartSegment(value: Double(snapshot.scrambles), color: AppTheme.mint, label: "SAVED"),
                    PremiumChartSegment(value: Double(max(snapshot.scrambleOpportunities - snapshot.scrambles, 0)), color: Color(red: 0.54, green: 0.78, blue: 0.54), label: "MISSED")
                ])

                Divider()

                HStack(spacing: 18) {
                    PremiumBottomMetric(title: "Scrambles", value: "\(snapshot.scrambles)/\(snapshot.scrambleOpportunities)", accent: AppTheme.mint)
                    PremiumBottomMetric(title: "Sand Save", value: "\(snapshot.sandSavePercent)%", accent: AppTheme.gold)
                    PremiumBottomMetric(title: "Bunkers", value: "\(snapshot.bunkerHoles)", accent: AppTheme.ink)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Around the green")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    PremiumHorizontalBar(label: "Scramble", value: snapshot.scramblePercent, color: AppTheme.mint)
                    PremiumHorizontalBar(label: "Sand", value: snapshot.sandSavePercent, color: AppTheme.gold)
                }
            }
        }
    }
}

struct PenaltyPremiumCard: View {
    let snapshot: InsightSnapshot
    let penaltyTypes: [(String, Int, Int)]

    private var activePenaltyTypes: [(String, Int, Int)] {
        penaltyTypes.filter { $0.1 > 0 }
    }

    var body: some View {
        PremiumStatsCard(title: "Penalties") {
            VStack(spacing: 20) {
                PremiumDonutChart(
                    segments: donutSegments,
                    centerTitle: "\(snapshot.penalties)",
                    centerSubtitle: snapshot.penalties == 1 ? "Penalty" : "Penalties"
                )
                .frame(width: 190, height: 190)

                PremiumLegend(segments: donutSegments)

                Divider()

                HStack(spacing: 18) {
                    PremiumBottomMetric(title: "Total", value: "\(snapshot.penalties)", accent: .red)
                    PremiumBottomMetric(title: "Per Round", value: String(format: "%.1f", penaltiesPerRound), accent: AppTheme.gold)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Penalty type")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)

                    if activePenaltyTypes.isEmpty {
                        Text("No OB, water, lost ball or unplayable penalties recorded in this range.")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.softText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(activePenaltyTypes.enumerated()), id: \.offset) { _, item in
                            PremiumPenaltyBar(label: item.0, count: item.1, percent: item.2, color: penaltyColor(for: item.0))
                        }
                    }
                }
            }
        }
    }

    private var donutSegments: [PremiumChartSegment] {
        if activePenaltyTypes.isEmpty {
            return [PremiumChartSegment(value: 1, color: Color(red: 0.54, green: 0.78, blue: 0.54), label: "CLEAN")]
        }
        return activePenaltyTypes.map { item in
            PremiumChartSegment(value: Double(item.1), color: penaltyColor(for: item.0), label: item.0.uppercased())
        }
    }

    private var penaltiesPerRound: Double {
        guard snapshot.roundCount > 0 else { return 0 }
        return Double(snapshot.penalties) / Double(snapshot.roundCount)
    }

    private func penaltyColor(for label: String) -> Color {
        switch label {
        case "Water": return .blue
        case "OB": return .red
        case "Lost": return AppTheme.gold
        case "Unplayable": return .orange
        default: return .red
        }
    }
}

struct PremiumChartSegment {
    let value: Double
    let color: Color
    let label: String
}

struct PremiumDonutChart: View {
    let segments: [PremiumChartSegment]
    let centerTitle: String
    let centerSubtitle: String

    private var total: Double {
        max(segments.reduce(0) { $0 + $1.value }, 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.subtleFill, lineWidth: 42)

            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Circle()
                    .trim(from: start(for: index), to: end(for: index))
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 42, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 3) {
                Text(centerTitle)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(centerSubtitle)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 112)
        }
    }

    private func start(for index: Int) -> CGFloat {
        CGFloat(segments.prefix(index).reduce(0) { $0 + $1.value } / total)
    }

    private func end(for index: Int) -> CGFloat {
        CGFloat(segments.prefix(index + 1).reduce(0) { $0 + $1.value } / total)
    }
}

struct PremiumLegend: View {
    let segments: [PremiumChartSegment]

    private let columns = [
        GridItem(.adaptive(minimum: 72), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Text(segment.label)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(Capsule().fill(segment.color))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

struct PremiumPenaltyBar: View {
    let label: String
    let count: Int
    let percent: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer()
                Text("\(count) - \(percent)%")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(1)
            }

            GeometryReader { proxy in
                let clampedPercent = min(max(percent, 0), 100)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.subtleFill)
                    Capsule()
                        .fill(color)
                        .frame(width: max(8, proxy.size.width * CGFloat(clampedPercent) / 100))
                }
            }
            .frame(height: 9)
        }
    }
}

struct PremiumBenchmarkRow: View {
    let title: String
    let value: String
    let percent: Int
    let targetLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    LinearGradient(colors: [.red, AppTheme.gold, AppTheme.mint], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 20)
                        .clipShape(Capsule())
                        .offset(y: 24)
                    Rectangle()
                        .fill(AppTheme.ink.opacity(0.78))
                        .frame(width: 4, height: 18)
                        .offset(x: proxy.size.width * 0.5, y: 25)
                    Text(targetLabel)
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(red: 0.12, green: 0.18, blue: 0.14))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.96)))
                        .offset(x: proxy.size.width * 0.5 - 28, y: -2)
                    Text(value)
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white).overlay(Capsule().stroke(statusColor, lineWidth: 2)))
                        .offset(x: min(max(proxy.size.width * CGFloat(percent) / 100 - 25, 0), proxy.size.width - 56), y: 20)
                }
            }
            .frame(height: 52)
        }
    }

    private var statusColor: Color {
        percent >= 50 ? Color(red: 0.05, green: 0.48, blue: 0.20) : Color(red: 0.76, green: 0.40, blue: 0.05)
    }
}

struct PremiumDirectionPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 86, height: 24)
                .background(Capsule().fill(color))
            Text(value)
                .font(.system(size: 27, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PremiumBottomMetric: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(size: 31, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.62)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PremiumHorizontalBar: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
            GeometryReader { proxy in
                Capsule()
                    .fill(color)
                    .frame(width: max(value == 0 ? 0 : 7, proxy.size.width * CGFloat(min(value, 100)) / 100))
            }
            .frame(height: 16)
            Text("\(value)%")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 42, alignment: .leading)
        }
        .frame(height: 19)
    }
}

struct PremiumMiniStat: View {
    let title: String
    let value: String
    let caption: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
        .shadow(color: AppTheme.shadow, radius: 10, x: 0, y: 5)
    }
}

struct FairwayFanShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 16, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 16, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - 34))
        return path
    }
}

struct PrecisionBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var backup: PrecisionBackup

    init(backup: PrecisionBackup) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        backup = try decoder.decode(PrecisionBackup.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}

struct AISeasonReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var report: AISeasonReport

    init(report: AISeasonReport) {
        self.report = report
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        report = try decoder.decode(AISeasonReport.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(report))
    }
}

struct AISeasonReport: Codable {
    let version: Int
    let exportedAt: Date
    let player: AISeasonPlayer
    let season: AISeasonWindow
    let aiBrief: String
    let summary: AISeasonSummary
    let trends: AISeasonTrends
    let parScoring: [AIParScoringExport]
    let rounds: [AIRoundExport]
    let handicapHistory: [HandicapRecord]
}

struct AISeasonPlayer: Codable {
    let name: String
    let homeClub: String
    let currentHandicapIndex: Double
}

struct AISeasonWindow: Codable {
    let year: Int
    let includedRoundCount: Int
    let firstRoundDate: Date?
    let latestRoundDate: Date?
}

struct AISeasonSummary: Codable {
    let averageGross: Double?
    let bestGross: Int?
    let latestGross: Int?
    let averageStableford: Double?
    let bestStableford: Int?
    let averagePutts: Double?
    let fairwaysHitPercent: Int?
    let girPercent: Int?
    let scramblingPercent: Int?
    let sandSavePercent: Int?
    let penaltiesPerRound: Double?
    let scoringMixPerRound: AIScoringMixExport
}

struct AIScoringMixExport: Codable {
    let eaglesOrBetter: Double
    let birdies: Double
    let pars: Double
    let bogeys: Double
    let doublesOrWorse: Double
}

struct AISeasonTrends: Codable {
    let last5AverageGross: Double?
    let previous5AverageGross: Double?
    let last10AverageGross: Double?
    let previous10AverageGross: Double?
    let recentRoundScores: [AITrendPointExport]
    let monthlyCheckpoints: [AISeasonCheckpointExport]
}

struct AITrendPointExport: Codable {
    let date: Date
    let courseName: String
    let gross: Int
    let toPar: Int
    let stablefordPoints: Int?
}

struct AISeasonCheckpointExport: Codable {
    let month: String
    let roundsPlayed: Int
    let averageGross: Double?
    let averageStableford: Double?
    let averagePutts: Double?
    let fairwaysHitPercent: Int?
    let girPercent: Int?
    let scramblingPercent: Int?
    let penaltiesPerRound: Double?
}

struct AIParScoringExport: Codable {
    let par: Int
    let holesPlayed: Int
    let averageGross: Double?
    let averageToPar: Double?
    let stablefordPointsAverage: Double?
}

struct AIRoundExport: Codable {
    let id: UUID
    let date: Date
    let courseName: String
    let location: String
    let teeName: String
    let teeYards: Int
    let teeRating: Double
    let teeSlope: Int
    let handicapIndex: Double?
    let playingHandicap: Int?
    let totalGross: Int
    let totalPar: Int
    let totalToPar: Int
    let stablefordPoints: Int?
    let totalPutts: Int
    let fairwaysHit: Int
    let fairwaysTracked: Int
    let greensHit: Int
    let greensTracked: Int
    let scrambles: Int
    let scramblingOpportunities: Int
    let sandSaves: Int
    let bunkerHoles: Int
    let penalties: Int
    let scoringMix: AIRoundScoringMixExport
    let holes: [AIHoleExport]
}

struct AIRoundScoringMixExport: Codable {
    let eaglesOrBetter: Int
    let birdies: Int
    let pars: Int
    let bogeys: Int
    let doublesOrWorse: Int
}

struct AIHoleExport: Codable {
    let holeNumber: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int
    let grossScore: Int
    let toPar: Int
    let stablefordPoints: Int?
    let putts: Int
    let pickedUp: Bool
    let fairway: String
    let greenInRegulation: String
    let teeClub: String?
    let approachRange: String?
    let approachProximity: String?
    let firstPuttDistance: String?
    let penalties: Int
    let penaltyType: String?
    let bunker: Bool?
    let upAndDown: Bool?
    let sandSave: Bool?
    let recovery: Bool?
    let note: String
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case account = "Account"
    case golf = "Golf"
    case data = "Data"

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var playerSettings: PlayerSettings
    let savedRounds: [SavedRound]
    @ObservedObject var roundArchive: RoundArchive
    @ObservedObject var courseFavorites: CourseFavorites
    @ObservedObject var goalArchive: GoalArchive
    @ObservedObject var clubYardages: ClubYardageStore
    @ObservedObject var handicapHistory: HandicapHistoryStore
    @ObservedObject var scorecardStore: CourseScorecardStore
    @ObservedObject var firebaseAccount: FirebaseAccountService
    @ObservedObject var firebaseSocial: FirebaseSocialService
    @ObservedObject var firebaseRoundSync: FirebaseRoundSyncService
    @Binding var profileName: String
    @Binding var profileHomeClub: String
    @State private var handicapText = ""
    @State private var backupDocument: PrecisionBackupDocument?
    @State private var aiSeasonReportDocument: AISeasonReportDocument?
    @State private var isExportingBackup = false
    @State private var isExportingAISeasonReport = false
    @State private var isImportingBackup = false
    @State private var pendingBackup: PrecisionBackup?
    @State private var showRestoreConfirmation = false
    @State private var restoreMessage: String?
    @State private var scorecardPendingDelete: CourseScorecardOverride?
    @State private var showAllCachedScorecards = false
    @State private var selectedSection: SettingsSection = .account
    @AppStorage("precision.appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Settings", subtitle: "Set your handicap index for course-adjusted Stableford tracking.")

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Appearance", actionTitle: nil)
                    Picker("Appearance", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Choose Light or Dark, or follow your iPhone setting.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))

                Picker("Settings section", selection: $selectedSection) {
                    ForEach(SettingsSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .tint(AppTheme.controlGreen)

                if selectedSection == .account {
                    VStack(alignment: .leading, spacing: 14) {
                    Text("Player Profile")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)

                    ProfileTextField(title: "Name", placeholder: "Your name", text: $profileName)
                    ProfileTextField(title: "Home Club", placeholder: "Optional", text: $profileHomeClub)

                    Text("Profile details are stored locally on this phone and do not alter completed rounds.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .lineSpacing(3)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                FirebaseAccountCard(
                    account: firebaseAccount,
                    roundSync: firebaseRoundSync,
                    localRoundCount: savedRounds.count,
                    profileName: profileName,
                    handicap: playerSettings.handicap,
                    homeClub: profileHomeClub,
                    syncRounds: {
                        await firebaseRoundSync.sync(rounds: savedRounds)
                    },
                    restoreRounds: {
                        if let restoredRounds = await firebaseRoundSync.restoreRounds(), !restoredRounds.isEmpty {
                            roundArchive.replace(with: restoredRounds)
                        }
                    }
                )

                    FriendCodeSettingsCard(
                    account: firebaseAccount,
                    social: firebaseSocial,
                    profileName: profileName,
                    handicap: playerSettings.handicap,
                    homeClub: profileHomeClub
                    )
                }

                if selectedSection == .golf {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Handicap Index")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)

                    HStack(spacing: 12) {
                        TextField("18.0", text: $handicapText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                            .onChange(of: handicapText) { _, newValue in
                                updateHandicap(from: newValue)
                            }

                        VStack(spacing: 8) {
                            Button {
                                playerSettings.handicap = min(54, playerSettings.handicap + 1)
                                syncHandicapText()
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(CounterButtonStyle())

                            Button {
                                playerSettings.handicap = max(0, playerSettings.handicap - 1)
                                syncHandicapText()
                            } label: {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(CounterButtonStyle())
                        }
                    }

                    Text("Stableford uses your handicap index, then converts it to a course handicap from the selected tee slope and rating.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .lineSpacing(3)

                    Button {
                        handicapHistory.record(playerSettings.handicap)
                    } label: {
                        Label("Record Handicap Change", systemImage: "clock.badge.checkmark")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(AppTheme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                }

                if selectedSection == .data {
                    VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Saved Scorecards", actionTitle: scorecardStore.overrides.isEmpty ? nil : "\(scorecardStore.overrides.count)")

                    if scorecardStore.overrides.isEmpty {
                        Text("Search for verified courses or star a course to cache its scorecard here.")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                            .lineSpacing(3)
                    } else {
                        ForEach(displayedScorecards) { scorecard in
                            CachedScorecardRow(scorecard: scorecard) {
                                scorecardPendingDelete = scorecard
                            }
                        }

                        if scorecardStore.overrides.count > 5 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAllCachedScorecards.toggle()
                                }
                            } label: {
                                HStack {
                                    Text(showAllCachedScorecards ? "Show Fewer" : "View \(scorecardStore.overrides.count - 5) More")
                                    Spacer()
                                    Image(systemName: showAllCachedScorecards ? "chevron.up" : "chevron.down")
                                }
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(AppTheme.mint)
                                .padding(13)
                                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                    .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "AI Season Export", actionTitle: "\(currentSeasonRounds.count) rounds")

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Download a structured season report for ChatGPT, Claude or another AI coach.")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            Text("Includes season averages, trends, par scoring, putting, fairways, GIR, scrambling, sand saves, penalties, handicap history and every hole from this season.")
                                .font(.system(.caption, design: .rounded).weight(.medium))
                                .foregroundStyle(AppTheme.softText)
                                .lineSpacing(3)
                        }

                        Button {
                            aiSeasonReportDocument = AISeasonReportDocument(report: makeAISeasonReport())
                            isExportingAISeasonReport = true
                        } label: {
                            HStack {
                                Image(systemName: "brain.head.profile")
                                Text("Export AI Season Report")
                                Spacer()
                                Text(String(currentSeasonYear))
                                    .font(.system(.caption, design: .rounded).weight(.bold))
                            }
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(15)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.controlGreen))
                        }
                        .disabled(currentSeasonRounds.isEmpty)
                        .opacity(currentSeasonRounds.isEmpty ? 0.55 : 1)

                        if currentSeasonRounds.isEmpty {
                            Text("Save a completed round this season before exporting an AI report.")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(AppTheme.softText)
                        }
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                    .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                    VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Data Backup", actionTitle: nil)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rounds and cached scorecards are stored locally on this phone in the app database.")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("Export before deleting the app or changing phone. The backup includes completed rounds, handicap, favourite courses, cached scorecards, custom goals and yardages.")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                            .lineSpacing(3)
                    }

                    Button {
                        backupDocument = PrecisionBackupDocument(backup: makeBackup())
                        isExportingBackup = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up.fill")
                            Text("Export Backup")
                            Spacer()
                            Text("\(savedRounds.count) rounds • \(scorecardStore.overrides.count) scorecards")
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(15)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mint))
                    }

                    Button {
                        isImportingBackup = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("Restore Backup")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .padding(15)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                    }

                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.softText)
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                    .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .onAppear {
            syncHandicapText()
        }
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "PrecisionGolf-Backup"
        ) { _ in }
        .fileExporter(
            isPresented: $isExportingAISeasonReport,
            document: aiSeasonReportDocument,
            contentType: .json,
            defaultFilename: "PrecisionGolf-AI-Season-\(currentSeasonYear)"
        ) { _ in }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            importBackup(result)
        }
        .alert("Restore backup?", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingBackup = nil
            }
            Button("Restore", role: .destructive) {
                restorePendingBackup()
            }
        } message: {
            Text("This will replace the local app data with the selected backup. Export your current data first if you want to keep a separate copy.")
        }
        .alert("Delete saved scorecard?", isPresented: Binding(
            get: { scorecardPendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    scorecardPendingDelete = nil
                }
            }
        )) {
            Button("Cancel", role: .cancel) {
                scorecardPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let scorecardPendingDelete {
                    scorecardStore.delete(scorecardPendingDelete)
                }
                scorecardPendingDelete = nil
            }
        } message: {
            Text("This removes the locally cached scorecard only. Your completed rounds are not changed.")
        }
    }

    private var displayedScorecards: [CourseScorecardOverride] {
        showAllCachedScorecards ? scorecardStore.overrides : Array(scorecardStore.overrides.prefix(5))
    }

    private var currentSeasonYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var currentSeasonRounds: [SavedRound] {
        savedRounds
            .filter { Calendar.current.component(.year, from: $0.date) == currentSeasonYear }
            .sorted { $0.date < $1.date }
    }

    private func syncHandicapText() {
        handicapText = String(format: "%.1f", playerSettings.handicap)
    }

    private func updateHandicap(from text: String) {
        let sanitized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(sanitized) else { return }
        playerSettings.handicap = min(54, max(0, value))
    }

    private func makeBackup() -> PrecisionBackup {
        PrecisionBackup(
            version: 1,
            exportedAt: Date(),
            handicap: playerSettings.handicap,
            rounds: savedRounds,
            favoriteCourseKeys: Array(courseFavorites.favoriteKeys).sorted(),
            customGoals: goalArchive.customGoals,
            clubYardages: clubYardages.clubs,
            handicapHistory: handicapHistory.records,
            courseScorecards: scorecardStore.overrides
        )
    }

    private func makeAISeasonReport() -> AISeasonReport {
        let rounds = currentSeasonRounds
        let sortedDescending = rounds.sorted { $0.date > $1.date }
        let grossScores = rounds.map { Double($0.totalScore) }
        let stablefordScores = rounds.compactMap(\.stablefordPoints)
        let totalFairways = rounds.reduce(0) { $0 + $1.fairwaysTotal }
        let totalFairwaysHit = rounds.reduce(0) { $0 + $1.fairwaysHit }
        let totalGreens = rounds.reduce(0) { $0 + $1.greensTracked }
        let totalGreensHit = rounds.reduce(0) { $0 + $1.greensInRegulation }
        let scrambleOpportunities = rounds.reduce(0) { $0 + $1.scramblingOpportunities }
        let scrambles = rounds.reduce(0) { $0 + $1.scrambles }
        let bunkerHoles = rounds.reduce(0) { $0 + $1.bunkerHoles }
        let sandSaves = rounds.reduce(0) { $0 + $1.sandSaves }
        let roundCount = Double(max(rounds.count, 1))

        return AISeasonReport(
            version: 1,
            exportedAt: Date(),
            player: AISeasonPlayer(
                name: profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Player" : profileName,
                homeClub: profileHomeClub,
                currentHandicapIndex: playerSettings.handicap
            ),
            season: AISeasonWindow(
                year: currentSeasonYear,
                includedRoundCount: rounds.count,
                firstRoundDate: rounds.first?.date,
                latestRoundDate: rounds.last?.date
            ),
            aiBrief: """
            You are my golf performance coach. Analyse this Precision Golf season export, identify the 3-5 biggest scoring opportunities, and create a practical practice plan for the next 6 months and 12 months. Focus on the data, explain trade-offs, and separate quick wins from long-term skill work.
            """,
            summary: AISeasonSummary(
                averageGross: average(grossScores),
                bestGross: rounds.map(\.totalScore).min(),
                latestGross: sortedDescending.first?.totalScore,
                averageStableford: average(stablefordScores.map(Double.init)),
                bestStableford: stablefordScores.max(),
                averagePutts: average(rounds.map { Double($0.totalPutts) }),
                fairwaysHitPercent: percentage(totalFairwaysHit, totalFairways),
                girPercent: percentage(totalGreensHit, totalGreens),
                scramblingPercent: percentage(scrambles, scrambleOpportunities),
                sandSavePercent: percentage(sandSaves, bunkerHoles),
                penaltiesPerRound: rounded(Double(rounds.reduce(0) { $0 + $1.penalties }) / roundCount),
                scoringMixPerRound: AIScoringMixExport(
                    eaglesOrBetter: rounded(Double(rounds.reduce(0) { $0 + $1.eaglesOrBetter }) / roundCount),
                    birdies: rounded(Double(rounds.reduce(0) { $0 + $1.birdies }) / roundCount),
                    pars: rounded(Double(rounds.reduce(0) { $0 + $1.pars }) / roundCount),
                    bogeys: rounded(Double(rounds.reduce(0) { $0 + $1.bogeys }) / roundCount),
                    doublesOrWorse: rounded(Double(rounds.reduce(0) { $0 + $1.doublesOrWorse }) / roundCount)
                )
            ),
            trends: AISeasonTrends(
                last5AverageGross: average(Array(sortedDescending.prefix(5)).map { Double($0.totalScore) }),
                previous5AverageGross: average(Array(sortedDescending.dropFirst(5).prefix(5)).map { Double($0.totalScore) }),
                last10AverageGross: average(Array(sortedDescending.prefix(10)).map { Double($0.totalScore) }),
                previous10AverageGross: average(Array(sortedDescending.dropFirst(10).prefix(10)).map { Double($0.totalScore) }),
                recentRoundScores: sortedDescending.prefix(20).map {
                    AITrendPointExport(
                        date: $0.date,
                        courseName: $0.courseName,
                        gross: $0.totalScore,
                        toPar: $0.totalScore - $0.totalPar,
                        stablefordPoints: $0.stablefordPoints
                    )
                },
                monthlyCheckpoints: makeMonthlyCheckpoints(rounds: rounds)
            ),
            parScoring: [3, 4, 5].map { par in
                makeParScoringExport(par: par, rounds: rounds)
            },
            rounds: rounds.map(makeAIRoundExport),
            handicapHistory: handicapHistory.records
        )
    }

    private func makeParScoringExport(par: Int, rounds: [SavedRound]) -> AIParScoringExport {
        let holes = rounds.flatMap(\.holes).filter { $0.par == par }
        return AIParScoringExport(
            par: par,
            holesPlayed: holes.count,
            averageGross: average(holes.map { Double($0.score) }),
            averageToPar: average(holes.map { Double($0.score - $0.par) }),
            stablefordPointsAverage: average(rounds.flatMap { round in
                round.holes
                    .filter { $0.par == par }
                    .map { hole in
                        Double(hole.stablefordPoints(using: Double(round.courseHandicap(using: round.handicap ?? playerSettings.handicap))))
                    }
            })
        )
    }

    private func makeAIRoundExport(_ round: SavedRound) -> AIRoundExport {
        let playingHandicap = round.handicap.map { round.courseHandicap(using: $0) }
        return AIRoundExport(
            id: round.id,
            date: round.date,
            courseName: round.courseName,
            location: round.location,
            teeName: round.teeName,
            teeYards: round.teeYards,
            teeRating: round.teeRating,
            teeSlope: round.teeSlope,
            handicapIndex: round.handicap,
            playingHandicap: playingHandicap,
            totalGross: round.totalScore,
            totalPar: round.totalPar,
            totalToPar: round.totalScore - round.totalPar,
            stablefordPoints: round.stablefordPoints,
            totalPutts: round.totalPutts,
            fairwaysHit: round.fairwaysHit,
            fairwaysTracked: round.fairwaysTotal,
            greensHit: round.greensInRegulation,
            greensTracked: round.greensTracked,
            scrambles: round.scrambles,
            scramblingOpportunities: round.scramblingOpportunities,
            sandSaves: round.sandSaves,
            bunkerHoles: round.bunkerHoles,
            penalties: round.penalties,
            scoringMix: AIRoundScoringMixExport(
                eaglesOrBetter: round.eaglesOrBetter,
                birdies: round.birdies,
                pars: round.pars,
                bogeys: round.bogeys,
                doublesOrWorse: round.doublesOrWorse
            ),
            holes: round.holes.map { hole in
                AIHoleExport(
                    holeNumber: hole.holeNumber,
                    par: hole.par,
                    yards: hole.yards,
                    strokeIndex: hole.strokeIndex,
                    grossScore: hole.score,
                    toPar: hole.score - hole.par,
                    stablefordPoints: playingHandicap.map { hole.stablefordPoints(using: Double($0)) },
                    putts: hole.putts,
                    pickedUp: hole.pickedUp,
                    fairway: hole.fairway.rawValue,
                    greenInRegulation: hole.green.rawValue,
                    teeClub: hole.teeClub?.rawValue,
                    approachRange: hole.approachRange?.rawValue,
                    approachProximity: hole.approachProximity?.rawValue,
                    firstPuttDistance: hole.firstPuttDistance?.rawValue,
                    penalties: hole.penalties,
                    penaltyType: hole.penaltyType?.rawValue,
                    bunker: hole.bunker,
                    upAndDown: hole.upAndDown,
                    sandSave: hole.sandSave,
                    recovery: hole.recovery,
                    note: hole.note
                )
            }
        )
    }

    private func makeMonthlyCheckpoints(rounds: [SavedRound]) -> [AISeasonCheckpointExport] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rounds) { round in
            calendar.dateComponents([.year, .month], from: round.date)
        }

        return grouped
            .compactMap { components, monthRounds -> (Date, AISeasonCheckpointExport)? in
                guard let date = calendar.date(from: components) else { return nil }
                let roundCount = Double(max(monthRounds.count, 1))
                let fairwaysTracked = monthRounds.reduce(0) { $0 + $1.fairwaysTotal }
                let fairwaysHit = monthRounds.reduce(0) { $0 + $1.fairwaysHit }
                let greensTracked = monthRounds.reduce(0) { $0 + $1.greensTracked }
                let greensHit = monthRounds.reduce(0) { $0 + $1.greensInRegulation }
                let scrambleOpportunities = monthRounds.reduce(0) { $0 + $1.scramblingOpportunities }
                let scrambles = monthRounds.reduce(0) { $0 + $1.scrambles }

                return (
                    date,
                    AISeasonCheckpointExport(
                        month: Self.monthFormatter.string(from: date),
                        roundsPlayed: monthRounds.count,
                        averageGross: average(monthRounds.map { Double($0.totalScore) }),
                        averageStableford: average(monthRounds.compactMap(\.stablefordPoints).map(Double.init)),
                        averagePutts: average(monthRounds.map { Double($0.totalPutts) }),
                        fairwaysHitPercent: percentage(fairwaysHit, fairwaysTracked),
                        girPercent: percentage(greensHit, greensTracked),
                        scramblingPercent: percentage(scrambles, scrambleOpportunities),
                        penaltiesPerRound: rounded(Double(monthRounds.reduce(0) { $0 + $1.penalties }) / roundCount)
                    )
                )
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return rounded(values.reduce(0, +) / Double(values.count))
    }

    private func percentage(_ numerator: Int, _ denominator: Int) -> Int? {
        guard denominator > 0 else { return nil }
        return Int((Double(numerator) / Double(denominator) * 100).rounded())
    }

    private func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func importBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pendingBackup = try decoder.decode(PrecisionBackup.self, from: data)
            showRestoreConfirmation = true
        } catch {
            restoreMessage = "Backup import failed. Choose a Precision Golf JSON backup."
        }
    }

    private func restorePendingBackup() {
        guard let backup = pendingBackup else { return }
        playerSettings.replaceHandicap(backup.handicap)
        syncHandicapText()
        roundArchive.replace(with: backup.rounds)
        courseFavorites.replace(with: Set(backup.favoriteCourseKeys))
        goalArchive.replace(with: backup.customGoals)
        clubYardages.replace(with: backup.clubYardages)
        handicapHistory.replace(with: backup.handicapHistory ?? [])
        let restoredScorecards = backup.courseScorecards?.count ?? 0
        scorecardStore.replace(with: backup.courseScorecards ?? [])
        restoreMessage = "Backup restored: \(backup.rounds.count) rounds and \(restoredScorecards) scorecards imported."
        pendingBackup = nil
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct FirebaseAccountCard: View {
    @ObservedObject var account: FirebaseAccountService
    @ObservedObject var roundSync: FirebaseRoundSyncService
    let localRoundCount: Int
    let profileName: String
    let handicap: Double
    let homeClub: String
    let syncRounds: () async -> Void
    let restoreRounds: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account & Sync")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(account.user == nil ? "Create an account to back up rounds and use friends." : "Your profile, friend code and completed rounds can sync to the cloud.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Image(systemName: account.user == nil ? "person.crop.circle.badge.plus" : "checkmark.icloud.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(account.user == nil ? AppTheme.softText : AppTheme.mint)
            }

            if let user = account.user {
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.email ?? "Signed in")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    if let profile = account.profile {
                        Text("\(profile.displayName.isEmpty ? "Unnamed golfer" : profile.displayName) - \(String(format: "%.1f", profile.handicap)) index")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                        if let friendCode = profile.friendCode {
                            Text("Friend code \(friendCode)")
                                .font(.system(.caption, design: .rounded).weight(.heavy))
                                .foregroundStyle(AppTheme.mint)
                        }
                    }
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

                HStack(spacing: 10) {
                    AccountSyncMetric(title: "On Phone", value: "\(localRoundCount)", caption: "rounds")
                    AccountSyncMetric(title: "Cloud", value: "\(roundSync.cloudRoundCount)", caption: "backed up")
                    AccountSyncMetric(title: "Last Sync", value: lastSyncText, caption: lastSyncCaption)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await account.saveProfile(displayName: profileName, handicap: handicap, homeClub: homeClub)
                        }
                    } label: {
                        Label("Sync Profile", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
                    .disabled(account.isWorking)

                    Button {
                        Task {
                            await syncRounds()
                        }
                    } label: {
                        Label("Back Up Rounds", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))
                    .disabled(roundSync.isWorking)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await restoreRounds()
                        }
                    } label: {
                        Label("Restore Cloud Backup", systemImage: "icloud.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))
                    .disabled(roundSync.isWorking)

                    Button {
                        account.signOut()
                    } label: {
                        Text("Sign Out")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))
                    .disabled(account.isWorking)
                }
            } else {
                VStack(spacing: 10) {
                    SocialSignInButton(title: "Continue with Apple", systemImage: "apple.logo", style: .dark) {
                        Task {
                            await account.signInWithApple()
                        }
                    }
                    .disabled(account.isWorking)

                    SocialSignInButton(title: "Continue with Google", systemImage: "g.circle.fill", style: .light) {
                        Task {
                            await account.signInWithGoogle()
                        }
                    }
                    .disabled(account.isWorking)
                }

                HStack(spacing: 10) {
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(height: 1)
                    Text("or use email")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.softText)
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(height: 1)
                }

                VStack(spacing: 10) {
                    TextField("Email", text: $account.email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .padding(13)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

                    SecureField("Password", text: $account.password)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .padding(13)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await account.signIn()
                        }
                    } label: {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))
                    .disabled(account.isWorking)

                    Button {
                        Task {
                            await account.createAccount(displayName: profileName, handicap: handicap, homeClub: homeClub)
                        }
                    } label: {
                        Text("Create")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
                    .disabled(account.isWorking)
                }

                Button {
                    Task {
                        await account.sendPasswordReset()
                    }
                } label: {
                    Text("Forgot Password?")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.mint)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(account.isWorking)

                Text("Accounts back up rounds on Firebase Spark. Rounds still save locally first, so live scoring works even when signal is poor.")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            }

            if account.isWorking || roundSync.isWorking {
                ProgressView()
                    .tint(AppTheme.mint)
            }

            if let status = account.statusMessage {
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(status.localizedCaseInsensitiveContains("error") ? Color.red : AppTheme.softText)
                    .lineSpacing(3)
            }

            if let status = roundSync.statusMessage {
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(status.localizedCaseInsensitiveContains("failed") ? Color.red : AppTheme.softText)
                    .lineSpacing(3)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var lastSyncText: String {
        guard let lastSyncDate = roundSync.lastSyncDate else { return "Not yet" }
        return Self.shortTimeFormatter.string(from: lastSyncDate)
    }

    private var lastSyncCaption: String {
        guard let lastSyncDate = roundSync.lastSyncDate else { return "sync" }
        return Self.shortDateFormatter.string(from: lastSyncDate)
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM"
        return formatter
    }()
}

struct AccountSyncMetric: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(caption)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
    }
}

struct SocialSignInButton: View {
    enum Style {
        case dark
        case light
    }

    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Spacer()
            }
            .foregroundStyle(foreground)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border))
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        style == .dark ? .white : AppTheme.ink
    }

    private var background: Color {
        style == .dark ? Color(red: 0.025, green: 0.035, blue: 0.03) : AppTheme.elevated
    }

    private var border: Color {
        style == .dark ? Color.white.opacity(0.18) : AppTheme.border
    }
}

struct FirebaseAccountButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundStyle(isPrimary ? .white : AppTheme.ink)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 8).fill(isPrimary ? AppTheme.controlGreen : AppTheme.subtleFill))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct FriendCodeSettingsCard: View {
    @ObservedObject var account: FirebaseAccountService
    @ObservedObject var social: FirebaseSocialService
    let profileName: String
    let handicap: Double
    let homeClub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Friend Code")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(account.user == nil ? "Create an account before sharing a friend code." : "Share this from Settings when someone wants to add you.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .lineSpacing(3)
                }
                Spacer()
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(account.user == nil ? AppTheme.softText : AppTheme.mint)
            }

            if account.user == nil {
                Text("Friend features need Firebase so requests and shared rounds know which player is which.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            } else if let friendCode = account.profile?.friendCode, !friendCode.isEmpty {
                Text(friendCode)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .minimumScaleFactor(0.7)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

                ShareLink(item: friendCode) {
                    Label("Share Friend Code", systemImage: "square.and.arrow.up.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
            } else {
                Text("Your profile needs a friend code before other players can add you.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)

                Button {
                    Task {
                        await account.saveProfile(displayName: profileName, handicap: handicap, homeClub: homeClub)
                        await social.refresh()
                    }
                } label: {
                    Label("Create Friend Code", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
                .disabled(account.isWorking)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }
}

struct GoalSettingsCard: View {
    @ObservedObject var goalArchive: GoalArchive
    @State private var goalTitle = ""
    @State private var goalPendingDelete: CustomGoal?

    private let suggestedPersonalGoals = [
        "Practice twice this week",
        "No three-putts next round",
        "Play a round without penalties",
        "Hit 50% fairways",
        "Hit 50% GIR",
        "Complete pre-shot routine every hole"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Set Goals", actionTitle: goalArchive.customGoals.isEmpty ? nil : "\(goalArchive.customGoals.count) active")

            Text("Add personal goals here. The Goals tab keeps your round achievements updated automatically from saved scorecards.")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
                .lineSpacing(3)

            HStack(spacing: 10) {
                TextField("Add your own goal", text: $goalTitle)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                    .submitLabel(.done)
                    .onSubmit(addGoal)

                Button(action: addGoal) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(AppTheme.mint))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add personal goal")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Ideas")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(suggestedPersonalGoals, id: \.self) { suggestion in
                        Button {
                            addSuggestion(suggestion)
                        } label: {
                            Text(isAdded(suggestion) ? "Added" : suggestion)
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .foregroundStyle(isAdded(suggestion) ? AppTheme.mint : AppTheme.ink)
                                .lineLimit(2)
                                .minimumScaleFactor(0.76)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(isAdded(suggestion) ? AppTheme.mintWash : AppTheme.subtleFill))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isAdded(suggestion) ? AppTheme.mint.opacity(0.4) : AppTheme.border.opacity(0.8)))
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdded(suggestion))
                    }
                }
            }

            if !goalArchive.customGoals.isEmpty {
                VStack(spacing: 10) {
                    ForEach(goalArchive.customGoals) { goal in
                        HStack(spacing: 12) {
                            Image(systemName: goal.isComplete ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(goal.isComplete ? AppTheme.mint : AppTheme.softText)

                            Text(goal.title)
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(AppTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                goalPendingDelete = goal
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(AppTheme.gold)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(AppTheme.subtleFill))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.8)))
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
        .alert("Delete this goal?", isPresented: Binding(
            get: { goalPendingDelete != nil },
            set: { if !$0 { goalPendingDelete = nil } }
        )) {
            Button("Keep Goal", role: .cancel) { goalPendingDelete = nil }
            Button("Delete Goal", role: .destructive) {
                if let goalPendingDelete { goalArchive.delete(goalPendingDelete) }
                goalPendingDelete = nil
            }
        } message: {
            Text("This removes the goal and its completion state.")
        }
    }

    private func addGoal() {
        goalArchive.add(title: goalTitle)
        goalTitle = ""
    }

    private func addSuggestion(_ suggestion: String) {
        guard !isAdded(suggestion) else { return }
        goalArchive.add(title: suggestion)
    }

    private func isAdded(_ suggestion: String) -> Bool {
        goalArchive.customGoals.contains {
            $0.title.caseInsensitiveCompare(suggestion) == .orderedSame
        }
    }
}

struct FriendsView: View {
    @ObservedObject var account: FirebaseAccountService
    @ObservedObject var social: FirebaseSocialService
    @Binding var openSharedRoundId: String?
    @State private var selectedFriend: FirebaseFriendProfile?
    @State private var selectedRound: FirebaseSharedRound?
    @State private var selectedGroup: FirebaseGolfGroup?
    @State private var newGroupName = ""
    @State private var showAddFriendForm = false
    @State private var showFindGolferForm = false
    @State private var showGroupForm = false
    @State private var showInbox = false
    @State private var pendingInboxSection: FriendsInboxSection?
    @State private var showContactPicker = false
    @State private var showMessageComposer = false
    @State private var contactInviteRecipients: [String] = []
    @State private var contactInviteBody = ""
    @State private var contactInviteStatus: String?

    private let betaInviteURL = "https://testflight.apple.com/join/5PvejjBZ"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    friendsHubHero

                    if account.user == nil {
                        signedOutCard
                    } else {
                        hubQuickActions
                        if showAddFriendForm {
                            addFriendCard
                        }
                        if showFindGolferForm {
                            findGolferCard
                        }
                        if showGroupForm {
                            groupCreatorCard
                        }
                        if !social.notifications.isEmpty {
                            notificationsCard
                                .id(FriendsInboxSection.roundAlerts)
                        }
                        friendsCard
                        if !social.groupInvites.isEmpty {
                            groupInvitesCard
                                .id(FriendsInboxSection.groupInvites)
                        }
                        if !social.incomingRequests.isEmpty {
                            requestsCard
                                .id(FriendsInboxSection.friendRequests)
                        }
                        groupsCard
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .onChange(of: pendingInboxSection) { _, section in
                guard let section else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    proxy.scrollTo(section, anchor: .top)
                }
                pendingInboxSection = nil
            }
        }
        .task {
            if account.user != nil {
                await social.refresh()
            }
        }
        .refreshable {
            await social.refresh()
        }
        .onChange(of: openSharedRoundId) { _, roundId in
            guard let roundId else { return }
            Task {
                await social.refresh()
                if let round = await social.loadSharedRound(id: roundId) {
                    selectedRound = round
                }
                openSharedRoundId = nil
            }
        }
        .sheet(item: $selectedFriend) { friend in
            FriendProfileDetailView(
                friend: friend,
                rounds: rounds(for: friend),
                matchplayRecord: matchplayRecord(for: friend)
            )
        }
        .sheet(item: $selectedRound) { round in
            SharedRoundDetailView(round: round)
        }
        .sheet(item: $selectedGroup) { group in
            GroupDetailView(
                group: group,
                friends: social.friends,
                rounds: rounds(for: group),
                liveGames: social.liveGroupGames.filter { $0.groupId == group.id },
                social: social
            )
        }
        .sheet(isPresented: $showInbox) {
            FriendsInboxView(
                notifications: social.notifications,
                requests: social.incomingRequests,
                groupInvites: social.groupInvites,
                openRound: { notification in
                    Task {
                        if let round = await social.loadSharedRound(id: notification.sharedRoundId) {
                            selectedRound = round
                            await social.markRead(notification)
                        }
                    }
                },
                openRequests: {
                    pendingInboxSection = .friendRequests
                },
                openGroupInvites: {
                    pendingInboxSection = .groupInvites
                }
            )
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerView { selection in
                handleContactInviteSelection(selection)
            }
        }
        .sheet(isPresented: $showMessageComposer) {
            MessageComposerView(recipients: contactInviteRecipients, body: contactInviteBody) { result in
                switch result {
                case .sent:
                    contactInviteStatus = "Invite sent"
                case .cancelled:
                    contactInviteStatus = "Invite cancelled"
                case .failed:
                    contactInviteStatus = "Invite failed"
                @unknown default:
                    contactInviteStatus = nil
                }
            }
        }
    }

    private func startContactInvite() {
        guard account.user != nil else {
            contactInviteStatus = "Create an account before inviting golfers."
            return
        }
        guard let friendCode = account.profile?.friendCode, !friendCode.isEmpty else {
            contactInviteStatus = "Create your friend code first in Settings."
            return
        }
        guard MFMessageComposeViewController.canSendText() else {
            contactInviteStatus = "Messages is not available on this device."
            return
        }

        contactInviteStatus = nil
        showContactPicker = true
    }

    private func handleContactInviteSelection(_ selection: ContactInviteSelection) {
        guard let phoneNumber = selection.phoneNumber, !phoneNumber.isEmpty else {
            contactInviteStatus = "\(selection.displayName) has no phone number saved."
            return
        }
        guard let friendCode = account.profile?.friendCode, !friendCode.isEmpty else {
            contactInviteStatus = "Create your friend code first in Settings."
            return
        }

        contactInviteRecipients = [phoneNumber]
        contactInviteBody = """
        Join me on Precision Golf.

        My friend code is \(friendCode).

        Beta/TestFlight link:
        \(betaInviteURL)
        """
        showMessageComposer = true
    }

    private var friendsHubHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Friends Hub")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Rounds, rivalries and your golfing circle.")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))
                }

                Spacer(minLength: 8)

                Image(systemName: "person.3.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(AppTheme.lime)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(.white.opacity(0.10)))
                    .overlay(Circle().stroke(.white.opacity(0.16)))
            }

            HStack(spacing: 10) {
                FriendsHubMetric(title: "Friends", value: "\(social.friends.count)", icon: "person.2.fill")
                FriendsHubMetric(title: "Groups", value: "\(social.groups.count)", icon: "person.3.fill")
                Button {
                    showInbox = true
                } label: {
                    FriendsHubMetric(
                        title: "Inbox",
                        value: "\(social.notifications.count + social.incomingRequests.count + social.groupInvites.count)",
                        icon: "tray.fill"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open inbox")
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.015, green: 0.16, blue: 0.09), Color(red: 0.02, green: 0.07, blue: 0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.mint.opacity(0.32)))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }

    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AppTheme.mint)
            Text("Create an account first")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
            Text("Friends need Firebase so each player has a private profile, friend code and request inbox. Sign in or create an account from Settings.")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
                .lineSpacing(3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var hubQuickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FriendsHubAction(
                    title: "Add Friend",
                    icon: "person.badge.plus",
                    isActive: showAddFriendForm
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAddFriendForm.toggle()
                        if showAddFriendForm {
                            showFindGolferForm = false
                            showGroupForm = false
                        }
                    }
                }

                FriendsHubAction(
                    title: "Find Golfer",
                    icon: "magnifyingglass",
                    isActive: showFindGolferForm
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFindGolferForm.toggle()
                        if showFindGolferForm {
                            showAddFriendForm = false
                            showGroupForm = false
                        } else {
                            social.clearGolferSearch()
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                FriendsHubAction(
                    title: "New Group",
                    icon: "person.3.fill",
                    isActive: showGroupForm
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showGroupForm.toggle()
                        if showGroupForm {
                            showAddFriendForm = false
                            showFindGolferForm = false
                        }
                    }
                }

                FriendsHubAction(
                    title: "Invite Golfer",
                    icon: "message.badge.fill",
                    isActive: false,
                    showsDisclosure: false
                ) {
                    startContactInvite()
                }
            }

            if let contactInviteStatus {
                Text(contactInviteStatus)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(contactInviteStatus.localizedCaseInsensitiveContains("failed") || contactInviteStatus.localizedCaseInsensitiveContains("not") ? Color.red : AppTheme.softText)
                    .lineSpacing(3)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var addFriendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Friend")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)

            TextField("Friend code, e.g. JAMES-4821", text: $social.friendCodeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

            Button {
                Task {
                    await social.sendFriendRequest()
                }
            } label: {
                Label("Send Friend Request", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
            .disabled(social.isWorking)

            if social.isWorking {
                ProgressView()
                    .tint(AppTheme.mint)
            }

            if let status = social.statusMessage {
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(status.localizedCaseInsensitiveContains("error") ? Color.red : AppTheme.softText)
                    .lineSpacing(3)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var findGolferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Find Golfer")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Text("Search synced Precision Golf profiles by name. New or existing users may need to sync their profile once before appearing.")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.softText)

                TextField("Search name, e.g. Andy", text: $social.golferSearchQuery)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .onSubmit {
                        Task { await social.searchGolfers() }
                    }

                Button {
                    Task { await social.searchGolfers() }
                } label: {
                    Text("Search")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(AppTheme.controlGreen))
                .disabled(social.isSearchingGolfers || social.golferSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

            if social.isSearchingGolfers {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(AppTheme.mint)
                    Text("Searching golfers...")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }
            }

            if !social.golferSearchResults.isEmpty {
                VStack(spacing: 10) {
                    ForEach(social.golferSearchResults) { golfer in
                        GolferSearchResultRow(golfer: golfer) {
                            Task {
                                await social.sendFriendRequest(to: golfer)
                            }
                        }
                    }
                }
            } else if !social.isSearchingGolfers && social.golferSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                Text("No results yet. Tap Search, or ask the golfer to sync their profile from Settings.")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            }

            if let status = social.statusMessage {
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(status.localizedCaseInsensitiveContains("failed") || status.localizedCaseInsensitiveContains("No synced") ? Color.red : AppTheme.softText)
                    .lineSpacing(3)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var groupCreatorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Golf Group")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            Text("Bring regular fourballs, society mates or trip players into one shared space.")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)

            TextField("Group name", text: $newGroupName)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.ink)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

            Button {
                let groupName = newGroupName
                newGroupName = ""
                showGroupForm = false
                Task {
                    await social.createGroup(name: groupName)
                }
            } label: {
                Label("Create Group", systemImage: "person.3.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
            .disabled(social.isWorking || newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Round Alerts", actionTitle: social.notifications.isEmpty ? nil : "\(min(3, social.notifications.count)) of \(social.notifications.count)")

            if social.notifications.isEmpty {
                Text("When a friend completes a round, you will see it here.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            } else {
                ForEach(Array(social.notifications.prefix(3))) { notification in
                    Button {
                        Task {
                            selectedRound = await social.loadSharedRound(id: notification.sharedRoundId)
                            await social.markRead(notification)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(AppTheme.mint)
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(AppTheme.mintWash))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(notification.message)
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                    .multilineTextAlignment(.leading)
                                Text("\(Self.friendRoundDateFormatter.string(from: notification.roundDate)) • Gross \(notification.gross) • \(notification.stableford.map { "\($0) pts" } ?? "Stableford pending")")
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                                    .foregroundStyle(AppTheme.softText)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.softText)
                        }
                        .padding(13)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
            .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private static let friendRoundDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var requestsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Friend Requests", actionTitle: social.incomingRequests.isEmpty ? nil : "\(social.incomingRequests.count)")

            if social.incomingRequests.isEmpty {
                Text("Incoming requests will appear here.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            } else {
                ForEach(social.incomingRequests) { request in
                    FriendRequestRow(request: request, social: social)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var groupInvitesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Group Invites", actionTitle: "\(social.groupInvites.count)")

            ForEach(social.groupInvites) { invite in
                GroupInviteRow(invite: invite, social: social)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Golf Groups", actionTitle: social.groups.isEmpty ? nil : "\(social.groups.count)")

            if social.groups.isEmpty {
                Text("Create a group for regular fourballs, society mates, trips or season-long bragging rights.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            } else {
                ForEach(social.groups) { group in
                    Button {
                        selectedGroup = group
                    } label: {
                        GroupRow(group: group, rounds: rounds(for: group))
                    }
                    .buttonStyle(.plain)
                }
            }

        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var friendsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your Circle", actionTitle: social.friends.isEmpty ? nil : "\(social.friends.count)")

            if social.friends.isEmpty {
                Text("Add your first friend by entering their Precision Golf friend code.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            } else {
                ForEach(social.friends) { friend in
                    Button {
                        selectedFriend = friend
                    } label: {
                        FriendProfileRow(
                            friend: friend,
                            matchplayRecord: matchplayRecord(for: friend)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private func rounds(for friend: FirebaseFriendProfile) -> [FirebaseSharedRound] {
        social.sharedRounds
            .filter { $0.ownerId == friend.uid }
            .sorted { $0.date > $1.date }
    }

    private func matchplayRecord(for friend: FirebaseFriendProfile) -> MatchplayFriendRecord {
        MatchplayFriendRecord(friend: friend, matches: social.matchplayHistory, currentUserId: account.user?.uid)
    }

    private func rounds(for group: FirebaseGolfGroup) -> [FirebaseSharedRound] {
        social.sharedRounds
            .filter { $0.groupIds.contains(group.id) }
            .sorted { $0.date > $1.date }
    }
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum FriendsInboxSection: Hashable {
    case roundAlerts
    case friendRequests
    case groupInvites
}

struct ContactInviteSelection {
    let displayName: String
    let phoneNumber: String?

    init(contact: CNContact) {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Golfer"
        displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Golfer" : name
        phoneNumber = contact.phoneNumbers.first?.value.stringValue
    }
}

struct ContactPickerView: UIViewControllerRepresentable {
    let onSelect: (ContactInviteSelection) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: (ContactInviteSelection) -> Void

        init(onSelect: @escaping (ContactInviteSelection) -> Void) {
            self.onSelect = onSelect
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onSelect(ContactInviteSelection(contact: contact))
        }
    }
}

struct MessageComposerView: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onComplete: (MessageComposeResult) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = context.coordinator
        composer.recipients = recipients
        composer.body = body
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, dismiss: dismiss)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onComplete: (MessageComposeResult) -> Void
        let dismiss: DismissAction

        init(onComplete: @escaping (MessageComposeResult) -> Void, dismiss: DismissAction) {
            self.onComplete = onComplete
            self.dismiss = dismiss
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            dismiss()
            onComplete(result)
        }
    }
}

struct FriendsInboxView: View {
    let notifications: [FirebaseRoundNotification]
    let requests: [FirebaseFriendRequest]
    let groupInvites: [FirebaseGroupInvite]
    let openRound: (FirebaseRoundNotification) -> Void
    let openRequests: () -> Void
    let openGroupInvites: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var totalCount: Int {
        notifications.count + requests.count + groupInvites.count
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if totalCount == 0 {
                        emptyState
                    } else {
                        if !requests.isEmpty {
                            inboxSection(
                                title: "Friend Requests",
                                count: requests.count,
                                icon: "person.badge.plus.fill",
                                tint: AppTheme.mint
                            ) {
                                ForEach(requests) { request in
                                    Button {
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            openRequests()
                                        }
                                    } label: {
                                        InboxActionRow(
                                            icon: "person.crop.circle.badge.plus",
                                            title: request.fromProfile.displayName,
                                            subtitle: "Approve or decline this friend request",
                                            meta: request.fromProfile.friendCode
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !groupInvites.isEmpty {
                            inboxSection(
                                title: "Group Invites",
                                count: groupInvites.count,
                                icon: "person.3.fill",
                                tint: AppTheme.lime
                            ) {
                                ForEach(groupInvites) { invite in
                                    Button {
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            openGroupInvites()
                                        }
                                    } label: {
                                        InboxActionRow(
                                            icon: "flag.2.crossed.fill",
                                            title: invite.groupName,
                                            subtitle: "\(invite.fromProfile?.displayName ?? "A friend") invited you",
                                            meta: "Join or decline"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !notifications.isEmpty {
                            inboxSection(
                                title: "Round Alerts",
                                count: notifications.count,
                                icon: "bell.badge.fill",
                                tint: AppTheme.mint
                            ) {
                                ForEach(notifications.prefix(5)) { notification in
                                    Button {
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            openRound(notification)
                                        }
                                    } label: {
                                        InboxActionRow(
                                            icon: "scorecard",
                                            title: notification.actorName,
                                            subtitle: notification.courseName,
                                            meta: "Gross \(notification.gross) • \(notification.stableford.map { "\($0) pts" } ?? "Stableford pending")"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.mint)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.lime)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(AppTheme.mintWash))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Inbox")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                    Text(totalCount == 1 ? "1 item needs attention" : "\(totalCount) items need attention")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppTheme.mint)
            Text("Nothing waiting")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            Text("Friend requests, group invites and round alerts will appear here.")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
                .lineSpacing(3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
    }

    private func inboxSection<Content: View>(
        title: String,
        count: Int,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }

            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.42), radius: 10, x: 0, y: 5)
    }
}

struct InboxActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let meta: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.mint)
                .frame(width: 42, height: 42)
                .background(Circle().fill(AppTheme.mintWash))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(2)
                Text(meta)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.mint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct FriendsHubMetric: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.lime)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
    }
}

struct FriendsHubAction: View {
    let title: String
    let icon: String
    let isActive: Bool
    var showsDisclosure = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 4)
                if showsDisclosure {
                    Image(systemName: isActive ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(isActive ? Color.white : AppTheme.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? AppTheme.controlGreen : AppTheme.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActive ? AppTheme.mint.opacity(0.55) : AppTheme.border))
        }
        .buttonStyle(.plain)
    }
}

struct GolferSearchResultRow: View {
    let golfer: FirebaseFriendProfile
    let sendRequest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(name: golfer.displayName, photoURL: golfer.photoURL, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(golfer.displayName)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    if !golfer.homeClub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(golfer.homeClub)
                            .lineLimit(1)
                    } else {
                        Text("Home club not set")
                            .lineLimit(1)
                    }

                    Text("HCP \(golfer.handicap, specifier: "%.1f")")
                        .lineLimit(1)
                }
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
            }

            Spacer(minLength: 8)

            Button(action: sendRequest) {
                Label("Add", systemImage: "person.badge.plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(AppTheme.controlGreen))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send friend request to \(golfer.displayName)")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
    }
}

enum WeeklyChallengeKind: String, CaseIterable, Identifiable {
    case birdies = "Birdies"
    case fairways = "Fairways"
    case putting = "Putting"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .birdies: "bird.fill"
        case .fairways: "flag.fill"
        case .putting: "figure.golf"
        }
    }

    var title: String {
        switch self {
        case .birdies: "Most birdies"
        case .fairways: "Most fairways"
        case .putting: "Lowest putting average"
        }
    }

    var accent: Color {
        switch self {
        case .birdies: AppTheme.lime
        case .fairways: AppTheme.mint
        case .putting: AppTheme.gold
        }
    }
}

struct WeeklyChallengePeriod {
    let start: Date
    let end: Date

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    var previous: WeeklyChallengePeriod {
        let duration: TimeInterval = 7 * 24 * 60 * 60
        return WeeklyChallengePeriod(start: start.addingTimeInterval(-duration), end: start)
    }

    static func current(at date: Date) -> WeeklyChallengePeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current

        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceSunday = (weekday - 1 + 7) % 7
        let sunday = calendar.date(byAdding: .day, value: -daysSinceSunday, to: startOfDay) ?? startOfDay
        let sundayAtNine = calendar.date(byAdding: .hour, value: 21, to: sunday) ?? sunday
        let start = date >= sundayAtNine
            ? sundayAtNine
            : calendar.date(byAdding: .day, value: -7, to: sundayAtNine) ?? sundayAtNine
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 24 * 60 * 60)
        return WeeklyChallengePeriod(start: start, end: end)
    }
}

struct WeeklyChallengeParticipant: Identifiable {
    let id: String
    let name: String
    let photoURL: String?
    let isCurrentUser: Bool
    let roundsPlayed: Int
    let birdies: Int
    let fairways: Int
    let totalPutts: Int

    var puttingAverage: Double? {
        guard roundsPlayed > 0 else { return nil }
        return Double(totalPutts) / Double(roundsPlayed)
    }

    func value(for challenge: WeeklyChallengeKind) -> Double? {
        guard roundsPlayed > 0 else { return nil }
        switch challenge {
        case .birdies: return Double(birdies)
        case .fairways: return Double(fairways)
        case .putting: return puttingAverage
        }
    }

    func valueText(for challenge: WeeklyChallengeKind) -> String {
        guard let value = value(for: challenge) else { return "No round" }
        switch challenge {
        case .birdies: return "\(Int(value))"
        case .fairways: return "\(Int(value))"
        case .putting: return String(format: "%.1f", value)
        }
    }
}

struct WeeklyChallengesHubCard: View {
    @Binding var selectedChallenge: WeeklyChallengeKind
    let currentPeriod: WeeklyChallengePeriod
    let previousPeriod: WeeklyChallengePeriod
    let currentParticipants: [WeeklyChallengeParticipant]
    let previousParticipants: [WeeklyChallengeParticipant]

    private var rankedCurrentParticipants: [WeeklyChallengeParticipant] {
        ranked(currentParticipants, for: selectedChallenge)
    }

    private var hasPreviousWinners: Bool {
        WeeklyChallengeKind.allCases.contains { previousWinner(for: $0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.77, blue: 0.24))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color(red: 0.98, green: 0.77, blue: 0.24).opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Weekly Challenges")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Automatic awards every Sunday at 9pm")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }

                Spacer(minLength: 8)

                Text(Self.periodFormatter.string(from: currentPeriod.end))
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.mint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(AppTheme.mintWash))
            }

            HStack(spacing: 8) {
                ForEach(WeeklyChallengeKind.allCases) { challenge in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedChallenge = challenge
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: challenge.icon)
                                .font(.system(size: 15, weight: .semibold))
                            Text(challenge.rawValue)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .foregroundStyle(selectedChallenge == challenge ? Color.white : AppTheme.softText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedChallenge == challenge ? AppTheme.controlGreen : AppTheme.subtleFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedChallenge == challenge ? challenge.accent.opacity(0.7) : AppTheme.border)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedChallenge.title)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("This week • \(Self.rangeFormatter.string(from: currentPeriod.start))–\(Self.rangeFormatter.string(from: currentPeriod.end))")
                            .font(.system(.caption2, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                    }
                    Spacer()
                    Text(valueHeader)
                        .font(.system(.caption2, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .textCase(.uppercase)
                }

                if rankedCurrentParticipants.isEmpty {
                    Text("Complete a round this week to put a score on the board.")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .padding(.vertical, 14)
                } else {
                    ForEach(Array(rankedCurrentParticipants.prefix(5).enumerated()), id: \.element.id) { index, participant in
                        WeeklyChallengeLeaderboardRow(
                            position: index + 1,
                            participant: participant,
                            challenge: selectedChallenge
                        )
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.74)))

            if hasPreviousWinners {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Last week's winners", systemImage: "medal.fill")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Spacer()
                        Text("Awarded Sun 9pm")
                            .font(.system(.caption2, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                    }

                    HStack(spacing: 8) {
                        ForEach(WeeklyChallengeKind.allCases) { challenge in
                            if let winner = previousWinner(for: challenge) {
                                WeeklyWinnerTile(challenge: challenge, winner: winner)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }

    private var valueHeader: String {
        switch selectedChallenge {
        case .birdies: "Birdies"
        case .fairways: "Hits"
        case .putting: "Avg"
        }
    }

    private func ranked(
        _ participants: [WeeklyChallengeParticipant],
        for challenge: WeeklyChallengeKind
    ) -> [WeeklyChallengeParticipant] {
        participants
            .filter { $0.value(for: challenge) != nil }
            .sorted { first, second in
                let firstValue = first.value(for: challenge) ?? 0
                let secondValue = second.value(for: challenge) ?? 0
                if firstValue == secondValue {
                    if first.roundsPlayed == second.roundsPlayed {
                        return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
                    }
                    return first.roundsPlayed > second.roundsPlayed
                }
                return challenge == .putting ? firstValue < secondValue : firstValue > secondValue
            }
    }

    private func previousWinner(for challenge: WeeklyChallengeKind) -> WeeklyChallengeParticipant? {
        ranked(previousParticipants, for: challenge).first
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "E HH:mm"
        return formatter
    }()

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}

struct WeeklyChallengeLeaderboardRow: View {
    let position: Int
    let participant: WeeklyChallengeParticipant
    let challenge: WeeklyChallengeKind

    var body: some View {
        HStack(spacing: 11) {
            Text("\(position)")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(position == 1 ? Color.white : AppTheme.softText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(position == 1 ? AppTheme.controlGreen : AppTheme.elevated))

            FriendAvatar(name: participant.name, photoURL: participant.photoURL, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.isCurrentUser ? "You" : participant.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text("\(participant.roundsPlayed) round\(participant.roundsPlayed == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            }

            Spacer(minLength: 8)

            Text(participant.valueText(for: challenge))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(challenge.accent)
        }
        .padding(.vertical, 4)
    }
}

struct WeeklyWinnerTile: View {
    let challenge: WeeklyChallengeKind
    let winner: WeeklyChallengeParticipant

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: challenge.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(challenge.accent)
            Text(winner.isCurrentUser ? "You" : winner.name)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(winner.valueText(for: challenge))
                .font(.system(.caption2, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(challenge.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(challenge.accent.opacity(0.22)))
    }
}

struct SharedRoundRow: View {
    let round: FirebaseSharedRound

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                FriendAvatar(name: round.ownerName, photoURL: round.ownerPhotoURL, size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(round.ownerName)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("\(round.courseName) • \(round.teeName) tees")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(Self.dateFormatter.string(from: round.date))
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.softText)
                    Text(round.scoreToParLabel)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.mint)
                }

                Image(systemName: "chevron.right")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText.opacity(0.7))
            }

            HStack(spacing: 8) {
                SharedRoundMetric(title: "Gross", value: "\(round.gross)")
                SharedRoundMetric(title: "Points", value: round.stableford.map(String.init) ?? "-")
                SharedRoundMetric(title: "Birdies", value: "\(round.birdies)")
                SharedRoundMetric(title: "Putts", value: "\(round.putts)")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

struct GroupRow: View {
    let group: FirebaseGolfGroup
    let rounds: [FirebaseSharedRound]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(AppTheme.mint))

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text("\(group.memberIds.count) members • \(rounds.count) recent rounds")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText.opacity(0.72))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct GroupInviteRow: View {
    let invite: FirebaseGroupInvite
    @ObservedObject var social: FirebaseSocialService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FriendAvatar(name: invite.fromProfile?.displayName ?? "Golfer", photoURL: invite.fromProfile?.photoURL, size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(invite.groupName)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("\(invite.fromProfile?.displayName ?? "A friend") invited you")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await social.decline(invite)
                    }
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))

                Button {
                    Task {
                        await social.accept(invite)
                    }
                } label: {
                    Text("Join")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct GroupDetailView: View {
    let group: FirebaseGolfGroup
    let friends: [FirebaseFriendProfile]
    let rounds: [FirebaseSharedRound]
    let liveGames: [FirebaseLiveGroupGame]
    @ObservedObject var social: FirebaseSocialService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRound: FirebaseSharedRound?

    private var memberFriends: [FirebaseFriendProfile] {
        friends
            .filter { group.memberIds.contains($0.uid) }
            .sorted { $0.displayName < $1.displayName }
    }

    private var inviteableFriends: [FirebaseFriendProfile] {
        friends
            .filter { !group.memberIds.contains($0.uid) }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    liveGamesCard
                    membersCard
                    inviteCard
                    roundsCard
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
            }
        }
        .sheet(item: $selectedRound) { round in
            SharedRoundDetailView(round: round)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Golf Group")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(.white.opacity(0.78))
                    Text(group.name)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 12)

                Image(systemName: "person.3.fill")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(.white))
            }

            HStack(spacing: 10) {
                GroupDetailMetric(title: "Members", value: "\(group.memberIds.count)")
                GroupDetailMetric(title: "Rounds", value: "\(rounds.count)")
                GroupDetailMetric(title: "Live", value: "\(liveGames.count)")
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [AppTheme.mint, AppTheme.lime],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var liveGamesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                SectionHeader(title: "Live Stableford", actionTitle: liveGames.isEmpty ? nil : "\(liveGames.count) active")

                Spacer(minLength: 8)

                Button {
                    Task {
                        await social.createStablefordGame(for: group)
                    }
                } label: {
                    Label("Start", systemImage: "bolt.fill")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
                .disabled(social.isWorking)
            }

            if liveGames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a live Stableford game before teeing off.")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("When members score a round, the leaderboard updates automatically and big moments appear here.")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .lineSpacing(3)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
            } else {
                ForEach(liveGames) { game in
                    LiveGroupGameCard(game: game) {
                        Task {
                            await social.completeLiveGroupGame(game)
                        }
                    }
                }
            }

            if let status = social.statusMessage {
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Members", actionTitle: "\(group.memberIds.count)")

            if memberFriends.isEmpty {
                Text("You are the first member. Invite friends below to start building this group.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            } else {
                ForEach(memberFriends) { friend in
                    FriendProfileSummary(friend: friend)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Invite Friends", actionTitle: inviteableFriends.isEmpty ? nil : "\(inviteableFriends.count)")

            if inviteableFriends.isEmpty {
                Text("All of your current friends are already in this group.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            } else {
                ForEach(inviteableFriends) { friend in
                    HStack(spacing: 12) {
                        FriendProfileSummary(friend: friend)

                        Button {
                            Task {
                                await social.invite(friend, to: group)
                            }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(AppTheme.mint))
                        }
                        .accessibilityLabel("Invite \(friend.displayName)")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                }
            }

            if let status = social.statusMessage {
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var roundsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Group Rounds", actionTitle: rounds.isEmpty ? nil : "\(rounds.count)")

            if rounds.isEmpty {
                Text("Rounds shared by group members will appear here automatically.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            } else {
                ForEach(rounds) { round in
                    Button {
                        selectedRound = round
                    } label: {
                        SharedRoundRow(round: round)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }
}

struct GroupDetailMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.16)))
    }
}

struct LiveGroupGameCard: View {
    let game: FirebaseLiveGroupGame
    let complete: () -> Void

    private var topPlayers: [FirebaseLiveGroupPlayer] {
        Array(game.players.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Stableford leaderboard", systemImage: "trophy.fill")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text(game.displayCourse)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button(action: complete) {
                    Text("Finish")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.mint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white))
                }
            }

            if game.players.isEmpty {
                Text("Scores appear once a group member starts scoring a round.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.72)))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(topPlayers.enumerated()), id: \.element.id) { index, player in
                        LiveGroupLeaderboardRow(position: index + 1, player: player)
                    }
                }
            }

            if !game.events.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Big moments")
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)

                    ForEach(Array(game.events.prefix(3))) { event in
                        LiveGroupEventRow(event: event)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [AppTheme.mintWash, Color.white], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.82)))
    }
}

struct LiveGroupLeaderboardRow: View {
    let position: Int
    let player: FirebaseLiveGroupPlayer

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(position == 1 ? .white : AppTheme.mint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(position == 1 ? AppTheme.mint : Color.white))

            FriendAvatar(name: player.displayName, photoURL: player.photoURL, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayName)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text(player.completed ? "Finished" : "Through \(player.throughText)")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.softText)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(player.stableford)")
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.mint)
                Text("pts")
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(player.gross == 0 ? "-" : "\(player.gross)")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Text("gross")
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
            }
            .frame(width: 48, alignment: .trailing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.86)))
    }
}

struct LiveGroupEventRow: View {
    let event: FirebaseLiveGroupEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(iconColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Text(event.holeNumber.map { "Hole \($0) • \(event.stableford) pts" } ?? "\(event.stableford) pts")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
            }

            Spacer(minLength: 4)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.78)))
    }

    private var iconName: String {
        switch event.type {
        case "eagle": return "sparkles"
        case "birdie": return "bird.fill"
        case "lead": return "arrow.up.right"
        case "completed": return "flag.checkered"
        default: return "bolt.fill"
        }
    }

    private var iconColor: Color {
        switch event.type {
        case "eagle": return AppTheme.lime
        case "birdie": return AppTheme.mint
        case "lead": return Color(red: 0.02, green: 0.28, blue: 0.72)
        case "completed": return AppTheme.gold
        default: return AppTheme.mint
        }
    }
}

struct SharedRoundMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
                .minimumScaleFactor(0.72)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
    }
}

struct FriendSeasonStatsCard: View {
    let rounds: [FirebaseSharedRound]

    private var seasonRounds: [FirebaseSharedRound] {
        rounds.filter { Calendar.current.component(.year, from: $0.date) == seasonYear }
    }

    private var seasonYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Performance Summary")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.mint)
                        .textCase(.uppercase)
                    Text("\(String(seasonYear)) Season Averages")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                }
                Spacer()
                if !seasonRounds.isEmpty {
                    Text("\(seasonRounds.count) \(seasonRounds.count == 1 ? "round" : "rounds")")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.mint)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(AppTheme.mintWash))
                }
            }

            if seasonRounds.isEmpty {
                Text("No shared rounds for this season yet.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    FriendPerformanceMetric(icon: "number.circle", title: "Avg Gross", value: averageGross, caption: "gross score", progress: grossProgress, tint: AppTheme.mint)
                    FriendPerformanceMetric(icon: "flag.checkered", title: "Avg Points", value: averageStableford, caption: "Stableford", progress: stablefordProgress, tint: AppTheme.gold)
                    FriendPerformanceMetric(icon: "figure.golf", title: "Putts", value: averagePutts, caption: "per round", progress: puttsProgress, tint: AppTheme.mint)
                    FriendPerformanceMetric(icon: "exclamationmark.triangle", title: "Penalties", value: averagePenalties, caption: "per round", progress: penaltyProgress, tint: Color(red: 0.88, green: 0.16, blue: 0.20))
                    FriendPerformanceMetric(icon: "flag.circle", title: "Fairways", value: "\(fairwayPercent)%", caption: "hit fairways", progress: Double(fairwayPercent) / 100, tint: AppTheme.mint)
                    FriendPerformanceMetric(icon: "target", title: "GIR", value: "\(girPercent)%", caption: "greens hit", progress: Double(girPercent) / 100, tint: AppTheme.mint)
                    FriendPerformanceMetric(icon: "waveform.path.ecg", title: "Scramble", value: "\(scramblePercent)%", caption: "up and downs", progress: Double(scramblePercent) / 100, tint: AppTheme.lime)
                    FriendPerformanceMetric(icon: "figure.golf", title: "Sand Save", value: "\(sandSavePercent)%", caption: "from bunkers", progress: Double(sandSavePercent) / 100, tint: AppTheme.gold)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var averageGross: String {
        formatAverage(seasonRounds.map { Double($0.gross) })
    }

    private var averageGrossValue: Double? {
        averageValue(seasonRounds.map { Double($0.gross) })
    }

    private var averageStableford: String {
        let points = seasonRounds.compactMap(\.stableford).map(Double.init)
        return points.isEmpty ? "-" : formatAverage(points)
    }

    private var averageStablefordValue: Double? {
        averageValue(seasonRounds.compactMap(\.stableford).map(Double.init))
    }

    private var averagePutts: String {
        formatAverage(seasonRounds.map { Double($0.putts) })
    }

    private var averagePuttsValue: Double? {
        averageValue(seasonRounds.map { Double($0.putts) })
    }

    private var averagePenalties: String {
        formatAverage(seasonRounds.map { Double($0.penalties) })
    }

    private var averagePenaltiesValue: Double? {
        averageValue(seasonRounds.map { Double($0.penalties) })
    }

    private var grossProgress: Double {
        guard let averageGrossValue else { return 0 }
        return clampedProgress((110 - averageGrossValue) / 40)
    }

    private var stablefordProgress: Double {
        guard let averageStablefordValue else { return 0 }
        return clampedProgress(averageStablefordValue / 45)
    }

    private var puttsProgress: Double {
        guard let averagePuttsValue else { return 0 }
        return clampedProgress((42 - averagePuttsValue) / 16)
    }

    private var penaltyProgress: Double {
        guard let averagePenaltiesValue else { return 0 }
        return clampedProgress((4 - averagePenaltiesValue) / 4)
    }

    private var fairwayPercent: Int {
        let hit = seasonRounds.reduce(0) { $0 + $1.fairwaysHit }
        let total = seasonRounds.reduce(0) { $0 + $1.fairwaysTracked }
        guard total > 0 else { return 0 }
        return Int((Double(hit) / Double(total) * 100).rounded())
    }

    private var girPercent: Int {
        let hit = seasonRounds.reduce(0) { $0 + $1.greensHit }
        let total = seasonRounds.reduce(0) { $0 + $1.greensTracked }
        guard total > 0 else { return 0 }
        return Int((Double(hit) / Double(total) * 100).rounded())
    }

    private var scramblePercent: Int {
        let made = seasonRounds.reduce(0) { $0 + $1.scrambles }
        let total = seasonRounds.reduce(0) { $0 + $1.scrambleOpportunities }
        guard total > 0 else { return 0 }
        return Int((Double(made) / Double(total) * 100).rounded())
    }

    private var sandSavePercent: Int {
        let made = seasonRounds.reduce(0) { $0 + $1.sandSaves }
        let total = seasonRounds.reduce(0) { $0 + $1.bunkerHoles }
        guard total > 0 else { return 0 }
        return Int((Double(made) / Double(total) * 100).rounded())
    }

    private func formatAverage(_ values: [Double]) -> String {
        guard let average = averageValue(values) else { return "-" }
        return String(format: "%.1f", average)
    }

    private func averageValue(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(1, max(0.12, value))
    }
}

struct FriendPerformanceMetric: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(tint.opacity(0.20)))
                    .overlay(Circle().stroke(tint.opacity(0.30)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.caption2, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(value)
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                }
            }

            Text(caption)
                .font(.system(.caption2, design: .rounded).weight(.medium))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.border.opacity(0.40))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(16, proxy.size.width * progress))
                }
            }
            .frame(height: 7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.glassGradient))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))
        .shadow(color: AppTheme.shadow.opacity(0.45), radius: 12, x: 0, y: 7)
    }
}

private enum RoundShareFormatter {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func scoreToParLabel(_ value: Int) -> String {
        value == 0 ? "E" : value > 0 ? "+\(value)" : "\(value)"
    }

    static func ratio(_ made: Int, _ total: Int) -> String {
        total > 0 ? "\(made)/\(total)" : "-"
    }
}

struct RoundSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]

    @MainActor
    static func savedRound(_ round: SavedRound) -> RoundSharePayload {
        if let image = ScorecardShareRenderer.renderSavedRound(round) {
            return RoundSharePayload(items: [image])
        }
        return RoundSharePayload(items: [round.shareText])
    }

    @MainActor
    static func sharedRound(_ round: FirebaseSharedRound) -> RoundSharePayload {
        if let image = ScorecardShareRenderer.renderSharedRound(round) {
            return RoundSharePayload(items: [image])
        }
        return RoundSharePayload(items: [round.shareText])
    }
}

private enum ScorecardShareRenderer {
    @MainActor
    static func renderSavedRound(_ round: SavedRound) -> UIImage? {
        let renderer = ImageRenderer(
            content:
                VisualScorecard(round: round)
                    .frame(width: 720)
                    .padding(24)
                    .background(Color.white)
        )
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }

    @MainActor
    static func renderSharedRound(_ round: FirebaseSharedRound) -> UIImage? {
        let renderer = ImageRenderer(
            content:
                SharedVisualScorecard(round: round)
                    .frame(width: 720)
                    .padding(24)
                    .background(Color.white)
        )
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }
}

struct ActivityShareView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension SavedRound {
    var shareText: String {
        let scoreToPar = totalScore - totalPar
        let stablefordText = stablefordPoints.map { "\($0) pts" } ?? "Stableford not recorded"
        let scorecardLines = holes.sorted { $0.holeNumber < $1.holeNumber }.map { hole in
            let score = hole.pickedUp ? "P\(hole.score)" : "\(hole.score)"
            let putts = hole.pickedUp ? "-" : "\(hole.putts)"
            return "H\(hole.holeNumber): \(score) on par \(hole.par), SI \(hole.strokeIndex), \(putts) putts"
        }

        return """
        Precision Golf round
        \(courseName) - \(teeName) tees
        \(RoundShareFormatter.dateFormatter.string(from: date))

        Gross \(totalScore) / Par \(totalPar) (\(RoundShareFormatter.scoreToParLabel(scoreToPar)))
        Stableford: \(stablefordText)
        Putts: \(totalPutts)
        Penalties: \(penalties)
        Fairways: \(RoundShareFormatter.ratio(fairwaysHit, fairwaysTotal))
        GIR: \(RoundShareFormatter.ratio(greensInRegulation, greensTracked))
        Scramble: \(RoundShareFormatter.ratio(scrambles, scramblingOpportunities))
        Sand save: \(RoundShareFormatter.ratio(sandSaves, bunkerHoles))

        Digital scorecard
        \(scorecardLines.joined(separator: "\n"))
        """
    }
}

extension FirebaseSharedRound {
    var shareText: String {
        let stablefordText = stableford.map { "\($0) pts" } ?? "Stableford not recorded"
        let scorecardLines = holes.sorted { $0.holeNumber < $1.holeNumber }.map { hole in
            let score = hole.pickedUp ? "P\(hole.score)" : "\(hole.score)"
            let putts = hole.pickedUp ? "-" : "\(hole.putts)"
            return "H\(hole.holeNumber): \(score) on par \(hole.par), SI \(hole.strokeIndex), \(putts) putts"
        }

        return """
        Precision Golf round
        \(ownerName) at \(courseName) - \(teeName) tees
        \(RoundShareFormatter.dateFormatter.string(from: date))

        Gross \(gross) / Par \(par) (\(scoreToParLabel))
        Stableford: \(stablefordText)
        Putts: \(putts)
        Penalties: \(penalties)
        Fairways: \(RoundShareFormatter.ratio(fairwaysHit, fairwaysTracked))
        GIR: \(RoundShareFormatter.ratio(greensHit, greensTracked))
        Scramble: \(RoundShareFormatter.ratio(scrambles, scrambleOpportunities))
        Sand save: \(RoundShareFormatter.ratio(sandSaves, bunkerHoles))

        Digital scorecard
        \(scorecardLines.isEmpty ? "No hole-by-hole card attached." : scorecardLines.joined(separator: "\n"))
        """
    }

    var fairwaysTracked: Int {
        holes.filter { $0.par > 3 && $0.fairway != .notTracked }.count
    }

    var fairwaysHit: Int {
        holes.filter { $0.par > 3 && $0.fairway == .hit }.count
    }

    var greensTracked: Int {
        holes.filter { $0.green != .notTracked }.count
    }

    var greensHit: Int {
        holes.filter { $0.green == .hit }.count
    }

    var scrambleOpportunities: Int {
        holes.filter { $0.green != .hit && $0.green != .notTracked }.count
    }

    var scrambles: Int {
        holes.filter { $0.green != .hit && $0.green != .notTracked && $0.score <= $0.par }.count
    }

    var bunkerHoles: Int {
        holes.filter { $0.bunker == true }.count
    }

    var sandSaves: Int {
        holes.filter { $0.bunker == true && $0.score <= $0.par }.count
    }
}

struct FriendProfileDetailView: View {
    let friend: FirebaseFriendProfile
    let rounds: [FirebaseSharedRound]
    let matchplayRecord: MatchplayFriendRecord
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRound: FirebaseSharedRound?
    @State private var showAllRounds = false

    private var visibleRounds: [FirebaseSharedRound] {
        showAllRounds ? rounds : Array(rounds.prefix(3))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    FriendProfileHeroCard(friend: friend, rounds: rounds, matchplayRecord: matchplayRecord)

                    FriendSeasonStatsCard(rounds: rounds)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Latest Rounds", actionTitle: rounds.isEmpty ? nil : (showAllRounds ? "\(rounds.count) rounds" : "\(min(3, rounds.count)) latest"))

                        if rounds.isEmpty {
                            Text("When this friend completes a shared round, it will appear here.")
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                                .foregroundStyle(AppTheme.softText)
                                .lineSpacing(3)
                        } else {
                            ForEach(visibleRounds) { round in
                                Button {
                                    selectedRound = round
                                } label: {
                                    SharedRoundRow(round: round)
                                }
                                .buttonStyle(.plain)
                            }

                            if rounds.count > 3 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showAllRounds.toggle()
                                    }
                                } label: {
                                    Label(showAllRounds ? "Show Latest 3" : "View All \(rounds.count) Rounds", systemImage: showAllRounds ? "chevron.up" : "chevron.down")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))
                            }
                        }
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                    .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
            }
        }
        .sheet(item: $selectedRound) { round in
            SharedRoundDetailView(round: round)
        }
    }
}

struct FriendProfileHeroCard: View {
    let friend: FirebaseFriendProfile
    let rounds: [FirebaseSharedRound]
    let matchplayRecord: MatchplayFriendRecord

    private var latestRoundScore: String {
        rounds.sorted { $0.date > $1.date }.first.map { "\($0.gross)" } ?? "-"
    }

    private var latestRoundCaption: String {
        guard let latest = rounds.sorted(by: { $0.date > $1.date }).first else {
            return "No rounds"
        }
        return Self.shortDateFormatter.string(from: latest.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                FriendAvatar(name: friend.displayName, photoURL: friend.photoURL, size: 72)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Friend Profile")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.mint)
                        .textCase(.uppercase)
                    Text(friend.displayName.isEmpty ? "Golfer" : friend.displayName)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    Text(friend.homeClub.isEmpty ? "Home club not set" : friend.homeClub)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 0) {
                SummaryMetric(title: "Handicap", value: String(format: "%.1f", friend.handicap), caption: "Current index")
                Divider().overlay(Color.white.opacity(0.18)).padding(.vertical, 10)
                SummaryMetric(title: "Rounds", value: "\(rounds.count)", caption: "Shared")
                Divider().overlay(Color.white.opacity(0.18)).padding(.vertical, 10)
                SummaryMetric(title: "Latest", value: latestRoundScore, caption: latestRoundCaption)
            }

            HStack(spacing: 9) {
                Image(systemName: "flag.2.crossed.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(matchplayRecord.summary)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14)))
        }
        .padding(20)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.performanceCard)
                FairwayCardBackdrop()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0.06)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

struct SharedRoundDetailView: View {
    let round: FirebaseSharedRound
    @Environment(\.dismiss) private var dismiss
    @State private var sharePayload: RoundSharePayload?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(round.ownerName)
                                    .font(.system(.headline, design: .rounded).weight(.heavy))
                                    .foregroundStyle(AppTheme.mint)
                                Text(round.courseName)
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                    .foregroundStyle(AppTheme.ink)
                                    .minimumScaleFactor(0.75)
                                Text("\(round.location.isEmpty ? "Course location not set" : round.location) - \(round.teeName) tees")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(AppTheme.softText)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(Self.dateFormatter.string(from: round.date))
                                    .font(.system(.caption, design: .rounded).weight(.heavy))
                                    .foregroundStyle(AppTheme.softText)
                                Text(round.scoreToParLabel)
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                    .foregroundStyle(AppTheme.mint)
                            }
                        }

                        HStack(spacing: 8) {
                            SharedRoundMetric(title: "Gross", value: "\(round.gross)")
                            SharedRoundMetric(title: "Par", value: "\(round.par)")
                            SharedRoundMetric(title: "Points", value: round.stableford.map(String.init) ?? "-")
                        }
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                    .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                    SharedRoundStatsGrid(round: round)

                    SharedRoundScorecard(round: round)
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        sharePayload = RoundSharePayload.sharedRound(round)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(AppTheme.mint)

                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityShareView(activityItems: payload.items)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct SharedRoundStatsGrid: View {
    let round: FirebaseSharedRound

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Round Stats", actionTitle: round.holes.isEmpty ? "Summary" : "Full")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                SharedRoundMetric(title: "Birdies", value: "\(round.birdies)")
                SharedRoundMetric(title: "Pars", value: "\(round.pars)")
                SharedRoundMetric(title: "Putts", value: "\(round.putts)")
                SharedRoundMetric(title: "Penalties", value: "\(round.penalties)")
                SharedRoundMetric(title: "Fairways", value: fairwayText)
                SharedRoundMetric(title: "GIR", value: girText)
                SharedRoundMetric(title: "Scramble", value: scrambleText)
                SharedRoundMetric(title: "Sand Save", value: sandSaveText)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var fairwayText: String {
        let tracked = round.holes.filter { $0.par > 3 && $0.fairway != .notTracked }
        guard !tracked.isEmpty else { return "-" }
        return "\(tracked.filter { $0.fairway == .hit }.count)/\(tracked.count)"
    }

    private var girText: String {
        let tracked = round.holes.filter { $0.green != .notTracked }
        guard !tracked.isEmpty else { return "-" }
        return "\(tracked.filter { $0.green == .hit }.count)/\(tracked.count)"
    }

    private var scrambleText: String {
        let opportunities = round.holes.filter { $0.green != .hit && $0.green != .notTracked }
        guard !opportunities.isEmpty else { return "-" }
        return "\(opportunities.filter { $0.score <= $0.par }.count)/\(opportunities.count)"
    }

    private var sandSaveText: String {
        let bunkerHoles = round.holes.filter { $0.bunker == true }
        guard !bunkerHoles.isEmpty else { return "-" }
        return "\(bunkerHoles.filter { $0.score <= $0.par }.count)/\(bunkerHoles.count)"
    }
}

struct SharedRoundScorecard: View {
    let round: FirebaseSharedRound

    var body: some View {
        if round.holes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Digital Scorecard", actionTitle: nil)
                Text("This round was shared before hole-by-hole scorecards were added. New shared rounds will include the full digital scorecard.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineSpacing(3)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
            .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
        } else {
            SharedVisualScorecard(round: round)
        }
    }
}

struct SharedVisualScorecard: View {
    let round: FirebaseSharedRound

    private var frontNine: [FirebaseSharedHoleEntry] {
        round.holes.filter { $0.holeNumber <= 9 }
    }

    private var backNine: [FirebaseSharedHoleEntry] {
        round.holes.filter { $0.holeNumber > 9 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(round.courseName)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Digital Scorecard - \(round.teeName) tees - \(Self.dateFormatter.string(from: round.date))")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(round.gross)")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.mint)
                    Text(round.ownerName)
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(1)
                }
            }

            GeometryReader { proxy in
                let metrics = ScorecardMetrics(containerWidth: proxy.size.width)
                VStack(alignment: .leading, spacing: 12) {
                    ScorecardTable(title: "Out", holes: frontNine, metrics: metrics, stablefordValues: stablefordValues(for: frontNine))
                    ScorecardTable(title: "In", holes: backNine, metrics: metrics, stablefordValues: stablefordValues(for: backNine))
                    SharedScorecardTotalRow(round: round)
                }
            }
            .frame(height: 460)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.panel)
                .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func stablefordValues(for holes: [FirebaseSharedHoleEntry]) -> [String]? {
        let values = holes.map { $0.stablefordPoints }
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.map { $0.map(String.init) ?? "-" }
    }
}

struct SharedScorecardTotalRow: View {
    let round: FirebaseSharedRound

    var body: some View {
        HStack(spacing: 6) {
            ScorecardFooterCell(title: "CH", value: courseHandicapText, accent: AppTheme.mint)
            ScorecardFooterCell(title: "Score", value: "\(round.gross)/\(round.par)", accent: AppTheme.mint)
            ScorecardFooterCell(title: "To Par", value: round.scoreToParLabel)
            ScorecardFooterCell(title: "Putts", value: "\(round.putts)")
            ScorecardFooterCell(title: "Pens", value: "\(round.penalties)", accent: round.penalties > 0 ? AppTheme.gold : nil)
            ScorecardFooterCell(title: "Points", value: stablefordText, accent: AppTheme.gold)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
    }

    private var courseHandicapText: String {
        round.courseHandicap.map(String.init) ?? "-"
    }

    private var stablefordText: String {
        round.stableford.map { "\($0) pts" } ?? "- pts"
    }
}

struct FriendRequestRow: View {
    let request: FirebaseFriendRequest
    @ObservedObject var social: FirebaseSocialService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FriendProfileSummary(friend: request.fromProfile)
            HStack(spacing: 10) {
                Button {
                    Task {
                        await social.decline(request)
                    }
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))

                Button {
                    Task {
                        await social.accept(request)
                    }
                } label: {
                    Text("Accept")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct MatchplayFriendRecord {
    let wins: Int
    let losses: Int
    let halves: Int

    init(friend: FirebaseFriendProfile, matches: [FirebaseMatchplayMatch], currentUserId: String?) {
        guard let currentUserId else {
            wins = 0
            losses = 0
            halves = 0
            return
        }

        let friendMatches = matches.filter {
            $0.memberIds.contains(currentUserId)
                && $0.memberIds.contains(friend.uid)
        }

        let outcomes = friendMatches.compactMap {
            Self.outcome(for: $0, currentUserId: currentUserId, friendId: friend.uid)
        }

        wins = outcomes.filter { $0 == .win }.count
        losses = outcomes.filter { $0 == .loss }.count
        halves = outcomes.filter { $0 == .half }.count
    }

    var played: Int { wins + losses + halves }

    var summary: String {
        played == 0 ? "No matches yet" : "\(wins)W \(losses)L \(halves)H"
    }

    private enum Outcome {
        case win
        case loss
        case half
    }

    private static func outcome(for match: FirebaseMatchplayMatch, currentUserId: String, friendId: String) -> Outcome? {
        if match.status == "completed" {
            if match.winnerId == currentUserId { return .win }
            if match.winnerId == friendId { return .loss }
            return .half
        }

        guard let holes = resolvedHoles(for: match) else { return nil }
        let score = matchScore(match: match, currentUserId: currentUserId, friendId: friendId, holes: holes)
        let completed = completedHoleCount(match: match, currentUserId: currentUserId, friendId: friendId, holes: holes)
        let holesLeft = max(0, holes.count - completed)
        guard abs(score) > holesLeft || completed == holes.count else { return nil }
        if score > 0 { return .win }
        if score < 0 { return .loss }
        return .half
    }

    private static func resolvedHoles(for match: FirebaseMatchplayMatch) -> [Hole]? {
        if !match.holes.isEmpty {
            return match.holes.map(\.hole)
        }

        return CourseDatabase.courses
            .first { $0.name.localizedCaseInsensitiveCompare(match.courseName) == .orderedSame }?
            .tees
            .first { $0.name.localizedCaseInsensitiveCompare(match.teeName) == .orderedSame }?
            .holes
    }

    private static func completedHoleCount(match: FirebaseMatchplayMatch, currentUserId: String, friendId: String, holes: [Hole]) -> Int {
        holes.indices.filter { index in
            match.score(for: currentUserId, holeIndex: index) > 0 && match.score(for: friendId, holeIndex: index) > 0
        }.count
    }

    private static func matchScore(match: FirebaseMatchplayMatch, currentUserId: String, friendId: String, holes: [Hole]) -> Int {
        holes.indices.reduce(0) { total, index in
            let userScore = match.score(for: currentUserId, holeIndex: index)
            let friendScore = match.score(for: friendId, holeIndex: index)
            guard userScore > 0, friendScore > 0 else { return total }
            let hole = holes[index]
            let userNet = userScore - match.strokes(for: currentUserId, hole: hole)
            let friendNet = friendScore - match.strokes(for: friendId, hole: hole)
            if userNet < friendNet { return total + 1 }
            if friendNet < userNet { return total - 1 }
            return total
        }
    }
}

struct FriendProfileRow: View {
    let friend: FirebaseFriendProfile
    let matchplayRecord: MatchplayFriendRecord

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(name: friend.displayName, photoURL: friend.photoURL, size: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(friend.displayName.isEmpty ? "Golfer" : friend.displayName)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)

                if matchplayRecord.played > 0 {
                    Text(matchplayRecord.summary)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Text("View")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(AppTheme.mint)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Capsule().fill(AppTheme.mintWash))
            .overlay(Capsule().stroke(AppTheme.mint.opacity(0.28)))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
    }
}

struct FriendRoundPreviewRow: View {
    let round: FirebaseSharedRound

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(round.courseName)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Text(Self.dateFormatter.string(from: round.date))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }

            Spacer(minLength: 8)

            Text("\(round.gross)")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.mint)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(AppTheme.mintWash))

            Text(round.stableford.map { "\($0) pts" } ?? "- pts")
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.gold)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Capsule().fill(AppTheme.elevated))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.65)))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct FriendAvatar: View {
    let name: String
    let photoURL: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.82), lineWidth: 2))
    }

    private var fallback: some View {
        Text(initials)
            .font(.system(size: max(15, size * 0.38), weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(AppTheme.mint))
    }

    private var avatarURL: URL? {
        guard
            let photoURL,
            !photoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(string: photoURL)
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let value = String(letters).uppercased()
        return value.isEmpty ? "PG" : value
    }
}

struct FriendProfileSummary: View {
    let friend: FirebaseFriendProfile

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(name: friend.displayName, photoURL: friend.photoURL, size: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(friend.displayName.isEmpty ? "Golfer" : friend.displayName)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Text(detailText)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)

            Text(String(format: "%.1f", friend.handicap))
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.mint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(AppTheme.mintWash))
        }
    }

    private var detailText: String {
        let club = friend.homeClub.trimmingCharacters(in: .whitespacesAndNewlines)
        return club.isEmpty ? friend.friendCode : "\(club) • \(friend.friendCode)"
    }
}

struct CachedScorecardRow: View {
    let scorecard: CourseScorecardOverride
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(scorecard.name)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(scorecard.location)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                HStack(spacing: 8) {
                    Label("\(scorecard.tees.count) tees", systemImage: "flag.fill")
                    Label("\(holeCount) holes", systemImage: "list.number")
                    Label(Self.dateFormatter.string(from: scorecard.updatedAt), systemImage: "clock")
                }
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.red)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.red.opacity(0.08)))
            }
            .accessibilityLabel("Delete cached scorecard")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }

    private var holeCount: Int {
        scorecard.tees.map { $0.holes.count }.max() ?? 0
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct GoalTemplate: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let isComplete: ([SavedRound]) -> Bool
    let progress: ([SavedRound]) -> String
}

private func automaticGoalSuggestions() -> [GoalTemplate] {
    [
        grossScoreGoal(id: "break100", title: "Break 100 Gross", target: 100, icon: "flag.fill"),
        grossScoreGoal(id: "break90", title: "Break 90 Gross", target: 90, icon: "flag.2.crossed.fill"),
        grossScoreGoal(id: "break80", title: "Break 80 Gross", target: 80, icon: "trophy.fill"),
        grossScoreGoal(id: "break75", title: "Break 75 Gross", target: 75, icon: "medal.fill"),
        GoalTemplate(
            id: "breakPar",
            title: "Break Par",
            detail: "Shoot level par or better in a completed round.",
            icon: "equal.circle.fill",
            isComplete: { rounds in rounds.contains { $0.totalScore <= $0.totalPar } },
            progress: { rounds in bestToParProgress(rounds, target: 0) }
        ),
        GoalTemplate(
            id: "underPar",
            title: "Shoot Under Par",
            detail: "Finish a round below the course par.",
            icon: "minus.circle.fill",
            isComplete: { rounds in rounds.contains { $0.totalScore < $0.totalPar } },
            progress: { rounds in bestToParProgress(rounds, target: -1) }
        ),
        GoalTemplate(
            id: "holeInOne",
            title: "Hole In One",
            detail: "Record a score of 1 on any hole.",
            icon: "1.circle.fill",
            isComplete: { rounds in rounds.flatMap(\.holes).contains { $0.score == 1 } },
            progress: { rounds in
                rounds.flatMap(\.holes).contains { $0.score == 1 } ? "Ace recorded" : "No aces yet"
            }
        ),
        GoalTemplate(
            id: "par5Eagle",
            title: "Eagle A Par 5",
            detail: "Record 3 or better on a par 5.",
            icon: "flag.fill",
            isComplete: { rounds in rounds.flatMap(\.holes).contains { $0.par == 5 && $0.score <= 3 } },
            progress: { rounds in
                rounds.flatMap(\.holes).contains { $0.par == 5 && $0.score <= 3 } ? "Par 5 eagle logged" : "Waiting for a par 5 eagle"
            }
        ),
        GoalTemplate(
            id: "tenTwos",
            title: "Minimum 10 Two's",
            detail: "Record at least ten scores of 2 across saved rounds.",
            icon: "2.circle.fill",
            isComplete: { rounds in twosCount(rounds) >= 10 },
            progress: { rounds in "\(min(twosCount(rounds), 10))/10 two's recorded" }
        ),
        GoalTemplate(
            id: "noPenaltyRound",
            title: "No Penalty Round",
            detail: "Complete a round without recording any penalty shots.",
            icon: "checkmark.shield.fill",
            isComplete: { rounds in rounds.contains { $0.holes.allSatisfy { $0.penalties == 0 } } },
            progress: { rounds in
                rounds.contains { $0.holes.allSatisfy { $0.penalties == 0 } } ? "Clean round recorded" : "Waiting for a clean round"
            }
        ),
        GoalTemplate(
            id: "thirtySixPoints",
            title: "36+ Stableford Points",
            detail: "Score 36 or more Stableford points in a completed round.",
            icon: "star.circle.fill",
            isComplete: { rounds in rounds.contains { ($0.stablefordPoints ?? 0) >= 36 } },
            progress: { rounds in
                guard let best = rounds.compactMap(\.stablefordPoints).max() else { return "No completed rounds yet" }
                return best >= 36 ? "Best \(best) points" : "\(36 - best) points away"
            }
        )
    ]
}

private func grossScoreGoal(id: String, title: String, target: Int, icon: String) -> GoalTemplate {
    GoalTemplate(
        id: id,
        title: title,
        detail: "Shoot \(target - 1) or better gross in a completed round.",
        icon: icon,
        isComplete: { rounds in rounds.contains { $0.totalScore < target } },
        progress: { rounds in
            guard let best = rounds.map(\.totalScore).min() else { return "No completed rounds yet" }
            return best < target ? "Best gross \(best)" : "\(max(0, best - (target - 1))) shots away"
        }
    )
}

struct GoalsView: View {
    let savedRounds: [SavedRound]
    @ObservedObject var goalArchive: GoalArchive
    @State private var customGoalTitle = ""
    @State private var goalPendingDelete: CustomGoal?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Goals", subtitle: "Your round achievements update automatically from completed cards.")

                GoalProgressHero(completed: completedAutomaticCount + completedCustomCount, total: goalSuggestions.count + goalArchive.customGoals.count)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Round Goals", actionTitle: "\(completedAutomaticCount)/\(goalSuggestions.count) complete")

                    VStack(spacing: 10) {
                        ForEach(goalSuggestions) { goal in
                            GoalRow(
                                title: goal.title,
                                detail: goal.detail,
                                progress: goal.progress(savedRounds),
                                icon: goal.icon,
                                isComplete: goal.isComplete(savedRounds),
                                isManual: false,
                                toggle: nil,
                                delete: nil
                            )
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "My Goals", actionTitle: goalArchive.customGoals.isEmpty ? "Set in Settings" : "\(completedCustomCount)/\(goalArchive.customGoals.count) complete")

                    if goalArchive.customGoals.isEmpty {
                        Text("Add personal goals from Settings. They can be things like practice twice a week, stick to your routine, or play without penalties.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(AppTheme.softText)
                            .lineSpacing(3)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    } else {
                        VStack(spacing: 10) {
                            ForEach(goalArchive.customGoals) { goal in
                                GoalRow(
                                    title: goal.title,
                                    detail: goal.isComplete ? "Marked complete manually." : "Manual goal. Tap the circle when done.",
                                    progress: goal.isComplete ? "Complete" : "In progress",
                                    icon: "flag.checkered",
                                    isComplete: goal.isComplete,
                                    isManual: true,
                                    toggle: { goalArchive.toggle(goal) },
                                    delete: { goalPendingDelete = goal }
                                )
                            }
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .alert("Delete this goal?", isPresented: Binding(
            get: { goalPendingDelete != nil },
            set: { if !$0 { goalPendingDelete = nil } }
        )) {
            Button("Keep Goal", role: .cancel) { goalPendingDelete = nil }
            Button("Delete Goal", role: .destructive) {
                if let goalPendingDelete { goalArchive.delete(goalPendingDelete) }
                goalPendingDelete = nil
            }
        } message: {
            Text("This removes the goal and its completion state.")
        }
    }

    private var completedCustomCount: Int {
        goalArchive.customGoals.filter(\.isComplete).count
    }

    private var completedAutomaticCount: Int {
        goalSuggestions.filter { $0.isComplete(savedRounds) }.count
    }

    private var goalSuggestions: [GoalTemplate] {
        automaticGoalSuggestions()
    }
}

struct GoalProgressHero: View {
    let completed: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Progress")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.softText)
            HStack(alignment: .lastTextBaseline) {
                Text("\(completed)")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text("of \(max(total, 1)) complete")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.softText)
            }
            ProgressView(value: total == 0 ? 0 : Double(completed), total: Double(max(total, 1)))
                .tint(AppTheme.mint)
            Text(total == 0 ? "Add a goal to start building your target list." : "Suggested and custom goals stay in your control.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panelStrong))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
        .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
    }
}

struct SuggestedGoalRow: View {
    let title: String
    let detail: String
    let icon: String
    let isAdded: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(accent.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text(detail)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: add) {
                Text(isAdded ? "Added" : "Add")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(isAdded ? AppTheme.mint : .white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(
                        Capsule()
                            .fill(isAdded ? AppTheme.mintWash : accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
            .accessibilityLabel(isAdded ? "\(title) added" : "Add \(title)")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.elevated, accent.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke((isAdded ? AppTheme.mint : AppTheme.border).opacity(0.72)))
    }

    private var accent: Color {
        isAdded ? AppTheme.mint : Color(red: 0.02, green: 0.28, blue: 0.72)
    }
}

struct GoalRow: View {
    let title: String
    let detail: String
    let progress: String
    let icon: String
    let isComplete: Bool
    let isManual: Bool
    let toggle: (() -> Void)?
    let delete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { toggle?() }) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(isComplete ? AppTheme.mint : AppTheme.softText)
            }
            .buttonStyle(.plain)
            .disabled(!isManual)
            .accessibilityLabel(isComplete ? "Goal complete" : "Goal incomplete")

            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isComplete ? AppTheme.mint : AppTheme.gold)
                .frame(width: 34, height: 34)
                .background(Circle().fill(AppTheme.subtleFill))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text(detail)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(AppTheme.softText)
                Text(progress)
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(isComplete ? AppTheme.mint : AppTheme.gold)
            }

            Spacer()

            if let delete {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(AppTheme.gold)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(AppTheme.subtleFill))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))
        .shadow(color: AppTheme.shadow.opacity(0.45), radius: 10, x: 0, y: 5)
    }
}

private func twosCount(_ rounds: [SavedRound]) -> Int {
    rounds.flatMap(\.holes).filter { $0.score == 2 }.count
}

private func bestToParProgress(_ rounds: [SavedRound], target: Int) -> String {
    guard let best = rounds.map({ $0.totalScore - $0.totalPar }).min() else {
        return "No completed rounds yet"
    }
    if best <= target {
        return best == 0 ? "Best round level par" : "Best round \(best)"
    }
    return "\(best - target) shots away"
}

struct HeaderBlock: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(subtitle)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)
            }
            Spacer()
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.mint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(AppTheme.mintWash))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panelStrong))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
        .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
    }

    private var iconName: String {
        switch title {
        case "New Round": return "flag.fill"
        case "Goals": return "target"
        case "Settings": return "gearshape.fill"
        case "Rounds": return "list.bullet.rectangle.portrait.fill"
        default: return "flag.fill"
        }
    }
}

struct ProfileOnboardingView: View {
    @Binding var profileName: String
    @Binding var profileHomeClub: String
    @ObservedObject var playerSettings: PlayerSettings
    @ObservedObject var firebaseAccount: FirebaseAccountService
    let complete: () -> Void
    @State private var step: OnboardingStep = .account
    @State private var nameText = ""
    @State private var homeClubText = ""
    @State private var handicapText = ""

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBlock(title: step.title, subtitle: step.subtitle)

                    HStack(spacing: 8) {
                        OnboardingStepPill(title: "Account", isActive: step == .account, isComplete: firebaseAccount.user != nil)
                        OnboardingStepPill(title: "Profile", isActive: step == .profile, isComplete: false)
                    }

                    if step == .account {
                        accountStep
                    } else {
                        profileStep
                    }
                }
                .padding(20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            nameText = profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : profileName
            homeClubText = profileHomeClub
            handicapText = String(format: "%.1f", playerSettings.handicap)
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: firebaseAccount.user == nil ? "person.crop.circle.badge.plus" : "checkmark.seal.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(firebaseAccount.user == nil ? AppTheme.mint : AppTheme.mint)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(AppTheme.mintWash))

                VStack(alignment: .leading, spacing: 5) {
                    Text(firebaseAccount.user == nil ? "Create your free account" : "Account connected")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text(firebaseAccount.user == nil ? "Use email and password so your profile can support friends, groups and shared rounds later." : "You can now finish your player profile and sync it to Firebase.")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .lineSpacing(3)
                }
            }

            if let user = firebaseAccount.user {
                VStack(alignment: .leading, spacing: 7) {
                    Text(user.email ?? "Signed in")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("This account will be used for future friend features.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            } else {
                VStack(spacing: 10) {
                    SocialSignInButton(title: "Continue with Apple", systemImage: "apple.logo", style: .dark) {
                        Task {
                            await firebaseAccount.signInWithApple()
                            if firebaseAccount.user != nil {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    step = .profile
                                }
                            }
                        }
                    }
                    .disabled(firebaseAccount.isWorking)

                    SocialSignInButton(title: "Continue with Google", systemImage: "g.circle.fill", style: .light) {
                        Task {
                            await firebaseAccount.signInWithGoogle()
                            if firebaseAccount.user != nil {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    step = .profile
                                }
                            }
                        }
                    }
                    .disabled(firebaseAccount.isWorking)
                }

                HStack(spacing: 10) {
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(height: 1)
                    Text("or use email")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.softText)
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(height: 1)
                }

                VStack(spacing: 10) {
                    TextField("Email", text: $firebaseAccount.email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))

                    SecureField("Password", text: $firebaseAccount.password)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await firebaseAccount.signIn()
                            if firebaseAccount.user != nil {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    step = .profile
                                }
                            }
                        }
                    } label: {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))
                    .disabled(firebaseAccount.isWorking)

                    Button {
                        Task {
                            await firebaseAccount.createAccount()
                            if firebaseAccount.user != nil {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    step = .profile
                                }
                            }
                        }
                    } label: {
                        Text("Create Account")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
                    .disabled(firebaseAccount.isWorking)
                }

                Button {
                    Task {
                        await firebaseAccount.sendPasswordReset()
                    }
                } label: {
                    Text("Forgot Password?")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.mint)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(firebaseAccount.isWorking)
            }

            if firebaseAccount.isWorking {
                ProgressView()
                    .tint(AppTheme.mint)
            }

            if let status = firebaseAccount.statusMessage {
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(status.localizedCaseInsensitiveContains("error") ? Color.red : AppTheme.softText)
                    .lineSpacing(3)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .profile
                }
            } label: {
                Text(firebaseAccount.user == nil ? "Continue without account" : "Continue to Profile")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(firebaseAccount.user == nil ? AppTheme.softText : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 8).fill(firebaseAccount.user == nil ? AppTheme.subtleFill : AppTheme.mint))
            }
            .buttonStyle(.plain)
            .disabled(firebaseAccount.isWorking)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProfileTextField(title: "Name", placeholder: "Your name", text: $nameText)
            ProfileTextField(title: "Home Club", placeholder: "Optional", text: $homeClubText)

            VStack(alignment: .leading, spacing: 8) {
                Text("Handicap Index")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                TextField("8.6", text: $handicapText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            }

            Text(firebaseAccount.user == nil ? "This stays local until you create an account in Settings." : "This will be stored locally and synced to your Firebase profile.")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.softText)
                .lineSpacing(3)

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .account
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: false))

                Button {
                    Task {
                        await saveProfile()
                    }
                } label: {
                    Label("Start Using Precision Golf", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FirebaseAccountButtonStyle(isPrimary: true))
                .disabled(firebaseAccount.isWorking)
            }

            if firebaseAccount.isWorking {
                ProgressView()
                    .tint(AppTheme.mint)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }

    private func saveProfile() async {
        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        profileName = trimmedName.isEmpty ? "Player" : trimmedName
        profileHomeClub = homeClubText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let handicap = Double(handicapText.replacingOccurrences(of: ",", with: ".")) {
            playerSettings.replaceHandicap(handicap)
        }
        if firebaseAccount.user != nil {
            await firebaseAccount.saveProfile(displayName: profileName, handicap: playerSettings.handicap, homeClub: profileHomeClub)
        }
        complete()
    }

    private enum OnboardingStep {
        case account
        case profile

        var title: String {
            switch self {
            case .account: return "Create Account"
            case .profile: return "Your Profile"
            }
        }

        var subtitle: String {
            switch self {
            case .account: return "Set up Precision Golf for groups and shared rounds."
            case .profile: return "Tell Precision Golf who is playing."
            }
        }
    }
}

struct OnboardingStepPill: View {
    let title: String
    let isActive: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.heavy))
        }
        .foregroundStyle(isActive || isComplete ? AppTheme.mint : AppTheme.softText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? AppTheme.mintWash : AppTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActive ? AppTheme.mint.opacity(0.35) : AppTheme.border.opacity(0.65)))
    }
}

struct ProfileTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
            TextField(placeholder, text: $text)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))
        .shadow(color: AppTheme.shadow.opacity(0.42), radius: 9, x: 0, y: 5)
    }
}

struct FocusCard: View {
    let title: String
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.gold)
            Text(headline)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
            Text(detail)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .lineSpacing(3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panelStrong))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.gold.opacity(0.35)))
        .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)
    }
}

struct RecentPatternCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Live Pattern")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(AppTheme.ink)
            HStack(spacing: 10) {
                ForEach(Array(["L", "Hit", "R", "R", "Hit", "R"].enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(item == "Hit" ? .black : AppTheme.ink)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(item == "Hit" ? AppTheme.mint : AppTheme.subtleFill))
                }
            }
            Text("Driver miss is leaning right. Keep the face square and choose a conservative start line.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
    }
}

struct ScorecardPreview: View {
    let tee: TeeBox

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scorecard")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("\(tee.name) tees")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.mint)
            }

            ForEach(tee.holes.prefix(9)) { hole in
                HStack {
                    Text("\(hole.number)")
                        .frame(width: 28)
                    Text("Par \(hole.par)")
                    Spacer()
                    Text("\(hole.yards) yds")
                    Text("SI \(hole.strokeIndex)")
                        .frame(width: 44, alignment: .trailing)
                }
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(AppTheme.softText)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
    }
}

enum LiveScoringStep {
    case score
    case stats
}

struct LiveHoleNavigator: View {
    let currentHole: Int
    let totalHoles: Int
    let goPrevious: () -> Void
    let goNext: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: goPrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .heavy))
                    .frame(width: 42, height: 38)
            }
            .disabled(currentHole <= 1)

            Text("Hole \(currentHole) of \(totalHoles)")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))

            Button(action: goNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .frame(width: 42, height: 38)
            }
            .disabled(currentHole >= totalHoles)
        }
        .buttonStyle(LiveHoleNavButtonStyle())
    }
}

struct LiveHoleNavButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppTheme.mint)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? AppTheme.mintWash : AppTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct LiveScoringStepPill: View {
    @Binding var step: LiveScoringStep

    var body: some View {
        HStack(spacing: 8) {
            stepItem(title: "Score", icon: "number", target: .score)
            stepItem(title: "Stats", icon: "chart.bar.fill", target: .stats)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))
    }

    private func stepItem(title: String, icon: String, target: LiveScoringStep) -> some View {
        let isSelected = step == target

        return Button {
            step = target
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .heavy))
                Text(title)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
            }
            .foregroundStyle(isSelected ? .white : AppTheme.softText)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? AppTheme.mint : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

struct ScoreKeypadPanel: View {
    let hole: Hole
    @Binding var score: Int
    let pickedUp: Bool
    let pickupScore: Int
    let markPickedUp: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gross Score")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("Par \(hole.par)")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(AppTheme.subtleFill))
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(1...9, id: \.self) { value in
                    ScoreKeypadButton(
                        title: "\(value)",
                        subtitle: scoreLabel(for: value),
                        isSelected: score == value && !pickedUp,
                        action: { score = value }
                    )
                }

                ScoreKeypadButton(
                    title: "Clear",
                    subtitle: nil,
                    isSelected: score == 0 && !pickedUp,
                    isUtility: true,
                    action: { score = 0 }
                )

                ScoreKeypadButton(
                    title: "Pickup",
                    subtitle: "\(pickupScore)",
                    isSelected: pickedUp,
                    isUtility: true,
                    action: markPickedUp
                )

                ScoreKeypadButton(
                    title: "10+",
                    subtitle: score >= 10 && !pickedUp ? "\(score)" : nil,
                    isSelected: score >= 10 && !pickedUp,
                    isUtility: true,
                    action: { score = max(score, 10) }
                )
            }

            if score >= 10 && !pickedUp {
                HStack(spacing: 10) {
                    Button {
                        score = max(10, score - 1)
                    } label: {
                        Image(systemName: "minus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RoundActionStyle(isPrimary: false))

                    Text("\(score)")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                        .frame(width: 72)

                    Button {
                        score = min(12, score + 1)
                    } label: {
                        Image(systemName: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RoundActionStyle(isPrimary: false))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.72), radius: 14, x: 0, y: 8)
    }

    private func scoreLabel(for value: Int) -> String? {
        let relative = value - hole.par
        switch relative {
        case ...(-3): return "Albatross"
        case -2: return "Eagle"
        case -1: return "Birdie"
        case 0: return "Par"
        case 1: return "Bogey"
        case 2: return "Double"
        default: return nil
        }
    }
}

struct ScoreKeypadButton: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    var isUtility = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: isUtility ? 19 : 34, weight: .regular, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(isSelected ? .white : AppTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: isUtility ? 58 : 70)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        if isSelected { return AppTheme.mint }
        return isUtility ? AppTheme.subtleFill : AppTheme.panelStrong
    }

    private var border: Color {
        if isSelected { return AppTheme.mint.opacity(0.22) }
        return isUtility ? AppTheme.border.opacity(0.7) : AppTheme.border.opacity(0.95)
    }
}

struct StepperPanel: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accent: Color
    var blankWhenZero = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Text(title == "Score" ? "Gross strokes" : "Total putts")
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .textCase(.uppercase)
            }
            Spacer()
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(CounterButtonStyle())
            Text(blankWhenZero && value == 0 ? "-" : "\(value)")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(blankWhenZero && value == 0 ? AppTheme.softText : accent)
                .frame(width: 54)
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(CounterButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.58), radius: 12, x: 0, y: 6)
    }
}

struct CompactStepperPanel: View {
    let title: String
    let subtitle: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .textCase(.uppercase)
            }
            Spacer()
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(CounterButtonStyle())
            Text("\(value)")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .frame(width: 48)
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(CounterButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.46), radius: 10, x: 0, y: 5)
    }
}

struct ChoicePanel: View {
    let title: String
    @Binding var selection: MissDirection
    let choices: [MissDirection]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(AppTheme.ink)
            HStack(spacing: 8) {
                ForEach(choices) { choice in
                    Button {
                        selection = choice
                    } label: {
                        Text(choice.rawValue)
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(selection == choice ? .white : AppTheme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selection == choice ? AppTheme.mint : AppTheme.subtleFill))
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }
}

struct OptionPanel<Option: Identifiable & RawRepresentable & Hashable>: View where Option.RawValue == String {
    let title: String
    @Binding var selection: Option
    let choices: [Option]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(AppTheme.ink)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(choices) { choice in
                        Button {
                            selection = choice
                        } label: {
                            Text(choice.rawValue)
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .foregroundStyle(selection == choice ? .white : AppTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 13)
                                .frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 8).fill(selection == choice ? AppTheme.mint : AppTheme.subtleFill))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }
}

struct ToggleGridItem: Identifiable {
    let id = UUID()
    let title: String
    let isOn: Binding<Bool>
}

struct ToggleGridPanel: View {
    let items: [ToggleGridItem]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(items) { item in
                Button {
                    item.isOn.wrappedValue.toggle()
                } label: {
                    HStack {
                        Image(systemName: item.isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                        Text(item.title)
                        Spacer()
                    }
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(item.isOn.wrappedValue ? .white : AppTheme.ink)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 8).fill(item.isOn.wrappedValue ? AppTheme.mint : AppTheme.subtleFill))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }
}

struct QuickStatsPanel: View {
    let showFairway: Bool
    @Binding var fairway: MissDirection
    @Binding var green: MissDirection
    @Binding var approachProximity: ApproachProximity?
    @Binding var penalties: Int
    @Binding var penaltyType: PenaltyType
    @Binding var bunker: Bool

    var body: some View {
        VStack(spacing: 8) {
            if showFairway {
                ShotOutcomePanel(
                    title: "Fairway",
                    hitTitle: "Hit Fairway",
                    selection: $fairway,
                    missChoices: [.left, .right]
                )
            }

            ShotOutcomePanel(
                title: "Green in Regulation",
                hitTitle: "Hit GIR",
                selection: $green,
                missChoices: [.left, .right, .short, .long]
            )

            if green == .hit {
                ApproachProximityPanel(selection: $approachProximity)
            }

            HStack {
                Text("Penalties")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                ForEach([0, 1, 2], id: \.self) { value in
                    Button {
                        penalties = value
                    } label: {
                        Text(value == 2 ? "2+" : "\(value)")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(penalties == value ? .white : AppTheme.ink)
                            .frame(width: 46, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(penalties == value ? AppTheme.gold : AppTheme.subtleFill))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(penalties == value ? AppTheme.gold.opacity(0.18) : AppTheme.border.opacity(0.62)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if penalties > 0 {
                PenaltyTypePanel(selection: $penaltyType)
            }

            HStack(spacing: 12) {
                Text("Bunker Save")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button {
                    bunker.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: bunker ? "checkmark.circle.fill" : "circle")
                        Text("Yes")
                    }
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(bunker ? .white : AppTheme.ink)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(bunker ? AppTheme.mint : AppTheme.subtleFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.46), radius: 10, x: 0, y: 5)
        .onChange(of: green) { _, newValue in
            if newValue != .hit {
                approachProximity = nil
            }
        }
        .onChange(of: penalties) { _, newValue in
            if newValue == 0 {
                penaltyType = .none
            } else if penaltyType == .none {
                penaltyType = .water
            }
        }
    }
}

struct PenaltyTypePanel: View {
    @Binding var selection: PenaltyType

    private var choices: [PenaltyType] {
        PenaltyType.allCases.filter { $0 != .none }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Penalty Type")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.ink)

            HStack(spacing: 8) {
                ForEach(choices) { type in
                    Button {
                        selection = type
                    } label: {
                        Text(type.rawValue)
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(selection == type ? .white : AppTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selection == type ? AppTheme.gold : AppTheme.subtleFill))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == type ? AppTheme.gold.opacity(0.18) : AppTheme.border.opacity(0.62)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ApproachProximityPanel: View {
    @Binding var selection: ApproachProximity?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Approach Proximity")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("GIR only")
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.mint)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ApproachProximity.allCases) { proximity in
                    Button {
                        selection = proximity
                    } label: {
                        Text(proximity.rawValue)
                            .font(.system(.caption, design: .rounded).weight(.heavy))
                            .foregroundStyle(selection == proximity ? .white : AppTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selection == proximity ? AppTheme.mint : AppTheme.subtleFill))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.mint.opacity(0.16)))
    }
}

struct RunningRoundStrip: View {
    let gross: Int
    let stableford: Int

    var body: some View {
        HStack(spacing: 14) {
            RunningRoundValue(title: "Gross", value: "\(gross)", accent: AppTheme.lime)

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1, height: 22)

            RunningRoundValue(title: "Stableford", value: "\(stableford)", accent: AppTheme.mint)

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
    }
}

struct LiveRoundHeaderCard: View {
    let courseName: String
    let holeNumber: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int
    let courseHandicap: Int
    let gross: Int
    let scoreToPar: Int
    let stableford: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(courseName)
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                    Text("Hole \(holeNumber)")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .layoutPriority(1)

                Spacer()

                HStack(spacing: 6) {
                    headerPill("Par \(par)")
                    headerPill("\(yards) yds")
                    headerPill("SI \(strokeIndex)")
                }
                .layoutPriority(2)
            }

            HStack(spacing: 8) {
                LiveRoundHeaderMetric(title: "Gross", value: "\(gross)", accent: AppTheme.lime)
                LiveRoundHeaderMetric(title: "To Par", value: scoreToParLabel, accent: scoreToParAccent, fill: scoreToParFill)
                LiveRoundHeaderMetric(title: "Points", value: "\(stableford)", accent: .white)
                LiveRoundHeaderMetric(title: "CH", value: "\(courseHandicap)", accent: .white)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.mint, AppTheme.lime],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.62)))
        .shadow(color: AppTheme.shadow.opacity(1.05), radius: 16, x: 0, y: 8)
    }

    private var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }

    private var scoreToParAccent: Color {
        .white
    }

    private var scoreToParFill: Color? {
        scoreToPar > 0 ? Color(red: 0.82, green: 0.03, blue: 0.03) : nil
    }

    private func headerPill(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded).weight(.heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.16)))
    }
}

struct LiveRoundHeaderMetric: View {
    let title: String
    let value: String
    let accent: Color
    var fill: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(.white.opacity(0.72))
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill ?? Color.white.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(fill == nil ? Color.white.opacity(0.18) : Color.white.opacity(0.34)))
    }
}

struct RunningRoundValue: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
        }
    }
}

struct ShotOutcomePanel: View {
    let title: String
    let hitTitle: String
    @Binding var selection: MissDirection
    let missChoices: [MissDirection]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button {
                    selection = selection == .hit ? .notTracked : .hit
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selection == .hit ? "checkmark.circle.fill" : "circle")
                        Text(hitTitle)
                    }
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(selection == .hit ? .white : AppTheme.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selection == .hit ? AppTheme.mint : AppTheme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == .hit ? AppTheme.mint.opacity(0.18) : AppTheme.border.opacity(0.62)))
                }
                .buttonStyle(.plain)
            }

            if selection != .hit {
                HStack(spacing: 8) {
                    ForEach(missChoices) { choice in
                        Button {
                            selection = choice
                        } label: {
                            Text("Miss \(choice.rawValue)")
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .foregroundStyle(selection == choice ? .white : AppTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(selection == choice ? AppTheme.gold.opacity(0.9) : AppTheme.subtleFill))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == choice ? AppTheme.gold.opacity(0.2) : AppTheme.border.opacity(0.62)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct PenaltyPanel: View {
    @Binding var penalties: Int

    var body: some View {
        HStack {
            Text("Penalties")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(AppTheme.ink)
            Spacer()
            ForEach([0, 1, 2], id: \.self) { value in
                Button {
                    penalties = value
                } label: {
                    Text(value == 2 ? "2+" : "\(value)")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(penalties == value ? .black : AppTheme.ink)
                        .frame(width: 48, height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(penalties == value ? AppTheme.gold : AppTheme.subtleFill))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
    }
}

struct InsightMetricSection<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill.opacity(0.78)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.78)))
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
            }
            content
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.72), radius: 18, x: 0, y: 10)
    }
}

struct InsightStatGrid<Content: View>: View {
    @ViewBuilder let content: Content

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            content
        }
    }
}

struct InsightStatTile: View {
    let title: String
    let value: String
    let caption: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(AppTheme.softText)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(AppTheme.subtleFill.opacity(0.76)))
                Text(title)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(2)
                Spacer(minLength: 8)
            }

            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .minimumScaleFactor(0.68)
                .lineLimit(1)

            Text(caption)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.62)))
        .shadow(color: AppTheme.shadow.opacity(0.42), radius: 10, x: 0, y: 6)
    }

    private var iconName: String {
        switch title.lowercased() {
        case let value where value.contains("bird"):
            return "bird.fill"
        case let value where value.contains("par 3"):
            return "3.circle.fill"
        case let value where value.contains("par 4"):
            return "4.circle.fill"
        case let value where value.contains("par 5"):
            return "5.circle.fill"
        case let value where value.contains("pars"):
            return "checkmark.seal.fill"
        case let value where value.contains("bogey"):
            return "plus.circle.fill"
        case let value where value.contains("worse"):
            return "xmark.octagon.fill"
        case let value where value.contains("fairway"):
            return "arrow.up.forward.circle.fill"
        case let value where value.contains("left"):
            return "arrow.left.circle.fill"
        case let value where value.contains("right"):
            return "arrow.right.circle.fill"
        case let value where value.contains("short"):
            return "arrow.down.circle.fill"
        case let value where value.contains("long"):
            return "arrow.up.circle.fill"
        case let value where value.contains("gir"):
            return "target"
        case let value where value.contains("putt"):
            return "circle.grid.cross.fill"
        default:
            return "chart.bar.fill"
        }
    }
}

struct InsightHero: View {
    let snapshot: InsightSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.roundCount <= 1 ? "Round Pace" : "Performance Baseline")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.mint)
            HStack(alignment: .lastTextBaseline) {
                Text(snapshot.scoreToParLabel)
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text("vs par")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }
            Text(headline)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panelStrong))
    }

    private var headline: String {
        if snapshot.penalties > 0 || snapshot.doublesOrWorse > 0 {
            return "You are losing shots through \(snapshot.penalties) penalties and \(snapshot.doublesOrWorse) doubles or worse."
        }
        if snapshot.girPercent < 35 {
            return "Approach play is the main scoring lever, with \(snapshot.girPercent)% GIR from the tracked holes."
        }
        if snapshot.threePutts > 0 {
            return "Putting pace is worth attention: \(snapshot.threePutts) three-putts are on the card."
        }
        return "The baseline is clean. Add more completed rounds to sharpen the pattern."
    }
}

struct InsightRow: View {
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AppTheme.mint)
                .frame(width: 38, height: 38)
                .background(Circle().fill(AppTheme.subtleFill))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.softText)
                Text(value)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text(detail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
    }
}

struct MissPatternSection: View {
    let snapshot: InsightSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Miss Patterns", actionTitle: leakTitle)

            VStack(spacing: 12) {
                MissPatternCard(
                    title: "Tee Game",
                    icon: "location.north.line.fill",
                    trackedLabel: "\(snapshot.fairwaysTotal) tracked tee shots",
                    hitLabel: "\(snapshot.fairwayPercent)% fairways",
                    misses: snapshot.fairwayMisses,
                    directions: [.left, .right]
                )

                MissPatternCard(
                    title: "Approach",
                    icon: "scope",
                    trackedLabel: "\(snapshot.greensTotal) tracked approaches",
                    hitLabel: "\(snapshot.girPercent)% GIR",
                    misses: snapshot.greenMisses,
                    directions: [.short, .long, .left, .right]
                )
            }
        }
    }

    private var leakTitle: String? {
        guard let leak else { return nil }
        return "\(leak.area): \(leak.direction.rawValue)"
    }

    private var leak: (area: String, direction: MissDirection, count: Int)? {
        let fairway = topMiss(in: snapshot.fairwayMisses, directions: [.left, .right]).map { ("Tee", $0.direction, $0.count) }
        let approach = topMiss(in: snapshot.greenMisses, directions: [.short, .long, .left, .right]).map { ("Approach", $0.direction, $0.count) }
        return [fairway, approach]
            .compactMap { $0 }
            .max { $0.count < $1.count }
    }

    private func topMiss(in misses: [MissDirection], directions: [MissDirection]) -> (direction: MissDirection, count: Int)? {
        directions
            .map { direction in (direction, misses.filter { $0 == direction }.count) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
    }
}

struct MissPatternCard: View {
    let title: String
    let icon: String
    let trackedLabel: String
    let hitLabel: String
    let misses: [MissDirection]
    let directions: [MissDirection]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.subtleFill))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("\(trackedLabel) - \(hitLabel)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
            }

            if misses.isEmpty {
                Text("No misses tracked yet. Use the miss buttons during scoring to build this view.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
            } else {
                VStack(spacing: 10) {
                    ForEach(directions, id: \.self) { direction in
                        MissPatternBar(
                            direction: direction,
                            count: count(for: direction),
                            totalMisses: max(misses.count, 1)
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }

    private func count(for direction: MissDirection) -> Int {
        misses.filter { $0 == direction }.count
    }
}

struct MissPatternBar: View {
    let direction: MissDirection
    let count: Int
    let totalMisses: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(direction.rawValue)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("\(count) - \(percent)%")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(count == 0 ? AppTheme.softText : AppTheme.mint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.subtleFill)
                    Capsule()
                        .fill(count == 0 ? AppTheme.border : AppTheme.mint)
                        .frame(width: max(6, proxy.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: 8)
        }
    }

    private var percent: Int {
        totalMisses == 0 ? 0 : Int((Double(count) / Double(totalMisses) * 100).rounded())
    }
}

struct TrendPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

struct RoundTrendSection: View {
    let rounds: [SavedRound]

    private var orderedRounds: [SavedRound] {
        Array(rounds.sorted { $0.date < $1.date }.suffix(8))
    }

    var body: some View {
        if orderedRounds.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Trends", actionTitle: "last \(orderedRounds.count)")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    TrendCard(title: "Score", points: points { Double($0.totalScore) }, lowerIsBetter: true)
                    TrendCard(title: "Stableford", points: points { Double($0.stablefordPoints ?? 0) }, lowerIsBetter: false)
                    TrendCard(title: "GIR", points: points { Double($0.greensInRegulation) }, lowerIsBetter: false)
                    TrendCard(title: "Fairways", points: points { Double($0.fairwaysHit) }, lowerIsBetter: false)
                    TrendCard(title: "Putts", points: points { Double($0.totalPutts) }, lowerIsBetter: true)
                    TrendCard(title: "Penalties", points: points { Double($0.penalties) }, lowerIsBetter: true)
                }
            }
        }
    }

    private func points(_ value: (SavedRound) -> Double) -> [TrendPoint] {
        orderedRounds.map { round in
            TrendPoint(label: Self.dateFormatter.string(from: round.date), value: value(round))
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM"
        return formatter
    }()
}

struct TrendCard: View {
    let title: String
    let points: [TrendPoint]
    let lowerIsBetter: Bool

    private var latestValue: String {
        guard let value = points.last?.value else { return "-" }
        return value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private var previousValue: Double? {
        guard points.count >= 2 else { return nil }
        return points[points.count - 2].value
    }

    private var averageValue: String {
        guard !points.isEmpty else { return "-" }
        let average = points.reduce(0) { $0 + $1.value } / Double(points.count)
        return average == average.rounded() ? "\(Int(average))" : String(format: "%.1f", average)
    }

    private var changeText: String {
        guard let previousValue, let latest = points.last?.value else { return "No trend yet" }
        let change = latest - previousValue
        guard abs(change) >= 0.1 else { return "No change" }
        let prefix = change > 0 ? "+" : ""
        return "\(prefix)\(format(change)) vs previous"
    }

    private var statusText: String {
        guard let previousValue, let latest = points.last?.value else { return "Pending" }
        let change = latest - previousValue
        guard abs(change) >= 0.1 else { return "Flat" }
        let improved = lowerIsBetter ? change < 0 : change > 0
        return improved ? "Improving" : "Needs work"
    }

    private var statusColor: Color {
        statusText == "Improving" ? AppTheme.mint : statusText == "Needs work" ? AppTheme.gold : AppTheme.softText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.softText)
                    .textCase(.uppercase)
                Spacer()
                Text(statusText)
                    .font(.system(.caption2, design: .rounded).weight(.heavy))
                    .foregroundStyle(statusColor)
            }
            Text(latestValue)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
            HStack(spacing: 8) {
                Text("Avg \(averageValue)")
                Text(changeText)
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(AppTheme.softText)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border))
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

struct TrendLineChart: View {
    let points: [TrendPoint]
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.value)
            let minValue = values.min() ?? 0
            let maxValue = values.max() ?? 1
            let range = max(maxValue - minValue, 1)
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)

            ZStack(alignment: .bottomLeading) {
                Path { path in
                    guard points.count > 1 else { return }
                    for index in points.indices {
                        let x = CGFloat(index) / CGFloat(max(points.count - 1, 1)) * width
                        let y = height - CGFloat((points[index].value - minValue) / range) * height
                        if index == points.startIndex {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let x = CGFloat(index) / CGFloat(max(points.count - 1, 1)) * width
                    let y = height - CGFloat((point.value - minValue) / range) * height
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(accent, lineWidth: 2))
                        .position(x: x, y: y)
                }
            }
        }
    }
}

struct CourseInsightsSection: View {
    let rounds: [SavedRound]

    private var stats: [CourseFormStat] {
        Dictionary(grouping: rounds, by: \.courseName)
            .map { CourseFormStat(courseName: $0.key, rounds: $0.value) }
            .sorted { $0.averageScore < $1.averageScore }
    }

    var body: some View {
        if !stats.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Course Trends", actionTitle: nil)
                VStack(spacing: 8) {
                    ForEach(stats.prefix(3)) { stat in
                        CourseFormRow(stat: stat)
                    }
                }
            }
        }
    }
}

struct ClubGappingSection: View {
    let clubs: [ClubYardage]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var mappedClubs: [ClubYardage] {
        clubs
            .filter { $0.isInBag && $0.yards != nil }
            .sorted { ($0.yards ?? 0) > ($1.yards ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Club Gapping")
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text(mappedClubs.isEmpty ? "Add carries to build the ladder." : "\(mappedClubs.count) mapped carries")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(AppTheme.softText)
                }
                Spacer()
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.mintWash))
            }

            VStack(spacing: 8) {
                if mappedClubs.count < 3 {
                    Text("Add carry distances in Yardages to unlock bag-gap analysis.")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.softText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill.opacity(0.7)))
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(mappedClubs) { club in
                            YardageGapTile(club: club)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.72), radius: 18, x: 0, y: 10)
    }
}

struct YardageGapTile: View {
    let club: ClubYardage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(club.name)
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Spacer(minLength: 4)
                Text(club.yards.map { "\($0)" } ?? "-")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.mint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text("yds")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.72)))
        .shadow(color: AppTheme.shadow.opacity(0.42), radius: 9, x: 0, y: 5)
    }
}

struct JournalPrompt: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.gold)
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.ink)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
    }
}

struct TabBar: View {
    @Binding var selectedTab: Tab

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)

            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 19, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(selectedTab == tab ? AppTheme.mint : AppTheme.tabInactive)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(selectedTab == tab ? AppTheme.mintWash : Color.clear)
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(
            AppTheme.tabBar
                .ignoresSafeArea()
        )
    }
}

struct CounterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(AppTheme.mint)
            .frame(width: 42, height: 42)
            .background(Circle().fill(configuration.isPressed ? AppTheme.mintWash : Color.white))
            .overlay(Circle().stroke(AppTheme.border.opacity(0.82)))
            .shadow(color: AppTheme.shadow.opacity(0.42), radius: 8, x: 0, y: 4)
    }
}

struct RoundActionStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(isPrimary ? Color.white : AppTheme.ink)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 8).fill(isPrimary ? AppTheme.mint : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isPrimary ? AppTheme.mint.opacity(0.18) : AppTheme.border.opacity(0.9)))
            .shadow(color: AppTheme.shadow.opacity(isPrimary ? 0.92 : 0.42), radius: 12, x: 0, y: 6)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
