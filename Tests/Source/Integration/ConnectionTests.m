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


@import ZMTransport;
@import zmessaging;
@import ZMCDataModel;

#import "IntegrationTestBase.h"
#import "ZMSearchDirectory.h"
#import "ZMUserSession.h"
#import "ZMConnectionTranscoder+Internal.h"

@interface ConnectionTests : IntegrationTestBase

@property (nonatomic) NSUInteger previousZMConnectionTranscoderPageSize;

@end

@implementation ConnectionTests


- (ZMConversation *)oneOnOneConversationForConnectedMockUser:(MockUser*)mockUser
{
    MockConnection *mockConnection = mockUser.connectionsTo.firstObject;
    ZMConversation *conversation = [self conversationForMockConversation:mockConnection.conversation];
    return conversation;
}

- (void)testThatWeRequestToTheBackendAConnectionFromASearchUser
{
    // given
    NSString *searchUserName = @"Karl McUser";
    NSUUID *userID = [NSUUID createUUID];
    [self createUserWithName:searchUserName uuid:userID];
    
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    // when
    [self searchAndConnectToUserWithName:searchUserName searchQuery:@"McUser"];
    WaitForEverythingToBeDone();
    
    // then
    ZMTransportRequest *foundRequest = [self.mockTransportSession.receivedRequests firstObjectMatchingWithBlock:^BOOL(ZMTransportRequest *request) {
        return [request.path hasPrefix:@"/connections"] &&
            (request.method == ZMMethodPOST)
        && [[[request.payload asDictionary] stringForKey:@"user"] isEqualToString:userID.transportString];
    }];
    XCTAssertNotNil(foundRequest);
}

- (void)testThatWhenConnectingToASearchUserAndResynchronizingWeHaveThatConnection
{
    // given
    NSString *searchUserName = @"Karl McUser";
    NSUUID *userID = [NSUUID createUUID];
    [self createUserWithName:searchUserName uuid:userID];
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self searchAndConnectToUserWithName:searchUserName searchQuery:@"McUser"];
    WaitForEverythingToBeDone();
    [self recreateUserSessionAndWipeCache:YES];
    
    // when
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // then
    NSArray *allConversations = [ZMConversationList conversationsInUserSession:self.userSession];
    ZMConversation *foundConversation = [allConversations firstObjectMatchingWithBlock:^BOOL(ZMConversation *conv) {
        if([conv.connectedUser.displayName isEqualToString:@"Karl"]) {
            return YES;
        }
        return NO;
    }];
    
    XCTAssertNotNil(foundConversation);
}

- (void)testThatWeRequestToTheBackendAConnectionForAUserWeAreInAConversationWith
{
    // given
    NSString *userName = @"Extra User4";
    NSUUID *userID = [NSUUID createUUID];
    [self createUserWithName:userName uuid:userID];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        NSFetchRequest *fetchRequest = [MockUser sortedFetchRequestWithPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", userID.transportString]];
        NSArray *users = [self.mockTransportSession.managedObjectContext executeFetchRequestOrAssert:fetchRequest];
        XCTAssertEqual(users.count, 1u);
        [self.groupConversation addUsersByUser:self.selfUser addedUsers:@[users[0]]];
    }];

    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.groupConversation];
    
    ZMUser *userToConnectTo = [conversation.activeParticipants.array firstObjectMatchingWithBlock:^BOOL(ZMUser* user) {
        return [user.displayName isEqual:@"Extra User4"];
    }];
    XCTAssertNotNil(userToConnectTo);
    
    // when
    [self.userSession performChanges:^{
        [userToConnectTo connectWithMessageText:@"Add me!" completionHandler:nil];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    ZMTransportRequest *foundRequest = [self.mockTransportSession.receivedRequests firstObjectMatchingWithBlock:^BOOL(ZMTransportRequest *request) {
        return [request.path hasPrefix:@"/connections"] &&
        (request.method == ZMMethodPOST)
        && [[[request.payload asDictionary] stringForKey:@"user"] isEqualToString:userID.transportString];
    }];
    XCTAssertNotNil(foundRequest);
}

- (void)testThatAPendingIncomingConnectionRequestIsDisplayedCorrectly;
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversationList *pending = [ZMConversationList pendingConnectionConversationsInUserSession:self.userSession];
    ZMConversationList *active = [ZMConversationList conversationsInUserSession:self.userSession];

    // when
    NSString *userName = @"Hans Von Üser";
    MockUser *mockUser = [self createPendingConnectionFromUserWithName:userName uuid:NSUUID.createUUID];
    
    // then
    ZMConversation *conversation = [self oneOnOneConversationForConnectedMockUser:mockUser];
    XCTAssertEqualObjects(conversation.displayName, userName);
    XCTAssertTrue(conversation.isPendingConnectionConversation);
    
    ZMUser *otherUser = [self userForMockUser:mockUser];
    XCTAssertNotNil(otherUser);
    XCTAssertEqual(conversation.connectedUser, otherUser);
    
    //pending connections should be in pending conversations list
    XCTAssertFalse([active containsObject:conversation]);
    XCTAssertTrue([pending containsObject:conversation]);
}

- (void)testThatASentConnectionRequestIsDisplayedCorrectly;
{
    // given
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversationList *pending = [ZMConversationList pendingConnectionConversationsInUserSession:self.userSession];
    ZMConversationList *active = [ZMConversationList conversationsInUserSession:self.userSession];
    
    // when
    NSString *userName = @"Hans Von Üser";
    MockUser *mockUser = [self createSentConnectionToUserWithName:userName uuid:NSUUID.createUUID];

    // then
    ZMConversation *conversation = [self oneOnOneConversationForConnectedMockUser:mockUser];
    XCTAssertNotNil(conversation);
    XCTAssertEqualObjects(conversation.displayName, userName);
    XCTAssertFalse(conversation.isPendingConnectionConversation);
    
    ZMUser *otherUser = [self userForMockUser:mockUser];
    XCTAssertNotNil(otherUser);
    XCTAssertEqual(conversation.connectedUser, otherUser);
    
    //sent connections should be in active conversations list
    XCTAssertTrue([active containsObject:conversation]);
    XCTAssertFalse([pending containsObject:conversation]);
}


- (void)testThatAConnectionRequestIsRemovedFromThePendingConnectionsListWhenItIsIgnored;
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);

    MockUser *mockUser = [self createPendingConnectionFromUserWithName:@"Hans Von Üser" uuid:NSUUID.createUUID];
    ZMConversation *conversation = [self oneOnOneConversationForConnectedMockUser:mockUser];
    ZMUser *user = [self userForMockUser:mockUser];
    XCTAssertEqual(user, conversation.connectedUser);
    
    ZMConversationList *pending = [ZMConversationList pendingConnectionConversationsInUserSession:self.userSession];
    XCTAssertTrue([pending containsObject:conversation]);
    
    ConversationListChangeObserver *observer = [[ConversationListChangeObserver alloc] initWithConversationList:pending];
    
    // when ignoring:
    [self.userSession performChanges:^{
        [user ignore];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    
    // then
    XCTAssertFalse([pending containsObject:conversation]);
    XCTAssertEqual(observer.notifications.count, 1u);
    [observer tearDown];
}

- (void)testThatAConnectionRequestIsRemovedFromConversationsListWhenItIsCancelled;
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    MockUser *mockUser = [self createSentConnectionToUserWithName:@"Hans Von Üser" uuid:NSUUID.createUUID];
    ZMConversation *conversation = [self oneOnOneConversationForConnectedMockUser:mockUser];
    ZMUser *user = [self userForMockUser:mockUser];
    XCTAssertEqual(user, conversation.connectedUser);
    
    ZMConversationList *conversations = [ZMConversationList conversationsIncludingArchivedInUserSession:self.userSession];
    XCTAssertTrue([conversations containsObject:conversation]);
    
    ConversationListChangeObserver *observer = [[ConversationListChangeObserver alloc] initWithConversationList:conversations];
    
    // when cancelling:
    [self.userSession performChanges:^{
        [user cancelConnectionRequest];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    
    // then
    XCTAssertFalse([conversations containsObject:conversation]);
    XCTAssertEqual(observer.notifications.count, 1u);
    [observer tearDown];
}

- (void)testThatConnectionRequestsFromTwoUsersAreBothAddedToActiveConversations;
{
    // given
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    MockUser *mockUser1 = [self createPendingConnectionFromUserWithName:@"Hans Von Üser" uuid:NSUUID.createUUID];
    ZMConversation *conversation1 = [self oneOnOneConversationForConnectedMockUser:mockUser1];
    XCTAssertEqual(conversation1.conversationType, ZMConversationTypeConnection);
    ZMUser *realUser1 = [self userForMockUser:mockUser1];
    XCTAssertEqualObjects(realUser1, conversation1.connectedUser);
    
    MockUser *mockUser2 = [self createPendingConnectionFromUserWithName:@"Hannelore Isstgern" uuid:NSUUID.createUUID];
    ZMConversation *conversation2 = [self oneOnOneConversationForConnectedMockUser:mockUser2];
    XCTAssertEqual(conversation2.conversationType, ZMConversationTypeConnection);
    ZMUser *realUser2 = [self userForMockUser:mockUser2];
    XCTAssertEqualObjects(realUser2, conversation2.connectedUser);
    
    ZMConversationList *active = [ZMConversationList conversationsInUserSession:self.userSession];
    ZMConversationList *pending = [ZMConversationList pendingConnectionConversationsInUserSession:self.userSession];
    
    XCTAssertFalse([active containsObject:conversation1]);
    XCTAssertFalse([active containsObject:conversation2]);
    XCTAssertTrue([pending containsObject:conversation1]);
    XCTAssertTrue([pending containsObject:conversation2]);

    
    ConversationListChangeObserver *pendingObserver = [[ConversationListChangeObserver alloc] initWithConversationList:pending];
    ConversationListChangeObserver *activeObserver = [[ConversationListChangeObserver alloc] initWithConversationList:active];
    
    // when accepting:
    
    [self.userSession performChanges:^{
        [realUser1 accept];
        [realUser2 accept];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    
    XCTAssertTrue([active containsObject:conversation1]);
    XCTAssertTrue([active containsObject:conversation2]);
    XCTAssertFalse([pending containsObject:conversation1]);
    XCTAssertFalse([pending containsObject:conversation2]);
    
    XCTAssertEqual(conversation1.conversationType, ZMConversationTypeOneOnOne);
    XCTAssertEqual(conversation2.conversationType, ZMConversationTypeOneOnOne);

    XCTAssertGreaterThanOrEqual(pendingObserver.notifications.count, 1u);
    __block NSInteger deletionsCount = 0;
    for (ConversationListChangeInfo *note in pendingObserver.notifications) {
        deletionsCount += note.deletedIndexes.count;
        //should be no insertions, moves, deletions in pending list
        XCTAssertEqual(note.insertedIndexes.count, 0u);
        XCTAssertEqual(note.updatedIndexes.count, 0u);
        XCTAssertEqual(note.movedIndexPairs.count, 0u);
    }
    XCTAssertEqual(deletionsCount, 2);

    XCTAssertGreaterThanOrEqual(activeObserver.notifications.count, 1u);
    __block NSInteger insertionsCount = 0;
    for (ConversationListChangeInfo *note in activeObserver.notifications) {
        insertionsCount += note.insertedIndexes.count;
        //should be no deletions in active list
        XCTAssertEqual(note.deletedIndexes.count, 0u);
    }
    XCTAssertEqual(insertionsCount, 2);
    [pendingObserver tearDown];
    [activeObserver tearDown];

}

- (void)addConnectionRequestInMockTransportsession:(MockTransportSession<MockTransportSessionObjectCreation> *)session forUser:(MockUser *)mockUser
{
    MockConversation *conversation =
    [session insertConversationWithSelfUser:self.selfUser creator:mockUser otherUsers:nil type:ZMTConversationTypeGroup];
    [self storeRemoteIDForObject:conversation];
    MockConnection *connection = [session insertConnectionWithSelfUser:self.selfUser toUser:mockUser];
    connection.message = @"Hello, my friend.";
    connection.status = @"pending";
    connection.lastUpdate = [NSDate dateWithTimeIntervalSinceNow:-20000];
    connection.conversation = conversation;
}

- (void)testThatConnectionRequestsFromTwoUsersTriggerNotifications;
{
    // given
    self.registeredOnThisDevice = YES;
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMConversationList *conversationList = [ZMConversationList conversationsInUserSession:self.userSession];
    XCTAssertEqual(conversationList.count, 3u);
    ConversationListChangeObserver *conversationListObserver = [[ConversationListChangeObserver alloc] initWithConversationList:conversationList];
    
    ZMConversationList *pendingConversationsList = [ZMConversationList pendingConnectionConversationsInUserSession:self.userSession];
    ConversationListChangeObserver *pendingConversationListObserver = [[ConversationListChangeObserver alloc] initWithConversationList:pendingConversationsList];
    
    ConversationChangeObserver *convObserver = self.conversationChangeObserver;
    
    NSString *userName1 = @"Hans Von Üser";
    NSUUID *userID1 = NSUUID.createUUID;
    MockUser *mockUser1 = [self createUserWithName:userName1 uuid:userID1];
    [self storeRemoteIDForObject:mockUser1];
    
    NSString *userName2 = @"Hannelore Isstgern";
    NSUUID *userID2 = NSUUID.createUUID;
    MockUser *mockUser2 = [self createUserWithName:userName2 uuid:userID2];
    [self storeRemoteIDForObject:mockUser2];
    
    ZMUser *realUser1;
    ZMUser *realUser2;
    
    ZMConversation *conv1;
    ZMConversation *conv2;    
    
    
    // when we add connection requests from remote users to the selfuser
    {
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            [self addConnectionRequestInMockTransportsession:session forUser:mockUser1];
            [self addConnectionRequestInMockTransportsession:session forUser:mockUser2];
        }];
        WaitForEverythingToBeDone();
    }
    
    // then the conversations should be accessible after sync and have the status pending
    {
        realUser1 = [self userForMockUser:mockUser1];
        XCTAssertNotNil(realUser1);
        
        realUser2 = [self userForMockUser:mockUser2];
        XCTAssertNotNil(realUser2);
        
        conv1 = realUser1.oneToOneConversation;
        XCTAssertNotNil(conv1);
        XCTAssertEqual(conv1.conversationType, ZMConversationTypeConnection);
        
        conv2 = realUser2.oneToOneConversation;
        XCTAssertNotNil(conv2);
        XCTAssertEqual(conv2.conversationType, ZMConversationTypeConnection);
        
        NSIndexSet *expectedSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)];
        NSArray *listNotes = pendingConversationListObserver.notifications;
        XCTAssertNotNil(listNotes);
        ConversationListChangeInfo *listNote = listNotes.firstObject;
        XCTAssertNotNil(listNote);
        XCTAssertEqualObjects(listNote.insertedIndexes, expectedSet);
        [conversationListObserver clearNotifications];
    }
    
    id token1 = [conv1 addConversationObserver:convObserver];
    id token2 = [conv2 addConversationObserver:convObserver];
    
    // when accepting the connection requests
    {
        [self.userSession performChanges:^{
            [realUser1 accept];
            [realUser2 accept];
        }];
        WaitForEverythingToBeDone();
        [self.mockTransportSession waitForAllRequestsToCompleteWithTimeout:0.5];
    }
    
    // we should receive notifcations about the list change and the conversation updates and the connection status should change
    {
        NSIndexSet *expectedSet1 = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 1)];

        NSArray *listNotes = conversationListObserver.notifications;
        XCTAssertEqual(listNotes.count, 2u);

        ConversationListChangeInfo *listNote1 = listNotes.firstObject;
        ConversationListChangeInfo *listNote2 = listNotes.lastObject;

        XCTAssertEqualObjects(listNote1.insertedIndexes, expectedSet1);
        XCTAssertLessThanOrEqual(listNote2.insertedIndexes.firstIndex, 1u); // there is a race condition, it might be 1 or 0

        
        NSArray *convNotes = convObserver.notifications;
        convNotes = convObserver.notifications;
        XCTAssertNotNil(convNotes);
        
        BOOL conv1StateChanged = NO;
        BOOL conv2StateChanged = NO;
        BOOL conv1MessagesChanged = NO;
        BOOL conv2MessagesChanged = NO;

        for (ConversationChangeInfo *note  in convNotes) {
            ZMConversation *conv = note. conversation;
            if (note.messagesChanged) {
                conv1MessagesChanged = conv1MessagesChanged ? YES :(conv == conv1);
                conv2MessagesChanged = conv2MessagesChanged ? YES :(conv == conv2);
            }
            if (note.connectionStateChanged) {
                conv1StateChanged = conv1StateChanged ? YES :(conv == conv1);
                conv2StateChanged = conv2StateChanged ? YES :(conv == conv2);
            }
        }
        XCTAssertTrue(conv1StateChanged);
        XCTAssertEqual(conv1.conversationType, ZMConversationTypeOneOnOne);
        XCTAssertEqual(conv1.messages.count, 2u); // accepting connection request produces a new conversation system message

        XCTAssertTrue(conv2StateChanged);
        XCTAssertEqual(conv2.conversationType, ZMConversationTypeOneOnOne);
        XCTAssertEqual(conv2.messages.count, 2u); // accepting connection request produces a new conversation system message
    }
    
    [ZMConversation removeConversationObserverForToken:token1];
    [ZMConversation removeConversationObserverForToken:token2];
    [conversationListObserver tearDown];
    [pendingConversationListObserver tearDown];
} 

- (void)testThatConnectionRequestsToTwoUsersAreAddedToPending;
{
    // given two remote users
    NSString *userName1 = @"Hans Von Üser";
    NSString *userName2 = @"Hannelore Isstgern";

    __block MockUser *mockUser1;
    __block MockUser *mockUser2;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        mockUser1 = [session insertUserWithName:userName1];
        XCTAssertNotNil(mockUser1.identifier);
        mockUser1.email = @"";
        mockUser1.phone = @"";
        [self storeRemoteIDForObject:mockUser1];
        
        mockUser2 = [session insertUserWithName:userName2];
        XCTAssertNotNil(mockUser2.identifier);
        mockUser2.email = @"";
        mockUser2.phone = @"";
        [self storeRemoteIDForObject:mockUser2];
    }];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);

    ZMConversationList *active = [ZMConversationList conversationsInUserSession:self.userSession];
    NSUInteger count = active.count;
    
    ConversationListChangeObserver *listObserver = [[ConversationListChangeObserver alloc] initWithConversationList:active];
    
    ZMConversation *conv1;
    ZMConversation *conv2;
    
    // when we search and send connection requests to users
    {
        [self.userSession performChanges:^{
            [self searchAndConnectToUserWithName:userName1 searchQuery:@"Hans"];
            [self searchAndConnectToUserWithName:userName2 searchQuery:@"Hannelore"];
        }];
        WaitForEverythingToBeDone();
    }
    
    // we should see two new active conversations
    {
        ZMUser *realUser1 = [self userForMockUser:mockUser1];
        XCTAssertNotNil(realUser1);
        XCTAssertEqual(realUser1.connection.status, ZMConnectionStatusSent);
        
        ZMUser *realUser2 = [self userForMockUser:mockUser2];
        XCTAssertNotNil(realUser2);
        XCTAssertEqual(realUser2.connection.status, ZMConnectionStatusSent);
        
        conv1 = realUser1.oneToOneConversation;
        XCTAssertNotNil(conv1);
        
        conv2 = realUser2.oneToOneConversation;
        XCTAssertNotNil(conv2);
        
        XCTAssertEqual(active.count, count+2);
    }
    
    ConversationChangeObserver *observer = self.conversationChangeObserver;
    id token1 = [conv1 addConversationObserver:observer];
    id token2 = [conv2 addConversationObserver:observer];

    // when the remote users accept the connection requests
    {
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            [session remotelyAcceptConnectionToUser:mockUser1];
            [session remotelyAcceptConnectionToUser:mockUser2];
        }];
        WaitForEverythingToBeDone();
        [NSThread sleepForTimeInterval:0.1];
        WaitForEverythingToBeDone();
    }
    
    WaitForAllGroupsToBeEmpty(0.5);

    // we should receive notifications about the changed status and participants
    {
        NSArray *notifications = observer.notifications;
        XCTAssertNotNil(notifications);
        
        BOOL conv1StateChanged = NO;
        BOOL conv2StateChanged = NO;
        BOOL conv1ParticipantsChanged = NO;
        BOOL conv2ParticipantsChanged = NO;
        
        for (ConversationChangeInfo *note  in notifications) {
            ZMConversation *conv = note.conversation;
            if (note.participantsChanged) {
                conv1ParticipantsChanged = conv1ParticipantsChanged ? YES :(conv == conv1);
                conv2ParticipantsChanged = conv2ParticipantsChanged ? YES :(conv == conv2);
            }
            if (note.connectionStateChanged) {
                conv1StateChanged = conv1StateChanged ? YES :(conv == conv1);
                conv2StateChanged = conv2StateChanged ? YES :(conv == conv2);
            }
        }
        XCTAssertTrue(conv1StateChanged);
        XCTAssertTrue(conv2StateChanged);
        XCTAssertFalse(conv1ParticipantsChanged);
        XCTAssertFalse(conv2ParticipantsChanged);
    }
    
    [ZMConversation removeConversationObserverForToken:token1];
    [ZMConversation removeConversationObserverForToken:token2];
    [listObserver tearDown];
}

- (void)testThatWeSeeANewConversationSystemMessageWhenAcceptingAConnectionRequest;
{
    self.registeredOnThisDevice = YES;
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    XCTAssertNotNil(self.selfToUser1Conversation);
    XCTAssertNotNil(conversation);
    
    [self.userSession saveOrRollbackChanges];
    WaitForEverythingToBeDone();
    
    XCTAssertEqual(conversation.conversationType, ZMConversationTypeOneOnOne);
    XCTAssertEqual(conversation.messages.count, 1u);
    id<ZMConversationMessage> message = conversation.messages.lastObject;
    XCTAssertEqualObjects([message class], [ZMSystemMessage class]);
    XCTAssertEqual(((ZMSystemMessage *)message).systemMessageType, ZMSystemMessageTypeUsingNewDevice);

}


- (void)DISABLED_testThatWeDontSeeASystemMessageWhenAUserAcceptsAConnectionRequest;
{
    // given two remote users
    NSString *userName1 = @"Hans Von Üser";
    
    __block MockUser *mockUser1;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        mockUser1 = [session insertUserWithName:userName1];
        XCTAssertNotNil(mockUser1.identifier);
        mockUser1.email = @"";
        mockUser1.phone = @"";
        [self storeRemoteIDForObject:mockUser1];
    }];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    NSArray *active = [ZMConversationList conversationsInUserSession:self.userSession];
    NSUInteger count = active.count;
    
    ZMConversation *conv1;
    
    // when we search and send connection requests to users
    {
        [self.userSession performChanges:^{
            [self searchAndConnectToUserWithName:userName1 searchQuery:@"Hans"];
        }];
        WaitForEverythingToBeDone();
    }
    
    // we should see a new active conversation
    {
        ZMUser *realUser1 = [self userForMockUser:mockUser1];
        XCTAssertNotNil(realUser1);
        XCTAssertEqual(realUser1.connection.status, ZMConnectionStatusSent);
        
        conv1 = realUser1.oneToOneConversation;
        XCTAssertNotNil(conv1);
        XCTAssertEqual(active.count, count+1);
    }
    
    
    // when the remote users accept the connection requests
    {
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            [session remotelyAcceptConnectionToUser:mockUser1];
        }];
        WaitForEverythingToBeDone();
    }
    
    // we should not see a system message in the conversation
    {
        XCTAssertEqual(conv1.conversationType, ZMConversationTypeOneOnOne);
        XCTAssertEqual(conv1.messages.count, 1u, @"%@", conv1.messages);
        ZMSystemMessage *message1 = conv1.messages[0];
        XCTAssertEqual(message1.systemMessageType, ZMSystemMessageTypeConnectionRequest);
        XCTAssertEqual(message1.text, @"Hola");
    }
}

- (void)testThatTheConnectionTypeChangesAfterARemoteUserAcceptsOurConnectionRequest
{
    // given a remote users
    NSString *userName1 = @"Hans Von Üser";
    
    __block MockUser *mockUser1;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        mockUser1 = [session insertUserWithName:userName1];
        XCTAssertNotNil(mockUser1.identifier);
        mockUser1.email = @"";
        mockUser1.phone = @"";
        [self storeRemoteIDForObject:mockUser1];
    }];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMConversation *conv1;
    ZMUser *realUser1;
    
    // when we search and send connection requests to users
    {
        [self.userSession performChanges:^{
            [self searchAndConnectToUserWithName:userName1 searchQuery:@"Hans"];
        }];
        WaitForEverythingToBeDone();
    }
    
    // we should see a new active conversation
    {
        realUser1 = [self userForMockUser:mockUser1];
        XCTAssertNotNil(realUser1);
        XCTAssertEqual(realUser1.connection.status, ZMConnectionStatusSent);
        
        conv1 = realUser1.oneToOneConversation;
        XCTAssertNotNil(conv1);
        XCTAssertEqual(conv1.conversationType, ZMConversationTypeConnection);

    }
    
    // when the remote users accept the connection requests
    {
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            [session remotelyAcceptConnectionToUser:mockUser1];
        }];
        WaitForEverythingToBeDone();
    }
    
    // we should not see a system message in the conversation
    {
        XCTAssertEqual(conv1.conversationType, ZMConversationTypeOneOnOne);
        XCTAssertEqual(realUser1.oneToOneConversation.conversationType, ZMConversationTypeOneOnOne);
    }
}

- (void)testThatTheObserverGetsNotifiedWhenARemoteUserAcceptsOurConnectionRequest
{
    // given two remote users
    NSString *userName1 = @"Hans Von Üser";
    
    __block MockUser *mockUser1;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        mockUser1 = [session insertUserWithName:userName1];
        XCTAssertNotNil(mockUser1.identifier);
        mockUser1.email = @"foo@bar.example.com";
        mockUser1.phone = @"123123124";
        [self storeRemoteIDForObject:mockUser1];
    }];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMConversation *conv1;
    
    // when we search and send connection requests to users
    {
        [self.userSession performChanges:^{
            [self searchAndConnectToUserWithName:userName1 searchQuery:@"Hans"];
        }];
        WaitForEverythingToBeDone();
    }
    
    // we should see two new active conversations
    {
        ZMUser *realUser1 = [self userForMockUser:mockUser1];
        XCTAssertNotNil(realUser1);
        XCTAssertEqual(realUser1.connection.status, ZMConnectionStatusSent);
        
        conv1 = realUser1.oneToOneConversation;
        XCTAssertNotNil(conv1);
        XCTAssertEqual(conv1.conversationType, ZMConversationTypeConnection);
        
    }
    
    ConversationChangeObserver *observer = self.conversationChangeObserver;
    id token = [conv1 addConversationObserver:observer];
    [observer clearNotifications];
    
    // when the remote users accept the connection requests
    {
        [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            [session remotelyAcceptConnectionToUser:mockUser1];
        }];
        WaitForEverythingToBeDone();
    }
    
    XCTAssertTrue([self waitOnMainLoopUntilBlock:^BOOL{
        return observer.notifications.count >= 1;
    } timeout:0.6]);
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // we should not see a system message in the conversation
    {
        XCTAssertEqual(conv1.conversationType, ZMConversationTypeOneOnOne);
        
        NSArray *notifications = observer.notifications;
        XCTAssertNotNil(notifications);
        
        BOOL conv1StateChanged = NO;
        BOOL conv1ParticipantsChanged = NO;
        
        for (ConversationChangeInfo *note  in notifications) {
            ZMConversation *conv = note.conversation;
            if (note.participantsChanged) {
                conv1ParticipantsChanged = conv1ParticipantsChanged ? YES :(conv == conv1);
            }
            if (note.connectionStateChanged) {
                conv1StateChanged = conv1StateChanged ? YES :(conv == conv1);
            }
        }
        XCTAssertTrue(conv1StateChanged);
        XCTAssertFalse(conv1ParticipantsChanged);
    }
    
    WaitForEverythingToBeDoneWithTimeout(0.1);
    [ZMConversation removeConversationObserverForToken:token];
}


- (void)testThatItNotifiesObserversWhenWeSendAConnectionRequest
{
    // given two remote users
    NSString *userName1 = @"Hans Von Üser";
    
    __block MockUser *mockUser1;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        mockUser1 = [session insertUserWithName:userName1];
        XCTAssertNotNil(mockUser1.identifier);
        mockUser1.email = @"";
        mockUser1.phone = @"";
        [self storeRemoteIDForObject:mockUser1];
    }];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMConversationList *activeConversations = [ZMConversationList conversationsInUserSession:self.userSession];
    NSUInteger activeCount = activeConversations.count;
    
    ConversationListChangeObserver *observer = [[ConversationListChangeObserver alloc] initWithConversationList:activeConversations];
    [observer clearNotifications];
    
    
    // when we search and send connection requests to users
    {
        [self.userSession performChanges:^{
            [self searchAndConnectToUserWithName:userName1 searchQuery:@"Hans"];
        }];
        WaitForEverythingToBeDone();
    }
    
    // we should see one new active conversations
    {
        XCTAssertEqual(activeConversations.count, activeCount+1u);
     
        NSArray *notifications = observer.notifications;
        XCTAssertNotNil(notifications);
        
        ConversationListChangeInfo *note = notifications.firstObject;
        XCTAssertNotNil(note);
        XCTAssertEqualObjects(note.insertedIndexes, [NSIndexSet indexSetWithIndex:0]);
        XCTAssertTrue(note.deletedIndexes.count == 0);
        XCTAssertTrue(note.updatedIndexes.count == 0);
        XCTAssertTrue(note.movedIndexPairs.count == 0);
    }
    [observer tearDown];
}

- (void)testThatItTheConnectionRequestConversationIsOnTopOfTheConversationList
{
    // given two remote users
    NSString *userName1 = @"Hans Von Üser";
    
    __block MockUser *mockUser;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        mockUser = [session insertUserWithName:userName1];
        XCTAssertNotNil(mockUser.identifier);
        mockUser.email = @"";
        mockUser.phone = @"";
        [self storeRemoteIDForObject:mockUser];
    }];
    WaitForEverythingToBeDone();
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    NSArray *active = [ZMConversationList conversationsInUserSession:self.userSession];
    
    // when we search and send connection requests to users
    [self.userSession performChanges:^{
        [self searchAndConnectToUserWithName:userName1 searchQuery:@"Hans"];
    }];
    WaitForEverythingToBeDone();
    
    // the new conversation should be the first item in the list

    ZMUser *user = [self userForMockUser:mockUser];
    ZMConversation *conversation = user.oneToOneConversation;
    XCTAssertEqualObjects(active.firstObject, conversation);
}

- (void)testThatItResendsConnectionRequestAfterItWasCancelled
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForAllGroupsToBeEmpty(0.5);

    MockUser *mockUser = [self createSentConnectionToUserWithName:@"Hans Von Üser" uuid:NSUUID.createUUID];
    ZMConversation *conversation = [self oneOnOneConversationForConnectedMockUser:mockUser];
    ZMUser *user = [self userForMockUser:mockUser];
    XCTAssertEqual(user, conversation.connectedUser);
    
    ZMConversationList *conversations = [ZMConversationList conversationsIncludingArchivedInUserSession:self.userSession];
    XCTAssertTrue([conversations containsObject:conversation]);
    
    ConversationListChangeObserver *observer = [[ConversationListChangeObserver alloc] initWithConversationList:conversations];
    
    // when cancelling:
    [self.userSession performChanges:^{
        [user cancelConnectionRequest];
    }];
    WaitForAllGroupsToBeEmpty(0.5);

    XCTAssertFalse([conversations containsObject:conversation]);
    XCTAssertEqual(observer.notifications.count, 1u);
    [observer clearNotifications];

    //when sending again
    [self.userSession performChanges:^{
        [user connectWithMessageText:@"connect!" completionHandler:nil];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertTrue([conversations containsObject:conversation]);
    XCTAssertEqual(observer.notifications.count, 2u);
    [observer tearDown];
}


@end



@implementation ConnectionTests (Pagination)

- (void)setupTestThatItPaginatesConnectionsRequests
{
    self.previousZMConnectionTranscoderPageSize = ZMConnectionTranscoderPageSize;
    ZMConnectionTranscoderPageSize = 2;
}

- (void)testThatItPaginatesConnectionsRequests
{
    // given
    XCTAssertEqual(ZMConnectionTranscoderPageSize, 2u);
    
    __block NSUInteger numberOfConnections;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        for(int i = 0; i < 11; ++i) {
            MockUser *user = [session insertUserWithName:@"foo foo"];
            user.identifier = [NSUUID createUUID].transportString;
            [session createConnectionRequestFromUser:self.selfUser toUser:user message:@"test"];
        }
        
        NSFetchRequest *request = [MockConnection sortedFetchRequest];
        NSArray *connections = [self.mockTransportSession.managedObjectContext executeFetchRequestOrAssert:request];
        numberOfConnections = connections.count;
    }];
    
    // when
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // then
    NSUInteger expectedRequests = (NSUInteger) (numberOfConnections / (float)ZMConnectionTranscoderPageSize + 0.5f);
    NSUInteger foundRequests = 0;
    for(ZMTransportRequest *request in self.mockTransportSession.receivedRequests) {
        if([request.path hasPrefix:@"/connections?size=2"]) {
            ++foundRequests;
        }
    }
    
    XCTAssertEqual(expectedRequests, foundRequests);
    XCTAssertEqual([ZMConnection connectionsInMangedObjectContext:self.uiMOC].count, numberOfConnections);
    
    // then
    ZMConnectionTranscoderPageSize = self.previousZMConnectionTranscoderPageSize;
}

@end


////
// TestObserver
///

@interface ConnectionLimitObserver : NSObject

@property (nonatomic) NSMutableArray *notifications;
- (void)clearNotifications;

@end

@implementation ConnectionLimitObserver

- (instancetype)init {
    self = [super init];
    if  (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(addNotfication:) name:@"ZMConnectionLimitReachedNotification" object:nil];
        self.notifications = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)addNotfication:(NSNotification *)note
{
    [self.notifications addObject:note];
}

- (void)clearNotifications
{
    self.notifications = [NSMutableArray array];
}

@end


@implementation ConnectionTests (ConnectionLimit)

- (ZMCustomResponseGeneratorBlock)responseBlockForConnectionLimit;
{
    return ^ZMTransportResponse *(ZMTransportRequest *request) {
        if (![request.path hasPrefix:@"/connections"] || (request.method == ZMMethodGET)) {
            return nil;
        }
        NSDictionary *payload = @{@"label": @"connection-limit"};
        return [[ZMTransportResponse alloc] initWithPayload:payload HTTPStatus:403 transportSessionError:nil headers:nil];
    };

}

- (void)testThatItDeletesTheConversationWhenConnectionIsRejectedByBackendAndNotifiesObservers
{
    // given
    NSString *searchUserName = @"Karl McUser";
    [self createUserWithName:searchUserName uuid:NSUUID.createUUID];
    
    self.mockTransportSession.responseGeneratorBlock = self.responseBlockForConnectionLimit;
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversationList *conversations = [ZMConversationList conversationsInUserSession:self.userSession];
    NSUInteger beforeInsertingCount = conversations.count;
    
    // when
    [self searchAndConnectToUserWithName:searchUserName searchQuery:@"McUser"];
    [self.mockTransportSession waitForAllRequestsToCompleteWithTimeout:0.5];
    
    // then
    XCTAssertEqual(conversations.count, beforeInsertingCount);
}

- (void)testThatItNotifiesObserversAboutConnectionLimitWhenInsertingAnObject
{
    // given
    ConnectionLimitObserver *observer = [[ConnectionLimitObserver alloc] init];
    
    NSString *searchUserName = @"Karl McUser";
    NSUUID *userID = [NSUUID createUUID];
    [self createUserWithName:searchUserName uuid:userID];
    
    self.mockTransportSession.responseGeneratorBlock = self.responseBlockForConnectionLimit;
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    XCTAssertEqual(observer.notifications.count, 0u);
    
    // when
    [self searchAndConnectToUserWithName:searchUserName searchQuery:@"McUser"];
    [self.mockTransportSession waitForAllRequestsToCompleteWithTimeout:0.5];
    
    // then
    XCTAssertEqual(observer.notifications.count, 1u);
}

- (void)testThatItResetsTheConversationWhenAConnectionStatusChangeFromPendingToAcceptedIsRejectedByTheBackend
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMConversationList *pending = [ZMConversationList pendingConnectionConversationsInUserSession:self.userSession];
    NSUInteger pendingCount = pending.count;

    // given
    // create pending conversation from remote user
    MockUser *mockUser = [self createPendingConnectionFromUserWithName:@"Hans" uuid:NSUUID.createUUID];
    XCTAssertEqual(pending.count, pendingCount + 1u);
    
    id listObserver = [OCMockObject niceMockForProtocol:@protocol(ZMConversationListObserver)];
    id listToken = [pending addConversationListObserver:listObserver];
    
    ZMUser *realUser1 = [self userForMockUser:mockUser];
    
    self.mockTransportSession.responseGeneratorBlock = self.responseBlockForConnectionLimit;
    
    // when accepting connection
    // the request gets refused and the connection status and conversation type are reset
    {
        // expect
        XCTestExpectation *expectation1 = [self expectationWithDescription:@"connection set to accepted"];
        [(id<ZMConversationListObserver>)[listObserver expect] conversationListDidChange:[OCMArg checkWithBlock:^BOOL(ConversationListChangeInfo *note) {
            if (note.conversationList == pending && note.deletedIndexes.count == 1){
                [expectation1 fulfill];
                return YES;
            }
            return NO;
        }]];
        
        XCTestExpectation *expectation2 = [self expectationWithDescription:@"connection set to pending after updating from backend"];
        [(id<ZMConversationListObserver>)[listObserver expect] conversationListDidChange:[OCMArg checkWithBlock:^BOOL(ConversationListChangeInfo *note) {
            if (note.conversationList == pending && note.insertedIndexes.count == 1){
                [expectation2 fulfill];
                return YES;
            }
            return NO;
        }]];

        // when
        [self.userSession performChanges:^{
            [realUser1 accept];
        }];
        
        XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);

        // then
        XCTAssertEqual(pending.count, pendingCount + 1u);
    }
    
    [pending removeConversationListObserverForToken:listToken];
}

- (void)testThatItSendsOutANotificationWhenAConnectionStatusChangeFromPendingToAcceptedIsRejectedByTheBackend
{
    // given
    ConnectionLimitObserver *observer = [[ConnectionLimitObserver alloc] init];

    // create pending conversation from remote user
    MockUser *mockUser = [self createPendingConnectionFromUserWithName:@"Hans" uuid:NSUUID.createUUID];
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMUser *realUser1 = [self userForMockUser:mockUser];
    self.mockTransportSession.responseGeneratorBlock = self.responseBlockForConnectionLimit;
    
    // when accepting connection
    [self.userSession performChanges:^{
        [realUser1 accept];
    }];
    [self.mockTransportSession waitForAllRequestsToCompleteWithTimeout:0.5];
    
    // then
    XCTAssertEqual(observer.notifications.count, 1u);

}


@end


