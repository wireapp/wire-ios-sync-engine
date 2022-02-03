//
//  ZMUserSession+SecurityClassification.swift
//  WireSyncEngine-ios
//
//  Created by Sun Bin Kim on 02.02.22.
//  Copyright © 2022 Zeta Project Gmbh. All rights reserved.
//

import Foundation

public enum SecurityClassification {
    case none
    case classified
    case notClassified
}

extension ZMUserSession {

    public func classification(with users: [UserType]) -> SecurityClassification {
        guard isSelfClassified else { return .none }

        var isClassified = true
        for user in users {
            let classification = classification(with: user)

            if classification != .classified {
                isClassified = false
                break
            }
        }

        return isClassified ? .classified : .notClassified
    }

    private func classification(with user: UserType) -> SecurityClassification {
        guard isSelfClassified else { return .none }

        guard let otherDomain = user.domain else { return .notClassified }

        return classifiedDomainsFeature.config.domains.contains(otherDomain) ? .classified : .notClassified
    }

    private var isSelfClassified: Bool {
        classifiedDomainsFeature.status == .enabled && selfUser.domain != nil
    }
}
