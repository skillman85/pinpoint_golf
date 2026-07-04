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
        var payload: [String: Any] = [
            "uid": uid,
            "displayName": displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            "handicap": handicap,
            "homeClub": homeClub.trimmingCharacters(in: .whitespacesAndNewlines),
            "updatedAt": now
        ]

        if profile == nil {
            payload["createdAt"] = now
        }

        try await document.setData(payload, merge: true)
        await loadProfile(for: uid)
    }
}

struct FirebaseUserProfile: Identifiable {
    var id: String { uid }
    let uid: String
    var displayName: String
    var handicap: Double
    var homeClub: String
    var photoURL: String?
    var createdAt: Timestamp?
    var updatedAt: Timestamp?
}
