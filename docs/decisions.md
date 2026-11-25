# Decisions

Agreements between chatty-core and chatty-chat. Each one is **proposed** until both developers approve it in a pull request.

Status values: `proposed`, `accepted`, `rejected`, `replaced by D-xx`.

---

## D-01: IDs are UUIDs everywhere
- **Status:** accepted
- **Decision:** All IDs (user, team, channel, file, message, invite) are `uuid`. chatty-chat stores `team_id`, `channel_id`, `author_id` and `user_id` as `uuid` columns without foreign keys.
- **Why:** chatty-core already uses UUIDs, so IDs can't be guessed by counting. The same type on both sides means no conversion.
- **Rejected:** `bigint` IDs in chatty-chat (two ID types, conversion bugs).
- **Plan impact:** none.

## D-02: Attachment download
- **Status:** accepted
- **Changed (CHAT-213):** one call per message that returns the URLs, instead of a redirect per file.
- **Decision:** chatty-chat has a read-only MinIO key for the `attachments/` prefix only. `GET /messages/{message_id}/attachments` checks that the user can read the message's channel, then returns a presigned GET URL per file that it signs itself (valid 5 minutes, with `expires_at`). The web app uses the URLs directly in `<img src>` and `<a href>`, and asks again when one is about to expire. Avatars and team icons are downloaded through chatty-core's `GET /files/{file_id}`.
- **Why:** no extra call to chatty-core per download, and one call to chatty-chat per message instead of one per file. The web app sends its token in the `Authorization` header, which `<img src>` and `<a href>` can't do, so a link to a chatty-chat endpoint can't be used directly; a presigned URL needs no token. This is the usual pattern for clients that authenticate with a token rather than a cookie.
- **Rejected:**
  - chatty-core adds `GET /internal/files/{id}/download-url` (extra call per download, +0.5 day for chatty-core);
  - `GET /attachments/{file_id}` with a 302 to the signed URL: the web app would have to fetch every file with its token and show it from a blob, and the CSP would need `connect-src` for MinIO and `blob:` images. It only fits cookie-based clients. It can be added later next to this endpoint if a file link has to work outside the web app;
  - URLs inside the message object: `message.created` is stored for 30 days and replayed by `POST /sync`, long after a URL expires.
- **Plan impact:** none in days (CHAT-213 "Download attachments through chatty-chat", CHAT-214 refreshes expired URLs). chatty-web's CSP needs the public MinIO origin in `img-src`.

## D-03: Attaching and detaching files
- **Status:** accepted
- **Changed (CHAT-173):** one call for all the files of a message instead of one call per file.
- **Decision:**
  - **Send:** before the message transaction starts, chatty-chat calls `POST /internal/files/attach` `{user_id, channel_id, file_ids}` once. chatty-core checks every file (it belongs to the user, is a `ready` attachment of the channel's team and isn't attached yet) and sets `attached_at` on all of them in one transaction, or on none if one check fails. It returns `object_key`, `filename`, `mime`, `size` for each file. chatty-chat stores these in its `attachments` table.
  - **A check fails:** nothing was attached, so there is nothing to undo. chatty-chat rejects the message.
  - **Saving fails after attach answered 200:** if no message with this `client_msg_id` was saved, chatty-chat calls `POST /internal/files/detach` `{file_ids}`. The files are deleted; the user uploads them again.
  - **Outcome of attach unknown** (timeout, lost response): chatty-chat undoes nothing. The files may stay attached to no message; a retry gets `file_already_attached` and the user uploads them again.
  - **Message deleted:** chatty-chat calls `detach` once for its files. chatty-core sets `deleted_at`, and its cleanup job removes the files from MinIO.
- **Why:** chatty-core validates the files and marks them in the same call, so the cleanup job never deletes a file that is in a sent message. All or nothing means a message with one bad file doesn't delete the user's other files, and a send is one call instead of up to ten. chatty-chat only undoes an attach it knows succeeded, so a file of a sent message is never detached by mistake. If a `detach` call is lost, the files just stay attached but unused, which is harmless.
- **Rejected:**
  - attach after the commit (a failed call could let the cleanup job delete a sent file);
  - chatty-core reads `message.created` from Kafka (+1–1.5 days, Kafka in Django);
  - one call per file (a failure on the third file meant detaching, and so deleting, the first two; up to 19 calls per send);
  - a `release` call that only clears `attached_at` after a failed save, so the files can be sent again. Nice to have but rare: the web app can upload the files again itself. It can be added later without breaking anything.
- **Plan impact:** none in days. CHAT-173 (chatty-core endpoints) and CHAT-212 (chatty-chat calls) use the bulk calls.

## D-04: A hidden DM gets a new message
- **Status:** accepted
- **Decision:** chatty-chat ignores `hidden`. When a hidden DM has unread messages, the web app shows it again and sends `PUT /channels/{channel_id}/me` with `hidden: false` to chatty-core, so it is visible on the user's other devices too.
- **Why:** No backend work and no internal call on every DM message.
- **Rejected:** chatty-chat calls chatty-core to un-hide (+0.5 day, an internal call per DM message).
- **Plan impact:** none (part of CHAT-194 "Sidebar with channels and DMs").

## D-05: Who can delete other people's messages
- **Status:** accepted
- **Decision:**
  - The **author** can edit and delete their own message.
  - The **channel owner** and **team owner/admin** can delete any message in the channel. Nobody can edit someone else's message.
  - In a DM, only the author can delete.
  - Reactions: anyone who can write. Pins: channel members who can write.
- **Why:** Matches how chatty-core lets channel owners and team admins manage channels.
- **Plan impact:** none (CHAT-178 "Edit and delete a message"). chatty-chat reads the roles from `/internal/users/{id}/memberships` (see D-07).

## D-06: Redis events from chatty-core
- **Status:** accepted
- **Decision:** Every event has the same envelope:
  ```json
  { "type": "membership.changed", "occurred_at": "2026-10-06T12:00:00Z", "data": { } }
  ```
  | Event | `data` |
  |---|---|
  | `membership.changed` | `user_id`, `channel_id`, `team_id`, `action`: `added` / `removed` / `settings` |
  | `team.member.changed` | `user_id`, `team_id`, `action`: `joined` / `left` / `removed` / `role_changed`, `role` |
  | `channel.updated` | `channel_id`, `team_id`, `name`, `topic`, `archived` |
  | `team.deleted` | `team_id` |
  | `user.deactivated` | `user_id` |
- Events are published only after chatty-core's transaction commits (`transaction.on_commit`).
- **Why:** One envelope means one parser in chatty-chat. Full details go in `docs/core-events.md`. What chatty-chat does with each event is on the chatty-chat Confluence page, section 3.
- **Plan impact:** none (CHAT-138 "Write docs/core-events.md", CHAT-172 publish, CHAT-187 consume).

## D-07: Internal memberships response
- **Status:** accepted
- **Decision:** `GET /internal/users/{user_id}/memberships` returns `is_active`, teams with the user's role and the team's public channel IDs, and channels with `team_id`, `kind`, `archived` and the user's channel settings:
  ```json
  {
    "is_active": true,
    "teams": [ { "team_id": "…", "role": "admin", "public_channel_ids": ["…"] } ],
    "channels": [
      { "channel_id": "…", "team_id": "…", "kind": "public", "archived": false,
        "role": "owner", "notify_level": "mentions", "muted": false, "hidden": false }
    ]
  }
  ```
- **Why:** chatty-chat needs `team_id` for per-team presence and unread counts, the roles for D-05, `public_channel_ids` to let team members read public channels they haven't joined, and `is_active` to block deactivated users. One cached call covers everything.
- **Plan impact:** none (CHAT-170 "GET /internal/users/{id}/memberships").

## D-08: How Redis events are sent and recovered
- **Status:** accepted
- **Decision:**
  - chatty-core publishes all 5 events of D-06 on one Redis pub/sub channel, `core.events`.
  - `team.member.changed` always has `role`: the new role, or `null` for `left` and `removed`.
  - `channel.updated` always has `name`, `topic` and `archived`, not only the changed ones.
  - `membership.changed` with `action: settings` carries no values. chatty-chat reloads them from `/internal/users/{id}/memberships`.
  - Every time chatty-chat subscribes to `core.events` (start and reconnect), it deletes all its `members:*` and `channel:*` cache keys. The 5-minute TTL stays as a backstop.
  - If publishing fails, chatty-core logs the error and the request still succeeds.
- **Why:** Pub/sub is the simplest option for 2 services and drops events only while chatty-chat is not subscribed, which the cache reset covers. Fixed shapes mean chatty-chat has no optional keys to check.
- **Rejected:** Redis Streams (acks, consumer groups and trimming, about +1 day across both services).
- **Plan impact:** none (CHAT-138 "Write docs/core-events.md", CHAT-172 publish, CHAT-187 consume).

## D-09: Client IP for rate limits
- **Status:** accepted
- **Decision:** In production, chatty-core and chatty-chat are reachable only through chatty-web's Nginx. Nginx sets `X-Real-IP` to the client's address, overwriting any value the client sent. The services read `X-Real-IP` only when `BEHIND_PROXY=True`; otherwise they use the socket address (`REMOTE_ADDR`). Local development keeps `BEHIND_PROXY=False`.
- **Why:** Behind a proxy every request has the proxy's IP, so all users would share one rate limit (`register:{ip}`, `login_fail:{ip}`). A client can fake any header, so only a value the proxy overwrites is trusted.
- **Rejected:** counting hops in `X-Forwarded-For` (more code, and wrong as soon as a proxy is added or removed, or when a client reaches the backend directly).
- **Plan impact:** none in days (CHAT-240).

## D-10: Access tokens can't be revoked
- **Status:** accepted
- **Decision:** Access tokens stay valid until they expire (15 minutes), even after logout or a password change. Only refresh tokens are revoked. (chatty-core already rejects deactivated users on every request.) Tokens have no `kid` header, so changing the signing key logs everyone out.
- **Why:** Short-lived JWTs are the usual trade-off: no lookup per request in chatty-core or chatty-chat. Key changes are rare, and logging everyone out once is acceptable.
- **Rejected:** a token denylist in Redis (a check on every request in both services); `kid` with several active keys (changes in chatty-core and chatty-chat, only useful once keys are rotated).
- **Plan impact:** none (CHAT-256).

## D-11: Any member can create invites that never expire
- **Status:** accepted
- **Decision:** Keep it as it is. Any team member can create an invite with `max_age: 0` (never expires) and `max_uses: 0` (unlimited).
- **Why:** Owners and admins can see and revoke every invite, and a member's invites are revoked when they leave or are removed. Blocking `max_age: 0` for members would not stop a leaked 7-day link either.
- **Rejected:** only owners and admins can create invites that never expire (a new 403 case and a role check, for little gain).
- **Plan impact:** none (CHAT-256).

## D-12: Sending `unread` to the user's other tabs
- **Status:** accepted
- **Decision:**
  - chatty-chat publishes `unread` on Redis pub/sub `chat.users:{user_id}`, after the commit.
  - Gateways subscribe to that exact channel while they hold a socket of the user.
  - The web app calls `GET /unread` after every reconnect, so a lost `unread` is fixed.
- **Why:** a user's tabs can sit on different gateways, and the existing channels are per channel,
  not per user. Pub/sub with exact channels costs Redis one small delivery per read.
- **Rejected:** `PSUBSCRIBE chat.users:*` (every gateway gets every user's messages);
  publishing on `chat.events:{channel_id}` (other members would see your read position);
  Redis Streams (acks and trimming for a message that the next `GET /unread` replaces anyway).
- **Plan impact:** CHAT-208 (+2–3 h for the gateway changes).

## D-13: Push subscriptions live in chatty-chat
- **Status:** accepted
- **Decision:**
  - chatty-chat stores the Web Push subscriptions (table `push_subscriptions`) and has both endpoints:
    [POST /push/subscriptions](api-chat.md#post-push-subscriptions) and
    [DELETE /push/subscriptions](api-chat.md#delete-push-subscriptions).
  - chatty-core has no push endpoints, public or internal.
  - The VAPID public key is in chatty-web's `.env`; it isn't secret, so there is no endpoint for it.
    The private key is only in chatty-chat.
- **Why:** the push worker runs in chatty-chat, so it reads and deletes subscriptions in its own
  database: no HTTP call to chatty-core per message, and pushes keep working while chatty-core is down.
  A subscription is a delivery address for one browser, not profile data; like read state, it lives
  with the service that uses it.
- **Cost:** chatty-chat has to delete a deactivated user's subscriptions itself, on
  [user.deactivated](core-events.md#event-user-deactivated). The push worker also skips users whose
  memberships say `is_active: false`, in case that event was missed.
- **Rejected:** subscriptions in chatty-core with two internal endpoints for the push worker (two more
  endpoints and an HTTP call per message, for no gain); an endpoint for the VAPID public key.
- **Plan impact:** replaces the push sections of `api-core.md` and `api-internal.md`.

## D-14: One MinIO bucket, separated by prefix
- **Status:** accepted
- **Decision:**
  - One private bucket, `chatty`. Files are separated by key prefix: `uploads/`, `avatars/`,
    `team-icons/`, `attachments/`. These are prefixes, not buckets.
  - Two service accounts: chatty-core reads and writes `chatty/*`; chatty-chat can only
    `s3:GetObject` on `chatty/attachments/*` (D-02).
  - `setup.bat` creates the bucket, the accounts, CORS (browser `PUT` from the web app's origin) and a
    lifecycle rule that deletes `uploads/*` after 1 day. The services never create buckets.
- **Why:** who can see a file is checked by the service before it signs a URL, not by the bucket.
  Prefixes still give per-prefix policies and lifecycle rules.
- **Rejected:** a bucket per team, channel or user (bucket counts are limited, names are global on
  AWS, and creating buckets at runtime needs admin rights).
- **Plan impact:** CHAT-120 (setup.bat, +2–3 h). The `upload_url` example in `api-core.md` changes
  with D-15.

## D-15: Upload to a temporary key, copy to the final key on confirm
- **Status:** accepted
- **Decision:**
  - `POST /files` returns a presigned PUT for `uploads/{file_id}`, with `Content-Type` and
    `Content-Length` in the signature (and in `upload_headers`), so MinIO rejects a different type or
    size.
  - `confirm` first copies the object to its final key (`avatars/…`, `team-icons/…`,
    `attachments/…`), then checks the copy (size, type, first bytes), then deletes the temporary
    one. If the check fails, it deletes both. Checking the copy, not the temporary object, matters:
    the upload URL still works during `confirm`, so a file checked in `uploads/` could be replaced
    before it is copied. No URL can write to the final key.
  - The type check reads the first bytes of the file. Avatars and team icons must really be one of
    the four image types, or the request fails with `upload_mismatch`. For attachments, which can be
    any type, `upload_mismatch` compares only the `Content-Type` header: real files often don't match
    what the browser says (`.docx` → `application/zip`). Executables are the exception: D-18.
- **Why:** a presigned URL can't be revoked. If it pointed at the final key, the owner could replace
  a checked file with any other file until the URL expires. A late `PUT` now only reaches
  `uploads/`, which nothing reads.
- **Rejected:** a shorter expiry only (smaller window, still open); storing the ETag at confirm and
  checking it on download.
- **Plan impact:** CHAT-120, no change in days. `api-core.md`: the `upload_url` example and the
  `upload_mismatch` row. `object_key` returned by `attach` is always the final key, so chatty-chat
  is not affected.

## D-16: Presigned URLs are signed for the public MinIO address
- **Status:** accepted
- **Decision:**
  - Both services sign URLs with an S3 client configured with `MINIO_PUBLIC_URL` (the address the
    browser uses: `http://127.0.0.1:9000` locally). chatty-core makes its other MinIO calls with a
    second client on `MINIO_INTERNAL_URL` (`http://minio:9000` in Docker).
  - Both use boto3 (`signature_version="s3v4"`, path-style addressing, region `us-east-1`).
  - chatty-chat signs attachment downloads with
    `Content-Disposition: attachment; filename*=UTF-8''…`, so an uploaded HTML or SVG file is
    downloaded, never opened as a page. Avatars and team icons, which passed the image check, are
    signed `inline`.
  - Presigned URLs are never logged.
- **Why:** the host is part of the signature, so a URL signed for `minio:9000` fails in the browser.
  Attachments can be any type, and opening one inline would let it run scripts.
- **Plan impact:** none in days (CHAT-120, CHAT-213). New setting `MINIO_PUBLIC_URL` in both services'
  `.env.example` and in `docker-compose.yml`.

## D-17: Cleaning up files that are never used
- **Status:** accepted
- **Decision:** chatty-core's cleanup job (every hour, as in the File upload diagram on the
  chatty-core Confluence page) also deletes:
  - attachments that are `ready` but still not attached to a message 24 hours after upload;
  - avatars and team icons that were replaced and are no longer used;
  - files of a deleted team, attached or not: the team answers 404 everywhere and can't be restored.

  An unattached attachment is marked deleted under the same row lock that `attach` takes, so a
  message sent at that moment either attaches it first (the job skips it) or gets `file_not_found`.
- **Why:** without this, a confirmed attachment that never goes into a message stays in MinIO
  forever: it isn't `pending` and has no `deleted_at`. The web app must not keep a file ID longer
  than 24 hours before sending.
- **Plan impact:** CHAT-120 (+1–2 h in the cleanup job). `api-core.md` (upload flow) and the
  chatty-core Confluence page (section 2, cleanup job) say so.

## D-18: No executables as attachments
- **Status:** accepted
- **Decision:**
  - Attachments can still be any type, except programs and installers. They are refused twice:
    - **`POST /files`, by name and declared type:** a `filename` ending in `.exe`, `.dll`, `.com`,
      `.scr`, `.cpl`, `.msi`, `.msp`, `.msix`, `.appx`, `.bat`, `.cmd`, `.ps1`, `.vbs`, `.vbe`,
      `.wsf`, `.hta`, `.lnk`, `.jar`, `.apk`, `.dmg` or `.pkg` (any case), or a `mime` of one of
      those types, gets `type_not_allowed`.
    - **`confirm`, by content:** the first bytes of the copy must not be a Windows program (`MZ`),
      a Linux program (ELF) or a macOS program (Mach-O), whatever the file is called. Otherwise
      both objects are deleted and the request fails with `upload_mismatch`.
  - Avatars and team icons: the format read from the bytes must be the declared `mime`, not just
    any of the four image types, because MinIO later serves the file with that `Content-Type`.
    The whole image is decoded (Pillow's `load()`, not `verify()`, which misses a JPEG or GIF that
    was cut short), and an image over 25 megapixels (5000 × 5000) is refused before decoding, so
    a small file that claims to be huge can't use up memory.
  - chatty-core detects formats with Pillow (images) and `filetype` (attachments): pure Python
    packages, so no system library in the Docker image, in CI or on Windows.
- **Why:** a chat is an easy way to spread malware: a program renamed to `report.pdf` looks like
  any other file. The name check tells the user before the upload; the content check catches
  renamed files. Scripts that are shared as code (`.js`, `.py`, `.sh`) stay allowed: developers
  send them in chat, and downloads are never opened in the browser (D-16).
- **Not covered:** a program inside an archive (`.zip`). That needs a virus scanner at confirm
  (e.g. ClamAV), which is not planned for the MVP.
- **Rejected:** an allowlist of safe types (every new file type a team uses would need a change);
  python-magic (needs the libmagic system library in Docker, in CI and on Windows, for formats a
  blocklist doesn't need).
- **Plan impact:** CHAT-166 (+0.5 day). `api-core.md`: `POST /files` and `confirm`.

## D-19: Read receipts in private channels and DMs
- **Status:** proposed
- **Decision:**
  - Read receipts exist only in private channels and DMs. They are always on: there is no setting,
    per channel or per user. Public channels have none.
  - They are computed from what chatty-chat already stores: a member has seen a message when their
    `read_state.last_read_seq` is at least the message's `seq`. A member without a read position
    has seen nothing. The author is never counted.
  - "Everyone" means the channel's current members, from chatty-core's
    [GET /internal/channels/{channel_id}](api-internal.md). People who left drop out; people who
    joined later count as not having seen older messages until they read them.
  - The web app shows the ticks only on the user's own messages, with a list of who has seen the
    message and who hasn't.
  - Live updates: when a member's read position moves forward in a private channel or DM
    ([POST /channels/{channel_id}/read](api-chat.md#post-channels-channel_id-read), or sending a
    message, which moves the sender's position), chatty-chat publishes a
    [read](events.md#ws-read) message on the Redis pub/sub channel `chat.reads:{channel_id}`, after
    the commit. Gateways subscribe to it together with `chat.events:{channel_id}` and
    `chat.typing:{channel_id}`. Nothing is published when the position didn't move.
  - `read` is a live message, like `typing` and `unread`: no `seq`, never stored, never in Kafka.
    The web app gets the current positions from
    [GET /channels/{channel_id}/reads](api-chat.md#get-channels-channel_id-reads) when it opens the
    channel and after every reconnect, so a lost `read` is fixed.
- **Why:** the read position and the channel's `seq` already say who read up to where, so no new
  table is needed. A position only moves forward, so the newest value always wins and nothing has
  to be replayed. In private channels and DMs everyone who can read is a member with a read
  position, so "seen by everyone" is true. In a public channel any team member can read without
  joining and has no read position, so the counts would be wrong, and the audience can be the
  whole team.
- **Rejected:**
  - `read` as a channel event with a `seq` (every read would take the channel's counter lock,
    go to Kafka and the push worker, and be replayed by `POST /sync`);
  - a setting per channel for owners and admins (DMs have no owner, and it would need a new field
    in chatty-core, its events and its internal API);
  - a table with one row per member and message (rows grow with members × messages, and the read
    position already holds the same information);
  - sending `read` on `chat.typing:{channel_id}` (one subscription fewer, but one handler for two
    kinds of message).
- **Not covered:** a "delivered" tick (needs an acknowledgement from each device); a per-user
  setting to hide one's own read receipts. Either can be added later without changing this one.
- **Plan impact:** chatty-chat (`read` publish, gateway subscription,
  `GET /channels/{channel_id}/reads`) and chatty-web (ticks, seen-by list). No change in
  chatty-core. `api-chat.md` and `events.md` change.
