//
// Wire
// Copyright (C) 2019 Wire Swiss GmbH
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

import Foundation

extension ZMLocalNotification {
    
    convenience init?(availability: Availability, managedObjectContext moc: NSManagedObjectContext) {
        let builder = AvailabilityNotificationBuilder(availability: availability, managedObjectContext: moc)
        
        self.init(conversation: nil, builder: builder)
    }
    
}

private class AvailabilityNotificationBuilder: NotificationBuilder {
    
    let managedObjectContext: NSManagedObjectContext
    let availability: Availability
    
    
    init(availability: Availability, managedObjectContext: NSManagedObjectContext) {
        self.availability = availability
        self.managedObjectContext = managedObjectContext
    }
    
    var notificationType: LocalNotificationType {
        return .availabilityBehaviourChangeAlert
    }
    
    func shouldCreateNotification() -> Bool {
        return availability.isOne(of: .away, .busy) && ZMUser.selfUser(in: managedObjectContext).isTeamMember
    }
    
    func titleText() -> String? {
        return "🚨 Your notifications are disabled" // TODO jacob final copy
    }
    
    func bodyText() -> String {
        return "Your current status is set to away, which from now on disables notifications" // TODO jacob final copy
    }
    
    func userInfo() -> NotificationUserInfo? {
        return nil
    }
}
