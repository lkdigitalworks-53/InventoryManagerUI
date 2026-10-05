# PH3b alert runbook (Q-L amended 2026-10-05)

**Status:** NOT created. The sandbox has no GCP access; Taher creates it in the console at the S-C deploy. Facts below checked in Google docs 2026-10-05 unless marked UNVERIFIED.

## What it does
`cleanupPendingMarkers` writes an ERROR log starting `PH3B_ALERT` when a human must act: marker parked, malformed marker, `backlog:true`, env-level failure. Cloud Monitoring sees the log (log-based alert policy: log-match condition, notification rate limit required, auto-close) and sends a notification. Transient failures log WARNING and never alert.

## Will it notify in the Karobar app? No.
Cloud Monitoring channels: email, SMS, Slack, PagerDuty, webhook, Pub/Sub, and the **Google Cloud console mobile app** (push to your phone). Docs: mobile app, Slack, PagerDuty and webhooks share one internal service (one point of failure), so keep **email** as the backup channel.
In-Karobar notification = new code (FCM token registration, a send from the function, a role-scoped screen, tests). Declined for now: more code than the problem. Reopen if you want owners (not only you) alerted.

## Console steps (Taher, once, project `inventorymanager-48392`)
1. Install the Google Cloud console app on your phone, open the project once.
2. Monitoring > Alerting > Edit notification channels: add Email (your address); add Google Cloud console (mobile) for your device.
3. Alerting > Create policy > **Log-based alert** (or Logs Explorer > Create alert). Filter: `severity>=ERROR AND (textPayload:"PH3B_ALERT" OR jsonPayload.message:"PH3B_ALERT")`. Preview the matches in Logs Explorer first. UNVERIFIED: exact `resource.type`/service name of the v2 function; no need to add them, the marker string is enough.
4. Notification rate limit: 1 hour. Auto-close: 1 day. Channels: email + mobile. Documentation text: "Cleanup marker parked or sweeper failing. Runbook: AGENTS.md PH3b / un-park steps."
5. Run test DV-9 (planted malformed marker). The blocker is lifted only when DV-9 passes.

## Optional: same policy as JSON (NOT validated against the API, field names from the v3 REST reference)
```json
{"displayName":"PH3b pending_cleanup needs a human","combiner":"OR",
 "conditions":[{"displayName":"PH3B_ALERT log","conditionMatchedLog":{"filter":"severity>=ERROR AND (textPayload:\"PH3B_ALERT\" OR jsonPayload.message:\"PH3B_ALERT\")"}}],
 "alertStrategy":{"notificationRateLimit":{"period":"3600s"},"autoClose":"86400s"},
 "notificationChannels":["projects/inventorymanager-48392/notificationChannels/<ID>"]}
```
Apply: `gcloud alpha monitoring policies create --policy-from-file=policy.json` (flag UNVERIFIED).

## When it fires
Console > Firestore > `pending_cleanup` > filter `parked == true` (collection group) > read `lastError`. Fix cause, then set `parked` false and `attempts` 0 (swept next run), or delete the marker only if its product and batches are confirmed gone.
