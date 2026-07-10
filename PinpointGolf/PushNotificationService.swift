import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import GoogleSignIn
import UIKit
import UserNotifications

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
            try await database.collection("users").document(uid).setData([
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
        try await database.collection("users").document(uid).setData([
            "pushTokens": FieldValue.arrayUnion([token]),
            "pushTokenUpdatedAt": Timestamp(date: Date())
        ], merge: true)
        lastTokenSyncMessage = "Notifications ready"
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
