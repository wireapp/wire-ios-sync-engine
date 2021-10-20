////
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
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
import LocalAuthentication
@testable import WireSyncEngine

class MockUserSessionDelegate: NSObject, UserSessionDelegate {
    
    var calledSetEncryptionAtRest: (Bool, Account, EncryptionKeys)?
    func setEncryptionAtRest(enabled: Bool, account: Account, encryptionKeys: EncryptionKeys) {
        calledSetEncryptionAtRest = (enabled, account, encryptionKeys)
    }

    func userSessionDidUnlock(_ session: ZMUserSession) {
        
    }
    
    func clientRegistrationDidSucceed(accountId: UUID) { }
    
    func clientRegistrationDidFail(_ error: NSError, accountId: UUID) { }
    
    var calleduserDidLogout: (Bool, UUID)?
    func userDidLogout(accountId: UUID) {
        calleduserDidLogout = (true, accountId)
    }
    
    func authenticationInvalidated(_ error: NSError, accountId : UUID) { }
}

class ZMUserSessionTests_EncryptionAtRest: ZMUserSessionTestsBase {

    private var account: Account {
        Account(userName: "", userIdentifier: ZMUser.selfUser(in: syncMOC).remoteIdentifier)
    }

    override func tearDown() {
        try! EncryptionKeys.deleteKeys(for: account)

        super.tearDown()
    }

    private func setEncryptionAtRest(enabled: Bool, file: StaticString = #file, line: UInt = #line) {
        try! sut.setEncryptionAtRest(enabled: true, skipMigration: true)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5), file: file, line: line)
    }
    
    // MARK: - Database migration
    
    // @SF.Storage @TSFI.UserInterface
    func testThatDelegateIsCalled_WhenEncryptionAtRestIsEnabled() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        let userSessionDelegate = MockUserSessionDelegate()
        sut.delegate = userSessionDelegate
        
        // when
        try sut.setEncryptionAtRest(enabled: true)
        
        // then
        XCTAssertNotNil(userSessionDelegate.calledSetEncryptionAtRest)
        XCTAssertEqual(userSessionDelegate.calledSetEncryptionAtRest?.0, true)
    }
    
    // @SF.Storage @TSFI.UserInterface
    func testThatDelegateIsCalled_WhenEncryptionAtRestIsDisabled() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: true)
        let userSessionDelegate = MockUserSessionDelegate()
        sut.delegate = userSessionDelegate
        
        // when
        try sut.setEncryptionAtRest(enabled: false)
        
        // then
        XCTAssertNotNil(userSessionDelegate.calledSetEncryptionAtRest)
        XCTAssertEqual(userSessionDelegate.calledSetEncryptionAtRest?.0, false)
    }
    
    // MARK: - Database locking/unlocking
    
    func testThatDatabaseIsUnlocked_WhenEncryptionAtRestIsDisabled() {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        
        // when
        setEncryptionAtRest(enabled: false)
        
        // then
        XCTAssertFalse(sut.isDatabaseLocked)
    }

    func testThatDatabaseIsUnlocked_AfterActivatingEncryptionAtRest() {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        
        // when
        setEncryptionAtRest(enabled: true)
        
        // then
        XCTAssertFalse(sut.isDatabaseLocked)
    }
    
    func testThatDatabaseIsUnlocked_AfterDeactivatingEncryptionAtRest() {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: true)
        
        // when
        setEncryptionAtRest(enabled: false)
        
        // then
        XCTAssertFalse(sut.isDatabaseLocked)
    }
        
    func testThatDatabaseIsUnlocked_AfterUnlockingDatabase() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: true)
        sut.applicationDidEnterBackground(nil)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        let context = LAContext()
        try sut.unlockDatabase(with: context)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertFalse(sut.isDatabaseLocked)
    }
    
    // @SF.Storage @TSFI.UserInterface
    func testThatDatabaseIsLocked_AfterEnteringBackground() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: true)
        
        // when
        sut.applicationDidEnterBackground(nil)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertTrue(sut.isDatabaseLocked)
    }

    // MARK: - Database lock handler/observer
    
    // @SF.Storage @TSFI.UserInterface
    func testThatDatabaseLockedHandlerIsCalled_AfterDatabaseIsLocked() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: true)
        
        // expect
        let databaseIsLocked = expectation(description: "database is locked")
        var token: Any? = sut.registerDatabaseLockedHandler { (isDatabaseLocked) in
            if isDatabaseLocked {
                databaseIsLocked.fulfill()
            }
        }
        XCTAssertNotNil(token)
        
        // when
        sut.applicationDidEnterBackground(nil)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // cleanup
        token = nil
    }
    
    func testThatDatabaseLockedHandlerIsCalled_AfterUnlockingDatabase() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: true)
        sut.applicationDidEnterBackground(nil)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // expect
        let databaseIsUnlocked = expectation(description: "database is unlocked")
        var token: Any? = sut.registerDatabaseLockedHandler { (isDatabaseLocked) in
            if !isDatabaseLocked {
                databaseIsUnlocked.fulfill()
            }
        }
        XCTAssertNotNil(token)
        
        // when
        let context = LAContext()
        try sut.unlockDatabase(with: context)
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // cleanup
        token = nil
    }

    // MARK: - Misc

    // @SF.Storage @TSFI.UserInterface
    func testThatOldEncryptionKeysAreReplaced_AfterActivatingEncryptionAtRest() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()

        let oldKeys = try EncryptionKeys.createKeys(for: account)

        // when
        setEncryptionAtRest(enabled: true)

        // then
        let newKeys = syncMOC.encryptionKeys

        XCTAssertFalse(sut.isDatabaseLocked)
        XCTAssertNotEqual(oldKeys, newKeys)
    }

    // @SF.Storage @TSFI.UserInterface
    func testThatIfDatabaseIsLocked_ThenUserSessionLockIsSet() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: true)

        sut.applicationDidEnterBackground(nil)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        XCTAssertTrue(sut.isDatabaseLocked)

        // then
        XCTAssertEqual(sut.lock, .database)
    }

    func testThatIfDatabaseIsNotLocked_ThenUserSessionLockIsNotSet() throws {
        // given
        simulateLoggedInUser()
        syncMOC.saveOrRollback()
        setEncryptionAtRest(enabled: false)
        XCTAssertFalse(sut.isDatabaseLocked)

        // then
        XCTAssertNotEqual(sut.lock, .database)
    }

}
