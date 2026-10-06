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
- [GET /attachments/{file_id}](#get-attachments-file_id)

**Read state and search**
- [POST /channels/{channel_id}/read](#post-channels-channel_id-read)
- [GET /unread](#get-unread)
- [GET /search](#get-search) (post-MVP)

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
- [Pagination](#pagination)
- [The message object](#message-object)

---

<a id="authorization"></a>
## Authorization

- chatty-chat does not issue tokens. The web app gets them from chatty-core ([POST /auth/login](api-core.md#post-auth-login)) and sends the same access token here.
- Every REST endpoint needs `Authorization: Bearer <access_token>`. chatty-chat checks the RS256 signature with chatty-core's public key and reads the user id from `sub`.
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
| 429 | `rate_limited` | too many requests; the `Retry-After` header says when to try again |
| 500 | `internal_error` | a bug; the response has a `request_id` to find it in the logs |
| 503 | `core_unavailable` | chatty-core could not be reached to check access and nothing was cached; try again |

The errors below each endpoint are only the ones specific to it.

---

<a id="pagination"></a>
## Pagination

Lists that can grow without limit are paginated. Messages and events already have an order number (`seq`) per channel, so they use it as the cursor. Search has no such order, so it uses an opaque cursor like chatty-core.

| Endpoint | How | Page size |
|---|---|---|
| [GET /channels/{channel_id}/messages](#get-channels-channel_id-messages) | `before_seq` → `has_more`; newest first | default 50, max 100 |
| [GET /channels/{channel_id}/events](#get-channels-channel_id-events) | `after_seq` → `has_more`; oldest first | default 500, max 500 |
| [GET /search](#get-search) (post-MVP) | `cursor` → `next_cursor`, as in [api-core.md](api-core.md#pagination) | default 20, max 50 |

- `seq` cursors are stable: new messages or deleted ones never shift a page, because a page is "everything before / after this number".
- The next page always starts from the last `seq` of the current one: the smallest for messages, the biggest for events.

Not paginated, because their size has a limit:
- [POST /sync](#post-sync): max 500 channels per call and max 500 events per channel. More returns `gap_too_large` for that channel, and the web app reloads it with the paginated history.
- [GET /channels/{channel_id}/pins](#get-channels-channel_id-pins): max 100 pins per channel.
- [GET /unread](#get-unread): one row per channel the user is in, in one team; the sidebar needs all of them.

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
  "body": "deploy at 5? <@u3…>",
  "file_ids": ["f6…"],
  "attachments": [
    { "file_id": "f6…", "filename": "report.pdf", "mime": "application/pdf", "size": 482133 }
  ],
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
- `body`: a mention is stored as `<@user_id>`. The web app shows the display name from chatty-core's [team members](api-core.md#get-teams-team_id-members).
- `mentions`: the mentioned users who are members of the channel. Mentions of other users stay in the text but are not in this list.
- `attachments`: what chatty-core's `attach` returned (D-03). Download with [GET /attachments/{file_id}](#get-attachments-file_id).
- `reactions`: one entry per emoji; `me` is true if the current user reacted with it.
- A deleted message keeps its `id` and `seq` (so the order doesn't change) but has `body: ""`, empty `file_ids`, `attachments`, `mentions` and `reactions`, and `deleted_at` set.

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
  "file_ids": ["f6…"]
}
```
- `client_msg_id`: a UUID made by the web app for this message. The same value on a retry returns the original
- `body`: 1–4000 chars, required unless `file_ids` is not empty
- `file_ids`: max 10, each must be a `ready` attachment uploaded by the sender in the channel's team ([upload in chatty-core](api-core.md#post-files))
- Before saving, chatty-chat calls chatty-core's `attach` for each file (D-03). If one fails, the files already attached in this request are detached and nothing is saved

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
  "mentions": ["u3…"],
  "reactions": [],
  "pinned": false,
  "edited_at": null,
  "deleted_at": null,
  "created_at": "2026-10-05T14:02:11Z"
}
```
- Also sends a [message.created](#event-message-created) event to everyone who can read the channel, and moves the sender's read position to this `seq`

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | body empty without files, body too long, more than 10 files |
| 400 | `invalid_file` | a file is not `ready`, not the sender's, of another team or already in a message; `message` names the file |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `channel_not_found` | channel does not exist |
| 409 | `channel_archived` | channel is archived or its team was deleted |

---

<a id="put-messages-message_id"></a>
## PUT /messages/{message_id}
Edit the text of my message. `body` is the only editable field, so the request always sends it. Files can't be changed.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the author, while they [can write](#access) in the channel

**Request**
```json
{
  "body": "deploy at 6? <@u3…>"
}
```
- `body`: 1–4000 chars. Empty only if the message has files

**Response 200**: the [message object](#message-object) with the new `body`, `mentions` and `edited_at`
- Also sends a [message.edited](#event-message-edited) event

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | body empty without files, or too long |
| 403 | `not_author` | the message is someone else's |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `message_deleted` | the message was deleted |
| 409 | `channel_archived` | the channel is archived or its team was deleted |

---

<a id="delete-messages-message_id"></a>
## DELETE /messages/{message_id}
Delete a message. It is a soft delete: the message stays in its place as "deleted", its pins are removed, and chatty-chat calls chatty-core's `detach` for its files (D-03).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the author. In public and private channels also the channel owner and team owner or admin. In DMs only the author (D-05).

**Response 204** (no body). Also 204 if it was already deleted.
- Also sends a [message.deleted](#event-message-deleted) event

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | the user is not the author, the channel owner or a team owner or admin |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `channel_archived` | the channel is archived or its team was deleted |

---

<a id="get-channels-channel_id-messages"></a>
## GET /channels/{channel_id}/messages
Message history, newest first, for scrolling up.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can read](#access) the channel

**Query**
- `before_seq`: optional. Only messages with a smaller `seq`. Leave it out for the newest page
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
      "mentions": ["u3…"],
      "reactions": [{ "emoji": "👍", "count": 2, "me": true }],
      "pinned": false,
      "edited_at": null,
      "deleted_at": null,
      "created_at": "2026-10-05T14:02:11Z"
    }
  ],
  "has_more": true,
  "last_seq": 112
}
```
- Sorted by `seq`, highest first. For the next page, send the smallest `seq` of this page as `before_seq`
- `has_more`: false on the oldest page
- `last_seq`: the channel's newest event number. The web app keeps it as its cursor for [POST /sync](#post-sync)
- Deleted messages are included as "deleted" so the order is kept

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `cannot_read_channel` | private channel or DM the user is not in, or not in the team |
| 404 | `channel_not_found` | channel does not exist |

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

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | the emoji is empty, too long or not an emoji |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `message_deleted` | the message was deleted |
| 409 | `channel_archived` | the channel is archived or its team was deleted |

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
| 403 | `not_a_member` | user is not in the channel |
| 404 | `message_not_found` | the message doesn't exist, or the user can't read its channel |
| 409 | `channel_archived` | the channel is archived or its team was deleted |

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

<a id="get-attachments-file_id"></a>
## GET /attachments/{file_id}
Download a file of a message. chatty-chat checks that the user can read the message's channel, then redirects to a MinIO URL it signs itself with its read-only key (D-02). Avatars and team icons are downloaded from chatty-core ([GET /files/{file_id}](api-core.md#get-files-file_id)).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** users who [can read](#access) the channel of the message that has the file

**Response 302**: `Location` header with a presigned GET URL, valid 5 minutes

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `cannot_read_channel` | the user can't read the message's channel |
| 404 | `attachment_not_found` | no message has this file, or the message was deleted |

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
- The new counts are also sent as an `unread` message on the WebSocket to the user's other tabs and devices

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `seq` missing or negative |
| 403 | `not_a_member` | user is not in the channel |
| 404 | `channel_not_found` | channel does not exist |

---

<a id="get-unread"></a>
## GET /unread
Unread messages and unread mentions of every channel I am in, in one team. Used for the sidebar badges.

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
- `mentions`: unread messages that mention me
- Channels with nothing unread are included with `0`, so the web app can clear badges

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `team_id` missing |
| 403 | `not_a_team_member` | the user is not in the team |

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
- `heartbeat`: every 20 s. `visible` says if the tab is on screen (used to skip push notifications). No heartbeat for 60 s means offline
- `typing`: at most once every 3 s per channel, only in channels the user can write in
- `watch`: live updates for one public channel the user has not joined but is looking at. Only for channels in the user's `public_channel_ids`. Max 1 per socket; a new `watch` replaces the old one. No read state or unread counts

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
{ "type": "channel.updated", "channel_id": "42aa…", "name": "releases", "topic": "Release notes", "archived": false }
```
```json
{ "type": "error", "code": "cannot_watch", "message": "channel is not public in your teams" }
```
- `event`: one channel event, see [events](#events)
- `typing`: the web app hides it after 5 s
- `presence`: `online` or `offline`, sent to the members of each team the user is in
- `channel.updated`: forwarded from chatty-core so the sidebar refreshes
- `error`: a client message was rejected; the socket stays open

**Close codes**
| Code | Reason | What the web app does |
|---|---|---|
| `4001` | `token_expired` | refresh the token through chatty-core, reconnect, call [POST /sync](#post-sync) |
| `4003` | `user_inactive` | log out |
| `4008` | `too_many_messages` | wait, reconnect, call [POST /sync](#post-sync) |
| `1001` | gateway restart | reconnect with backoff, call [POST /sync](#post-sync) |

- The web app may refresh the token about 1 minute before `exp` and reconnect early, so the socket is not closed with `4001`.
- When the user is removed from a channel (`membership.changed` from chatty-core), the gateway stops sending that channel's events right away. No message is sent; the sidebar updates from chatty-core.

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

**Client rule:** ignore if `seq` <= last seen. If `seq` > last seen + 1, call `POST /sync`.

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
