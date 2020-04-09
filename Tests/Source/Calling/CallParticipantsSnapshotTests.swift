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

class CallParticipantsSnapshotTests: MessagingTest {

    private typealias Sut = WireSyncEngine.CallParticipantsSnapshot

    var mockWireCallCenterV3: WireCallCenterV3Mock!
    var mockFlowManager: FlowManagerMock!

    private var aliceIphone: AVSClient!
    private var aliceDesktop: AVSClient!
    private var bobIphone: AVSClient!
    private var bobDesktop: AVSClient!

    override func setUp() {
        super.setUp()
        mockFlowManager = FlowManagerMock()
        mockWireCallCenterV3 = WireCallCenterV3Mock(userId: UUID(),
                                                    clientId: UUID().transportString(),
                                                    uiMOC: uiMOC,
                                                    flowManager: mockFlowManager,
                                                    transport: WireCallCenterTransportMock())

        let aliceId = UUID()
        let bobId = UUID()

        aliceIphone = AVSClient(userId: aliceId, clientId: "iphone")
        aliceDesktop = AVSClient(userId: aliceId, clientId: "desktop")
        bobIphone = AVSClient(userId: bobId, clientId: "iphone")
        bobDesktop = AVSClient(userId: bobId, clientId: "desktop")
    }
    
    override func tearDown() {
        mockFlowManager = nil
        mockWireCallCenterV3 = nil
        super.tearDown()
    }

    private func createSut(members: [AVSCallMember]) -> Sut {
        return Sut(conversationId: UUID(), members: members, callCenter: mockWireCallCenterV3)
    }

    // MARK: - Duplicates

    func testThat_ItDoesNotCrash_WhenInitialized_WithDuplicateCallMembers(){
        // Given
        let member1 = AVSCallMember(client: aliceIphone, audioState: .established)
        let member2 = AVSCallMember(client: aliceIphone, audioState: .connecting)

        // When
        let sut = createSut(members: [member1, member2])

        
        // Then
        XCTAssertEqual(sut.members.array, [member1])
    }
    
    func testThat_ItDoesNotCrash_WhenUpdated_WithDuplicateCallMembers(){
        // Given
        let member1 = AVSCallMember(client: aliceIphone, audioState: .established)
        let member2 = AVSCallMember(client: aliceIphone, audioState: .connecting)
        let sut = createSut(members: [])

        // when
        sut.callParticipantsChanged(participants: [member1, member2])
        
        // then
        XCTAssertEqual(sut.members.array, [member1])
    }

    func testThat_ItDoesNotConsider_AUserWithMultipleDevices_AsDuplicated() {
        // Given
        let member1 = AVSCallMember(client: aliceIphone, audioState: .established)
        let member2 = AVSCallMember(client: aliceDesktop, audioState: .connecting)

        // When
        let sut = createSut(members: [member1, member2])

        // Then
        XCTAssertEqual(sut.members.array, [member1, member2])
    }

    // MARK: - Network Quality

    func testThat_ItTakesTheWorstNetworkQuality_FromParticipants() {
        // Given
        let normalQuality = AVSCallMember(client: aliceIphone, networkQuality: .normal)
        let mediumQuality = AVSCallMember(client: aliceDesktop, networkQuality: .medium)
        let poorQuality = AVSCallMember(client: bobIphone, networkQuality: .poor)
        let problemQuality = AVSCallMember(client: bobDesktop, networkQuality: .problem)
        let sut = createSut(members: [])

        XCTAssertEqual(sut.networkQuality, .normal)

        // When, then
        sut.callParticipantsChanged(participants: [normalQuality])
        XCTAssertEqual(sut.networkQuality, .normal)

        // When, then
        sut.callParticipantsChanged(participants: [mediumQuality, normalQuality])
        XCTAssertEqual(sut.networkQuality, .medium)

        // When, then
        sut.callParticipantsChanged(participants: [poorQuality, normalQuality])
        XCTAssertEqual(sut.networkQuality, .poor)

        // When, then
        sut.callParticipantsChanged(participants: [poorQuality, normalQuality, problemQuality])
        XCTAssertEqual(sut.networkQuality, .problem)

        // When, then
        sut.callParticipantsChanged(participants: [mediumQuality, poorQuality])
        XCTAssertEqual(sut.networkQuality, .poor)
    }

    // MARK: - Updates

    func testThat_ItUpdatesNetworkQuality_WhenItChangesForParticipant() {
        // Given
        let member1 = AVSCallMember(client: aliceIphone, audioState: .established, networkQuality: .normal)
        let member2 = AVSCallMember(client: bobIphone, audioState: .established, networkQuality: .normal)
        let sut = createSut(members: [member1, member2])

        XCTAssertEqual(sut.networkQuality, .normal)

        // When, then
        sut.callParticipantNetworkQualityChanged(client: member1.client, networkQuality: .medium)
        XCTAssertEqual(sut.networkQuality, .medium)

        // When, then
        sut.callParticipantNetworkQualityChanged(client: member2.client, networkQuality: .poor)
        XCTAssertEqual(sut.networkQuality, .poor)

        // When, then
        sut.callParticipantNetworkQualityChanged(client: member1.client, networkQuality: .normal)
        sut.callParticipantNetworkQualityChanged(client: member2.client, networkQuality: .normal)
        XCTAssertEqual(sut.networkQuality, .normal)
    }

    func testThat_ItDoesNotUpdateNetworkQuality_WhenNoMatchFound() {
        // Given
        let member1 = AVSCallMember(client: aliceIphone, videoState: .stopped)
        let member2 = AVSCallMember(client: bobIphone, videoState: .stopped)
        let sut = createSut(members: [member1, member2])

        // When
        let unknownMember = AVSCallMember(client: aliceDesktop, videoState: .stopped)
        sut.callParticipantNetworkQualityChanged(client: unknownMember.client, networkQuality: .problem)

        // Then
        XCTAssertEqual(sut.members.array, [member1, member2])
    }


    func testThat_ItUpdatesAudioState_WhenItChangesForParticipant() {
        // Given
        let member1 = AVSCallMember(client: aliceIphone, audioState: .connecting)
        let member2 = AVSCallMember(client: bobIphone, audioState: .connecting)
        let sut = createSut(members: [member1, member2])

        // When
        let updatedMember1 = member1.with(audioState: .established)
        sut.callParticipantsChanged(participants: [updatedMember1, member2])

        // Then
        XCTAssertEqual(sut.members.array, [updatedMember1, member2])
    }

    func testThat_ItUpdatesVideoState_WhenItChangesForParticipant() {
        // Given
        let member1 = AVSCallMember(client: aliceIphone, videoState: .stopped)
        let member2 = AVSCallMember(client: bobIphone, videoState: .stopped)
        let sut = createSut(members: [member1, member2])

        // When
        let updatedMember1 = member1.with(videoState: .screenSharing)
        sut.callParticipantsChanged(participants: [updatedMember1, member2])

        // Then
        XCTAssertEqual(sut.members.array, [updatedMember1, member2])
    }

}

private extension AVSCallMember {

    func with(audioState: AudioState) -> AVSCallMember {
        return AVSCallMember(client: client,
                             audioState: audioState,
                             videoState: videoState,
                             networkQuality: networkQuality)
    }

    func with(videoState: VideoState) -> AVSCallMember {
        return AVSCallMember(client: client,
                             audioState: audioState,
                             videoState: videoState,
                             networkQuality: networkQuality)
    }

}
