import Foundation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import GoogleSignIn
import UIKit
import UserNotifications
import FirebaseCore

extension Notification.Name {
    static let precisionOpenSharedRound = Notification.Name("precisionOpenSharedRound")
    static let precisionOpenFriends = Notification.Name("precisionOpenFriends")
}

@MainActor
final class PushNotificationService: NSObject, ObservableObject {
    static let shared = PushNotificationService()

    private enum NotificationAction {
        static let acceptFriendRequest = "FRIEND_REQUEST_ACCEPT"
        static let declineFriendRequest = "FRIEND_REQUEST_DECLINE"
        static let joinGroup = "GROUP_INVITE_JOIN"
        static let declineGroupInvite = "GROUP_INVITE_DECLINE"
    }

    private enum NotificationCategory {
        static let friendRequest = "FRIEND_REQUEST"
        static let groupInvite = "GROUP_INVITE"
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastTokenSyncMessage: String?

    private let database = Firestore.firestore()
    private var currentToken: String?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        Messaging.messaging().delegate = self
        Task {
            await refreshAuthorizationStatus()
            if authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            await syncCurrentToken()
        }
    }

    func requestPermissionAndRegister() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
            await syncCurrentToken()
        } catch {
            lastTokenSyncMessage = error.localizedDescription
        }
    }

    func syncCurrentToken() async {
        do {
            let token = try await Messaging.messaging().token()
            currentToken = token
            try await saveToken(token)
            lastTokenSyncMessage = "Notifications ready"
        } catch {
            lastTokenSyncMessage = error.localizedDescription
        }
    }

    func removeTokenFromCurrentUser() async {
        guard let uid = Auth.auth().currentUser?.uid, let currentToken else { return }
        await removeToken(currentToken, from: uid)
    }

    func removeCurrentToken(from uid: String) async {
        guard let currentToken else { return }
        await removeToken(currentToken, from: uid)
    }

    func recordRegistrationError(_ error: Error) {
        lastTokenSyncMessage = error.localizedDescription
    }

    private func removeToken(_ token: String, from uid: String) async {
        do {
            let userReference = database.collection("users").document(uid)
            try await userReference.collection("pushDevices").document(deviceDocumentId(for: token)).delete()
            try await userReference.setData([
                "pushTokens": FieldValue.arrayRemove([token]),
                "pushTokenUpdatedAt": Timestamp(date: Date())
            ], merge: true)
        } catch {
            lastTokenSyncMessage = error.localizedDescription
        }
    }

    private func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    private func saveToken(_ token: String) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let userReference = database.collection("users").document(uid)
        try await userReference.collection("pushDevices").document(deviceDocumentId(for: token)).setData([
            "token": token,
            "platform": "ios",
            "pushTokenUpdatedAt": Timestamp(date: Date())
        ], merge: true)
        try await userReference.setData([
            "pushTokens": FieldValue.arrayUnion([token]),
            "pushTokenUpdatedAt": Timestamp(date: Date())
        ], merge: true)
    }

    func sendNotificationEvent(type: String, resourceId: String) async {
        guard let user = Auth.auth().currentUser,
              let baseURLString = Bundle.main.object(forInfoDictionaryKey: "PrecisionCourseAPIBaseURL") as? String,
              let baseURL = URL(string: baseURLString),
              let url = URL(string: "/api/notifications/send", relativeTo: baseURL)?.absoluteURL
        else { return }

        for attempt in 1...3 {
            do {
                let idToken = try await user.getIDToken()
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "type": type,
                    "resourceId": resourceId
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode)
                else {
                    throw PushNotificationError.senderRejectedRequest
                }
                if let result = try? JSONDecoder().decode(PushDispatchResponse.self, from: data) {
                    if result.sent == 0 {
                        lastTokenSyncMessage = result.reason == "no_tokens"
                            ? "Notification saved, but no recipient device token was registered."
                            : "Notification saved, but no push was delivered."
                    } else if result.failed > 0 {
                        lastTokenSyncMessage = "Notification sent to \(result.sent) device\(result.sent == 1 ? "" : "s"); \(result.failed) failed."
                    } else {
                        lastTokenSyncMessage = "Notification sent"
                    }
                }
                return
            } catch {
                guard attempt < 3 else {
                    lastTokenSyncMessage = "The event was saved, but its push notification could not be delivered."
                    return
                }
                try? await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    private func deviceDocumentId(for token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func openSharedRound(id roundId: String) {
        NotificationCenter.default.post(
            name: .precisionOpenSharedRound,
            object: nil,
            userInfo: ["sharedRoundId": roundId]
        )
    }

    private func openFriends() {
        NotificationCenter.default.post(name: .precisionOpenFriends, object: nil)
    }

    private func registerNotificationCategories() {
        let acceptAction = UNNotificationAction(
            identifier: NotificationAction.acceptFriendRequest,
            title: "Accept",
            options: [.authenticationRequired]
        )
        let declineAction = UNNotificationAction(
            identifier: NotificationAction.declineFriendRequest,
            title: "Decline",
            options: [.destructive, .authenticationRequired]
        )
        let friendRequestCategory = UNNotificationCategory(
            identifier: NotificationCategory.friendRequest,
            actions: [acceptAction, declineAction],
            intentIdentifiers: [],
            options: []
        )
        let joinGroupAction = UNNotificationAction(
            identifier: NotificationAction.joinGroup,
            title: "Join",
            options: [.authenticationRequired]
        )
        let declineGroupAction = UNNotificationAction(
            identifier: NotificationAction.declineGroupInvite,
            title: "Decline",
            options: [.destructive, .authenticationRequired]
        )
        let groupInviteCategory = UNNotificationCategory(
            identifier: NotificationCategory.groupInvite,
            actions: [joinGroupAction, declineGroupAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([friendRequestCategory, groupInviteCategory])
    }

    private func handleFriendRequestAction(
        _ actionIdentifier: String,
        requestId: String?,
        fromUserId: String?,
        toUserId: String?
    ) async {
        guard
            let requestId,
            let fromUserId,
            let toUserId,
            Auth.auth().currentUser?.uid == toUserId
        else {
            openFriends()
            return
        }

        do {
            if actionIdentifier == NotificationAction.acceptFriendRequest {
                let friendshipId = [fromUserId, toUserId].sorted().joined(separator: "_")
                try await database.collection("friendships").document(friendshipId).setData([
                    "memberIds": [fromUserId, toUserId].sorted(),
                    "createdAt": Timestamp(date: Date())
                ], merge: true)
                try await database.collection("friendRequests").document(requestId).setData([
                    "status": "accepted",
                    "updatedAt": Timestamp(date: Date())
                ], merge: true)
            } else if actionIdentifier == NotificationAction.declineFriendRequest {
                try await database.collection("friendRequests").document(requestId).setData([
                    "status": "declined",
                    "updatedAt": Timestamp(date: Date())
                ], merge: true)
            }
        } catch {
            lastTokenSyncMessage = error.localizedDescription
        }

        openFriends()
    }

    private func handleGroupInviteAction(
        _ actionIdentifier: String,
        inviteId: String?,
        groupId: String?,
        toUserId: String?
    ) async {
        guard
            let inviteId,
            let groupId,
            let toUserId,
            Auth.auth().currentUser?.uid == toUserId
        else {
            openFriends()
            return
        }

        do {
            if actionIdentifier == NotificationAction.joinGroup {
                try await database.collection("golfGroups").document(groupId).setData([
                    "memberIds": FieldValue.arrayUnion([toUserId]),
                    "updatedAt": Timestamp(date: Date())
                ], merge: true)
                try await database.collection("groupInvites").document(inviteId).setData([
                    "status": "accepted",
                    "updatedAt": Timestamp(date: Date())
                ], merge: true)
            } else if actionIdentifier == NotificationAction.declineGroupInvite {
                try await database.collection("groupInvites").document(inviteId).setData([
                    "status": "declined",
                    "updatedAt": Timestamp(date: Date())
                ], merge: true)
            }
        } catch {
            lastTokenSyncMessage = error.localizedDescription
        }

        openFriends()
    }

    private func routeDefaultTap(type: String?, sharedRoundId: String?) {
        if let sharedRoundId {
            openSharedRound(id: sharedRoundId)
        } else if type == "friendRequest" || type == "groupInvite" {
            openFriends()
        }
    }
}

private enum PushNotificationError: Error {
    case senderRejectedRequest
}

private struct PushDispatchResponse: Decodable {
    let sent: Int
    let failed: Int
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case sent
        case failed
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sent = try container.decodeIfPresent(Int.self, forKey: .sent) ?? 0
        failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

extension PushNotificationService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in
            self.currentToken = fcmToken
            do {
                try await self.saveToken(fcmToken)
            } catch {
                self.lastTokenSyncMessage = error.localizedDescription
            }
        }
    }
}

extension PushNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .badge, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let type = userInfo["type"] as? String
        let sharedRoundId = userInfo["sharedRoundId"] as? String
        let friendRequestId = userInfo["friendRequestId"] as? String
        let groupInviteId = userInfo["groupInviteId"] as? String
        let groupId = userInfo["groupId"] as? String
        let fromUserId = userInfo["fromUserId"] as? String
        let toUserId = userInfo["toUserId"] as? String
        switch actionIdentifier {
        case NotificationAction.acceptFriendRequest, NotificationAction.declineFriendRequest:
            await self.handleFriendRequestAction(
                actionIdentifier,
                requestId: friendRequestId,
                fromUserId: fromUserId,
                toUserId: toUserId
            )
        case NotificationAction.joinGroup, NotificationAction.declineGroupInvite:
            await self.handleGroupInviteAction(
                actionIdentifier,
                inviteId: groupInviteId,
                groupId: groupId,
                toUserId: toUserId
            )
        default:
            await self.routeDefaultTap(type: type, sharedRoundId: sharedRoundId)
        }
    }
}

final class PrecisionGolfAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        Task { @MainActor in
            PushNotificationService.shared.configure()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
        Task { @MainActor in
            await PushNotificationService.shared.syncCurrentToken()
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationService.shared.recordRegistrationError(error)
        }
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }
}
