import CloudKit
import Foundation
import os

/// Owns all CloudKit work for the containing app. One private record with a
/// fixed ID is the authoritative value; the App Group cache is the fast local
/// mirror the app and widget read. Implemented as an actor so fetches, saves,
/// and debounce state stay serialized.
actor CloudTextStore {
    /// Result of a fetch or save. Fetches report whether the local cache
    /// actually changed; saves report whether the cloud write succeeded.
    enum Outcome {
        case updated
        case unchanged
        case failed
    }

    static let shared = CloudTextStore()

    private static let containerIdentifier = "iCloud.com.milestonemade.tinytext"
    private static let recordType = "TinyTextDocument"
    private static let recordName = "primary"
    private static let subscriptionID = "tinytext-document-changes"
    private static let textKey = "text"
    private static let saveDebounce: Duration = .milliseconds(750)

    private let database: CKDatabase
    private let recordID: CKRecord.ID
    private let logger = Logger(subsystem: "com.milestonemade.tinytext", category: "CloudTextStore")

    private var pendingSave: Task<Void, Never>?
    // Serial chain of in-flight cloud writes. Each write awaits the previous one
    // before issuing its own modifyRecords, so writes commit in enqueue order
    // (newest wins) despite actor reentrancy across the network await.
    private var writeChain: Task<Outcome, Never>?
    // Identifies the most recently scheduled debounce so a finished older debounce
    // never clears a newer one's pendingSave.
    private var saveGeneration = 0

    init() {
        let container = CKContainer(identifier: Self.containerIdentifier)
        database = container.privateCloudDatabase
        recordID = CKRecord.ID(recordName: Self.recordName)
    }

    // MARK: - Lifecycle

    /// Ensure the subscription exists, then pull (or seed) the authoritative value.
    func start() async {
        await ensureSubscription()
        _ = await fetchLatestOrSeed()
    }

    /// Fetch the subscription by ID. Create it only when CloudKit reports that
    /// it does not yet exist. An existing subscription counts as success, so no
    /// device-local "created" flag is needed.
    func ensureSubscription() async {
        do {
            _ = try await database.subscription(for: Self.subscriptionID)
        } catch {
            guard isUnknownItem(error) else {
                logger.error("Failed to fetch subscription: \(String(describing: error), privacy: .public)")
                return
            }
            await createSubscription()
        }
    }

    private func createSubscription() async {
        let subscription = CKQuerySubscription(
            recordType: Self.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        // A silent, content-available push. No alert, so it needs no
        // user-facing notification permission.
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await database.save(subscription)
        } catch {
            // Another launch may have created it first. Re-fetch by ID: a
            // now-existing subscription is success. Only log if it is truly absent.
            do {
                _ = try await database.subscription(for: Self.subscriptionID)
            } catch let verifyError {
                logger.error("Failed to create subscription: \(String(describing: verifyError), privacy: .public)")
            }
        }
    }

    // MARK: - Fetching

    /// Fetch `primary`. If it exists, apply its text to the cache; if it is
    /// missing, seed it from the current cache. Network, account, or permission
    /// errors keep the good cache and report failure.
    @discardableResult
    func fetchLatestOrSeed() async -> Outcome {
        do {
            return try await fetchAndApply()
        } catch {
            guard isUnknownItem(error) else {
                logger.error("Initial fetch failed: \(String(describing: error), privacy: .public)")
                return .failed
            }
            return await enqueueSave(SharedStore.loadText())
        }
    }

    /// Fetch `primary` without seeding. Used for silent-notification and
    /// background-refresh handling, where a missing record is simply no data.
    @discardableResult
    func fetchLatest() async -> Outcome {
        do {
            return try await fetchAndApply()
        } catch {
            guard isUnknownItem(error) else {
                logger.error("Fetch failed: \(String(describing: error), privacy: .public)")
                return .failed
            }
            return .unchanged
        }
    }

    private func fetchAndApply() async throws -> Outcome {
        let record = try await database.record(for: recordID)
        guard let text = record[Self.textKey] as? String else {
            // The record exists but has no valid String text field. Preserve the
            // good cache instead of clobbering it with an empty value.
            logger.error("Fetched record has no String \(Self.textKey, privacy: .public) field; keeping cached text")
            return .failed
        }
        let changed = text != SharedStore.loadText()
        SharedStore.applyRemoteText(text)
        return changed ? .updated : .unchanged
    }

    // MARK: - Saving

    /// Cancel any pending debounce and save the latest text after 750 ms.
    func scheduleSave(_ text: String) {
        pendingSave?.cancel()
        saveGeneration &+= 1
        let generation = saveGeneration
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.saveDebounce)
            } catch {
                return // debounce cancelled by a newer edit or flush
            }
            guard !Task.isCancelled, let self else { return }
            await self.runDebouncedSave(text, generation: generation)
        }
    }

    private func runDebouncedSave(_ text: String, generation: Int) async {
        _ = await enqueueSave(text)
        // Clear only if no newer debounce was scheduled while this one committed,
        // so an older task never nils out a newer task's pendingSave.
        if generation == saveGeneration {
            pendingSave = nil
        }
    }

    /// Cancel the debounce and save immediately (e.g. when backgrounding).
    @discardableResult
    func flushSave(_ text: String) async -> Outcome {
        pendingSave?.cancel()
        pendingSave = nil
        return await enqueueSave(text)
    }

    /// Append a write to the serial chain and await its result. Chaining behind
    /// any in-flight write guarantees writes commit in enqueue order (newest
    /// wins), which actor reentrancy across the network await cannot provide.
    @discardableResult
    private func enqueueSave(_ text: String) async -> Outcome {
        let previous = writeChain
        let task = Task { [weak self] in
            _ = await previous?.value // let the prior write commit first
            guard let self else { return Outcome.failed }
            return await self.performWrite(text)
        }
        writeChain = task
        return await task.value
    }

    /// Write `text` to the fixed record. A fresh `CKRecord` plus a `.changedKeys`
    /// policy is a deliberate last-write-wins on the single `text` field: the
    /// policy ignores the server change tag rather than comparing it.
    private func performWrite(_ text: String) async -> Outcome {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Self.textKey] = text

        do {
            let results = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
            if case .failure(let error) = results.saveResults[recordID] {
                logger.error("Save failed: \(String(describing: error), privacy: .public)")
                return .failed
            }
            return .updated
        } catch {
            logger.error("Save failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    // MARK: - Helpers

    private func isUnknownItem(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }
}
