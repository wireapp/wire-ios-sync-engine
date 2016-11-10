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


import zmessaging
import ZMUtilities
import ZMTesting
import Cryptobox
import ZMCMockTransport
import ZMCDataModel

class UserClientRequestFactoryTests: MessagingTest {
    
    var sut: UserClientRequestFactory!
    var authenticationStatus: ZMAuthenticationStatus!
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
        
        authenticationStatus = MockAuthenticationStatus(cookie: nil);
        self.sut = UserClientRequestFactory()
        
        let newKeyStore = FakeKeysStore(in: FakeKeysStore.testDirectory)
        self.syncMOC.userInfo.setObject(newKeyStore, forKey: "ZMUserClientKeysStore" as NSCopying)
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }

    func expectedKeyPayloadForClientPreKeys(_ client : UserClient) -> [[String : Any]] {
        let generatedKeys = (client.keysStore as! FakeKeysStore).lastGeneratedKeys
        let expectedPrekeys : [[String: Any]] = generatedKeys.map { (key: (id: UInt16, prekey: String)) in
            return ["key": key.prekey, "id": NSNumber(value: key.id)]
        }
        return expectedPrekeys
    }
    
    func testThatItCreatesRegistrationRequestWithEmailCorrectly() {
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        let credentials = ZMEmailCredentials(email: "some@example.com", password: "123")
        
        //when
        let request = try! sut.registerClientRequest(client, credentials: credentials, authenticationStatus:authenticationStatus)
        
        //then
        guard let transportRequest = request.transportRequest else { return XCTFail("Should return non nil request") }
        guard let payload = transportRequest.payload?.asDictionary() as? [String: NSObject] else { return XCTFail("Request should contain payload") }
        
        guard let type = payload["type"] as? String, type == ZMUserClientTypePermanent else { return XCTFail("Client type should be 'permanent'") }
        guard let password = payload["password"] as? String, password == credentials.password else { return XCTFail("Payload should contain password") }
        
        let lastPreKey = (client.keysStore as! FakeKeysStore).lastGeneratedLastPrekey!
        
        guard let lastKeyPayload = payload["lastkey"] as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(lastKeyPayload["key"] as? String, lastPreKey)
        XCTAssertEqual(lastKeyPayload["id"] as? NSNumber, NSNumber(value: UserClientKeysStore.MaxPreKeyID + 1))

        guard let preKeysPayloadData = payload["prekeys"] as? [[String: Any]] else  { return XCTFail("Payload should contain prekeys") }
        zip(preKeysPayloadData, expectedKeyPayloadForClientPreKeys(client)).forEach { (lhs, rhs) in
            XCTAssertEqual(lhs["key"] as? String, rhs["key"] as? String)
            XCTAssertEqual(lhs["id"] as? UInt16, rhs["id"] as? UInt16)
        }

        guard let apnsKeysPayload = payload["sigkeys"] as? [String: NSObject] else {return XCTFail("Payload should contain apns keys")}
        XCTAssertNotNil(apnsKeysPayload["enckey"], "Payload should contain apns enc key")
        XCTAssertNotNil(apnsKeysPayload["mackey"], "Payload should contain apns mac key")
    }
    
    func testThatItCreatesRegistrationRequestWithPhoneCredentialsCorrectly() {
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        
        //when
        let upstreamRequest : ZMUpstreamRequest
        do {
            upstreamRequest = try sut.registerClientRequest(client, credentials: nil, authenticationStatus:authenticationStatus)
        } catch {
            return XCTFail("error should be nil \(error)")
            
        }
        
        //then
        guard let request = upstreamRequest.transportRequest else { return XCTFail("Request should not be nil") }
        XCTAssertEqual(request.path, "/clients", "Should create request with correct path")
        XCTAssertEqual(request.method, ZMTransportRequestMethod.methodPOST, "Should create POST request")
        guard let payload = request.payload?.asDictionary() as? [String: NSObject] else { return XCTFail("Request should contain payload") }
        XCTAssertEqual(payload["type"] as? String, ZMUserClientTypePermanent, "Client type should be 'permanent'")
        XCTAssertNil(payload["password"])
        
        let lastPreKey = try! client.keysStore.lastPreKey()
        
        guard let lastKeyPayload = payload["lastkey"] as? [String: Any] else { return XCTFail("Payload should contain last prekey") }
        XCTAssertEqual(lastKeyPayload["key"] as? String, lastPreKey)
        XCTAssertEqual(lastKeyPayload["id"] as? NSNumber, NSNumber(value: UserClientKeysStore.MaxPreKeyID + 1))
        
        guard let preKeysPayloadData = payload["prekeys"] as? [[String: Any]] else { return XCTFail("Payload should contain prekeys") }
        
        zip(preKeysPayloadData, expectedKeyPayloadForClientPreKeys(client)).forEach { (lhs, rhs) in
            XCTAssertEqual(lhs["key"] as? String, rhs["key"] as? String)
            XCTAssertEqual(lhs["id"] as? UInt16, rhs["id"] as? UInt16)
        }

        guard let signalingKeys = payload["sigkeys"] as? [String: NSObject] else { return XCTFail("Payload should contain apns keys") }
        XCTAssertNotNil(signalingKeys["enckey"], "Payload should contain apns enc key")
        XCTAssertNotNil(signalingKeys["mackey"], "Payload should contain apns mac key")
    }
    
    func testThatItReturnsNilForRegisterClientRequestIfCanNotGeneratePreKyes() {
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        (client.keysStore as! FakeKeysStore).failToGeneratePreKeys = true
        
        let credentials = ZMEmailCredentials(email: "some@example.com", password: "123")
        
        //when
        let request = try? sut.registerClientRequest(client, credentials: credentials, authenticationStatus:authenticationStatus)
        
        XCTAssertNil(request, "Should not return request if client fails to generate prekeys")
    }
    
    func testThatItReturnsNilForRegisterClientRequestIfCanNotGenerateLastPreKey() {
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        (client.keysStore as! FakeKeysStore).failToGenerateLastPreKey = true
        
        let credentials = ZMEmailCredentials(email: "some@example.com", password: "123")
        
        //when
        let request = try? sut.registerClientRequest(client, credentials: credentials, authenticationStatus:authenticationStatus)
        
        XCTAssertNil(request, "Should not return request if client fails to generate last prekey")
    }
    
    func testThatItCreatesUpdateClientRequestCorrectlyWhenStartingFromPrekey0() {
        
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        client.remoteIdentifier = UUID.create().transportString()
        
        //when
        let request = try! sut.updateClientPreKeysRequest(client)
        
        AssertOptionalNotNil(request.transportRequest, "Should return non nil request") { request in
            
            XCTAssertEqual(request.path, "/clients/\(client.remoteIdentifier!)", "Should create request with correct path")
            XCTAssertEqual(request.method, ZMTransportRequestMethod.methodPUT, "Should create POST request")
            
            AssertOptionalNotNil(request.payload?.asDictionary() as? [String: NSObject], "Request should contain payload") { payload in
                
                let preKeysPayloadData = payload["prekeys"] as? [[NSString: Any]]
                AssertOptionalNotNil(preKeysPayloadData, "Payload should contain prekeys") { data in
                    zip(data, expectedKeyPayloadForClientPreKeys(client)).forEach { (lhs, rhs) in
                        XCTAssertEqual(lhs["key"] as? String, rhs["key"] as? String)
                        XCTAssertEqual(lhs["id"] as? UInt16, rhs["id"] as? UInt16)
                    }
                }
            }
        }
    }
    
    func testThatItCreatesUpdateClientRequestCorrectlyWhenStartingFromPrekey400() {
        
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        client.remoteIdentifier = UUID.create().transportString()
        client.preKeysRangeMax = 400
        
        //when
        let request = try! sut.updateClientPreKeysRequest(client)
        
        AssertOptionalNotNil(request.transportRequest, "Should return non nil request") { request in
            
            XCTAssertEqual(request.path, "/clients/\(client.remoteIdentifier!)", "Should create request with correct path")
            XCTAssertEqual(request.method, ZMTransportRequestMethod.methodPUT, "Should create POST request")
            
            AssertOptionalNotNil(request.payload?.asDictionary() as? [String: NSObject], "Request should contain payload") { payload in
                
                let preKeysPayloadData = payload["prekeys"] as? [[NSString: Any]]
                AssertOptionalNotNil(preKeysPayloadData, "Payload should contain prekeys") { data in
                    zip(data, expectedKeyPayloadForClientPreKeys(client)).forEach { (lhs, rhs) in
                        XCTAssertEqual(lhs["key"] as? String, rhs["key"] as? String)
                        XCTAssertEqual(lhs["id"] as? UInt16, rhs["id"] as? UInt16)
                    }
                }
            }
        }
    }

    
    func testThatItReturnsNilForUpdateClientRequestIfCanNotGeneratePreKeys() {
        
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        (client.keysStore as! FakeKeysStore).failToGeneratePreKeys = true

        client.remoteIdentifier = UUID.create().transportString()
        
        //when
        let request = try? sut.updateClientPreKeysRequest(client)
        
        XCTAssertNil(request, "Should not return request if client fails to generate prekeys")
    }
    
    func testThatItDoesNotReturnRequestIfClientIsNotSynced() {
        //given
        let client = UserClient.insertNewObject(in: self.syncMOC)
        
        // when
        do {
            _ = try sut.updateClientPreKeysRequest(client)
        }
        catch let error {
            XCTAssertNotNil(error, "Should not return request if client does not have remoteIdentifier")
        }
        
    }
    
    func testThatItCreatesARequestToDeleteAClient() {
        
        // given
        let email = "foo@example.com"
        let password = "gfsgdfgdfgdfgdfg"
        let credentials = ZMEmailCredentials(email: email, password: password)
        let client = UserClient.insertNewObject(in: self.syncMOC)
        client.remoteIdentifier = "\(client.objectID)"
        self.syncMOC.saveOrRollback()
        
        // when
        let nextRequest = sut.deleteClientRequest(client, credentials: credentials)
        
        // then
        AssertOptionalNotNil(nextRequest) {
            XCTAssertEqual($0.transportRequest.path, "/clients/\(client.remoteIdentifier!)")
            XCTAssertEqual($0.transportRequest.payload as! [String:String], [
                "email" : email,
                "password" : password
                ])
            XCTAssertEqual($0.transportRequest.method, ZMTransportRequestMethod.methodDELETE)
        }
    }
    
}

