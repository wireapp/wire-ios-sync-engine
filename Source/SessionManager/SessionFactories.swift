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
import WireDataModel

open class AuthenticatedSessionFactory {

    let appVersion: String
    let mediaManager: MediaManagerType
    let flowManager: FlowManagerType
    var analytics: AnalyticsType?
    let application: ZMApplication

    var environment: BackendEnvironmentProvider
    var reachability: Reachability

    public init(
        appVersion: String,
        application: ZMApplication,
        mediaManager: MediaManagerType,
        flowManager: FlowManagerType,
        environment: BackendEnvironmentProvider,
        proxyUsername: String?,
        proxyPassword: String?,
        reachability: Reachability,
        analytics: AnalyticsType? = nil) {

            self.appVersion = appVersion
            self.mediaManager = mediaManager
            self.flowManager = flowManager
            self.analytics = analytics
            self.application = application
            self.environment = environment
            self.proxyUsername = proxyUsername
            self.proxyPassword = proxyPassword
            self.reachability = reachability
        }

    func session(
        for account: Account,
        coreDataStack: CoreDataStack,
        configuration: ZMUserSession.Configuration) -> ZMUserSession? {

        let transportSession = ZMTransportSession(
            environment: environment,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword,
            cookieStorage: environment.cookieStorage(for: account),
            reachability: reachability,
            initialAccessToken: nil,
            applicationGroupIdentifier: nil,
            applicationVersion: appVersion
        )

        let userSession = ZMUserSession(
            userId: account.userIdentifier,
            transportSession: transportSession,
            mediaManager: mediaManager,
            flowManager: flowManager,
            analytics: analytics,
            application: application,
            appVersion: appVersion,
            coreDataStack: coreDataStack,
            configuration: configuration
        )

        userSession.startRequestLoopTracker()

        return userSession
    }

    public func updateProxy(username: String?, password: String?) {
        self.proxyUsername = username
        self.proxyPassword = password
    }

    // MARK: - Private

    private(set) var proxyUsername: String?
    private(set) var proxyPassword: String?
}

// MARK: -

open class UnauthenticatedSessionFactory {

    var environment: BackendEnvironmentProvider
    var reachability: Reachability

    var readyForRequests: Bool = false
    let appVersion: String

    init(
      appVersion: String,
      environment: BackendEnvironmentProvider,
      proxyUsername: String?,
      proxyPassword: String?,
      reachability: Reachability
    ) {
        self.environment = environment
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.reachability = reachability
        self.appVersion = appVersion
    }

    func session(
      delegate: UnauthenticatedSessionDelegate,
      authenticationStatusDelegate: ZMAuthenticationStatusDelegate
    ) -> UnauthenticatedSession {
        let transportSession = UnauthenticatedTransportSession(
          environment: environment,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          reachability: reachability,
          applicationVersion: appVersion,
          readyForRequests: readyForRequests
        )

      return UnauthenticatedSession(
        transportSession: transportSession,
        reachability: reachability,
        delegate: delegate,
        authenticationStatusDelegate: authenticationStatusDelegate
      )
    }

    public func updateProxy(username: String?, password: String?) {
        self.proxyUsername = username
        self.proxyPassword = password
    }

    // MARK: - Private

    private var proxyUsername: String?
    private var proxyPassword: String?
}
