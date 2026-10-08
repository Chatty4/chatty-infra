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
- **Decision:** chatty-chat has a read-only MinIO key for the `attachments/` prefix only. `GET /attachments/{file_id}` checks that the user can read the message's channel, then redirects to a presigned GET URL it signs itself (valid 5 minutes). Avatars and team icons are downloaded through chatty-core's `GET /files/{file_id}`.
- **Why:** One request, no extra call to chatty-core per download.
- **Rejected:** chatty-core adds `GET /internal/files/{id}/download-url` (extra call per download, +0.5 day for chatty-core).
- **Plan impact:** none (CHAT-213 "Download attachments through chatty-chat").

## D-03: Attaching and detaching files
- **Status:** accepted
- **Decision:**
  - **Send:** before the message transaction starts, chatty-chat calls `POST /internal/files/{file_id}/attach` `{user_id, channel_id}` for each file. chatty-core checks the file belongs to the user, is a `ready` attachment of the channel's team and isn't attached yet, sets `attached_at`, and returns `object_key`, `filename`, `mime`, `size`. chatty-chat stores these in its `attachments` table.
  - **Saving fails after attach:** chatty-chat calls `POST /internal/files/{file_id}/detach`.
  - **Message deleted:** chatty-chat calls `detach` for its files. chatty-core sets `deleted_at`, and its cleanup job removes the file from MinIO.
- **Why:** chatty-core validates the file and marks it in the same call, so the cleanup job never deletes a file that is in a sent message. If a `detach` call is lost, the file just stays attached but unused, which is harmless.
- **Rejected:** attach after the commit (a failed call could let the cleanup job delete a sent file); chatty-core reads `message.created` from Kafka (+1–1.5 days, Kafka in Django).
- **Plan impact:** none in days. The Jira descriptions of CHAT-173 and CHAT-212 still mention `GET /internal/files/{id}` and need updating to attach/detach.

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
