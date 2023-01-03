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
        mockPushTokenService = MockPushTokenService()
        super.setUp()
        createSelfUserAndConversation()
        PushTokenStorage.pushToken = nil
    }

    override func tearDown() {
        mockPushTokenService = nil
        PushTokenStorage.pushToken = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testItRegistersAndSyncsStandardTokenIfNoneExists() throws {
        XCTAssert(login())
        let sut = try XCTUnwrap(sessionManager)
        let application = try XCTUnwrap(application)
        let pushService = try XCTUnwrap(mockPushTokenService)
        let session = try XCTUnwrap(sut.activeUserSession)
        let clientID = try XCTUnwrap(session.selfUserClient?.remoteIdentifier)
        let deviceToken = Data.secureRandomData(length: 8)

        // Mock device token
        application.deviceToken = deviceToken
        application.registerForRemoteNotificationCount = 0

        // Given we need a standard token
        sut.requiredPushTokenType = .standard

        // Given no local token exists
        pushService.localToken = nil

        // Given some tokens are registered remotely
        pushService.registeredTokensByClientID[clientID] = [
            .createAPNSToken(from: .secureRandomData(length: 8)),
            .createVOIPToken(from: .secureRandomData(length: 8))
        ]

        let registrationDone = expectation(description: "registration done")
        pushService.onRegistrationComplete = { registrationDone.fulfill() }

        let unregistrationDone = expectation(description: "unregistration done")
        pushService.onUnregistrationComplete = { unregistrationDone.fulfill() }

        // When
        sut.configurePushToken(session: session)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))

        // Then a new token was generated
        XCTAssertEqual(application.registerForRemoteNotificationCount, 1)

        // Then the local token is correct
        let expectedToken = PushToken.createAPNSToken(from: deviceToken)
        XCTAssertEqual(pushService.localToken, expectedToken)

        // Then only the local token is registered
        XCTAssertEqual(pushService.registeredTokensByClientID[clientID], [expectedToken])
    }

    func testItRegistersAndSyncsVoIPTokenIfNoneExists() throws {
        XCTAssert(login())
        let sut = try XCTUnwrap(sessionManager)
        let pushService = try XCTUnwrap(mockPushTokenService)
        let session = try XCTUnwrap(sut.activeUserSession)
        let clientID = try XCTUnwrap(session.selfUserClient?.remoteIdentifier)
        let deviceToken = Data.secureRandomData(length: 8)

        // Mock device token
        pushRegistry.mockPushToken = deviceToken

        // Given we need a standard token
        sut.requiredPushTokenType = .voip

        // Given no local token exists
        pushService.localToken = nil

        // Given some tokens are registered remotely
        pushService.registeredTokensByClientID[clientID] = [
            .createAPNSToken(from: .secureRandomData(length: 8)),
            .createVOIPToken(from: .secureRandomData(length: 8))
        ]

        let registrationDone = expectation(description: "registration done")
        pushService.onRegistrationComplete = { registrationDone.fulfill() }

        let unregistrationDone = expectation(description: "unregistration done")
        pushService.onUnregistrationComplete = { unregistrationDone.fulfill() }

        // When
        sut.configurePushToken(session: session)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))

        // Then the local token is correct
        let expectedToken = PushToken.createVOIPToken(from: deviceToken)
        XCTAssertEqual(pushService.localToken, expectedToken)

        // Then only the local token is registered
        XCTAssertEqual(pushService.registeredTokensByClientID[clientID], [expectedToken])
    }

    func testItRegistersAndSyncsStandardTokenIfVoIPTokenExists() throws {
        XCTAssert(login())
        let sut = try XCTUnwrap(sessionManager)
        let application = try XCTUnwrap(application)
        let pushService = try XCTUnwrap(mockPushTokenService)
        let session = try XCTUnwrap(sut.activeUserSession)
        let clientID = try XCTUnwrap(session.selfUserClient?.remoteIdentifier)
        let deviceToken = Data.secureRandomData(length: 8)

        // Mock device token
        application.deviceToken = deviceToken
        application.registerForRemoteNotificationCount = 0

        // Given we need a standard token
        sut.requiredPushTokenType = .standard

        // Given no local token exists
        pushService.localToken = .createVOIPToken(from: .secureRandomData(length: 8))

        // Given some tokens are registered remotely
        pushService.registeredTokensByClientID[clientID] = [
            pushService.localToken!
        ]

        let registrationDone = expectation(description: "registration done")
        pushService.onRegistrationComplete = { registrationDone.fulfill() }

        let unregistrationDone = expectation(description: "unregistration done")
        pushService.onUnregistrationComplete = { unregistrationDone.fulfill() }

        // When
        sut.configurePushToken(session: session)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))

        // Then a new token was generated
        XCTAssertEqual(application.registerForRemoteNotificationCount, 1)

        // Then the local token is correct
        let expectedToken = PushToken.createAPNSToken(from: deviceToken)
        XCTAssertEqual(pushService.localToken, expectedToken)

        // Then only the local token is registered
        XCTAssertEqual(pushService.registeredTokensByClientID[clientID], [expectedToken])
    }

}
