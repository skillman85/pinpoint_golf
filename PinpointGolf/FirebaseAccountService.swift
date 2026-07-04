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
            incomingRequests = try await requests
            friends = try await loadedFriends
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
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

            let friendshipId = friendshipDocumentId(fromUid, toUid)
            let friendshipSnapshot = try await database.collection("friendships").document(friendshipId).getDocument()
            guard !friendshipSnapshot.exists else {
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
