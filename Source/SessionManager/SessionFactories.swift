//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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


import avs

open class AuthenticatedSessionFactory {

    let appVersion: String
    let mediaManager: MediaManagerType
    let flowManager: FlowManagerType
    var analytics: AnalyticsType?
    let application: ZMApplication
    var environment: BackendEnvironmentProvider
    let reachability: ReachabilityProvider & TearDownCapable

    public init(
        appVersion: String,
        application: ZMApplication,
        mediaManager: MediaManagerType,
        flowManager: FlowManagerType,
        environment: BackendEnvironmentProvider,
        reachability: ReachabilityProvider & TearDownCapable,
        analytics: AnalyticsType? = nil) {
        self.appVersion = appVersion
        self.mediaManager = mediaManager
        self.flowManager = flowManager
        self.analytics = analytics
        self.application = application
        self.environment = environment
        self.reachability = reachability
    }

    func session(
        for account: Account,
        storeProvider: LocalStoreProviderProtocol,
        configuration: ZMUserSession.Configuration,
        userClientDelegate: UserClientDelegate?,
        logoutDelegate: LogoutDelegate?) -> ZMUserSession? {

        let transportSession = ZMTransportSession(
            environment: environment,
            cookieStorage: environment.cookieStorage(for: account),
            reachability: reachability,
            initialAccessToken: nil,
            applicationGroupIdentifier: nil,
            applicationVersion: appVersion
        )

        let userSession = ZMUserSession(
            transportSession: transportSession,
            mediaManager: mediaManager,
            flowManager:flowManager,
            analytics: analytics,
            application: application,
            appVersion: appVersion,
            storeProvider: storeProvider,
            configuration: configuration,
            userClientDelegate: userClientDelegate,
            logoutDelegate: logoutDelegate
        )
        
        userSession.startRequestLoopTracker()
        
        return userSession
    }
    
}


open class UnauthenticatedSessionFactory {

    var environment: BackendEnvironmentProvider
    let reachability: ReachabilityProvider
    let authenticationStatus: ZMAuthenticationStatus
    let groupQueue: DispatchGroupQueue
    let appVersion: String
    
    init(appVersion: String,
         environment: BackendEnvironmentProvider,
         reachability: ReachabilityProvider,
         authenticationStatus: ZMAuthenticationStatus,
         groupQueue: DispatchGroupQueue) {
        self.environment = environment
        self.reachability = reachability
        self.authenticationStatus = authenticationStatus
        self.groupQueue = groupQueue
        self.appVersion = appVersion
    }

    func session(withDelegate delegate: UnauthenticatedSessionDelegate) -> UnauthenticatedSession {
        let transportSession = UnauthenticatedTransportSession(environment: environment,
                                                               reachability: reachability,
                                                               applicationVersion: appVersion)
        return UnauthenticatedSession(transportSession: transportSession,
                                      reachability: reachability,
                                      authenticationStatus: authenticationStatus,
                                      groupQueue: groupQueue,
                                      delegate: delegate)
    }
}
