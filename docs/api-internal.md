# chatty-core internal API contracts

Base URL: `/internal` · Auth: `X-Service-Token: <token>` · IDs: `uuid` · Times: ISO 8601 UTC

Endpoints that chatty-core exposes for chatty-chat only. They are not reachable from the internet. The public endpoints are in [api-core.md](api-core.md).

Source: the chatty-core Confluence page (section 4, internal endpoints) and `docs/decisions.md` (D-02, D-03, D-07). If this file and the page disagree, fix one of them in the same pull request.

## Endpoints

**Access checks**
- [GET /internal/users/{user_id}/memberships](#get-internal-users-user_id-memberships)
- [GET /internal/channels/{channel_id}](#get-internal-channels-channel_id)

**Files**
- [POST /internal/files/{file_id}/attach](#post-internal-files-file_id-attach)
- [POST /internal/files/{file_id}/detach](#post-internal-files-file_id-detach)

**Push (post-MVP)**
- [GET /internal/users/{user_id}/push-subscriptions](#get-internal-users-user_id-push-subscriptions)
- [DELETE /internal/push-subscriptions/{subscription_id}](#delete-internal-push-subscriptions-subscription_id)

**Health**
- [GET /health](#get-health)

**Other**
- [Authorization (X-Service-Token)](#authorization)
- [Errors that every endpoint can return](#common-errors)
- [Caching in chatty-chat](#caching)

---

<a id="authorization"></a>
## Authorization (X-Service-Token)

**The token**
- One shared secret, at least 32 random bytes, for example made with `openssl rand -hex 32`.
- It is set as an environment variable in both services: `CORE_SERVICE_TOKEN` in chatty-core and in chatty-chat. It never goes into git, the web app or logs.
- To change it, set the new value in both services and restart them.

**Sending the token**
- Every internal endpoint needs the header `X-Service-Token: <token>`. There is no JWT on these calls: they are made by chatty-chat, not by a user.
- chatty-core compares it in constant time (`hmac.compare_digest`). A missing or wrong token returns `401 invalid_service_token`.

**Who can reach these endpoints**
- Only services on the Docker network, for example `http://chatty-core:8000/internal/...`.
- Nginx does not route `/internal` to the outside, so a request from the internet gets `404` from Nginx before it reaches chatty-core.
- The token is the second protection, in case the network rule is ever wrong.

---

<a id="common-errors"></a>
## Errors that every endpoint can return

Every error has the same body as in [api-core.md](api-core.md#common-errors):
```json
{
  "error": {
    "code": "invalid_service_token",
    "message": "missing or wrong X-Service-Token"
  }
}
```

| Status | code | When |
|---|---|---|
| 400 | `validation_error` | a field is missing or has the wrong type |
| 401 | `invalid_service_token` | missing or wrong `X-Service-Token` |
| 500 | `internal_error` | a bug; the response has a `request_id` to find it in the logs |

The errors below each endpoint are only the ones specific to it.

---

<a id="caching"></a>
## Caching in chatty-chat

| Endpoint | Redis key in chatty-chat | TTL | Cleared by the event |
|---|---|---|---|
| [GET /internal/users/{user_id}/memberships](#get-internal-users-user_id-memberships) | `members:{user_id}` | 5 minutes | `membership.changed`, `team.member.changed`, `user.deactivated` |
| [GET /internal/channels/{channel_id}](#get-internal-channels-channel_id) | `channel:{channel_id}` | 5 minutes | `membership.changed`, `channel.updated`, `team.deleted` |

- chatty-core publishes the events only after its transaction commits, so a call made after the event always returns the new data.
- The TTL is a backstop if an event is lost. The other endpoints are never cached.

---

# Access checks

<a id="get-internal-users-user_id-memberships"></a>
## GET /internal/users/{user_id}/memberships
Everything chatty-chat needs to check what a user can read and write (D-07): whether the account is active, the user's teams with their role, and the user's channels with their settings.

**Auth:** `X-Service-Token: <token>`

**Who:** chatty-chat `api` and `gateway`, on a cache miss of `members:{user_id}`

**Response 200**
```json
{
  "user_id": "u7…",
  "is_active": true,
  "teams": [
    {
      "team_id": "t1…",
      "role": "admin",
      "public_channel_ids": ["c0…", "c8…"]
    }
  ],
  "channels": [
    {
      "channel_id": "c0…",
      "team_id": "t1…",
      "kind": "public",
      "archived": false,
      "role": "member",
      "notify_level": "mentions",
      "muted": false,
      "hidden": false
    },
    {
      "channel_id": "c5…",
      "team_id": "t1…",
      "kind": "dm",
      "archived": false,
      "role": "member",
      "notify_level": "all",
      "muted": false,
      "hidden": true
    }
  ]
}
```
- `teams[].role`: `owner`, `admin` or `member`
- `teams[].public_channel_ids`: all public channels of the team, joined or not, so chatty-chat lets team members read public channels they haven't joined
- `channels`: only channels the user is a member of. `role`: `owner` or `member`. `kind`: `public`, `private` or `dm`
- Deleted teams and their channels are left out
- A deactivated user still returns 200, with `is_active: false`, so chatty-chat can refuse their requests and close their sockets

**Errors**
| Status | code | When |
|---|---|---|
| 404 | `user_not_found` | no user with this ID |

---

<a id="get-internal-channels-channel_id"></a>
## GET /internal/channels/{channel_id}
One channel with all its members and their notification settings. Used to check writes, to validate @mentions (only members can be mentioned) and to decide who gets a push notification.

**Auth:** `X-Service-Token: <token>`

**Who:** chatty-chat `api` and `push-worker`, on a cache miss of `channel:{channel_id}`

**Response 200**
```json
{
  "channel_id": "c5…",
  "team_id": "t1…",
  "kind": "dm",
  "archived": false,
  "team_deleted": false,
  "members": [
    {
      "user_id": "u7…",
      "role": "member",
      "notify_level": "all",
      "muted": false
    },
    {
      "user_id": "u3…",
      "role": "member",
      "notify_level": "all",
      "muted": true
    }
  ]
}
```
- `archived: true` or `team_deleted: true`: the channel is read only, chatty-chat rejects writes with `409`
- `members[].role`: `owner` or `member`. DMs have no owner, every member is `member`
- `members[].notify_level`: `all`, `mentions` or `none`. DMs default to `all`, channels to `mentions`

**Errors**
| Status | code | When |
|---|---|---|
| 404 | `channel_not_found` | no channel with this ID |

---

# Files

<a id="post-internal-files-file_id-attach"></a>
## POST /internal/files/{file_id}/attach
Called **before** chatty-chat saves a message with files (D-03). chatty-core checks the file and marks it attached (`attached_at`) in one step, so its cleanup job never deletes a file that is in a sent message. The response has what chatty-chat stores in its `attachments` table to show and sign downloads without calling chatty-core again (D-02).

**Auth:** `X-Service-Token: <token>`

**Who:** chatty-chat `api`, once per file, while handling `POST /channels/{channel_id}/messages`

**Request**
```json
{
  "user_id": "u7…",
  "channel_id": "c8…"
}
```
- `user_id`: the sender of the message
- `channel_id`: the channel the message is sent to

**Response 200**
```json
{
  "file_id": "f6…",
  "object_key": "attachments/t1…/f6…",
  "filename": "report.pdf",
  "mime": "application/pdf",
  "size": 482133,
  "attached_at": "2026-10-06T12:00:03Z"
}
```

**Checks, in this order**
1. The file exists and was not deleted.
2. It was uploaded by `user_id`.
3. Its purpose is `attachment`.
4. Its `team_id` is the team of `channel_id`.
5. Its status is `ready`.
6. It is not attached yet.

**Errors**
| Status | code | When |
|---|---|---|
| 404 | `file_not_found` | no file with this ID, or it was deleted |
| 403 | `not_file_owner` | the file was uploaded by another user |
| 400 | `wrong_purpose` | the file is an avatar or a team icon |
| 400 | `wrong_team` | the file belongs to another team than the channel |
| 409 | `file_not_ready` | the upload was not confirmed |
| 409 | `file_already_attached` | the file is already in a message |

- chatty-chat checks `client_msg_id` before calling `attach`, so a retried send returns the original message instead of attaching the files again.
- If one file fails, chatty-chat calls [detach](#post-internal-files-file_id-detach) for the files already attached in that request and rejects the message.

---

<a id="post-internal-files-file_id-detach"></a>
## POST /internal/files/{file_id}/detach
Called when a message with this file is deleted, or when saving the message failed after [attach](#post-internal-files-file_id-attach). chatty-core sets `attached_at` to empty and `deleted_at` to now. The file can't be attached or downloaded anymore, and the cleanup job removes it from MinIO.

**Auth:** `X-Service-Token: <token>`

**Who:** chatty-chat `api`, after `DELETE /messages/{id}` commits, or after a failed save

**Request**: no body

**Response 204** (no body). Also 204 if the file was already detached, so chatty-chat can retry safely.

**Errors**
| Status | code | When |
|---|---|---|
| 404 | `file_not_found` | no file with this ID |

- If this call fails, chatty-chat retries it later. If it is lost, the file only stays attached but unused, which is harmless.

---

# Push (post-MVP)

<a id="get-internal-users-user_id-push-subscriptions"></a>
## GET /internal/users/{user_id}/push-subscriptions
The browsers where a user allowed notifications. chatty-chat's push worker sends Web Push to each of them.

**Auth:** `X-Service-Token: <token>`

**Who:** chatty-chat `push-worker`

**Response 200**
```json
{
  "subscriptions": [
    {
      "id": "p1…",
      "endpoint": "https://fcm.googleapis.com/fcm/send/…",
      "p256dh": "BOr…",
      "auth": "k8J…"
    }
  ]
}
```
- An empty list if the user has no subscriptions or doesn't exist

---

<a id="delete-internal-push-subscriptions-subscription_id"></a>
## DELETE /internal/push-subscriptions/{subscription_id}
Called when the push service answers `410 Gone` (the browser revoked permission), so the worker stops sending to it.

**Auth:** `X-Service-Token: <token>`

**Who:** chatty-chat `push-worker`

**Response 204** (no body). Also 204 if it was already deleted.

---

# Health

<a id="get-health"></a>
## GET /health
Health check for Docker and monitoring. Note: the path is `/health`, not under `/internal`.

**Auth:** none. Only reachable on the Docker network.

**Who:** Docker health checks, monitoring, chatty-chat at startup

**Response 200**
```json
{
  "status": "ok",
  "db": "ok",
  "redis": "ok",
  "minio": "ok"
}
```

**Response 503**: the same body, with `"status": "degraded"` and the failing dependency set to `"error"`.
