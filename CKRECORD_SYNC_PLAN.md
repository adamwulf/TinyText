# CKRecord and CKQuerySubscription Implementation Plan

## Outcome

An edit on device A should normally update device B's open editor and widget without opening TinyText on device B. Local edits must continue updating the local widget immediately.[^1]

CloudKit will store one private record and send silent change notifications through a `CKQuerySubscription`.[^2] There is no Netlify service, permanent KVS compatibility layer, or multi-user migration system.

## Decisions

- One private CloudKit record is the authoritative value.
- App Group `UserDefaults` remains the fast local cache read by the app and widget.
- The containing app owns all CloudKit work; the widget only reads the cache.
- Use a fixed record ID, so every fetch is a direct lookup rather than a query.
- Use a five-second debounce for cloud writes so normal typing pauses do not
  generate a burst of CloudKit saves and silent pushes. Backgrounding still
  flushes the latest value immediately.
- Use `.changedKeys` for simple last-write-wins behavior on the single `text` field.[^3]
- Concurrent editing on two devices is out of scope.
- Never delete the record through the app.
- Remove all `NSUbiquitousKeyValueStore` code and its entitlement in the same release.

## CloudKit Model

| Item | Value |
| --- | --- |
| Container | `iCloud.com.milestonemade.tinytext` |
| Database | Private |
| Record type | `TinyTextDocument` |
| Record ID | `primary` |
| Field | `text` (`String`) |
| Subscription ID | `tinytext-document-changes` |
| Subscription events | Creation and update |

## Implementation Phases

### Phase 1 — Configure the app target

1. Add the iCloud capability with CloudKit enabled.
2. Select `iCloud.com.milestonemade.tinytext`.
3. Add the Push Notifications capability.
4. Add `remote-notification` to `UIBackgroundModes` and retain `fetch`.
5. Do not add CloudKit or Push Notifications capabilities to the widget target.

Expected result: the application target can access the private CloudKit database and receive silent subscription notifications.

### Phase 2 — Make `SharedStore` local-only

Update `App/TinyText/Support/SharedStore.swift`:

1. Keep the App Group identifier, text key, and `loadText()`.
2. Replace `saveText(_:)` with a cache write that returns `true` only when the value changed.
3. Continue calling `WidgetCenter.shared.reloadTimelines(ofKind:)` after a real cache change.[^4]
4. Add `applyRemoteText(_:)`. It writes the cache, reloads the widget, and posts an app-local text-change notification.
5. Remove the KVS store, `refreshFromCloud()`, `applyExternalChange(_:)`, and the widget-process check.

Update `App/TinyTextWidget/TinyTextWidget.swift`:

1. Remove both calls to `SharedStore.refreshFromCloud()`.
2. Keep reading `SharedStore.loadText()`.
3. Keep the four-hour timeline policy as a cache-rendering fallback.

Expected result: local app and widget behavior still works with no cloud implementation present.

### Phase 3 — Add `CloudTextStore`

Create `App/TinyText/Support/CloudTextStore.swift` in the app target only. Implement it as one actor so fetches, saves, and debounce state are serialized.

Provide these operations:

1. `start()`
   - Run `fetchLatestOrSeed()`.
   - Ensure the subscription exists.
   - Seeding first means a pristine development container has the `TinyTextDocument` record type before the `CKQuerySubscription` that queries it is saved, so one signed launch creates and verifies both the `primary` record and the subscription without a relaunch. This order intentionally changes pristine first-launch provisioning and push-arm timing — the record exists before the subscription arms — while preserving the existing data-safety guards.
2. `ensureSubscription()`
   - Fetch `tinytext-document-changes` by ID.
   - If CloudKit returns `CKError.unknownItem`, create a `CKQuerySubscription` for `TinyTextDocument` creation and updates.
   - Set `notificationInfo.shouldSendContentAvailable = true`.
   - Treat an existing subscription as success; do not use a device-local “created” flag.
3. `fetchLatestOrSeed()`
   - Fetch record ID `primary`.
   - If found, pass its `text` to `SharedStore.applyRemoteText(_:)`.
   - If the record is missing, create it from the current App Group cache.
   - On network, account, or permission errors, retain the cache and report failure.
4. `scheduleSave(_:)`
   - Cancel the previous pending save.
   - Wait five seconds and then save the latest text.
5. `flushSave(_:)`
   - Cancel the debounce and save immediately.
6. `fetchLatest()`
   - Fetch without seeding; use this for notification and background-refresh handling.

Every save creates a `CKRecord` with the fixed record ID, sets `text`, and calls `modifyRecords` with `savePolicy: .changedKeys`. That policy intentionally does not compare record change tags.[^3]

Return a small outcome enum such as `updated`, `unchanged`, and `failed`. Log failures with `Logger`, but do not clear or overwrite good cached text after an error.

Expected result: foreground launches and local edits synchronize through the fixed CloudKit record.

### Phase 4 — Receive remote changes

Create `App/TinyText/AppDelegate.swift` in the app target only:

1. Register for remote notifications during launch. Silent CloudKit notifications do not require an alert-permission prompt.
2. Implement `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
3. Parse the payload with `CKNotification` and accept only `tinytext-document-changes`.
4. Fetch `primary` through `CloudTextStore.fetchLatest()` rather than trusting payload fields. CloudKit may coalesce subscription notifications, so the notification is a signal to fetch authoritative state.[^2]
5. Map the outcome to `.newData`, `.noData`, or `.failed` and invoke the completion handler exactly once.

Update `App/TinyText/TinyTextApp.swift`:

1. Attach the delegate with `@UIApplicationDelegateAdaptor`.
2. Keep the existing background-task registration and scheduling.

Expected result: when device A saves, CloudKit normally wakes device B, device B fetches the record, updates the App Group cache, and reloads its widget.

### Phase 5 — Connect the editor and fallback refresh

Update `App/TinyText/RootView.swift`:

1. Initialize `text` from the App Group cache as it does today.
2. Start `CloudTextStore.start()` from a SwiftUI task.
3. Replace the KVS publisher with the app-local text-change notification.
4. On a local edit:
   - Write the cache immediately.
   - Only when that cache write reports a real change, call `scheduleSave(_:)`.
5. On backgrounding, call `flushSave(_:)`.
6. Applying a remote value must update the cache before notifying the view, so the resulting UI change does not echo back into another cloud save.

Update `App/TinyText/Support/BackgroundRefresh.swift`:

1. Replace the KVS refresh with an asynchronous `CloudTextStore.fetchLatest()`.
2. Reschedule the next background task.
3. Cancel the fetch from the expiration handler.
4. Complete the `BGAppRefreshTask` exactly once.

Silent notifications are best-effort and may be delayed or dropped.[^5] Fetching at launch, foregrounding, and during the existing background task provides recovery.

Expected result: active UI, background delivery, and missed-notification recovery all update the same cache path.

### Phase 6 — Remove KVS and deploy the schema

1. Confirm no `NSUbiquitousKeyValueStore` references remain.
2. Remove `com.apple.developer.ubiquity-kvstore-identifier` from the app and widget entitlements.
3. Build the app and widget for iOS/iPadOS and Mac Catalyst.
4. Archive each release platform and inspect the signed app entitlements. Confirm the distribution profile resolved the APNs environment to `production`; iOS/iPadOS use `aps-environment`, while Mac Catalyst uses `com.apple.developer.aps-environment`.[^7]
5. Run once against the development CloudKit environment and save text. This first launch creates the `TinyTextDocument` record type and its `text` field in the development schema, seeds the `primary` record, and registers the `tinytext-document-changes` subscription.
6. Verify the `primary` record and the `tinytext-document-changes` subscription in the CloudKit Console's Development environment.
7. Deploy the schema to production before TestFlight or App Store installation. Schema deployment promotes only record types, fields, and indexes; it does not copy the development environment's record data or subscriptions. After the schema is live, the first updated production installation for an iCloud account creates that account's `primary` record and `tinytext-document-changes` subscription at runtime; later devices signed into the same account fetch and use the existing objects.

Expected result: the release has one synchronization system and no dormant KVS compatibility code.

### Phase 7 — Test and cut over the two devices

Remote CloudKit notifications must be tested on physical devices; simulators cannot register for the remote pushes used by CloudKit synchronization.[^6]

1. Copy the current note into another app as a backup.
2. Install the new build on device A and launch it.
3. If `primary` does not exist, device A seeds it from the existing App Group cache.
4. Confirm the text, make a harmless edit, and wait for the save to finish.
5. Install the new build on device B and launch it once.
6. Confirm device B fetches the CloudKit value.
7. Background device B, edit on device A, and confirm device B's widget updates without opening TinyText.
8. Repeat in the other direction.
9. Test an empty note, rapid typing, offline recovery, foreground recovery, and a force-quit followed by relaunch.
10. If the initial seed is wrong, paste the backup into either updated device. That write becomes authoritative.

The old KVS value may remain orphaned in iCloud. No cleanup or migration-version code is required.

## Acceptance Criteria

- Local edits still update the local widget immediately.
- Device A normally updates device B's open editor and widget through the CloudKit subscription.
- Rapid typing results in one debounced cloud write, not one write per character.
- Remote values do not create save loops.
- Missed pushes recover on a later launch, foreground refresh, or background task.
- Both targets build successfully.
- The production CloudKit schema is deployed.
- No active KVS synchronization code or entitlement remains.

## Out of Scope

- Simultaneous multi-device conflict merging.
- Sharing a note between different iCloud accounts.
- A Netlify or custom APNs backend.
- Historical revisions.
- Permanent migration or rollback support.

[^1]: [Current local widget update path](App/TinyText/Support/SharedStore.swift:SharedStore.saveText)
[^2]: [Apple Developer Documentation: CKQuerySubscription](https://developer.apple.com/documentation/cloudkit/ckquerysubscription)
[^3]: [Apple Developer Documentation: CKModifyRecordsOperation.RecordSavePolicy.changedKeys](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/changedkeys)
[^4]: [Apple Developer Documentation: Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
[^5]: [Apple Developer Documentation: Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
[^6]: [Apple sample: CloudKit Samples — CKSyncEngine](https://github.com/apple/sample-cloudkit-sync-engine)
[^7]: [Apple Developer Documentation: Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
