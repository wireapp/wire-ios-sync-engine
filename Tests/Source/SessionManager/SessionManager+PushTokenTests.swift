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

import XCTest
import WireTesting
@testable import WireSyncEngine

class SessionManagerPushTokenTests: IntegrationTest {

    override func setUp() {
        super.setUp()
        PushTokenStorage.pushToken = nil
    }

    override func tearDown() {
        super.tearDown()
        PushTokenStorage.pushToken = nil
    }

    // MARK: - Helpers

    struct Failure: LocalizedError {

        let message: String

        var errorDescription: String? {
            return message
        }

        init(_ message: String) {
            self.message = message
        }

    }

    func sut() throws -> SessionManager {
        guard let sut = sessionManager else {
            throw Failure("sut not available")
        }

        return sut
    }

    // MARK: - Tests

    // Given no local token, it creates APNS token, registers it, removes others
    func testItRegistersAndSyncsStandardTokenIfNoneExists() throws {
        // Given
        let sut = try sut()
        sut.requiredPushTokenType = .standard
        PushTokenStorage.pushToken = nil

        // Some remote tokens


        // When
        // Configure tokens for a session.

        // Then
        // Local token is APNS
        // Remote token is APNS
    }

    // Given VOIP local token, it creates APNS token, registers it, removes others

    // Given no local token, it creates VOIP token, registers it, removes others

}
