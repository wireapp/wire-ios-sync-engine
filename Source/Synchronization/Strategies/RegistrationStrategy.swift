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

final class RegistrationStrategy: NSObject {
    let registrationStatus: RegistrationStatusProtocol
    weak var userInfoParser: UserInfoParser?
    var registrationSync: ZMSingleRequestSync!

    init(groupQueue: ZMSGroupQueue, status: RegistrationStatusProtocol, userInfoParser: UserInfoParser) {
        registrationStatus = status
        self.userInfoParser = userInfoParser
        super.init()
        registrationSync = ZMSingleRequestSync(singleRequestTranscoder: self, groupQueue: groupQueue)
    }
}

extension RegistrationStrategy: ZMSingleRequestTranscoder {
    func request(for sync: ZMSingleRequestSync) -> ZMTransportRequest? {
        switch registrationStatus.phase {
        case let .createUser(user):
            return ZMTransportRequest(path: "/register", method: .methodPOST, payload: user.payload)
        case let .createTeam(team):
            return ZMTransportRequest(path: "/register", method: .methodPOST, payload: team.payload)
        default:
            fatal("Generating request for invalid phase: \(registrationStatus.phase)")
        }
    }

    func didReceive(_ response: ZMTransportResponse, forSingleRequest sync: ZMSingleRequestSync) {
        if response.result == .success {
            response.extractUserInfo().apply {
                userInfoParser?.upgradeToAuthenticatedSession(with: $0)
            }
            registrationStatus.success()
        } else if let error = NSError.blacklistedEmail(with: response) {
            registrationStatus.handleError(error)
        } else if let error = NSError.invalidActivationCode(with: response) {
            registrationStatus.handleError(error)
        } else if let error = NSError.emailAddressInUse(with: response) {
            registrationStatus.handleError(error)
        } else if let error = NSError.phoneNumberIsAlreadyRegisteredError(with: response) {
            registrationStatus.handleError(error)
        } else if let error = NSError.invalidEmail(with: response) {
            registrationStatus.handleError(error)
        } else if let error = NSError.invalidPhoneNumber(withReponse: response) {
            registrationStatus.handleError(error)
        } else if let error = NSError.unauthorizedEmailError(with: response) {
            registrationStatus.handleError(error)
        } else if let error = NSError.domainBlocked(with: response) {
            registrationStatus.handleError(error)
        } else {
            registrationStatus.handleError(NSError(code: .unknownError, userInfo: [:]))
        }
    }
}

extension RegistrationStrategy: RequestStrategy {
    func nextRequest() -> ZMTransportRequest? {
        switch registrationStatus.phase {
        case .createTeam, .createUser:
            registrationSync.readyForNextRequestIfNotBusy()
            return registrationSync.nextRequest()
        default:
            return nil
        }
    }
}
