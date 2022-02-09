//
// Wire
// Copyright (C) 2021 Wire Swiss GmbH
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

class ZMConversation_AVSIdentifierTests: MessagingTest {

    override func tearDown() {
        uiMOC.zm_isFederationEnabled = false
        super.tearDown()
    }

    func testThatItIncludesDomain_WhenFederationIsEnabled() {
        // GIVEN
        uiMOC.zm_isFederationEnabled = true

        let sut = ZMConversation.insertNewObject(in: uiMOC)
        sut.remoteIdentifier = UUID()
        sut.domain = "example.domain.com"

        // WHEN / THEN
        XCTAssertEqual(sut.avsIdentifier?.domain, sut.domain)
    }

    func testThatItDoesntIncludeDomain_WhenFederationIsDisabled() {
        // GIVEN
        uiMOC.zm_isFederationEnabled = false

        let sut = ZMConversation.insertNewObject(in: uiMOC)
        sut.remoteIdentifier = UUID()
        sut.domain = "example.domain.com"

        // WHEN / THEN
        XCTAssertNil(sut.avsIdentifier!.domain)
    }
}
