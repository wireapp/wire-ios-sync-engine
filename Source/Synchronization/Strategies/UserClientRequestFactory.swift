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
import WireCryptobox

enum UserClientRequestError: Error {
    case noPreKeys
    case noLastPreKey
    case clientNotRegistered
}

//TODO: when we should update last pre key or signaling keys?

public final class UserClientRequestFactory {
    
    unowned var keyStore : UserClientKeysStore
    public let keyCount : UInt16
    
    public init(keysCount: UInt16 = 100, keysStore: UserClientKeysStore) {
        self.keyCount = keysCount
        self.keyStore = keysStore
    }
    
    public func registerClientRequest(_ client: UserClient, credentials: ZMEmailCredentials?, authenticationStatus: ZMAuthenticationStatus) throws -> ZMUpstreamRequest {
        
        let (preKeysPayloadData, preKeysRangeMax) = try payloadForPreKeys(client)
        let (signalingKeysPayloadData, signalingKeys) = payloadForSignalingKeys()
        let lastPreKeyPayloadData = try payloadForLastPreKey(client)
        
        var payload: [String: Any] = [
            "type": client.type,
            "label": (client.label ?? ""),
            "model": (client.model ?? ""),
            "class": (client.deviceClass ?? ""),
            "lastkey": lastPreKeyPayloadData,
            "prekeys": preKeysPayloadData,
            "sigkeys": signalingKeysPayloadData,
            "cookie" : ((authenticationStatus.cookieLabel.characters.count != 0) ? authenticationStatus.cookieLabel! : "")
        ]
         
        if let password = credentials?.password {
            payload["password"] = password
        }
        
        let request = ZMTransportRequest(path: "/clients", method: ZMTransportRequestMethod.methodPOST, payload: payload as ZMTransportData)
        request.add(storeMaxRangeID(client, maxRangeID: preKeysRangeMax))
        request.add(storeAPSSignalingKeys(client, signalingKeys: signalingKeys))
        
        let upstreamRequest = ZMUpstreamRequest(transportRequest: request)
        return upstreamRequest!
    }
    
    
    func storeMaxRangeID(_ client: UserClient, maxRangeID: UInt16) -> ZMCompletionHandler {
        let completionHandler = ZMCompletionHandler(on: client.managedObjectContext!, block: { [weak client] response in
            guard let client = client else { return }
            if response.result == .success {
                client.preKeysRangeMax = Int64(maxRangeID)
            }
        })
        return completionHandler
    }
    
    func storeAPSSignalingKeys(_ client: UserClient, signalingKeys: SignalingKeys) -> ZMCompletionHandler {
        let completionHandler = ZMCompletionHandler(on: client.managedObjectContext!, block: { [weak client] response in
            guard let client = client else { return }
            if response.result == .success {
                client.apsDecryptionKey = signalingKeys.decryptionKey
                client.apsVerificationKey = signalingKeys.verificationKey
                client.needsToUploadSignalingKeys = false
            }
        })
        return completionHandler
    }
    
    internal func payloadForPreKeys(_ client: UserClient, startIndex: UInt16 = 0) throws -> (payload: [[String: Any]], maxRange: UInt16) {
        //we don't want to generate new prekeys if we already have them
        do {
            let preKeys = try keyStore.generateMoreKeys(keyCount, start: startIndex)
            guard preKeys.count > 0 else {
                throw UserClientRequestError.noPreKeys
            }
            let preKeysPayloadData : [[String : Any]] = preKeys.map {
                ["key": $0.prekey, "id": NSNumber(value:$0.id)]
            }
            return (preKeysPayloadData, preKeys.last!.id)
        }
        catch {
            throw UserClientRequestError.noPreKeys
        }
    }
    
    internal func payloadForLastPreKey(_ client: UserClient) throws -> [String: Any] {
        do {
            let lastKey = try keyStore.lastPreKey()
            let lastPreKeyString = lastKey
            let lastPreKeyPayloadData : [String: Any] = [
                "key": lastPreKeyString,
                "id": NSNumber(value: CBOX_LAST_PREKEY_ID)
            ]
            return lastPreKeyPayloadData
        } catch  {
            throw UserClientRequestError.noLastPreKey
        }
    }
    
    internal func payloadForSignalingKeys() -> (payload: [String: String], signalingKeys: SignalingKeys) {
        let signalingKeys = APSSignalingKeysStore.createKeys()
        let payload = ["enckey": signalingKeys.decryptionKey.base64String(), "mackey": signalingKeys.verificationKey.base64String()]
        return (payload, signalingKeys)
    }
    
    public func updateClientPreKeysRequest(_ client: UserClient) throws -> ZMUpstreamRequest {
        if let remoteIdentifier = client.remoteIdentifier {
            let startIndex = UInt16(client.preKeysRangeMax)
            let (preKeysPayloadData, preKeysRangeMax) = try payloadForPreKeys(client, startIndex: startIndex)
            let payload: [String: Any] = [
                "prekeys": preKeysPayloadData
            ]
            let request = ZMTransportRequest(path: "/clients/\(remoteIdentifier)", method: ZMTransportRequestMethod.methodPUT, payload: payload as ZMTransportData)
            request.add(storeMaxRangeID(client, maxRangeID: preKeysRangeMax))

            return ZMUpstreamRequest(keys: Set(arrayLiteral: ZMUserClientNumberOfKeysRemainingKey), transportRequest: request, userInfo: nil)
        }
        throw UserClientRequestError.clientNotRegistered
    }
    
    public func updateClientSignalingKeysRequest(_ client: UserClient) throws -> ZMUpstreamRequest {
        if let remoteIdentifier = client.remoteIdentifier {
            let (signalingKeysPayloadData, signalingKeys) = payloadForSignalingKeys()
            let payload: [String: Any] = [
                "sigkeys": signalingKeysPayloadData,
                "prekeys": [] // NOTE backend always expects 'prekeys' to be present atm
            ]
            let request = ZMTransportRequest(path: "/clients/\(remoteIdentifier)", method: ZMTransportRequestMethod.methodPUT, payload: payload as ZMTransportData)
            request.add(storeAPSSignalingKeys(client, signalingKeys: signalingKeys))
            
            return ZMUpstreamRequest(keys: Set(arrayLiteral: ZMUserClientNeedsToUpdateSignalingKeysKey), transportRequest: request, userInfo: nil)
        }
        throw UserClientRequestError.clientNotRegistered
    }
    
    /// Password needs to be set
    public func deleteClientRequest(_ client: UserClient, credentials: ZMEmailCredentials) -> ZMUpstreamRequest {
        let payload = [
            "email" : credentials.email!,
            "password" : credentials.password!
        ]
        let request =  ZMTransportRequest(path: "/clients/\(client.remoteIdentifier!)", method: ZMTransportRequestMethod.methodDELETE, payload: payload as ZMTransportData)
        return ZMUpstreamRequest(keys: Set(arrayLiteral: ZMUserClientMarkedToDeleteKey), transportRequest: request)
    }
    
    public func fetchClientsRequest() -> ZMTransportRequest! {
        return ZMTransportRequest(getFromPath: "/clients")
    }
    
}
