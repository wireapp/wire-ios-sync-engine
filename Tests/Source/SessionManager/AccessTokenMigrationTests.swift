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
import XCTest
@testable import WireSyncEngine

class AccessTokenRenewerMock: AccessTokenRenewing {

    struct Calls {
        var setAccessTokenRenewalObserver = [AccessTokenRenewalObserver]()
        var renewAccessToken = [String]()
    }

    var calls = Calls()

    func setAccessTokenRenewalObserver(_ observer: AccessTokenRenewalObserver) {
        calls.setAccessTokenRenewalObserver.append(observer)
    }

    var shoudFail: Bool = false
    func renewAccessToken(with clientID: String) {
        calls.renewAccessToken.append(clientID)

        if shoudFail {
            calls.setAccessTokenRenewalObserver.last?.accessTokenRenewalDidFail()
        } else {
            calls.setAccessTokenRenewalObserver.last?.accessTokenRenewalDidSucceed()
        }
    }

}

class AccessTokenMigrationTests: XCTestCase {

    func test_itSetsObserver_AndRenewsAccessToken() async throws {
        // Given
        let sut = AccessTokenMigration()
        let tokenRenewer = AccessTokenRenewerMock()
        let clientID = "1234abcd"

        tokenRenewer.shoudFail = false

        // When
        try await sut.perform(with: tokenRenewer, clientID: clientID)

        // Then
        XCTAssertEqual(tokenRenewer.calls.setAccessTokenRenewalObserver.count, 1)
        XCTAssertEqual(tokenRenewer.calls.renewAccessToken.count, 1)
        XCTAssertEqual(tokenRenewer.calls.renewAccessToken.first, clientID)
    }

    func test_itThrows_FailedToRenewAccessToken() async {
        // Given
        let sut = AccessTokenMigration()
        let tokenRenewer = AccessTokenRenewerMock()
        let clientID = "1234abcd"

        tokenRenewer.shoudFail = true

        // When / Then
        do {
            try await sut.perform(with: tokenRenewer, clientID: clientID)
            XCTFail("expected an error")
        } catch let error as AccessTokenMigration.Error {
            XCTAssertEqual(error, .failedToRenewAccessToken)
        } catch {
            XCTFail("error is not the one expected")
        }
    }

}
