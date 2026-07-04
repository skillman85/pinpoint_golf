import Foundation
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class FirebaseAccountService: ObservableObject {
    @Published private(set) var user: FirebaseAuth.User?
    @Published private(set) var profile: FirebaseUserProfile?
    @Published var email = ""
    @Published var password = ""
    @Published var statusMessage: String?
    @Published var isWorking = false

    private let database = Firestore.firestore()
    private var authHandle: AuthStateDidChangeListenerHandle?

    init() {
        user = Auth.auth().currentUser
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                if let user {
                    await self?.loadProfile(for: user.uid)
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
final class FirebaseSocialService: ObservableObject {
    @Published var friendCodeInput = ""
    @Published private(set) var friends: [FirebaseFriendProfile] = []
    @Published private(set) var incomingRequests: [FirebaseFriendRequest] = []
    @Published private(set) var sharedRounds: [FirebaseSharedRound] = []
    @Published private(set) var notifications: [FirebaseRoundNotification] = []
    @Published var statusMessage: String?
    @Published var isWorking = false

    private let database = Firestore.firestore()

    func refresh() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            friends = []
            incomingRequests = []
            statusMessage = "Create an account to use friends."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            async let requests = loadIncomingRequests(for: uid)
            async let loadedFriends = loadFriends(for: uid)
            async let loadedSharedRounds = loadSharedRounds(for: uid)
            async let loadedNotifications = loadNotifications(for: uid)
            incomingRequests = try await requests
            friends = try await loadedFriends
            sharedRounds = try await loadedSharedRounds
            notifications = try await loadedNotifications
            statusMessage = nil
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
            friendCode: data["friendCode"] as? String ?? ""
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
}

struct FirebaseFriendRequest: Identifiable {
    let id: String
    var fromUserId: String
    var toUserId: String
    var status: String
    var fromProfile: FirebaseFriendProfile
}

struct FirebaseSharedRound: Identifiable {
    let id: String
    var ownerId: String
    var ownerName: String
    var ownerHandicap: Double
    var ownerHomeClub: String
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
        let data = document.data()
        guard
            let ownerId = data["ownerId"] as? String,
            let ownerName = data["ownerName"] as? String,
            let courseName = data["courseName"] as? String,
            let teeName = data["teeName"] as? String,
            let timestamp = data["date"] as? Timestamp,
            let gross = data["gross"] as? Int,
            let par = data["par"] as? Int
        else { return nil }

        self.id = document.documentID
        self.ownerId = ownerId
        self.ownerName = ownerName
        self.ownerHandicap = data["ownerHandicap"] as? Double ?? 0
        self.ownerHomeClub = data["ownerHomeClub"] as? String ?? ""
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
        self.createdAt = timestamp.dateValue()
    }
}
