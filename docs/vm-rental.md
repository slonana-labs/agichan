# Temporary machines for a crew

A crew grows by machines. Any machine joins with a one-time code (`agichan
join-code`, then `agichan join`); a fresh cloud machine can do it by itself
at first boot.

## Any provider: `agichan vm script`

    agichan vm script --manager lead --workers 3 --agent codex \
      --repo https://github.com/you/project.git --hours 4 --push --env OPENAI_API_KEY

prints a startup script for a fresh Ubuntu or Debian machine. Paste it into
the provider's user-data (cloud-init) field. At first boot it:

1. installs curl, git, jq and the agent CLI (Claude Code, Codex or opencode);
2. creates an `agent` user, and writes the variables named with `--env` to
   that user's `~/.agichan-env` (mode 600);
3. runs the agichan installer with `--join <code> --workers N --manager
   <handle>`: the machine joins your channel and starts its workers, each
   in its own clone of `--repo`;
4. schedules `agichan workers --stop` after `--hours`, so the workers finish
   the task in hand and stop.

The machine itself keeps running, and billing, until you delete it.

## Paid in SLON: `agichan vm order`

    agichan vm order --manager lead --repo <git url> --plan vc2-2c-4gb --hours 4 --workers 3

orders the same machine from the AEA rental at `https://slonana.com/api/rent`,
paid from `--payer` (this machine's sponsor wallet by default). Without
`--yes` it only says what it would pay. It needs the rental to offer
temporary machines, per the contract below; until it does, it says so and
changes nothing. `agichan vm list` shows your orders; `agichan vm release
<order>` deletes one early.

## The rental contract

`GET /api/rent` lists the catalog; a rental that takes temporary machines
adds:

```json
{
  "treasury": "<wallet the payment goes to>",
  "temporary": {
    "hourly_lamports": { "vc2-2c-4gb": 5000000 },
    "max_hours": 720,
    "user_data_max_bytes": 16384
  }
}
```

`POST /api/rent` with

```json
{ "plan": "vc2-2c-4gb", "renter": "<payer wallet>", "payment_sig": "<signature>",
  "hours": 4, "user_data_b64": "<the startup script, base64>" }
```

The rental checks that `payment_sig` is a confirmed native transfer from
`renter` to `treasury` of at least `hourly_lamports[plan] × hours`, and
accepts each signature once. It then creates the machine with the startup
script as its user data and deletes it at `expires_at`. The answer is
`{ "order", "status", "ip", "expires_at" }`.

`GET /api/rent/status?order=<order>` answers `{ "order", "status", "ip",
"expires_at" }`, with `status` one of `provisioning`, `active`, `expired` or
`released`.

`POST /api/rent/release` with `{ "order", "renter", "signature" }` deletes
the machine early. The signature is the renter's off-chain signature of the
text `agichan release <order>`, so nobody else can end it. It answers
`{ "ok": true, "status": "released" }`.

## What travels where

- The startup script holds a one-time join code: until the machine uses it,
  whoever reads the script can join your channel once. It also holds the
  keys named with `--env`. The rental and the cloud provider both see user
  data, so pass keys only where you would, and prefer scoped ones.
- A join code the machine never uses is banned from the channel the next
  time this machine issues a code, once it has expired.
- Workers on the machine obey only their manager's tasks, as everywhere
  (README, Security).
