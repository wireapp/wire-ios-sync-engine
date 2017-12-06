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
@testable import WireSyncEngine

class EmailVerificationStrategyTests : MessagingTest {

    var registrationStatus : TestRegistrationStatus!
    var sut : WireSyncEngine.EmailVerificationStrategy!

    override func setUp() {
        super.setUp()
        registrationStatus = TestRegistrationStatus()
        sut = WireSyncEngine.EmailVerificationStrategy(groupQueue: self.syncMOC, status: registrationStatus)
    }

    override func tearDown() {
        sut = nil
        registrationStatus = nil

        super.tearDown()
    }

    // MARK:- nil request tests

    func testThatItDoesNotReturnRequestIfThePhaseIsNone(){
        let request = sut.nextRequest()
        XCTAssertNil(request);
    }

    // MARK:- Send activation code tests

    func testThatItReturnsARequestWhenStateIsSendActivationCode(){
        //given
        let email = "john@smith.com"
        let path = "/activate/send"
        let payload = ["email": email,
                       "locale": NSLocale.formattedLocaleIdentifier()!]

        let transportRequest = ZMTransportRequest(path: path, method: .methodPOST, payload: payload as ZMTransportData)
        registrationStatus.phase = .sendActivationCode(email: email)

        //when

        let request = sut.nextRequest()

        //then
        XCTAssertNotNil(request);
        XCTAssertEqual(request, transportRequest)
    }

    func testThatItNotifiesStatusAfterSuccessfulResponseToSendingActivationCode() {
        // given
        let email = "john@smith.com"
        registrationStatus.phase = .sendActivationCode(email: email)
        let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil)

        // when
        XCTAssertEqual(registrationStatus.successCalled, 0)
        sut.didReceive(response, forSingleRequest: sut.codeSendingSync)

        // then
        XCTAssertEqual(registrationStatus.successCalled, 1)
    }

    // MARK:- Check activation code tests

    func testThatItReturnsARequestWhenStateIsCheckActivationCode(){
        //given
        let email = "john@smith.com"
        let code = "123456"
        let path = "/activate"
        let payload = ["email": email,
                       "code": code,
                       "dryrun": true] as [String : Any]

        let transportRequest = ZMTransportRequest(path: path, method: .methodPOST, payload: payload as ZMTransportData)
        registrationStatus.phase = .checkActivationCode(email: email, code: code)

        //when

        let request = sut.nextRequest()

        //then
        XCTAssertNotNil(request);
        XCTAssertEqual(request, transportRequest)
    }

    func testThatItNotifiesStatusAfterSuccessfulResponseToCheckActivationCode() {
        // given
        let email = "john@smith.com"
        let code = "123456"
        registrationStatus.phase = .checkActivationCode(email: email, code: code)
        let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil)

        // when
        XCTAssertEqual(registrationStatus.successCalled, 0)
        sut.didReceive(response, forSingleRequest: sut.codeSendingSync)

        // then
        XCTAssertEqual(registrationStatus.successCalled, 1)
    }


}

extension EmailVerificationStrategyTests: RegistrationStatusStrategyTestHelper {

    func handleResponse(response: ZMTransportResponse) {
        sut.didReceive(response, forSingleRequest: sut.codeSendingSync)
    }

    // MARK:- error tests for verification

    func testThatItNotifiesStatusAfterErrorToEmailVerify_BlacklistEmail() {
        checkSendingCodeResponseError(with: .blacklistedEmail, errorLabel: "blacklisted-email", httpStatus: 403)
    }

    func testThatItNotifiesStatusAfterErrorToEmailVerify_EmailExists() {
        checkSendingCodeResponseError(with: .emailIsAlreadyRegistered, errorLabel: "key-exists", httpStatus: 409)
    }

    func testThatItNotifiesStatusAfterErrorToEmailVerify_InvalidEmail() {
        checkSendingCodeResponseError(with: .invalidEmail, errorLabel: "invalid-email", httpStatus: 400)
    }

    func testThatItNotifiesStatusAfterErrorToEmailVerify_OtherError() {
        checkSendingCodeResponseError(with: .unknownError, errorLabel: "not-clear-what-happened", httpStatus: 414)
    }

    // MARK:- error tests for activation

    func testThatItNotifiesStatusAfterErrorToEmailactivate_InvalidCode() {
        checkActivationResponseError(with: .invalidActivationCode, errorLabel: "invalid-code", httpStatus: 404)
    }

    func testThatItNotifiesStatusAfterErrorToEmailActivation_OtherError() {
        checkActivationResponseError(with: .unknownError, errorLabel: "not-clear-what-happened", httpStatus: 414)
    }

    func checkSendingCodeResponseError(with code: ZMUserSessionErrorCode, errorLabel: String, httpStatus: NSInteger, file: StaticString = #file, line: UInt = #line) {
        // given
        let email = "john@smith.com"
        let phase: RegistrationStatus.Phase = .sendActivationCode(email: email)

        // when & then
        checkResponseError(with: phase, code: code, errorLabel: errorLabel, httpStatus: httpStatus)
    }

    func checkActivationResponseError(with code: ZMUserSessionErrorCode, errorLabel: String, httpStatus: NSInteger, file: StaticString = #file, line: UInt = #line) {
        // given
        let email = "john@smith.com"
        let activationCode = "123456"
        let phase: RegistrationStatus.Phase = .checkActivationCode(email: email, code: activationCode)

        // when & then
        checkResponseError(with: phase, code: code, errorLabel: errorLabel, httpStatus: httpStatus)
    }

}
