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

import Foundation
import WireSyncEngine

/// A mock of Application that records the calls
@objc public final class ApplicationMock : NSObject {
    
    public var applicationState: UIApplicationState = .active
    
    public var alertNotificationsEnabled: Bool = false
    
    /// Records calls to `scheduleLocalNotification`
    public var scheduledLocalNotifications : [UILocalNotification] = []
    
    /// Records calls to `cancelledLocalNotifications`
    public var cancelledLocalNotifications : [UILocalNotification] = []
    
    /// Records calls to `registerForRemoteNotification`
    public var registerForRemoteNotificationCount : Int = 0
    
    /// The current badge icon number
    public var applicationIconBadgeNumber: Int = 0
    
    /// Records calls to `registerUserNotificationSettings`
    public var registeredUserNotificationSettings : [UIUserNotificationSettings] = []
    
    /// Records calls to `setMinimumBackgroundFetchInterval`
    public var minimumBackgroundFetchInverval : TimeInterval = UIApplicationBackgroundFetchIntervalNever
    
    /// Callback invoked when `registerUserNotificationSettings` is invoked
    public var registerForRemoteNotificationsCallback : ()->() = { _ in }
}

// MARK: - Application protocol
extension ApplicationMock : Application {
    
    public func scheduleLocalNotification(_ notification: UILocalNotification) {
        self.scheduledLocalNotifications.append(notification)
    }
    
    public func cancelLocalNotification(_ notification: UILocalNotification) {
        self.cancelledLocalNotifications.append(notification)
    }
    
    public func registerForRemoteNotifications() {
        self.registerForRemoteNotificationCount += 1
        self.registerForRemoteNotificationsCallback()
    }
    
    public func registerUserNotificationSettings(_ settings: UIUserNotificationSettings) {
        self.registeredUserNotificationSettings.append(settings)
    }
    
    public func setMinimumBackgroundFetchInterval(_ minimumBackgroundFetchInterval: TimeInterval) {
        self.minimumBackgroundFetchInverval = minimumBackgroundFetchInterval
    }
}

// MARK: - Observers
extension ApplicationMock {
    
    @objc public func registerObserverForDidBecomeActive(_ object: NSObject, selector: Selector) {
        NotificationCenter.default.addObserver(object, selector: selector, name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
    }
    
    @objc public func registerObserverForWillResignActive(_ object: NSObject, selector: Selector) {
        NotificationCenter.default.addObserver(object, selector: selector, name: NSNotification.Name.UIApplicationWillResignActive, object: nil)
    }
    
    @objc public func registerObserverForWillEnterForeground(_ object: NSObject, selector: Selector) {
        NotificationCenter.default.addObserver(object, selector: selector, name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
    }
    
    @objc public func registerObserverForDidEnterBackground(_ object: NSObject, selector: Selector) {
        NotificationCenter.default.addObserver(object, selector: selector, name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
    }
    
    @objc public func registerObserverForApplicationWillTerminate(_ object: NSObject, selector: Selector) {
        NotificationCenter.default.addObserver(object, selector: selector, name: NSNotification.Name.UIApplicationWillTerminate, object: nil)
    }
    
    @objc public func unregisterObserverForStateChange(_ object: NSObject) {
        NotificationCenter.default.removeObserver(object, name: NSNotification.Name.UIApplicationWillResignActive, object: nil)
        NotificationCenter.default.removeObserver(object, name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
        NotificationCenter.default.removeObserver(object, name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
        NotificationCenter.default.removeObserver(object, name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.removeObserver(object, name: NSNotification.Name.UIApplicationWillTerminate, object: nil)
    }
}

// MARK: - Simulate application state change
extension ApplicationMock {
    
    @objc public func simulateApplicationDidBecomeActive() {
        NotificationCenter.default.post(name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
    }
    
    @objc public func simulateApplicationWillResignActive() {
        NotificationCenter.default.post(name: NSNotification.Name.UIApplicationWillResignActive, object: nil)
    }
    
    @objc public func simulateApplicationWillEnterForeground() {
        NotificationCenter.default.post(name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
    }
    
    @objc public func simulateApplicationDidEnterBackground() {
        NotificationCenter.default.post(name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
    }
    
    @objc public func simulateApplicationWillTerminate() {
        NotificationCenter.default.post(name: NSNotification.Name.UIApplicationWillTerminate, object: nil)
    }
    
    var isInBackground : Bool {
        return self.applicationState == .background
    }
    
    @objc func setBackground() {
        self.applicationState = .background
    }
    
    var isInactive : Bool {
        return self.applicationState == .inactive
    }
    
    @objc func setInactive() {
        self.applicationState = .inactive
    }
    
    var isActive : Bool {
        return self.applicationState == .active
    }
    
    @objc func setActive() {
        self.applicationState = .active
    }

}
