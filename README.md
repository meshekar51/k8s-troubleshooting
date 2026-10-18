# Kubernetes Troubleshooting Lab

32 production-style incidents for a local **kind** cluster, graded **L1 → L3**.
The lab quietly breaks something, hands you a ticket with **symptoms only**, and checks your fix. Finding the root cause is your job.

> Think of it as a fire drill. Someone starts a small fire somewhere in the building and you get the call: *"smoke on floor 3."* Nobody tells you where the fire is.

```
./lab.sh start L2-04   →  fault injected, incident ticket printed (symptoms only)
        you            →  investigate and fix it like it's production
./lab.sh check         →  ✔ RESOLVED  /  ✘ NOT RESOLVED YET
./lab.sh reset         →  cluster back to a clean state
```

---

## Levels

| Level | Think of it as | What it takes |
|---|---|---|
| **L1** | First responder / service desk | One object is wrong. Your first few commands point straight at it. |
| **L2** | Platform engineer | The cause sits one hop away from the symptom, in how objects relate to each other. |
| **L3** | SRE / cluster admin | Cluster-wide or node-level faults, misleading symptoms, sometimes more than one fault at once. Expect to work on the nodes themselves. |

Suggested time-box: **L1 ≈ 10 min · L2 ≈ 20 min · L3 ≈ 45 min.**

---

## Prerequisites

| Tool | Version |
|---|---|
| Linux or macOS host | ~4 GB free RAM, **~10 GB free disk** (on EC2: t3.medium or larger, 20 GB+ root volume), internet access for image pulls |
| Docker | running, usable by your user |
| [kind](https://kind.sigs.k8s.io/) | **v0.25 or newer** (needed for NetworkPolicy enforcement) |
| kubectl | any recent version |
| bash | 3.2+ |

## Quick start

```bash
git clone https://github.com/<your-user>/k8s-troubleshooting-lab.git
cd k8s-troubleshooting-lab
chmod +x lab.sh

./lab.sh up            # ~2-3 min: 3-node kind cluster + metrics-server + image preload
./lab.sh list          # the incident board
./lab.sh start L1-01   # go
```

`./lab.sh up` switches your kubectl context to `kind-trouble-lab`.
If you switch away (EKS, work clusters...), switch back before troubleshooting:

```bash
kubectl config use-context kind-trouble-lab
```

> The lab's own commands are always pinned to `--context kind-trouble-lab`, so it can never break anything else you're connected to.

## Commands

| Command | What it does |
|---|---|
| `./lab.sh up` | Create the cluster and lab add-ons (safe to re-run) |
| `./lab.sh list` | All incidents with your progress (✔ solved, ▶ active) |
| `./lab.sh start <ID>` | Inject the fault and print the ticket. Re-running the same ID restarts it from scratch |
| `./lab.sh ticket` | Re-print the active ticket |
| `./lab.sh check` | Verify the active incident. Every "Done when" line is checked |
| `./lab.sh reset [ID\|all]` | Undo the active incident (or a given one, or everything) |
| `./lab.sh down` | Delete the cluster and all local lab state |

## Your access

You have the same access a cluster admin has in a self-managed cluster:

- **cluster-admin** through `kubectl`
- **root on every node**, which in kind is a Docker container:

```bash
docker exec -it trouble-lab-control-plane bash
docker exec -it trouble-lab-worker bash
docker exec -it trouble-lab-worker2 bash
```

## Rules of engagement

1. **No peeking.** `scenarios/*.sh` and `.lab/lab.log` contain the answers.
2. **Fix it like production.** Find the root cause, don't work around it. Don't delete and recreate the namespace, and don't remove safeguards someone put there on purpose. The checker verifies they're still in place.
3. **One incident at a time.** `./lab.sh reset` before you start the next one.
4. **Write a 3-line post-mortem** after each one: *symptom → root cause → fix*. That's the habit interviews and on-call actually test.

---

## Incident board

| ID | Level | Incident |
|---|---|---|
| L1-01 | L1 | Storefront release never came up |
| L1-02 | L1 | Invoice worker won't start |
| L1-03 | L1 | Analytics API stuck after config change |
| L1-04 | L1 | Checkout pods never start |
| L1-05 | L1 | Orders API stuck creating |
| L1-06 | L1 | Report worker restart loop |
| L1-07 | L1 | Catalog service unreachable |
| L1-08 | L1 | Scale-up for the sale didn't happen |
| L1-09 | L1 | Notifier pods refuse to start |
| L1-10 | L1 | Status page keeps restarting |
| L2-01 | L2 | Search API refuses connections |
| L2-02 | L2 | Profile pods never become Ready |
| L2-03 | L2 | Cache store stuck Pending |
| L2-04 | L2 | Config sync job failing |
| L2-05 | L2 | Shop frontend can't reach backend |
| L2-06 | L2 | Sandbox deployment creates no pods |
| L2-07 | L2 | Search indexer never schedules |
| L2-08 | L2 | Order processor can't reach inventory |
| L2-09 | L2 | Autoscaler never scales |
| L2-10 | L2 | Node drain hangs forever |
| L2-11 | L2 | Reviews pods stuck initializing |
| L2-12 | L2 | Feature flag change not live |
| L3-01 | L3 | No new pods start anywhere |
| L3-02 | L3 | Deployments create nothing |
| L3-03 | L3 | kubectl can't reach the cluster |
| L3-04 | L3 | Worker node went NotReady |
| L3-05 | L3 | Apps can't reach each other |
| L3-06 | L3 | New service unreachable, old ones fine |
| L3-07 | L3 | Cart can't talk to Redis |
| L3-08 | L3 | Ledger deployment silently fails |
| L3-09 | L3 | Namespace stuck Terminating |
| L3-10 | L3 | Worker2 keeps evicting pods |

---

## When the lab itself gets stuck

| Situation | Do this |
|---|---|
| `up` was interrupted, or `context "kind-trouble-lab" does not exist` | `./lab.sh down && ./lab.sh up` |
| `no space left on device` during `up` | Free disk (`docker image prune -a`, `docker volume prune`) or grow the volume, then `./lab.sh down && ./lab.sh up` |
| Want to retry an incident from zero | `./lab.sh start <same ID>` |
| Gave up / moving on | `./lab.sh reset` |
| Not sure what's still broken | `./lab.sh reset all` |
| Everything is weird | `./lab.sh down && ./lab.sh up` (~3 min) |
| A check fails right after a correct fix | Wait ~15 s and re-run `./lab.sh check`; some apps retry on a loop |

## Repository layout

```
.
├── lab.sh               # the runner: up / list / start / ticket / check / reset / down
├── kind-config.yaml     # 1 control-plane + 2 workers
├── lib/common.sh        # shared helpers (kubectl pinned to the lab context, checks, node backups)
├── scenarios/           # one file per incident — SPOILERS
└── .lab/                # local state, git-ignored (active incident, progress, backups, log)
```

## Adding your own incident

Create `scenarios/<ID>.sh` with:

```bash
ID="L2-13"; LEVEL="L2"; TITLE="Short symptom, never the cause"; NS="my-namespace"

ticket()          { cat <<'EOF'
...symptoms + "Done when" lines...
EOF
}
scenario_break()  { ... }   # inject the fault (use k, ns_fresh, node_backup ...)
scenario_check()  { expect "outcome description" some_check_fn args; }
scenario_reset()  { ... }   # must be safe to run even if the scenario never started
```

Rules that keep the lab hint-free: tickets describe **what users see**, never **what is wrong**, and check descriptions state **outcomes**, not causes.

## Notes

- Images used: `nginx:1.27-alpine`, `nginx:1.27`, `busybox:1.36`, `curlimages/curl:8.10.1`, `redis:7.2-alpine`, `python:3.12-alpine`. All are multi-arch (amd64 + arm64).
- If Docker Hub rate-limits you, run `docker login` and re-run `./lab.sh up`.
- Pin a Kubernetes version with `KIND_NODE_IMAGE=kindest/node:<tag> ./lab.sh up`.
