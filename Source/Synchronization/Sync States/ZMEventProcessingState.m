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


@import ZMUtilities;
@import WireRequestStrategy;

#import "ZMEventProcessingState.h"
#import "ZMConnectionTranscoder.h"
#import "ZMUserTranscoder.h"
#import "ZMSyncStrategy.h"
#import "ZMTestNotifications.h"
#import "ZMSyncStateDelegate.h"
#import "ZMStateMachineDelegate.h"
#import "ZMHotFix.h"
#import <zmessaging/zmessaging-Swift.h>

@interface ZMEventProcessingState ()

@property (nonatomic) NSArray *syncObjects;
@property (nonatomic) BOOL isSyncing; // Only used to send a notification to UI that syncing finished
@property (nonatomic) SyncStatus *slowSynStatus;

@end;



@implementation ZMEventProcessingState

-(BOOL)shouldProcessLiveEvents
{
    return YES;
}

- (instancetype)initWithAuthenticationCenter:(ZMAuthenticationStatus *)authenticationStatus
                    clientRegistrationStatus:(ZMClientRegistrationStatus *)clientRegistrationStatus
                     objectStrategyDirectory:(id<ZMObjectStrategyDirectory>)objectStrategyDirectory
                        stateMachineDelegate:(id<ZMStateMachineDelegate>)stateMachineDelegate
                               slowSynStatus:(SyncStatus *)slowSynStatus;
{
    
    self = [super initWithAuthenticationCenter:authenticationStatus
                      clientRegistrationStatus:clientRegistrationStatus
                       objectStrategyDirectory:objectStrategyDirectory
                          stateMachineDelegate:stateMachineDelegate];
    if (self) {
        self.slowSynStatus = slowSynStatus;
        self.syncObjects = @[
                             objectStrategyDirectory.flowTranscoder,
                             objectStrategyDirectory.callStateTranscoder,
                             objectStrategyDirectory.selfTranscoder,
                             objectStrategyDirectory.systemMessageTranscoder,
                             objectStrategyDirectory.clientMessageTranscoder,
                             ];
        
        for (id<ZMObjectStrategy> syncObject in self.syncObjects) {
            Require([syncObject conformsToProtocol:@protocol(ZMObjectStrategy)]);
        }
    }
    return self;
}

- (ZMTransportRequest *)nextRequest
{
    if (self.slowSynStatus.currentSyncPhase != SyncPhaseDone) {
        // TODO Sabine: Message related transcoders should probably not send messages at this point in order to not get the enryption keys out of order
        return nil;
    }
    
    ZMTransportRequest *request = [self nextRequestFromTranscoders:self.syncObjects];
    if (self.isSyncing && request == nil) {
        self.isSyncing = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:ZMTestSynchronizationStoppedNotification object:nil];
    }
    
    self.isSyncing = (request != nil);
    
    return request;
}

- (void)didEnterState
{
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMApplicationDidEnterEventProcessingStateNotificationName object:nil];
}

- (void)tearDown
{
    self.syncObjects = nil;
    [super tearDown];
}

@end
