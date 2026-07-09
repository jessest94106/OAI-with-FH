#!/usr/bin/env python3
# Server-less UL saturator for the MU-MIMO demo.
# Blasts paced UDP at a dst routed via the UE's tun default route -> keeps the RLC UL buffer
# backlogged -> continuous BSR -> the scheduler grants every slot -> two backlogged UEs co-schedule.
# No server needed (UDP is fire-and-forget; iperf3 -u needs a TCP control channel to a reachable
# UPF, which is the 0-byte-log failure this replaces). Run one per UE netns, simultaneously.
#
# usage: ul_saturate.py <dst_ip> <duration_s> [rate_mbps=60] [payload=1200]
import socket, sys, time

dst = (sys.argv[1] if len(sys.argv) > 1 else "10.0.0.1", 9999)
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
rate = (float(sys.argv[3]) if len(sys.argv) > 3 else 60.0) * 1e6 / 8.0  # bytes/s
size = int(sys.argv[4]) if len(sys.argv) > 4 else 1200

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
buf = b"\0" * size
end = time.time() + dur
nxt = time.time()
sent = 0
while time.time() < end:
    try:
        s.sendto(buf, dst)
        sent += 1
    except OSError:
        pass  # tun/socket buffer full -> drop, stay backlogged
    nxt += size / rate  # pace so we stay just above UL capacity (backlogged, not CPU-spinning)
    dt = nxt - time.time()
    if dt > 0:
        time.sleep(dt)
print("ul_saturate sent=%d bytes=%d dst=%s dur=%.0f rate_mbps=%.0f" % (sent, sent * size, dst[0], dur, rate * 8 / 1e6))
