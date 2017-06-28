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


import WireTesting
@testable import WireSyncEngine

class TeamDownloadRequestStrategy_EventsTests: MessagingTest {

    var sut: TeamDownloadRequestStrategy!
    var mockApplicationStatus : MockApplicationStatus!
    var mockSyncStatus : MockSyncStatus!
    var mockSyncStateDelegate: MockSyncStateDelegate!
    
    override func setUp() {
        super.setUp()
        mockApplicationStatus = MockApplicationStatus()
        mockSyncStateDelegate = MockSyncStateDelegate()
        mockSyncStatus = MockSyncStatus(managedObjectContext: syncMOC, syncStateDelegate: mockSyncStateDelegate)
        sut = TeamDownloadRequestStrategy(withManagedObjectContext: syncMOC, applicationStatus: mockApplicationStatus, syncStatus: mockSyncStatus)
        
        syncMOC.performGroupedBlockAndWait{
            let user = ZMUser.selfUser(in: self.syncMOC)
            user.remoteIdentifier = UUID()
        }
    }

    override func tearDown() {
        mockApplicationStatus = nil
        mockSyncStateDelegate = nil
        mockSyncStatus = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - Team Create
    // The team.create update event is only sent to the creator of the team

    func testThatItDoesNotCreateALocalTeamWhenReceivingTeamCreateUpdateEvent() {
        // given
        let teamId = UUID.create()
        let payload: [String: Any] = [
            "type": "team.create",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": NSNull()
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        XCTAssertNil(Team.fetchOrCreate(with: teamId, create: false, in: uiMOC, created: nil))
    }

    func testThatItDoesNotSetNeedsToBeUpdatedFromBackendForExistingTeamWhenReceivingTeamCreateUpdateEvent() {
        // given
        let teamId = UUID.create()

        syncMOC.performGroupedBlock {
            _ = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)
            XCTAssert(self.syncMOC.saveOrRollback())
        }

        let payload: [String: Any] = [
            "type": "team.create",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": NSNull()
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        guard let team = Team.fetchOrCreate(with: teamId, create: false, in: uiMOC, created: nil) else { return XCTFail("No team created") }
        XCTAssertFalse(team.needsToBeUpdatedFromBackend)
    }

    // MARK: - Team Delete 

    func testThatItDeletesAnExistingTeamWhenReceivingATeamDeleteUpdateEvent() {
        // given
        let teamId = UUID.create()

        syncMOC.performGroupedBlock {
            _ = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)
            XCTAssert(self.syncMOC.saveOrRollback())
        }

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertNotNil(Team.fetch(withRemoteIdentifier: teamId, in: uiMOC))

        let payload: [String: Any] = [
            "type": "team.delete",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": NSNull()
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        XCTAssertNil(Team.fetch(withRemoteIdentifier: teamId, in: uiMOC))
    }

    func testThatItDeltesATeamsConversationsWhenReceivingATeamDeleteUpdateEvent() {
        // given
        let conversationId = UUID.create()
        let teamId = UUID.create()

        syncMOC.performGroupedBlock {
            let team = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)
            let conversation = ZMConversation.insertNewObject(in: self.syncMOC)
            conversation.remoteIdentifier = conversationId
            conversation.team = team
            XCTAssert(self.syncMOC.saveOrRollback())
        }

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertNotNil(Team.fetch(withRemoteIdentifier: teamId, in: uiMOC))

        let payload: [String: Any] = [
            "type": "team.delete",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": NSNull()
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        XCTAssertNil(Team.fetch(withRemoteIdentifier: teamId, in: uiMOC))
        XCTAssertNil(ZMConversation.fetch(withRemoteIdentifier: conversationId, in: uiMOC))
    }

    // MARK: - Team Update

    func testThatItUpdatesATeamsNameWhenReceivingATeamUpdateUpdateEvent() {
        // given
        let dataPayload = ["name": "Wire GmbH"]

        // when
        guard let team = assertThatItUpdatesTeamsProperties(with: dataPayload) else { return XCTFail("No Team") }

        // then
        XCTAssertEqual(team.name, "Wire GmbH")
    }

    func testThatItUpdatesATeamsIconWhenReceivingATeamUpdateUpdateEvent() {
        // given
        let newAssetId = UUID.create().transportString()
        let dataPayload = ["icon": newAssetId]

        // when
        guard let team = assertThatItUpdatesTeamsProperties(with: dataPayload) else { return XCTFail("No Team") }

        // then
        XCTAssertEqual(team.pictureAssetId, newAssetId)
    }

    func testThatItUpdatesATeamsIconKeyWhenReceivingATeamUpdateUpdateEvent() {
        // given
        let newAssetKey = UUID.create().transportString()
        let dataPayload = ["icon_key": newAssetKey]

        // when
        guard let team = assertThatItUpdatesTeamsProperties(with: dataPayload) else { return XCTFail("No Team") }

        // then
        XCTAssertEqual(team.pictureAssetKey, newAssetKey)
    }

    func assertThatItUpdatesTeamsProperties(
        with dataPayload: [String: Any]?,
        preExistingTeam: Bool = true,
        file: StaticString = #file,
        line: UInt = #line) -> Team? {

        // given
        let teamId = UUID.create()

        if preExistingTeam {
            syncMOC.performGroupedBlock {
                let team = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)!
                team.name = "Some Team"
                team.remoteIdentifier = teamId
                team.pictureAssetId = UUID.create().transportString()
                team.pictureAssetKey = UUID.create().transportString()
                XCTAssert(self.syncMOC.saveOrRollback())
            }

            XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1), file: file, line: line)
            XCTAssertNotNil(Team.fetchOrCreate(with: teamId, create: false, in: uiMOC, created: nil))
        }

        let payload: [String: Any] = [
            "type": "team.update",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": dataPayload ?? NSNull()
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        return Team.fetchOrCreate(with: teamId, create: false, in: uiMOC, created: nil)
    }

    func testThatItDoesNotCreateATeamIfItDoesNotAlreadyExistWhenReceivingATeamUpdateUpdateEvent() {
        // given
        let dataPayload = ["name": "Wire GmbH"]

        // then
        XCTAssertNil(assertThatItUpdatesTeamsProperties(with: dataPayload, preExistingTeam: false))
    }

    // MARK: - Team Member-Join

    func testThatItAddsANewTeamMemberAndUserWhenReceivingATeamMemberJoinUpdateEventExistingTeam() {
        // given
        let teamId = UUID.create()
        let userId = UUID.create()

        syncMOC.performGroupedBlock {
            _ = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)!
            XCTAssert(self.syncMOC.saveOrRollback())
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        let payload: [String: Any] = [
            "type": "team.member-join",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        guard let user = ZMUser.fetch(withRemoteIdentifier: userId, in: uiMOC) else { return XCTFail("No user") }
        guard let team = Team.fetch(withRemoteIdentifier: teamId, in: uiMOC) else { return XCTFail("No team") }
        guard let member = user.membership else { return XCTFail("No member") }

        XCTAssert(user.needsToBeUpdatedFromBackend)
        XCTAssert(member.needsToBeUpdatedFromBackend)
        XCTAssertFalse(team.needsToBeUpdatedFromBackend)
        XCTAssertFalse(team.needsToRedownloadMembers)
        XCTAssertEqual(member.team, team)
    }

    func testThatItAddsANewTeamMemberToAnExistingUserWhenReceivingATeamMemberJoinUpdateEventExistingTeam() {
        // given
        let teamId = UUID.create()
        let userId = UUID.create()

        syncMOC.performGroupedBlockAndWait {
            let user = ZMUser.insertNewObject(in: self.syncMOC)
            user.remoteIdentifier = userId
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = teamId
            XCTAssert(self.syncMOC.saveOrRollback())
        }

        let payload: [String: Any] = [
            "type": "team.member-join",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            guard let user = ZMUser.fetch(withRemoteIdentifier: userId, in: self.syncMOC) else { return XCTFail("No user") }
            guard let team = Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC) else { return XCTFail("No team") }
            guard let member = user.membership else { return XCTFail("No member") }

            XCTAssert(user.needsToBeUpdatedFromBackend)
            XCTAssert(member.needsToBeUpdatedFromBackend)
            XCTAssertFalse(team.needsToBeUpdatedFromBackend)
            XCTAssertFalse(team.needsToRedownloadMembers)
            XCTAssertEqual(member.team, team)
        }
    }

    func testThatItAddsANewTeamMemberAndUserToAnExistingUserWhenReceivingATeamMemberJoinUpdateEventExistingTeam() {
        // given
        let teamId = UUID.create()
        let userId = UUID.create()

        syncMOC.performGroupedBlockAndWait {
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = teamId
            XCTAssert(self.syncMOC.saveOrRollback())
        }

        let payload: [String: Any] = [
            "type": "team.member-join",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            guard let user = ZMUser.fetch(withRemoteIdentifier: userId, in: self.syncMOC) else { return XCTFail("No user") }
            guard let team = Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC) else { return XCTFail("No team") }
            guard let member = user.membership else { return XCTFail("No member") }

            XCTAssert(user.needsToBeUpdatedFromBackend)
            XCTAssert(member.needsToBeUpdatedFromBackend)
            XCTAssertFalse(team.needsToBeUpdatedFromBackend)
            XCTAssertFalse(team.needsToRedownloadMembers)
            XCTAssertEqual(member.team, team)
        }
    }

    func testThatItDoesNotCreateALocalTeamWhenReceivingAMemberJoinEventForTheSelfUserWithoutExistingTeam() {
        // given
        let teamId = UUID.create()
        let userId = UUID.create()

        let payload: [String: Any] = [
            "type": "team.member-join",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            XCTAssertNil(ZMUser.fetch(withRemoteIdentifier: userId, in: self.syncMOC))
            XCTAssertNil(Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC))
        }
    }

    func testThatItFlagsAddedTeamMembersToBeRefetchedWhenItReceivesAMemberJoinForTheSelfUserEvenIfThereWasALocalTeam() {
        // given
        let teamId = UUID.create()
        var userId: UUID!

        syncMOC.performGroupedBlockAndWait {
            let user = ZMUser.selfUser(in: self.syncMOC)
            userId = user.remoteIdentifier
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = teamId
            XCTAssert(self.syncMOC.saveOrRollback())
        }

        let payload: [String: Any] = [
            "type": "team.member-join",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            guard let team = Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC) else { return XCTFail("No team") }
            XCTAssertFalse(team.needsToRedownloadMembers)
            guard let member = Member.fetch(withRemoteIdentifier: userId, in: self.syncMOC) else { return XCTFail("No member") }
            XCTAssert(member.needsToBeUpdatedFromBackend)
        }
    }

    // MARK: - Team Member-Leave

    func testThatItDeletesAMemberWhenReceivingATeamMemberLeaveUpdateEventForAnotherUser() {
        // given
        let teamId = UUID.create()
        let userId = UUID.create()

        syncMOC.performGroupedBlock {
            let user = ZMUser.insertNewObject(in: self.syncMOC)
            user.remoteIdentifier = userId
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = teamId
            let member = Member.getOrCreateMember(for: user, in: team, context: self.syncMOC)
            XCTAssertNotNil(member)
            XCTAssertEqual(user.membership, member)
            XCTAssert(self.syncMOC.saveOrRollback())
        }

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        let payload: [String: Any] = [
            "type": "team.member-leave",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            XCTAssertNotNil(ZMUser.fetch(withRemoteIdentifier: userId, in: self.syncMOC))

            // users won't be deleted as we might be in other (non-team) conversations with them
            guard let team = Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC) else { return XCTFail("No team") }
            XCTAssertEqual(team.members, [])
        }
    }

    func testThatItDeletesTheSelfMemberWhenReceivingATeamMemberLeaveUpdateEventForSelfUser() {
        let teamId = UUID.create()
        var userId: UUID!

        syncMOC.performGroupedBlockAndWait {
            // given
            let user = ZMUser.selfUser(in: self.syncMOC)
            userId = user.remoteIdentifier!
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = teamId
            let member = Member.getOrCreateMember(for: user, in: team, context: self.syncMOC)
            XCTAssertNotNil(member)
            XCTAssertEqual(user.membership, member)
        }

        // when
        let payload: [String: Any] = [
            "type": "team.member-leave",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            XCTAssertNotNil(ZMUser.fetch(withRemoteIdentifier: userId, in: self.syncMOC))
            XCTAssertNil(Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC))
        }
    }

    func testThatItRemovesAMemberFromAllTeamConversationsSheWasPartOfWhenReceivingAMemberLeaveForThatMember() {
        let teamId = UUID.create()
        let teamConversationId = UUID.create(), conversationId = UUID.create()
        let userId = UUID.create()

        syncMOC.performGroupedBlockAndWait {
            // given
            let user = ZMUser.insertNewObject(in: self.syncMOC)
            user.remoteIdentifier = userId
            let otherUser = ZMUser.insertNewObject(in: self.syncMOC)
            otherUser.remoteIdentifier = .create()
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = teamId
            let teamConversation1 = ZMConversation.insertNewObject(in: self.syncMOC)
            teamConversation1.remoteIdentifier = teamConversationId
            teamConversation1.conversationType = .group
            teamConversation1.addParticipant(user)
            teamConversation1.team = team
            let conversation = ZMConversation.insertGroupConversation(into: self.syncMOC, withParticipants: [user, otherUser])
            conversation?.remoteIdentifier = conversationId
            let member = Member.getOrCreateMember(for: user, in: team, context: self.syncMOC)
            XCTAssertNotNil(member)
            XCTAssertEqual(user.membership, member)
        }

        // when
        let payload: [String: Any] = [
            "type": "team.member-leave",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["user" : userId.transportString()]
        ]
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            guard let user = ZMUser.fetch(withRemoteIdentifier: userId, in: self.syncMOC) else { return XCTFail("No User") }
            guard Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC) != nil else { return XCTFail("No User") }
            XCTAssertNil(user.membership)
            guard let teamConversation = ZMConversation.fetch(withRemoteIdentifier: teamConversationId, in: self.syncMOC) else { return XCTFail("No Team Conversation") }
            guard let conversation = ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC) else { return XCTFail("No Conversation") }
            XCTAssertFalse(teamConversation.otherActiveParticipants.contains(user))
            XCTAssert(conversation.otherActiveParticipants.contains(user))
        }
    }
    
    func testThatItAppendsASystemMessageToAllTeamConversationsSheWasPartOfWhenReceivingAMemberLeaveForThatMember() {
        let teamId = UUID.create()
        let teamConversationId = UUID.create(), teamAnotherConversationId = UUID.create(), conversationId = UUID.create()
        let userId = UUID.create()
        
        syncMOC.performGroupedBlockAndWait {
            // given
            let user = ZMUser.insertNewObject(in: self.syncMOC)
            user.remoteIdentifier = userId
            let otherUser = ZMUser.insertNewObject(in: self.syncMOC)
            otherUser.remoteIdentifier = .create()
            
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = teamId
            
            let teamConversation1 = ZMConversation.insertNewObject(in: self.syncMOC)
            teamConversation1.remoteIdentifier = teamConversationId
            teamConversation1.conversationType = .group
            teamConversation1.addParticipant(user)
            teamConversation1.team = team
            
            let teamConversation2 = ZMConversation.insertNewObject(in: self.syncMOC)
            teamConversation2.remoteIdentifier = teamAnotherConversationId
            teamConversation2.conversationType = .group
            teamConversation2.addParticipant(user)
            teamConversation2.team = team

            
            let conversation = ZMConversation.insertGroupConversation(into: self.syncMOC, withParticipants: [user, otherUser])
            conversation?.remoteIdentifier = conversationId
            let member = Member.getOrCreateMember(for: user, in: team, context: self.syncMOC)
            XCTAssertNotNil(member)
            XCTAssertEqual(user.membership, member)
        }
        
        // when
        let timestamp = Date(timeIntervalSinceNow: -30)
        let payload: [String: Any] = [
            "type": "team.member-leave",
            "team": teamId.transportString(),
            "time": timestamp.transportString(),
            "data": ["user" : userId.transportString()]
        ]
        processEvent(fromPayload: payload)
        
        // then
        syncMOC.performGroupedBlockAndWait {
            guard let user = ZMUser.fetch(withRemoteIdentifier: userId, in: self.syncMOC) else { return XCTFail("No User") }
            guard Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC) != nil else { return XCTFail("No User") }
            XCTAssertNil(user.membership)
            guard let teamConversation = ZMConversation.fetch(withRemoteIdentifier: teamConversationId, in: self.syncMOC) else { return XCTFail("No Team Conversation") }
            guard let teamAnotherConversation = ZMConversation.fetch(withRemoteIdentifier: teamAnotherConversationId, in: self.syncMOC) else { return XCTFail("No Team Conversation") }
            guard let conversation = ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC) else { return XCTFail("No Conversation") }
            
            self.checkLastMessage(in: teamConversation, isLeaveMessageFor: user, at: timestamp)
            self.checkLastMessage(in: teamAnotherConversation, isLeaveMessageFor: user, at: timestamp)
            
            if let lastMessage = conversation.messages.lastObject as? ZMSystemMessage, lastMessage.systemMessageType == .teamMemberLeave {
                XCTFail("Should not append leave message to regular conversation")
            }
        }
    }
    
    private func checkLastMessage(in conversation: ZMConversation, isLeaveMessageFor user: ZMUser, at timestamp: Date,  file: StaticString = #file, line: UInt = #line) {
        guard let lastMessage = conversation.messages.lastObject as? ZMSystemMessage else { XCTFail("Last message is not system message", file: file, line: line); return }
        guard lastMessage.systemMessageType == .teamMemberLeave else { XCTFail("System message is not teamMemberLeave: but '\(lastMessage.systemMessageType.rawValue)'", file: file, line: line); return }
        guard let serverTimestamp = lastMessage.serverTimestamp else { XCTFail("System message should have timestamp", file: file, line: line); return }
        XCTAssertEqualWithAccuracy(serverTimestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.1, file: file, line: line)
        return
    }

    // MARK: - Team Conversation-Create

    func testThatItCreatesANewTeamConversationWhenReceivingATeamConversationCreateUpdateEvent() {
        // given
        let conversationId = UUID.create()
        let teamId = UUID.create()

        syncMOC.performGroupedBlockAndWait {
            _ = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)
        }

        let payload: [String: Any] = [
            "type": "team.conversation-create",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["conv": conversationId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            guard let conversation = ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC) else { return XCTFail("No conversation") }
            XCTAssertNotNil(conversation.team)
            XCTAssertEqual(conversation.team?.remoteIdentifier, teamId)
            XCTAssertTrue(conversation.needsToBeUpdatedFromBackend)
        }
    }

    func testThatItDoesNotCreateANewTeamConversationWhenReceivingATeamConversationCreateEventWithoutLocalTeam() {
        // given
        let conversationId = UUID.create()
        let teamId = UUID.create()

        let payload: [String: Any] = [
            "type": "team.conversation-create",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["conv": conversationId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            XCTAssertNil(ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC))
            XCTAssertNil(Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC))
        }
    }

    // MARK: - Team Conversation-Delete (Member)

    func testThatItDeletesALocalTeamConversationInWhichSelfIsAMember() {
        // given
        let conversationId = UUID.create()
        let teamId = UUID.create()

        syncMOC.performGroupedBlockAndWait {
            let team = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)
            let conversation = ZMConversation.insertNewObject(in: self.syncMOC)
            conversation.remoteIdentifier = conversationId
            conversation.conversationType = .group
            conversation.team = team

            XCTAssertNotNil(ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC))
            XCTAssertNotNil(Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC))
        }

        let payload: [String: Any] = [
            "type": "team.conversation-delete",
            "team": teamId.transportString(),
            "time": Date().transportString(),
            "data": ["conv": conversationId.transportString()]
        ]

        // when
        processEvent(fromPayload: payload)

        // then
        syncMOC.performGroupedBlockAndWait {
            XCTAssertNil(ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC))
            XCTAssertNotNil(Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC))
        }
    }

    func testThatItDoesNotDeleteALocalConversationIfTheTeamDoesNotMatchTheTeamInTheEventPayload() {
        // given
        let conversationId = UUID.create()
        let teamId = UUID.create()
        let otherTeamId = UUID.create()

        syncMOC.performGroupedBlockAndWait {
            let team = Team.fetchOrCreate(with: teamId, create: true, in: self.syncMOC, created: nil)
            _ = Team.fetchOrCreate(with: otherTeamId, create: true, in: self.syncMOC, created: nil)
            let conversation = ZMConversation.insertNewObject(in: self.syncMOC)
            conversation.remoteIdentifier = conversationId
            conversation.conversationType = .group
            conversation.team = team

            XCTAssertNotNil(ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC))
            XCTAssertNotNil(Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC))
        }

        let payload: [String: Any] = [
            "type": "team.conversation-delete",
            "team": otherTeamId.transportString(),
            "time": Date().transportString(),
            "data": ["conv": conversationId.transportString()]
        ]

        // when
        performIgnoringZMLogError {
            self.processEvent(fromPayload: payload)
        }

        // then
        syncMOC.performGroupedBlockAndWait {
            guard let conversation = ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC) else { return XCTFail("No conversation") }
            XCTAssertEqual(conversation.team?.remoteIdentifier, teamId)
            XCTAssertNotNil(Team.fetch(withRemoteIdentifier: teamId, in: self.syncMOC))
        }
    }

    // MARK: - Conversation-Delete (Guest)

    func disabled_testThatItDeletesALocalTeamConversationInWhichSelfIsAGuest() {
        // given
        let conversationId = UUID.create()
        let payload: [String: Any] = [
            "type": "conversation-delete",
            "time": Date().transportString(),
            "data": ["conv": conversationId.transportString()]
        ]

        syncMOC.performGroupedBlockAndWait {
            let conversation = ZMConversation.insertNewObject(in: self.syncMOC)
            conversation.remoteIdentifier = conversationId
            conversation.conversationType = .group
            XCTAssertNotNil(ZMConversation.fetch(withRemoteIdentifier: conversationId, in: self.syncMOC))
        }

        // when
        processEvent(fromPayload: payload)

        XCTFail("Implement and test behaviour when self is a guest in a team conversation which gets deleted.")
    }

    // MARK: - Helper

    private func processEvent(fromPayload eventPayload: [String: Any], file: StaticString = #file, line: UInt = #line) {
        guard let event = ZMUpdateEvent(fromEventStreamPayload: eventPayload as ZMTransportData, uuid: nil) else {
            return XCTFail("Unable to create update event from payload", file: file, line: line)
        }

        // when
        syncMOC.performGroupedBlock {
            self.sut.processEvents([event], liveEvents: false, prefetchResult: nil)
            XCTAssert(self.syncMOC.saveOrRollback(), file: file, line: line)
        }

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5), file: file, line: line)
    }

}
