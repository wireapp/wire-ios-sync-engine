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
import WireRequestStrategy

private let pushLog = ZMSLog(tag: "Push")

protocol PushRegistry {

    var delegate: PKPushRegistryDelegate? { get set }
    var desiredPushTypes: Set<PKPushType>? { get set }

    func pushToken(for type: PKPushType) -> Data?

}

extension PKPushRegistry: PushRegistry {}

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

    var shouldProcessLegacyPushes: Bool {
        return requiredPushTokenType == .voip
    }

}
