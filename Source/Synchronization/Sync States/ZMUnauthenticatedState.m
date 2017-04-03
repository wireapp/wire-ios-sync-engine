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


@import UIKit;
@import ZMCSystem;
@import ZMUtilities;
@import ZMCDataModel;

#import "ZMUnauthenticatedState+Tests.h"
#import "ZMStateMachineDelegate.h"
#import "ZMUserSession+Internal.h"
#import "ZMSyncStrategy.h"
#import "ZMSelfStrategy.h"
#import "ZMObjectStrategyDirectory.h"
#import "ZMLoginTranscoder+Internal.h"
#import "ZMLoginCodeRequestTranscoder.h"
#import "ZMAuthenticationStatus.h"
#import "ZMCredentials.h"
#import "NSError+ZMUserSessionInternal.h"
#import "ZMStateMachineDelegate.h"
#import "ZMUserSessionAuthenticationNotification.h"
#import "ZMRegistrationTranscoder.h"
#import "ZMPhoneNumberVerificationTranscoder.h"

static NSString *const TimerInfoOriginalCredentialsKey = @"originalCredentials";
NSTimeInterval DebugLoginFailureTimerOverride = 0;

static NSString *ZMLogTag ZM_UNUSED = @"State machine";

// if the request will fail in less than 50ms, don't even start it
static NSTimeInterval const RequestFailureTimeIntervalBufferTime = 0.05;

@interface ZMUnauthenticatedState ()

@property (nonatomic) ZMTimer* loginFailureTimer;
@property (nonatomic) NSDate* lastTimerStart;
@property (nonatomic, weak) id<ZMApplication>application;
@property (nonatomic) BOOL didLaunchInForeground;

@end



@implementation ZMUnauthenticatedState

+ (NSTimeInterval)loginTimeout;
{
    if (DebugLoginFailureTimerOverride > 0) {
        return DebugLoginFailureTimerOverride;
    }
    return 30.0;
}

- (instancetype)initWithAuthenticationCenter:(ZMAuthenticationStatus *)authenticationStatus
                    clientRegistrationStatus:(ZMClientRegistrationStatus *)clientRegistrationStatus
                     objectStrategyDirectory:(id<ZMObjectStrategyDirectory>)objectStrategyDirectory
                        stateMachineDelegate:(id<ZMStateMachineDelegate>)stateMachineDelegate
                                 application:(id<ZMApplication>)application;
{
    self = [super initWithAuthenticationCenter:authenticationStatus
                      clientRegistrationStatus:clientRegistrationStatus
                       objectStrategyDirectory:objectStrategyDirectory
                          stateMachineDelegate:stateMachineDelegate];
    if(self) {
        self.loginFailureTimer = nil;
        self.lastTimerStart = nil;
        self.application = application;
    }
    return self;
}

- (void)tearDown
{
    [self.loginFailureTimer cancel];
    self.loginFailureTimer = nil;
    [super tearDown];
}

- (void)dealloc
{
    [self tearDown];
}

- (BOOL)isLoggedIn
{
    return self.authenticationStatus.currentPhase == ZMAuthenticationPhaseAuthenticated &&
           self.clientRegistrationStatus.currentPhase == ZMClientRegistrationPhaseRegistered;
}

- (BOOL)isDoneWithLogin
{
    return self.isLoggedIn
        && [self.objectStrategyDirectory.selfStrategy isSelfUserComplete];
}

- (void)dataDidChange
{
    if(self.shouldEnterEventProcessingState) {
        id<ZMStateMachineDelegate> stateMachine = self.stateMachineDelegate;
        [stateMachine goToState:stateMachine.eventProcessingState];
    }
}

- (BOOL)shouldEnterEventProcessingState
{
    if (!self.didLaunchInForeground && self.application.applicationState != UIApplicationStateBackground) {
        self.didLaunchInForeground = YES;
    }
    return (self.isDoneWithLogin && self.didLaunchInForeground);
}

- (ZMTransportRequest *)nextRequest
{
    if([self isDoneWithLogin]) {
        if (self.shouldEnterEventProcessingState) {
            id<ZMStateMachineDelegate> stateMachine = self.stateMachineDelegate;
            [stateMachine goToState:stateMachine.eventProcessingState];
        }
        return nil;
    }
    
    //TODO: sync strategy should ask transcoders for next request and they should ask auth status for current state to decide if they need to return request
    id<ZMObjectStrategyDirectory> directory = self.objectStrategyDirectory;
    ZMClientRegistrationPhase clientRegPhase  = self.clientRegistrationStatus.currentPhase;

    switch(self.authenticationStatus.currentPhase) {
        case ZMAuthenticationPhaseLoginWithEmail:
        case ZMAuthenticationPhaseLoginWithPhone:
        case ZMAuthenticationPhaseWaitingForEmailVerification:
            return [self loginRequest];
        case ZMAuthenticationPhaseRegisterWithEmail:
        case ZMAuthenticationPhaseRegisterWithPhone:
            return [[directory.registrationTranscoder requestGenerators] nextRequest];
        case ZMAuthenticationPhaseRequestPhoneVerificationCodeForRegistration:
        case ZMAuthenticationPhaseVerifyPhoneForRegistration:
            return [directory.phoneNumberVerificationTranscoder nextRequest];
        case ZMAuthenticationPhaseRequestPhoneVerificationCodeForLogin:
            return [[[directory loginCodeRequestTranscoder] requestGenerators] nextRequest];
        case ZMAuthenticationPhaseUnauthenticated:
            return [self loginRequest]; // this will, confusingly, also resend verification emails
        case ZMAuthenticationPhaseAuthenticated:
            if (clientRegPhase == ZMClientRegistrationPhaseWaitingForEmailVerfication) {
                return [self loginRequest];
            }
            return nil;
    }
}

- (ZMTransportRequest *)loginRequest
{
    id<ZMObjectStrategyDirectory> directory = self.objectStrategyDirectory;
    ZMTransportRequest *request = [[directory.loginTranscoder requestGenerators] nextRequest];
    
    if (self.shouldRunTimerForLoginExpiration)
    {
        if(self.lastTimerStart == nil) {
            [self startLoginTimer];
        }
        
        // Fail the login if I did not get a response within the timeout, no matter what
        NSTimeInterval diff = [ZMUnauthenticatedState loginTimeout] - [[NSDate date] timeIntervalSinceDate:self.lastTimerStart] - RequestFailureTimeIntervalBufferTime;
        if (diff > 0) {
            [request expireAfterInterval:diff];
            return request;
        }
        return nil;
    }
    
    ZM_WEAK(self);
    [request addCompletionHandler:[ZMCompletionHandler handlerOnGroupQueue:directory.moc block:^(ZMTransportResponse * response) {
        NOT_USED(response);
        ZM_STRONG(self);
        [ZMRequestAvailableNotification notifyNewRequestsAvailable:self];
    }]];
    
    // this could be any other request
    return request;
}

- (void)didFailAuthentication {
    // nop
}


- (void)didEnterBackground
{
    id<ZMStateMachineDelegate> stateMachine = self.stateMachineDelegate;
    [stateMachine goToState:stateMachine.unauthenticatedBackgroundState];
}

- (void)didEnterForeground
{
    self.didLaunchInForeground = YES;

    if ([self isDoneWithLogin]) {
        id<ZMStateMachineDelegate> stateMachine = self.stateMachineDelegate;
        [stateMachine goToState:stateMachine.eventProcessingState];
    }
}

- (void)stopLoginTimer
{
    [self.loginFailureTimer cancel];
    self.loginFailureTimer = nil;
    self.lastTimerStart = nil;
}

- (void)startLoginTimer
{
    [self.loginFailureTimer cancel];
    self.loginFailureTimer = nil;
    self.loginFailureTimer = [ZMTimer timerWithTarget:self];
    self.lastTimerStart = [NSDate date];
    self.loginFailureTimer.userInfo = @{TimerInfoOriginalCredentialsKey : self.authenticationStatus.loginCredentials};
    [self.loginFailureTimer fireAfterTimeInterval:[ZMUnauthenticatedState loginTimeout]];
}

- (void)didChangeAuthenticationData
{
    ZMAuthenticationStatus *authStatus  = self.authenticationStatus;

    [self.loginFailureTimer cancel];
    self.loginFailureTimer = nil;
    if (authStatus.currentPhase == ZMAuthenticationPhaseLoginWithEmail || authStatus.currentPhase == ZMAuthenticationPhaseLoginWithPhone)
    {
        [self startLoginTimer];
    }
    if (authStatus.currentPhase == ZMAuthenticationPhaseRegisterWithEmail || authStatus.currentPhase == ZMAuthenticationPhaseRegisterWithPhone) {
        [self.objectStrategyDirectory.registrationTranscoder resetRegistrationState];
    }
    [self dataDidChange];
}

- (ZMUpdateEventsPolicy)updateEventsPolicy
{
    return ZMUpdateEventPolicyIgnore;
}

- (void)timerDidFire:(ZMTimer * __unused)timer
{
    [[self.objectStrategyDirectory moc] performGroupedBlock:^{
        [self.authenticationStatus didTimeoutLoginForCredentials:timer.userInfo[TimerInfoOriginalCredentialsKey]];
    }];
    
}

- (BOOL)shouldRunTimerForLoginExpiration
{
    ZMAuthenticationPhase authPhase  = self.authenticationStatus.currentPhase;
    return authPhase == ZMAuthenticationPhaseLoginWithEmail || authPhase == ZMAuthenticationPhaseLoginWithPhone;
}

- (void)didEnterState
{
    id<ZMObjectStrategyDirectory> directory = self.objectStrategyDirectory;

    id<ZMStateMachineDelegate> stateMachine = self.stateMachineDelegate;
    
    if ([self isDoneWithLogin]) {
        ZMLogDebug(@"%@ is already logged in on enter, starting quick sync", self.class);
        [stateMachine goToState:stateMachine.eventProcessingState];
        return;
    }
    
    ZMAuthenticationStatus *authenticationStatus = self.authenticationStatus;
    
    [directory.registrationTranscoder resetRegistrationState];
    
    if (self.shouldRunTimerForLoginExpiration) {
        [self startLoginTimer];
    }
    
    [authenticationStatus addAuthenticationCenterObserver:self];
}

- (void)didLeaveState
{
    [self stopLoginTimer];
    [self.authenticationStatus removeAuthenticationCenterObserver:self];
}

@end
