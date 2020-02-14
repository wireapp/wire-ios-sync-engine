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

import avs

private let zmLog = ZMSLog(tag: "AVS")

final class AVSLogObserver: NSObject, AVSLogger {
    private var token: Any!
    
    override init() {
        super.init()
        token = SessionManager.addLogger(self)
    }
    
    // MARK: - AVSLoggger
    
    func log(message: String) {
//        zmLog.safePublic(message) ///TODO: public?
                zmLog.safePublic("Invalid participant change data", level: .public)
    }
}
