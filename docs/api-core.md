# chatty-core API contracts

Base URL: `/api/core/v1` · Auth: `Authorization: Bearer <JWT>` · IDs: `uuid` · Times: ISO 8601 UTC

Source: the chatty-core Confluence page (section 4) and `docs/decisions.md`. If this file and the page disagree, fix one of them in the same pull request.

## Endpoints

**Auth and me**
- [POST /auth/register](#post-auth-register)
- [POST /auth/login](#post-auth-login)
- [POST /auth/refresh](#post-auth-refresh)
- [POST /auth/logout](#post-auth-logout)
- [POST /auth/password](#post-auth-password)
- [GET /me](#get-me)
- [PUT /me](#put-me)

**Teams and team members**
- [GET /teams](#get-teams)
- [POST /teams](#post-teams)
- [GET /teams/{team_id}](#get-teams-team_id)
- [PUT /teams/{team_id}](#put-teams-team_id)
- [DELETE /teams/{team_id}](#delete-teams-team_id)
- [POST /teams/{team_id}/leave](#post-teams-team_id-leave)
- [GET /teams/{team_id}/members](#get-teams-team_id-members)
- [PUT /teams/{team_id}/members/{user_id}](#put-teams-team_id-members-user_id)
- [DELETE /teams/{team_id}/members/{user_id}](#delete-teams-team_id-members-user_id)

**Invites**
- [POST /teams/{team_id}/invites](#post-teams-team_id-invites)
- [GET /teams/{team_id}/invites](#get-teams-team_id-invites)
- [DELETE /invites/{invite_id}](#delete-invites-invite_id)
- [GET /invites/{invite_code}](#get-invites-invite_code)
- [POST /invites/{invite_code}/join](#post-invites-invite_code-join)

**Channels and DMs**
- [GET /teams/{team_id}/channels](#get-teams-team_id-channels)
- [GET /teams/{team_id}/channels/browse](#get-teams-team_id-channels-browse)
- [POST /teams/{team_id}/channels](#post-teams-team_id-channels)
- [POST /teams/{team_id}/dms](#post-teams-team_id-dms)
- [GET /channels/{channel_id}](#get-channels-channel_id)
- [PUT /channels/{channel_id}](#put-channels-channel_id)
- [POST /channels/{channel_id}/archive](#post-channels-channel_id-archive)
- [POST /channels/{channel_id}/join](#post-channels-channel_id-join)
- [POST /channels/{channel_id}/leave](#post-channels-channel_id-leave)
- [GET /channels/{channel_id}/members](#get-channels-channel_id-members)
- [POST /channels/{channel_id}/members](#post-channels-channel_id-members)
- [DELETE /channels/{channel_id}/members/{user_id}](#delete-channels-channel_id-members-user_id)
- [PUT /channels/{channel_id}/me](#put-channels-channel_id-me)

**Files**
- [POST /files](#post-files)
- [PUT presigned upload URL](#put-presigned-upload-url)
- [POST /files/{file_id}/confirm](#post-files-file_id-confirm)
- [GET /files/{file_id}](#get-files-file_id)
- [DELETE /files/{file_id}](#delete-files-file_id)

**Push (post-MVP)**
- [POST /push/subscriptions](#post-push-subscriptions)
- [DELETE /push/subscriptions/{subscription_id}](#delete-push-subscriptions-subscription_id)

**Other**
- [Authorization](#authorization)
- [Errors that every endpoint can return](#common-errors)
- [Pagination](#pagination)
- [Events (Redis)](#events)

---

<a id="authorization"></a>
## Authorization

**Getting tokens**
- [POST /auth/register](#post-auth-register) and [POST /auth/login](#post-auth-login) return an `access_token` and a `refresh_token`.
- The access token is a JWT signed by chatty-core with RS256. It lives 15 minutes. Claims: `sub` (user id), `iat`, `exp`, `jti`. It has no teams or roles; those are checked on every request.
- The refresh token lives 30 days and is rotated on every refresh: the old one stops working.
- The same access token is used for chatty-chat, which checks it with chatty-core's public key.

**Sending the token**
- Every endpoint needs `Authorization: Bearer <access_token>`, except the ones marked **Auth:** none.
- No token, a bad signature or an expired token returns `401 unauthorized`.

**When the access token expires**
1. The request returns `401 unauthorized`.
2. The web app calls [POST /auth/refresh](#post-auth-refresh) once, then repeats the request with the new token.
3. If the refresh returns `401 invalid_refresh_token`, the user has to log in again.
- The web app may refresh about 1 minute before `exp` to avoid the failed request.

**What the user is allowed to do**
- The **Who** line of each endpoint says who may call it. It is checked after the token, with the user's role in the team (`owner`, `admin`, `member`) and in the channel (`owner`, `member`).
- A valid token for a user who is not allowed returns `403` with a specific `code` (for example `not_a_team_member` or `forbidden`).
- A deactivated user gets `403 user_inactive`, even with a token that has not expired yet.

---

<a id="common-errors"></a>
## Errors that every endpoint can return

Every error has the same body:
```json
{
  "error": {
    "code": "validation_error",
    "message": "name must be 1-80 characters",
    "fields": { "name": "too_long" }
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

The errors below each endpoint are only the ones specific to it.

---

<a id="pagination"></a>
## Pagination

Lists that can grow without limit use cursor pagination:
- [GET /teams/{team_id}/members](#get-teams-team_id-members)
- [GET /teams/{team_id}/channels/browse](#get-teams-team_id-channels-browse)
- [GET /channels/{channel_id}/members](#get-channels-channel_id-members)

**Query**
- `limit`: items per page, default 50, max 200
- `cursor`: optional, the `next_cursor` of the previous page. Leave it out for the first page

**Response**
```json
{
  "members": [ ],
  "next_cursor": "eyJrIjpbIm1paGFpIiwidTMiXX0"
}
```
- `next_cursor` is `null` on the last page.
- The cursor is opaque: the client sends it back as it is and never builds or reads it. Inside it is the sort key of the last item (keyset pagination), so pages don't skip or repeat items when someone joins or leaves in between.
- Each endpoint has a fixed sort order, written in its contract. Filters such as `q` must be the same on every page; a cursor used with a different `q` returns `invalid_cursor`.

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `limit` is not between 1 and 200 |
| 400 | `invalid_cursor` | the cursor is broken, or was made for another endpoint or another `q` |

Not paginated, because their size has a limit: `GET /teams` (the user's teams), `GET /teams/{team_id}/channels` (the sidebar needs all of it), `GET /teams/{team_id}/invites` (max 100 active invites).

---

# Auth and me

<a id="post-auth-register"></a>
## POST /auth/register
Create an account. The new user has no teams yet. Joining a team happens with an invite.

**Auth:** none

**Who:** anyone, no token. Max 10 per hour per IP (`register:{ip}`).

**Request**
```json
{
  "email": "ana@example.com",
  "display_name": "Ana Pop",
  "password": "correct horse battery"
}
```
- `email`: valid email, stored lowercase, unique
- `display_name`: 1–60 chars
- `password`: at least 10 chars, not a common password, not only digits (Django password validators)

**Response 201**
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs…",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "rt_8Hq2…",
  "refresh_expires_in": 2592000,
  "user": {
    "id": "u7…",
    "email": "ana@example.com",
    "display_name": "Ana Pop",
    "avatar_file_id": null,
    "timezone": "UTC"
  }
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | email not valid, display_name empty or too long, password too weak |
| 409 | `email_taken` | an account with this email exists |
| 429 | `rate_limited` | more than 10 registrations from this IP in an hour |

---

<a id="post-auth-login"></a>
## POST /auth/login
Log in with email and password.

**Auth:** none

**Who:** anyone, no token. Max 5 failed tries per 15 minutes per email and per IP.

**Request**
```json
{
  "email": "ana@example.com",
  "password": "correct horse battery"
}
```

**Response 200**
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs…",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "rt_8Hq2…",
  "refresh_expires_in": 2592000,
  "user": {
    "id": "u7…",
    "email": "ana@example.com",
    "display_name": "Ana Pop",
    "avatar_file_id": "f2…",
    "timezone": "Europe/Bucharest"
  }
}
```
- The access token's claims: `sub` (user id), `iat`, `exp`, `jti`. No teams or roles, chatty-chat reads those from the internal API.

**Errors**
| Status | code | When |
|---|---|---|
| 401 | `invalid_credentials` | wrong email or wrong password (the same code for both, so nobody can find out which emails exist) |
| 403 | `user_inactive` | the password is right but the user was deactivated |
| 429 | `too_many_attempts` | 5 failed tries in 15 minutes for this email or IP |

---

<a id="post-auth-refresh"></a>
## POST /auth/refresh
Get a new access token. The refresh token is rotated: the old one stops working.

**Auth:** none (the refresh token is sent in the body)

**Who:** anyone with a valid refresh token, no access token needed.

**Request**
```json
{
  "refresh_token": "rt_8Hq2…"
}
```

**Response 200**
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs…",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "rt_N4ka…",
  "refresh_expires_in": 2592000
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 401 | `invalid_refresh_token` | unknown, expired or revoked refresh token |
| 403 | `user_inactive` | the user was deactivated |

---

<a id="post-auth-logout"></a>
## POST /auth/logout
Log out this device by revoking its refresh token. The access token keeps working until it expires (at most 15 minutes).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Request**
```json
{
  "refresh_token": "rt_N4ka…"
}
```

**Response 204** (no body). Also 204 if the token was already revoked.

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | the refresh token belongs to another user |

---

<a id="post-auth-password"></a>
## POST /auth/password
Change the password. All other devices are logged out (their refresh tokens are revoked). This device stays logged in.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Request**
```json
{
  "old_password": "correct horse battery",
  "new_password": "a much longer passphrase",
  "refresh_token": "rt_N4ka…"
}
```
- `refresh_token`: this device's token, the one that is not revoked
- `new_password`: same rules as register, and different from the old one

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | new password too weak or the same as the old one |
| 400 | `wrong_password` | `old_password` is wrong |

---

<a id="get-me"></a>
## GET /me
My profile and my teams with my role in each.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Response 200**
```json
{
  "id": "u7…",
  "email": "ana@example.com",
  "display_name": "Ana Pop",
  "avatar_file_id": "f2…",
  "timezone": "Europe/Bucharest",
  "date_joined": "2026-10-01T09:12:00Z",
  "teams": [
    { "team_id": "t1…", "name": "Backend", "icon_file_id": null, "role": "owner" }
  ]
}
```

---

<a id="put-me"></a>
## PUT /me
Edit my profile. `PUT` replaces all editable fields, so send all of them.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Request**
```json
{
  "display_name": "Ana P.",
  "timezone": "Europe/Bucharest",
  "avatar_file_id": "f2…"
}
```
- `display_name`: 1–60 chars
- `timezone`: an IANA name, for example `Europe/Bucharest`
- `avatar_file_id`: `null` removes the avatar. Otherwise a `ready` file with purpose `avatar`, uploaded by me

**Response 200**: the same body as [GET /me](#get-me)

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | display_name empty or too long, unknown timezone |
| 400 | `invalid_file` | the avatar file is not mine, not `ready` or not an `avatar` |

---

# Teams and team members

<a id="get-teams"></a>
## GET /teams
My teams.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Response 200**
```json
{
  "teams": [
    {
      "id": "t1…",
      "name": "Backend",
      "icon_file_id": null,
      "role": "owner",
      "member_count": 12,
      "created_at": "2026-10-01T09:15:00Z"
    }
  ]
}
```

---

<a id="post-teams"></a>
## POST /teams
Create a team. I become its owner, and a `general` channel is created that every member joins.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user, max 10 teams created per user

**Request**
```json
{
  "name": "Backend"
}
```
- `name`: 1–80 chars. Team names don't have to be unique

**Response 201**
```json
{
  "id": "t1…",
  "name": "Backend",
  "icon_file_id": null,
  "role": "owner",
  "member_count": 1,
  "general_channel_id": "c0…",
  "created_at": "2026-10-06T12:00:00Z"
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | name empty or too long |
| 409 | `team_limit_reached` | I already created 10 teams |

---

<a id="get-teams-team_id"></a>
## GET /teams/{team_id}
One team.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Response 200**
```json
{
  "id": "t1…",
  "name": "Backend",
  "icon_file_id": "f9…",
  "my_role": "admin",
  "member_count": 12,
  "created_by": "u7…",
  "created_at": "2026-10-01T09:15:00Z"
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `not_a_team_member` | I am not in the team |
| 404 | `team_not_found` | the team doesn't exist or was deleted |

---

<a id="put-teams-team_id"></a>
## PUT /teams/{team_id}
Edit the team's name and icon.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** team owner or admin

**Request**
```json
{
  "name": "Backend team",
  "icon_file_id": "f9…"
}
```
- `icon_file_id`: `null` removes the icon. Otherwise a `ready` file with purpose `team_icon` and this `team_id`

**Response 200**: the same body as [GET /teams/{team_id}](#get-teams-team_id)

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `invalid_file` | the icon is not `ready`, not a `team_icon` or of another team |
| 403 | `forbidden` | I am a member, not an owner or admin |
| 404 | `team_not_found` | the team doesn't exist or was deleted |

---

<a id="delete-teams-team_id"></a>
## DELETE /teams/{team_id}
Delete the team. It is a soft delete: the team disappears for everyone, and a cleanup job removes its files later. Publishes `team.deleted`.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** team owner

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | I am not an owner |
| 404 | `team_not_found` | the team doesn't exist or was already deleted |

---

<a id="post-teams-team_id-leave"></a>
## POST /teams/{team_id}/leave
Leave the team. I am also removed from all its channels. Publishes `team.member.changed` (`left`).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `not_a_team_member` | I am not in the team |
| 409 | `last_owner` | I am the only owner; make someone else owner first, or delete the team |

---

<a id="get-teams-team_id-members"></a>
## GET /teams/{team_id}/members
The team directory. The web app also uses it to show names and avatars in messages.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Query**
- `q`: optional, matches the start of display name words, case-insensitive
- `limit`, `cursor`: see [Pagination](#pagination)
- `user_ids`: optional, comma-separated, max 100. Returns exactly these members, without pagination. The web app uses it to load names and avatars for the authors of messages it shows

**Sort:** display name (A to Z), then `user_id`

**Response 200**
```json
{
  "members": [
    {
      "user_id": "u3…",
      "display_name": "Mihai Ionescu",
      "avatar_file_id": null,
      "role": "member",
      "is_active": true,
      "joined_at": "2026-10-02T08:00:00Z"
    }
  ],
  "next_cursor": "eyJrIjpbIm1paGFpIiwidTMiXX0"
}
```
- `next_cursor` is always `null` when `user_ids` is used
- Users in `user_ids` who are not in the team are left out (for example people who left; their messages show "former member")

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `invalid_cursor` | see [Pagination](#pagination) |
| 400 | `validation_error` | more than 100 `user_ids`, or `user_ids` together with `cursor` |
| 403 | `not_a_team_member` | I am not in the team |
| 404 | `team_not_found` | the team doesn't exist or was deleted |

---

<a id="put-teams-team_id-members-user_id"></a>
## PUT /teams/{team_id}/members/{user_id}
Change a member's role. Publishes `team.member.changed` (`role_changed`).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** team owner or admin. Only an owner can make someone owner or change an owner's role.

**Request**
```json
{
  "role": "admin"
}
```
- `role`: `owner`, `admin` or `member`

**Response 200**
```json
{
  "user_id": "u3…",
  "team_id": "t1…",
  "role": "admin"
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | I am a member, or an admin trying to make an owner or change an owner |
| 404 | `member_not_found` | the user is not in the team |
| 409 | `last_owner` | the change would leave the team without an owner |

---

<a id="delete-teams-team_id-members-user_id"></a>
## DELETE /teams/{team_id}/members/{user_id}
Remove someone from the team. They are also removed from all the team's channels. Publishes `team.member.changed` (`removed`).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** team owner or admin. Admins can't remove owners. To remove yourself use [leave](#post-teams-team_id-leave).

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | I am a member, or an admin removing an owner |
| 404 | `member_not_found` | the user is not in the team |
| 409 | `use_leave` | the user is me |

---

# Invites

<a id="post-teams-team_id-invites"></a>
## POST /teams/{team_id}/invites
Create an invite link, like Discord. Anyone who has the link can join the team as `member`.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team. Max 100 active invites per team.

**Request**
```json
{
  "max_age": 604800,
  "max_uses": 0
}
```
- `max_age`: seconds. One of `1800`, `3600`, `21600`, `43200`, `86400`, `604800` (default) or `0` = never expires
- `max_uses`: one of `1`, `5`, `10`, `25`, `50`, `100` or `0` = unlimited (default)

**Response 201**
```json
{
  "id": "i4…",
  "code": "aB3xK9pQ",
  "url": "https://chatty.app/invite/aB3xK9pQ",
  "team_id": "t1…",
  "created_by": "u7…",
  "max_uses": 0,
  "uses": 0,
  "expires_at": "2026-10-13T12:00:00Z",
  "created_at": "2026-10-06T12:00:00Z"
}
```
- `expires_at` is `null` when `max_age` is `0`

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | `max_age` or `max_uses` is not one of the allowed values |
| 403 | `not_a_team_member` | I am not in the team |
| 409 | `invite_limit_reached` | the team already has 100 active invites |

---

<a id="get-teams-team_id-invites"></a>
## GET /teams/{team_id}/invites
Active invites (not expired, not revoked, not used up).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team see their own invites. Owners and admins see all invites of the team.

**Response 200**
```json
{
  "invites": [
    {
      "id": "i4…",
      "code": "aB3xK9pQ",
      "url": "https://chatty.app/invite/aB3xK9pQ",
      "created_by": "u7…",
      "max_uses": 0,
      "uses": 3,
      "expires_at": "2026-10-13T12:00:00Z",
      "created_at": "2026-10-06T12:00:00Z"
    }
  ]
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `not_a_team_member` | I am not in the team |

---

<a id="delete-invites-invite_id"></a>
## DELETE /invites/{invite_id}
Revoke an invite. The link stops working right away.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the creator of the invite, team owner or admin

**Response 204** (no body). Also 204 if it was already revoked.

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | I am not the creator, an owner or an admin |
| 404 | `invite_not_found` | the invite doesn't exist |

---

<a id="get-invites-invite_code"></a>
## GET /invites/{invite_code}
The invite page: which team and whether the link still works. Shown before login, so it also returns a short-lived icon URL.

**Auth:** none

**Who:** anyone, no token. Max 30 per minute per IP (`invite_lookup:{ip}`), so codes can't be guessed by trying many.

**Response 200**
```json
{
  "code": "aB3xK9pQ",
  "valid": true,
  "reason": null,
  "team": {
    "name": "Backend",
    "icon_url": "https://minio…/team-icons/t1…/f9…?X-Amz-Signature=…",
    "member_count": 12
  },
  "expires_at": "2026-10-13T12:00:00Z"
}
```
- `valid: false` with `reason`: `expired`, `revoked` or `used_up`
- `icon_url` is valid 5 minutes, `null` without an icon

**Errors**
| Status | code | When |
|---|---|---|
| 404 | `invite_not_found` | no invite with this code, or its team was deleted |
| 429 | `rate_limited` | more than 30 lookups per minute from this IP |

---

<a id="post-invites-invite_code-join"></a>
## POST /invites/{invite_code}/join
Join the team with an invite. I become a `member` and join the default channels. `uses` goes up by 1 in the same transaction, so a link can't be used more times than allowed. Publishes `team.member.changed` (`joined`) and `membership.changed` (`added`).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user

**Request**: no body

**Response 201** (200 if I was already in the team; nothing changes and `uses` doesn't go up)
```json
{
  "team_id": "t1…",
  "name": "Backend",
  "role": "member",
  "already_member": false,
  "channel_ids": ["c0…"]
}
```
- `channel_ids`: the default channels I joined

**Errors**
| Status | code | When |
|---|---|---|
| 404 | `invite_not_found` | no invite with this code, or its team was deleted |
| 410 | `invite_invalid` | the invite expired, was revoked or is used up; `message` says which |

---

# Channels and DMs

<a id="get-teams-team_id-channels"></a>
## GET /teams/{team_id}/channels
My channels and DMs in a team (the sidebar). Hidden DMs are included with `hidden: true`, so the web app can show them again when they have unread messages. Unread counts come from chatty-chat.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Response 200**
```json
{
  "channels": [
    {
      "id": "c0…",
      "kind": "public",
      "name": "general",
      "topic": "Everything",
      "is_default": true,
      "archived": false,
      "dm_member_ids": null,
      "my": { "role": "member", "notify_level": "mentions", "muted": false, "hidden": false }
    },
    {
      "id": "c5…",
      "kind": "dm",
      "name": null,
      "topic": null,
      "is_default": false,
      "archived": false,
      "dm_member_ids": ["u7…", "u3…"],
      "my": { "role": "member", "notify_level": "all", "muted": false, "hidden": false }
    }
  ]
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `not_a_team_member` | I am not in the team |
| 404 | `team_not_found` | the team doesn't exist or was deleted |

---

<a id="get-teams-team_id-channels-browse"></a>
## GET /teams/{team_id}/channels/browse
Public channels of the team that I haven't joined.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Query**
- `q`: optional, matches the channel name
- `limit`, `cursor`: see [Pagination](#pagination)

**Sort:** channel name (A to Z)

**Response 200**
```json
{
  "channels": [
    { "id": "c8…", "name": "releases", "topic": "Release notes", "member_count": 7, "archived": false }
  ],
  "next_cursor": null
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `invalid_cursor` | see [Pagination](#pagination) |
| 403 | `not_a_team_member` | I am not in the team |

---

<a id="post-teams-team_id-channels"></a>
## POST /teams/{team_id}/channels
Create a public or private channel. I become its owner and only member. Publishes `membership.changed` (`added`).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team

**Request**
```json
{
  "name": "releases",
  "kind": "public",
  "topic": "Release notes"
}
```
- `name`: 1–80 chars, lowercase letters, digits, `-` and `_`. Unique in the team
- `kind`: `public` or `private` (DMs are created with [POST /teams/{team_id}/dms](#post-teams-team_id-dms))
- `topic`: optional, max 250 chars

**Response 201**
```json
{
  "id": "c8…",
  "team_id": "t1…",
  "kind": "public",
  "name": "releases",
  "topic": "Release notes",
  "is_default": false,
  "archived": false,
  "created_by": "u7…",
  "created_at": "2026-10-06T12:00:00Z"
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | bad name, kind is `dm`, topic too long |
| 403 | `not_a_team_member` | I am not in the team |
| 409 | `channel_name_taken` | another channel in the team has this name |

---

<a id="post-teams-team_id-dms"></a>
## POST /teams/{team_id}/dms
Open a DM with 1 to 7 other people (max 8 with me). If a DM with exactly these people exists in the team, it is returned. Publishes `membership.changed` (`added`) for each member when a DM is created.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team; everyone in `user_ids` must be in the team too

**Request**
```json
{
  "user_ids": ["u3…"]
}
```
- `user_ids`: 1–7 IDs, without me. Duplicates are ignored

**Response 201** (200 if the DM already existed)
```json
{
  "id": "c5…",
  "team_id": "t1…",
  "kind": "dm",
  "member_ids": ["u7…", "u3…"],
  "created_at": "2026-10-06T12:00:00Z"
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | 0 or more than 7 other people, or only me |
| 400 | `user_not_in_team` | someone in `user_ids` is not in the team |
| 403 | `not_a_team_member` | I am not in the team |

---

<a id="get-channels-channel_id"></a>
## GET /channels/{channel_id}
One channel.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel members; for public channels also anyone in the team

**Response 200**
```json
{
  "id": "c8…",
  "team_id": "t1…",
  "kind": "public",
  "name": "releases",
  "topic": "Release notes",
  "is_default": false,
  "archived": false,
  "member_count": 7,
  "created_by": "u7…",
  "created_at": "2026-10-06T12:00:00Z",
  "my": { "role": "owner", "notify_level": "mentions", "muted": false, "hidden": false }
}
```
- `my` is `null` when I can read the channel but haven't joined it

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `cannot_read_channel` | private channel or DM I am not in, or I am not in the team |
| 404 | `channel_not_found` | the channel doesn't exist or its team was deleted |

---

<a id="put-channels-channel_id"></a>
## PUT /channels/{channel_id}
Rename a channel or change its topic. Publishes `channel.updated`.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel owner, team owner or admin. Public and private channels only.

**Request**
```json
{
  "name": "release-notes",
  "topic": "Everything that ships"
}
```
- same rules as [POST /teams/{team_id}/channels](#post-teams-team_id-channels)

**Response 200**: the same body as [GET /channels/{channel_id}](#get-channels-channel_id)

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `not_allowed_for_dm` | the channel is a DM |
| 403 | `forbidden` | I am not the channel owner, a team owner or an admin |
| 404 | `channel_not_found` | the channel doesn't exist |
| 409 | `channel_name_taken` | another channel in the team has this name |
| 409 | `channel_archived` | the channel is archived |

---

<a id="post-channels-channel_id-archive"></a>
## POST /channels/{channel_id}/archive
Archive a channel. It becomes read-only for everyone. Publishes `channel.updated` with `archived: true`.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel owner, team owner or admin. Public and private channels only. The `general` channel can't be archived.

**Request**: no body

**Response 200**: the same body as [GET /channels/{channel_id}](#get-channels-channel_id), with `archived: true`. Also 200 if it was already archived.

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `not_allowed_for_dm` | the channel is a DM |
| 400 | `cannot_archive_default` | the channel is `general` |
| 403 | `forbidden` | I am not the channel owner, a team owner or an admin |
| 404 | `channel_not_found` | the channel doesn't exist |

---

<a id="post-channels-channel_id-join"></a>
## POST /channels/{channel_id}/join
Join a public channel. Publishes `membership.changed` (`added`).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** members of the team. Public channels only.

**Request**: no body

**Response 200**
```json
{
  "channel_id": "c8…",
  "role": "member",
  "notify_level": "mentions",
  "muted": false,
  "hidden": false
}
```
- Also 200 if I was already a member

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `not_a_team_member` | I am not in the team |
| 403 | `cannot_join_private` | the channel is private or a DM |
| 404 | `channel_not_found` | the channel doesn't exist |
| 409 | `channel_archived` | the channel is archived |

---

<a id="post-channels-channel_id-leave"></a>
## POST /channels/{channel_id}/leave
Leave a channel. Publishes `membership.changed` (`removed`). If I was the last owner of a private channel, the member who joined first becomes the owner.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel members. Public and private channels only; DMs can't be left, only hidden with [PUT /channels/{channel_id}/me](#put-channels-channel_id-me).

**Request**: no body

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `cannot_leave_dm` | the channel is a DM |
| 403 | `not_a_member` | I am not in the channel |
| 404 | `channel_not_found` | the channel doesn't exist |

---

<a id="get-channels-channel_id-members"></a>
## GET /channels/{channel_id}/members
Members of a channel.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel members; for public channels also anyone in the team

**Query**
- `limit`, `cursor`: see [Pagination](#pagination)

**Sort:** `joined_at` (oldest first), then `user_id`

**Response 200**
```json
{
  "members": [
    { "user_id": "u7…", "role": "owner", "joined_at": "2026-10-06T12:00:00Z" },
    { "user_id": "u3…", "role": "member", "joined_at": "2026-10-06T12:05:00Z" }
  ],
  "next_cursor": "eyJrIjpbIjIwMjYtMTAtMDZUMTI6MDU6MDBaIiwidTMiXX0"
}
```
- Names and avatars come from [GET /teams/{team_id}/members](#get-teams-team_id-members) with `user_ids`

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `invalid_cursor` | see [Pagination](#pagination) |
| 403 | `cannot_read_channel` | private channel or DM I am not in |
| 404 | `channel_not_found` | the channel doesn't exist |

---

<a id="post-channels-channel_id-members"></a>
## POST /channels/{channel_id}/members
Add people to a channel. People who are already members are skipped. Publishes `membership.changed` (`added`) for each new member.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel members. Public and private channels only. The people must be in the team.

**Request**
```json
{
  "user_ids": ["u3…", "u5…"]
}
```
- `user_ids`: 1–50 IDs

**Response 200**
```json
{
  "added": ["u5…"],
  "already_members": ["u3…"]
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `not_allowed_for_dm` | the channel is a DM |
| 400 | `user_not_in_team` | someone in `user_ids` is not in the team |
| 403 | `not_a_member` | I am not in the channel |
| 404 | `channel_not_found` | the channel doesn't exist |
| 409 | `channel_archived` | the channel is archived |

---

<a id="delete-channels-channel_id-members-user_id"></a>
## DELETE /channels/{channel_id}/members/{user_id}
Remove someone from a channel. Publishes `membership.changed` (`removed`); chatty-chat stops sending them the channel's events right away.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel owner, team owner or admin. Public and private channels only. To remove yourself use [leave](#post-channels-channel_id-leave).

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `not_allowed_for_dm` | the channel is a DM |
| 403 | `forbidden` | I am not the channel owner, a team owner or an admin |
| 404 | `member_not_found` | the user is not in the channel |
| 409 | `use_leave` | the user is me |

---

<a id="put-channels-channel_id-me"></a>
## PUT /channels/{channel_id}/me
My settings for a channel. Publishes `membership.changed` (`settings`), so chatty-chat uses the new notification settings.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** channel members

**Request**
```json
{
  "notify_level": "mentions",
  "muted": false,
  "hidden": false
}
```
- `notify_level`: `all`, `mentions` or `none`
- `hidden`: only for DMs. The web app sends `hidden: false` when a hidden DM gets unread messages (D-04)

**Response 200**
```json
{
  "channel_id": "c5…",
  "role": "member",
  "notify_level": "mentions",
  "muted": false,
  "hidden": false
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | unknown `notify_level`, or `hidden: true` for a channel that is not a DM |
| 403 | `not_a_member` | I am not in the channel |
| 404 | `channel_not_found` | the channel doesn't exist |

---

# Files

Uploads take 3 steps: [POST /files](#post-files) → [PUT to the upload URL](#put-presigned-upload-url) → [POST /files/{file_id}/confirm](#post-files-file_id-confirm). Only `ready` files can be used.

<a id="post-files"></a>
## POST /files
Step 1: ask for an upload. Creates a `pending` file and returns a presigned MinIO upload URL.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** logged-in user. For `team_icon` and `attachment`, members of `team_id`.

**Request**
```json
{
  "purpose": "attachment",
  "team_id": "t1…",
  "filename": "report.pdf",
  "mime": "application/pdf",
  "size": 482133
}
```
- `purpose`: `avatar`, `team_icon` or `attachment`
- `team_id`: `null` for `avatar`, required for `team_icon` and `attachment`
- `avatar` and `team_icon`: `image/png`, `image/jpeg`, `image/webp` or `image/gif`, max 2 MB
- `attachment`: any type, max 25 MB
- `filename`: 1–255 chars

**Response 201**
```json
{
  "file_id": "f6…",
  "upload_url": "https://minio…/attachments/t1…/f6…?X-Amz-Signature=…",
  "upload_method": "PUT",
  "upload_headers": { "Content-Type": "application/pdf" },
  "expires_at": "2026-10-06T12:10:00Z"
}
```
- The URL is valid 10 minutes (`upload_expires_at`)

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | unknown purpose, missing or extra `team_id`, bad filename |
| 400 | `file_too_large` | over 2 MB for images, over 25 MB for attachments |
| 400 | `type_not_allowed` | not an image for `avatar` or `team_icon` |
| 403 | `not_a_team_member` | I am not in `team_id` |

---

<a id="put-presigned-upload-url"></a>
## PUT presigned upload URL
Step 2: the browser uploads the file straight to MinIO. This request does not go to chatty-core and has no `Authorization` header.

**Auth:** none (the signature in the URL is the authorization)

**Who:** whoever has the URL from step 1, until it expires

**Request**: the raw file bytes, with the headers from `upload_headers`

**Response 200** from MinIO (no body)

**Errors**: MinIO returns `403` if the URL expired or the headers don't match.

---

<a id="post-files-file_id-confirm"></a>
## POST /files/{file_id}/confirm
Step 3: check the uploaded file in MinIO and mark it `ready`. If the object is missing, or its size or type doesn't match step 1, chatty-core deletes it and returns an error.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the owner of the file

**Request**: no body

**Response 200** (also 200 if it was already `ready`)
```json
{
  "id": "f6…",
  "purpose": "attachment",
  "team_id": "t1…",
  "filename": "report.pdf",
  "mime": "application/pdf",
  "size": 482133,
  "status": "ready",
  "created_at": "2026-10-06T12:00:00Z"
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `upload_missing` | nothing was uploaded to MinIO |
| 400 | `upload_mismatch` | the size or type is different from step 1; the object was deleted |
| 403 | `forbidden` | the file is not mine |
| 404 | `file_not_found` | the file doesn't exist |
| 410 | `upload_expired` | the 10 minutes passed; start again with step 1 |

---

<a id="get-files-file_id"></a>
## GET /files/{file_id}
Download an avatar or a team icon. Attachments are downloaded through chatty-chat (`GET /attachments/{file_id}`, D-02).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** avatars: any logged-in user. Team icons: members of the team.

**Response 302**: `Location` header with a presigned GET URL, valid 5 minutes

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `use_chatty_chat` | the file is an attachment |
| 403 | `not_a_team_member` | a team icon of a team I am not in |
| 404 | `file_not_found` | the file doesn't exist, is not `ready` or was deleted |

---

<a id="delete-files-file_id"></a>
## DELETE /files/{file_id}
Delete my own file before it is used in a message. Files in messages are removed when the message is deleted (`detach`).

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the owner of the file

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | the file is not mine |
| 404 | `file_not_found` | the file doesn't exist or was already deleted |
| 409 | `file_attached` | the file is in a message (`attached_at` is set) |

---

# Push (post-MVP)

<a id="post-push-subscriptions"></a>
## POST /push/subscriptions
Register this browser for Web Push. If the same `endpoint` exists, it is moved to the current user.

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

**Response 201** (200 if the endpoint was already registered)
```json
{
  "id": "p1…",
  "created_at": "2026-10-06T12:00:00Z"
}
```

**Errors**
| Status | code | When |
|---|---|---|
| 400 | `validation_error` | endpoint is not an https URL, keys missing |

---

<a id="delete-push-subscriptions-subscription_id"></a>
## DELETE /push/subscriptions/{subscription_id}
Stop push notifications for this browser.

**Auth:** `Authorization: Bearer <JWT>`

**Who:** the owner of the subscription

**Response 204** (no body)

**Errors**
| Status | code | When |
|---|---|---|
| 403 | `forbidden` | the subscription is not mine |
| 404 | `subscription_not_found` | the subscription doesn't exist |

---

<a id="events"></a>
# Events (Redis)

chatty-core publishes 5 events on Redis pub/sub, only after its transaction commits. The envelope and payloads are agreed in D-06; the full schemas belong in `docs/core-events.md` (CHAT-138).

```json
{
  "type": "membership.changed",
  "occurred_at": "2026-10-06T12:00:00Z",
  "data": { "user_id": "u3…", "channel_id": "c8…", "team_id": "t1…", "action": "added" }
}
```

| Event | Published by |
|---|---|
| `membership.changed` | create channel, join, leave, add or remove members, open a DM, join a team, `PUT /channels/{channel_id}/me` |
| `team.member.changed` | join with an invite, leave a team, remove a member, change a role |
| `channel.updated` | rename, change topic, archive |
| `team.deleted` | delete a team |
| `user.deactivated` | a platform admin deactivates a user in Django admin |
