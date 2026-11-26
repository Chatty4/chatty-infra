# chatty-chat API contracts

Base URL: `/api/chat/v1` · Auth: `Authorization: Bearer <JWT>` · IDs: `uuid` · Times: ISO 8601 UTC

Source: the chatty-chat Confluence page (sections 5 and 8) and `docs/decisions.md`. Endpoints of chatty-core are in [api-core.md](api-core.md), the internal ones in [api-internal.md](api-internal.md). If this file and the page disagree, fix one of them in the same pull request.

`PUT` replaces the editable fields of a resource, so the body must contain all of them (same rule as chatty-core).

## Endpoints

**Messages**
- [POST /channels/{channel_id}/messages](#post-channels-channel_id-messages)
- [PUT /messages/{message_id}](#put-messages-message_id)
- [DELETE /messages/{message_id}](#delete-messages-message_id)
- [GET /channels/{channel_id}/messages](#get-channels-channel_id-messages)

**Sync**
- [POST /sync](#post-sync)
- [GET /channels/{channel_id}/events](#get-channels-channel_id-events)

**Reactions and pins**
- [PUT /messages/{message_id}/reactions/{emoji}](#put-messages-message_id-reactions-emoji)
- [DELETE /messages/{message_id}/reactions/{emoji}](#delete-messages-message_id-reactions-emoji)
- [POST /channels/{channel_id}/pins/{message_id}](#post-channels-channel_id-pins-message_id)
- [DELETE /channels/{channel_id}/pins/{message_id}](#delete-channels-channel_id-pins-message_id)
- [GET /channels/{channel_id}/pins](#get-channels-channel_id-pins)

**Attachments**
- [GET /messages/{message_id}/attachments](#get-messages-message_id-attachments)

**Read state and search**
- [POST /channels/{channel_id}/read](#post-channels-channel_id-read)
- [GET /unread](#get-unread)
- [GET /channels/{channel_id}/reads](#get-channels-channel_id-reads)
- [GET /search](#get-search) (post-MVP)
- [GET /search/attachments](#get-search-attachments) (post-MVP)

**Presence**
- [GET /teams/{team_id}/presence](#get-teams-team_id-presence)

**Push**
- [POST /push/subscriptions](#post-push-subscriptions)
- [DELETE /push/subscriptions](#delete-push-subscriptions)
- [Push payload](#push-payload)

**WebSocket**
- [GET /ws](#get-ws)

**Events**
- [Event envelope and client rule](#events)
- [message.created](#event-message-created)
- [message.edited](#event-message-edited)
- [message.deleted](#event-message-deleted)
- [reaction.added](#event-reaction-added)
- [reaction.removed](#event-reaction-removed)
- [pin.added](#event-pin-added)
- [pin.removed](#event-pin-removed)

**Other**
- [Authorization](#authorization)
- [Who can read and write a channel](#access)
- [Errors that every endpoint can return](#common-errors)
- [Rate limits](#rate-limits)
- [Pagination](#pagination)
- [The message object](#message-object)

---

<a id="authorization"></a>
## Authorization

- chatty-chat does not issue tokens. The web app gets them from chatty-core ([POST /auth/login](api-core.md#post-auth-login)) and sends the same access token here.
- Every REST endpoint needs `Authorization: Bearer <access_token>`. chatty-chat checks the RS256 signature with chatty-core's public key and reads the user id from `sub`.
- A token without `exp` or `sub` is rejected with `401 unauthorized`.
- The WebSocket gets the token in the URL ([GET /ws](#get-ws)) and is closed with code `4001` when the token expires.
- No token, a bad signature or an expired token returns `401 unauthorized`. The web app then refreshes the token through chatty-core and repeats the request once.
- The token has no teams or roles. They come from chatty-core's memberships response, cached in Redis for 5 minutes and cleared by chatty-core's events. A deactivated user (`is_active: false`) gets `403 user_inactive`.

---

<a id="access"></a>
## Who can read and write a channel

The **Who** line of each endpoint uses these words:

| Word | Means |
|---|---|
| **can read** | a member of the channel, or a member of the team for a public channel (`public_channel_ids`) |
| **can write** | a member of the channel, and the channel is not archived and its team is not deleted |
| **channel owner** | `role: owner` in the channel (public and private channels only; DMs have no owner) |
| **team owner or admin** | `role: owner` or `admin` in the channel's team |

- Not in the team, or the channel doesn't exist for the user: `403` / `404`, see each endpoint.
- Archived channel or deleted team: reading still works, writing returns `409 channel_archived`.

---

<a id="common-errors"></a>
## Errors that every endpoint can return

Every error has the same body as in chatty-core:
```json
{
  "error": {
    "code": "validation_error",
    "message": "body must be 1-4000 characters",
    "fields": { "body": "too_long" }
  }
}
```
- `fields` is only present for `validation_error`.

| Status | code | When |
|---|---|---|
| 400 | `validation_error` | a field is missing, has the wrong type or breaks a limit |
| 401 | `unauthorized` | no token, a bad signature, or the access token expired |
| 403 | `user_inactive` | the user was deactivated by a platform admin |
| 429 | `rate_limited` | too many requests, see [Rate limits](#rate-limits); the `Retry-After` header says when to try again |
| 500 | `internal_error` | a bug; the response has a `request_id` to find it in the logs |
| 503 | `core_unavailable` | chatty-core could not be reached to check access and nothing was cached; try again |

The errors below each endpoint are only the ones specific to it.

<a id="rate-limits"></a>
## Rate limits

Limits are per user, counted in Redis in fixed windows of one minute (one second for `watch`). Over a limit, a REST request gets `429 rate_limited` with a `Retry-After` header in seconds. If Redis is unavailable, rate limits are skipped and the request proceeds.

| Endpoint | Limit per user |
|---|---|
| [POST /channels/{channel_id}/messages](#post-channels-channel_id-messages) | 60 / min |
| [PUT /messages/{message_id}](#put-messages-message_id) | 30 / min |
| [DELETE /messages/{message_id}](#delete-messages-message_id) | 30 / min |
| [PUT](#put-messages-message_id-reactions-emoji) and [DELETE](#delete-messages-message_id-reactions-emoji) `/messages/{message_id}/reactions/{emoji}` | 60 / min together, and at most 20 different emoji per user on one message (`409 reaction_limit_reached`) |
| [POST](#post-channels-channel_id-pins-message_id) and [DELETE](#delete-channels-channel_id-pins-message_id) `/channels/{channel_id}/pins/{message_id}` | 20 / min together |
| [POST /channels/{channel_id}/read](#post-channels-channel_id-read) | 120 / min |
| [GET /channels/{channel_id}/messages](#get-channels-channel_id-messages) | 120 / min |
| [GET /channels/{channel_id}/events](#get-channels-channel_id-events) | 120 / min |
| [GET /channels/{channel_id}/reads](#get-channels-channel_id-reads) | 120 / min |
| [POST /sync](#post-sync) | 20 / min |
| [GET /search](#get-search) | 30 / min |
| [GET /search/attachments](#get-search-attachments) (post-MVP) | 30 / min |
| [POST](#post-push-subscriptions) and [DELETE](#delete-push-subscriptions) `/push/subscriptions` | 10 / min together |
| WebSocket `watch` | 1 / s per socket; more are ignored without an `error` |
| [GET /messages/{message_id}/attachments](#get-messages-message_id-attachments), [GET /channels/{channel_id}/pins](#get-channels-channel_id-pins), [GET /unread](#get-unread), [GET /teams/{team_id}/presence](#get-teams-team_id-presence), `heartbeat`, `/health` | no limit |

---

<a id="pagination"></a>
## Pagination

Lists that can grow without limit are paginated. Messages and events already have an order number (`seq`) per channel, so they use it as the cursor. Search has no such order, so it uses an opaque cursor like chatty-core.

| Endpoint | How | Page size |
|---|---|---|
| [GET /channels/{channel_id}/messages](#get-channels-channel_id-messages) | `before_seq` → `has_more`; newest first | default 50, max 100 |
| [GET /channels/{channel_id}/events](#get-channels-channel_id-events) | `after_seq` → `has_more`; oldest first | default 500, max 500 |
| [GET /search](#get-search) (post-MVP) | `cursor` → `next_cursor`, as in [api-core.md](api-core.md#pagination) | default 20, max 50 |
| [GET /search/attachments](#get-search-attachments) (post-MVP) | `cursor` → `next_cursor`, as in [api-core.md](api-core.md#pagination) | default 20, max 50 |


- `seq` cursors are stable: new messages or deleted ones never shift a page, because a page is "everything before / after this number".
- The next page always starts from the last `seq` of the current one: the smallest for messages, the biggest for events.

Not paginated, because their size has a limit:
- [POST /sync](#post-sync): max 500 channels per call and max 500 events per channel. More returns `gap_too_large` for that channel, and the web app reloads it with the paginated history.
- [GET /channels/{channel_id}/pins](#get-channels-channel_id-pins): max 100 pins per channel.
- [GET /unread](#get-unread): one row per channel the user is in, in one team; the sidebar needs all of them.
- [GET /channels/{channel_id}/reads](#get-channels-channel_id-reads): one row per member of a private channel or DM; the seen-by list needs all of them.

---

<a id="message-object"></a>
## The message object

Returned by the message endpoints and inside `message.created` events.

```json
{
  "id": "9f3a…",
  "channel_id": "42aa…",
  "seq": 108,
  "author_id": "u7…",
  "client_msg_id": "c1b2e0a4-…",
  "body": "deploy at 5? <@u3…>",
  "file_ids": ["f6…"],
  "attachments": [
    { "file_id": "f6…", "filename": "report.pdf", "mime": "application/pdf", "size": 482133 }
  ],
  "reply_to": {
    "id": "77c1…",
    "seq": 104,
    "author_id": "u3…",
    "body": "is v1.4 ready?",
    "deleted": false
  },
  "mentions": ["u3…"],
  "reactions": [
    { "emoji": "👍", "count": 2, "me": true }
  ],
  "pinned": false,
  "edited_at": null,
  "deleted_at": null,
  "created_at": "2026-10-05T14:02:11Z"
}
```
- `seq`: the message's place in the channel. Edits, reactions and pins also take numbers, so gaps between messages are normal.
- `client_msg_id`: the UUID the author's app sent with [POST /channels/{channel_id}/messages](#post-channels-channel_id-messages). The author's app uses it to replace its pending copy of the message, whether the POST response or the `message.created` event arrives first.
- `body`: a mention is stored as `<@user_id>`. The web app shows the display name from chatty-core's [team members](api-core.md#get-teams-team_id-members).
- `mentions`: the mentioned users who are members of the channel. Mentions of other users stay in the text but are not in this list.
- `attachments`: what chatty-core's `attach` returned (D-03), in the order they were sent. They have no URL: get short-lived download URLs with [GET /messages/{message_id}/attachments](#get-messages-message_id-attachments) when the message is shown.
- `reply_to`: `null`, or the message this one replies to, as it is now (an edit of it shows here too):
  - `body`: its first 200 characters. An empty `body` with `deleted: false` is a message with only files: every message has text or files, and an edit can empty the text only when there are files
  - `deleted`: it was deleted. Then `body` is `""`; `id`, `seq` and `author_id` stay, so the web app can still show who wrote it
- `reactions`: one entry per emoji; `me` is true if the current user reacted with it.
- A deleted message keeps its `id` and `seq` (so the order doesn't change) but has `body: ""`, empty `file_ids`, `attachments`, `mentions` and `reactions`, `reply_to: null`, and `deleted_at` set.

---

# Messages

<a id="post-channels-channel_id-messages"></a>
## POST /channels/{channel_id}/messages
Send a message. A retry with the same `client_msg_id` returns the original message.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can write](#access) in the channel

**Request**
```json
{
  "client_msg_id": "c1b2e0a4-…",
  "body": "deploy at 5? <@u3…>",
  "file_ids": ["f6…"],
  "reply_to_id": "77c1…"
}
```
- `client_msg_id`: a UUID made by the web app for this message. The same value on a retry returns the original, even if the channel was archived or its team deleted since. The same value already used for a message in another channel returns `400 validation_error` with `fields.client_msg_id: "already_used"`
- `body`: 1–4000 chars, required unless `file_ids` is not empty. The body isn't trimmed, so a body of only spaces counts as text
- `file_ids`: max 10, each must be a `ready` attachment uploaded by the sender in the channel's team ([upload in chatty-core](api-core.md#post-files))
- `reply_to_id`: optional. A message of this channel to reply to; it must exist and not be deleted. The reply shows a quote of it (`reply_to` in the [message object](#message-object)). A retry with the same `client_msg_id` returns the original without checking `reply_to_id` again
- Before saving, chatty-chat calls chatty-core's `attach` once for all the files (D-03). If one file fails, none is attached and nothing is saved: the user can remove that file and send again
- If saving fails after the files were attached, they are deleted (D-03). A retry with the same `client_msg_id` then gets `invalid_file`: upload the files again (the web app can do it by itself if it still has them) and send with the new `file_ids`

**Response 201** (200 if it was a retry): a [message object](#message-object)
```json
{
  "id": "9f3a…",
  "channel_id": "42aa…",
  "seq": 108,
  "author_id": "u7…",
  "body": "deploy at 5? <@u3…>",
  "file_ids": ["f6…"],
  "attachments": [
    { "file_id": "f6…", "filename": "report.pdf", "mime": "application/pdf", "size": 482133 }
  ],
  "reply_to": {
    "id": "77c1…",
    "seq": 104,
    "author_id": "u3…",
    "body": "is v1.4 ready?",
    "deleted": false
  },
  "mentions": ["u3…"],
  "reactions": [],
  "pinned": false,
  "edited_at": null,
  "deleted_at": null,
  "created_at": "2026-10-05T14:02:11Z"
}
```
- Also sends a [message.created](#event-message-created) event to everyone who can read the channel, and moves the sender's read position to this `seq`
- In a private channel or DM, the moved read position is also sent as a [read](events.md#ws-read) message on the WebSocket (D-19). A retry sends none

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | body empty without files, body too long, more than 10 files or the same file twice, `client_msg_id` already used in another channel, `reply_to_id` not a message of this channel (`fields.reply_to_id: "invalid"`) |
| 400 | `invalid_file` | a file doesn't exist or was deleted, is not `ready`, not the sender's, of another team or already in a message; `message` names the file. No file of the message is attached |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `channel_not_found` | channel does not exist |
| 409 | `channel_archived` | channel is archived or its team was deleted |
| 409 | `message_deleted` | the message in `reply_to_id` was deleted |
| 429 | `rate_limited` | more than 60 messages per minute; `Retry-After` says when to try again |

---

<a id="put-messages-message_id"></a>
## PUT /messages/{message_id}
Edit the text of my message. `body` is the only editable field, so the request always sends it. Files can't be changed, and neither can the message it replies to.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the author, while they [can write](#access) in the channel

**Request**
```json
{
  "body": "deploy at 6? <@u3…>"
}
```
- `body`: 1–4000 chars. Empty only if the message has files. Not trimmed: a body of only spaces counts as text

**Response 200**: the [message object](#message-object) with the new `body`, `mentions` and `edited_at`
- Also sends a [message.edited](#event-message-edited) event

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | body empty without files, or too long |
| 403 | `not_author` | the message is someone else's |
| 403 | `not_a_member` | I wrote the message but am no longer in the channel (I can still read a public channel) |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `message_deleted` | the message was deleted |
| 409 | `channel_archived` | the channel is archived or its team was deleted |
| 429 | `rate_limited` | more than 30 edits per minute; `Retry-After` says when to try again |

---

<a id="delete-messages-message_id"></a>
## DELETE /messages/{message_id}
Delete a message. It is a soft delete: the message stays in its place as "deleted", its pins are removed, and after the commit chatty-chat calls chatty-core's `detach` once for all its files (D-03). Its text is also cleared from its earlier `message.created` and `message.edited` events, so [GET /channels/{channel_id}/events](#get-channels-channel_id-events) and [POST /sync](#post-sync) don't return it ([events.md, the event envelope](events.md#envelope)). Replies to it stay. Their `reply_to` shows `deleted: true` and loses its text, also in their stored `message.created` events.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the author. In public and private channels also the channel owner and team owner or admin. In DMs only the author (D-05).
- The user must also [be able to read](#access) the channel. A team owner or admin who is not in a private channel can't read it, so they get `404 message_not_found` there (to confirm with the PO: D-05 says they can delete any message in the channel)

**Response 204** (no body). Also 204 if it was already deleted.
- Also sends a [message.deleted](#event-message-deleted) event

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | the user is not the author, the channel owner or a team owner or admin |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `channel_archived` | the channel is archived or its team was deleted |
| 429 | `rate_limited` | more than 30 deletes per minute; `Retry-After` says when to try again |

---

<a id="get-channels-channel_id-messages"></a>
## GET /channels/{channel_id}/messages
Message history, newest first, for scrolling up.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can read](#access) the channel

**Query**
- `before_seq`: optional. Only messages with a smaller `seq`. Leave it out for the newest page
- `around_seq`: optional. Jump to a message, e.g. from search: up to `limit / 2` messages with a smaller `seq`, and the rest with `seq >= around_seq`
- `after_seq`: optional. The next `limit` messages with a bigger `seq` (the closest ones, not the newest), for scrolling down after `around_seq`
- Send only one of `before_seq`, `around_seq`, `after_seq`
- `limit`: default 50, max 100

**Response 200**
```json
{
  "messages": [
    {
      "id": "9f3a…",
      "channel_id": "42aa…",
      "seq": 108,
      "author_id": "u7…",
      "body": "deploy at 5? <@u3…>",
      "file_ids": [],
      "attachments": [],
      "reply_to": null,
      "mentions": ["u3…"],
      "reactions": [{ "emoji": "👍", "count": 2, "me": true }],
      "pinned": false,
      "edited_at": null,
      "deleted_at": null,
      "created_at": "2026-10-05T14:02:11Z"
    }
  ],
  "has_more": true,
  "has_more_after": false,
  "last_seq": 112
}
```
- Sorted by `seq`, highest first. For the next page, send the smallest `seq` of this page as `before_seq`
- `has_more`: older messages exist (scroll up). False on the oldest page
- `has_more_after`: with `around_seq` or `after_seq`. True when newer messages exist; for the next page, send the biggest `seq` of this page as `after_seq`. Always false otherwise
- `around_seq` doesn't need to be a message's `seq`; gaps from edits and reactions are fine
- `last_seq`: the channel's newest event number. The web app keeps it as its cursor for [POST /sync](#post-sync)
- Deleted messages are included as "deleted" so the order is kept

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | more than one of `before_seq`, `around_seq`, `after_seq` |
| 403 | `cannot_read_channel` | private channel or DM the user is not in, or not in the team |
| 404 | `channel_not_found` | channel does not exist |
| 429 | `rate_limited` | more than 120 history requests per minute; `Retry-After` says when to try again |

---

# Sync

<a id="post-sync"></a>
## POST /sync
Get the missed events of many channels in one call. The web app calls it after it reconnects the WebSocket, for example after the token expired (code `4001`) or the network dropped.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** any logged-in user. Each channel is checked on its own: channels the user can't read are answered with an error inside the response, the others still return their events.

**Request**
```json
{
  "cursors": {
    "42aa…": 108,
    "7c01…": 15
  }
}
```
- `cursors`: channel ID → the last `seq` the web app has. Max 500 channels
- Channels not in `cursors` are not returned. A channel the web app has never opened is loaded with [GET /channels/{channel_id}/messages](#get-channels-channel_id-messages)

**Response 200**
```json
{
  "channels": {
    "42aa…": {
      "events": [
        {
          "type": "message.created",
          "channel_id": "42aa…",
          "seq": 109,
          "created_at": "2026-10-05T14:05:40Z",
          "payload": { "message": { "id": "a1…", "seq": 109, "author_id": "u3…", "body": "yes" } }
        }
      ],
      "last_seq": 109,
      "gap_too_large": false
    },
    "7c01…": {
      "events": [],
      "last_seq": 912,
      "gap_too_large": true
    },
    "dd40…": {
      "error": "cannot_read_channel"
    }
  }
}
```
- `events`: in `seq` order, in the same shape as on the WebSocket ([events](#events))
- `gap_too_large: true` when more than 500 events are missing, or the missing events were already cleaned up (older than 30 days). The web app then reloads that channel with [GET /channels/{channel_id}/messages](#get-channels-channel_id-messages)
- `error` per channel: `cannot_read_channel` (the user was removed, or it is private) or `channel_not_found`. The web app drops that channel from its state

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `cursors` missing, more than 500 channels, a negative `seq` |
| 429 | `rate_limited` | more than 20 syncs per minute; `Retry-After` says when to try again |

---

<a id="get-channels-channel_id-events"></a>
## GET /channels/{channel_id}/events
The events of one channel after a `seq`. The web app calls it when it sees a gap (an event with `seq` bigger than last seen + 1) in one channel.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can read](#access) the channel

**Query**
- `after_seq`: required, the last `seq` the web app has
- `limit`: default 500, max 500

**Response 200**
```json
{
  "events": [
    {
      "type": "reaction.added",
      "channel_id": "42aa…",
      "seq": 110,
      "created_at": "2026-10-05T14:06:02Z",
      "payload": { "message_id": "9f3a…", "user_id": "u3…", "emoji": "👍" }
    }
  ],
  "last_seq": 110,
  "has_more": false
}
```
- `has_more`: true if there are more than `limit` events; call again with the last `seq` as `after_seq`

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `cannot_read_channel` | private channel or DM the user is not in, or not in the team |
| 404 | `channel_not_found` | channel does not exist |
| 409 | `gap_too_large` | the events after `after_seq` were already cleaned up (older than 30 days); reload with [GET /channels/{channel_id}/messages](#get-channels-channel_id-messages) |
| 429 | `rate_limited` | more than 120 event requests per minute; `Retry-After` says when to try again |

---

# Reactions and pins

<a id="put-messages-message_id-reactions-emoji"></a>
## PUT /messages/{message_id}/reactions/{emoji}
Add my reaction to a message. Adding the same emoji twice does nothing.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can write](#access) in the message's channel

**Path**
- `emoji`: one Unicode emoji, URL-encoded (`%F0%9F%91%8D` for 👍), max 32 bytes

**Request**: no body

**Response 200**
```json
{
  "message_id": "9f3a…",
  "reactions": [
    { "emoji": "👍", "count": 3, "me": true }
  ]
}
```
- Also sends a [reaction.added](#event-reaction-added) event, only if the reaction is new
- A user can have at most 20 different emoji on one message

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | the emoji is empty, too long or not an emoji |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `message_deleted` | the message was deleted |
| 409 | `channel_archived` | the channel is archived or its team was deleted |
| 409 | `reaction_limit_reached` | I already have 20 different emoji on this message; remove one first. Adding one I already have is still `200` |
| 429 | `rate_limited` | more than 60 reaction changes (adds and removes together) per minute; `Retry-After` says when to try again |

---

<a id="delete-messages-message_id-reactions-emoji"></a>
## DELETE /messages/{message_id}/reactions/{emoji}
Remove my reaction. Removing a reaction I don't have does nothing.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can write](#access) in the message's channel. Only their own reaction.

**Response 200**: the same body as [PUT](#put-messages-message_id-reactions-emoji)
- Also sends a [reaction.removed](#event-reaction-removed) event, only if a reaction was removed

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | the emoji is empty, too long or not an emoji |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `channel_archived` | the channel is archived or its team was deleted |
| 429 | `rate_limited` | more than 60 reaction changes (adds and removes together) per minute; `Retry-After` says when to try again |

---

<a id="post-channels-channel_id-pins-message_id"></a>
## POST /channels/{channel_id}/pins/{message_id}
Pin a message. Max 100 pins per channel.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can write](#access) in the channel

**Request**: no body

**Response 201** (200 if it was already pinned)
```json
{
  "channel_id": "42aa…",
  "message_id": "9f3a…",
  "pinned_by": "u7…",
  "pinned_at": "2026-10-05T14:10:00Z"
}
```
- Also sends a [pin.added](#event-pin-added) event, only if it was not pinned before

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `not_a_member` | user is not in the channel |
| 404 | `message_not_found` | the message doesn't exist or is in another channel |
| 409 | `message_deleted` | the message was deleted |
| 409 | `pin_limit_reached` | the channel already has 100 pins |
| 409 | `channel_archived` | the channel is archived or its team was deleted |
| 429 | `rate_limited` | more than 20 pin changes (pins and unpins together) per minute; `Retry-After` says when to try again |

---

<a id="delete-channels-channel_id-pins-message_id"></a>
## DELETE /channels/{channel_id}/pins/{message_id}
Unpin a message.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can write](#access) in the channel (not only the person who pinned it)

**Response 204** (no body). Also 204 if it was not pinned.
- Also sends a [pin.removed](#event-pin-removed) event, only if it was pinned

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `not_a_member` | user is not in the channel |
| 404 | `message_not_found` | the message doesn't exist or is in another channel |
| 409 | `channel_archived` | the channel is archived or its team was deleted |
| 429 | `rate_limited` | more than 20 pin changes (pins and unpins together) per minute; `Retry-After` says when to try again |

---

<a id="get-channels-channel_id-pins"></a>
## GET /channels/{channel_id}/pins
Pinned messages of a channel, newest pin first. Not paginated: max 100 pins per channel.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can read](#access) the channel

**Response 200**
```json
{
  "pins": [
    {
      "pinned_by": "u7…",
      "pinned_at": "2026-10-05T14:10:00Z",
      "message": {
        "id": "9f3a…",
        "channel_id": "42aa…",
        "seq": 108,
        "author_id": "u7…",
        "body": "deploy at 5? <@u3…>",
        "file_ids": [],
        "attachments": [],
        "reply_to": null,
        "mentions": ["u3…"],
        "reactions": [],
        "pinned": true,
        "edited_at": null,
        "deleted_at": null,
        "created_at": "2026-10-05T14:02:11Z"
      }
    }
  ]
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `cannot_read_channel` | private channel or DM the user is not in, or not in the team |
| 404 | `channel_not_found` | channel does not exist |

---

# Attachments

<a id="get-messages-message_id-attachments"></a>
## GET /messages/{message_id}/attachments
Download URLs for the files of a message. chatty-chat checks that the user can read the message's channel, then signs one MinIO URL per file with its read-only key (D-02). The URLs need no token, so the web app puts them straight into `<img src>` and `<a href>`. Avatars and team icons are downloaded from chatty-core ([GET /files/{file_id}](api-core.md#get-files-file_id)).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can read](#access) the channel of the message

**Response 200**
```json
{
  "attachments": [
    {
      "file_id": "f6…",
      "filename": "report.pdf",
      "mime": "application/pdf",
      "size": 482133,
      "url": "http://127.0.0.1:9000/chatty/attachments/t1…/f6…?X-Amz-Algorithm=…",
      "expires_at": "2026-10-05T14:07:11Z"
    }
  ]
}
```
- One entry per file, in the order they were sent; `[]` for a message without files.
- `url`: a presigned GET URL for the public MinIO address, valid 5 minutes (`expires_at`). Its answer has the file's `Content-Type` and `Content-Disposition: attachment; filename*=UTF-8''…`, so a link downloads the file under its name and an uploaded HTML or SVG file is never opened as a page (D-16). An `<img>` still shows an image.
- The URL can't be revoked: someone removed from the channel can still use one they already have until it expires.
- **Expired URLs:** an image already shown stays on screen. For a new load or a click, the web app first calls this endpoint again if `expires_at` is less than a minute away, or after an image fails to load.
- The message object itself has no URLs: it is stored in `message.created` for 30 days and replayed by [POST /sync](#post-sync), long after a URL would expire.

**Errors**
| Status | code | When |
|---|---|---|
| 404 | `message_not_found` | the message doesn't exist, was deleted, or the user can't read its channel |

---

# Read state and search

<a id="post-channels-channel_id-read"></a>
## POST /channels/{channel_id}/read
Mark the channel as read up to `seq`. The read position only moves forward, so an old tab can't make messages unread again.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the channel. Users who only read a public channel without joining it have no read state.

**Request**
```json
{
  "seq": 112
}
```
- `seq`: a `seq` the web app has seen. A value bigger than the channel's last `seq` is lowered to it

**Response 200**
```json
{
  "channel_id": "42aa…",
  "last_read_seq": 112,
  "unread": 0,
  "mentions": 0
}
```
- The new counts are also sent as an `unread` message on the WebSocket to the user's other tabs and devices. A tab that was disconnected gets the counts from GET /unread after it reconnects.
- In a private channel or DM, when `last_read_seq` moved forward, the new position is also sent as a [read](events.md#ws-read) message to the channel's sockets, for read receipts (D-19). Nothing is sent when it didn't move.

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `seq` missing or negative |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `channel_not_found` | channel does not exist |
| 429 | `rate_limited` | more than 120 read updates per minute; `Retry-After` says when to try again |

---

<a id="get-unread"></a>
## GET /unread
Unread messages and unread mentions of every channel I am in, in one team. Used for the sidebar badges. Called when the app loads,
when the user switches team, and after every WebSocket reconnect.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Query**
- `team_id`: required

**Response 200**
```json
{
  "channels": [
    { "channel_id": "42aa…", "unread": 4, "mentions": 1 },
    { "channel_id": "c5…", "unread": 100, "mentions": 0 }
  ]
}
```
- `unread`: messages after my read position that are not mine and not deleted. Capped at 100; the UI shows 99+
- `mentions`: unread messages that mention me or reply to one of my messages. A message that does both counts once
- Channels with nothing unread are included with `0`, so the web app can clear badges

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `team_id` missing |
| 403 | `not_a_team_member` | the user is not in the team |

---

<a id="get-channels-channel_id-reads"></a>
## GET /channels/{channel_id}/reads
The read position of every member of a private channel or DM, for read receipts (D-19). Called when the web app opens the channel and after every WebSocket reconnect; between those, [read](events.md#ws-read) messages keep it up to date.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the channel. Archived channels and channels of a deleted team still answer.

**Response 200**
```json
{
  "channel_id": "42aa…",
  "last_seq": 120,
  "reads": [
    { "user_id": "u3…", "last_read_seq": 118 },
    { "user_id": "u7…", "last_read_seq": 120 },
    { "user_id": "u9…", "last_read_seq": 0 }
  ]
}
```
- `reads`: one row per current member of the channel (from chatty-core), the caller included, in no fixed order. A member who never read the channel has `last_read_seq: 0`
- `last_seq`: the channel's last `seq` when the positions were read
- A member has seen a message when their `last_read_seq` is at least the message's `seq`. The author of a message is not counted. Which messages show ticks is up to the web app: only the user's own
- Not paginated: one row per member

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `read_receipts_unavailable` | the channel is public; read receipts are only in private channels and DMs |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `channel_not_found` | channel does not exist |
| 429 | `rate_limited` | more than 120 requests per minute; `Retry-After` says when to try again |

---

<a id="get-search"></a>
## GET /search
Full-text search in the messages of one team. *Post-MVP*

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team. Only channels the user [can read](#access) are searched.

**Query**
- `team_id`: required
- `q`: required, 2–200 chars
- `in`: optional, a channel ID
- `from`: optional, an author's user ID
- `before`, `after`: optional, ISO 8601 times
- `limit`: default 20, max 50
- `cursor`: optional, the `next_cursor` of the previous page (opaque, see [api-core.md pagination](api-core.md#pagination))

**Response 200**
```json
{
  "results": [
    {
      "message": {
        "id": "9f3a…",
        "channel_id": "42aa…",
        "seq": 108,
        "author_id": "u7…",
        "body": "deploy at 5? <@u3…>",
        "file_ids": [],
        "attachments": [],
        "reply_to": null,
        "mentions": ["u3…"],
        "reactions": [],
        "pinned": false,
        "edited_at": null,
        "deleted_at": null,
        "created_at": "2026-10-05T14:02:11Z"
      },
      "highlight": "<mark>deploy</mark> at 5?"
    }
  ],
  "next_cursor": null
}
```
- Sorted by relevance, then newest first. Deleted messages are never returned

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `q` too short or too long, `team_id` missing |
| 400 | `invalid_cursor` | the cursor is broken or was made for another query |
| 403 | `not_a_team_member` | the user is not in the team |
| 429 | `rate_limited` | more than 30 searches per minute; `Retry-After` says when to try again |

---

<a id="get-search-attachments"></a>
## GET /search/attachments
Search the attachments of one team by what is in them: file name, colors and objects in images,
text in images, and text in documents. Without `q`, lists the newest files. *Post-MVP*

Files are labeled in the background, so a new attachment can take a few minutes to show up.
Labeled types: images (`image/png`, `image/jpeg`, `image/webp`, `image/gif`), PDF, DOCX, XLSX,
PPTX and `text/*`. Other files match by file name only. 

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team. Only channels the user [can read](#access) are searched.

**Query:** the same as [GET /search](#get-search): `team_id`, `q`, `in`, `from`, `before`, `after`,
`limit`, `cursor`, except that `q` is optional. Without it, every file is returned, labeled or not:
with `in`, this is a conversation's "files" list

**Response 200**
```json
{
  "results": [
    {
      "attachment": {
        "file_id": "f6…",
        "filename": "sunset.jpg",
        "mime": "image/jpeg",
        "size": 482133
      },
      "message": { "id": "9f3a…", "channel_id": "42aa…", "seq": 108, "...": "as in GET /search" },
      "highlight": "<mark>red</mark>, orange, sky, sunset"
    }
  ],
  "next_cursor": null
}
```
- `message` is the message the file was sent with. Open it with `around_seq`
- `highlight` shows the matched words from the file name, labels or text; `""` without `q`
- With `q`: sorted by relevance, then newest first. Without `q`: newest first. Files of deleted
  messages are never returned

**Errors:** the same as [GET /search](#get-search)

---

# Presence

<a id="get-teams-team_id-presence"></a>
## GET /teams/{team_id}/presence
Who is online in a team right now. The web app calls it once per team, after the [WebSocket](#get-ws) is open, and then follows the `presence` messages. In the other order, a change between the two would be lost.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Response 200**
```json
{
  "team_id": "t1…",
  "online": ["u3…", "u7…"]
}
```
- `online`: the IDs of the team members with at least one open WebSocket. Everyone else in the team is offline. Names and avatars come from chatty-core's [team members](api-core.md#get-teams-team_id-members)
- A hidden tab counts as online. `visible` in the heartbeat doesn't change presence
- Not paginated

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `team_id` is not a UUID |
| 403 | `not_a_team_member` | the user is not in the team |

---

# Push

Web Push for browsers where Chatty isn't open. The browser's `pushManager.subscribe()` gives the web app
a subscription: `endpoint` (the URL of the browser's push service), `p256dh` (the browser's public key)
and `auth` (a shared secret). chatty-chat stores it, and its push worker sends to it ([D-13](decisions.md)).

- A subscription belongs to one browser, not to a team: it gets pushes from all of the user's teams.
- Whether a push is sent depends on the channel settings from chatty-core (`notify_level`, `muted`) and on
  the tab being hidden (`visible` in the [heartbeat](#get-ws)).
- `endpoint`, `p256dh` and `auth` are never logged and never returned by any endpoint.

<a id="post-push-subscriptions"></a>
## POST /push/subscriptions
Save this browser's subscription for the current user. The web app calls it after the user allows
notifications, and again on every app start, because browsers sometimes change the subscription.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Request**
```json
{
  "endpoint": "https://fcm.googleapis.com/fcm/send/…",
  "p256dh": "BOr…",
  "auth": "k8J…"
}
```
- `endpoint`: an `https://` URL on a known push service (`fcm.googleapis.com`, `updates.push.services.mozilla.com`, `web.push.apple.com`, `*notify.windows.com` ), at most 2048 characters
- `p256dh`: base64url, 65 bytes once decoded
- `auth`: base64url, 16 bytes once decoded

**Response 204** (no body)
- Saved by `endpoint`: a new endpoint is added; a known one gets the new keys.
- If the endpoint belongs to another user (a shared computer), it moves to the current user, so the
  browser only gets pushes for whoever is logged in.
- A user keeps at most 10 subscriptions. Saving one more deletes the one saved longest ago.

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `endpoint` is not an `https` URL or is not on a known push service or is too long, or a key is missing or not valid base64url |
| 429 | `rate_limited` | more than 10 subscription changes (saves and deletes together) per minute; `Retry-After` says when to try again |

---

<a id="delete-push-subscriptions"></a>
## DELETE /push/subscriptions
Stop push notifications for this browser. The web app calls it when the user turns notifications off,
and on logout **before** chatty-core's [POST /auth/logout](api-core.md#post-auth-logout), while the
access token still works.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Request**
```json
{
  "endpoint": "https://fcm.googleapis.com/fcm/send/…"
}
```
- The endpoint is in the body, not the URL, so it never ends up in access logs. The web app reads it from
  `pushManager.getSubscription()`.

**Response 204** (no body)
- Deletes the subscription only if it belongs to the current user.
- Also 204 if there was nothing to delete, so calling it twice is safe and it doesn't reveal other
  users' subscriptions.

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `endpoint` is missing or not an `https` URL |
| 429 | `rate_limited` | more than 10 subscription changes (saves and deletes together) per minute; `Retry-After` says when to try again |

---

<a id="push-payload"></a>
## Push payload
What the push worker sends to a browser for a new message. The payload is encrypted for that browser
(Web Push, aes128gcm), so the push service can't read it.

```json
{
  "type": "message",
  "team_id": "t1…",
  "channel_id": "42aa…",
  "message_id": "9f3a…",
  "seq": 108,
  "mentioned": true,
  "replied": false,
  "preview": "deploy at 5? <@u3…>"
}
```
- `preview`: the first 100 characters of the body; empty for a message with only attachments.
  Mentions stay as `<@user_id>`; the service worker shows a generic text if it can't resolve them.
- `mentioned`: the user is in the message's `mentions`.
- `replied`: the message replies to one of the user's messages. The service worker shows "New reply to your message"; "You were mentioned" wins when both are true.
- `team_id`: the channel's team, so a click can open `/teams/{team_id}/channels/{channel_id}` in the web
  app, which loads the message with REST as after a reconnect.

**Who gets one**, for each `message.created` event:
- a member of the channel who isn't the author and hasn't muted it, and
- whose `notify_level` is `all`, or `mentions` and they are mentioned or the message replies to one of their messages (DMs default to `all`), and
- who is active (`is_active` in [memberships](api-internal.md#get-internal-users-user_id-memberships)), and
- who has no Chatty tab on screen (`visible` heartbeat in the last 45 s).
- One push per user and message, to every browser they subscribed. Events older than 10 minutes are
  skipped: a late notification is noise.
- A `404` or `410` from the push service deletes that subscription (D-13).

---

# WebSocket

<a id="get-ws"></a>
## GET /ws
The live connection: new events, typing and presence. Writes are never sent over the WebSocket, they go through REST.

**Auth:** `?token=<JWT>` in the URL (browsers can't set headers on a WebSocket)

**Who:** any logged-in user. The gateway subscribes the socket to every channel the user is a member of, in all their teams.

**Connect**
```
GET /api/chat/v1/ws?token=eyJhbGciOiJSUzI1NiIs…
```

**Client → server**
```json
{ "type": "heartbeat", "visible": true }
```
```json
{ "type": "typing", "channel_id": "42aa…" }
```
```json
{ "type": "watch", "channel_id": "c8…" }
```
```json
{ "type": "unwatch", "channel_id": "c8…" }
```
- `heartbeat`: every 20 s, and right away when the tab is shown or hidden. `visible` says if the tab is on screen (used to skip push notifications; the gateway keeps visible sockets in Redis `visible:{user_id}`, see [events.md](events.md#ws-heartbeat)). No heartbeat for 60 s means offline, and the socket is closed with `4002`. Only `heartbeat` resets the 60 s timer
- Invalid JSON, unknown message types and binary frames are ignored without an `error`; the socket stays open
- A message is at most 4 KB. A bigger one closes the socket with `1009`
- `typing`: at most once every 3 s per channel, only in channels the user can write in. Anything else is ignored without an `error`
- `watch`: live updates for one public channel the user has not joined but is looking at. Only for channels in the user's `public_channel_ids`. Max 1 per socket; a new `watch` replaces the old one. No read state or unread counts. At most 1 `watch` per second per socket; more are ignored without an `error`

**Server → client**
```json
{
  "type": "event",
  "event": {
    "type": "message.created",
    "channel_id": "42aa…",
    "seq": 108,
    "created_at": "2026-10-05T14:02:11Z",
    "payload": { "message": { "id": "9f3a…", "seq": 108 } }
  }
}
```
```json
{ "type": "typing", "channel_id": "42aa…", "user_id": "u3…" }
```
```json
{ "type": "presence", "team_id": "t1…", "user_id": "u3…", "status": "online" }
```
```json
{ "type": "unread", "channel_id": "42aa…", "unread": 0, "mentions": 0 }
```
```json
{ "type": "read", "channel_id": "42aa…", "user_id": "u3…", "last_read_seq": 118 }
```
```json
{ "type": "channel.updated", "channel_id": "42aa…", "name": "releases", "topic": "Release notes", "archived": false }
```
```json
{ "type": "error", "code": "cannot_watch", "message": "channel is not public in your teams" }
```
- `event`: one channel event, see [events](#events)
- `typing`: sent to the channel's sockets and the sockets that `watch` it, except the typing user's own. The web app hides it after 5 s
- `presence`: `online` or `offline`, sent to the members of each team the user is in, only when it changes. For who is online now, see [GET /teams/{team_id}/presence](#get-teams-team_id-presence)
- `read`: a member's read position moved forward in a private channel or DM, for read receipts (D-19). Sent to the channel's sockets. For the positions now, see [GET /channels/{channel_id}/reads](#get-channels-channel_id-reads)
- `channel.updated`: forwarded from chatty-core so the sidebar refreshes
- `error`: a client message was rejected; the socket stays open

**Close codes**
| Code | Reason | What the web app does |
|---|---|---|
| `4001` | `token_expired` | refresh the token through chatty-core, reconnect, call [POST /sync](#post-sync) |
| `4002` | `heartbeat_timeout` | reconnect, call [POST /sync](#post-sync) (no token refresh) |
| `4003` | `user_inactive` | log out |
| `4008` | `too_many_messages` (planned, not sent yet) | wait, reconnect, call [POST /sync](#post-sync) |
| `1001` | `gateway_restart`: the gateway lost Redis and reconnected, so it may have missed events | reconnect with backoff, call [POST /sync](#post-sync) |
| `1001` | `too_slow`: the socket didn't take an event within 5 s | reconnect, call [POST /sync](#post-sync) |
| `1009` | a client message over 4 KB (sent by uvicorn) | a bug in the web app; reconnect, call [POST /sync](#post-sync) |
| `1011` | `core_unavailable`: chatty-core could not be reached while connecting | reconnect with backoff, call [POST /sync](#post-sync) |
| `1012` | gateway restart (sent by uvicorn on shutdown) | reconnect with backoff, call [POST /sync](#post-sync) |

- The web app may refresh the token about 1 minute before `exp` and reconnect early, so the socket is not closed with `4001`.
- When the user is removed from a channel (`membership.changed` from chatty-core), the gateway stops sending that channel's events right away. No message is sent; the sidebar updates from chatty-core.
- On `team.deleted` the gateway changes nothing: open sockets stay subscribed to the team's channels. Those channels are read-only (writes return `409 channel_archived`), so no new events arrive.

---

<a id="events"></a>
# Events (WebSocket + Kafka `chat.events`)

Every change in a channel is one event with the next `seq` of that channel. The same JSON is sent on the WebSocket (inside `{"type": "event", "event": …}`), returned by [POST /sync](#post-sync) and [GET /channels/{channel_id}/events](#get-channels-channel_id-events), and written to Kafka.

```json
{
  "type": "message.created",
  "channel_id": "42aa…",
  "seq": 108,
  "created_at": "2026-10-05T14:02:11Z",
  "payload": { }
}
```

**Client rule:** ignore if `seq` <= last seen. If `seq` > last seen + 1, call [GET /channels/{channel_id}/events](#get-channels-channel_id-events) with `after_seq` = last seen. After a reconnect, call [POST /sync](#post-sync) and [GET /unread](#get-unread), and [GET /channels/{channel_id}/reads](#get-channels-channel_id-reads) for an open private channel or DM. The full rules are in [events.md](events.md#client-rules).

<a id="event-message-created"></a>
## message.created
```json
{
  "type": "message.created",
  "channel_id": "42aa…",
  "seq": 108,
  "created_at": "2026-10-05T14:02:11Z",
  "payload": { "message": { "...same as POST response...": "" } }
}
```
- `payload.message` is a full [message object](#message-object). `reactions` is empty and `me` is never set, because the same event goes to everyone

<a id="event-message-edited"></a>
## message.edited
```json
{
  "type": "message.edited",
  "channel_id": "42aa…",
  "seq": 111,
  "created_at": "2026-10-05T14:07:30Z",
  "payload": { "message_id": "9f3a…", "body": "deploy at 6? <@u3…>", "mentions": ["u3…"], "edited_at": "2026-10-05T14:07:30Z" }
}
```

<a id="event-message-deleted"></a>
## message.deleted
```json
{
  "type": "message.deleted",
  "channel_id": "42aa…",
  "seq": 112,
  "created_at": "2026-10-05T14:08:00Z",
  "payload": { "message_id": "9f3a…", "deleted_by": "u7…", "deleted_at": "2026-10-05T14:08:00Z" }
}
```
- The web app shows the message as deleted, removes its files and reactions, and removes it from the pins
- The message's earlier `message.created` and `message.edited` events lose their `body` and `mentions` in the stored history, so a later sync shows no deleted text

<a id="event-reaction-added"></a>
## reaction.added
```json
{
  "type": "reaction.added",
  "channel_id": "42aa…",
  "seq": 110,
  "created_at": "2026-10-05T14:06:02Z",
  "payload": { "message_id": "9f3a…", "user_id": "u3…", "emoji": "👍" }
}
```

<a id="event-reaction-removed"></a>
## reaction.removed
```json
{
  "type": "reaction.removed",
  "channel_id": "42aa…",
  "seq": 113,
  "created_at": "2026-10-05T14:09:00Z",
  "payload": { "message_id": "9f3a…", "user_id": "u3…", "emoji": "👍" }
}
```

<a id="event-pin-added"></a>
## pin.added
```json
{
  "type": "pin.added",
  "channel_id": "42aa…",
  "seq": 114,
  "created_at": "2026-10-05T14:10:00Z",
  "payload": { "message_id": "9f3a…", "pinned_by": "u7…", "pinned_at": "2026-10-05T14:10:00Z" }
}
```

<a id="event-pin-removed"></a>
## pin.removed
```json
{
  "type": "pin.removed",
  "channel_id": "42aa…",
  "seq": 115,
  "created_at": "2026-10-05T14:12:00Z",
  "payload": { "message_id": "9f3a…", "unpinned_by": "u7…" }
}
```
- When a message is deleted, its pin is removed without a separate `pin.removed` event; [message.deleted](#event-message-deleted) covers it
