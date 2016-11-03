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


@import ZMCMockTransport;
@import WireMessageStrategy;

#import "MessagingTest.h"
#import <libkern/OSAtomic.h>
#import <CommonCrypto/CommonCrypto.h>

@import MobileCoreServices;
@import CoreData;
@import ZMTransport;
@import ZMCMockTransport;
@import ZMCDataModel;

#import "ZMTimingTests.h"
#import "MockModelObjectContextFactory.h"

#import "ZMObjectStrategyDirectory.h"

#import "ZMUserTranscoder.h"
#import "ZMUserImageTranscoder.h"
#import "ZMConversationTranscoder.h"
#import "ZMSelfTranscoder.h"
#import "ZMConnectionTranscoder.h"
#import "ZMRegistrationTranscoder.h"
#import "ZMPhoneNumberVerificationTranscoder.h"
#import "ZMMissingUpdateEventsTranscoder.h"
#import "ZMLastUpdateEventIDTranscoder.h"
#import "ZMFlowSync.h"
#import "ZMCallStateTranscoder.h"
#import "ZMPushTokenTranscoder.h"
#import "ZMLoginTranscoder.h"
#import "ZMLoginCodeRequestTranscoder.h"
#import "ZMSearchUserImageTranscoder.h"
#import "ZMTypingTranscoder.h"
#import "ZMRemovedSuggestedPeopleTranscoder.h"
#import "ZMUserSession+Internal.h"
#import "ZMUserProfileUpdateTranscoder.h"
#import <zmessaging/zmessaging-Swift.h>
#import "zmessaging_iOS_Tests-Swift.h"


@interface MessagingTest () 

@property (nonatomic) NSManagedObjectContext *uiMOC;
@property (nonatomic) NSManagedObjectContext *syncMOC;
@property (nonatomic) NSManagedObjectContext *testMOC;
@property (nonatomic) NSManagedObjectContext *alternativeTestMOC;
@property (nonatomic) NSManagedObjectContext *searchMOC;

@property (nonatomic) NSString *groupIdentifier;
@property (nonatomic) NSURL *databaseDirectory;
@property (nonatomic) MockTransportSession *mockTransportSession;

@property (nonatomic) NSTimeInterval originalConversationLastReadTimestampTimerValue; // this will speed up the tests A LOT

@end




@implementation MessagingTest
@synthesize mockUserSession = _mockUserSession;

- (BOOL)shouldSlowTestTimers
{
    return [self.class isDebuggingTests] && !self.ignoreTestDebugFlagForTestTimers;
}

- (void)performPretendingUiMocIsSyncMoc:(void(^)(void))block;
{
    if(!block) {
        return;
    }
    [self.uiMOC resetContextType];
    [self.uiMOC markAsSyncContext];
    block();
    [self.uiMOC resetContextType];
    [self.uiMOC markAsUIContext];
}

- (BOOL)shouldUseRealKeychain;
{
    return NO;
}

- (BOOL)shouldUseInMemoryStore;
{
    return YES;
}

- (void)setUp;
{
    [super setUp];
    
    NSFileManager *fm = NSFileManager.defaultManager;
    self.groupIdentifier = [@"group." stringByAppendingString:[NSBundle bundleForClass:self.class].bundleIdentifier];
    self.databaseDirectory = [fm containerURLForSecurityApplicationGroupIdentifier:self.groupIdentifier];
    _application = [[ApplicationMock alloc] init];
    
    self.originalConversationLastReadTimestampTimerValue = ZMConversationDefaultLastReadTimestampSaveDelay;
    ZMConversationDefaultLastReadTimestampSaveDelay = 0.02;
    
    NSString *testName = NSStringFromSelector(self.invocation.selector);
    NSString *methodName = [NSString stringWithFormat:@"setup%@%@", [testName substringToIndex:1].capitalizedString, [testName substringFromIndex:1]];
    SEL selector = NSSelectorFromString(methodName);
    if ([self respondsToSelector:selector]) {
        ZM_SILENCE_CALL_TO_UNKNOWN_SELECTOR([self performSelector:selector]);
    }

    [NSManagedObjectContext setUseInMemoryStore:self.shouldUseInMemoryStore];

    [self resetState];
    
    if (self.shouldUseRealKeychain) {
        [ZMPersistentCookieStorage setDoNotPersistToKeychain:NO];
        
#if ! TARGET_IPHONE_SIMULATOR
        // On the Xcode Continuous Intergration server the tests run as a user whose username starts with an underscore.
        BOOL const runningOnIntegrationServer = [[[NSProcessInfo processInfo] environment][@"USER"] hasPrefix:@"_"];
        if (runningOnIntegrationServer) {
            [ZMPersistentCookieStorage setDoNotPersistToKeychain:YES];
        }
#endif
    } else {
        [ZMPersistentCookieStorage setDoNotPersistToKeychain:YES];
    }
    
    [self resetUIandSyncContextsAndResetPersistentStore:YES];
    
    [ZMPersistentCookieStorage deleteAllKeychainItems];
    
    self.testMOC = [MockModelObjectContextFactory testContext];
    [self.testMOC addGroup:self.dispatchGroup];
    self.alternativeTestMOC = [MockModelObjectContextFactory alternativeMocForPSC:self.testMOC.persistentStoreCoordinator];
    [self.alternativeTestMOC addGroup:self.dispatchGroup];
    self.searchMOC = [NSManagedObjectContext createSearchContextWithStoreDirectory:self.databaseDirectory];
    [self.searchMOC addGroup:self.dispatchGroup];
    self.mockTransportSession = [[MockTransportSession alloc] initWithDispatchGroup:self.dispatchGroup];
    self.mockTransportSession.cryptoboxLocation = [UserClientKeysStore otrDirectory];
    Require([self waitForAllGroupsToBeEmptyWithTimeout:5]);
}

- (void)tearDown;
{
    [(id)_mockUserSession stopMocking];
    _mockUserSession = nil;

    ZMConversationDefaultLastReadTimestampSaveDelay = self.originalConversationLastReadTimestampTimerValue;

    [self resetState];
    [MessagingTest deleteAllFilesInCache];
    [super tearDown];
    Require([self waitForAllGroupsToBeEmptyWithTimeout:5]);
}

- (void)resetState
{
    [self.uiMOC.globalManagedObjectContextObserver tearDown];
    [self.uiMOC zm_tearDownCallTimer];
    [self.testMOC zm_tearDownCallTimer];
    
    [self.syncMOC performGroupedBlock:^{
        [self.syncMOC.globalManagedObjectContextObserver tearDown];
        [self.syncMOC zm_tearDownCallTimer];
        [self.syncMOC zm_tearDownCryptKeyStore];
        [self.syncMOC.userInfo removeAllObjects];
    }];

    WaitForAllGroupsToBeEmpty(0.5);
    
    // teardown all mmanagedObjectContexts
    [self cleanUpAndVerify];

    [self.mockTransportSession tearDown];
    self.mockTransportSession = nil;
    
    self.ignoreTestDebugFlagForTestTimers = NO;
    [NSManagedObjectContext resetUserInterfaceContext];
    [NSManagedObjectContext resetSharedPersistentStoreCoordinator];
}

- (void)waitAndDeleteAllManagedObjectContexts;
{
    NSManagedObjectContext *refUiMOC = self.uiMOC;
    NSManagedObjectContext *refTestMOC = self.testMOC;
    NSManagedObjectContext *refAlternativeTestMOC = self.alternativeTestMOC;
    NSManagedObjectContext *refSearchMoc = self.searchMOC;
    NSManagedObjectContext *refSyncMoc = self.syncMOC;
    
    WaitForAllGroupsToBeEmpty(2);
    
    self.uiMOC = nil;
    self.syncMOC = nil;
    self.testMOC = nil;
    self.alternativeTestMOC = nil;
    self.searchMOC = nil;
    
    [refUiMOC performBlockAndWait:^{
        // Do nothing.
    }];
    [refSyncMoc performBlockAndWait:^{
        
    }];
    [self.mockTransportSession.managedObjectContext performBlockAndWait:^{
        // Do nothing
    }];
    [refTestMOC performBlockAndWait:^{
        // Do nothing
    }];
    [refAlternativeTestMOC performBlockAndWait:^{
        // Do nothing
    }];
    [refSearchMoc performBlockAndWait:^{
        // Do nothing
    }];
    
    [refUiMOC.globalManagedObjectContextObserver tearDown];

    [refSyncMoc performGroupedBlockAndWait:^{
        [refSyncMoc.globalManagedObjectContextObserver tearDown];
    }];
}

- (void)cleanUpAndVerify {
    //[self.mockTransportSession expireAllBlockedRequests];
    [self waitAndDeleteAllManagedObjectContexts];
    [self verifyMocksNow];
}

- (void)resetUIandSyncContextsAndResetPersistentStore:(BOOL)resetPersistentStore
{
    [self resetUIandSyncContextsAndResetPersistentStore:resetPersistentStore notificationContentHidden:NO];
}

- (void)resetUIandSyncContextsAndResetPersistentStore:(BOOL)resetPersistentStore notificationContentHidden:(BOOL)notificationContentVisible;
{
    [self.uiMOC zm_tearDownCallTimer];
    [self.syncMOC zm_tearDownCallTimer];
    
    [self.syncMOC.globalManagedObjectContextObserver tearDown];
    [self.uiMOC.globalManagedObjectContextObserver tearDown];
    
    NSString *clientID = [self.uiMOC persistentStoreMetadataForKey:ZMPersistedClientIdKey];
    self.uiMOC = nil;
    self.syncMOC = nil;
    
    WaitForAllGroupsToBeEmpty(2);
    
    [NSManagedObjectContext resetUserInterfaceContext];
    
    if (resetPersistentStore) {
        [NSManagedObjectContext resetSharedPersistentStoreCoordinator];
    }
    [self performIgnoringZMLogError:^{
        self.uiMOC = [NSManagedObjectContext createUserInterfaceContextWithStoreDirectory:self.databaseDirectory];
        self.uiMOC.globalManagedObjectContextObserver.propagateChanges = YES;
    }];
    
    ImageAssetCache *imageAssetCache = [[ImageAssetCache alloc] initWithMBLimit:100];
    FileAssetCache *fileAssetCache = [[FileAssetCache alloc] init];
    
    [self.uiMOC addGroup:self.dispatchGroup];
    self.uiMOC.userInfo[@"TestName"] = self.name;
    
    self.syncMOC = [NSManagedObjectContext createSyncContextWithStoreDirectory:self.databaseDirectory];
    [self.syncMOC performGroupedBlockAndWait:^{
        self.syncMOC.userInfo[@"TestName"] = self.name;
        [self.syncMOC addGroup:self.dispatchGroup];
        [self.syncMOC saveOrRollback];
        
        [self.syncMOC setZm_userInterfaceContext:self.uiMOC];
        [self.syncMOC setPersistentStoreMetadata:@(notificationContentVisible) forKey:@"ZMShouldNotificationContentKey"];
        self.syncMOC.zm_imageAssetCache = imageAssetCache;
        self.syncMOC.zm_fileAssetCache = fileAssetCache;
    }];
    
    WaitForAllGroupsToBeEmpty(2);
    
    [self.uiMOC setPersistentStoreMetadata:clientID forKey:ZMPersistedClientIdKey];
    [self.uiMOC saveOrRollback];
    WaitForAllGroupsToBeEmpty(2);
    
    
    [self.uiMOC setZm_syncContext:self.syncMOC];
    [self.uiMOC   setPersistentStoreMetadata:@(notificationContentVisible) forKey:@"ZMShouldNotificationContentKey"];

    self.uiMOC.zm_imageAssetCache = imageAssetCache;
    self.uiMOC.zm_fileAssetCache = fileAssetCache;
}

- (id<ZMObjectStrategyDirectory>)createMockObjectStrategyDirectoryInMoc:(NSManagedObjectContext *)moc;
{
    id objectDirectory = [OCMockObject mockForProtocol:@protocol(ZMObjectStrategyDirectory)];
    
    id userTranscoder = [OCMockObject mockForClass:ZMUserTranscoder.class];
    [self verifyMockLater:userTranscoder];
    id userImageTranscoder = [OCMockObject mockForClass:ZMUserImageTranscoder.class];
    [self verifyMockLater:userImageTranscoder];
    id conversationTranscoder = [OCMockObject mockForClass:ZMConversationTranscoder.class];
    [self verifyMockLater:conversationTranscoder];
    id systemMessageTranscoder = [OCMockObject mockForClass:ZMSystemMessageTranscoder.class];
    [self verifyMockLater:systemMessageTranscoder];
    id clientMessageTranscoder = [OCMockObject mockForClass:ZMClientMessageTranscoder.class];
    [self verifyMockLater:clientMessageTranscoder];
    id selfTranscoder = [OCMockObject mockForClass:ZMSelfTranscoder.class];
    [self verifyMockLater:selfTranscoder];
    id connectionTranscoder = [OCMockObject mockForClass:ZMConnectionTranscoder.class];
    [self verifyMockLater:connectionTranscoder];
    id registrationTranscoder = [OCMockObject mockForClass:ZMRegistrationTranscoder.class];
    [self verifyMockLater:registrationTranscoder];
    id phoneNumberVerificationTranscoder = [OCMockObject mockForClass:ZMPhoneNumberVerificationTranscoder.class];
    [self verifyMockLater:phoneNumberVerificationTranscoder];
    id missingUpdateEventsTranscoder = [OCMockObject mockForClass:ZMMissingUpdateEventsTranscoder.class];
    [self verifyMockLater:missingUpdateEventsTranscoder];
    id lastUpdateEventIDTranscoder = [OCMockObject mockForClass:ZMLastUpdateEventIDTranscoder.class];
    [self verifyMockLater:lastUpdateEventIDTranscoder];
    id flowTranscoder = [OCMockObject mockForClass:ZMFlowSync.class];
    [self verifyMockLater:flowTranscoder];
    id callStateTranscoder = [OCMockObject mockForClass:ZMCallStateTranscoder.class];
    [self verifyMockLater:callStateTranscoder];
    id pushTokenTranscoder = [OCMockObject mockForClass:ZMPushTokenTranscoder.class];
    [self verifyMockLater:pushTokenTranscoder];
    id loginTranscoder = [OCMockObject mockForClass:ZMLoginTranscoder.class];
    [self verifyMockLater:loginTranscoder];
    id loginCodeRequestTranscoder = [OCMockObject mockForClass:ZMLoginCodeRequestTranscoder.class];
    [self verifyMockLater:loginCodeRequestTranscoder];
    id searchUserImageTranscoder = [OCMockObject mockForClass:ZMSearchUserImageTranscoder.class];
    [self verifyMockLater:searchUserImageTranscoder];
    id typingTranscoder = [OCMockObject mockForClass:ZMTypingTranscoder.class];
    [self verifyMockLater:typingTranscoder];
    id removedSuggestedPeopleTranscoder = [OCMockObject mockForClass:ZMRemovedSuggestedPeopleTranscoder.class];
    [self verifyMockLater:removedSuggestedPeopleTranscoder];
    id userProfileUpdateTranscoder = [OCMockObject mockForClass:ZMUserProfileUpdateTranscoder.class];
    [self verifyMockLater:userProfileUpdateTranscoder];
    
    
    [[[objectDirectory stub] andReturn:userTranscoder] userTranscoder];
    [[[objectDirectory stub] andReturn:userImageTranscoder] userImageTranscoder];
    [[[objectDirectory stub] andReturn:conversationTranscoder] conversationTranscoder];
    [[[objectDirectory stub] andReturn:systemMessageTranscoder] systemMessageTranscoder];
    [[[objectDirectory stub] andReturn:clientMessageTranscoder] clientMessageTranscoder];
    [[[objectDirectory stub] andReturn:selfTranscoder] selfTranscoder];
    [[[objectDirectory stub] andReturn:connectionTranscoder] connectionTranscoder];
    [[[objectDirectory stub] andReturn:registrationTranscoder] registrationTranscoder];
    [[[objectDirectory stub] andReturn:phoneNumberVerificationTranscoder] phoneNumberVerificationTranscoder];
    [[[objectDirectory stub] andReturn:missingUpdateEventsTranscoder] missingUpdateEventsTranscoder];
    [[[objectDirectory stub] andReturn:lastUpdateEventIDTranscoder] lastUpdateEventIDTranscoder];
    [[[objectDirectory stub] andReturn:flowTranscoder] flowTranscoder];
    [[[objectDirectory stub] andReturn:callStateTranscoder] callStateTranscoder];
    [[[objectDirectory stub] andReturn:pushTokenTranscoder] pushTokenTranscoder];
    [[[objectDirectory stub] andReturn:loginTranscoder] loginTranscoder];
    [[[objectDirectory stub] andReturn:loginCodeRequestTranscoder] loginCodeRequestTranscoder];
    [[[objectDirectory stub] andReturn:searchUserImageTranscoder] searchUserImageTranscoder];
    [[[objectDirectory stub] andReturn:typingTranscoder] typingTranscoder];
    [[[objectDirectory stub] andReturn:removedSuggestedPeopleTranscoder] removedSuggestedPeopleTranscoder];
    [[[objectDirectory stub] andReturn:userProfileUpdateTranscoder] userProfileUpdateTranscoder];
    
    [[[objectDirectory stub] andReturn:@[
                                        userTranscoder,
                                        userImageTranscoder,
                                        conversationTranscoder,
                                        systemMessageTranscoder,
                                        clientMessageTranscoder,
                                        selfTranscoder,
                                        connectionTranscoder,
                                        registrationTranscoder,
                                        phoneNumberVerificationTranscoder,
                                        missingUpdateEventsTranscoder,
                                        lastUpdateEventIDTranscoder,
                                        flowTranscoder,
                                        callStateTranscoder,
                                        pushTokenTranscoder,
                                        loginTranscoder,
                                        loginCodeRequestTranscoder,
                                        searchUserImageTranscoder,
                                        typingTranscoder,
                                        removedSuggestedPeopleTranscoder,
                                        userProfileUpdateTranscoder
                                        ]] allTranscoders];
    
    
    [[[objectDirectory stub] andReturn:moc] moc];
    [self verifyMockLater:objectDirectory];

    return objectDirectory;
}

- (ZMUserSession *)mockUserSession
{
    if (nil == _mockUserSession) {
        id mockUserSession = [OCMockObject niceMockForClass:[ZMUserSession class]];
        [[[mockUserSession stub] andReturn:self.uiMOC] managedObjectContext];
        _mockUserSession = mockUserSession;
    }
    
    return _mockUserSession;
}

- (BOOL)waitWithTimeout:(NSTimeInterval)timeout forSaveOfContext:(NSManagedObjectContext *)moc untilBlock:(BOOL(^)(void))block;
{
    Require(moc != nil);
    Require(block != nil);
    
    timeout = [MessagingTest timeToUseForOriginalTime:timeout];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    NSDate * const start = [NSDate date];
    NSNotificationCenter * const center = [NSNotificationCenter defaultCenter];
    id token = [center addObserverForName:NSManagedObjectContextDidSaveNotification object:moc queue:nil usingBlock:^(NSNotification *note) {
        NOT_USED(note);
        if (block()) {
            dispatch_semaphore_signal(sem);
        }
    }];
    
    BOOL success = NO;
    
    // We try to block the current thread as much as possible to not use too much CPU:
    NSDate * const stopDate = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ((! success) && (NSDate.timeIntervalSinceReferenceDate < stopDate.timeIntervalSinceReferenceDate)) {
        // Block this thread for a bit:
        NSTimeInterval const blockingTimeout = 0.01;
        success = (0 == dispatch_semaphore_wait(sem, dispatch_walltime(NULL, llround(blockingTimeout * NSEC_PER_SEC))));
        // Let anything on the main run loop run:
        [MessagingTest performRunLoopTick];
    }
    
    [center removeObserver:token];
    PrintTimeoutWarning(self, timeout, -[start timeIntervalSinceNow]);
    return success;
}


@end



@implementation MessagingTest (Asyncronous)

- (NSArray *)allManagedObjectContexts;
{
    NSMutableArray *result = [NSMutableArray array];
    if (self.uiMOC != nil) {
        [result addObject:self.uiMOC];
    }
    if (self.syncMOC != nil) {
        [result addObject:self.syncMOC];
    }
    if (self.testMOC != nil) {
        [result addObject:self.testMOC];
    }
    if (self.alternativeTestMOC != nil) {
        [result addObject:self.alternativeTestMOC];
    }
    if (self.searchMOC != nil) {
        [result addObject:self.searchMOC];
    }
    if (self.mockTransportSession.managedObjectContext != nil) {
        [result addObject:self.mockTransportSession.managedObjectContext];
    }

    return result;
}

- (NSArray *)allDispatchGroups;
{
    NSMutableArray *groups = [NSMutableArray array];
    [groups addObject:self.dispatchGroup];
    for (NSManagedObjectContext *moc in self.allManagedObjectContexts) {
        [groups addObject:moc.dispatchGroup];
    }
    return groups;
}


- (XCTestExpectation *)expectationForSaveOnContext:(NSManagedObjectContext *)moc withUpdateOfClass:(Class)aClass handler:(SaveExpectationHandler)handler;
{
    return [self expectationForNotification:NSManagedObjectContextDidSaveNotification object:moc handler:^BOOL(NSNotification *notification) {
        NSSet *updated = notification.userInfo[NSUpdatedObjectsKey];
        for (ZMManagedObject *mo in updated) {
            if ([mo isKindOfClass:aClass] &&
                handler(mo))
            {
                return YES;
            }
        }
        return NO;
    }];
}

@end



@implementation MessagingTest (DisplayNameGenerator)

- (void)updateDisplayNameGeneratorWithUsers:(NSArray *)users;
{
    [self.uiMOC saveOrRollback];
    NSNotification *note = [NSNotification notificationWithName:@"TestNotification" object:nil userInfo:@{
                                                                                              NSInsertedObjectsKey : [NSSet setWithArray:users],
                                                                                              NSUpdatedObjectsKey :[NSSet set],
                                                                                              NSDeletedObjectsKey : [NSSet set]
                                                                                              }];
    [self.uiMOC updateDisplayNameGeneratorWithChanges:note];
}

@end




@implementation MessagingTest (AVS)

- (void)simulateMediaFlowEstablishedOnConversation:(ZMConversation *)uiConversation;
{
    [self.mockTransportSession.mockFlowManager.delegate didEstablishMediaInConversation:uiConversation.remoteIdentifier.transportString];
}

- (void)simulateParticipantsChanged:(NSArray *)users onConversation:(ZMConversation *)uiConversation;
{
    NSArray *userIDString = [users mapWithBlock:^id(MockUser *user) {
        return user.identifier;
    }];
    [self.mockTransportSession performRemoteChanges:^(ZM_UNUSED id session) {
        [self.mockTransportSession.mockFlowManager.delegate conferenceParticipantsDidChange:userIDString inConversation:uiConversation.remoteIdentifier.transportString];
    }];
}


- (void)simulateMediaFlowReleasedOnConversation:(ZMConversation *)uiConversation;
{
    [self.mockTransportSession performRemoteChanges:^(ZM_UNUSED id session) {
        [self.mockTransportSession.mockFlowManager.delegate errorHandler:0 conversationId:uiConversation.remoteIdentifier.transportString context:nil];
    }];
}

@end


@implementation MessagingTest (UserTesting)

- (void)setEmailAddress:(NSString *)emailAddress onUser:(ZMUser *)user;
{
    user.emailAddress = emailAddress;
}

- (void)setPhoneNumber:(NSString *)phoneNumber onUser:(ZMUser *)user;
{
    user.phoneNumber = phoneNumber;
}

@end



@implementation MessagingTest (FilesInCache)

+ (NSURL *)cacheFolder {
    return (NSURL *)[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
}

+ (void)deleteAllFilesInCache {
    NSFileManager *fm = [NSFileManager defaultManager];
    for(NSURL *url in [self filesInCache]) {
        [fm removeItemAtURL:url error:nil];
    }
}

+ (NSSet *)filesInCache {
    return [NSSet setWithArray:[[NSFileManager defaultManager] contentsOfDirectoryAtURL:[self cacheFolder] includingPropertiesForKeys:@[NSURLNameKey] options:0 error:nil]];
}

@end


@implementation MessagingTest (OTR)

- (NSData *)encryptedMessage:(ZMGenericMessage *)message recipient:(UserClient *)recipient
{
    [self establishSessionWithClient:recipient];
    
    __block NSData *messageData;
    __block NSError *error;
    
    [self.syncMOC.zm_cryptKeyStore.encryptionContext perform:^(EncryptionSessionsDirectory * _Nonnull sessionsDirectory) {
        messageData = [sessionsDirectory encrypt:message.data recipientClientId:recipient.remoteIdentifier error:&error];
    }];

    XCTAssertNil(error, @"Error encrypting message: %@", error);
    return messageData;
}

- (void)establishSessionWithClient:(UserClient *)userClient
{
    ZMUser *selfUser = [ZMUser selfUserInContext:self.syncMOC];
    
    __block NSError *error;
    __block NSString *lastPrekey;
    __block BOOL hasSession = NO;
    
    [selfUser.selfClient.keysStore.encryptionContext perform:^(EncryptionSessionsDirectory * _Nonnull sessionsDirectory) {
        if (![sessionsDirectory hasSessionForID:userClient.remoteIdentifier]) {
            lastPrekey = [sessionsDirectory generateLastPrekeyAndReturnError:&error];
        } else {
            hasSession = YES;
        }
    }];
    
    if (hasSession) {
        return;
    }
    
    XCTAssertTrue([selfUser.selfClient establishSessionWithClient:userClient usingPreKey:lastPrekey], @"Unable to establish session");
    XCTAssertNil(error, @"Error establishing session: %@", error);
}

- (UserClient *)setupSelfClientInMoc:(NSManagedObjectContext *)moc;
{
    ZMUser *selfUser = [ZMUser selfUserInContext:moc];
    if (selfUser.remoteIdentifier == nil) {
        selfUser.remoteIdentifier = [NSUUID createUUID];
    }
    
    UserClient *client = [UserClient insertNewObjectInManagedObjectContext:moc];
    client.remoteIdentifier = [NSString createAlphanumericalString];
    client.user = selfUser;
    
    [moc setPersistentStoreMetadata:client.remoteIdentifier forKey:ZMPersistedClientIdKey];
    [moc saveOrRollback];
    
    return client;
}

- (UserClient *)createSelfClient
{
    UserClient *selfClient = [self setupSelfClientInMoc:self.syncMOC];
    [UserClient createOrUpdateClient:@{@"id": selfClient.remoteIdentifier, @"type": @"permanent", @"time": [[NSDate date] transportString]} context:self.syncMOC];
    [self.syncMOC saveOrRollback];
    
    return selfClient;
}

- (UserClient *)createClientForUser:(ZMUser *)user createSessionWithSelfUser:(BOOL)createSessionWithSeflUser
{
    if(user.remoteIdentifier == nil) {
        user.remoteIdentifier = [NSUUID createUUID];
    }
    UserClient *userClient = [UserClient insertNewObjectInManagedObjectContext:self.syncMOC];
    userClient.remoteIdentifier = [NSString createAlphanumericalString];
    userClient.user = user;
    
    if (createSessionWithSeflUser) {
        [self establishSessionWithClient:userClient];
    }

    return userClient;
}

- (UserClient *)createClientForMockUser:(MockUser *)mockUser createSessionWithSelfUser:(BOOL)createSessionWithSeflUser
{
    ZMUser *user = [ZMUser fetchObjectWithRemoteIdentifier:mockUser.identifier.UUID inManagedObjectContext:self.syncMOC];
    if(user) {
        return [self createClientForUser:user createSessionWithSelfUser:createSessionWithSeflUser];
    }
    return nil;
}

- (ZMClientMessage *)createClientTextMessage:(BOOL)encrypted
{
    return [self createClientTextMessage:self.name encrypted:encrypted];
}

- (ZMClientMessage *)createClientTextMessage:(NSString *)text encrypted:(BOOL)encrypted
{
    ZMClientMessage *message = [ZMClientMessage insertNewObjectInManagedObjectContext:self.syncMOC];
    NSUUID *messageNonce = [NSUUID createUUID];
    ZMGenericMessage *textMessage = [ZMGenericMessage messageWithText:text nonce:messageNonce.transportString expiresAfter:nil];
    [message addData:textMessage.data];
    message.isEncrypted = encrypted;
    return message;
}

- (ZMAssetClientMessage *)createImageMessageWithImageData:(NSData *)imageData format:(ZMImageFormat)format processed:(BOOL)processed stored:(BOOL)stored encrypted:(BOOL)encrypted moc:(NSManagedObjectContext *)moc
{
    NSUUID *nonce = [NSUUID createUUID];
    ZMAssetClientMessage *imageMessage = [ZMAssetClientMessage assetClientMessageWithOriginalImageData:imageData nonce:nonce managedObjectContext:moc expiresAfter:0];
    imageMessage.isEncrypted = encrypted;
    
    if(processed) {
        
        CGSize imageSize = [ZMImagePreprocessor sizeOfPrerotatedImageWithData:imageData];
        ZMIImageProperties *properties = [ZMIImageProperties imagePropertiesWithSize:imageSize
                                                                              length:imageData.length
                                                                            mimeType:@"image/jpeg"];
        ZMImageAssetEncryptionKeys *keys = nil;
        if (encrypted) {
            keys = [[ZMImageAssetEncryptionKeys alloc] initWithOtrKey:[NSData zmRandomSHA256Key]
                                                               macKey:[NSData zmRandomSHA256Key]
                                                                  mac:[NSData zmRandomSHA256Key]];
        }
        
        ZMGenericMessage *message = [ZMGenericMessage genericMessageWithMediumImageProperties:properties processedImageProperties:properties encryptionKeys:keys nonce:nonce.transportString format:format expiresAfter:nil];
        [imageMessage addGenericMessage:message];
        
        ImageAssetCache *directory = self.uiMOC.zm_imageAssetCache;
        if (stored) {
            [directory storeAssetData:nonce format:ZMImageFormatOriginal encrypted:NO data:imageData];
        }
        if (processed) {
            [directory storeAssetData:nonce format:format encrypted:NO data:imageData];
        }
        if (encrypted) {
            [directory storeAssetData:nonce format:format encrypted:YES data:imageData];
        }
    }
    return imageMessage;
}

@end


@implementation  MessagingTest (SwiftBridgeConversation)

- (void)simulateUnreadCount:(NSUInteger)unreadCount forConversation:(ZMConversation *)conversation;
{
    BOOL isSyncContext = conversation.managedObjectContext.zm_isSyncContext;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMConversation *syncConv = conversation;
        if (!isSyncContext) {
            NSManagedObjectID *objectID = conversation.objectID;
            syncConv = (id)[self.syncMOC objectWithID:objectID];
        }
        syncConv.internalEstimatedUnreadCount = [@(unreadCount) intValue];
        [self.syncMOC saveOrRollback];
    }];
    if (!isSyncContext) {
        [self.uiMOC refreshObject:conversation mergeChanges:YES];
    }
}

- (void)simulateUnreadMissedCallInConversation:(ZMConversation *)conversation;
{
    BOOL isSyncContext = conversation.managedObjectContext.zm_isSyncContext;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMConversation *syncConv = conversation;
        if (!isSyncContext) {
            NSManagedObjectID *objectID = conversation.objectID;
            syncConv = (id)[self.syncMOC objectWithID:objectID];
        }
        syncConv.lastUnreadMissedCallDate = [NSDate date];
        [self.syncMOC saveOrRollback];
    }];
    if (!isSyncContext) {
        [self.uiMOC refreshObject:conversation mergeChanges:YES];
    }
}


- (void)simulateUnreadMissedKnockInConversation:(ZMConversation *)conversation;
{
    BOOL isSyncContext = conversation.managedObjectContext.zm_isSyncContext;
    [self.syncMOC performGroupedBlockAndWait:^{
        ZMConversation *syncConv = conversation;
        if (!isSyncContext) {
            NSManagedObjectID *objectID = conversation.objectID;
            syncConv = (id)[self.syncMOC objectWithID:objectID];
        }
        syncConv.lastUnreadKnockDate = [NSDate date];
        [self.syncMOC saveOrRollback];
    }];
    if (!isSyncContext) {
        [self.uiMOC refreshObject:conversation mergeChanges:YES];
    }
}

@end
