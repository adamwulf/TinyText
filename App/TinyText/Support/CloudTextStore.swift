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

    /// Sendable result of reading the fixed record, so no `CKRecord` (which is
    /// not Sendable) crosses the fetch's continuation boundary.
    private enum Fetched: Sendable {
        case text(String)
        case missingField
    }

    static let shared = CloudTextStore()

    private static let containerIdentifier = "iCloud.com.milestonemade.tinytext"
    private static let recordType = "TinyTextDocument"
    private static let recordName = "primary"
    /// Shared with `AppDelegate`, which accepts only pushes carrying this ID.
    static let subscriptionID = "tinytext-document-changes"
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
    // Bumped on every local persist request (schedule or flush) and counted while
    // a write is in flight. A fetch inspects these to know whether a newer local
    // edit is pending, so an older server record never overwrites just-typed text.
    private var localSaveGeneration = 0
    private var activeWrites = 0

    init() {
        let container = CKContainer(identifier: Self.containerIdentifier)
        database = container.privateCloudDatabase
        recordID = CKRecord.ID(recordName: Self.recordName)
    }

    // MARK: - Lifecycle

    /// Pull (or seed) the authoritative value first, then ensure the subscription
    /// exists. Seeding first means a pristine development container has the
    /// `TinyTextDocument` record type before the `CKQuerySubscription` that queries
    /// it is saved, so one signed launch can create and verify both the `primary`
    /// record and the subscription without a relaunch. This order intentionally
    /// changes pristine first-launch provisioning and push-arm timing — the record
    /// exists before the subscription arms — while preserving the existing
    /// data-safety guards in `fetchAndApply` and the serial write chain.
    func start() async {
        _ = await fetchLatestOrSeed()
        await ensureSubscription()
    }

    /// Fetch the subscription by ID. Create it only when CloudKit reports that
    /// it does not yet exist. An existing subscription counts as success, so no
    /// device-local "created" flag is needed. The by-ID lookup is a deliberate
    /// network round-trip that keeps the client stateless about creation.
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
            if isUnknownItem(error) {
                return await enqueueSave()
            }
            // Cancellation (e.g. the view's task ending) is expected, not a failure
            // worth logging, but it is still a non-success outcome.
            if !isCancellation(error) {
                logger.error("Initial fetch failed: \(String(describing: error), privacy: .public)")
            }
            return .failed
        }
    }

    /// Fetch `primary` without seeding. Used for silent-notification and
    /// background-refresh handling, where a missing record is simply no data.
    /// Honors task cancellation, so a background expiration stops the network work.
    @discardableResult
    func fetchLatest() async -> Outcome {
        do {
            return try await fetchAndApply()
        } catch {
            if isUnknownItem(error) {
                return .unchanged
            }
            if !isCancellation(error) {
                logger.error("Fetch failed: \(String(describing: error), privacy: .public)")
            }
            return .failed
        }
    }

    private func fetchAndApply() async throws -> Outcome {
        // Snapshot local state so a slow fetch that returns an older server value
        // can never overwrite a newer local edit.
        let startGeneration = localSaveGeneration
        let startCache = SharedStore.loadText()

        let fetched = try await fetchRecord()

        // Discard the fetched value if any local mutation or save raced the
        // network round-trip: a persist was requested (generation moved), one is
        // pending or in flight, or the cache changed under us (covering the window
        // where the editor updated the cache before its save task reached here).
        guard localSaveGeneration == startGeneration,
              pendingSave == nil,
              activeWrites == 0,
              SharedStore.loadText() == startCache
        else {
            return .unchanged
        }

        switch fetched {
        case .missingField:
            // The record exists but has no valid String text field. Preserve the
            // good cache instead of clobbering it with an empty value.
            logger.error("Fetched record has no String \(Self.textKey, privacy: .public) field; keeping cached text")
            return .failed
        case .text(let text):
            // The apply is atomic with local writes under SharedStore's lock and
            // refuses when the cache is dirty, closing the guard/apply TOCTOU.
            switch SharedStore.applyRemoteText(text) {
            case .applied(let changed):
                return changed ? .updated : .unchanged
            case .refusedDirty:
                // An unsynced local edit is present (e.g. a prior upload failed).
                // Re-upload it instead of losing it to the older server value.
                _ = await enqueueSave()
                return .unchanged
            }
        }
    }

    /// Fetch the fixed record with a `CKFetchRecordsOperation` that is cancelled
    /// when the surrounding task is cancelled (e.g. background-refresh expiration).
    /// Throws `CKError.unknownItem` when the record does not exist.
    private func fetchRecord() async throws -> Fetched {
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        let targetID = recordID

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Fetched, Error>) in
                // All callbacks run serially on the operation's private queue, so
                // this shared result needs no extra locking.
                nonisolated(unsafe) var perRecord: Result<CKRecord, Error>?
                operation.perRecordResultBlock = { id, result in
                    if id == targetID { perRecord = result }
                }
                operation.fetchRecordsResultBlock = { result in
                    switch perRecord {
                    case .success(let record):
                        if let text = record[Self.textKey] as? String {
                            continuation.resume(returning: .text(text))
                        } else {
                            continuation.resume(returning: .missingField)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case nil:
                        switch result {
                        case .success:
                            continuation.resume(throwing: CKError(.unknownItem))
                        case .failure(let error):
                            continuation.resume(throwing: Self.recordError(for: targetID, from: error))
                        }
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    // MARK: - Saving

    /// Cancel any pending debounce and save the latest cache after 750 ms.
    func scheduleSave() {
        localSaveGeneration &+= 1
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
            await self.runDebouncedSave(generation: generation)
        }
    }

    private func runDebouncedSave(generation: Int) async {
        _ = await enqueueSave()
        // Clear only if no newer debounce was scheduled while this one committed,
        // so an older task never nils out a newer task's pendingSave.
        if generation == saveGeneration {
            pendingSave = nil
        }
    }

    /// Cancel the debounce and save the latest cache immediately (e.g. when
    /// backgrounding). Skips the write when the cache is already synced.
    @discardableResult
    func flushSave() async -> Outcome {
        pendingSave?.cancel()
        pendingSave = nil
        guard SharedStore.isDirty else { return .unchanged }
        localSaveGeneration &+= 1
        return await enqueueSave()
    }

    /// Append a write to the serial chain and await its result. Chaining behind
    /// any in-flight write guarantees writes commit in enqueue order (newest
    /// wins), which actor reentrancy across the network await cannot provide.
    @discardableResult
    private func enqueueSave() async -> Outcome {
        let previous = writeChain
        let task = Task { [weak self] in
            _ = await previous?.value // let the prior write commit first
            guard let self else { return Outcome.failed }
            return await self.performWrite()
        }
        writeChain = task
        activeWrites += 1
        let outcome = await task.value
        activeWrites -= 1
        return outcome
    }

    /// Write the current cache to the fixed record. Reading the cache here (rather
    /// than trusting a value captured when the save was requested) means the write
    /// always persists the freshest text. A fresh `CKRecord` plus a `.changedKeys`
    /// policy is a deliberate last-write-wins on the single `text` field: the
    /// policy ignores the server change tag rather than comparing it.
    private func performWrite() async -> Outcome {
        let text = SharedStore.loadText()
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Self.textKey] = text

        do {
            let results = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
            // Require an explicit success for our record before trusting the write.
            // A .failure or a missing entry both mean the upload is not confirmed,
            // so leave the cache dirty for a later retry.
            switch results.saveResults[recordID] {
            case .success:
                // Confirmed on the server; clear the dirty marker unless a newer
                // edit changed the cache after this text was read.
                SharedStore.clearDirty(ifTextEquals: text)
                return .updated
            case .failure(let error):
                logger.error("Save failed: \(String(describing: error), privacy: .public)")
                return .failed
            case nil:
                logger.error("Save returned no result for record \(Self.recordName, privacy: .public)")
                return .failed
            }
        } catch {
            logger.error("Save failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    // MARK: - Helpers

    private func isUnknownItem(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }

    /// A cancelled fetch (task cancellation or the CloudKit operation being
    /// cancelled on background-refresh expiration). Expected, so it is not logged.
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? CKError)?.code == .operationCancelled
    }

    /// Unwrap the per-record error from a `CKError.partialFailure`, so a missing
    /// record surfaces as `CKError.unknownItem` for the seed path.
    private static func recordError(for id: CKRecord.ID, from error: Error) -> Error {
        guard let ckError = error as? CKError,
              ckError.code == .partialFailure,
              let itemError = ckError.partialErrorsByItemID?[id]
        else {
            return error
        }
        return itemError
    }
}
