//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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

class SessionManagerTests_APIVersionResolver: IntegrationTest {

    func testThatDatabaseIsMigrated_WhenFederationIsEnabled() throws {
        // Given
        let sessionManager = try XCTUnwrap(sessionManager)
        let account = addAccount(name: "John Doe", userIdentifier: UUID())
        sessionManager.accountManager.select(account)

        var session: ZMUserSession!
        sessionManager.loadSession(for: account, completion: {
            session = $0
        })

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        let context = session.managedObjectContext

        var user: ZMUser!
        var conversation: ZMConversation!
        session.perform {
            user = ZMUser.insertNewObject(in: session.managedObjectContext)
            user.remoteIdentifier = UUID()
            conversation = ZMConversation.insertNewObject(in: session.managedObjectContext)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertNil(user.domain)
        XCTAssertNil(conversation.domain)

        let domain = "example.domain.com"
        APIVersion.domain = domain

        let expectation = XCTestExpectation(description: "Migration completed")
        let delegate = MockSessionManagerDelegate()
        delegate.expectation = expectation
        sessionManager.delegate = delegate

        // When
        sessionManager.apiVersionResolverDetectedFederationHasBeenEnabled()

        XCTAssertTrue(delegate.didCallWillMigrateAccount)

        wait(for: [expectation], timeout: 15) // Timeout is subject to change

        // Then
        XCTAssertTrue(delegate.didCallDidChangeActiveUserSession)
        try session = XCTUnwrap(delegate.session)

        let migratedUser = ZMUser.fetch(with: user.remoteIdentifier, in: context)
        XCTAssertNotNil(migratedUser)
        XCTAssertEqual(migratedUser?.domain, domain)
        XCTAssertEqual(conversation.domain, domain)

        userSession = nil
    }

    private func addAccount(name: String, userIdentifier: UUID) -> Account {
        let account = Account(userName: name, userIdentifier: userIdentifier)
        let cookie = NSData.secureRandomData(ofLength: 16)
        sessionManager!.environment.cookieStorage(for: account).authenticationCookieData = cookie
        sessionManager!.accountManager.addOrUpdate(account)
        return account
    }
}

class MockSessionManagerDelegate: SessionManagerDelegate {

    var didCallWillMigrateAccount: Bool = false
    func sessionManagerWillMigrateAccount(userSessionCanBeTornDown: @escaping () -> Void) {
        didCallWillMigrateAccount = true
        userSessionCanBeTornDown()
    }

    var didCallDidReportLockChange: Bool = false

    var expectation: XCTestExpectation?
    func sessionManagerDidReportLockChange(forSession session: UserSessionAppLockInterface) {
        didCallDidReportLockChange = true
        expectation?.fulfill()
    }

    var didCallDidChangeActiveUserSession: Bool = false
    var session: ZMUserSession?
    func sessionManagerDidChangeActiveUserSession(userSession: ZMUserSession) {
        didCallDidChangeActiveUserSession = true
        session = userSession
        expectation?.fulfill()
    }

    func sessionManagerDidFailToLogin(error: Error?) {
        // no op
    }

    func sessionManagerWillLogout(error: Error?, userSessionCanBeTornDown: (() -> Void)?) {
        // no op
    }

    func sessionManagerWillOpenAccount(_ account: Account, from selectedAccount: Account?, userSessionCanBeTornDown: @escaping () -> Void) {
        // no op
    }

    func sessionManagerDidFailToLoadDatabase() {
        // no op
    }

    func sessionManagerDidBlacklistCurrentVersion(reason: BlacklistReason) {
        // no op
    }

    func sessionManagerDidBlacklistJailbrokenDevice() {
        // no op
    }

    var isInAuthenticatedAppState: Bool {
        return true
    }

    var isInUnathenticatedAppState: Bool {
        return false
    }

}
