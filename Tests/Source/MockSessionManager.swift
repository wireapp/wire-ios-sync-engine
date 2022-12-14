//
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
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

@testable import WireSyncEngine

class MockSessionManager: NSObject, WireSyncEngine.SessionManagerType {

    static let accountManagerURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MockSessionManager.accounts")

    var foregroundNotificationResponder: ForegroundNotificationResponder?
    var callKitManager: CallKitManagerInterface = MockCallKitManager()
    var callNotificationStyle: CallNotificationStyle = .pushNotifications
    var accountManager: AccountManager = AccountManager(sharedDirectory: accountManagerURL)
    var backgroundUserSessions: [UUID: ZMUserSession] = [:]
    var mockUserSession: ZMUserSession?

    var lastRequestToShowMessage: (ZMUserSession, ZMConversation, ZMConversationMessage)?
    var lastRequestToShowConversation: (ZMUserSession, ZMConversation)?
    var lastRequestToShowConversationsList: ZMUserSession?
    var lastRequestToShowUserProfile: UserType?
    var lastRequestToShowConnectionRequest: UUID?

    func showConversation(_ conversation: ZMConversation, at message: ZMConversationMessage?, in session: ZMUserSession) {
        if let message = message {
            lastRequestToShowMessage = (session, conversation, message)
        } else {
            lastRequestToShowConversation = (session, conversation)
        }
    }

    func showConversationList(in session: ZMUserSession) {
        lastRequestToShowConversationsList = session
    }

    func showUserProfile(user: UserType) {
        lastRequestToShowUserProfile = user
    }

    func showConnectionRequest(userId: UUID) {
        lastRequestToShowConnectionRequest = userId
    }

    @objc public var updatePushTokenCalled = false
    func configurePushToken(session: ZMUserSession) {
        updatePushTokenCalled = true
    }

    func updateAppIconBadge(accountID: UUID, unreadCount: Int) {
        // no-op
    }

    func configureUserNotifications() {
        // no-op
    }

    func update(credentials: ZMCredentials) -> Bool {
        return false
    }

    func checkJailbreakIfNeeded() -> Bool {
        return false
    }

    func passwordVerificationDidFail(with failCount: Int) {
        // no-op
    }
}

class MockCallKitManager: CallKitManagerInterface {

    var isEnabled = false

    func setDelegate(_ delegate: Any) {
        // no-op
    }

    func updateConfiguration() {
        // no-op
    }

    func continueUserActivity(_ userActivity: NSUserActivity) -> Bool {
        return false
    }

    func requestMuteCall(in conversation: ZMConversation, muted: Bool) {
        // no-op
    }

    func requestJoinCall(in conversation: ZMConversation, video: Bool) {
        // no-op
    }

    func requestEndCall(in conversation: ZMConversation, completion: (() -> Void)?) {
        // no-op
    }

}
