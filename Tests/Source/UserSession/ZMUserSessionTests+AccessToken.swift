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
import WireTransport
@testable import WireSyncEngine
import XCTest

class ZMUserSessionTests_AccessToken: ZMUserSessionTestsBase {

    override func tearDown() {
        BackendInfo.apiVersion = nil
        super.tearDown()
    }

    func test_itRenewsAccessTokenAfterClientRegistration_StartingFromApiV3() {
        createSelfClient()

        APIVersion.allCases.forEach {
            test_accessTokenRenewalAfterClientRegistration(
                apiVersion: $0,
                shouldRenew: $0 > .v2
            )
        }
    }

    func test_accessTokenRenewalAfterClientRegistration(
        apiVersion: APIVersion,
        shouldRenew: Bool
    ) {
        // given
        BackendInfo.apiVersion = apiVersion

        let userClient = UserClient.insertNewObject(in: uiMOC)
        userClient.remoteIdentifier = "1234abcd"

        // when
        sut.didRegisterSelfUserClient(userClient)

        // then
        if shouldRenew {
            XCTAssertEqual(transportSession.renewAccessTokenCalls.count, 1)
            XCTAssertEqual(transportSession.renewAccessTokenCalls.first, "1234abcd")
        } else {
            XCTAssertEqual(transportSession.renewAccessTokenCalls.count, 0)
        }

    }

}
