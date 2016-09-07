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


#import "ZMUserSession.h"
#import "ZMUserSession+Internal.h"
#import "ZMOperationLoop.h"

@implementation ZMUserSession (Proxy)

- (void)proxiedRequestWithPath:(NSString * __nonnull)path method:(ZMTransportRequestMethod)method type:(ProxiedRequestType)type callback:(void (^__nullable)(NSData * __nullable, NSHTTPURLResponse * __nonnull, NSError * __nullable))callback;
{
    [self.syncManagedObjectContext performGroupedBlock:^{
        [self.proxiedRequestStatus addRequest:type path:path method:method callback:callback];
        [ZMRequestAvailableNotification notifyNewRequestsAvailable:self];
    }];
}

@end
