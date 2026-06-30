import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var roundArchive = RoundArchive()
    @StateObject private var playerSettings = PlayerSettings()
    @StateObject private var courseFavorites = CourseFavorites()
    @StateObject private var goalArchive = GoalArchive()
    @StateObject private var clubYardages = ClubYardageStore()
    @StateObject private var handicapHistory = HandicapHistoryStore()
    @StateObject private var scorecardStore = CourseScorecardStore()
    @AppStorage("pinpoint.profileImageData") private var profileImageData: Data = Data()
    @AppStorage("precision.profileName") private var profileName = ""
    @AppStorage("precision.profileHomeClub") private var profileHomeClub = ""
    @AppStorage("precision.profileOnboardingComplete") private var profileOnboardingComplete = false
    @State private var selectedTab: Tab = .home
    @State private var selectedCourse = CourseDatabase.courses[0]
    @State private var selectedTee = CourseDatabase.courses[0].tees[0]
    @State private var isRoundActive = false
    @State private var isRoundFlowPresented = false
    @State private var isRoundReviewPresented = false
    @State private var currentHoleIndex = 0
    @State private var roundHandicap = 0.0
    @State private var entries = DemoData.holes.map {
        ContentView.defaultEntry(for: $0)
    }
    private let activeRoundDraftKey = "pinpoint.activeRoundDraft"

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                TabBar(selectedTab: $selectedTab)
            }
        }
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $isRoundFlowPresented) {
            roundFlow
        }
        .sheet(isPresented: onboardingBinding) {
            ProfileOnboardingView(
                profileName: $profileName,
                profileHomeClub: $profileHomeClub,
                playerSettings: playerSettings,
                complete: {
                    profileOnboardingComplete = true
                }
            )
            .interactiveDismissDisabled()
        }
        .onAppear {
            restoreActiveRoundDraft()
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
                    isRoundActive: isRoundActive,
                    currentHandicap: playerSettings.handicap,
                    profileName: profileName,
                    profileHomeClub: profileHomeClub,
                    profileImageData: $profileImageData,
                    startRound: {
                        openRoundFlow()
                    },
                    discardRound: discardCurrentRound,
                    deleteRound: { round in
                        roundArchive.delete(roundID: round.id)
                    },
                    updateRound: { round in
                        roundArchive.update(round)
                    }
                )
        case .yardages:
            YardagesView(store: clubYardages)
        case .insights:
            RecentRoundsView(
                savedRounds: roundArchive.rounds,
                currentHandicap: playerSettings.handicap,
                startRound: openRoundFlow,
                deleteRound: { round in
                    roundArchive.delete(roundID: round.id)
                },
                updateRound: { round in
                    roundArchive.update(round)
                }
            )
        case .goals:
            GoalsView(savedRounds: roundArchive.rounds, goalArchive: goalArchive)
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

    private func beginRound() {
        currentHoleIndex = 0
        entries = selectedTee.holes.map {
            Self.defaultEntry(for: $0)
        }
        isRoundActive = true
        isRoundFlowPresented = true
        saveActiveRoundDraft()
    }

    private func finishRound() {
        isRoundReviewPresented = true
    }

    private func saveReviewedRound() {
        roundArchive.save(course: selectedCourse, tee: selectedTee, handicap: roundHandicap, entries: entries)
        handicapHistory.record(roundHandicap)
        isRoundActive = false
        isRoundFlowPresented = false
        isRoundReviewPresented = false
        currentHoleIndex = 0
        selectedTab = .home
        clearActiveRoundDraft()
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
        selectedTab = .home
        clearActiveRoundDraft()
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
        .preferredColorScheme(.light)
    }
}

enum Tab: String, CaseIterable {
    case home = "Home"
    case yardages = "Yardages"
    case insights = "Rounds"
    case goals = "Goals"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .yardages: "ruler.fill"
        case .insights: "list.bullet.rectangle.portrait.fill"
        case .goals: "target"
        case .settings: "gearshape.fill"
        }
    }
}

struct AppTheme {
    static let background = LinearGradient(
        colors: [.white, .white],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let panel = Color.white
    static let panelStrong = Color.white
    static let subtleFill = Color(red: 0.965, green: 0.97, blue: 0.968)
    static let ink = Color(red: 0.07, green: 0.13, blue: 0.10)
    static let softText = Color(red: 0.37, green: 0.45, blue: 0.40)
    static let mint = Color(red: 0.02, green: 0.43, blue: 0.24)
    static let mintWash = Color(red: 0.93, green: 0.97, blue: 0.95)
    static let lime = Color(red: 0.70, green: 0.95, blue: 0.18)
    static let gold = Color(red: 0.72, green: 0.50, blue: 0.11)
    static let border = Color(red: 0.88, green: 0.895, blue: 0.89)
    static let shadow = Color.black.opacity(0.055)
}

struct HomeView: View {
    let savedRounds: [SavedRound]
    let entries: [RoundHoleEntry]
    let recentRounds: [RoundSummary]
    let isRoundActive: Bool
    let currentHandicap: Double
    let profileName: String
    let profileHomeClub: String
    @Binding var profileImageData: Data
    let startRound: () -> Void
    let discardRound: () -> Void
    let deleteRound: (SavedRound) -> Void
    let updateRound: (SavedRound) -> Void
    @State private var selectedRound: SavedRound?
    @State private var showDiscardRoundAlert = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    PlayerProfileCard(
                        rounds: savedRounds,
                        profileName: profileName,
                        profileHomeClub: profileHomeClub,
                        profileImageData: $profileImageData
                    )

                    PerformanceOverview(rounds: savedRounds)

                    InsightsDashboardContent(entries: entries, savedRounds: savedRounds, isRoundActive: isRoundActive, currentHandicap: currentHandicap)

                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 112)
            }

            HomeFloatingRoundButton(
                isRoundActive: isRoundActive,
                startRound: startRound,
                discardRound: { showDiscardRoundAlert = true }
            )
            .padding(.trailing, 22)
            .padding(.bottom, 18)
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
}

struct RecentRoundsView: View {
    let savedRounds: [SavedRound]
    let currentHandicap: Double
    let startRound: () -> Void
    let deleteRound: (SavedRound) -> Void
    let updateRound: (SavedRound) -> Void
    @State private var selectedRound: SavedRound?
    @State private var visibleRecentRoundCount = 8

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
                                deleteRound: { deleteRound(round) }
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
                HStack(spacing: 10) {
                    Image(systemName: isRoundActive ? "flag.fill" : "plus")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(isRoundActive ? Color(red: 0.02, green: 0.24, blue: 0.52) : Color(red: 0.57, green: 0.86, blue: 0.18))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().stroke(Color.white.opacity(0.72), lineWidth: 1))
                    Text(isRoundActive ? "Resume Round" : "New Round")
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(Color.white)
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .frame(height: 56)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.03, green: 0.32, blue: 0.72),
                                    Color(red: 0.00, green: 0.54, blue: 0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(Capsule().stroke(Color.white.opacity(0.36), lineWidth: 1))
                .shadow(color: Color(red: 0.02, green: 0.24, blue: 0.52).opacity(0.32), radius: 16, x: 0, y: 8)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.72), radius: 18, x: 0, y: 10)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
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
                                colors: [AppTheme.mint, Color(red: 0.12, green: 0.56, blue: 0.32)],
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
        .overlay(Circle().stroke(.white, lineWidth: 4))
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
        .background(Capsule().fill(AppTheme.subtleFill.opacity(0.74)))
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 12, weight: .heavy))
                            Text("\(String(seasonYear)) Season")
                                .font(.system(.caption2, design: .rounded).weight(.heavy))
                        }
                        .foregroundStyle(.white.opacity(0.86))

                        Text("Scoring Average")
                            .font(.system(.title3, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    Text(roundCountLabel)
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.mint)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white))
                }

                HStack(alignment: .bottom, spacing: 16) {
                    Text(scoringAverage)
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("gross")
                            .font(.system(.caption2, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white.opacity(0.72))
                            .textCase(.uppercase)
                        Text("per round")
                            .font(.system(.subheadline, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.bottom, 11)
                    Spacer()
                }
            }
            .padding(20)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.07, green: 0.67, blue: 0.35), AppTheme.mint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )

            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    CompactMetricPill(title: "Stableford", value: averageStableford, tint: AppTheme.mint)
                    CompactMetricPill(title: "Putts", value: averagePutts, tint: AppTheme.gold)
                    CompactMetricPill(title: "Penalties", value: averagePenalties, tint: Color(red: 0.82, green: 0.34, blue: 0.20))
                    CompactMetricPill(title: "Fairways", value: "\(fairwayPercent)%", tint: AppTheme.mint)
                    CompactMetricPill(title: "GIR", value: "\(girPercent)%", tint: Color(red: 0.11, green: 0.42, blue: 0.74))
                    CompactMetricPill(title: "Scramble", value: "\(scramblePercent)%", tint: Color(red: 0.42, green: 0.22, blue: 0.58))
                }

                ScoringMixStrip(
                    birdies: averageBirdies,
                    pars: averagePars,
                    bogeys: averageBogeys,
                    doubles: averageDoublesOrWorse
                )
            }
            .padding(16)
            .background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.9)))
        .shadow(color: AppTheme.shadow.opacity(0.72), radius: 18, x: 0, y: 10)
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
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text("avg per round")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
    }
}

struct HoleAverageCard: View {
    let title: String
    let value: String
    let target: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "flag.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(tint)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(tint.opacity(0.12)))
                Spacer()
                Text(target)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Capsule().fill(AppTheme.subtleFill))
            }

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
        .frame(minHeight: 118)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white, tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.18)))
        .shadow(color: tint.opacity(0.12), radius: 14, x: 0, y: 8)
        .shadow(color: AppTheme.shadow.opacity(0.7), radius: 8, x: 0, y: 4)
    }
}

struct CompactMetricPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 70)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.72)))
        .shadow(color: AppTheme.shadow.opacity(0.38), radius: 10, x: 0, y: 6)
    }
}

struct ScoringMixPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.62)))
        .shadow(color: AppTheme.shadow.opacity(0.32), radius: 9, x: 0, y: 5)
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
                                .font(.system(.headline, design: .rounded).weight(.bold))
                                .foregroundStyle(AppTheme.ink)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(round.summary.dateLabel)
                                    .font(.system(.caption, design: .rounded).weight(.bold))
                                    .foregroundStyle(AppTheme.softText)
                                Text(handicapText)
                                    .font(.system(.caption, design: .rounded).weight(.heavy))
                                    .foregroundStyle(AppTheme.ink)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
                            }
                        }
                        HStack(spacing: 6) {
                            TeeMarkerSwatch(marker: round.teeMarkerColor ?? TeeMarkerColor.inferred(from: round.teeName), size: 10)
                            Text("\(round.teeName) tees - \(round.greensInRegulation) GIR - \(round.totalPutts) putts\(stablefordText)")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(AppTheme.softText)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.mint)
                }
            }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $isEditingRound) {
            SavedRoundEditorView(round: round) { updatedRound in
                updateRound(updatedRound)
                isEditingRound = false
                dismiss()
            }
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
        .preferredColorScheme(.light)
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
                    Text("Digital Scorecard")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(AppTheme.ink)
                    Text("\(round.teeName) tees - \(round.summary.dateLabel)")
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
                    ScorecardTable(title: "Out", holes: frontNine, metrics: metrics)
                    ScorecardTable(title: "In", holes: backNine, metrics: metrics)
                    ScorecardTotalRow(round: round)
                }
            }
            .frame(height: 402)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.panel)
                .shadow(color: AppTheme.shadow, radius: 16, x: 0, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
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

struct ScorecardTable: View {
    let title: String
    let holes: [SavedHoleEntry]
    let metrics: ScorecardMetrics

    var body: some View {
        VStack(spacing: 4) {
            ScorecardHoleHeader(holes: holes, total: title, metrics: metrics)
            ScorecardInfoRow(label: "SI", values: holes.map { "\($0.strokeIndex)" }, total: "", metrics: metrics)
            ScorecardInfoRow(label: "Par", values: holes.map { "\($0.par)" }, total: "\(holes.reduce(0) { $0 + $1.par })", metrics: metrics)
            ScorecardInfoRow(label: "Yds", values: holes.map { "\($0.yards)" }, total: "\(holes.reduce(0) { $0 + $1.yards })", metrics: metrics)
            ScorecardScoreRow(holes: holes, total: "\(holes.reduce(0) { $0 + $1.score })", metrics: metrics)
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
            ScorecardFooterCell(title: "CR", value: String(format: "%.1f", round.teeRating))
            ScorecardFooterCell(title: "Score", value: "\(round.totalScore)/\(round.totalPar)", accent: AppTheme.mint)
            ScorecardFooterCell(title: "Slope", value: "\(round.teeSlope)")
            ScorecardFooterCell(title: "Putts", value: "\(round.totalPutts)")
            ScorecardFooterCell(title: "Scr", value: "\(round.scramblePercent)%", accent: AppTheme.mint)
            ScorecardFooterCell(title: "Points", value: stablefordText, accent: AppTheme.gold)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mintWash))
    }

    private var stablefordText: String {
        round.stablefordPoints.map { "\($0) pts" } ?? "- pts"
    }
}

struct ScorecardHoleHeader: View {
    let holes: [SavedHoleEntry]
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

struct ScorecardScoreRow: View {
    let holes: [SavedHoleEntry]
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

struct ScorecardResultCell: View {
    let hole: SavedHoleEntry
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

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - 40)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBlock(title: "New Round", subtitle: "Choose a course from the database or enter a scorecard manually.")

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
                        startRound: startRound,
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
        startRound()
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
        .preferredColorScheme(.light)
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
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
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
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Build your bag map and spot distance gaps quickly.")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "ruler.fill")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(AppTheme.mint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.white))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.07, green: 0.67, blue: 0.35), AppTheme.mint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.65), lineWidth: 1))
        .shadow(color: AppTheme.shadow.opacity(1.35), radius: 20, x: 0, y: 10)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
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
                                colors: [AppTheme.gold.opacity(0.82), Color(red: 0.07, green: 0.67, blue: 0.35)],
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
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
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

struct LiveRoundView: View {
    let selectedCourse: GolfCourse
    let selectedTee: TeeBox
    @Binding var currentHoleIndex: Int
    @Binding var entries: [RoundHoleEntry]
    let handicap: Double
    let finishRound: () -> Void
    let discardRound: () -> Void
    @State private var scoringStep: LiveScoringStep = .score
    @State private var showIncompleteScoreAlert = false
    @State private var showDiscardRoundAlert = false

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

            Spacer(minLength: 0)

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
                        if currentHoleIndex == entries.count - 1 {
                            if entries.contains(where: { $0.score == 0 }) {
                                showIncompleteScoreAlert = true
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
        }
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
        .preferredColorScheme(.light)
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
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text(snapshot.roundCount == 0 ? "Finish a round to unlock personalised patterns." : "\(snapshot.roundCount) round baseline - \(snapshot.holeCount) holes tracked")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(AppTheme.softText)
            }

            PremiumInsightRangePicker(selection: $selectedRange)

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

            VStack(alignment: .leading, spacing: 12) {
                Text("Hole Scoring Stats")
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    HoleAverageCard(title: "Par 3s", value: formatOptionalAverage(snapshot.par3Average), target: "\(snapshot.par3Count) holes", tint: Color(red: 0.11, green: 0.42, blue: 0.74))
                    HoleAverageCard(title: "Par 4s", value: formatOptionalAverage(snapshot.par4Average), target: "\(snapshot.par4Count) holes", tint: AppTheme.mint)
                    HoleAverageCard(title: "Par 5s", value: formatOptionalAverage(snapshot.par5Average), target: "\(snapshot.par5Count) holes", tint: AppTheme.gold)
                }
            }
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
                        .foregroundStyle(selection == range ? .white : AppTheme.softText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            Capsule()
                                .fill(selection == range ? Color(red: 0.07, green: 0.67, blue: 0.35) : Color.clear)
                                .shadow(color: selection == range ? AppTheme.shadow.opacity(1.6) : .clear, radius: 12, x: 0, y: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke(AppTheme.border.opacity(0.65)))
        .shadow(color: AppTheme.shadow.opacity(0.95), radius: 16, x: 0, y: 8)
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
                        .fill(selection == index ? Color(red: 0.07, green: 0.67, blue: 0.35) : AppTheme.softText.opacity(0.28))
                        .frame(width: selection == index ? 22 : 8, height: 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.white.opacity(0.94)))
        .overlay(Capsule().stroke(AppTheme.border.opacity(0.55)))
        .shadow(color: AppTheme.shadow.opacity(0.65), radius: 10, x: 0, y: 5)
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
                        colors: [Color.white, AppTheme.subtleFill.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.75)))
        .shadow(color: AppTheme.shadow.opacity(1.6), radius: 18, x: 0, y: 10)
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
                                    .fill(Color(red: 0.07, green: 0.67, blue: 0.35))
                            )
                        HStack(spacing: 14) {
                            PremiumDirectionPill(title: "LEFT", value: "\(snapshot.fairwayMissLeftPercent)%", color: .red)
                            PremiumDirectionPill(title: "CENTER", value: "\(snapshot.fairwayPercent)%", color: Color(red: 0.07, green: 0.67, blue: 0.35))
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
                        PremiumChartSegment(value: Double(snapshot.twoPutts), color: Color(red: 0.07, green: 0.67, blue: 0.35), label: "2 PUTTS"),
                        PremiumChartSegment(value: Double(snapshot.threePutts), color: .red, label: "3 PUTTS")
                    ],
                    centerTitle: puttsPerRound,
                    centerSubtitle: "Putts / round"
                )
                .frame(width: 190, height: 190)

                PremiumLegend(segments: [
                    PremiumChartSegment(value: Double(snapshot.onePutts), color: Color(red: 0.54, green: 0.78, blue: 0.54), label: "1 PUTT"),
                    PremiumChartSegment(value: Double(snapshot.twoPutts), color: Color(red: 0.07, green: 0.67, blue: 0.35), label: "2 PUTTS"),
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
                        PremiumHorizontalBar(label: proximity.rawValue.replacingOccurrences(of: " ft", with: ""), value: proximityPercent(proximity), color: Color(red: 0.07, green: 0.67, blue: 0.35))
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
                        PremiumChartSegment(value: Double(snapshot.scrambles), color: Color(red: 0.07, green: 0.67, blue: 0.35), label: "SAVED"),
                        PremiumChartSegment(value: Double(max(snapshot.scrambleOpportunities - snapshot.scrambles, 0)), color: Color(red: 0.54, green: 0.78, blue: 0.54), label: "MISSED")
                    ],
                    centerTitle: "\(snapshot.scramblePercent)%",
                    centerSubtitle: "Scramble"
                )
                .frame(width: 190, height: 190)

                PremiumLegend(segments: [
                    PremiumChartSegment(value: Double(snapshot.scrambles), color: Color(red: 0.07, green: 0.67, blue: 0.35), label: "SAVED"),
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
                    PremiumHorizontalBar(label: "Scramble", value: snapshot.scramblePercent, color: Color(red: 0.07, green: 0.67, blue: 0.35))
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
                Spacer()
                Text("\(count) - \(percent)%")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(AppTheme.ink)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.subtleFill)
                    Capsule()
                        .fill(color)
                        .frame(width: max(8, proxy.size.width * CGFloat(percent) / 100))
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
                    LinearGradient(colors: [.red, AppTheme.gold, Color(red: 0.07, green: 0.67, blue: 0.35)], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 20)
                        .clipShape(Capsule())
                        .offset(y: 24)
                    Rectangle()
                        .fill(AppTheme.ink.opacity(0.78))
                        .frame(width: 4, height: 18)
                        .offset(x: proxy.size.width * 0.5, y: 25)
                    Text(targetLabel)
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.ink.opacity(0.78))
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
        percent >= 50 ? Color(red: 0.07, green: 0.67, blue: 0.35) : AppTheme.gold
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.7)))
        .shadow(color: AppTheme.shadow.opacity(0.72), radius: 10, x: 0, y: 5)
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

struct SettingsView: View {
    @ObservedObject var playerSettings: PlayerSettings
    let savedRounds: [SavedRound]
    @ObservedObject var roundArchive: RoundArchive
    @ObservedObject var courseFavorites: CourseFavorites
    @ObservedObject var goalArchive: GoalArchive
    @ObservedObject var clubYardages: ClubYardageStore
    @ObservedObject var handicapHistory: HandicapHistoryStore
    @ObservedObject var scorecardStore: CourseScorecardStore
    @Binding var profileName: String
    @Binding var profileHomeClub: String
    @State private var handicapText = ""
    @State private var backupDocument: PrecisionBackupDocument?
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var pendingBackup: PrecisionBackup?
    @State private var showRestoreConfirmation = false
    @State private var restoreMessage: String?
    @State private var scorecardPendingDelete: CourseScorecardOverride?
    @State private var showAllCachedScorecards = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Settings", subtitle: "Set your handicap index for course-adjusted Stableford tracking.")

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

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Handicap History", actionTitle: handicapHistory.records.isEmpty ? nil : "\(handicapHistory.records.count) records")
                    if handicapHistory.records.isEmpty {
                        Text("Record a handicap change to start tracking movement over time.")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(AppTheme.softText)
                    } else {
                        TrendLineChart(points: handicapHistory.records.reversed().map { TrendPoint(label: Self.shortDateFormatter.string(from: $0.date), value: $0.handicap) }, accent: AppTheme.gold)
                            .frame(height: 92)
                        ForEach(handicapHistory.records.prefix(4)) { record in
                            HStack {
                                Text(Self.longDateFormatter.string(from: record.date))
                                    .font(.system(.caption, design: .rounded).weight(.bold))
                                    .foregroundStyle(AppTheme.softText)
                                Spacer()
                                Text(String(format: "%.1f", record.handicap))
                                    .font(.system(.headline, design: .rounded).weight(.bold))
                                    .foregroundStyle(AppTheme.ink)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                SectionHeader(title: "Stableford", actionTitle: savedRounds.isEmpty ? nil : "Saved rounds")

                HStack(spacing: 10) {
                    StatTile(title: "Handicap", value: String(format: "%.1f", playerSettings.handicap), caption: "current")
                    StatTile(title: "Best", value: bestStableford, caption: "points")
                    StatTile(title: "Average", value: averageStableford, caption: "points")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent Stableford Cards")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(AppTheme.ink)

                    if savedRounds.isEmpty {
                        Text("Finish a round and Stableford points will appear here.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(AppTheme.softText)
                            .lineSpacing(3)
                    } else {
                        ForEach(savedRounds.prefix(5)) { round in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(round.courseName)
                                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text("\(round.teeName) tees - gross \(round.totalScore) - \(stablefordCaption(for: round))")
                                        .font(.system(.caption, design: .rounded).weight(.medium))
                                        .foregroundStyle(AppTheme.softText)
                                }
                                Spacer()
                                Text(stablefordPointsText(for: round))
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(AppTheme.mint)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

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

    private var bestStableford: String {
        savedRounds.compactMap(\.stablefordPoints).max().map(String.init) ?? "-"
    }

    private var averageStableford: String {
        let points = savedRounds.compactMap(\.stablefordPoints)
        guard !points.isEmpty else { return "-" }
        let average = Double(points.reduce(0, +)) / Double(points.count)
        return String(format: "%.1f", average)
    }

    private var displayedScorecards: [CourseScorecardOverride] {
        showAllCachedScorecards ? scorecardStore.overrides : Array(scorecardStore.overrides.prefix(5))
    }

    private func stablefordPointsText(for round: SavedRound) -> String {
        round.stablefordPoints.map(String.init) ?? "-"
    }

    private func stablefordCaption(for round: SavedRound) -> String {
        guard let handicap = round.handicap else {
            return "No saved handicap"
        }
        return "CH \(round.courseHandicap(using: handicap))"
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

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
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

struct GoalsView: View {
    let savedRounds: [SavedRound]
    @ObservedObject var goalArchive: GoalArchive
    @State private var customGoalTitle = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBlock(title: "Goals", subtitle: "Template goals tick off from your saved rounds. Custom goals can be completed manually.")

                GoalProgressHero(completed: completedTemplateCount + completedCustomCount, total: templateGoals.count + goalArchive.customGoals.count)

                SectionHeader(title: "Template Goals", actionTitle: "\(completedTemplateCount)/\(templateGoals.count) complete")

                VStack(spacing: 10) {
                    ForEach(templateGoals) { goal in
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

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Custom Goals", actionTitle: "\(completedCustomCount)/\(goalArchive.customGoals.count) complete")

                    HStack(spacing: 10) {
                        TextField("Add your own goal", text: $customGoalTitle)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.subtleFill))
                            .submitLabel(.done)
                            .onSubmit(addCustomGoal)

                        Button(action: addCustomGoal) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(AppTheme.mint))
                        }
                        .accessibilityLabel("Add custom goal")
                    }

                    if goalArchive.customGoals.isEmpty {
                        Text("Add goals like better pre-shot routine, practice twice a week, or play a medal without penalties.")
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
                                    delete: { goalArchive.delete(goal) }
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
    }

    private var completedTemplateCount: Int {
        templateGoals.filter { $0.isComplete(savedRounds) }.count
    }

    private var completedCustomCount: Int {
        goalArchive.customGoals.filter(\.isComplete).count
    }

    private func addCustomGoal() {
        goalArchive.add(title: customGoalTitle)
        customGoalTitle = ""
    }

    private var templateGoals: [GoalTemplate] {
        [
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
}

struct GoalProgressHero: View {
    let completed: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Progress")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .foregroundStyle(.white.opacity(0.78))
            HStack(alignment: .lastTextBaseline) {
                Text("\(completed)")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("of \(max(total, 1)) complete")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            ProgressView(value: total == 0 ? 0 : Double(completed), total: Double(max(total, 1)))
                .tint(.white)
            Text(total == 0 ? "Add a custom goal to start building your target list." : "Automatic goals update when rounds are saved. Custom goals stay in your control.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.07, green: 0.67, blue: 0.35), AppTheme.mint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.62)))
        .shadow(color: AppTheme.shadow.opacity(1.2), radius: 18, x: 0, y: 9)
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
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(subtitle)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)
            }
            Spacer()
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(AppTheme.mint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.white))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.07, green: 0.67, blue: 0.35), AppTheme.mint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.62)))
        .shadow(color: AppTheme.shadow.opacity(1.35), radius: 20, x: 0, y: 10)
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
    let complete: () -> Void
    @State private var nameText = ""
    @State private var homeClubText = ""
    @State private var handicapText = ""

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBlock(title: "Your Profile", subtitle: "Set up Precision Golf for this player.")

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

                        Text("This only personalises this phone. It will not change completed rounds or saved stats.")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(AppTheme.softText)
                            .lineSpacing(3)
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.85)))
                    .shadow(color: AppTheme.shadow.opacity(0.62), radius: 12, x: 0, y: 6)

                    Button(action: saveProfile) {
                        Label("Start Using Precision Golf", systemImage: "checkmark.circle.fill")
                            .font(.system(.headline, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.mint))
                    }
                    .buttonStyle(.plain)
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

    private func saveProfile() {
        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        profileName = trimmedName.isEmpty ? "Player" : trimmedName
        profileHomeClub = homeClubText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let handicap = Double(handicapText.replacingOccurrences(of: ",", with: ".")) {
            playerSettings.replaceHandicap(handicap)
        }
        complete()
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
                LiveRoundHeaderMetric(title: "To Par", value: scoreToParLabel, accent: scoreToParAccent)
                LiveRoundHeaderMetric(title: "Points", value: "\(stableford)", accent: .white)
                LiveRoundHeaderMetric(title: "CH", value: "\(courseHandicap)", accent: .white)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.07, green: 0.67, blue: 0.35), AppTheme.mint],
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
        scoreToPar <= 0 ? .white : Color(red: 1.0, green: 0.42, blue: 0.34)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18)))
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
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
                                .font(.system(size: 17, weight: .bold))
                            Text(tab.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(selectedTab == tab ? AppTheme.mint : AppTheme.softText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedTab == tab ? AppTheme.subtleFill : Color.clear)
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(Color.white)
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
