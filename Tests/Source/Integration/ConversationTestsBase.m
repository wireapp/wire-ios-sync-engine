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


#import "ConversationTestsBase.h"
#import "WireSyncEngine_iOS_Tests-Swift.h"


@implementation ConversationTestsBase

- (void)setUp{
    [super setUp];
    [self setupGroupConversationWithOnlyConnectedParticipants];
    self.receivedConversationWindowChangeNotifications = [NSMutableArray array];
}

- (void)tearDown
{
    [self.userSession.syncManagedObjectContext performGroupedBlockAndWait:^{
        [self.userSession.syncManagedObjectContext zm_teardownMessageObfuscationTimer];
    }];
    XCTAssert([self waitForAllGroupsToBeEmptyWithTimeout: 0.5]);
    
    [self.userSession.managedObjectContext zm_teardownMessageDeletionTimer];
    XCTAssert([self waitForAllGroupsToBeEmptyWithTimeout: 0.5]);
    self.groupConversationWithOnlyConnected = nil;
    self.receivedConversationWindowChangeNotifications = nil;
    
    [super tearDown];
}

- (NSURL *)createTestFile:(NSString *)name
{
    NSError *error;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = [fm URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    XCTAssertNil(error);

    NSString *fileName = [NSString stringWithFormat:@"%@.dat", name];
    NSURL *fileURL = [directory URLByAppendingPathComponent:fileName].filePathURL;
    NSData *testData = [NSData secureRandomDataOfLength:256];
    XCTAssertTrue([testData writeToFile:fileURL.path atomically:YES]);

    return fileURL;
}

- (void)setDate:(NSDate *)date forAllEventsInMockConversation:(MockConversation *)conversation
{
    for(MockEvent *event in conversation.events) {
        event.time = date;
    }
}

- (void)setupGroupConversationWithOnlyConnectedParticipants
{
    [self createSelfUserAndConversation];
    [self createExtraUsersAndConversations];

    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        
        NSDate *selfConversationDate = [NSDate dateWithTimeIntervalSince1970:1400157817];
        NSDate *connection1Date = [NSDate dateWithTimeInterval:500 sinceDate:selfConversationDate];
        NSDate *connection2Date = [NSDate dateWithTimeInterval:1000 sinceDate:connection1Date];
        NSDate *groupConversationDate = [NSDate dateWithTimeInterval:1000 sinceDate:connection2Date];
        
        [self setDate:selfConversationDate forAllEventsInMockConversation:self.selfConversation];
        [self setDate:connection1Date forAllEventsInMockConversation:self.selfToUser1Conversation];
        [self setDate:connection2Date forAllEventsInMockConversation:self.selfToUser2Conversation];
        [self setDate:groupConversationDate forAllEventsInMockConversation:self.groupConversation];
        
        self.connectionSelfToUser1.lastUpdate = connection1Date;
        self.connectionSelfToUser2.lastUpdate = connection2Date;

        self.groupConversationWithOnlyConnected = [session insertGroupConversationWithSelfUser:self.selfUser
                                                                                    otherUsers:@[self.user1, self.user2]];
        self.groupConversationWithOnlyConnected.creator = self.selfUser;
        [self.groupConversationWithOnlyConnected changeNameByUser:self.selfUser name:@"Group conversation with only connected participants"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
}

- (void)testThatItSendsANotificationInConversation:(MockConversation *)mockConversation
                                    ignoreLastRead:(BOOL)ignoreLastRead
                        onRemoteMessageCreatedWith:(void(^)())createMessage
                                            verify:(void(^)(ZMConversation *))verifyConversation
{
    // given
    XCTAssertTrue([self login]);
    
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    
    // when
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
        createMessage(session);
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(observer.notifications.count, 1u);
    
    ConversationChangeInfo *note = observer.notifications.lastObject;
    XCTAssertNotNil(note);
    XCTAssertTrue(note.messagesChanged);
    XCTAssertFalse(note.participantsChanged);
    XCTAssertFalse(note.nameChanged);
    XCTAssertTrue(note.lastModifiedDateChanged);
    if(!ignoreLastRead) {
        XCTAssertTrue(note.unreadCountChanged);
    }
    XCTAssertFalse(note.connectionStateChanged);
    
    verifyConversation(conversation);
}

- (void)testThatItSendsANotificationInConversation:(MockConversation *)mockConversation
                        onRemoteMessageCreatedWith:(void(^)())createMessage
                                verifyWithObserver:(void(^)(ZMConversation *, ConversationChangeObserver *))verifyConversation;
{
    [self testThatItSendsANotificationInConversation:mockConversation
                                     afterLoginBlock:nil
                          onRemoteMessageCreatedWith:createMessage
                                  verifyWithObserver:verifyConversation];
}

- (void)testThatItSendsANotificationInConversation:(MockConversation *)mockConversation
                                   afterLoginBlock:(void(^)())afterLoginBlock
                        onRemoteMessageCreatedWith:(void(^)())createMessage
                                verifyWithObserver:(void(^)(ZMConversation *, ConversationChangeObserver *))verifyConversation;
{
    // given
    XCTAssertTrue([self login]);
    afterLoginBlock();
    WaitForAllGroupsToBeEmpty(0.5);
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    
    // when
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * __unused session) {
        createMessage(session);
    }];
    
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    verifyConversation(conversation, observer);
}

- (BOOL)conversation:(ZMConversation *)conversation hasMessagesWithNonces:(NSArray *)nonces
{
    BOOL hasAllMessages = YES;
    for (NSUUID *nonce in nonces) {
        BOOL hasMessageWithNonce = [conversation.messages.array containsObjectMatchingWithBlock:^BOOL(ZMMessage *msg) {
            return [msg.nonce isEqual:nonce];
        }];
        hasAllMessages &= hasMessageWithNonce;
    }
    return hasAllMessages;
}

- (void)testThatItAppendsMessageToConversation:(MockConversation *)mockConversation
                                     withBlock:(NSArray *(^)(MockTransportSession<MockTransportSessionObjectCreation> *session))appendMessages
                                        verify:(void(^)(ZMConversation *))verifyConversation
{
    // given
    XCTAssertTrue([self login]);
    
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    
    // Make sure this relationship is not a fault:
    for (id obj in conversation.messages) {
        (void) obj;
    }
    
    // when
    ConversationChangeObserver *observer = [[ConversationChangeObserver alloc] initWithConversation:conversation];
    [observer clearNotifications];
    
    __block NSArray *messsagesNonces;
    
    // expect
    XCTestExpectation *exp = [self expectationWithDescription:@"All messages received"];
    observer.notificationCallback = (ObserverCallback) ^(ConversationChangeInfo * __unused note) {
        BOOL hasAllMessages = [self conversation:conversation hasMessagesWithNonces:messsagesNonces];
        if (hasAllMessages) {
            [exp fulfill];
        }
    };
    
    // when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> * session) {
        messsagesNonces = appendMessages(session);
    }];
    XCTAssert([self waitForCustomExpectationsWithTimeout:0.5]);
    
    // then
    verifyConversation(conversation);
    
}

- (MockConversationWindowObserver *)windowObserverAfterLogginInAndInsertingMessagesInMockConversation:(MockConversation *)mockConversation;
{
    XCTAssertTrue([self login]);
    ZMConversation *conversation = [self conversationForMockConversation:mockConversation];
    
    const int MESSAGES = 10;
    const NSUInteger WINDOW_SIZE = 5;
    NSMutableArray *insertedMessages = [NSMutableArray array];
    for(int i = 0; i < MESSAGES; ++i)
    {
        [self.userSession performChanges:^{ // I save multiple times so that it is inserted in the mocktransportsession in the order I expect
            NSString *text = [NSString stringWithFormat:@"Message %d", i+1];
            [conversation appendMessageWithText:text];
        }];
        WaitForAllGroupsToBeEmpty(0.5);
    }
    
    [conversation setVisibleWindowFromMessage:insertedMessages.firstObject toMessage:insertedMessages.lastObject];
    MockConversationWindowObserver *observer = [[MockConversationWindowObserver alloc] initWithConversation:conversation size:WINDOW_SIZE];
    
    return observer;
}

@end

