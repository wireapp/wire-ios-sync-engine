//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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
import WireTesting

@testable import WireSyncEngine

class BuildTypeTests: ZMTBaseTest {

    func testThatItParsesKnownBundleIDs() {
        // GIVEN
        let bundleIdsToTypes: [String: WireSyncEngine.BuildType] = ["com.wearezeta.zclient.ios": .production,
                                                                    "com.wearezeta.zclient-alpha": .alpha,
                                                                    "com.wearezeta.zclient.ios-development": .development,
                                                                    "com.wearezeta.zclient.ios-internal": .internal]

        bundleIdsToTypes.forEach { bundleId, expectedType in
            // WHEN
            let type = WireSyncEngine.BuildType(bundleID: bundleId)
            // THEN
            XCTAssertEqual(type, expectedType)
        }
    }

    func testThatItParsesUnknownBundleID() {
        // GIVEN
        let someBundleId = "com.mycompany.myapp"
        // WHEN
        let buildType = WireSyncEngine.BuildType(bundleID: someBundleId)
        // THEN
        XCTAssertEqual(buildType, WireSyncEngine.BuildType.custom(bundleID: someBundleId))
    }

    func testThatItReturnsTheCertName() {
        // GIVEN
        let type = WireSyncEngine.BuildType.alpha
        // WHEN
        let certName = type.certificateName
        // THEN
        XCTAssertEqual(certName, "com.wire.ent")
    }

    func testThatItReturnsBundleIdForCertNameIfCustom() {
        // GIVEN
        let type = WireSyncEngine.BuildType.custom(bundleID: "com.mycompany.myapp")
        // WHEN
        let certName = type.certificateName
        // THEN
        XCTAssertEqual(certName, "com.mycompany.myapp")
    }

}
