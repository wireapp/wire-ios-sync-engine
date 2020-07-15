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

import Foundation
@testable import WireSyncEngine

class VoiceChannelV3Tests : MessagingTest {
    
    var wireCallCenterMock : WireCallCenterV3Mock? = nil
    var conversation : ZMConversation?
    var sut : VoiceChannelV3!
    
    override func setUp() {
        super.setUp()
        
        let selfUser = ZMUser.selfUser(in: uiMOC)
        selfUser.remoteIdentifier = UUID.create()
        
        let selfClient = createSelfClient()
        
        conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation?.remoteIdentifier = UUID.create()
        
        wireCallCenterMock = WireCallCenterV3Mock(userId: selfUser.remoteIdentifier!, clientId: selfClient.remoteIdentifier!, uiMOC: uiMOC, flowManager: FlowManagerMock(), transport: WireCallCenterTransportMock())
        
        uiMOC.zm_callCenter = wireCallCenterMock
        
        sut = VoiceChannelV3(conversation: conversation!)
    }
    
    override func tearDown() {
        super.tearDown()
        
        wireCallCenterMock = nil
    }
    
    func testThatItStartsACall_whenTheresNotAnIncomingCall() {
        // given
        wireCallCenterMock?.removeMockActiveCalls()
        
        // when
        _ = sut.join(video: false)
        
        // then
        XCTAssertTrue(wireCallCenterMock!.didCallStartCall)
    }
    
    func testThatItAnswers_whenTheresAnIncomingCall() {
        // given
        wireCallCenterMock?.setMockCallState(.incoming(video: false, shouldRing: false, degraded: false), conversationId: conversation!.remoteIdentifier!, callerId: UUID(), isVideo: false)

        // when
        _ = sut.join(video: false)
        
        // then
        XCTAssertTrue(wireCallCenterMock!.didCallAnswerCall)
    }
    
    func testThatItDoesntAnswer_whenTheresAnIncomingDegradedCall() {
        // given
        wireCallCenterMock?.setMockCallState(.incoming(video: false, shouldRing: false, degraded: true), conversationId: conversation!.remoteIdentifier!, callerId: UUID(), isVideo: false)

        // when
        _ = sut.join(video: false)
        
        // then
        XCTAssertFalse(wireCallCenterMock!.didCallAnswerCall)
    }

    func testThatItForwardsNetworkQualityFromCallCenter() {
        // given
        let caller = AVSClient(userId: UUID(), clientId: UUID().transportString())
        wireCallCenterMock?.setMockCallState(.established, conversationId: conversation!.remoteIdentifier!, callerId: caller.userId, isVideo: false)
        let quality = NetworkQuality.poor
        XCTAssertEqual(sut.networkQuality, .normal)

        // when

        wireCallCenterMock?.handleNetworkQualityChange(conversationId: conversation!.remoteIdentifier!, client: caller, quality: quality)
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(sut.networkQuality, quality)
    }

}
