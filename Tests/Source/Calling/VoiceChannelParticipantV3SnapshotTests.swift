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

class VoiceChannelParticipantV3SnapshotTests : MessagingTest {

    var mockWireCallCenterV3 : WireCallCenterV3Mock!
    var mockFlowManager : FlowManagerMock!

    override func setUp() {
        super.setUp()
        mockFlowManager = FlowManagerMock()
        mockWireCallCenterV3 = WireCallCenterV3Mock(userId: UUID(), clientId: "foo", uiMOC: uiMOC, flowManager: mockFlowManager, transport: WireCallCenterTransportMock())
    }
    
    override func tearDown() {
        mockFlowManager = nil
        mockWireCallCenterV3 = nil
        super.tearDown()
    }

    func testThatItDoesNotCrashWhenInitializedWithDuplicateCallMembers(){
        // given
        let userId = UUID()
        let callMember1 = CallMember(userId: userId, audioEstablished: true)
        let callMember2 = CallMember(userId: userId, audioEstablished: false)

        // when
        let sut = WireSyncEngine.VoiceChannelParticipantV3Snapshot(callCenter: mockWireCallCenterV3,
                                                                   conversationId: UUID(),
                                                                   selfUserID: UUID(),
                                                                   members: [callMember1, callMember2])
        
        // then
        // it does not crash and
        XCTAssertEqual(sut.members.array.count, 1)
        if let first = sut.members.array.first {
            XCTAssertTrue(first.audioEstablished)
        }
    }
    
    func testThatItDoesNotCrashWhenUpdatedWithDuplicateCallMembers(){
        // given
        let userId = UUID()
        let callMember1 = CallMember(userId: userId, audioEstablished: true)
        let callMember2 = CallMember(userId: userId, audioEstablished: false)
        let sut = WireSyncEngine.VoiceChannelParticipantV3Snapshot(callCenter: mockWireCallCenterV3,
                                                                   conversationId: UUID(),
                                                                   selfUserID: UUID(),
                                                                   members: [])

        // when
        sut.callParticipantsChanged(newParticipants: [callMember1, callMember2])
        
        // then
        // it does not crash and
        XCTAssertEqual(sut.members.array.count, 1)
        if let first = sut.members.array.first {
            XCTAssertTrue(first.audioEstablished)
        }
    }
    
    func testThatItKeepsTheMemberWithAudioEstablished(){
        // given
        let userId = UUID()
        let callMember1 = CallMember(userId: userId, audioEstablished: false)
        let callMember2 = CallMember(userId: userId, audioEstablished: true)
        let sut = WireSyncEngine.VoiceChannelParticipantV3Snapshot(callCenter: mockWireCallCenterV3,
                                                                   conversationId: UUID(),
                                                                   selfUserID: UUID(),
                                                                   members: [])
        
        // when
        sut.callParticipantsChanged(newParticipants: [callMember1, callMember2])
        
        // then
        // it does not crash and
        XCTAssertEqual(sut.members.array.count, 1)
        if let first = sut.members.array.first {
            XCTAssertTrue(first.audioEstablished)
        }
    }
}
