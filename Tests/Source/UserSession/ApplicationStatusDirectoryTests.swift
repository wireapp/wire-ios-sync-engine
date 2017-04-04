//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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

@testable import zmessaging

class ApplicationStatusDirectoryTests : MessagingTest {
    
    var sut : ApplicationStatusDirectory!
    
    override func setUp() {
        super.setUp()
        
        let cookieStorage = ZMPersistentCookieStorage()
        let cookie = ZMCookie(managedObjectContext: syncMOC, cookieStorage: cookieStorage)
        let mockApplication = ApplicationMock()
        
        sut = ApplicationStatusDirectory(withManagedObjectContext: syncMOC, cookie: cookie!, requestCancellation: self, application: mockApplication, syncStateDelegate: self)
    }
    
    func testThatOperationStatusIsUpdatedWhenCallStarts() {
        // given
        let note = Notification(name: CallStateObserver.CallInProgressNotification, object: nil, userInfo: [CallStateObserver.CallInProgressKey : true ])
        
        // when
        NotificationCenter.default.post(note)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertTrue(sut.operationStatus.hasOngoingCall)
    }
    
    func testThatOperationStatusIsUpdatedWhenCallEnds() {
        // given
        sut.operationStatus.hasOngoingCall = true
        let note = Notification(name: CallStateObserver.CallInProgressNotification, object: nil, userInfo: [CallStateObserver.CallInProgressKey : false ])
        
        // when
        NotificationCenter.default.post(note)
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertFalse(sut.operationStatus.hasOngoingCall)
    }
    
}

extension ApplicationStatusDirectoryTests : ZMRequestCancellation {
    
    func cancelTask(with taskIdentifier: ZMTaskIdentifier) {
        // no-op
    }
    
}

extension ApplicationStatusDirectoryTests : ZMSyncStateDelegate {
    
    func didStartSync() {
        // no-op
    }
    
    func didFinishSync() {
        // no-op
    }
    
    func didRegister(_ userClient: UserClient!) {
        // no-op
    }
    
    
}
