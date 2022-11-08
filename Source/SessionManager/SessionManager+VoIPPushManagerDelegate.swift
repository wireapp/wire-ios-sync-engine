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
import PushKit
import OSLog

extension SessionManager: VoIPPushManagerDelegate, WireLoggable {

    // MARK: - Token management

    public func storeVoIPToken(_ data: Data) {
        Logging.push.info("storing voIP token on all sessions...")
        let pushToken = PushToken.createVOIPToken(from: data)
        backgroundUserSessions.values.forEach {
            $0.setPushToken(pushToken)
        }
    }

    public func deleteExistingVoIPToken() {
        Logging.push.info("deleting existing token from all sessions...")
        backgroundUserSessions.values.forEach {
            $0.deletePushToken()
        }
    }

    // MARK: - VoIP push from NSE

    public func processIncomingFakeVoIPPush(
        payload: VoIPPushPayload,
        completion: @escaping () -> Void
    ) {
        guard let account = accountManager.account(with: payload.accountID) else {
            completion()
            logger.warning("account not found")
            return
        }

        withSession(for: account) { [weak self] _ in
            do {
                self?.logger.info("will processCallMessage")
                try self?.processCallMessage(
                    from: payload,
                    completion: completion
                )
            } catch let error as VOIPPushError {
                // TODO: report call failure?
                self?.logger.warning("Failed to handle voip push payload: \(error)")
                Logging.push.safePublic("Failed to handle voip push payload: \(error)")
                completion()
            } catch {
                // TODO: report call failure?
                self?.logger.warning("Failed to handle voip push payload for unknown reason")
                Logging.push.safePublic("Failed to handle voip push payload for unknown reason")
                completion()
            }
        }
    }

    private func processCallMessage(
        from payload: VoIPPushPayload,
        completion: @escaping () -> Void
    ) throws {
        defer { completion() }

        logger.trace("processCallMessage")
        guard let account = accountManager.account(with: payload.accountID) else {
            logger.warning("account not found")
            throw VOIPPushError.accountNotFound
        }

        // TODO: shouldn't we call 'withSession', then pass the event to the calling request strategy?

        guard let session = backgroundUserSessions[account.userIdentifier] else {
            logger.warning("userSession not found")
            throw VOIPPushError.userSessionNotFound
        }

        // TODO: [John] check if call kit is enabled

        guard payload.caller(in: session.viewContext) != nil else {
            logger.warning("caller not found")
            throw VOIPPushError.callerNotFound
        }

        guard payload.conversation(in: session.viewContext) != nil else {
            logger.warning("conversation not found")
            throw VOIPPushError.conversationNotFound
        }

        guard CallEventContent(from: payload.data) != nil else {
            logger.warning("malformedPayloadData")
            throw VOIPPushError.malformedPayloadData
        }

        guard let processor = session.syncStrategy?.callingRequestStrategy else {
            logger.warning("processor not found")
            throw VOIPPushError.processorNotFound
        }

        Logging.push.safePublic("forwading call event to session with account \(account.userIdentifier)")
        logger.trace("forwading call event to session with account \(account.userIdentifier)")

        processor.processCallEvent(
            conversationUUID: payload.conversationID,
            senderUUID: payload.senderID,
            clientId: payload.senderClientID,
            conversationDomain: payload.conversationDomain,
            senderDomain: payload.senderDomain,
            payload: payload.data,
            currentTimestamp: payload.serverTimeDelta,
            eventTimestamp: payload.timestamp
        )
    }

    private enum VOIPPushError: Error, SafeForLoggingStringConvertible {

        case accountNotFound
        case userSessionNotFound
        case processorNotFound
        case callKitManagerNotFound
        case callerNotFound
        case conversationNotFound
        case malformedPayloadData
        case failedToReportIncomingCall(reason: CallKitManager.ReportIncomingCallError)
        case failedToReportTerminatingCall(reason: CallKitManager.ReportTerminatingCallError)

        var safeForLoggingDescription: String {
            switch self {
            case .accountNotFound:
                return "Account not found"

            case .userSessionNotFound:
                return "User session not found"

            case .processorNotFound:
                return "Call event processor not found"

            case .callKitManagerNotFound:
                return "CallKit manager not found"

            case .callerNotFound:
                return "Caller not found"

            case .conversationNotFound:
                return "Conversation not found"

            case .malformedPayloadData:
                return "Malformed payload data"

            case .failedToReportIncomingCall(let reason):
                return reason.safeForLoggingDescription

            case .failedToReportTerminatingCall(let reason):
                return reason.safeForLoggingDescription
            }
        }

    }

    // MARK: - Legacy voIP push

    public func processIncomingRealVoIPPush(
        payload: [AnyHashable: Any],
        completion: @escaping () -> Void
    ) {
        Logging.push.info("processing incoming (real) voIP push payload: \(payload)")

        // We were given some time to run, resume background task creation.
        BackgroundActivityFactory.shared.resume()
        notificationsTracker?.registerReceivedPush()

        guard
            let accountId = payload.accountId(),
            let account = self.accountManager.account(with: accountId),
            let activity = BackgroundActivityFactory.shared.startBackgroundActivity(
                withName: "\(payload.stringIdentifier)",
                expirationHandler: { [weak self] in
                  Logging.push.warn("Processing push payload expired: \(payload)")
                  self?.notificationsTracker?.registerProcessingExpired()
                }
            )
        else {
            Logging.push.warn("Aborted processing of payload: \(payload)")
            notificationsTracker?.registerProcessingAborted()
            return completion()
        }

        withSession(for: account, perform: { userSession in
            Logging.push.safePublic("Forwarding push payload to user session with account \(account.userIdentifier)")

            userSession.receivedPushNotification(with: payload, completion: { [weak self] in
                Logging.push.info("Processing push payload completed")
                self?.notificationsTracker?.registerNotificationProcessingCompleted()
                BackgroundActivityFactory.shared.endBackgroundActivity(activity)
                completion()
            })
        })
    }

}

private extension VoIPPushPayload {

    func caller(in context: NSManagedObjectContext) -> ZMUser? {
        return ZMUser.fetch(
            with: senderID,
            domain: senderDomain,
            in: context
        )
    }

    func conversation(in context: NSManagedObjectContext) -> ZMConversation? {
        return ZMConversation.fetch(
            with: conversationID,
            domain: conversationDomain,
            in: context
        )
    }

}

private extension Dictionary where Key == AnyHashable, Value == Any {

    var stringIdentifier: String {
        guard
            let data = self["data"] as? [AnyHashable: Any],
            let innerData = data["data"] as? [AnyHashable: Any],
            let id = innerData["id"]
        else {
            return self.description
        }

        return "\(id)"
    }

}

