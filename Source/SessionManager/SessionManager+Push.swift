//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import PushKit
import UserNotifications

private let pushLog = ZMSLog(tag: "Push")

public enum PushFromNotificationExtensionKeys: String {
    case accountId
    case fromNotificationExtension
    case currentTimestamp
}

public struct PushFromNotificationExtension: Codable {
    let conversationId: UUID
    let senderId: UUID
    let senderClientID: String
    let conversationDomain: String?
    let senderDomain: String?
    let payloadData: Data
    let timestamp: Date

    public init? (event: ZMUpdateEvent) {
        guard let conversationId = event.conversationUUID,
              let senderId = event.senderUUID,
              let senderClientID = event.senderClientID,
              let timestamp = event.timestamp,
              let genericMessage = GenericMessage(from: event),
              let payloadData = genericMessage.calling.content.data(using: .utf8, allowLossyConversion: false)
        else {
            return nil
        }
        self.conversationId = conversationId
        self.senderId = senderId
        self.senderClientID = senderClientID
        self.conversationDomain = event.conversationDomain
        self.senderDomain = event.senderDomain
        self.timestamp = timestamp
        self.payloadData = payloadData
    }
}

protocol PushRegistry {

    var delegate: PKPushRegistryDelegate? { get set }
    var desiredPushTypes: Set<PKPushType>? { get set }

    func pushToken(for type: PKPushType) -> Data?

}

extension PKPushRegistry: PushRegistry {}

extension PKPushPayload {
    fileprivate var stringIdentifier: String {
        if let data = dictionaryPayload["data"] as? [AnyHashable: Any], let innerData = data["data"] as? [AnyHashable: Any], let id = innerData["id"] {
            return "\(id)"
        } else {
            return self.description
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension SessionManager: PKPushRegistryDelegate {

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }

        Logging.push.safePublic("PushKit token was updated: \(pushCredentials)")

        // give new push token to all running sessions
        backgroundUserSessions.values.forEach({ userSession in
            let pushToken = PushToken.createVOIPToken(from: pushCredentials.token)
            userSession.setPushToken(pushToken)
        })
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }

        Logging.push.safePublic("PushKit token was invalidated")

        // delete push token from all running sessions
        backgroundUserSessions.values.forEach({ userSession in
            userSession.deletePushKitToken()
        })
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        self.pushRegistry(registry, didReceiveIncomingPushWith: payload, for: type, completion: {})
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {

        if let fromNotificationExtension = payload.dictionaryPayload[PushFromNotificationExtensionKeys.fromNotificationExtension.rawValue] as? Bool,
           fromNotificationExtension == true {
            handleCallPushPayload(payload, completion: completion)
        } else {
            handleLegacyPushPayload(payload, for: type, completion: completion)
        }
    }

    private func handleCallPushPayload(_ payload: PKPushPayload, completion: @escaping () -> Void) {
        guard let accountIdString = payload.dictionaryPayload[PushFromNotificationExtensionKeys.accountId.rawValue] as? String,
              let accountId = UUID(uuidString: accountIdString),
              let account = self.accountManager.account(with: accountId),
              let serverTimeDelta = payload.dictionaryPayload["currentTimestamp"] as? TimeInterval,
              let dictionaryPayload = payload.dictionaryPayload as? [String: Any],
              let pushPayload = PushFromNotificationExtension(dictionaryPayload) else {
                  Logging.push.safePublic("Aborted processing of payload: \(payload)")
                  return completion()
              }

        withSession(for: account, perform: { userSession in
            Logging.push.safePublic("Forwarding push payload to user session with account \(account.userIdentifier)")
            userSession.syncStrategy?.callingRequestStrategy?.processCallEvent(conversationUUID: pushPayload.conversationId,
                                                                               senderUUID: pushPayload.senderId,
                                                                               clientId: pushPayload.senderClientID,
                                                                               conversationDomain: pushPayload.conversationDomain,
                                                                               senderDomain: pushPayload.senderDomain,
                                                                               payload: pushPayload.payloadData,
                                                                               currentTimestamp: serverTimeDelta,
                                                                               eventTimestamp: pushPayload.timestamp)
        })
    }

    private func handleLegacyPushPayload(_ payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // We only care about voIP pushes, other types are not related to push notifications (watch complications and files)
        guard type == .voIP else { return completion() }

        Logging.push.safePublic("Received push payload: \(payload)")
        // We were given some time to run, resume background task creation.
        BackgroundActivityFactory.shared.resume()
        notificationsTracker?.registerReceivedPush()

        guard let accountId = payload.dictionaryPayload.accountId(),
              let account = self.accountManager.account(with: accountId),
              let activity = BackgroundActivityFactory.shared.startBackgroundActivity(withName: "\(payload.stringIdentifier)", expirationHandler: { [weak self] in
                  Logging.push.safePublic("Processing push payload expired: \(payload)")
                  self?.notificationsTracker?.registerProcessingExpired()
              }) else {
                  Logging.push.safePublic("Aborted processing of payload: \(payload)")
                  notificationsTracker?.registerProcessingAborted()
                  return completion()
              }

        withSession(for: account, perform: { userSession in
            Logging.push.safePublic("Forwarding push payload to user session with account \(account.userIdentifier)")

            userSession.receivedPushNotification(with: payload.dictionaryPayload, completion: { [weak self] in
                Logging.push.safePublic("Processing push payload completed")
                self?.notificationsTracker?.registerNotificationProcessingCompleted()
                BackgroundActivityFactory.shared.endBackgroundActivity(activity)
                completion()
            })
        })
    }
}

// MARK: - UNUserNotificationCenterDelegate

@objc extension SessionManager: UNUserNotificationCenterDelegate {

    // Called by the OS when the app receieves a notification while in the
    // foreground.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // route to user session
        handleNotification(with: notification.userInfo) { userSession in
            userSession.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
        }
    }

    // Called when the user engages a notification action.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        // Resume background task creation.
        BackgroundActivityFactory.shared.resume()
        // route to user session
        handleNotification(with: response.notification.userInfo) { userSession in
            userSession.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
        }
    }

    // MARK: Helpers

    public func configureUserNotifications() {
        guard (application as? NotificationSettingsRegistrable)?.shouldRegisterUserNotificationSettings ?? true else { return }
        notificationCenter.setNotificationCategories(PushNotificationCategory.allCategories)
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound], completionHandler: { _, _ in })
        notificationCenter.delegate = self
    }

    public func updatePushToken(for session: ZMUserSession) {
        session.managedObjectContext.performGroupedBlock { [weak session] in
            // Refresh the tokens if needed
            if #available(iOS 13.0, *), !self.configuration.useLegacyPushNotifications {
                pushLog.safePublic("creating standard push token")
                self.application.registerForRemoteNotifications()
            } else {
                if let token = self.pushRegistry.pushToken(for: .voIP) {
                    pushLog.safePublic("creating voip push token")
                    let pushToken = PushToken.createVOIPToken(from: token)
                    session?.setPushToken(pushToken)
                }
            }
        }
    }

    func handleNotification(with userInfo: NotificationUserInfo, block: @escaping (ZMUserSession) -> Void) {
        guard
            let selfID = userInfo.selfUserID,
            let account = accountManager.account(with: selfID)
            else { return }

        self.withSession(for: account, perform: block)
    }

    fileprivate func activateAccount(for session: ZMUserSession, completion: @escaping () -> Void) {
        if session == activeUserSession {
            completion()
            return
        }

        var foundSession: Bool = false
        self.backgroundUserSessions.forEach { accountId, backgroundSession in
            if session == backgroundSession, let account = self.accountManager.account(with: accountId) {

                self.select(account, completion: { _ in
                    completion()
                })
                foundSession = true
                return
            }
        }

        if !foundSession {
            fatalError("User session \(session) is not present in backgroundSessions")
        }
    }
}

extension SessionManager {

    public func showConversation(_ conversation: ZMConversation,
                                 at message: ZMConversationMessage? = nil,
                                 in session: ZMUserSession) {
        activateAccount(for: session) {
            self.presentationDelegate?.showConversation(conversation, at: message)
        }
    }

    public func showConversationList(in session: ZMUserSession) {
        activateAccount(for: session) {
            self.presentationDelegate?.showConversationList()
        }
    }

    public func showUserProfile(user: UserType) {
        self.presentationDelegate?.showUserProfile(user: user)
    }

    public func showConnectionRequest(userId: UUID) {
        self.presentationDelegate?.showConnectionRequest(userId: userId)
    }

}

extension SessionManager {
    public func updateDeviceToken(_ deviceToken: Data) {
        let pushToken = PushToken.createAPNSToken(from: deviceToken)
        // give new device token to all running sessions
        self.backgroundUserSessions.values.forEach({ userSession in
            userSession.setPushToken(pushToken)
        })
    }
}
