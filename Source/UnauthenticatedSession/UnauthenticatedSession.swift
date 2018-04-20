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

import Foundation
import WireUtilities

public protocol UnauthenticatedSessionDelegate: class {
    /// Update credentials for the corresponding user session. Returns true if the credentials were accepted.
    func session(session: UnauthenticatedSession, updatedCredentials credentials: ZMCredentials)  -> Bool
    func session(session: UnauthenticatedSession, updatedProfileImage imageData: Data)
    func session(session: UnauthenticatedSession, createdAccount account: Account)
    func session(session: UnauthenticatedSession, isExistingAccount account: Account) -> Bool
}

@objc public protocol UserInfoParser: class {
    @objc(userIdentifierFromResponse:)
    func userIdentifier(from response: ZMTransportResponse) -> UUID?
    @objc(accountExistsLocallyFromResponse:)
    func accountExistsLocally(from response: ZMTransportResponse) -> Bool
    @objc(parseUserInfoFromResponse:)
    func parseUserInfo(from response: ZMTransportResponse)
}

private let log = ZMSLog(tag: "UnauthenticatedSession")


@objc
public class UnauthenticatedSession: NSObject {
    
    public let groupQueue: DispatchGroupQueue
    private(set) public var authenticationStatus: ZMAuthenticationStatus!
    public let registrationStatus: RegistrationStatus 
    let reachability: ReachabilityProvider
    private(set) var operationLoop: UnauthenticatedOperationLoop!
    private let transportSession: UnauthenticatedTransportSessionProtocol
    fileprivate var tornDown = false

    weak var delegate: UnauthenticatedSessionDelegate?

    init(transportSession: UnauthenticatedTransportSessionProtocol, reachability: ReachabilityProvider, delegate: UnauthenticatedSessionDelegate?) {
        self.delegate = delegate
        self.groupQueue = DispatchGroupQueue(queue: .main)
        self.registrationStatus = RegistrationStatus()
        self.transportSession = transportSession
        self.reachability = reachability
        super.init()

        self.authenticationStatus = ZMAuthenticationStatus(groupQueue: groupQueue, userInfoParser: self)
        self.operationLoop = UnauthenticatedOperationLoop(
            transportSession: transportSession,
            operationQueue: groupQueue,
            requestStrategies: [
                ZMLoginTranscoder(groupQueue: groupQueue, authenticationStatus: authenticationStatus),
                ZMLoginCodeRequestTranscoder(groupQueue: groupQueue, authenticationStatus: authenticationStatus)!,
                ZMRegistrationTranscoder(groupQueue: groupQueue, authenticationStatus: authenticationStatus)!,
                ZMPhoneNumberVerificationTranscoder(groupQueue: groupQueue, authenticationStatus: authenticationStatus)!,
                EmailVerificationStrategy(groupQueue: groupQueue, status: registrationStatus),
                TeamRegistrationStrategy(groupQueue: groupQueue, status: registrationStatus, userInfoParser: self)
            ]
        )
    }

    deinit {
        precondition(tornDown, "Need to call tearDown before deinit")
    }

    func authenticationErrorIfNotReachable(_ block: () -> ()) {
        if self.reachability.mayBeReachable {
            block()
        } else {
            authenticationStatus.notifyAuthenticationDidFail(NSError(code: .networkError, userInfo:nil))
        }
    }
}

extension UnauthenticatedSession: TearDownCapable {
    public func tearDown() {
        operationLoop.tearDown()
        tornDown = true
    }
}

// MARK: - UserInfoParser

extension UnauthenticatedSession: UserInfoParser {
    public func userIdentifier(from response: ZMTransportResponse) -> UUID? {
        guard let info = response.extractUserInfo() else {
            log.warn("Failed to parse UserInfo from response: \(response)")
            return nil;
        }
        return info.identifier
    }

    public func accountExistsLocally(from response: ZMTransportResponse) -> Bool {
        guard let info = response.extractUserInfo() else {
            log.warn("Failed to parse UserInfo from response: \(response)")
            return false
        }
        let account = Account(userName: "", userIdentifier: info.identifier)
        guard let delegate = delegate else { return false }
        return delegate.session(session: self, isExistingAccount: account)
    }

    public func parseUserInfo(from response: ZMTransportResponse) {
        guard let info = response.extractUserInfo() else { return log.warn("Failed to parse UserInfo from response: \(response)") }
        log.debug("Parsed UserInfo from response: \(info)")
        let account = Account(userName: "", userIdentifier: info.identifier)
        let cookieStorage = account.cookieStorage()
        cookieStorage.authenticationCookieData = info.cookieData
        self.authenticationStatus.authenticationCookieData = info.cookieData
        self.delegate?.session(session: self, createdAccount: account)
    }

}
