//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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
import XCTest
import WireTesting
@testable import WireSyncEngine

public class ZMConversationAccessModeTests : MessagingTest {
    override public func setUp() {
        super.setUp()
        
        teamA = {
                let team = Team.insertNewObject(in: self.uiMOC)
                team.name = "Team A"
                team.remoteIdentifier = UUID()
                return team
        }()
        
        teamB = {
            let team = Team.insertNewObject(in: self.uiMOC)
            team.name = "Team B"
            team.remoteIdentifier = UUID()
            return team
        }()
    }
    
    override public func tearDown() {
        teamA = nil
        teamB = nil
        super.tearDown()
    }
    
    func testThatItGeneratesCorrectSetAccessModeRequest() {
        // given
        selfUser(options: SelfUserOptions(team: .teamA))
        let conversation = self.conversation(options: ConversationOptions(hasRemoteId: true, team: .teamA, isGroup: true))
        // when
        let request = WireSyncEngine.WirelessRequestFactory.set(allowGuests: true, for: conversation)
        // then
        XCTAssertEqual(request.method, .methodPUT)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/access")
        let payload = request.payload as! [String: AnyHashable]
        XCTAssertNotNil(payload)
        XCTAssertNotNil(payload["access"])
        XCTAssertEqual(Set(payload["access"] as! [String]), Set(["invite", "code"]))
        XCTAssertNotNil(payload["access_role"])
        XCTAssertEqual(payload["access_role"], "non_activated")
    }
    
    func testThatItGeneratesCorrectFetchLinkRequest() {
        // given
        selfUser(options: SelfUserOptions(team: .teamA))
        let conversation = self.conversation(options: ConversationOptions(hasRemoteId: true, team: .teamA, isGroup: true))
        // when
        let request = WireSyncEngine.WirelessRequestFactory.fetchLinkRequest(for: conversation)
        // then
        XCTAssertEqual(request.method, .methodGET)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertNil(request.payload)
    }
    
    func testThatItGeneratesCorrectCreateLinkRequest() {
        // given
        selfUser(options: SelfUserOptions(team: .teamA))
        let conversation = self.conversation(options: ConversationOptions(hasRemoteId: true, team: .teamA, isGroup: true))
        // when
        let request = WireSyncEngine.WirelessRequestFactory.createLinkRequest(for: conversation)
        // then
        XCTAssertEqual(request.method, .methodPOST)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertNil(request.payload)
    }
    
    func testThatItGeneratesCorrectDeleteLinkRequest() {
        // given
        selfUser(options: SelfUserOptions(team: .teamA))
        let conversation = self.conversation(options: ConversationOptions(hasRemoteId: true, team: .teamA, isGroup: true))
        // when
        let request = WireSyncEngine.WirelessRequestFactory.deleteLinkRequest(for: conversation)
        // then
        XCTAssertEqual(request.method, .methodDELETE)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertNil(request.payload)
    }
    
    enum ConversationOptionsTeam {
        case none
        case teamA
        case teamB
    }
    
    struct ConversationOptions {
        let hasRemoteId: Bool
        let team: ConversationOptionsTeam
        let isGroup: Bool
    }
    
    var teamA: Team!
    var teamB: Team!
    
    @discardableResult func createMembership(user: ZMUser, team: Team) -> Member {
        let member = Member.insertNewObject(in: self.uiMOC)
        member.user = user
        member.team = team
        return member
    }
    
    func conversation(options: ConversationOptions) -> ZMConversation {
        let conversation = ZMConversation.insertGroupConversation(into: self.uiMOC, withParticipants: [], name: "Test Conversation", in: nil)!
        if options.hasRemoteId {
            conversation.remoteIdentifier = UUID()
        }
        else {
            conversation.remoteIdentifier = nil
        }
        if options.isGroup {
            conversation.conversationType = .group
        }
        else {
            conversation.conversationType = .invalid
        }
        
        switch options.team {
        case .none: conversation.team = nil
        case .teamA:
            conversation.team = teamA
            conversation.teamRemoteIdentifier = teamA.remoteIdentifier
        case .teamB:
            conversation.team = teamB
            conversation.teamRemoteIdentifier = teamB.remoteIdentifier
        }
        
        return conversation
    }
    
    struct SelfUserOptions {
        let team: ConversationOptionsTeam
    }
    
    @discardableResult func selfUser(options: SelfUserOptions) -> ZMUser {
        let selfUser = ZMUser.selfUser(in: self.uiMOC)
        switch options.team {
        case .none:
            selfUser.membership?.team = nil
            selfUser.membership?.user = nil
            
        case .teamA: createMembership(user: selfUser, team: teamA)
        case .teamB: createMembership(user: selfUser, team: teamB)
        }
        
        return selfUser
    }
    
    struct TestCase {
        let conversationOptions: ConversationOptions
        let userOptions: SelfUserOptions
        let expectedResult: Bool
    }
    
    let cases: [TestCase] = [TestCase(conversationOptions: ConversationOptions(hasRemoteId: true,
                                                                               team: .teamA,
                                                                               isGroup: true),
                                      userOptions: SelfUserOptions(team: .teamA),
                                      expectedResult: true),
                             TestCase(conversationOptions: ConversationOptions(hasRemoteId: false,
                                                                               team: .teamA,
                                                                               isGroup: true),
                                      userOptions: SelfUserOptions(team: .teamA),
                                      expectedResult: false),
                             TestCase(conversationOptions: ConversationOptions(hasRemoteId: true,
                                                                               team: .teamB,
                                                                               isGroup: true),
                                      userOptions: SelfUserOptions(team: .teamA),
                                      expectedResult: false),
                             TestCase(conversationOptions: ConversationOptions(hasRemoteId: true,
                                                                               team: .teamA,
                                                                               isGroup: true),
                                      userOptions: SelfUserOptions(team: .teamB),
                                      expectedResult: false),
                             TestCase(conversationOptions: ConversationOptions(hasRemoteId: true,
                                                                               team: .none,
                                                                               isGroup: true),
                                      userOptions: SelfUserOptions(team: .teamA),
                                      expectedResult: false),
                             TestCase(conversationOptions: ConversationOptions(hasRemoteId: true,
                                                                               team: .teamA,
                                                                               isGroup: true),
                                      userOptions: SelfUserOptions(team: .none),
                                      expectedResult: false),
                             TestCase(conversationOptions: ConversationOptions(hasRemoteId: true,
                                                                               team: .teamA,
                                                                               isGroup: false),
                                      userOptions: SelfUserOptions(team: .teamA),
                                      expectedResult: false),
                             TestCase(conversationOptions: ConversationOptions(hasRemoteId: true,
                                                                               team: .teamA,
                                                                               isGroup: true),
                                      userOptions: SelfUserOptions(team: .none),
                                      expectedResult: false),
                             ]
    
    func testCanManageAccess() {
        cases.forEach { testCase in
            // given
            let _ = self.selfUser(options: testCase.userOptions)
            let conversation = self.conversation(options: testCase.conversationOptions)
            // when
            let result = conversation.canManageAccess
            // then
            XCTAssertEqual(result, testCase.expectedResult)
        }
        
    }
}

