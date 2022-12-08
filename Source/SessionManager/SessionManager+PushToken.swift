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

    /*

     Which pushes do we use?

     iOS 15 and later:
        - Standard APNS pushes -> delivered to Notification Service Extension (NSE).
        - Still register for voIP pushes (BUT DON'T REGISTER WITH BACKEND), so that
          the NSE can wake up the main app to notify calls to CallKit (via PushKit).
        - Why? VoIP pushes are restricted for calling only since iOS 13, out exemption
          expires in iOS 15.

     iOS 14 and earlier:
        - VoIP pushes (via PushKit) -> delivered to main app and used to fetch all
          events, regardless if calling or not.

     */

    // MARK: - Registration

    func registerForVoIPPushNotifications() {
        Logging.push.safePublic("registering for voip push token")
        self.pushRegistry.delegate = self
        let pkPushTypeSet: Set<PKPushType> = [PKPushType.voIP]
        self.pushRegistry.desiredPushTypes = pkPushTypeSet
    }

    // MARK: - Token registration

    func setUpPushToken(session: ZMUserSession) {
        guard let localToken = PushTokenStorage.pushToken else {
            // No local token, generate a new one.
            generateLocalToken(session: session)
            return
        }

        if localToken.tokenType != requiredPushTokenType {
            // Local token is invalid, generate a new one.
            generateLocalToken(session: session)
        }

        // Local token is correct.
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
                    PushTokenStorage.pushToken = .createVOIPToken(from: token)
                }
            case .standard:
                Logging.push.safePublic("generateLocalToken: standard")
                self.application.registerForRemoteNotifications()
            }
        }
    }

    func syncLocalTokenWithRemote(session: ZMUserSession) {
        Logging.push.safePublic("syncLocalTokenWithRemote")
        registerLocalToken(session: session)
        unregisterOtherTokens(session: session)
    }

    private func registerLocalToken(session: ZMUserSession) {
        Logging.push.safePublic("registerLocalToken")
        guard let token = PushTokenStorage.pushToken else {
            Logging.push.safePublic("registerLocalToken: failed: no token to register")
            return
        }

        guard let clientID = session.selfUserClient?.remoteIdentifier else {
            Logging.push.safePublic("registerLocalToken: failed: no client id")
            return
        }

        RegisterPushTokenAction(
            token: token,
            clientID: clientID
        ) { result in
            switch result {
            case .success:
                Logging.push.safePublic("registerLocalToken: success")
                break

            case .failure(let error):
                Logging.push.safePublic("registerLocalToken: failed: \(error)")
                break
            }
        }.send(in: session.managedObjectContext.notificationContext)
    }

    private func unregisterOtherTokens(session: ZMUserSession) {
        Logging.push.safePublic("unregisterOtherTokens")
        guard let clientID = session.selfUserClient?.remoteIdentifier else {
            Logging.push.safePublic("unregisterOtherTokens: failed: no client id")
            return
        }

        GetPushTokensAction(clientID: clientID) { [weak self] result in
            switch result {
            case .success(let tokens):
                let count = SanitizedString(stringLiteral: "\(tokens.count)")
                Logging.push.safePublic("unregisterOtherTokens: there are \(count) registered tokens")
                let localToken = PushTokenStorage.pushToken

                for remoteToken in tokens where remoteToken != localToken {
                    self?.unregisterPushToken(remoteToken, in: session)
                }

            case .failure(let error):
                Logging.push.safePublic("unregisterOtherTokens: failed: \(error)")
                break
            }
        }.send(in: session.managedObjectContext.notificationContext)
    }

    private func unregisterPushToken(_ pushToken: PushToken, in session: ZMUserSession) {
        Logging.push.safePublic("unregisterPushToken")
        RemovePushTokenAction(deviceToken: pushToken.deviceTokenString) { result in
            switch result {
            case .success:

                Logging.push.safePublic("unregisterPushToken: success")
                break

            case .failure(let error):
                Logging.push.safePublic("unregisterPushToken: failed: \(error)")
                break
            }
        }.send(in: session.managedObjectContext.notificationContext)
    }

    // MARK: - Legacy

    func updateOrMigratePushToken(session userSession: ZMUserSession) {
        return
        return
        // If the legacy token exists, migrate it to the PushTokenStorage and delete it from selfClient
        if let client = userSession.selfUserClient, let legacyToken = client.retrieveLegacyPushToken() {
            PushTokenStorage.pushToken = legacyToken
        }

        guard let localToken = PushTokenStorage.pushToken else {
            updatePushToken(for: userSession)
            return
        }

        if localToken.tokenType != requiredPushTokenType {
            userSession.deletePushToken { [weak self] in
                self?.updatePushToken(for: userSession)
            }
        }
    }


}
