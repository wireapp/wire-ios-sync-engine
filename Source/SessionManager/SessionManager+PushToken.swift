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

extension SessionManager {

    /* Which pushes do we use?
     *
     * iOS 15 and later:
     *    - Standard APNS pushes -> delivered to Notification Service Extension (NSE).
     *    - Still register for voIP pushes (BUT DON'T REGISTER WITH BACKEND), so that
     *      the NSE can wake up the main app to notify calls to CallKit (via PushKit).
     *    - Why? VoIP pushes are restricted for calling only since iOS 13, our exemption
     *      expires in iOS 15.
     *
     * iOS 14 and earlier:
     *    - VoIP pushes (via PushKit) -> delivered to main app and used to fetch all
     *      events, regardless if calling or not.
     */

    // MARK: - Token registration

    public func configurePushToken(session: ZMUserSession) {
        guard let localToken = pushTokenService.localToken else {
            Logging.push.safePublic("no local token, will generate one")
            generateLocalToken(session: session)
            return
        }

        guard localToken.tokenType == requiredPushTokenType else {
            Logging.push.safePublic("local token is of type \(localToken.tokenType) but should be \(requiredPushTokenType), will generate a new token")
            generateLocalToken(session: session)
            return
        }

        syncLocalTokenWithRemote(session: session)
    }

    private func generateLocalToken(session: ZMUserSession) {
        Logging.push.safePublic("generateLocalToken")
        session.managedObjectContext.performGroupedBlock {
            switch self.requiredPushTokenType {
            case .voip:
                Logging.push.safePublic("generateLocalToken: voip")
                if let token = self.pushRegistry.pushToken(for: .voIP) {
                    Logging.push.safePublic("generateLocalToken: voip: token already generated, storing...")
                    self.pushTokenService.storeLocalToken(.createVOIPToken(from: token))
                }
            case .standard:
                Logging.push.safePublic("generateLocalToken: standard")
                self.application.registerForRemoteNotifications()
            }
        }
    }

    func syncLocalTokenWithRemote(session: ZMUserSession) {
        Logging.push.safePublic("syncLocalTokenWithRemote")

        guard let clientID = session.selfUserClient?.remoteIdentifier else {
            Logging.push.safePublic("syncLocalTokenWithRemote: failed: no self client id")
            return
        }

        let context = session.managedObjectContext.notificationContext

        Task {
            do {
                try await pushTokenService.syncLocalTokenWithRemote(
                    clientID: clientID,
                    in: context
                )

                Logging.push.safePublic("syncLocalTokenWithRemote: success")

            } catch {
                Logging.push.safePublic("syncLocalTokenWithRemote: failed: pushTokenService failed")
            }
        }
    }

}
