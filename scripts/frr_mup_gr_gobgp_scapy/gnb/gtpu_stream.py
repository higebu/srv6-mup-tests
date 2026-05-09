#!/usr/bin/env python3
"""Continuous GTP-U(ICMP echo) traffic generator with reply accounting.

Used by the GR / route-refresh sub-tests to count how many GTP-U
echo replies are lost while a control-plane event (clear bgp,
soft refresh) is in flight.  Each sent packet carries a unique
ICMP `seq`; the AsyncSniffer collects all replies on the GTP-U
port and we diff the seq sets to compute loss.

Args:
  $1 GW_DST   IPv4 destination of the outer IP (= T2ST EP)
  $2 UE_SRC   inner IPv4 source (= UE prefix host bits)
  $3 DN_DST   inner IPv4 destination (DN host)
  $4 TEID     GTP-U TEID
  $5 RATE_HZ  send rate, packets per second
  $6 DURATION wall-clock seconds to send for
  $7 OUTFILE  path for the result line (key=value pairs)
"""
import os
import sys
import time
from scapy.all import IP, ICMP, UDP, conf, send, AsyncSniffer
from scapy.contrib.gtp import GTP_U_Header

GW_DST = sys.argv[1]
UE_SRC = sys.argv[2].split("/", 1)[0]
DN_DST = sys.argv[3].split("/", 1)[0]
TEID = int(sys.argv[4])
RATE = float(sys.argv[5])
DURATION = float(sys.argv[6])
OUTFILE = sys.argv[7]

conf.verb = 0

# Sniff every GTP-U echo-reply on TEID; record the inner ICMP seq.
seen_seqs = set()


def is_reply(pkt):
    if not pkt.haslayer(GTP_U_Header):
        return False
    if not pkt.haslayer(ICMP):
        return False
    if int(pkt[GTP_U_Header].teid) != TEID:
        return False
    if int(pkt[ICMP].type) != 0:
        return False
    seen_seqs.add(int(pkt[ICMP].seq))
    return False  # never stop early; we drain on duration


sniffer = AsyncSniffer(filter="udp port 2152", store=False, prn=is_reply)
sniffer.start()
time.sleep(0.2)

interval = 1.0 / RATE if RATE > 0 else 0.05
deadline = time.time() + DURATION

sent = 0
seq = 0
t0 = time.time()
next_send = t0
while time.time() < deadline:
    seq += 1
    inner = (
        IP(src=UE_SRC, dst=DN_DST)
        / ICMP(type=8, id=0xBEEF, seq=seq & 0xFFFF)
        / (b"srv6mup-gr-%08d" % seq)
    )
    outer = (
        IP(src="10.99.0.5", dst=GW_DST)
        / UDP(sport=2152, dport=2152)
        / GTP_U_Header(teid=TEID)
        / inner
    )
    try:
        send(outer)
        sent += 1
    except OSError:
        # transient ENOBUFS during clear bgp can fire here on small queues
        pass
    next_send += interval
    sleep_for = next_send - time.time()
    if sleep_for > 0:
        time.sleep(sleep_for)

# Drain late replies for a brief grace window so packets in flight
# at deadline still count as delivered.
time.sleep(1.0)
sniffer.stop()

# 16-bit seq wraps after 65535; for the rates and durations the
# tests use (<= 100 Hz x <= 30 s) we never wrap, so a plain set
# diff is correct.  Add a defensive assert.
assert sent < 65536, "seq space wrapped — increase seq width"

delivered = len(seen_seqs)
lost = sent - delivered
# first_loss_seq: lowest sent seq we never saw replied
first_loss_seq = -1
for s in range(1, sent + 1):
    if s not in seen_seqs:
        first_loss_seq = s
        break

with open(OUTFILE, "w") as f:
    f.write(
        "sent={} delivered={} lost={} first_loss_seq={} duration={:.3f}\n".format(
            sent, delivered, lost, first_loss_seq, time.time() - t0
        )
    )

print(
    "GTPU-STREAM sent={} delivered={} lost={} first_loss_seq={}".format(
        sent, delivered, lost, first_loss_seq
    )
)
