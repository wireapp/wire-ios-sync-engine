//
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
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

import XCTest
@testable import WireSyncEngine

class SignatureRequestStrategyTests: MessagingTest {
     var sut: SignatureRequestStrategy!
     var mockApplicationStatus: MockApplicationStatus!
     var asset: ZMAsset?
    
    override func setUp() {
        super.setUp()
        mockApplicationStatus = MockApplicationStatus()
        asset = randomAsset()
        let signatureStatus = SignatureStatus(asset: asset,
                                              managedObjectContext: syncMOC)
        syncMOC.signatureStatus = signatureStatus
        sut = SignatureRequestStrategy(withManagedObjectContext: syncMOC,
                                       applicationStatus: mockApplicationStatus)
    }
    
    override func tearDown() {
        sut = nil
        mockApplicationStatus = nil
        asset = nil
        super.tearDown()
    }
    
    func testThatItGeneratesCorrectRequestIfStateIsWaitingForConsentURL() {
        //given
        syncMOC.signatureStatus?.state = .waitingForConsentURL

        //when
        let request = sut.nextRequestIfAllowed()
        
        //then
        XCTAssertNotNil(request)
        let payload = request?.payload?.asDictionary()
        XCTAssertEqual(payload?["documentId"] as? String, syncMOC.signatureStatus?.documentID)
        XCTAssertEqual(payload?["name"] as? String, syncMOC.signatureStatus?.fileName)
        XCTAssertEqual(payload?["hash"] as? String, syncMOC.signatureStatus?.encodedHash)
        XCTAssertEqual(request?.path, "/signature/request")
        XCTAssertEqual(request?.method, ZMTransportRequestMethod.methodPOST)
    }
    
    func testThatItGeneratesCorrectRequestIfStateIsWaitingForSignature() {
        //given
        let responseId = "123123"
        let payload: [String : String] = ["consentURL": "http://test.com",
                                          "responseId" : responseId]
        let successResponse = ZMTransportResponse(payload: payload as NSDictionary, httpStatus: 200, transportSessionError: nil)
        
        //when user inserted correct OTP code
        sut.didReceive(successResponse, forSingleRequest: sut.requestSync!)
        syncMOC.signatureStatus?.state = .waitingForSignature
        let request = sut.nextRequestIfAllowed()
        
        //then
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/signature/pending/\(responseId)")
        XCTAssertEqual(request?.method, ZMTransportRequestMethod.methodGET)
    }
    
    func testThatItNotifiesSignatureStatusAfterSuccessfulResponseToReceiveConsentURL() {
        //given
        let responseId = "123123"
        let payload: [String : String] = ["consentURL": "http://test.com",
                                          "responseId" : responseId]
        let successResponse = ZMTransportResponse(payload: payload as NSDictionary, httpStatus: 200, transportSessionError: nil)

        //when
        let _ = sut.nextRequestIfAllowed()
        sut.didReceive(successResponse, forSingleRequest: sut.requestSync!)

        //then
        XCTAssertEqual(syncMOC.signatureStatus?.state, .waitingForCodeVerification)
    }
    
    func testThatItNotifiesSignatureStatusAfterSuccessfulResponseToReceiveSignature() {
        //given
        let documentId = "123123"
        let payload: [String : String] = ["documentId": documentId,
                                          "cms" : "Test"]
        let successResponse = ZMTransportResponse(payload: payload as NSDictionary, httpStatus: 200, transportSessionError: nil)
        
        //when
        let _ = sut.nextRequestIfAllowed()
        sut.didReceive(successResponse, forSingleRequest: sut.retrieveSync!)
        
        //then
        XCTAssertEqual(syncMOC.signatureStatus?.state, .finished)
    }
    
    func testThatItNotifiesSignatureStatusAfterFailedResponseToReceiveConsentURL() {
        //given
        let successResponse = ZMTransportResponse(payload: nil, httpStatus: 400, transportSessionError: nil)
        
        //when
        let _ = sut.nextRequestIfAllowed()
        sut.didReceive(successResponse, forSingleRequest: sut.requestSync!)
        
        //then
        XCTAssertEqual(syncMOC.signatureStatus?.state, .signatureInvalid)
    }

    
    func testThatItNotifiesSignatureStatusAfterFailedResponseToReceiveSignature() {
        //given
        let successResponse = ZMTransportResponse(payload: nil, httpStatus: 400, transportSessionError: nil)
        
        //when
        let _ = sut.nextRequestIfAllowed()
        sut.didReceive(successResponse, forSingleRequest: sut.retrieveSync!)
        
        //then
        XCTAssertEqual(syncMOC.signatureStatus?.state, .signatureInvalid)
    }
    
    private func randomAsset() -> ZMAsset? {
        let imageMetaData = ZMAssetImageMetaData.imageMetaData(withWidth: 30, height: 40)
        let imageMetaDataBuilder = imageMetaData.toBuilder()!
        let original  = ZMAssetOriginal.original(withSize: 200, mimeType: "application/pdf", name: "PDF test", imageMetaData: imageMetaData)
        let remoteData = ZMAssetRemoteData.remoteData(withOTRKey: Data(), sha256: Data(), assetId: "id", assetToken: "token")
        let preview = ZMAssetPreview.preview(withSize: 200, mimeType: "application/pdf", remoteData: remoteData, imageMetadata: imageMetaDataBuilder.build())

        return ZMAsset.asset(withOriginal: original, preview: preview)
    }
}