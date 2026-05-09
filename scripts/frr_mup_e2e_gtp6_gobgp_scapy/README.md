# `frr_mup_e2e_gtp6_gobgp_scapy/` — BGP-MUP v6 系 e2e ハーネス

`frr_mup_e2e_gobgp_scapy/` の v6 派生。RFC 9433 Section 6.3 / Section 6.5
の v6 系 Mobile User Plane 動作 (End.M.GTP6.D / End.M.GTP6.E) と
End.DT6 (RFC 8986 Section 4.8) を、BGP-MUP の origination → 受信 →
install 経路を通った状態で **実 GTP-U(v6)** が SR-domain を抜ける
ところまで一気通貫で検証する。VPP interop (`vpp_interop_end_m_gtp6_*`)
が手動 `ip route add ... seg6local action End.M.GTP6.*` で kernel 側の
wire-format 互換だけを確認していたのに対し、本シナリオは FRR の
`address-family ipv6 unicast` 上の `behavior mup export dt6` /
`segment mup export interwork` までを通る。

## トポロジ

5 netns 構成は v4 baseline と同一。

```
+-----+ gtpu  +-----+ srv6  +-----+ ipv6  +-----+
| gnb |-------| gw1 |-------| pe1 |-------| dn  |
+-----+ veth  +-----+ veth  +-----+ veth  +-----+
scapy         MUP-GW        MUP-PE
              ISD origin    DSD origin
              (End.M.GTP6.E)   (End.DT6)
                ^                 ^
                |                 |
                +-- gobgpd (MUP-C) --+
                    via separate veth into pe1
                    (ipv6-mup AF)
```

| netns  | 役割 (Mobile User Plane の語彙)               | 主な install                                  |
|--------|-----------------------------------------------|-----------------------------------------------|
| `gnb`  | gNB (UL ingress / DL egress, scapy で送受信)  | -                                             |
| `gw1`  | MUP-GW (ISD originator)                       | seg6local End.M.GTP6.E @ gw1 locator          |
| `pe1`  | MUP-PE (DSD originator)                       | seg6local End.DT6 @ pe1 locator               |
| `dn`   | DN-side host (UE トラフィックの先)            | -                                             |
| `gbgp` | MUP-Controller (gobgpd で T1ST/T2ST を inject)| -                                             |

## アドレスプラン

`gnb` / `dn` / `ue` は IPv6 として valid hex ではないため、単一 hex
桁の代用 (`a` = access network, `b` = backbone, `c` = client) を採用。
これは `docs/topology.md` 既存の単 hex 桁 /64 スロット (`e`/`f`/`6`/`9`
等) と同じ命名スタイル。

| 用途                            | プレフィクス             | 備考                                              |
|---------------------------------|--------------------------|---------------------------------------------------|
| gNB-side IPv6 link              | `2001:db8:a::/64`        | gw1=::1, gnb=::5                                  |
| GTP-U(v6) サービス IP (T2ST EP) | `2001:db8:a::100/128`    | gw1 上、ISD `2001:db8:a::/64` 配下                |
| UE プレフィクス (T1ST)          | `2001:db8:c::5/128`      | 単一 UE                                           |
| DN-side IPv6 link               | `2001:db8:b::/64`        | pe1=::1, dn=::5                                   |
| SR-domain IPv6 link             | `2001:db8:1::/64`        | gw1=::1, pe1=::2                                  |
| MUP-C 制御バス                  | `2001:db8:0::/64`        | pe1=::1, gbgp=::2                                 |
| pe1 SR locator                  | `2001:db8:e::/48`        | block 24 / node 24 / func 8 (loc_func = 56 bits)  |
| gw1 SR locator                  | `2001:db8:f::/48`        | block 24 / node 24 / func 8                       |
| DSD address                     | `10.0.0.250` (IPv4)      | DSD の Address AFI は現 FRR では IPv4 のみ        |
| TEID / QFI                      | 12345 / 9                | UL/DL 共通                                        |
| MUP-EC seg-id                   | `10:10`                  | T2ST と DSD で一致                                |

## How to run

`vng` (virtme-ng) 上で root として実行する。`vng_test.sh` の他のシナリオと
同じく `--rwdir=$PCAP_DIR` で pcap を VM 外に持ち出せる。

```bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PCAP_DIR=$ROOT/srv6-mup-tests/pcaps
script -q -c "vng -m 4G --rwdir=$PCAP_DIR \
  --run $ROOT/linux --user root \
  -- $ROOT/srv6-mup-tests/scripts/frr_mup_e2e_gtp6_gobgp_scapy/frr_mup_e2e_gtp6_gobgp_scapy.sh" \
  /tmp/run.log
```

トラブルシュート用フラグ:

- `DEBUG=1` … `nlmon0` (RTM_NEWROUTE 観測) と `tcpdump -i any` を pe1 / gw1 で起動。

## Pass criteria

スクリプト末尾は `===VERDICT=== FRR-MUP-E2E-GTP6-GOBGP-SCAPY: PASS` を
吐く。PASS 条件は順に:

1. `pe1` の `2001:db8:c::5/128` が vrf-red (table 100) に
   `encap seg6 mode encap` (= H.Encaps) で install されている。
2. `gw1` の `2001:db8:a::100/128` が vrf-red に `encap seg6local` で
   install されている (action は現 FRR 実装に追従)。
3. `pe1` で End.DT6 seg6local が DSD SID locator にぶら下がっている。
4. `gw1` で End.M.GTP6.E seg6local が ISD SID locator にぶら下がっている。
5. `pe1` の T1ST 由来 install が持つ synthesized SID の bits 88..127 が
   Args.Mob.Session = `(QFI<<2) || TEID` (40-bit、MSB-aligned) に一致。
6. **DL probe**: `dn` から UE プレフィクス宛の ICMPv6 echo-request を
   流し、`gnb` が GTP-U(v6, TEID=12345) を 5s 以内に観測。
7. **UL probe**: `gnb` で生成した GTP-U(v6) の中の ICMPv6 echo-request
   が DN まで到達して echo-reply が GTP-U(v6) で返ってくる。

## Known gaps

- 現 FRR (`bgpd/bgp_mup.c:bgp_mup_build_t2st_route` line 1731) の
  T2ST install は endpoint AFI に関わらず
  `ZEBRA_SEG6_LOCAL_ACTION_H_M_GTP4_D` を選ぶため、AFI_IP6 の T2ST
  install では v6 GTP-U ingress を受けられず本ハーネスの UL leg は
  失敗する。これは設計上のバグで、`srv6-mup-issues/`
  `20260509-150607-bug-t2st-v6-endpoint-installs-h-m-gtp4-d.md` で
  別 issue として追跡。UL を skip する逃げ道は意図的に置いていない —
  fix が入るまで UL は FAIL を返し、回帰検出に役立てる。
- DSD の Address AFI は draft-ietf-bess-mup-safi Section 3.3.4 では
  inner-PDU AFI と独立だが、現 FRR の `segment mup export direct
  address X` は `A.B.C.D` (IPv4) しか取らない。本ハーネスでは
  `address 10.0.0.250` を使い、AFI_IP6 BGP-MUP に対しても IPv4 router-id
  ベースの DSD address が乗ることを前提にする。

## References

- RFC 9433 Section 6.3 (End.M.GTP6.D), Section 6.5 (End.M.GTP6.E),
  RFC 8986 Section 4.8 (End.DT6) <https://www.rfc-editor.org/rfc/rfc9433.txt>
- v4 baseline: `scripts/frr_mup_e2e_gobgp_scapy/`
- v6 wire-format kernel-only 互換: `scripts/vpp_interop_end_m_gtp6_d.sh`,
  `vpp_interop_end_m_gtp6_d_di.sh`, `vpp_interop_end_m_gtp6_e.sh`
- `bgpd/bgp_mup.c` の `behavior mup export dt6` / `bgp_mup_build_t2st_route`
