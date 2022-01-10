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

class AVSIdentifierTests: XCTestCase {

    let uuid = UUID()
    let domain = "wire.com"

    func testProperties_WhenCreatedFromSerializedString_WithUUIDAndDomain() {
        // When
        let serializedString = "\(uuid.uuidString)@\(domain)"
        let sut = AVSIdentifier(string: serializedString)

        // Then
        XCTAssertNotNil(sut)
        XCTAssertEqual(sut?.identifier, uuid)
        XCTAssertEqual(sut?.domain, domain)
        XCTAssertEqual(sut?.serialized, serializedString)
    }

    func testProperties_WhenCreatedFromSerializedString_WithUUID() {
        // When
        let serializedString = uuid.uuidString
        let sut = AVSIdentifier(string: serializedString)

        // Then
        XCTAssertNotNil(sut)
        XCTAssertEqual(sut?.identifier, uuid)
        XCTAssertNil(sut?.domain)
        XCTAssertEqual(sut?.serialized, serializedString)
    }

    func testThatCreationFromInvalidStringReturnsNil() {
        // When / Then
        XCTAssertNil(AVSIdentifier(string: "invalidUUID@domain.com"))
        XCTAssertNil(AVSIdentifier(string: "UUID@domain.com@something"))
        XCTAssertNil(AVSIdentifier(string: ""))
    }
}
