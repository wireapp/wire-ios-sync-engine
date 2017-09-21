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


@import WireUtilities;
@import WireTransport;
@import WireDataModel;

#import "ZMLoginTranscoder+Internal.h"
#import "ZMAuthenticationStatus.h"
#import "ZMCredentials.h"
#import "NSError+ZMUserSessionInternal.h"
#import "ZMUserSession+Internal.h"
#import "ZMUserSessionRegistrationNotification.h"
#import <WireSyncEngine/WireSyncEngine-Swift.h>

NSString * const ZMLoginURL = @"/login?persist=true";
NSString * const ZMResendVerificationURL = @"/activate/send";
static ZMTransportRequestMethod const LoginMethod = ZMMethodPOST;
NSTimeInterval DefaultPendingValidationLoginAttemptInterval = 5;


@interface ZMLoginTranscoder () <ZMRequestVerificationEmailObserver>

@property (nonatomic, weak) ZMAuthenticationStatus *authenticationStatus;
@property (nonatomic, weak) id<UserInfoParser> userInfoParser;
@property (nonatomic, readonly) ZMSingleRequestSync *verificationResendRequest;
@property (nonatomic) id emailResendObserverToken;
@property (nonatomic, weak) id<ZMSGroupQueue> groupQueue;

@end


@implementation ZMLoginTranscoder

- (instancetype)initWithGroupQueue:(id<ZMSGroupQueue>)groupQueue
              authenticationStatus:(ZMAuthenticationStatus *)authenticationStatus
                    userInfoParser:(id<UserInfoParser>)userInfoParser
{
    return [self initWithGroupQueue:groupQueue
               authenticationStatus:authenticationStatus
                     userInfoParser:userInfoParser
                timedDownstreamSync:nil
          verificationResendRequest:nil];
}

- (instancetype)initWithGroupQueue:(id<ZMSGroupQueue>)groupQueue
              authenticationStatus:(ZMAuthenticationStatus *)authenticationStatus
                    userInfoParser:(id<UserInfoParser>)userInfoParser
               timedDownstreamSync:(ZMTimedSingleRequestSync *)timedDownstreamSync
         verificationResendRequest:(ZMSingleRequestSync *)verificationResendRequest
{
    self = [super init];
    
    if (self != nil) {
        self.groupQueue = groupQueue;
        self.authenticationStatus = authenticationStatus;
        self.userInfoParser = userInfoParser;
        _timedDownstreamSync = timedDownstreamSync ?: [[ZMTimedSingleRequestSync alloc] initWithSingleRequestTranscoder:self everyTimeInterval:0 groupQueue:groupQueue];
        _verificationResendRequest = verificationResendRequest ?: [[ZMSingleRequestSync alloc] initWithSingleRequestTranscoder:self groupQueue:groupQueue];
        
        self.emailResendObserverToken = [ZMUserSessionRegistrationNotification addObserverForRequestForVerificationEmail:self context:authenticationStatus];
        
        _loginWithPhoneNumberSync = [[ZMSingleRequestSync alloc] initWithSingleRequestTranscoder:self groupQueue:groupQueue];
    }
    return self;
}

- (ZMStrategyConfigurationOption)configuration
{
    return ZMStrategyConfigurationOptionAllowsRequestsWhileUnauthenticated;
}

- (void)didChangeAuthenticationData
{
    self.timedDownstreamSync.timeInterval = 0;
}

- (void)tearDown
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.timedDownstreamSync invalidate];
}

- (ZMTransportRequest *)nextRequest
{
    ZMAuthenticationStatus *authenticationStatus = self.authenticationStatus;
    ZMTransportRequest *request;
    
    request = [self.verificationResendRequest nextRequest];
    if(request) {
        return request;
    }
    
    if(authenticationStatus.currentPhase == ZMAuthenticationPhaseLoginWithPhone) {
        [self.loginWithPhoneNumberSync readyForNextRequestIfNotBusy];
        return [self.loginWithPhoneNumberSync nextRequest];
    }
    if(authenticationStatus.currentPhase == ZMAuthenticationPhaseLoginWithEmail) {
        [self.timedDownstreamSync readyForNextRequestIfNotBusy];
        request = [self.timedDownstreamSync nextRequest];
    }
    if(authenticationStatus.currentPhase == ZMAuthenticationPhaseWaitingForEmailVerification)
    {
        request = [self.timedDownstreamSync nextRequest];
    }

    return request;
}

- (void)processEvents:(NSArray<ZMUpdateEvent *> __unused *)events
           liveEvents:(BOOL __unused)liveEvents
       prefetchResult:(__unused ZMFetchRequestBatchResult *)prefetchResult;
{
    // no op
}

- (NSArray *)contextChangeTrackers
{
    return @[];
}

- (void)didReceiveRequestToResendValidationEmail
{
    [self.groupQueue performGroupedBlock:^{
        [self.verificationResendRequest readyForNextRequest];
        [ZMRequestAvailableNotification notifyNewRequestsAvailable:self];
    }];
}

- (BOOL)isWaitingForEmailVerification
{
    ZMAuthenticationPhase authenticationPhase = self.authenticationStatus.currentPhase;
    return authenticationPhase == ZMAuthenticationPhaseWaitingForEmailVerification || authenticationPhase == ZMAuthenticationPhaseLoginWithEmail;
}

- (ZMTransportRequest *)requestForSingleRequestSync:(ZMSingleRequestSync *)sync
{
    if (sync == self.timedDownstreamSync ||
        sync == self.loginWithPhoneNumberSync) {
        return [self loginRequest];
    }
    else if (sync == self.verificationResendRequest) {
        return [self resendEmailVerificationRequest];
    }
    else {
        return nil;
    }
}

- (ZMTransportRequest *)loginRequest
{
    ZMAuthenticationStatus *authenticationStatus = self.authenticationStatus;
    if (authenticationStatus.currentPhase == ZMAuthenticationPhaseAuthenticated) {
        return nil;
    }
    ZMCredentials *credentials = authenticationStatus.loginCredentials;
    if(credentials == nil) {
        return nil;
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    if (credentials.email != nil && credentials.password != nil) {
        payload[@"email"] = credentials.email;
        payload[@"password"] = credentials.password;
    }
    else if (credentials.phoneNumber != nil && credentials.phoneNumberVerificationCode != nil) {
        payload[@"phone"] = credentials.phoneNumber;
        payload[@"code"] = credentials.phoneNumberVerificationCode;
    }
    else {
        return nil;
    }
    if (CookieLabel.current.length != 0) {
        payload[@"label"] = CookieLabel.current.value;
    }
    return [[ZMTransportRequest alloc] initWithPath:ZMLoginURL method:LoginMethod payload:payload authentication:ZMTransportRequestAuthCreatesCookieAndAccessToken];

}

- (ZMTransportRequest *)resendEmailVerificationRequest
{
    ZMAuthenticationStatus * authenticationStatus = self.authenticationStatus;
    NSString *email;
    if(authenticationStatus.currentPhase == ZMAuthenticationPhaseWaitingForEmailVerification) {
        email = authenticationStatus.loginCredentials.email;
    }
    if (email.length == 0) {
        return nil;
    }
    NSDictionary *payload = @{@"email" : email,
                              @"locale" : [NSLocale formattedLocaleIdentifier] };
    return [[ZMTransportRequest alloc] initWithPath:ZMResendVerificationURL method:ZMMethodPOST payload:payload authentication:ZMTransportRequestAuthNone];
}

- (void)didReceiveResponse:(ZMTransportResponse *)response forSingleRequest:(ZMSingleRequestSync *)sync
{
    if (sync == self.verificationResendRequest) {
        return;
    }
    
    BOOL shouldStartTimer = NO;
    ZMAuthenticationStatus * authenticationStatus = self.authenticationStatus;
    if (response.result == ZMTransportResponseStatusSuccess) {
        [authenticationStatus loginSucceed];
        [self.userInfoParser parseUserInfoFromResponse:response];
    }
    else if (response.result == ZMTransportResponseStatusPermanentError) {
        
        if ([self isResponseForSuspendedAccount:response]) {
            [authenticationStatus didFailLoginBecauseAccountSuspended];
        }
        else if (sync == self.timedDownstreamSync) {
            
            if([self isResponseForPendingEmailActionvation:response]) {
//                if (self.isWaitingForEmailVerification) { // TODO jacob this must be wrong
                    [authenticationStatus didFailLoginWithEmailBecausePendingValidation];
                    shouldStartTimer = YES;
//                }
            }
            else {
                [authenticationStatus didFailLoginWithEmail:[self isResponseForInvalidCredentials:response]];
            }
        }
        else if (sync == self.loginWithPhoneNumberSync) {
            [authenticationStatus didFailLoginWithPhone:[self isResponseForInvalidCredentials:response]];
        }
    }

    if (shouldStartTimer) {
        if(self.timedDownstreamSync.timeInterval != DefaultPendingValidationLoginAttemptInterval) {
            self.timedDownstreamSync.timeInterval = DefaultPendingValidationLoginAttemptInterval;
        }
    }
    else {
        self.timedDownstreamSync.timeInterval = 0;
    }
}

- (BOOL)isResponseForInvalidCredentials:(ZMTransportResponse *)response
{
    NSString *label = [response.payload asDictionary][@"label"];
    return [label isEqualToString:@"invalid-credentials"] || [label isEqualToString:@"invalid-key"];
}

- (BOOL)isResponseForPendingEmailActionvation:(ZMTransportResponse *)response
{
    NSString *label = [response.payload asDictionary][@"label"];
    return [label isEqualToString:@"pending-activation"];
}

- (BOOL)isResponseForSuspendedAccount:(ZMTransportResponse *)response
{
    NSString *label = [response.payload asDictionary][@"label"];
    return response.HTTPStatus == 403 && [label isEqualToString:@"suspended"];
}

@end
