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


@import WireTransport;
@import WireRequestStrategy;

#import <WireSyncEngine/WireSyncEngine-Swift.h>

#import "ZMLoginCodeRequestTranscoder.h"
#import "ZMAuthenticationStatus.h"
#import "ZMAuthenticationStatus.h"
#import "ZMCredentials.h"
#import "NSError+ZMUserSessionInternal.h"

@interface ZMLoginCodeRequestTranscoder() <ZMSingleRequestTranscoder>

@property (nonatomic, weak) ZMAuthenticationStatus *authenticationStatus;
@property (nonatomic) ZMSingleRequestSync *codeRequestSync;
@property (nonatomic, weak) id<ZMSGroupQueue> groupQueue;

@end

@implementation ZMLoginCodeRequestTranscoder

- (instancetype)initWithGroupQueue:(id<ZMSGroupQueue>)groupQueue authenticationStatus:(ZMAuthenticationStatus *)authenticationStatus
{
    self = [super init];
    if (self != nil) {
        self.groupQueue = groupQueue;
        self.authenticationStatus = authenticationStatus;
        self.codeRequestSync = [[ZMSingleRequestSync alloc] initWithSingleRequestTranscoder:self groupQueue:groupQueue];
        [self.codeRequestSync readyForNextRequest];
    }
    return self;
}

- (ZMTransportRequest *)nextRequestForAPIVersion:(ZMAPIVersion)apiVersion
{
    if (self.authenticationStatus.currentPhase == ZMAuthenticationPhaseRequestPhoneVerificationCodeForLogin) {
        [self.codeRequestSync readyForNextRequestIfNotBusy];
        return [self.codeRequestSync nextRequestForAPIVersion:apiVersion];
    }
    return nil;
}

#pragma mark - ZMSingleRequestTranscoder

- (ZMTransportRequest *)requestForSingleRequestSync:(__unused ZMSingleRequestSync *)sync;
{
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:@"/login/send"
                                                                    method:ZMMethodPOST
                                                                   payload:@{@"phone": self.authenticationStatus.loginPhoneNumberThatNeedsAValidationCode}
                                                            authentication:ZMTransportRequestAuthNone
                                                                apiVersion:v0];
    return request;
}

- (void)didReceiveResponse:(ZMTransportResponse *)response forSingleRequest:(__unused ZMSingleRequestSync *)sync
{
    ZMAuthenticationStatus *authStatus  = self.authenticationStatus;
    if(response.result == ZMTransportResponseStatusSuccess) {
        [authStatus didCompleteRequestForLoginCodeSuccessfully];
    }
    else {
        NSError *error = {
            [NSError pendingLoginErrorWithResponse:response] ?:
            [NSError unauthorizedErrorWithResponse:response] ?:
            [NSError invalidPhoneNumberErrorWithReponse:response] ?:
            [NSError userSessionErrorWithErrorCode:ZMUserSessionUnknownError userInfo:nil]
        };

        [authStatus didFailRequestForLoginCode:error];
    }
}

@end
