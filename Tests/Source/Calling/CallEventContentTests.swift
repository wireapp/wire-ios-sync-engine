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

class CallEventContentTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let remoteMute = "REMOTEMUTE"

    private func eventData(type: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": type], options: [])
    }

    func testThatItCanBeCreatedFromData() {
        // GIVEN / WHEN
        let sut = CallEventContent(from: eventData(type: remoteMute), with: decoder)

        // THEN
        XCTAssertEqual(sut?.type, remoteMute)
    }

    func testThatIsRemoteMute_IsTrue_WhenTypeIsRemoteMute() {
        // GIVEN
        let sut = CallEventContent(from: eventData(type: remoteMute), with: decoder)!

        // WHEN / THEN
        XCTAssertTrue(sut.isRemoteMute)
    }

    func testThatIsRemoteMute_IsFalse_WhenTypeIsNotRemoteMute() {
        // GIVEN
        let sut = CallEventContent(from: eventData(type: "SOME"), with: decoder)!

        // WHEN / THEN
        XCTAssertFalse(sut.isRemoteMute)
    }
}
