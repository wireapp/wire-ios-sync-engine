//
// Wire
// Copyright (C) 2022 Wire Swiss GmbH
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

extension SessionManager: VoIPPushManagerDelegate {

    // MARK: - Legacy voIP push

    public func processIncomingRealVoIPPush(
        payload: [AnyHashable: Any],
        completion: @escaping () -> Void
    ) {
        Logging.push.info("processing incoming (real) voIP push payload: \(payload)")

        // We were given some time to run, resume background task creation.
        BackgroundActivityFactory.shared.resume()
        notificationsTracker?.registerReceivedPush()

        guard
            let accountId = payload.accountId(),
            let account = self.accountManager.account(with: accountId),
            let activity = BackgroundActivityFactory.shared.startBackgroundActivity(
                withName: "\(payload.stringIdentifier)",
                expirationHandler: { [weak self] in
                  Logging.push.warn("Processing push payload expired: \(payload)")
                  self?.notificationsTracker?.registerProcessingExpired()
                }
            )
        else {
            Logging.push.warn("Aborted processing of payload: \(payload)")
            notificationsTracker?.registerProcessingAborted()
            return completion()
        }

        withSession(for: account, perform: { userSession in
            Logging.push.safePublic("Forwarding push payload to user session with account \(account.userIdentifier)")

            userSession.receivedPushNotification(with: payload, completion: { [weak self] in
                Logging.push.info("Processing push payload completed")
                self?.notificationsTracker?.registerNotificationProcessingCompleted()
                BackgroundActivityFactory.shared.endBackgroundActivity(activity)
                completion()
            })
        })
    }

}

private extension VoIPPushPayload {

    func caller(in context: NSManagedObjectContext) -> ZMUser? {
        return ZMUser.fetch(
            with: senderID,
            domain: senderDomain,
            in: context
        )
    }

    func conversation(in context: NSManagedObjectContext) -> ZMConversation? {
        return ZMConversation.fetch(
            with: conversationID,
            domain: conversationDomain,
            in: context
        )
    }

}

private extension Dictionary where Key == AnyHashable, Value == Any {

    var stringIdentifier: String {
        guard
            let data = self["data"] as? [AnyHashable: Any],
            let innerData = data["data"] as? [AnyHashable: Any],
            let id = innerData["id"]
        else {
            return self.description
        }

        return "\(id)"
    }

}

