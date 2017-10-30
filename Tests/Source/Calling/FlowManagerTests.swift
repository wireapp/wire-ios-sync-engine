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


import Foundation
@testable import WireSyncEngine

final fileprivate class FlowManagerMockDelegate: FlowManagerDelegate {
    func flowManagerDidUpdateVolume(_ volume: Double, for participantId: String, in conversationId: UUID) {
        // NO-OP
    }
}

class FlowManagerTests : MessagingTest {
    func testThatItSendsNotificationWhenFlowManagerIsCreated() {
        // GIVEN
        let sut = FlowManager(mediaManager: AVSMediaManager.default())
        let expectation = self.expectation(description: "Notification is sent")
        let notificationObserver = NotificationCenter.default.addObserver(forName: FlowManager.AVSFlowManagerCreatedNotification, object: sut, queue: nil) { _ in
            expectation.fulfill()
        }
        // WHEN
        sut.delegate = FlowManagerMockDelegate()
        // THEN
        XCTAssertTrue(self.waitForCustomExpectations(withTimeout: 0.5))
        NotificationCenter.default.removeObserver(notificationObserver)
    }
}
