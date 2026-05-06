# Follow-up TODOs (post v1)

Items intentionally left out of the v1 SRv6 MUP series and queued for
later submission.

## 1. Per-action `NF_INET_PRE_ROUTING` on inner T-PDU

**Goal:** Make the inner T-PDU 5-tuple visible to iptables / nftables
/ conntrack on the SRv6 MUP decap path, matching what `End.DX4` and
`End.DX6` already do (see `net/ipv6/seg6_local.c:967` /
`net/ipv6/seg6_local.c:1017`).

**Why this is a follow-up, not part of v1:**

- v1 is scoped to behavior implementation + UAPI.  Adding inner-flow
  netfilter integration expands the review surface of an already-
  large series.
- The pattern is well established in the kernel (DX4/DX6), so a
  follow-up series can be reviewed quickly on its own merits.
- v1's `seg6_mobile.rst` (current state) does not advertise inner
  exposure, so adding it later is a non-breaking enhancement rather
  than a contract change.

**Series shape (the right way to land this):**

The hook lives inside each behavior's input handler.  Splitting it
into a single "infrastructure + all five handlers" mega-patch is
hard to review and not bisect-clean (a reviewer who NACKs the
infrastructure patch loses the per-behavior context).  Instead:

  - **One commit per behavior.** Each commit refactors that behavior
    into a `_core` / `_finish` pair and adds the `NF_HOOK` call
    gated on `nf_hooks_lwtunnel_enabled`.  Touch only one behavior
    per commit so each is independently bisect-clean.
  - **Behaviors to touch (in this order):** `End.M.GTP6.D`,
    `End.M.GTP6.D.Di`, `End.M.GTP4.E`, `End.M.GTP6.E`, `H.M.GTP4.D`.
    `End.MAP` does not decap and is skipped.
  - **Selftest update lands alongside the behavior commit it
    exercises.** Each behavior commit adds one or two cases to its
    matching `srv6_*_test.sh` (e.g. install
    `nft add rule ip filter forward ip saddr <inner-sa> drop` in
    the SR Gateway netns and assert no GTP-U packet appears at the
    egress).  This keeps the bisect property: at every commit the
    behavior + its selftest agree.
  - **Final commit updates `Documentation/networking/seg6_mobile.rst`**
    to add a "Netfilter integration" section listing which hook
    fires on which packet for each behavior, and noting the
    `nf_hooks_lwtunnel=1` requirement (one-way; see
    `Documentation/networking/nf_conntrack-sysctl.rst`).
  - No new UAPI is needed; the inner-flow visibility is purely a
    kernel-internal hook arrangement.

**Implementation sketch (per handler):**

DX4/DX6 (`net/ipv6/seg6_local.c:945-972` and
`net/ipv6/seg6_local.c:1003-1023`) is the reference pattern.  For an
E-family MUP behavior the split looks like:

```c
static int input_action_end_m_gtp4_e_finish(struct net *net,
                                            struct sock *sk,
                                            struct sk_buff *skb)
{
    /* second half: build IPv4/UDP/GTP-U + dst_output() */
}

static int input_action_end_m_gtp4_e(struct sk_buff *skb,
                                     struct seg6_local_lwt *slwt)
{
    /* first half: validate SRH, decap to inner T-PDU */
    /* set skb->protocol = htons(ETH_P_IP) or ETH_P_IPV6 from inner */
    /* skb_reset_network_header(skb); */
    /* skb_set_transport_header(skb, inner_ip_hdr_len); */
    /* nf_reset_ct(skb); */

    if (static_branch_unlikely(&nf_hooks_lwtunnel_enabled))
        return NF_HOOK(inner_nfproto, NF_INET_PRE_ROUTING,
                       dev_net(skb->dev), NULL, skb, skb->dev,
                       NULL, input_action_end_m_gtp4_e_finish);

    return input_action_end_m_gtp4_e_finish(dev_net(skb->dev),
                                            NULL, skb);
}
```

`inner_nfproto` is selected at runtime from the inner protocol byte
(`NFPROTO_IPV4` for `IPPROTO_IPIP`, `NFPROTO_IPV6` for
`IPPROTO_IPV6`).

**Estimate:** 30-50 lines of C per behavior commit + 30-60 lines of
shell/scapy in the matching selftest = roughly 60-110 lines per
commit.  Five commits + one Documentation commit ≈ 350-500 lines
total across six commits.

**Caveats to call out in commit messages:**

- The hook only fires when `nf_hooks_lwtunnel=1`.  Default behavior
  is unchanged.
- A `DROP` verdict from the hook causes the packet to be dropped
  before re-encapsulation; an `ACCEPT` verdict causes the original
  encap path to run.
- conntrack now tracks inner T-PDU flows for these SIDs; operators
  who run separate conntrack zones for the SR underlay vs the user
  plane should verify zone tagging still does what they expect.
