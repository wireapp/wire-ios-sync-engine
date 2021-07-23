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

extension ZMOperationLoopTests {
    func testThatMOCIsSavedOnSuccessfulRequest() {
        // given
        let request = ZMTransportRequest(path: "/boo", method: .methodGET, payload: nil)
        request.add(ZMCompletionHandler(on:syncMOC,
                                        block: { [weak self] _ in
                                            _ = ZMClientMessage(nonce: NSUUID.create(), managedObjectContext: self!.syncMOC)
                                        }))
        mockRequestStrategy.mockRequest = request
        
        RequestAvailableNotification.notifyNewRequestsAvailable(self) // this will enqueue `request`
        _ = waitForAllGroupsToBeEmpty(withTimeout: 0.5)
        
        // expect
        expectation(
            forNotification: .NSManagedObjectContextDidSave,
            object: nil,
            handler: nil)
        
        // when
        let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil)
        request.complete(with: response)
        _ = waitForAllGroupsToBeEmpty(withTimeout: 0.5)
        
        // then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        
    }
    
    func testThatMOCIsSavedOnFailedRequest() {
        // given
        let request = ZMTransportRequest(path: "/boo", method: .methodGET, payload: nil)
        request.add(ZMCompletionHandler(on: syncMOC,
                                        block: { [weak self] _ in
                                            _ = ZMClientMessage(nonce: NSUUID.create(), managedObjectContext: self!.syncMOC)
                                        }))
        mockRequestStrategy.mockRequest = request
        
        RequestAvailableNotification.notifyNewRequestsAvailable(self) // this will enqueue `request`
        _ = waitForAllGroupsToBeEmpty(withTimeout: 0.5)
        
        // expect
        expectation(
            forNotification: .NSManagedObjectContextDidSave,
            object: nil,
            handler: nil)
        
        // when
        request.complete(with: ZMTransportResponse(payload: nil, httpStatus: 400, transportSessionError: nil))
        _ = waitForAllGroupsToBeEmpty(withTimeout: 0.5)
        
        // then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
}
