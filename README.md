# oci-hunt

Hunts an Oracle Cloud **Always Free** instance until one lands, then stops.

`VM.Standard.A1.Flex` — 4 Arm cores and 24 GB RAM, free forever — is the best
offer in cloud computing and therefore permanently out of stock. Every launch
comes back `Out of host capacity`. The only way through is to keep asking and
be there the moment somebody releases a machine.

That is all this does, reliably, unattended, for as long as it takes.

```sh
./oci-hunt.sh discover   # print the OCIDs you need
./oci-hunt.sh check      # verify the config, make no attempts
./oci-hunt.sh run        # hunt until it lands
```

## What stops it

Only three things:

| | |
|---|---|
| **It lands an instance** | the point of the exercise — it reports the IP and exits |
| **One already exists** | checked before every run, so a restart is harmless |
| **Continuing cannot work** | quota full, or a credential or OCID is wrong |

Everything else is expected on a long hunt and retried indefinitely: capacity
misses, HTTP 429, 5xx, connection resets, timeouts, and anything it does not
recognise. An unknown error is treated as transient on purpose — abandoning a
hunt because of an unfamiliar string is worse than one wasted attempt.

Auth failures sit in between. They are usually a stale token that clears
itself, so it retries `AUTH_RETRIES` times (default 10) before concluding the
credentials are genuinely broken.

## Where to run it

**It needs a machine that is always on.** GitHub Actions cannot do this: a job
is capped at 6 hours, scheduled runs are dropped under load, and schedules are
disabled after 60 days of repository inactivity.

Hosts that work:

- **Google Cloud always-free `e2-micro`** — free forever, always on, in
  `us-west1`, `us-central1` or `us-east1`. 1 GB is useless for real workloads
  but ample for a bash loop. This is the free answer.
- **A Raspberry Pi or an old laptop** — equally good, nothing to sign up for.
- **Any cheap VPS** — though if you are paying for one, note it could just be
  the server you wanted.

Install it as a systemd user service and it survives logout, reboots and
crashes. See the header of `oci-hunt.service`.

## Setup

```sh
git clone https://github.com/s-rakim/instance2 ~/oci-hunt
# install the OCI CLI, then:
oci setup config

mkdir -p ~/.config
cp ~/oci-hunt/oci-hunt.env.example ~/.config/oci-hunt.env
chmod 600 ~/.config/oci-hunt.env       # it holds your Discord webhook
$EDITOR ~/.config/oci-hunt.env

~/oci-hunt/oci-hunt.sh discover        # fills in the OCIDs
~/oci-hunt/oci-hunt.sh check           # confirms it before you walk away
```

`check` verifies your credentials, lists your availability domains, and says
whether a run would hunt or exit. Run it before leaving anything unattended.

Then install the service — the commands are in the header of
`oci-hunt.service`.

## Notifications

Set `DISCORD_WEBHOOK` and you get a message when it lands, when it stops for a
reason you would want to know about, and a heartbeat every
`HEARTBEAT_HOURS` (default 12) so silence never means "it died three days ago".

## Shape sizing

Default is **1 OCPU / 6 GB**, not the full 4/24. A smaller ask lands far more
often, four of them fit inside the same free allowance, and an `A1.Flex`
instance can be resized afterwards. Take the small one and grow it.

## On how hard to push

Rate limiting is not the real hazard. Oracle has flagged accounts and zeroed
their service limits based on *cumulative* volume, at intervals as gentle as
ten minutes sustained over months —
[oracle-freetier-instance-creation#75](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation/issues/75).
Running this 24/7 at the default is roughly 160 attempts a day, which is above
that case. `oci-hunt.env.example` lists gentler settings and what each costs
you in coverage.

The lever that actually helps is **upgrading the account to Pay As You Go**.
It reportedly improves capacity access, exempts you from idle reclamation, and
removes the trial expiry — and Always Free resources stay free on PAYG. If you
are going to change one thing, change that rather than the sleep interval.

Oracle publishes no policy on any of this. Decide knowing what is documented
and what is only widely reported.

## Requirements

The OCI CLI (authenticated), bash 4+, curl, and python3 — which you already
have, because the OCI CLI is written in it.

## Licence

MIT.
