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


final class EmailVerificationStrategy : NSObject {
    let registrationStatus: RegistrationStatusProtocol
    var codeSendingSync: ZMSingleRequestSync!

    init(groupQueue: ZMSGroupQueue, status : RegistrationStatusProtocol) {
        registrationStatus = status
        super.init()
        codeSendingSync = ZMSingleRequestSync(singleRequestTranscoder: self, groupQueue: groupQueue)
    }
}

extension EmailVerificationStrategy : ZMSingleRequestTranscoder {
    func request(for sync: ZMSingleRequestSync) -> ZMTransportRequest? {
        let currentStatus = registrationStatus
        var payload : [String: Any]
        var path : String

        switch (currentStatus.phase) {
        case let .sendActivationCode(email: email):
            path = "/activate/send"
            payload = ["email": email,
                       "locale": NSLocale.formattedLocaleIdentifier()!]
        case let .checkActivationCode(email: email, code: code):
            path = "/activate"
            payload = ["email": email,
                       "code": code,
                       "dryrun": true]
        default:
            fatal("Generating request for invalid phase: \(currentStatus.phase)")
        }

        return ZMTransportRequest(path: path, method: .methodPOST, payload: payload as ZMTransportData)
    }

    func didReceive(_ response: ZMTransportResponse, forSingleRequest sync: ZMSingleRequestSync) {
        if response.result == .success {
            registrationStatus.success()
        }
        else {
            let error : NSError

            switch (registrationStatus.phase) {
            case .sendActivationCode:
                error = NSError.blacklistedEmail(with: response) ??
                    NSError.emailAddressInUse(with: response) ??
                    NSError.invalidEmail(with: response) ??
                    NSError(code: .unknownError, userInfo: [:])
            case .checkActivationCode:
                error = NSError.invalidActivationCode(with: response) ??
                    NSError(code: .unknownError, userInfo: [:])
            default:
                fatal("Error occurs for invalid phase: \(registrationStatus.phase)")
            }
            registrationStatus.handleError(error)
        }
    }

}

extension EmailVerificationStrategy : RequestStrategy {
    func nextRequest() -> ZMTransportRequest? {
        switch (registrationStatus.phase) {
        case .sendActivationCode, .checkActivationCode:
            codeSendingSync.readyForNextRequestIfNotBusy()
            return codeSendingSync.nextRequest()
        default:
            return nil
        }
    }
}
