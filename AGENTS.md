# Agent guidelines for this workspace

This repository (`srv6-mup-tests`) is the test harness for an in-progress
contribution that adds RFC 9433 (SRv6 Mobile User Plane) support to two
upstream projects:

- **Linux kernel** — patch series at <https://github.com/higebu/linux/tree/srv6-mup>
  (target: `netdev` mailing list, `net-next` tree)
- **iproute2** — patch series at <https://github.com/higebu/iproute2/tree/srv6-mup>
  (target: `netdev` mailing list, iproute2-next tree)

When working in this workspace (or in the two source trees above), the
following rules apply.

## Scope

The deliverable is the patch series for Linux + iproute2 that implements
the six RFC 9433 §6.2-§6.7 behaviors (End.MAP, End.M.GTP6.D, End.M.GTP6.D.Di,
End.M.GTP6.E, End.M.GTP4.E, H.M.GTP4.D). End.Limit (§6.8) is intentionally
out of scope for the initial series.

Everything in this repo is **infrastructure** for that series — selftests,
VPP interop scripts, evidence pcaps, documentation. It is not itself the
contribution.

## Authoritative spec source

- **Always read RFC 9433 in the plain-text canonical form**:
  <https://www.rfc-editor.org/rfc/rfc9433.txt>
  HTML / PDF renderings sometimes alter whitespace or line numbering of
  the pseudo-code, which has bitten this project before. The .txt is the
  RFC Editor source-of-truth.
- For SRv6 fundamentals also read the .txt of:
  - RFC 8754 (SRH wire format / segment list ordering)
  - RFC 8986 (SRv6 Network Programming, baseline End / End.X / End.DT*)
  - 3GPP TS 38.415 (PDU Session Container, used by `pdu_session_type`)

## RFC compliance is a hard requirement

- Implementation must follow the RFC pseudo-code **literally**, including
  field offsets, MUST / SHOULD wording, and the SID / Args.Mob.Session
  byte layout in §6.1.
- Read the RFC holistically. When one section's pseudo-code uses a
  short notation (e.g. "the SRH[0]" referring to a logical SID
  position) and another section adds a normative constraint (e.g. an
  §-level MUST about where an SID must reside), they must be read
  together — the constraint resolves the notation. Document the unified
  reading in code comments and in the commit message.
- Concrete example present in this codebase: §6.3 S08 says
  *"Write in the SRH[0] the Args.Mob.Session"* and §6.5 Note states
  *"An End.M.GTP6.E SID MUST always be the **penultimate SID**"*.
  Read together with §6.4 S08 (which uses "as SRH[0]" to mean the
  preserved original DA), §6.3 S08's "SRH[0]" is the End.M.GTP6.E SID
  position, and §6.5 Note pins that position to the penultimate slot
  in the wire SRH. The wire layout produced by End.M.GTP6.D therefore
  is `[D (preserved orig DA at wire SRH[0]),
       End.M.GTP6.E SID + Args.Mob.Session (= penultimate)]`.
  Any code change touching End.M.GTP6.D / End.M.GTP6.E must preserve
  this invariant.
- Departures from the RFC, however small, must be called out
  explicitly in the affected commit message and (where applicable) in
  `Documentation/networking/srv6_mobile.rst`.

## Match the upstream coding and commit style

When editing Linux kernel sources:

- Coding style: `Documentation/process/coding-style.rst`. Run
  `scripts/checkpatch.pl --strict --codespell` on every patch; aim for
  zero non-trivial warnings.
- Commit message style: `Documentation/process/submitting-patches.rst`,
  in particular the "Describe your changes" and "Sign your work" rules.
  Subject prefix follows the existing convention of the touched
  subsystem (e.g. `seg6: ...`, `selftests: seg6: ...`).
- Selftest style: match the existing `tools/testing/selftests/net/srv6_*.sh`
  skeleton — `source lib.sh`, `setup_ns`, `cleanup_all_ns`, exit
  `$ksft_pass` / `$ksft_fail`.
- UAPI rules (`include/uapi/linux/seg6_local.h`): never renumber existing
  values; add new enum entries at the end.

When editing iproute2 sources:

- Coding style: tabs, K&R-ish, kernel-flavoured. Match the surrounding
  code in `ip/iproute_lwtunnel.c` exactly.
- Commit message style: subject prefix matches the file or feature area
  (e.g. `seg6: ...`). Stephen Hemminger's tree expects clean,
  one-purpose commits.
- Keyword choice: prefer underscore-separated CLI keywords (e.g.
  `sr_prefix_len`, `pdu_session_type`) over dotted forms, matching the
  iproute2 convention used elsewhere.

When editing this repo (`srv6-mup-tests`):

- Documentation: English, Markdown. Topology / sequence diagrams in
  Mermaid (GitHub renders them inline).
- Test scripts: `set -e` at the top, idempotent, no host-network
  side-effects (everything runs inside vng).

## Reviewing code: strict, maintainer-perspective

When asked to review code (in this workspace or in linked repos),
review **as if you were the upstream maintainer who has to merge it**:

- **No sycophancy.** Do not praise patches that have problems. Do not
  soften phrasing to be polite. Be direct.
- **Read the diff with the spec next to you.** Every behavior change
  must be cross-checked against the RFC pseudo-code line by line.
- **Bisectability.** Each patch must build and pass selftests on its
  own; mid-series breakage is a hard reject.
- **Hard issues to flag explicitly when they exist:** mis-counted
  field offsets, missing UAPI annotations, locking races, missing
  `pskb_may_pull` / `skb_cow_head`, unbounded loops, integer
  overflow in length math, leaks on error paths,
  `seg6_action_table[]` ordering changes that break ABI, `checkpatch`
  warnings.
- **Commit hygiene to flag:** "fix the previous commit" patterns,
  unrelated whitespace/rename changes, missing `Signed-off-by`,
  missing `Reviewed-by` / `Tested-by` attribution where appropriate,
  subject prefixes that don't match the subsystem.
- If the patch is good, say so concisely; do not pad. If a problem is
  not actually present, do not invent one.
- When unsure, say so explicitly rather than guessing — pointing out
  "I cannot tell from the diff whether X happens; please clarify" is
  better than fabricating a verdict.

The goal is to give the patch the same scrutiny it would face on
`netdev@vger.kernel.org`, before a tired maintainer says "needs more
work" and moves on.

## Deploying the built bundle to the CML2 verification node

For end-to-end verification (selftests + VPP interop) against a real
Ubuntu 24.04 LTS host, the patched kernel + iproute2 are installed on a
dedicated CML2 lab node from the `.deb` bundle produced by
`scripts/build_tarball.sh`.

Hosts:

- **Build server** — `tk1ad-ykusakabe-01`. After every successful run of
  `scripts/build_tarball.sh` the freshest bundle lives at
  `~/srv6-mup-bundle.tar.gz` on this host. Treat its mtime/sha256 as the
  source-of-truth for "is there a newer build to install?".
- **CML2 verification node** — `higebu@192.168.255.221`. Ubuntu 24.04
  LTS. Receives the bundle, installs the debs with `apt-get install -y
  ./*.deb`, and reboots into the new kernel.

Workflow (run from the local workstation; both hosts are reachable over
SSH):

1. Pull the bundle from the build server and push it to the CML2 node
   only if the build server's copy is newer than what's already on the
   CML2 node (sha256 / mtime comparison). Do not blindly re-copy — a
   spurious copy still triggers a reinstall + reboot below.
2. On the CML2 node: `tar xzf srv6-mup-bundle.tar.gz`,
   `cd srv6-mup-bundle`, `sudo apt-get install -y ./*.deb`. The kernel
   debs land in `/boot`; `update-grub` is run by the maintainer scripts.
3. `sudo reboot`. The new kernel is required because the bundle's debs
   replace `linux-image-...` and the running kernel cannot be swapped
   in-place.
4. After the node comes back, confirm `uname -r` matches the
   `linux-image-...srv6mup-NN` version in the freshly-installed bundle
   and `ip -V` / `ip route help 2>&1 | grep -i mup` show the patched
   iproute2.

If there is no diff between the build-server bundle and the bundle
already on the CML2 node, do nothing — skip steps 2–4. Reinstalling and
rebooting "just in case" wastes the soak window for any in-progress
verification.

### Do **not** run selftests on the CML2 node without explicit instruction

The kernel selftests (`tools/testing/selftests/net/srv6_*_test.sh`,
shipped under `selftests/` inside the bundle) execute

```sh
sysctl -w net.netfilter.nf_hooks_lwtunnel=1
```

as part of their setup. This sysctl, once turned on, **cannot be
turned off again on a running kernel** — the only way to clear it is a
reboot. That makes running the selftests on the CML2 node a
state-changing action with a non-trivial blast radius (subsequent
unrelated traffic on that host goes through the netfilter lwtunnel hook
path until the next reboot).

Therefore: **never run the selftests on the CML2 node on your own
initiative.** Wait for an explicit "run the selftests now" instruction
from the user. Deployment (copy + `apt-get install` + reboot) is fine
to do autonomously when a newer bundle is available; the selftest
invocation is not.
