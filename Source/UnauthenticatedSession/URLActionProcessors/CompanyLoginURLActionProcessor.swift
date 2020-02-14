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

import Foundation

protocol CompanyLoginURLActionProcessorDelegate: class {
    
    var isAllowedToCreateNewAccount: Bool { get }
    
}

class CompanyLoginURLActionProcessor: URLActionProcessor {
    
    private weak var delegate: CompanyLoginURLActionProcessorDelegate?
    private var authenticationStatus: ZMAuthenticationStatus
    
    init(delegate: CompanyLoginURLActionProcessorDelegate, authenticationStatus: ZMAuthenticationStatus) {
        self.delegate = delegate
        self.authenticationStatus = authenticationStatus
    }
    
    func process(urlAction: URLAction, delegate urlActionDelegate: URLActionDelegate?) {
        switch urlAction {
        case .companyLoginSuccess(let userInfo):
            authenticationStatus.loginSucceeded(with: userInfo)
        case .startCompanyLogin(let code):
            guard delegate?.isAllowedToCreateNewAccount == true else {
                urlActionDelegate?.failedToPerformAction(urlAction, error: SessionManager.AccountError.accountLimitReached)
                return
            }
            
            authenticationStatus.notifyCompanyLoginCodeDidBecomeAvailable(code)
        default:
            break
        }
        
        // Delete the url scheme verification token
        CompanyLoginVerificationToken.flush()
        
        urlActionDelegate?.completedURLAction(urlAction)
    }
    
}
