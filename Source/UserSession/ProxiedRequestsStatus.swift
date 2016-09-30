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


public typealias ProxyRequestCallback = (Data?, HTTPURLResponse?, NSError?) -> Void

@objc(ZMProxyRequest)
public class ProxyRequest : NSObject {
    public let type: ProxiedRequestType
    public let path: String
    public let method : ZMTransportRequestMethod
    public private(set) var callback : ProxyRequestCallback?
    
    public init(type: ProxiedRequestType, path: String, method: ZMTransportRequestMethod, callback: ProxyRequestCallback?) {
        self.type = type
        self.path = path
        self.method = method
        self.callback = callback
    }
}


/// Keeps track of which requests to send to the backend
public final class ProxiedRequestsStatus: NSObject {
    
    public typealias Request = (type:ProxiedRequestType, path: String, method: ZMTransportRequestMethod, callback: ((Data?, HTTPURLResponse?, NSError?) -> Void)?)
    
    private let requestCancellation : ZMRequestCancellation

    /// List of requests to be sent to backend
    public var pendingRequests : [ProxyRequest] = []
    public var executedRequests : [(ProxyRequest, ZMTaskIdentifier)] = []
    
    public init(requestCancellation: ZMRequestCancellation) {
        self.requestCancellation = requestCancellation
    }
    
    @objc(addRequest:)
    public func add(request: ProxyRequest) {
        pendingRequests.append(request)
    }
    
    @objc(cancelRequest:)
    public func cancel(request: ProxyRequest) {
        if let index = pendingRequests.index(of: request) {
            pendingRequests.remove(at: index)
        }
        
        if let index = executedRequests.index(where: {$0.0 == request }) {
            let (_, taskIdentifier) = executedRequests.remove(at: index)
            requestCancellation.cancelTask(with: taskIdentifier)
        }
    }
}
