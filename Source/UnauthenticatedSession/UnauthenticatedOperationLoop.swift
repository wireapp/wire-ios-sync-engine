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
import WireTransport

class UnauthenticatedOperationLoop: NSObject {
    
    let transportSession: ZMTransportSession
    let requestStrategies: [RequestStrategy]
    let operationQueue : ZMSGroupQueue
    
    init(transportSession: ZMTransportSession, operationQueue: ZMSGroupQueue, requestStrategies: [RequestStrategy]) {
        self.transportSession = transportSession
        self.requestStrategies = requestStrategies
        self.operationQueue = operationQueue
        super.init()
        RequestAvailableNotification.addObserver(self)
    }
    
    deinit {
        for requestStrategy in requestStrategies {
                        
            if let requestStrategy = requestStrategy as? NSObject {
                let tearDownSelector = Selector("tearDown") // TODO referer to a teardown protocol
                
                if requestStrategy.responds(to: tearDownSelector) {
                    requestStrategy.perform(tearDownSelector)
                }
            }
            
        }
    }
}

extension UnauthenticatedOperationLoop: RequestAvailableObserver {
    func newRequestsAvailable() {
        self.transportSession.attemptToEnqueueSyncRequest { () -> ZMTransportRequest? in
            let request = (self.requestStrategies as NSArray).nextRequest()
            
            request?.add(ZMCompletionHandler(on: self.operationQueue, block: {_ in
                self.operationQueue.performGroupedBlock { [weak self] in
                    self?.newRequestsAvailable()
                }
            }))
            
            return request
        }
    }
}
