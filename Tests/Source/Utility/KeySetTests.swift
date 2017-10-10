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
import XCTest



class KeySetTests: MessagingTest {

    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }

    func testThatItCanIterate() {
        // given
        let sut = KeySet(["foo", "bar"])
        var result: [WireDataModel.KeyPath] = []
        
        // when
        for k in sut {
            result.append(k)
        }

        // then
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(KeyPath.keyPathForString("foo")))
        XCTAssertTrue(result.contains(KeyPath.keyPathForString("bar")))
    }
}
