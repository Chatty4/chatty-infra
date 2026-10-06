# chatty-core events

Redis pub/sub channel: `core.events` · IDs: `uuid` · Times: ISO 8601 UTC

The 5 events that chatty-core publishes on Redis, with their exact JSON and what chatty-chat does with each one. Source: `docs/decisions.md` (D-06, D-08), [api-core.md](api-core.md#events) and the chatty-chat Confluence page (section 3). The events that chatty-chat sends to the web app are in [events.md](events.md). If this file and the page disagree, fix one of them in the same pull request.

## Contents

- [How they are sent](#transport)
- [The event envelope](#envelope)
- [membership.changed](#event-membership-changed)
- [team.member.changed](#event-team-member-changed)
- [channel.updated](#event-channel-updated)
- [team.deleted](#event-team-deleted)
- [user.deactivated](#event-user-deactivated)
- [Missed events](#missed-events)

---

<a id="transport"></a>
## How they are sent

| Item | Value |
|---|---|
| Transport | Redis pub/sub |
| Channel | `core.events`, one channel for all 5 events. chatty-chat tells them apart by `type` |
| Publisher | chatty-core, after its database transaction commits (`transaction.on_commit`), so a call made after the event always returns the new data |
| Subscribers | the chatty-chat `api` and every `gateway`, all of them to all 5 events |
| Stored | no. Pub/sub keeps nothing: a subscriber that is not connected misses the event |
| Delivery | at most once. See [missed events](#missed-events) |

- The events carry only IDs and the few values chatty-chat needs to react. For everything else, chatty-chat calls chatty-core's [internal API](api-internal.md) again, because it clears its cache first ([caching](api-internal.md#caching)).
- If publishing fails, chatty-core writes an error to its log and the request still succeeds. The cache TTL fixes the data later.

---

<a id="envelope"></a>
## The event envelope

```json
{
  "type": "membership.changed",
  "occurred_at": "2026-10-06T12:00:00Z",
  "data": { }
}
```

| Field | Type | Meaning |
|---|---|---|
| `type` | string | one of the 5 types below |
| `occurred_at` | ISO 8601 | when chatty-core committed the change |
| `data` | object | depends on `type`, see below. Never `null` |

**Rules for chatty-chat**
- A `type` it doesn't know is logged and ignored.
- A field it doesn't know is ignored, so chatty-core can add fields later.
- Do not depend on the order of two events from different requests. Every event only clears a cache or closes a connection, so a different order gives the same result.

---

<a id="event-membership-changed"></a>
## membership.changed
A user was added to a channel, removed from it, or changed their settings for it.
```json
{
  "type": "membership.changed",
  "occurred_at": "2026-10-06T12:00:00Z",
  "data": {
    "user_id": "u3…",
    "channel_id": "c8…",
    "team_id": "t1…",
    "action": "added"
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `user_id` | uuid | the user the change is about |
| `channel_id` | uuid | the channel |
| `team_id` | uuid | the team of the channel |
| `action` | string | `added`, `removed` or `settings` |

**Published by:** create a channel, join, leave, add or remove members, open a DM (one event for each member), join a team (one for each default channel), [PUT /channels/{channel_id}/me](api-core.md#put-channels-channel_id-me)

**`action`**
- `added`: the user joined the channel, was added, or created it.
- `removed`: the user left, or was removed.
- `settings`: the user's `notify_level`, `muted` or `hidden` for this channel changed. The event has no values: chatty-chat gets them from [GET /internal/users/{user_id}/memberships](api-internal.md#get-internal-users-user_id-memberships).

**chatty-chat**
- Deletes `members:{user_id}` and `channel:{channel_id}`.
- `added`: the gateways subscribe the user's sockets to the channel.
- `removed`: the gateways unsubscribe them right away, so the user gets no more events of the channel.
- `settings`: only the cache. Mute and notify level are used for push.

---

<a id="event-team-member-changed"></a>
## team.member.changed
A user joined a team, left it, was removed from it, or got a new role in it.
```json
{
  "type": "team.member.changed",
  "occurred_at": "2026-10-06T12:00:00Z",
  "data": {
    "user_id": "u7…",
    "team_id": "t1…",
    "action": "role_changed",
    "role": "admin"
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `user_id` | uuid | the user the change is about |
| `team_id` | uuid | the team |
| `action` | string | `joined`, `left`, `removed` or `role_changed` |
| `role` | string or `null` | the user's role in the team after the change: `owner`, `admin` or `member`. `null` when `action` is `left` or `removed`. Always present |

**Published by:** [join with an invite](api-core.md#post-invites-invite_code-join), [leave a team](api-core.md#post-teams-team_id-leave), [remove a member](api-core.md#delete-teams-team_id-members-user_id), [change a role](api-core.md#put-teams-team_id-members-user_id)

**chatty-chat**
- Deletes `members:{user_id}`.
- `joined`: nothing else. The user's channels arrive as `membership.changed` events.
- `left` / `removed`: the gateways unsubscribe the user from all channels of the team and stop their presence there.
- `role_changed`: the new role applies to delete rights, from the next request ([D-05](decisions.md)).

---

<a id="event-channel-updated"></a>
## channel.updated
A channel was renamed, its topic changed, or it was archived.
```json
{
  "type": "channel.updated",
  "occurred_at": "2026-10-06T12:00:00Z",
  "data": {
    "channel_id": "c8…",
    "team_id": "t1…",
    "name": "releases",
    "topic": "Release notes",
    "archived": false
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `channel_id` | uuid | the channel |
| `team_id` | uuid | the team of the channel |
| `name` | string | the channel's name now |
| `topic` | string or `null` | the channel's topic now. `null` if it has none |
| `archived` | boolean | true if the channel is archived |

- Always has all 3 values, not only the one that changed, so chatty-chat can overwrite what it has.

**Published by:** [rename or change topic](api-core.md#put-channels-channel_id), [archive](api-core.md#post-channels-channel_id-archive)

**chatty-chat**
- Deletes `channel:{channel_id}`.
- `archived: true`: writes to the channel return `409 channel_archived`.
- The gateways send a [channel.updated](events.md#ws-channel-updated) message with `name`, `topic` and `archived` to the channel's members, so the sidebar refreshes.

---

<a id="event-team-deleted"></a>
## team.deleted
A team was deleted (soft delete).
```json
{
  "type": "team.deleted",
  "occurred_at": "2026-10-06T12:00:00Z",
  "data": {
    "team_id": "t1…"
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `team_id` | uuid | the deleted team |

**Published by:** [DELETE /teams/{team_id}](api-core.md#delete-teams-team_id)

**chatty-chat**
- Deletes the cache of the team's channels.
- Rejects writes to those channels with `409 channel_archived`.
- The gateways unsubscribe all sockets from the team's channels.

---

<a id="event-user-deactivated"></a>
## user.deactivated
A platform admin deactivated a user in Django admin.
```json
{
  "type": "user.deactivated",
  "occurred_at": "2026-10-06T12:00:00Z",
  "data": {
    "user_id": "u7…"
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `user_id` | uuid | the deactivated user |

**Published by:** deactivating a user in Django admin

**chatty-chat**
- Deletes `members:{user_id}`.
- The gateways close all the user's sockets with code `4003` (`user_inactive`).
- New requests fail with `403 user_inactive`, because [memberships](api-internal.md#get-internal-users-user_id-memberships) now returns `is_active: false`.

---

<a id="missed-events"></a>
## Missed events

Redis pub/sub does not store events. If chatty-chat is down, restarting, or loses its connection, it misses the events sent meanwhile.

- **Every time** the `api` or a `gateway` subscribes to `core.events` (at start and after every reconnect), it deletes all its `members:*` and `channel:*` cache keys. Events can only be missed while the subscription is down, so this covers the gap.
- The 5-minute TTL on `members:{user_id}` and `channel:{channel_id}` is a backstop if an event is lost while the subscription is up.
