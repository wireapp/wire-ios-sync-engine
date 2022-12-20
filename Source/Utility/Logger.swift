//
// Wire
// Copyright (C) 2022 Wire Swiss GmbH
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
import OSLog

public struct Logger {

    private typealias LogHandler = (String) -> Void

    private var logger: Any?

    private var onDebug: LogHandler?
    private var onInfo: LogHandler?
    private var onTrace: LogHandler?
    private var onWarning: LogHandler?
    private var onError: LogHandler?
    private var onCritical: LogHandler?

    public init(
        subsystem: String,
        category: String
    ) {
        // Disabled for now, re-enable when you want to debug.
        if false, #available(iOS 14, *) {
            let logger = os.Logger(
                subsystem: subsystem,
                category: category
            )

            self.logger = logger

            onDebug = { message in
                logger.debug("\(message, privacy: .public)")
            }

            onInfo = { message in
                logger.info("\(message, privacy: .public)")
            }

            onTrace = { message in
                logger.trace("\(message, privacy: .public)")
            }

            onWarning = { message in
                logger.warning("\(message, privacy: .public)")
            }

            onError = { message in
                logger.error("\(message, privacy: .public)")
            }

            onCritical = { message in
                logger.critical("\(message, privacy: .public)")
            }
        }
    }

    public func debug(_ message: String) {
        onDebug?(message)
    }

    public func info(_ message: String) {
        onInfo?(message)
    }

    public func trace(_ message: String) {
        onTrace?(message)
    }

    public func warning(_ message: String) {
        onWarning?(message)
    }

    public func error(_ message: String) {
        onError?(message)
    }

    public func critical(_ message: String) {
        onCritical?(message)
    }

}
