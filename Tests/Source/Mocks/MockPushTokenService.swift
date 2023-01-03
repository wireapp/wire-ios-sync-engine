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

@objc
class MockPushTokenService: NSObject, PushTokenServiceInterface {

    // MARK: - Properties

    var localToken: PushToken?
    var onTokenChange: ((PushToken?) -> Void)?
    var onRegistrationComplete: (() -> Void)?
    var onUnregistrationComplete: (() -> Void)?

    var registeredTokensByClientID = [String: [PushToken]]()

    // MARK: - Methods

    func storeLocalToken(_ token: PushToken?) {
        localToken = token
        onTokenChange?(token)
    }

    func registerPushToken(
        _ token: PushToken,
        clientID: String,
        in context: NotificationContext
    ) async throws {
        var existingTokens = registeredTokensByClientID[clientID] ?? []
        existingTokens.append(token)
        registeredTokensByClientID[clientID] = existingTokens
        onRegistrationComplete?()
    }

    func unregisterRemoteTokens(
        clientID: String,
        excluding token: PushToken?,
        in context: NotificationContext
    ) async throws {
        let existingTokens = registeredTokensByClientID[clientID] ?? []
        registeredTokensByClientID[clientID] = existingTokens.filter { $0 == token }
        onUnregistrationComplete?()

    }

}
