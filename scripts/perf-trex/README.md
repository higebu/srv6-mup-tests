# scripts/perf-trex/

End-to-end runner for SRPerf-based SRv6 (incl. RFC 9433 Mobile User
Plane) performance sweeps on a Vultr-provisioned 2-node b2b testbed.

These scripts are testbed-specific glue — the SRPerf fork itself
(`../../SRPerf`, branch `srv6-mup-port`) stays testbed-agnostic.

```
provision.sh   →  create 2x bare-metal + 1x VPC 2.0, attach + reboot
install_sut.sh →  push rebuilt kernel/iproute2 debs, configure NICs
install_trex.sh→  install Cisco T-Rex + DPDK on the tester, bind NIC
run_sweep.sh   →  regen pcaps with real MAC, rsync SRPerf, run PDR/MRR
destroy.sh     →  detach VPC, delete bare-metals, delete VPC, drop state
```

All scripts share `lib.sh` (Vultr CLI wrapper, SSH helpers, state file
at `~/.cache/srv6-mup-trex-state.env`) and read the testbed address
plan from environment variables defaulting to
[`SRPerf/sut/linux/forwarding-behaviour.cfg`](../../../SRPerf/sut/linux/forwarding-behaviour.cfg).

See [`docs/perf-trex-vultr.md`](../../docs/perf-trex-vultr.md) for the
end-to-end runbook.
