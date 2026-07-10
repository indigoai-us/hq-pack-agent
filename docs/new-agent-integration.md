# Integrating hq-pack-agent into `/new-agent`

A freshly minted agent should self-install `hq-pack-agent` on its first session,
so agent-only behavior is present from the start. Two things make this the right
integration point in `/new-agent`:

1. It happens **after** identity + membership + vault + secret grants (Layers
   1–4), so the private-repo deploy token (`HQ_PACK_AGENT_DEPLOY_TOKEN`) resolves
   from the agent's vault when bootstrap runs.
2. It runs **on the agent's runtime** (Layer 5), which is exactly where
   `/new-agent`'s Step 5 bootstrap block already runs.

## The change

`/new-agent` Step 5 ("Generate the runtime bootstrap block") emits a copy-paste
block that runs on the agent runtime. Append the package bootstrap to that block:

```bash
# --- HQ agent bootstrap: {agent} @ {co} ---
hq login                      # or hq auth status if already authenticated
# /accept <token>             # only if membership is still pending
hq team-sync                  # pulls companies/{co}/ into this HQ
hq secrets list --company {co}   # must show the granted keys

# --- Agent behavior package (hq-pack-agent) ---
# Self-installs agent-only hooks/policies and arms self-update. Provision mode
# drops the durable agent-identity marker so the package recognizes this HQ as an
# agent's even without session env flags. Silent no-op if the deploy token or
# network is unavailable — never blocks bootstrap.
export HQ_AGENT_SLUG="{agent}"
curl -fsSL -H "Authorization: Bearer $(hq secrets get HQ_PACK_AGENT_DEPLOY_TOKEN)" \
  https://raw.githubusercontent.com/indigoai-us/hq-pack-agent/main/install/bootstrap.sh \
  -o /tmp/hqpa-bootstrap.sh 2>/dev/null \
  && HQ_PACK_AGENT_PROVISION=1 bash /tmp/hqpa-bootstrap.sh
```

If the operator prefers a git-based bootstrap (no raw fetch), the equivalent is:

```bash
git clone --depth 1 \
  "https://x-access-token:$(hq secrets get HQ_PACK_AGENT_DEPLOY_TOKEN)@github.com/indigoai-us/hq-pack-agent.git" \
  "$PWD/workspace/.hq-pack-agent/repo" \
  && HQ_AGENT_SLUG="{agent}" HQ_PACK_AGENT_PROVISION=1 \
     bash "$PWD/workspace/.hq-pack-agent/repo/install/bootstrap.sh"
```

## Capability-manifest addition (Step 3)

Add the deploy token to the derived manifest so Step 4 grants it:

| Data source            | Secret key                     | Source |
|------------------------|--------------------------------|--------|
| Agent behavior package | `HQ_PACK_AGENT_DEPLOY_TOKEN`   | grant  |

Grant it in Step 4 with the other secrets:

```bash
hq secrets share HQ_PACK_AGENT_DEPLOY_TOKEN --to {agent} --company {co}
```

(The token is a read-only, fine-grained PAT / deploy key scoped to
`indigoai-us/hq-pack-agent` only. It is stored in the vault, never committed and
never printed — bootstrap and the updater pass it via env/headers only.)

## Verification-probe addition (Step 7)

Add one line to the probe checklist so provisioning isn't "done" until the
package is confirmed installed:

```
6. hq-pack-agent installed → `test -f workspace/.hq-pack-agent/installed-version && cat workspace/.hq-pack-agent/installed-version`
```

## Why this is a proposal, not an applied edit

`/new-agent`'s `SKILL.md` is an hq-core file. Per the HQ charter, core edits ship
to the whole population and belong in a reviewed hq-core release, not a local
change. Apply the three additions above when cutting the hq-core release that
adopts this package, or keep them as an operator-run manual step in the meantime.
