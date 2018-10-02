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

private let log = ZMSLog(tag: "Push")

protocol PushRegistry {
    
    var delegate: PKPushRegistryDelegate? { get set }
    var desiredPushTypes: Set<PKPushType>? { get set }
    
    func pushToken(for type: PKPushType) -> Data?
    
}

extension PKPushRegistry: PushRegistry {}


// MARK: - PKPushRegistryDelegate

extension SessionManager: PKPushRegistryDelegate {
    
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        
        log.debug("PushKit token was updated: \(pushCredentials.token)")
        
        // give new push token to all running sessions
        backgroundUserSessions.values.forEach({ userSession in
            userSession.setPushKitToken(pushCredentials.token)
        })
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        
        log.debug("PushKit token was invalidated")
        
        // delete push token from all running sessions
        backgroundUserSessions.values.forEach({ userSession in
            userSession.deletePushKitToken()
        })
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        self.pushRegistry(registry, didReceiveIncomingPushWith: payload, for: type, completion: {})
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // We only care about voIP pushes, other types are not related to push notifications (watch complications and files)
        guard type == .voIP else { return completion() }
        
        log.debug("Received push payload: \(payload.dictionaryPayload)")
        notificationsTracker?.registerReceivedPush()
        
        guard let accountId = payload.dictionaryPayload.accountId(),
              let account = self.accountManager.account(with: accountId),
              let activity = BackgroundActivityFactory.sharedInstance().backgroundActivity(withName: "Process PushKit payload", expirationHandler: { [weak self] in
                log.debug("Processing push payload expired")
                self?.notificationsTracker?.registerProcessingExpired()
              }) else {
                log.debug("Aborted processing of payload: \(payload.dictionaryPayload)")
                notificationsTracker?.registerProcessingAborted()
                return completion()
        }
        
        withSession(for: account, perform: { userSession in
            log.debug("Forwarding push payload to user session with account \(account.userIdentifier)")
            
            userSession.receivedPushNotification(with: payload.dictionaryPayload, completion: { [weak self] in
                log.debug("Processing push payload completed")
                self?.notificationsTracker?.registerNotificationProcessingCompleted()
                activity.end()
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
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        // route to user session
        handleNotification(with: notification.userInfo) { userSession in
            userSession.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
        }
    }
    
    // Called when the user engages a notification action.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void)
    {
        // route to user session
        handleNotification(with: response.notification.userInfo) { userSession in
            userSession.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
        }
    }
    
    // MARK: Helpers
    
    @objc public func configureUserNotifications() {
        guard application.shouldRegisterUserNotificationSettings ?? true else { return }
        notificationCenter.setNotificationCategories(PushNotificationCategory.allCategories)
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound], completionHandler: { _, _ in })
        notificationCenter.delegate = self
    }
    
    public func updatePushToken(for session: ZMUserSession) {
        session.managedObjectContext.performGroupedBlock {
            // Refresh the tokens if needed
            if let token = self.pushRegistry.pushToken(for: .voIP) {
                session.setPushKitToken(token)
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
    
    fileprivate func activateAccount(for session: ZMUserSession, completion: @escaping () -> ()) {
        if session == activeUserSession {
            completion()
            return
        }
        
        var foundSession: Bool = false
        self.backgroundUserSessions.forEach { accountId, backgroundSession in
            if session == backgroundSession, let account = self.accountManager.account(with: accountId) {
                self.select(account) {
                    completion()
                }
                foundSession = true
                return
            }
        }
        
        if !foundSession {
            fatalError("User session \(session) is not present in backgroundSessions")
        }
    }
}

// MARK: - ShowContentDelegate


@objc
public protocol ShowContentDelegate: class {
    
    func showConversation(_ conversation: ZMConversation, at message: ZMConversationMessage?)
    func showConversationList()
    
}

extension SessionManager {
    
    public func showConversation(_ conversation: ZMConversation, at message: ZMConversationMessage?, in session: ZMUserSession) {
        activateAccount(for: session) {
            self.showContentDelegate?.showConversation(conversation, at: message)
        }
    }
    
    public func showConversationList(in session: ZMUserSession) {
        activateAccount(for: session) {
            self.showContentDelegate?.showConversationList()
        }
    }
    
}
