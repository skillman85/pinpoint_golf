import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn

@MainActor
final class FirebaseAccountService: NSObject, ObservableObject {
    @Published private(set) var user: FirebaseAuth.User?
    @Published private(set) var profile: FirebaseUserProfile?
    @Published var email = ""
    @Published var password = ""
    @Published var statusMessage: String?
    @Published var isWorking = false

    private let database = Firestore.firestore()
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var appleSignInContinuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    override init() {
        super.init()
        user = Auth.auth().currentUser
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                if let user {
                    await self?.loadProfile(for: user.uid)
                    await PushNotificationService.shared.syncCurrentToken()
                } else {
                    self?.profile = nil
                }
            }
        }
    }

    deinit {
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
    }

    func signIn() async {
        guard validateCredentials() else { return }
        isWorking = true
        statusMessage = nil
        do {
            let result = try await Auth.auth().signIn(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            user = result.user
            await loadProfile(for: result.user.uid)
            statusMessage = "Signed in"
        } catch {
            statusMessage = error.localizedDescription
        }
        isWorking = false
    }

    func createAccount() async {
        guard validateCredentials() else { return }
        isWorking = true
        statusMessage = nil
        do {
            let result = try await Auth.auth().createUser(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            user = result.user
            await loadProfile(for: result.user.uid)
            statusMessage = "Account created"
        } catch {
            statusMessage = error.localizedDescription
        }
        isWorking = false
    }

    func createAccount(displayName: String, handicap: Double, homeClub: String) async {
        guard validateCredentials() else { return }
        isWorking = true
        statusMessage = nil
        do {
            let result = try await Auth.auth().createUser(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            user = result.user
            try await saveProfile(uid: result.user.uid, displayName: displayName, handicap: handicap, homeClub: homeClub)
            statusMessage = "Account created"
        } catch {
            statusMessage = error.localizedDescription
        }
        isWorking = false
    }

    func signInWithApple() async {
        isWorking = true
        statusMessage = nil
        do {
            let nonce = Self.randomNonceString()
            let appleCredential = try await requestAppleCredential(nonce: nonce)
            guard let identityToken = appleCredential.identityToken,
                  let tokenString = String(data: identityToken, encoding: .utf8)
            else {
                throw AuthFlowError.missingAppleIdentityToken
            }

            let credential = OAuthProvider.appleCredential(
                withIDToken: tokenString,
                rawNonce: nonce,
                fullName: appleCredential.fullName
            )
            let result = try await Auth.auth().signIn(with: credential)
            user = result.user
            await ensureProfile(for: result.user, fallbackName: appleCredential.fullName?.formatted())
            statusMessage = "Signed in with Apple"
        } catch {
            statusMessage = error.localizedDescription
        }
        isWorking = false
    }

    func signInWithGoogle() async {
        isWorking = true
        statusMessage = nil
        do {
            guard let presentingViewController = Self.topViewController() else {
                throw AuthFlowError.missingPresentingViewController
            }
            guard let clientID = FirebaseAppClientID.current else {
                throw AuthFlowError.missingGoogleClientID
            }

            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
            guard let idToken = signInResult.user.idToken?.tokenString else {
                throw AuthFlowError.missingGoogleIDToken
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: signInResult.user.accessToken.tokenString
            )
            let result = try await Auth.auth().signIn(with: credential)
            user = result.user
            await ensureProfile(for: result.user, fallbackName: result.user.displayName)
            statusMessage = "Signed in with Google"
        } catch {
            statusMessage = error.localizedDescription
        }
        isWorking = false
    }

    func saveProfile(displayName: String, handicap: Double, homeClub: String) async {
        guard let uid = user?.uid else {
            statusMessage = "Sign in before saving your Firebase profile."
            return
        }
        isWorking = true
        statusMessage = nil
        do {
            try await saveProfile(uid: uid, displayName: displayName, handicap: handicap, homeClub: homeClub)
            statusMessage = "Profile synced"
        } catch {
            statusMessage = error.localizedDescription
        }
        isWorking = false
    }

    func signOut() {
        do {
            let signedInUid = user?.uid
            Task {
                if let signedInUid {
                    await PushNotificationService.shared.removeCurrentToken(from: signedInUid)
                }
            }
            try Auth.auth().signOut()
            user = nil
            profile = nil
            password = ""
            statusMessage = "Signed out"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func validateCredentials() -> Bool {
        guard email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@") else {
            statusMessage = "Enter a valid email address."
            return false
        }
        guard password.count >= 6 else {
            statusMessage = "Password must be at least 6 characters."
            return false
        }
        return true
    }

    private func ensureProfile(for user: FirebaseAuth.User, fallbackName: String?) async {
        await loadProfile(for: user.uid)
        guard profile == nil else { return }

        let trimmedName = fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (trimmedName?.isEmpty == false ? trimmedName : nil)
            ?? user.email?.components(separatedBy: "@").first
            ?? "Golfer"

        do {
            try await saveProfile(uid: user.uid, displayName: displayName, handicap: 18.0, homeClub: "")
        } catch {
            statusMessage = "Signed in, but profile setup needs finishing."
        }
    }

    private func loadProfile(for uid: String) async {
        do {
            let snapshot = try await database.collection("users").document(uid).getDocument()
            guard let data = snapshot.data() else {
                profile = nil
                return
            }
            profile = FirebaseUserProfile(
                uid: data["uid"] as? String ?? uid,
                displayName: data["displayName"] as? String ?? "",
                handicap: data["handicap"] as? Double ?? 0,
                homeClub: data["homeClub"] as? String ?? "",
                friendCode: data["friendCode"] as? String,
                photoURL: data["photoURL"] as? String,
                createdAt: data["createdAt"] as? Timestamp,
                updatedAt: data["updatedAt"] as? Timestamp
            )
        } catch {
            profile = nil
        }
    }

    private func saveProfile(uid: String, displayName: String, handicap: Double, homeClub: String) async throws {
        let document = database.collection("users").document(uid)
        let now = Timestamp(date: Date())
        let friendCode = profile?.friendCode ?? Self.makeFriendCode(from: displayName)
        var payload: [String: Any] = [
            "uid": uid,
            "displayName": displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            "handicap": handicap,
            "homeClub": homeClub.trimmingCharacters(in: .whitespacesAndNewlines),
            "friendCode": friendCode,
            "updatedAt": now
        ]

        if profile == nil {
            payload["createdAt"] = now
        }

        try await document.setData(payload, merge: true)
        try await database.collection("friendCodes").document(friendCode).setData([
            "uid": uid,
            "displayName": displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            "updatedAt": now
        ], merge: true)
        await loadProfile(for: uid)
    }

    private static func makeFriendCode(from displayName: String) -> String {
        let cleanedName = displayName
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        let prefix = String((cleanedName.isEmpty ? "GOLFER" : cleanedName).prefix(5))
        let suffix = String(Int.random(in: 1000...9999))
        return "\(prefix)-\(suffix)"
    }
}

extension FirebaseAccountService: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            Self.topViewController()?.view.window ?? ASPresentationAnchor()
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            Task { @MainActor in
                appleSignInContinuation?.resume(throwing: AuthFlowError.missingAppleIdentityToken)
                appleSignInContinuation = nil
            }
            return
        }

        Task { @MainActor in
            appleSignInContinuation?.resume(returning: credential)
            appleSignInContinuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            appleSignInContinuation?.resume(throwing: error)
            appleSignInContinuation = nil
        }
    }

    private func requestAppleCredential(nonce: String) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            appleSignInContinuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    @MainActor
    private static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let rootViewController = base ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController

        if let navigationController = rootViewController as? UINavigationController {
            return topViewController(base: navigationController.visibleViewController)
        }
        if let tabBarController = rootViewController as? UITabBarController {
            return topViewController(base: tabBarController.selectedViewController)
        }
        if let presented = rootViewController?.presentedViewController {
            return topViewController(base: presented)
        }
        return rootViewController
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            if status != errSecSuccess {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(status)")
            }

            randoms.forEach { random in
                guard remainingLength > 0 else { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}

private enum AuthFlowError: LocalizedError {
    case missingAppleIdentityToken
    case missingGoogleClientID
    case missingGoogleIDToken
    case missingPresentingViewController

    var errorDescription: String? {
        switch self {
        case .missingAppleIdentityToken:
            return "Apple did not return an identity token. Please try again."
        case .missingGoogleClientID:
            return "Google Sign-In needs an updated GoogleService-Info.plist with CLIENT_ID and the reversed client URL scheme."
        case .missingGoogleIDToken:
            return "Google did not return an identity token. Please try again."
        case .missingPresentingViewController:
            return "Could not open the Google sign-in screen. Please try again."
        }
    }
}

private enum FirebaseAppClientID {
    static var current: String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path)
        else { return nil }
        return plist["CLIENT_ID"] as? String
    }
}

struct FirebaseUserProfile: Identifiable {
    var id: String { uid }
    let uid: String
    var displayName: String
    var handicap: Double
    var homeClub: String
    var friendCode: String?
    var photoURL: String?
    var createdAt: Timestamp?
    var updatedAt: Timestamp?
}

@MainActor
final class FirebaseRoundSyncService: ObservableObject {
    @Published private(set) var cloudRoundCount = 0
    @Published private(set) var lastSyncDate: Date?
    @Published var statusMessage: String?
    @Published var isWorking = false

    private let database = Firestore.firestore()
    private let lastSyncKey = "precision.cloudRoundsLastSync"

    init() {
        lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    func refreshCloudCount() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            cloudRoundCount = 0
            statusMessage = nil
            return
        }

        do {
            let snapshot = try await roundsCollection(for: uid).getDocuments()
            cloudRoundCount = snapshot.documents.count
        } catch {
            statusMessage = "Cloud round count unavailable: \(error.localizedDescription)"
        }
    }

    func sync(rounds: [SavedRound]) async {
        guard let uid = Auth.auth().currentUser?.uid else {
            statusMessage = "Create an account to back up rounds."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            for round in rounds {
                try await upload(round, uid: uid)
            }
            markSynced(count: rounds.count)
        } catch {
            statusMessage = "Round backup failed: \(error.localizedDescription)"
        }
    }

    func sync(round: SavedRound) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        do {
            try await upload(round, uid: uid)
            markSynced(count: max(cloudRoundCount, 1))
        } catch {
            statusMessage = "Round saved locally. Cloud backup failed: \(error.localizedDescription)"
        }
    }

    func delete(roundID: UUID) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        do {
            try await roundsCollection(for: uid).document(roundID.uuidString).delete()
            cloudRoundCount = max(0, cloudRoundCount - 1)
            statusMessage = "Cloud backup updated"
        } catch {
            statusMessage = "Local round deleted. Cloud delete failed: \(error.localizedDescription)"
        }
    }

    func restoreRounds() async -> [SavedRound]? {
        guard let uid = Auth.auth().currentUser?.uid else {
            statusMessage = "Create an account before restoring cloud rounds."
            return nil
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let snapshot = try await roundsCollection(for: uid)
                .order(by: "date", descending: true)
                .getDocuments()
            let rounds = snapshot.documents.compactMap { document -> SavedRound? in
                guard let encodedRound = document.data()["roundJSON"] as? String,
                      let data = encodedRound.data(using: .utf8)
                else { return nil }
                return try? Self.decoder.decode(SavedRound.self, from: data)
            }
            cloudRoundCount = rounds.count
            statusMessage = rounds.isEmpty ? "No cloud rounds found yet." : "Restored \(rounds.count) cloud rounds."
            return rounds
        } catch {
            statusMessage = "Cloud restore failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func upload(_ round: SavedRound, uid: String) async throws {
        let data = try Self.encoder.encode(round)
        guard let roundJSON = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "PrecisionGolf.RoundSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not prepare this round for cloud backup."
            ])
        }

        var payload: [String: Any] = [
            "ownerId": uid,
            "roundId": round.id.uuidString,
            "courseName": round.courseName,
            "location": round.location,
            "teeName": round.teeName,
            "date": Timestamp(date: round.date),
            "gross": round.totalScore,
            "par": round.totalPar,
            "scoreToPar": round.totalScore - round.totalPar,
            "putts": round.totalPutts,
            "penalties": round.penalties,
            "holeCount": round.holes.count,
            "roundJSON": roundJSON,
            "updatedAt": Timestamp(date: Date())
        ]

        if let stablefordPoints = round.stablefordPoints {
            payload["stableford"] = stablefordPoints
        }

        try await roundsCollection(for: uid).document(round.id.uuidString).setData(payload, merge: true)
    }

    private func roundsCollection(for uid: String) -> CollectionReference {
        database.collection("users").document(uid).collection("roundBackups")
    }

    private func markSynced(count: Int) {
        lastSyncDate = Date()
        cloudRoundCount = count
        UserDefaults.standard.set(lastSyncDate, forKey: lastSyncKey)
        statusMessage = count == 1 ? "1 round backed up" : "\(count) rounds backed up"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

@MainActor
final class FirebaseSocialService: ObservableObject {
    @Published var friendCodeInput = ""
    @Published private(set) var friends: [FirebaseFriendProfile] = []
    @Published private(set) var incomingRequests: [FirebaseFriendRequest] = []
    @Published private(set) var groups: [FirebaseGolfGroup] = []
    @Published private(set) var groupInvites: [FirebaseGroupInvite] = []
    @Published private(set) var sharedRounds: [FirebaseSharedRound] = []
    @Published private(set) var notifications: [FirebaseRoundNotification] = []
    @Published private(set) var liveMatchplayMatches: [FirebaseMatchplayMatch] = []
    @Published var statusMessage: String?
    @Published var isWorking = false

    private let database = Firestore.firestore()
    private var matchplayListener: ListenerRegistration?

    deinit {
        matchplayListener?.remove()
    }

    func refresh() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            friends = []
            incomingRequests = []
            groups = []
            groupInvites = []
            sharedRounds = []
            notifications = []
            liveMatchplayMatches = []
            matchplayListener?.remove()
            matchplayListener = nil
            statusMessage = "Create an account to use friends."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            async let requests = loadIncomingRequests(for: uid)
            async let loadedFriends = loadFriends(for: uid)
            async let loadedGroups = loadGroups(for: uid)
            async let loadedGroupInvites = loadGroupInvites(for: uid)
            async let loadedSharedRounds = loadSharedRounds(for: uid)
            async let loadedNotifications = loadNotifications(for: uid)
            incomingRequests = try await requests
            friends = try await loadedFriends
            groups = try await loadedGroups
            groupInvites = try await loadedGroupInvites
            sharedRounds = try await loadedSharedRounds
            notifications = try await loadedNotifications
            startMatchplayListener(for: uid)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startMatchplay(with friend: FirebaseFriendProfile, course: GolfCourse, tee: TeeBox, playerProfile: FirebaseUserProfile?, courseHandicap: Int) async {
        guard let uid = Auth.auth().currentUser?.uid else {
            statusMessage = "Create an account before starting matchplay."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let documentId = matchplayDocumentId(uid, friend.uid)
            let holeCount = tee.holes.count
            let opponentCourseHandicap = calculatedCourseHandicap(for: friend.handicap, tee: tee)
            let payload: [String: Any] = [
                "memberIds": [uid, friend.uid].sorted(),
                "createdBy": uid,
                "status": "active",
                "courseName": course.name,
                "teeName": tee.name,
                "holeCount": holeCount,
                "useHandicap": true,
                "players": [
                    uid: [
                        "displayName": displayName(from: playerProfile),
                        "handicap": playerProfile?.handicap ?? 0,
                        "courseHandicap": courseHandicap
                    ],
                    friend.uid: [
                        "displayName": friend.displayName,
                        "handicap": friend.handicap,
                        "courseHandicap": opponentCourseHandicap
                    ]
                ],
                "scores": [
                    uid: Array(repeating: 0, count: holeCount),
                    friend.uid: Array(repeating: 0, count: holeCount)
                ],
                "currentHoleByUser": [
                    uid: 0,
                    friend.uid: 0
                ],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]

            try await database.collection("matchplayMatches").document(documentId).setData(payload, merge: true)
            statusMessage = "Matchplay started with \(friend.displayName)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func syncMatchplayScore(_ match: FirebaseMatchplayMatch, holeIndex: Int, score: Int) async {
        guard let uid = Auth.auth().currentUser?.uid, match.memberIds.contains(uid) else { return }
        guard holeIndex >= 0, holeIndex < match.holeCount else { return }

        var userScores = match.scores[uid] ?? Array(repeating: 0, count: match.holeCount)
        if userScores.count < match.holeCount {
            userScores += Array(repeating: 0, count: match.holeCount - userScores.count)
        }
        userScores[holeIndex] = max(0, min(20, score))

        do {
            try await database.collection("matchplayMatches").document(match.id).updateData([
                "scores.\(uid)": userScores,
                "currentHoleByUser.\(uid)": holeIndex,
                "updatedAt": Timestamp(date: Date())
            ])
        } catch {
            statusMessage = "Matchplay sync failed: \(error.localizedDescription)"
        }
    }

    func cancelMatchplay(_ match: FirebaseMatchplayMatch) async {
        guard let uid = Auth.auth().currentUser?.uid, match.memberIds.contains(uid) else { return }

        do {
            try await database.collection("matchplayMatches").document(match.id).setData([
                "status": "cancelled",
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func publishCompletedRound(_ round: SavedRound, ownerProfile: FirebaseUserProfile?) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        do {
            let ownerName = displayName(from: ownerProfile)
            let documentId = round.id.uuidString
            var payload: [String: Any] = [
                "ownerId": uid,
                "ownerName": ownerName,
                "ownerHandicap": ownerProfile?.handicap ?? round.handicap ?? 0,
                "ownerHomeClub": ownerProfile?.homeClub ?? "",
                "ownerPhotoURL": ownerProfile?.photoURL ?? "",
                "courseName": round.courseName,
                "location": round.location,
                "teeName": round.teeName,
                "date": Timestamp(date: round.date),
                "gross": round.totalScore,
                "par": round.totalPar,
                "scoreToPar": round.totalScore - round.totalPar,
                "birdies": round.birdies,
                "pars": round.pars,
                "putts": round.totalPutts,
                "penalties": round.penalties,
                "visibility": "friends",
                "createdAt": Timestamp(date: Date())
            ]
            if let stablefordPoints = round.stablefordPoints {
                payload["stableford"] = stablefordPoints
            }
            let scoringHandicap = ownerProfile?.handicap ?? round.handicap
            let scoringCourseHandicap = scoringHandicap.map { round.courseHandicap(using: $0) }
            if let scoringCourseHandicap {
                payload["courseHandicap"] = scoringCourseHandicap
            }
            payload["holes"] = round.holes.map { hole -> [String: Any] in
                var holePayload: [String: Any] = [
                    "holeNumber": hole.holeNumber,
                    "par": hole.par,
                    "yards": hole.yards,
                    "strokeIndex": hole.strokeIndex,
                    "score": hole.score,
                    "putts": hole.putts,
                    "pickedUp": hole.pickedUp,
                    "fairway": hole.fairway.rawValue,
                    "green": hole.green.rawValue,
                    "penalties": hole.penalties
                ]
                if let scoringCourseHandicap {
                    holePayload["stablefordPoints"] = hole.stablefordPoints(using: Double(scoringCourseHandicap))
                }
                if let bunker = hole.bunker {
                    holePayload["bunker"] = bunker
                }
                if let upAndDown = hole.upAndDown {
                    holePayload["upAndDown"] = upAndDown
                }
                if let sandSave = hole.sandSave {
                    holePayload["sandSave"] = sandSave
                }
                if let recovery = hole.recovery {
                    holePayload["recovery"] = recovery
                }
                return holePayload
            }

            try await database.collection("sharedRounds").document(documentId).setData(payload, merge: true)

            let loadedFriends = try await loadFriends(for: uid)
            for friend in loadedFriends {
                let notificationId = "\(documentId)_\(friend.uid)"
                var notificationPayload: [String: Any] = [
                    "recipientId": friend.uid,
                    "actorId": uid,
                    "actorName": ownerName,
                    "sharedRoundId": documentId,
                    "courseName": round.courseName,
                    "gross": round.totalScore,
                    "message": "\(ownerName) completed a round at \(round.courseName)",
                    "read": false,
                    "roundDate": Timestamp(date: round.date),
                    "createdAt": Timestamp(date: Date())
                ]
                if let stablefordPoints = round.stablefordPoints {
                    notificationPayload["stableford"] = stablefordPoints
                }
                try await database.collection("roundNotifications").document(notificationId).setData(notificationPayload, merge: true)
            }

            await refresh()
        } catch {
            statusMessage = "Round saved locally, but friend sharing failed: \(error.localizedDescription)"
        }
    }

    func sendFriendRequest() async {
        guard let fromUid = Auth.auth().currentUser?.uid else {
            statusMessage = "Create an account before adding friends."
            return
        }

        let code = normalizeFriendCode(friendCodeInput)
        guard !code.isEmpty else {
            statusMessage = "Enter a friend code."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let codeSnapshot = try await database.collection("friendCodes").document(code).getDocument()
            guard let toUid = codeSnapshot.data()?["uid"] as? String else {
                statusMessage = "No player found for that code."
                return
            }
            guard toUid != fromUid else {
                statusMessage = "That is your own friend code."
                return
            }

            guard !friends.contains(where: { $0.uid == toUid }) else {
                statusMessage = "You are already friends."
                return
            }

            let requestId = requestDocumentId(fromUid: fromUid, toUid: toUid)
            try await database.collection("friendRequests").document(requestId).setData([
                "fromUserId": fromUid,
                "toUserId": toUid,
                "status": "pending",
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            friendCodeInput = ""
            statusMessage = "Friend request sent"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func accept(_ request: FirebaseFriendRequest) async {
        guard let uid = Auth.auth().currentUser?.uid, request.toUserId == uid else {
            statusMessage = "This request is not for the signed-in user."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let friendshipId = friendshipDocumentId(request.fromUserId, request.toUserId)
            try await database.collection("friendships").document(friendshipId).setData([
                "memberIds": [request.fromUserId, request.toUserId].sorted(),
                "createdAt": Timestamp(date: Date())
            ], merge: true)
            try await database.collection("friendRequests").document(request.id).setData([
                "status": "accepted",
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            statusMessage = "Friend added"
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func decline(_ request: FirebaseFriendRequest) async {
        isWorking = true
        defer { isWorking = false }

        do {
            try await database.collection("friendRequests").document(request.id).setData([
                "status": "declined",
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            statusMessage = "Request declined"
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createGroup(name: String) async {
        guard let uid = Auth.auth().currentUser?.uid else {
            statusMessage = "Create an account before making a group."
            return
        }

        let groupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupName.isEmpty else {
            statusMessage = "Enter a group name."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let document = database.collection("golfGroups").document()
            try await document.setData([
                "name": groupName,
                "ownerId": uid,
                "memberIds": [uid],
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ])
            statusMessage = "Group created"
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func invite(_ friend: FirebaseFriendProfile, to group: FirebaseGolfGroup) async {
        guard let uid = Auth.auth().currentUser?.uid, group.memberIds.contains(uid) else {
            statusMessage = "You need to be in this group before inviting friends."
            return
        }
        guard !group.memberIds.contains(friend.uid) else {
            statusMessage = "\(friend.displayName) is already in this group."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let inviteId = "\(group.id)_\(friend.uid)"
            try await database.collection("groupInvites").document(inviteId).setData([
                "groupId": group.id,
                "groupName": group.name,
                "fromUserId": uid,
                "toUserId": friend.uid,
                "status": "pending",
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            statusMessage = "Group invite sent"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func accept(_ invite: FirebaseGroupInvite) async {
        guard let uid = Auth.auth().currentUser?.uid, invite.toUserId == uid else {
            statusMessage = "This group invite is not for the signed-in user."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            try await database.collection("golfGroups").document(invite.groupId).setData([
                "memberIds": FieldValue.arrayUnion([uid]),
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            try await database.collection("groupInvites").document(invite.id).setData([
                "status": "accepted",
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            statusMessage = "Joined \(invite.groupName)"
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func decline(_ invite: FirebaseGroupInvite) async {
        isWorking = true
        defer { isWorking = false }

        do {
            try await database.collection("groupInvites").document(invite.id).setData([
                "status": "declined",
                "updatedAt": Timestamp(date: Date())
            ], merge: true)
            statusMessage = "Group invite declined"
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadIncomingRequests(for uid: String) async throws -> [FirebaseFriendRequest] {
        let snapshot = try await database.collection("friendRequests")
            .whereField("toUserId", isEqualTo: uid)
            .whereField("status", isEqualTo: "pending")
            .getDocuments()

        var requests: [FirebaseFriendRequest] = []
        for document in snapshot.documents {
            let data = document.data()
            guard
                let fromUserId = data["fromUserId"] as? String,
                let toUserId = data["toUserId"] as? String,
                let status = data["status"] as? String
            else { continue }

            let fromProfile = try await loadProfile(uid: fromUserId)
            requests.append(FirebaseFriendRequest(
                id: document.documentID,
                fromUserId: fromUserId,
                toUserId: toUserId,
                status: status,
                fromProfile: fromProfile
            ))
        }
        return requests.sorted { $0.fromProfile.displayName < $1.fromProfile.displayName }
    }

    private func loadFriends(for uid: String) async throws -> [FirebaseFriendProfile] {
        let snapshot = try await database.collection("friendships")
            .whereField("memberIds", arrayContains: uid)
            .getDocuments()

        var profiles: [FirebaseFriendProfile] = []
        for document in snapshot.documents {
            let memberIds = document.data()["memberIds"] as? [String] ?? []
            guard let otherUid = memberIds.first(where: { $0 != uid }) else { continue }
            profiles.append(try await loadProfile(uid: otherUid))
        }
        return profiles.sorted { $0.displayName < $1.displayName }
    }

    private func loadGroups(for uid: String) async throws -> [FirebaseGolfGroup] {
        let snapshot = try await database.collection("golfGroups")
            .whereField("memberIds", arrayContains: uid)
            .getDocuments()

        return snapshot.documents
            .compactMap(FirebaseGolfGroup.init(document:))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadGroupInvites(for uid: String) async throws -> [FirebaseGroupInvite] {
        let snapshot = try await database.collection("groupInvites")
            .whereField("toUserId", isEqualTo: uid)
            .whereField("status", isEqualTo: "pending")
            .getDocuments()

        var invites: [FirebaseGroupInvite] = []
        for document in snapshot.documents {
            guard let invite = FirebaseGroupInvite(document: document) else { continue }
            let fromProfile = try await loadProfile(uid: invite.fromUserId)
            var enrichedInvite = invite
            enrichedInvite.fromProfile = fromProfile
            invites.append(enrichedInvite)
        }

        return invites.sorted { $0.createdAt > $1.createdAt }
    }

    private func loadSharedRounds(for uid: String) async throws -> [FirebaseSharedRound] {
        let friendIds = try await loadFriends(for: uid).map(\.uid)
        var rounds: [FirebaseSharedRound] = []

        for ownerId in friendIds {
            let snapshot = try await database.collection("sharedRounds")
                .whereField("ownerId", isEqualTo: ownerId)
                .limit(to: 20)
                .getDocuments()
            rounds.append(contentsOf: snapshot.documents.compactMap(FirebaseSharedRound.init(document:)))
        }

        return Array(rounds.sorted { $0.date > $1.date }.prefix(30))
    }

    func loadSharedRound(id: String) async -> FirebaseSharedRound? {
        if let existingRound = sharedRounds.first(where: { $0.id == id }) {
            return existingRound
        }

        do {
            let document = try await database.collection("sharedRounds").document(id).getDocument()
            guard let data = document.data() else { return nil }
            return FirebaseSharedRound(id: document.documentID, data: data)
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    private func loadNotifications(for uid: String) async throws -> [FirebaseRoundNotification] {
        let snapshot = try await database.collection("roundNotifications")
            .whereField("recipientId", isEqualTo: uid)
            .whereField("read", isEqualTo: false)
            .limit(to: 20)
            .getDocuments()

        return snapshot.documents
            .compactMap(FirebaseRoundNotification.init(document:))
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func loadProfile(uid: String) async throws -> FirebaseFriendProfile {
        let snapshot = try await database.collection("users").document(uid).getDocument()
        let data = snapshot.data() ?? [:]
        return FirebaseFriendProfile(
            uid: uid,
            displayName: data["displayName"] as? String ?? "Golfer",
            handicap: data["handicap"] as? Double ?? 0,
            homeClub: data["homeClub"] as? String ?? "",
            friendCode: data["friendCode"] as? String ?? "",
            photoURL: data["photoURL"] as? String
        )
    }

    private func normalizeFriendCode(_ code: String) -> String {
        let cleaned = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count > 4 else { return cleaned }
        let splitIndex = cleaned.index(cleaned.endIndex, offsetBy: -4)
        return "\(cleaned[..<splitIndex])-\(cleaned[splitIndex...])"
    }

    private func requestDocumentId(fromUid: String, toUid: String) -> String {
        "\(fromUid)_\(toUid)"
    }

    private func friendshipDocumentId(_ firstUid: String, _ secondUid: String) -> String {
        [firstUid, secondUid].sorted().joined(separator: "_")
    }

    private func matchplayDocumentId(_ firstUid: String, _ secondUid: String) -> String {
        [firstUid, secondUid].sorted().joined(separator: "_") + "_active"
    }

    private func startMatchplayListener(for uid: String) {
        matchplayListener?.remove()
        matchplayListener = database.collection("matchplayMatches")
            .whereField("memberIds", arrayContains: uid)
            .whereField("status", isEqualTo: "active")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.statusMessage = "Matchplay unavailable: \(error.localizedDescription)"
                        return
                    }

                    self?.liveMatchplayMatches = snapshot?.documents
                        .compactMap(FirebaseMatchplayMatch.init(document:))
                        .sorted { $0.updatedAt > $1.updatedAt } ?? []
                }
            }
    }

    private func calculatedCourseHandicap(for handicap: Double, tee: TeeBox) -> Int {
        let adjusted = (handicap * Double(tee.slope) / 113.0) + (tee.rating - Double(tee.par))
        return max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
    }

    private func displayName(from profile: FirebaseUserProfile?) -> String {
        guard let profile, !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "A friend"
        }
        return profile.displayName
    }
}

struct FirebaseFriendProfile: Identifiable {
    var id: String { uid }
    let uid: String
    var displayName: String
    var handicap: Double
    var homeClub: String
    var friendCode: String
    var photoURL: String?
}

struct FirebaseFriendRequest: Identifiable {
    let id: String
    var fromUserId: String
    var toUserId: String
    var status: String
    var fromProfile: FirebaseFriendProfile
}

struct FirebaseGolfGroup: Identifiable {
    let id: String
    var name: String
    var ownerId: String
    var memberIds: [String]
    var createdAt: Date
    var updatedAt: Date

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let name = data["name"] as? String,
            let ownerId = data["ownerId"] as? String,
            let memberIds = data["memberIds"] as? [String]
        else { return nil }

        self.id = document.documentID
        self.name = name
        self.ownerId = ownerId
        self.memberIds = memberIds
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt
    }
}

struct FirebaseGroupInvite: Identifiable {
    let id: String
    var groupId: String
    var groupName: String
    var fromUserId: String
    var toUserId: String
    var status: String
    var createdAt: Date
    var fromProfile: FirebaseFriendProfile?

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let groupId = data["groupId"] as? String,
            let groupName = data["groupName"] as? String,
            let fromUserId = data["fromUserId"] as? String,
            let toUserId = data["toUserId"] as? String,
            let status = data["status"] as? String
        else { return nil }

        self.id = document.documentID
        self.groupId = groupId
        self.groupName = groupName
        self.fromUserId = fromUserId
        self.toUserId = toUserId
        self.status = status
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.fromProfile = nil
    }
}

struct FirebaseMatchplayPlayer {
    var displayName: String
    var handicap: Double
    var courseHandicap: Int

    init(data: [String: Any]) {
        displayName = data["displayName"] as? String ?? "Golfer"
        handicap = data["handicap"] as? Double ?? 0
        courseHandicap = data["courseHandicap"] as? Int ?? 0
    }
}

struct FirebaseMatchplayMatch: Identifiable {
    let id: String
    var memberIds: [String]
    var createdBy: String
    var status: String
    var courseName: String
    var teeName: String
    var holeCount: Int
    var useHandicap: Bool
    var players: [String: FirebaseMatchplayPlayer]
    var scores: [String: [Int]]
    var currentHoleByUser: [String: Int]
    var updatedAt: Date

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let memberIds = data["memberIds"] as? [String],
            let createdBy = data["createdBy"] as? String,
            let status = data["status"] as? String,
            let courseName = data["courseName"] as? String,
            let teeName = data["teeName"] as? String,
            let holeCount = data["holeCount"] as? Int
        else { return nil }

        let playerPayload = data["players"] as? [String: [String: Any]] ?? [:]
        let scorePayload = data["scores"] as? [String: [Int]] ?? [:]
        let holePayload = data["currentHoleByUser"] as? [String: Int] ?? [:]

        self.id = document.documentID
        self.memberIds = memberIds
        self.createdBy = createdBy
        self.status = status
        self.courseName = courseName
        self.teeName = teeName
        self.holeCount = holeCount
        self.useHandicap = data["useHandicap"] as? Bool ?? true
        self.players = playerPayload.mapValues(FirebaseMatchplayPlayer.init(data:))
        self.scores = scorePayload
        self.currentHoleByUser = holePayload
        self.updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
    }

    func opponentId(for uid: String) -> String? {
        memberIds.first { $0 != uid }
    }

    func score(for uid: String, holeIndex: Int) -> Int {
        guard holeIndex >= 0 else { return 0 }
        let values = scores[uid] ?? []
        guard holeIndex < values.count else { return 0 }
        return values[holeIndex]
    }

    func strokes(for uid: String, hole: Hole) -> Int {
        guard useHandicap else { return 0 }
        let handicap = players[uid]?.courseHandicap ?? 0
        return handicap / 18 + (hole.strokeIndex <= handicap % 18 ? 1 : 0)
    }
}

struct FirebaseSharedRound: Identifiable {
    let id: String
    var ownerId: String
    var ownerName: String
    var ownerHandicap: Double
    var courseHandicap: Int?
    var ownerHomeClub: String
    var ownerPhotoURL: String?
    var courseName: String
    var location: String
    var teeName: String
    var date: Date
    var gross: Int
    var par: Int
    var scoreToPar: Int
    var stableford: Int?
    var birdies: Int
    var pars: Int
    var putts: Int
    var penalties: Int
    var holes: [FirebaseSharedHoleEntry]

    init?(document: QueryDocumentSnapshot) {
        self.init(id: document.documentID, data: document.data())
    }

    init?(id: String, data: [String: Any]) {
        guard
            let ownerId = data["ownerId"] as? String,
            let ownerName = data["ownerName"] as? String,
            let courseName = data["courseName"] as? String,
            let teeName = data["teeName"] as? String,
            let timestamp = data["date"] as? Timestamp,
            let gross = data["gross"] as? Int,
            let par = data["par"] as? Int
        else { return nil }

        self.id = id
        self.ownerId = ownerId
        self.ownerName = ownerName
        self.ownerHandicap = data["ownerHandicap"] as? Double ?? 0
        self.courseHandicap = data["courseHandicap"] as? Int
        self.ownerHomeClub = data["ownerHomeClub"] as? String ?? ""
        self.ownerPhotoURL = data["ownerPhotoURL"] as? String
        self.courseName = courseName
        self.location = data["location"] as? String ?? ""
        self.teeName = teeName
        self.date = timestamp.dateValue()
        self.gross = gross
        self.par = par
        self.scoreToPar = data["scoreToPar"] as? Int ?? gross - par
        self.stableford = data["stableford"] as? Int
        self.birdies = data["birdies"] as? Int ?? 0
        self.pars = data["pars"] as? Int ?? 0
        self.putts = data["putts"] as? Int ?? 0
        self.penalties = data["penalties"] as? Int ?? 0
        self.holes = (data["holes"] as? [[String: Any]] ?? [])
            .compactMap(FirebaseSharedHoleEntry.init(data:))
            .sorted { $0.holeNumber < $1.holeNumber }
    }

    var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }
}

struct FirebaseSharedHoleEntry: Identifiable {
    var id: Int { holeNumber }
    var holeNumber: Int
    var par: Int
    var yards: Int
    var strokeIndex: Int
    var score: Int
    var putts: Int
    var pickedUp: Bool
    var fairway: MissDirection
    var green: MissDirection
    var penalties: Int
    var stablefordPoints: Int?
    var bunker: Bool?
    var upAndDown: Bool?
    var sandSave: Bool?
    var recovery: Bool?

    init?(data: [String: Any]) {
        guard
            let holeNumber = data["holeNumber"] as? Int,
            let par = data["par"] as? Int,
            let yards = data["yards"] as? Int,
            let strokeIndex = data["strokeIndex"] as? Int,
            let score = data["score"] as? Int,
            let putts = data["putts"] as? Int
        else { return nil }

        self.holeNumber = holeNumber
        self.par = par
        self.yards = yards
        self.strokeIndex = strokeIndex
        self.score = score
        self.putts = putts
        self.pickedUp = data["pickedUp"] as? Bool ?? false
        self.fairway = MissDirection(rawValue: data["fairway"] as? String ?? "") ?? .notTracked
        self.green = MissDirection(rawValue: data["green"] as? String ?? "") ?? .notTracked
        self.penalties = data["penalties"] as? Int ?? 0
        self.stablefordPoints = data["stablefordPoints"] as? Int
        self.bunker = data["bunker"] as? Bool
        self.upAndDown = data["upAndDown"] as? Bool
        self.sandSave = data["sandSave"] as? Bool
        self.recovery = data["recovery"] as? Bool
    }

    var scoreToPar: Int { score - par }
    var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }
}

struct FirebaseRoundNotification: Identifiable {
    let id: String
    var recipientId: String
    var actorId: String
    var actorName: String
    var sharedRoundId: String
    var courseName: String
    var gross: Int
    var stableford: Int?
    var message: String
    var roundDate: Date
    var createdAt: Date

    init?(document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let recipientId = data["recipientId"] as? String,
            let actorId = data["actorId"] as? String,
            let actorName = data["actorName"] as? String,
            let sharedRoundId = data["sharedRoundId"] as? String,
            let courseName = data["courseName"] as? String,
            let gross = data["gross"] as? Int,
            let message = data["message"] as? String,
            let timestamp = data["createdAt"] as? Timestamp
        else { return nil }

        self.id = document.documentID
        self.recipientId = recipientId
        self.actorId = actorId
        self.actorName = actorName
        self.sharedRoundId = sharedRoundId
        self.courseName = courseName
        self.gross = gross
        self.stableford = data["stableford"] as? Int
        self.message = message
        self.roundDate = (data["roundDate"] as? Timestamp)?.dateValue() ?? timestamp.dateValue()
        self.createdAt = timestamp.dateValue()
    }
}
