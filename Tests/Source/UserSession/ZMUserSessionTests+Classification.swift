//
//  ZMUserSessionTests+Classification.swift
//  UnitTests
//
//  Created by Sun Bin Kim on 10.02.22.
//  Copyright © 2022 Zeta Project Gmbh. All rights reserved.
//

import XCTest
@testable import WireSyncEngine

final class ZMUserSessionTests_Classification: ZMUserSessionTestsBase {

    func otherUser(moc: NSManagedObjectContext, domain: String?) -> ZMUser {
        let otherUser = ZMUser(context: moc)
        otherUser.remoteIdentifier = UUID()
        otherUser.domain = domain
        otherUser.name = "Other Test User"

        return otherUser
    }

    func storeClassifiedDomains(with status: Feature.Status, domains: [String]) {
        let classifiedDomains = Feature.ClassifiedDomains(
            status: status,
            config: Feature.ClassifiedDomains.Config(domains: domains)
        )
        sut.featureService.storeClassifiedDomains(classifiedDomains)
    }

    func testThatItReturnsNone_WhenFeatureIsEnabled_WhenSelfDomainIsNil() {
        // given
        let otherUser = otherUser(moc: syncMOC, domain: UUID().uuidString)

        storeClassifiedDomains(with: .enabled, domains: [])

        syncMOC.performGroupedBlock {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            selfUser.domain = nil
            self.syncMOC.saveOrRollback()
        }

        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // when
        let classification = sut.classification(with: [otherUser])

        // then
        XCTAssertEqual(classification, .none)
    }

    func testThatItReturnsNone_WhenFeatureIsDisabled_WhenSelfDomainIsNotNil() {
        // given
        let otherUser = otherUser(moc: syncMOC, domain: UUID().uuidString)

        storeClassifiedDomains(with: .disabled, domains: [])

        syncMOC.performGroupedBlock {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            selfUser.domain = UUID().uuidString
            self.syncMOC.saveOrRollback()
        }

        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // when
        let classification = sut.classification(with: [otherUser])

        // then
        XCTAssertEqual(classification, .none)
    }

    func testThatItReturnClassified_WhenFeatureIsEnabled_WhenAllOtherUserDomainIsClassified() {
        // given
        let otherUser1 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUser2 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUser3 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUsers = [otherUser1, otherUser2, otherUser3]
        let classifiedDomains = otherUsers.map { $0.domain! }

        storeClassifiedDomains(with: .enabled, domains: classifiedDomains)

        syncMOC.performGroupedBlock {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            selfUser.domain = UUID().uuidString
            self.syncMOC.saveOrRollback()
        }

        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // when
        let classification = sut.classification(with: otherUsers)

        // then
        XCTAssertEqual(classification, .classified)
    }

    func testThatItReturnsNotClassified_WhenFeatureIsEnabled_WhenAtLeastOneOtherUserDomainIsNotClassified() {
        // given
        let otherUser1 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUser2 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUser3 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUsers = [otherUser1, otherUser2, otherUser3]

        var classifiedDomains = otherUsers.map { $0.domain! }
        classifiedDomains.removeFirst()

        storeClassifiedDomains(with: .enabled, domains: classifiedDomains)

        syncMOC.performGroupedBlock {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            selfUser.domain = UUID().uuidString
            self.syncMOC.saveOrRollback()
        }

        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // when
        let classification = sut.classification(with: otherUsers)

        // then
        XCTAssertEqual(classification, .notClassified)
    }

    func testThatItReturnsNotClassified_WhenFeatureIsEnabled_WhenAtLeastOneOtherUserDomainIsNil() {
        // given
        let otherUser1 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUser2 = otherUser(moc: syncMOC, domain: nil)
        let otherUser3 = otherUser(moc: syncMOC, domain: UUID().uuidString)
        let otherUsers = [otherUser1, otherUser2, otherUser3]

        let classifiedDomains = otherUsers.compactMap { $0.domain }

        storeClassifiedDomains(with: .enabled, domains: classifiedDomains)

        syncMOC.performGroupedBlock {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            selfUser.domain = UUID().uuidString
            self.syncMOC.saveOrRollback()
        }

        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // when
        let classification = sut.classification(with: otherUsers)

        // then
        XCTAssertEqual(classification, .notClassified)
    }

}
