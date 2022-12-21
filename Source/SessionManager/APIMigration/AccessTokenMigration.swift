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

protocol AccessTokenRenewalObserver {
    func accessTokenRenewalDidSucceed()
    func accessTokenRenewalDidFail()
}

class AccessTokenMigration: APIMigration, AccessTokenRenewalObserver {

    let version: APIVersion

    private var continuation: CheckedContinuation<Void, Swift.Error>?
    private let logger = Logging.apiMigration

    enum Error: Swift.Error {
        case failedToRenewAccessToken
    }

    init(version: APIVersion) {
        self.version = version
    }

    func perform(with session: ZMUserSession, clientID: String) async throws {
        logger.info("performing access token migration for clientID \(clientID)")

        session.setAccessTokenRenewalObserver(self)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            self.continuation = continuation
            session.renewAccessToken(with: clientID)
        }
    }

    // TODO: David
    // We may want to tear down the access token renewal observer when it succeeds / fails
    // to avoid getting callbacks when the token is renewed from elsewhere.
    // Note that since we tear down the continuation, the only consequence to that is that we will log.

    func accessTokenRenewalDidSucceed() {
        logger.info("successfully renewed access token")
        continuation?.resume()
        teardownContinuation()
    }

    func accessTokenRenewalDidFail() {
        logger.warn("failed to renew access token")
        continuation?.resume(throwing: Self.Error.failedToRenewAccessToken)
        teardownContinuation()
    }

    private func teardownContinuation() {
        continuation = nil
    }
}
