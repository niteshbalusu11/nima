# Admin invites and token sign-in

Plan for the next phase. Keep the existing Go API, SQLite volume, SwiftUI app, and persistent sessions.

## Permission model

Proposed rule: only the server CLI can create admin invites. Signed-in admins can generate invites for regular members in the app. Members cannot generate invites. Admin status grants invite creation only; it does not grant access to other people's profiles or media.

| Actor | Create member invite | Create admin invite |
| --- | --- | --- |
| Server CLI | Yes | Yes |
| Signed-in admin | Yes | No |
| Member or signed-out user | No | No |

Invites remain single-use and expire after 24 hours. Each new-user invite creates a separate account. Sessions have no expiry and no automatic sign-out. Invite creation and redemption require an internet connection; an already generated QR can still be displayed offline.

## User experience

**Sign-in:** one small screen with an invite-token field, Paste, Continue, and Scan QR. Accept the raw token or the existing `uploadvideo:invite:` QR text, trimming surrounding whitespace. Scan opens a camera sheet; request camera permission at that point. Paste sign-in must work without camera access. Both methods call the same enrollment function and lead directly to the camera after Keychain storage succeeds. Admins and members use the same screen; the server determines their role.

Disable repeat submissions while joining. Show short errors for an invalid/used/expired invite or an unavailable network. Returning users open directly to the camera, including when offline.

**Admin invites:** add an Invite person row to the existing Profile sheet for admins. Opening it shows a Create invite button. A successful request displays a large QR with Copy token and New invite. Disable generation while the request is pending. Keep the current QR until a new request succeeds, and display its expiry. Use a new single-use invite for each person; no polling, invite history, or admin dashboard is needed for this phase.

The displayed token is the newly generated invitation, never the admin's session credential. Keep the raw invite in the screen's state; the server stores only its hash. Copying is user-initiated. Dismissing the screen does not invalidate an invite already handed out.

## Server and CLI

1. Add `role` (`member` or `admin`, default `member`) to accounts and invites, constrained in SQLite. Add nullable `created_by` to invites to record the issuing admin; CLI-created invites have no issuer account.
2. Extend the CLI with `uploadvideo invite --admin --out admin.png --text-out admin.txt`. The existing command without `--admin` creates a member invite. Replacement invites using `--account` retain that account's role; reject combining `--admin` with `--account`.
3. During enrollment, consume the invite and create the account with its stored role in the existing transaction. Clients cannot choose a role during enrollment. Return `role` with `token` and `account_id`, and include it in `GET /me`. `PATCH /me` continues to accept only the existing contact fields.
4. Add authenticated `POST /invites`. Check the caller's current database role on every request. Return 401 without a valid session and 403 for a member. Always create a fresh member invite; do not accept role, account ID, or expiry overrides from the app. Return the raw invite token and its expiration with the existing no-store response headers. Do not log tokens.
5. Reuse the existing random-token generation, hashing, single-use consumption, and enrollment throttling. Rate-limit invite generation per admin without introducing a total invite allowance.

The iOS role controls visibility only. The server enforces permission even when someone calls the API directly or modifies the app. This follows [OWASP's server-side, per-request authorization guidance](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html).

## Implementation order and verification

1. **Server roles, CLI, and endpoint.** Verify CLI admin enrollment, member enrollment, anonymous/member rejection, and admin invite creation. Attempt to request admin privileges through invite creation, enrollment, and profile edits; all must fail. Confirm an admin-created invite enrolls a member with an independent account and no access to the inviter's media.
2. **Shared sign-in screen.** Add `AuthView` and store the returned role with the Keychain session; refresh role from `/me` when online. Move scanner activation out of the automatic signed-out camera lifecycle. Verify raw/prefixed pasted tokens, QR scanning, denied camera permission, double taps, invalid/expired/reused tokens, and persistent sign-in after relaunch.
3. **Admin invite screen.** Add `InviteView` and the profile entry. Verify QR contents match the copied invite, new invite generation works, offline errors preserve the current QR, and members never see the entry. Camera capture and uploads keep their current flow.
4. **End-to-end and deployment.** Verify concurrent redemption creates only one account, session persistence still works, and the live video/photo tests still pass. Check both iOS builds and the admin-to-member QR flow on two phones. Apply the prerelease schema change to the local and Fly test databases before deploying the API. If that schema update fails, recreate the disposable SQLite database through the CLI as requested; issue fresh bootstrap invites after a reset. Keep compatibility fields and migration frameworks out of this version. Push tested server changes to `master` for CI deployment, then create the first admin invite through the Fly CLI.

Make small commits on `master`: server permissions; sign-in UI; admin invite UI; integration checks and operating instructions.

SwiftUI provides a native [PasteButton](https://developer.apple.com/documentation/swiftui/pastebutton); use the existing AVFoundation QR scanner and native QR rendering without another service or SDK.
