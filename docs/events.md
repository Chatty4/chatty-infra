# chatty-chat events

WebSocket: `/api/chat/v1/ws` · Kafka topic: `chat.events` · IDs: `uuid` · Times: ISO 8601 UTC

Every message the web app can receive from chatty-chat, with its exact JSON, and the rules the web app follows when it misses one. Source: the chatty-chat Confluence page (sections 6 and 8), [api-chat.md](api-chat.md) and `docs/decisions.md`. The events that chatty-core sends to chatty-chat over Redis are in [core-events.md](core-events.md). If this file and the page disagree, fix one of them in the same pull request.

## Contents

**How it works**
- [Where an event travels](#where)
- [The event envelope](#envelope)
- [Client rules for `seq`](#client-rules)

**WebSocket messages**
- [Client → server](#ws-client)
- [Server → client](#ws-server)
- [Close codes](#ws-close)

**Channel events** (have a `seq`, are stored, go to Kafka)
- [message.created](#event-message-created)
- [message.edited](#event-message-edited)
- [message.deleted](#event-message-deleted)
- [reaction.added](#event-reaction-added)
- [reaction.removed](#event-reaction-removed)
- [pin.added](#event-pin-added)
- [pin.removed](#event-pin-removed)

**Kafka**
- [Topic `chat.events`](#kafka)
- [Consumers](#kafka-consumers)

---

<a id="where"></a>
## Where an event travels

There are two kinds of messages. Only the first kind is an event.

| | Channel events | Live messages |
|---|---|---|
| Examples | `message.created`, `reaction.added`, `pin.removed` | `typing`, `presence`, `unread`, `channel.updated` |
| Has a `seq` | yes, the next number of its channel | no |
| Stored | yes, in the `channel_events` table (30 days) | no, sent once and forgotten |
| WebSocket | yes, inside `{"type": "event", …}` | yes, as a message of its own |
| Kafka `chat.events` | yes | no |
| Can be fetched later | yes: [POST /sync](api-chat.md#post-sync), [GET /channels/{channel_id}/events](api-chat.md#get-channels-channel_id-events) | no. If the web app misses one, the next one fixes it |

Writes never go through the WebSocket. The web app sends them with REST, and chatty-chat answers with the REST response and with an event to everyone who can read the channel.

---

<a id="envelope"></a>
## The event envelope

Every channel event has the same shape everywhere: on the WebSocket, in the answers of `POST /sync` and `GET /channels/{channel_id}/events`, and in Kafka.

```json
{
  "type": "message.created",
  "channel_id": "42aa…",
  "seq": 108,
  "created_at": "2026-10-05T14:02:11Z",
  "payload": { }
}
```

| Field | Type | Meaning |
|---|---|---|
| `type` | string | one of the seven types below |
| `channel_id` | uuid | the channel the event belongs to |
| `seq` | integer | the event's place in the channel, starting at 1. Every event of a channel takes the next number, so messages have gaps between their `seq` (edits, reactions and pins take numbers too) |
| `created_at` | ISO 8601 | when the change happened |
| `payload` | object | depends on `type`, see below. Never `null` |

- `seq` is only unique inside one channel. Two channels can both have `seq: 5`.
- The same event is never changed after it is written. A correction is a new event (for example `message.edited`).

---

<a id="client-rules"></a>
## Client rules for `seq`

The web app keeps one number per channel: the last `seq` it has applied (`last_seen`). It gets the first value from `last_seq` in [GET /channels/{channel_id}/messages](api-chat.md#get-channels-channel_id-messages).

**When an event arrives**

| Case | What the web app does |
|---|---|
| `seq` <= `last_seen` | Ignore it. It is a duplicate (Kafka delivers at least once, and a reconnect can repeat events) |
| `seq` = `last_seen` + 1 | Apply it and set `last_seen = seq` |
| `seq` > `last_seen` + 1 | There is a gap. Do **not** apply it. Call [GET /channels/{channel_id}/events](api-chat.md#get-channels-channel_id-events) with `after_seq=last_seen`, apply the returned events in order, then apply this one |

**After a reconnect** (close codes `4001`, `4008`, `1001`, or a dropped network)
1. Reconnect the WebSocket. Events that arrive meanwhile are held back until step 2 is done.
2. Call [POST /sync](api-chat.md#post-sync) with `last_seen` of every channel the web app has open.
3. Apply the returned events of each channel in order, then release the held-back ones (the duplicate rule drops the ones already applied).

**When the answer says the gap is too big**
- `POST /sync` returns `gap_too_large: true` for a channel, or `GET …/events` returns `409 gap_too_large`. This happens when more than 500 events are missing, or they are older than 30 days.
- The web app throws away that channel's messages and reloads it with [GET /channels/{channel_id}/messages](api-chat.md#get-channels-channel_id-messages), then takes `last_seq` from the answer.

**Other rules**
- A channel the web app never opened has no `last_seen`. It is loaded with the history endpoint, not with sync.
- An event about a message the web app doesn't have (for example `message.edited` for a message that is far up in the history) is ignored but still moves `last_seen`. The message comes from the history endpoint when the user scrolls to it.
- A reaction event moves `count`. `me` changes only when `payload.user_id` is the current user.
- `typing`, `presence`, `unread` and `channel.updated` have no `seq`, so none of these rules apply to them.

---

<a id="ws-client"></a>
## WebSocket: client → server

Connect with `GET /api/chat/v1/ws?token=<JWT>` (see [GET /ws](api-chat.md#get-ws)). Messages are JSON text frames.

<a id="ws-heartbeat"></a>
### heartbeat
```json
{ "type": "heartbeat", "visible": true }
```
- Every 20 s. `visible` is true when the tab is on screen (a visible tab gets no push notification). No heartbeat for 60 s means the user is offline.

<a id="ws-typing-out"></a>
### typing
```json
{ "type": "typing", "channel_id": "42aa…" }
```
- At most once every 3 s per channel, only in channels the user can write in.

<a id="ws-watch"></a>
### watch
```json
{ "type": "watch", "channel_id": "c8…" }
```
- Live events of one public channel the user has not joined but is looking at. Only for channels in the user's `public_channel_ids`. One per socket, a new `watch` replaces the old one. No read state or unread counts for it.

<a id="ws-unwatch"></a>
### unwatch
```json
{ "type": "unwatch", "channel_id": "c8…" }
```

---

<a id="ws-server"></a>
## WebSocket: server → client

<a id="ws-event"></a>
### event
A channel event inside a wrapper.
```json
{
  "type": "event",
  "event": {
    "type": "reaction.added",
    "channel_id": "42aa…",
    "seq": 110,
    "created_at": "2026-10-05T14:06:02Z",
    "payload": { "message_id": "9f3a…", "user_id": "u3…", "emoji": "👍" }
  }
}
```
- `event` is exactly the [envelope](#envelope). The web app handles it with the [client rules](#client-rules).
- Sent to every socket whose user [can read](api-chat.md#access) the channel, plus the sockets that `watch` it.

<a id="ws-typing-in"></a>
### typing
```json
{ "type": "typing", "channel_id": "42aa…", "user_id": "u3…" }
```
- Someone is typing. The web app hides it after 5 s.

<a id="ws-presence"></a>
### presence
```json
{ "type": "presence", "team_id": "t1…", "user_id": "u3…", "status": "online" }
```
- `status`: `online` or `offline`. Sent to the members of every team the user is in.

<a id="ws-unread"></a>
### unread
```json
{ "type": "unread", "channel_id": "42aa…", "unread": 0, "mentions": 0 }
```
- The new counts of one channel. Sent to the user's other tabs and devices after [POST /channels/{channel_id}/read](api-chat.md#post-channels-channel_id-read). `unread` is capped at 100 (the UI shows 99+).

<a id="ws-channel-updated"></a>
### channel.updated
```json
{ "type": "channel.updated", "channel_id": "42aa…", "name": "releases", "topic": "Release notes", "archived": false }
```
- Forwarded from chatty-core's [channel.updated](core-events.md) event, so the sidebar refreshes. It always has the full values, not only the changed ones. It has no `seq`.

<a id="ws-error"></a>
### error
```json
{ "type": "error", "code": "cannot_watch", "message": "channel is not public in your teams" }
```
- A client message was rejected. The socket stays open.

| `code` | When |
|---|---|
| `cannot_watch` | `watch` for a channel that is not in the user's `public_channel_ids` |

---

<a id="ws-close"></a>
## WebSocket: close codes

| Code | Reason | What the web app does |
|---|---|---|
| `4001` | `token_expired` | refresh the token through chatty-core, reconnect, then [POST /sync](api-chat.md#post-sync) |
| `4003` | `user_inactive` | log out |
| `4008` | `too_many_messages` | wait, reconnect, then `POST /sync` |
| `1001` | gateway restart | reconnect with backoff, then `POST /sync` |

- The web app can refresh the token about 1 minute before `exp` and reconnect early, so the socket is never closed with `4001`.
- When the user is removed from a channel, the gateway stops sending that channel's events. It sends no message about it: the sidebar updates from chatty-core.

---

# Channel events

Each event below is an [envelope](#envelope) with a different `payload`. The examples show the whole envelope.

<a id="event-message-created"></a>
## message.created
A message was sent.
```json
{
  "type": "message.created",
  "channel_id": "42aa…",
  "seq": 108,
  "created_at": "2026-10-05T14:02:11Z",
  "payload": {
    "message": {
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
  }
}
```
- Sent by: [POST /channels/{channel_id}/messages](api-chat.md#post-channels-channel_id-messages)
- `payload.message` is the full [message object](api-chat.md#message-object). `message.seq` is the same number as the event's `seq`.
- `reactions` is always empty and has no `me`, because the same event goes to everyone.
- The web app adds the message to the channel. If it already has the message from the REST answer of its own send (same `id`), it keeps one copy.

<a id="event-message-edited"></a>
## message.edited
The text of a message changed.
```json
{
  "type": "message.edited",
  "channel_id": "42aa…",
  "seq": 111,
  "created_at": "2026-10-05T14:07:30Z",
  "payload": {
    "message_id": "9f3a…",
    "body": "deploy at 6? <@u3…>",
    "mentions": ["u3…"],
    "edited_at": "2026-10-05T14:07:30Z"
  }
}
```
- Sent by: [PUT /messages/{message_id}](api-chat.md#put-messages-message_id)
- `body` and `mentions` replace the old values. Files can't change.

<a id="event-message-deleted"></a>
## message.deleted
A message was deleted (soft delete).
```json
{
  "type": "message.deleted",
  "channel_id": "42aa…",
  "seq": 112,
  "created_at": "2026-10-05T14:08:00Z",
  "payload": {
    "message_id": "9f3a…",
    "deleted_by": "u7…",
    "deleted_at": "2026-10-05T14:08:00Z"
  }
}
```
- Sent by: [DELETE /messages/{message_id}](api-chat.md#delete-messages-message_id)
- `deleted_by` can be the author, the channel owner or a team owner or admin.
- The web app shows the message as deleted, removes its files, reactions and mentions, and removes it from the pins. There is no separate `pin.removed` for that.

<a id="event-reaction-added"></a>
## reaction.added
Someone reacted to a message.
```json
{
  "type": "reaction.added",
  "channel_id": "42aa…",
  "seq": 110,
  "created_at": "2026-10-05T14:06:02Z",
  "payload": { "message_id": "9f3a…", "user_id": "u3…", "emoji": "👍" }
}
```
- Sent by: [PUT /messages/{message_id}/reactions/{emoji}](api-chat.md#put-messages-message_id-reactions-emoji), only if the reaction is new
- The web app adds 1 to `count` for this `emoji`, and sets `me: true` if `user_id` is the current user.

<a id="event-reaction-removed"></a>
## reaction.removed
Someone removed their reaction.
```json
{
  "type": "reaction.removed",
  "channel_id": "42aa…",
  "seq": 113,
  "created_at": "2026-10-05T14:09:00Z",
  "payload": { "message_id": "9f3a…", "user_id": "u3…", "emoji": "👍" }
}
```
- Sent by: [DELETE /messages/{message_id}/reactions/{emoji}](api-chat.md#delete-messages-message_id-reactions-emoji), only if a reaction was removed
- The web app subtracts 1 from `count` (the emoji disappears at 0), and sets `me: false` if `user_id` is the current user.

<a id="event-pin-added"></a>
## pin.added
A message was pinned.
```json
{
  "type": "pin.added",
  "channel_id": "42aa…",
  "seq": 114,
  "created_at": "2026-10-05T14:10:00Z",
  "payload": { "message_id": "9f3a…", "pinned_by": "u7…", "pinned_at": "2026-10-05T14:10:00Z" }
}
```
- Sent by: [POST /channels/{channel_id}/pins/{message_id}](api-chat.md#post-channels-channel_id-pins-message_id), only if it was not pinned before
- The web app sets `pinned: true` on the message and adds it to the pin list.

<a id="event-pin-removed"></a>
## pin.removed
A message was unpinned.
```json
{
  "type": "pin.removed",
  "channel_id": "42aa…",
  "seq": 115,
  "created_at": "2026-10-05T14:12:00Z",
  "payload": { "message_id": "9f3a…", "unpinned_by": "u7…" }
}
```
- Sent by: [DELETE /channels/{channel_id}/pins/{message_id}](api-chat.md#delete-channels-channel_id-pins-message_id), only if it was pinned
- The web app sets `pinned: false` on the message and removes it from the pin list.

---

<a id="kafka"></a>
# Kafka

## Topic `chat.events`

Every channel event is also written to Kafka, for the services that are not the web app: the gateways, and later the push worker and the search indexer.

| Item | Value |
|---|---|
| Topic | `chat.events` |
| Message key | `channel_id`, so all events of one channel land in one partition, in order |
| Partitions | 6 (enough for the MVP; this number is hard to change later) |
| Retention | 7 days |
| Value | the [envelope](#envelope) as JSON, the same as on the WebSocket: `{type, channel_id, seq, created_at, payload}` |
| Broker | 1 broker in KRaft mode (no ZooKeeper) for dev and the MVP |
| Python client | `aiokafka` |

- Only [channel events](#where) are written. `typing`, `presence`, `unread` and `channel.updated` never go to Kafka.
- The REST history keeps events for 30 days, Kafka for 7. The web app recovers with REST, never with Kafka.

**How an event gets there (outbox relay)**
1. The REST endpoint saves the change and the `channel_events` row in one database transaction, then commits.
2. The relay selects up to 100 rows with `published_at IS NULL`, in `id` order (`FOR UPDATE SKIP LOCKED`).
3. It produces them to Kafka in that order and waits for the acknowledgement.
4. It sets `published_at = now()` and commits.
5. The relay wakes up on `NOTIFY chat_events` (sent after each commit) and also polls every 200 ms.

- Run exactly **one** relay. Two relays could publish the events of a channel out of order.
- If Kafka is down, rows stay unpublished and are sent when it is back. The REST endpoints keep working.

**Delivery:** at least once. A duplicate is harmless: the web app ignores a `seq` it already has, and the push worker skips events it already sent.

**Until the Kafka epic lands** (sprints 5 to 6), the gateways read events from Redis pub/sub behind the same `EventBus` interface. The JSON is the same, so the web app does not change.

<a id="kafka-consumers"></a>
## Consumers

| Consumer | Group ID | Starts from | Commits offsets | Why |
|---|---|---|---|---|
| Each gateway | `gateway-{instance_id}` (unique per instance) | latest | no | Every gateway must see every event. Missed events are recovered by the client with `POST /sync` |
| Push worker *(post-MVP)* | `push-worker` (shared) | last committed | yes, after sending | Each event is handled once, even with 2 or more workers |
| Search indexer *(post-MVP)* | `search-indexer` | last committed | yes | Can rebuild the index by replaying the topic |
