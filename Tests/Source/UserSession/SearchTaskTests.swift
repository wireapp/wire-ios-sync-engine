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

class SearchTaskTests : MessagingTest {
    
    
    func createConnectedUser(withName name: String) -> ZMUser {
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.name = name
        user.remoteIdentifier = UUID.create()
        
        let connection = ZMConnection.insertNewObject(in: uiMOC)
        connection.to = user
        connection.status = .accepted
        
        uiMOC.saveOrRollback()
        
        return user
    }
    
    func createGroupConversation(withName name: String) -> ZMConversation {
        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.userDefinedName = name
        conversation.conversationType = .group
        
        uiMOC.saveOrRollback()
        
        return conversation
    }
    
    // MARK: Contacts Search

    func testThatItFindsASingleUser() {
        
        // given
        let resultArrived = expectation(description: "received result")
        let user = createConnectedUser(withName: "userA")
        
        let request = SearchRequest(query: "userA", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertTrue(result.contacts.contains(user))
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItDoesNotFindUsersContainingButNotBeginningWithSearchString() {
        // given
        let resultArrived = expectation(description: "received result")
        _ = createConnectedUser(withName: "userA")
        
        let request = SearchRequest(query: "serA", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.contacts.count, 0)
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItFindsUsersBeginningWithSearchString() {
        // given
        let resultArrived = expectation(description: "received result")
        let user = createConnectedUser(withName: "userA")
        
        let request = SearchRequest(query: "user", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertTrue(result.contacts.contains(user))
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItUsesAllQueryComponentsToFindAUser() {
        // given
        let resultArrived = expectation(description: "received result")
        let user1 = createConnectedUser(withName: "Some Body")
        _ = createConnectedUser(withName: "Some")
        _ = createConnectedUser(withName: "Any Body")
        
        let request = SearchRequest(query: "Some Body", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.contacts, [user1])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItFindsSeveralUsers() {
        // given
        let resultArrived = expectation(description: "received result")
        let user1 = createConnectedUser(withName: "Grant")
        let user2 = createConnectedUser(withName: "Greg")
        _ = createConnectedUser(withName: "Bob")
        
        let request = SearchRequest(query: "Gr", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.contacts, [user1, user2])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatUserSearchIsCaseInsensitive() {
        // given
        let resultArrived = expectation(description: "received result")
        let user1 = createConnectedUser(withName: "Somebody")
        
        let request = SearchRequest(query: "someBodY", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.contacts, [user1])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatUserSearchIsInsensitiveToDiacritics() {
        // given
        let resultArrived = expectation(description: "received result")
        let user1 = createConnectedUser(withName: "Sömëbodÿ")
        
        let request = SearchRequest(query: "Sømebôdy", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.contacts, [user1])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatUserSearchOnlyReturnsConnectedUsers() {
        // given
        let resultArrived = expectation(description: "received result")
        let user1 = createConnectedUser(withName: "Somebody Blocked")
        user1.block()
        let user2 = createConnectedUser(withName: "Somebody Pending")
        user2.connection?.status = .pending
        let user3 = createConnectedUser(withName: "Somebody")
        
        let request = SearchRequest(query: "Some", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.contacts, [user3])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItDoesNotReturnTheSelfUser() {
        // given
        let resultArrived = expectation(description: "received result")
        let selfUser = ZMUser.selfUser(in: uiMOC)
        selfUser.name = "Some self user"
        let user = createConnectedUser(withName: "Somebody")
        
        let request = SearchRequest(query: "Some", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.contacts, [user])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItCanSearchForTeamMembers() {
        // given
        let resultArrived = expectation(description: "received result")
        let team = Team.insertNewObject(in: uiMOC)
        let user = ZMUser.insertNewObject(in: uiMOC)
        let member = Member.insertNewObject(in: uiMOC)
        
        user.name = "Member A"
        
        member.team = team
        member.user = user
        
        uiMOC.saveOrRollback()
        
        let request = SearchRequest(query: "@member", searchOptions: [.teamMembers], team: team)
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.teamMembers, [member])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    // MARK: Conversation Search
    
    func testThatItFindsASingleConversation() {
        // given
        let resultArrived = expectation(description: "received result")
        let conversation = createGroupConversation(withName: "Somebody")
        
        let request = SearchRequest(query: "Somebody", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItDoesNotFindConversationsUsingPartialNames() {
        // given
        let resultArrived = expectation(description: "received result")
        _ = createGroupConversation(withName: "Somebody")
        
        let request = SearchRequest(query: "mebo", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    
    func testThatItFindsSeveralConversations() {
        // given
        let resultArrived = expectation(description: "received result")
        let conversation1 = createGroupConversation(withName: "Candy Apple Records")
        let conversation2 = createGroupConversation(withName: "Landspeed Records")
        _ = createGroupConversation(withName: "New Day Rising")
        
        let request = SearchRequest(query: "Records", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation1, conversation2])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatConversationSearchIsCaseInsensitive() {
        // given
        let resultArrived = expectation(description: "received result")
        let conversation = createGroupConversation(withName: "SoMEBody")
        
        let request = SearchRequest(query: "someBodY", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatConversationSearchIsInsensitiveToDiacritics() {
        // given
        let resultArrived = expectation(description: "received result")
        let conversation = createGroupConversation(withName: "Sömëbodÿ")
        
        let request = SearchRequest(query: "Sømebôdy", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItOnlyFindsGroupConversations() {
        // given
        let resultArrived = expectation(description: "received result")
        let groupConversation = createGroupConversation(withName: "Group Conversation")
        let oneOnOneConversation = createGroupConversation(withName: "OneOnOne Conversation")
        oneOnOneConversation.conversationType = .oneOnOne
        let selfConversation = createGroupConversation(withName: "Self Conversation")
        selfConversation.conversationType = .self
        
        uiMOC.saveOrRollback()
        
        let request = SearchRequest(query: "Conversation", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [groupConversation])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItFindsConversationsThatDoNotHaveAUserDefinedName() {
        // given
        let resultArrived = expectation(description: "received result")
        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.conversationType = .group
        
        let user1 = createConnectedUser(withName: "Shinji")
        let user2 = createConnectedUser(withName: "Asuka")
        let user3 = createConnectedUser(withName: "Rëï")
        
        conversation.addParticipant(user1)
        conversation.addParticipant(user2)
        conversation.addParticipant(user3)
        
        uiMOC.saveOrRollback()
        
        let request = SearchRequest(query: "Rei", searchOptions: [.conversations, .contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation])
            XCTAssertEqual(result.contacts, [user3])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItFindsConversationsThatContainsSearchTermOnlyInParticipantName() {
        // given
        let resultArrived = expectation(description: "received result")
        let conversation = createGroupConversation(withName: "Summertime")
        let user = createConnectedUser(withName: "Rëï")
        conversation.addParticipant(user)
        
        uiMOC.saveOrRollback()
        
        let request = SearchRequest(query: "Rei", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItOrdersConversationsByUserDefinedName() {
        // given
        let resultArrived = expectation(description: "received result")
        let conversation1 = createGroupConversation(withName: "FooA")
        let conversation2 = createGroupConversation(withName: "FooC")
        let conversation3 = createGroupConversation(withName: "FooB")
        
        let request = SearchRequest(query: "Foo", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation1, conversation3, conversation2])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItOrdersConversationsByUserDefinedNameFirstAndByParticipantNameSecond() {
        // given
        let resultArrived = expectation(description: "received result")
        let user1 = createConnectedUser(withName: "Bla")
        let user2 = createConnectedUser(withName: "FooB")
        
        let conversation1 = createGroupConversation(withName: "FooA")
        let conversation2 = createGroupConversation(withName: "Bar")
        let conversation3 = createGroupConversation(withName: "FooB")
        let conversation4 = createGroupConversation(withName: "Bar")
        
        conversation2.addParticipant(user1)
        conversation4.addParticipant(user1)
        conversation4.addParticipant(user2)
        
        uiMOC.saveOrRollback()
        
        let request = SearchRequest(query: "Foo", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation1, conversation3, conversation4])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItFiltersConversationWhenTheQueryStartsWithAtSymbol() {
        // given
        let resultArrived = expectation(description: "received result")
        _ = createGroupConversation(withName: "New Day Rising")
        _ = createGroupConversation(withName: "Landspeed Records")
        
        let request = SearchRequest(query: "@records", searchOptions: [.conversations])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItOnlyReturnsTeamConversationsWhenPassingTeamParameter() {
        // given
        let resultArrived = expectation(description: "received result")
        let team = Team.insertNewObject(in: uiMOC)
        let conversation = createGroupConversation(withName: "Beach Club")
        _ = createGroupConversation(withName: "Beach Club")
        
        conversation.team = team
        
        uiMOC.saveOrRollback()
        
        let request = SearchRequest(query: "Beach", searchOptions: [.conversations], team: team)
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.conversations, [conversation])
        }
        
        // when
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    // MARK: Directory Search
    
    func testThatItSendsASearchRequest() {
        // given
        let request = SearchRequest(query: "Steve O'Hara & Söhne", searchOptions: [.directory])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // when
        task.performRemoteSearch()
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().first?.path, "/search/contacts?q=Steve%20O'Hara%20%26%20S%C3%B6hne&size=10")
    }
    
    func testThatItDoesNotSendASearchRequestIfSeachingLocally() {
        // given
        let request = SearchRequest(query: "Steve O'Hara & Söhne", searchOptions: [.contacts])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // when
        task.performRemoteSearch()
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 0)
    }
    
    func testThatItEncodesAPlusCharacterInTheSearchURL() {
        // given
        let request = SearchRequest(query: "foo+bar@example.com", searchOptions: [.directory])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // when
        task.performRemoteSearch()
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().first?.path, "/search/contacts?q=foo%2Bbar@example.com&size=10")
    }
    
    func testThatItEncodesUnsafeCharactersInRequest() {
        // RFC 3986 Section 3.4 "Query"
        // <https://tools.ietf.org/html/rfc3986#section-3.4>
        //
        // "The characters slash ("/") and question mark ("?") may represent data within the query component."
        
        // given
        let request = SearchRequest(query: "$&+,/:;=?@", searchOptions: [.directory])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // when
        task.performRemoteSearch()
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().first?.path, "/search/contacts?q=$%26%2B,/:;%3D?@&size=10")
    }
    
    func testThatItCallsCompletionHandlerForDirectorySearch() {
        // given
        let resultArrived = expectation(description: "received result")
        let request = SearchRequest(query: "User", searchOptions: [.directory])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        mockTransportSession.performRemoteChanges { (remoteChanges) in
            remoteChanges.insertUser(withName: "User A")
        }
        
        // expect
        task.onResult { (result) in
            resultArrived.fulfill()
            XCTAssertEqual(result.directory.first?.name, "User A")
        }
        
        // when
        task.performRemoteSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    // MARK: Combined results
    
    func testThatRemoteResultsIncludePreviousLocalResults() {
        // given
        let localResultArrived = expectation(description: "received local result")
        let remoteResultArrived = expectation(description: "received remote result")
        let user = createConnectedUser(withName: "userA")
        
        mockTransportSession.performRemoteChanges { (remoteChanges) in
            remoteChanges.insertUser(withName: "UserB")
        }
        
        let request = SearchRequest(query: "user", searchOptions: [.contacts, .directory])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            
            if result.directory.isEmpty {
                localResultArrived.fulfill()
            } else {
                remoteResultArrived.fulfill()
            }
            
            XCTAssertTrue(result.contacts.contains(user))
        }
        
        // when
        task.performLocalSearch()
        spinMainQueue(withTimeout: 0.2)
        task.performRemoteSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatLocalResultsIncludePreviousRemoteResults() {
        // given
        let localResultArrived = expectation(description: "received local result")
        let remoteResultArrived = expectation(description: "received remote result")
        _ = createConnectedUser(withName: "userA")
        
        mockTransportSession.performRemoteChanges { (remoteChanges) in
            remoteChanges.insertUser(withName: "UserB")
        }
        
        let request = SearchRequest(query: "user", searchOptions: [.contacts, .directory])
        let task = SearchTask(request: request, context: mockUserSession.managedObjectContext, session: mockUserSession)
        
        // expect
        task.onResult { (result) in
            
            if result.contacts.isEmpty {
                remoteResultArrived.fulfill()
            } else {
                localResultArrived.fulfill()
            }
            
            XCTAssertEqual(result.directory.count, 1)
        }
        
        // when
        task.performRemoteSearch()
        spinMainQueue(withTimeout: 0.2)
        task.performLocalSearch()
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
}
