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


@import CoreTelephony;
@import ZMCDataModel;

#import "ZMOnDemandFlowManager.h"
#import "ZMAVSBridge.h"
#import "ZMUserSession.h"
#import "ZMVoiceChannel+CallFlow.h"
#import "ZMVoiceChannel+VideoCalling.h"
#import "AVSFlowManager.h"
#import <zmessaging/zmessaging-Swift.h>


@implementation ZMVoiceChannel (CallFlow)

- (AVSFlowManager *)flowManager
{
    return [[ZMAVSBridge flowManagerClass] getInstance];
}

- (void)startOrCancelTimerForState:(ZMVoiceChannelState)state
{
    switch (state) {
        case ZMVoiceChannelStateNoActiveUsers:
        case ZMVoiceChannelStateSelfConnectedToActiveChannel:
        case ZMVoiceChannelStateSelfIsJoiningActiveChannel:
        case ZMVoiceChannelStateDeviceTransferReady:
        case ZMVoiceChannelStateInvalid:
            [self resetTimer];
            break;
        case ZMVoiceChannelStateOutgoingCall:
        case ZMVoiceChannelStateIncomingCall:
            if (self.conversation.callParticipants.count > 0) {
                [self startTimer];
            } else {
                // the timer should only be started when there are callParticipants
                // if there are no call participants, but callDeviceIsActive is set, we were previously joined
                [self resetTimer];
            }
            break;
        case ZMVoiceChannelStateIncomingCallInactive:
        case ZMVoiceChannelStateOutgoingCallInactive:
            break;
    }
}


- (void)join
{
    ZMConversation *conv = self.conversation;
    
    if ([self hasOngoingGSMCall]) {
        [conv.managedObjectContext.zm_userInterfaceContext performGroupedBlock: ^{
                [CallingInitialisationNotification notifyCallingFailedWithErrorCode:ZMVoiceChannelErrorCodeOngoingGSMCall];
            }];
        return;
    }
   
    [conv.managedObjectContext.zm_userInterfaceContext performGroupedBlock: ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:self userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey: @YES}];
    }];
    
    if(!conv.callDeviceIsActive) {
        [ZMUserSession appendAVSLogMessageForConversation:conv withMessage:@"Self user wants to join voice channel"];
    }
    conv.isOutgoingCall = (conv.callParticipants.count == 0);
    conv.isIgnoringCall = NO;
    conv.callDeviceIsActive = YES;
}

- (void)leave;
{
    [self leaveWithReason:ZMCallStateReasonToLeaveUser];
}

- (void)leaveOnAVSError
{
    [self leaveWithReason:ZMCallStateReasonToLeaveAvsError];
}

- (void)leaveWithReason:(ZMCallStateReasonToLeave)reasonToLeave
{
    ZMConversation *conv = self.conversation;
    
    if (conv.isVideoCall) {
        [self.flowManager setVideoSendState:FLOWMANAGER_VIDEO_SEND_NONE forConversation:conv.remoteIdentifier.transportString];
    }
    
    if (conv.callDeviceIsActive) {
        NSString *leaveMessage = [NSString stringWithFormat:@"Left voice channel: reason is %@", [ZMCallStateReasonToLeaveDescriber reasonToLeaveToString:reasonToLeave]];
        [ZMUserSession appendAVSLogMessageForConversation:conv withMessage:leaveMessage];
    }
    conv.callDeviceIsActive = NO;
    conv.reasonToLeave = reasonToLeave;
    
    if (conv.conversationType != ZMConversationTypeOneOnOne) {
        conv.isIgnoringCall = YES; // when selfUser leaves call we don't want it to ring
    }
    
    if (conv.callParticipants.count <= 2) {
        [self resetCallState];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:self userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey: @NO}];
}

+ (NSComparator)conferenceComparator
{
    Class flowManagerClass = [ZMAVSBridge flowManagerClass];
    NSComparator result = [flowManagerClass conferenceComparator];
    if (result == nil) {
        result = ^NSComparisonResult(NSString *obj1, NSString *obj2) {
            return [obj1 compare:obj2];
        };
    }
    return result;
}

- (void)updateActiveFlowParticipants:(NSArray *)newParticipants
{
    ZMConversation *conv = self.conversation;
    if ([conv.activeFlowParticipants isEqual:newParticipants]) {
        return;
    }
    if (conv.isOutgoingCall) {
        conv.isOutgoingCall = NO; // reset outgoingCall State, so that the phone does not start ringing if the flow gets interrupted
    }
    NSMutableOrderedSet *mutableParticipants = [NSMutableOrderedSet orderedSetWithArray:newParticipants];

    [mutableParticipants zm_sortUsingComparator:[self.class conferenceComparator] valueGetter:^id(ZMUser *user) {
        return user.remoteIdentifier.UUIDString;
    }];

    conv.activeFlowParticipants = [NSOrderedSet orderedSetWithOrderedSet:mutableParticipants];
    [self updateForStateChange];
}

- (void)addCallParticipant:(ZMUser *)participant
{
    NSMutableOrderedSet *participants = [self.conversation mutableOrderedSetValueForKey:ZMConversationCallParticipantsKey];
    [participants addObject:participant];
    
    [self reSortCallParticipants:participants];

    [self updateForStateChange];    
}

- (void)removeCallParticipant:(ZMUser *)participant
{
    ZMConversation *conversation = self.conversation;
    
    NSMutableOrderedSet *participants = [conversation mutableOrderedSetValueForKey:ZMConversationCallParticipantsKey];
    [participants removeObject:participant];
    
    if (participant.isSelfUser) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionShouldKeepWebsocketOpenNotificationName
                                                            object:self
                                                          userInfo:@{ZMTransportSessionShouldKeepWebsocketOpenKey: @NO}];
    }
    
    if (participants.count > 0) {
        [self reSortCallParticipants:participants];
        if (participant.isSelfUser) {
            conversation.isIgnoringCall = YES;
        }
    }
    else {
        [self resetCallState];
    }

    [self updateForStateChange];
}

- (void)reSortCallParticipants:(NSMutableOrderedSet *)participants
{    
    [participants zm_sortUsingComparator:[self.class conferenceComparator] valueGetter:^id(ZMUser *user) {
        return user.remoteIdentifier.UUIDString;
    }];
}

- (void)removeAllCallParticipants
{
    if (self.conversation.callParticipants.count == 0) {
        return;
    }
    [self resetCallState];
    [self updateForStateChange];
}

- (void)resetCallState
{
    ZMConversation *conversation = self.conversation;
    NSMutableOrderedSet *callParticipants = [conversation mutableOrderedSetValueForKey:ZMConversationCallParticipantsKey];
    [callParticipants removeAllObjects];
    
    conversation.callTimedOut = NO;
    conversation.isIgnoringCall = NO;
    conversation.isOutgoingCall = NO;
    conversation.isVideoCall = NO;
    conversation.isSendingVideo = NO;
    conversation.isFlowActive = NO;
    conversation.activeFlowParticipants = [NSOrderedSet orderedSet];
    conversation.otherActiveVideoCallParticipants = [NSSet set];
    if (conversation.managedObjectContext.zm_isSyncContext) {
        [conversation.managedObjectContext zm_resetCallTimer:conversation];
    }
}

- (void)ignoreIncomingCall
{
    ZMConversation *conv = self.conversation;
    
    if(!conv.isIgnoringCall) {
        [ZMUserSession appendAVSLogMessageForConversation:conv withMessage:@"Self user wants to ignore incoming call"];
    }
    conv.isIgnoringCall = YES;
}

- (void)updateForStateChange
{
    [self startOrCancelTimerForState:self.state];
    
    if (self.conversation.isVideoCall) {
        NSError *error = nil;
        if (self.state == ZMVoiceChannelStateIncomingCall || self.state == ZMVoiceChannelStateOutgoingCall) {
           
            if (nil != error) {
                ZMLogError(@"Cannot set video send state: %@", error);
            }
        }
        else if (self.state == ZMVoiceChannelStateNoActiveUsers) {
            [self setVideoSendState:FLOWMANAGER_VIDEO_SEND_NONE error:&error];
            
            if (nil != error) {
                ZMLogError(@"Cannot set video send state: %@", error);
            }
        }
    }
}

- (void)tearDown
{
    ZMConversation *conv = self.conversation;
    if (!conv.managedObjectContext.zm_isSyncContext) {
        return;
    }
    [conv.managedObjectContext zm_resetCallTimer:conv];
}

@end


@implementation ZMConversation (CallFlow)

- (void)prepareForDeletion
{
    if(self.managedObjectContext.zm_isSyncContext) {
        [self.managedObjectContext zm_resetCallTimer:self];
    }
    [super prepareForDeletion];
}

@end

