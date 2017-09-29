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

@import Foundation;
@import WireSyncEngine;
@import CallKit;

NS_ASSUME_NONNULL_BEGIN

@interface CallKitDelegateTestsMocking: NSObject
+ (void)mockUserSession:(id)userSession callKitDelegate:(id)callKitDelegate;
+ (CXCall *)mockCallWithUUID:(NSUUID *)uuid outgoing:(BOOL)outgoing;
+ (void)stopMockingMock:(NSObject *)Mock;

@end

NS_ASSUME_NONNULL_END
