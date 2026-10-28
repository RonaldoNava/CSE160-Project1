CSE 160 – Project 2: Distance Vector Routing

For Project 2, I implemented Distance Vector Routing using Bellman-Ford in TinyOS. I reused Neighbor Discovery and Flooding modules from Project 1 and added a Distance Vector module to find the shortest routes between nodes.

The IP module uses the routing table to forward packets to their next hop instead of flooding them.

 Implementation:

- Distance Vector: Maintains destinations, next hops, and hop counts using Bellman-Ford.
- Poison Reverse: Advertises a cost of 16 to a neighbor if the route goes through that neighbor.
- Route Updates: Sends periodic updates and handles routes that become unavailable.
- IP Forwarding: Uses the DV routing table for multi-hop Ping and PingReply.

We used these settings:

| Setting | Value |
|---|---|
| INFINITY | 16 |
| Maximum stored routes | 32 |
| Maximum cached neighbors | 8 |
| Update interval | 10 seconds |
| Route expiration | 5 update intervals |
| Withdrawal period | 5 update intervals |
| Entries per advertisement packet | 6 |
| Normal packet TTL | 20 |

How to Run:

Inside the TinyOS Docker container, compile using:

```bash
make clean
make micaz sim
```

Run the tests using:

```bash
python -u dvLineTest.py
python -u dvAlternateTest.py
python -u dvPartitionTest.py
python -u dvPacketCapacityTest.py
python -u dvLossTest.py
```

The topology files are in `topo/`, and the noise files are in `noise/`. Each test loads its topology and noise model, boots the nodes, and allows the network to converge. The line test also logs poison reverse advertisements.

For the TTL test, temporarily change `MAX_TTL` in `includes/packet.h` from `20` to `2`, rebuild with the commands above, and run `python -u dvLineTest.py`. The packet should expire at Node 3 before reaching Node 4. Change `MAX_TTL` back to `20` and rebuild afterward.

Test Results:

| Test | Expected | Observed |
|---|---|---|
| Four-node line | Node 1 reaches Node 4 in 3 hops and gets a reply | Cost 3 route; PingReply received |
| Poison reverse | Node 2 advertises cost 16 to Node 3 and cost 2 to Node 1 for destination 4 | Both advertisement values logged |
| Alternative path | Route to Node 4 changes from cost 2 to 3, then back to 2 | Correct next hops and PingReplies in all three stages |
| Network partition | Removing link 2–3 makes Node 4 unreachable from Node 1; restoring it recovers the route | Ping dropped with no route, then PingReply received after recovery |
| Packet capacity | Learn all 20 destinations using multiple DV packets | All 20 routes learned; PingReply from Node 12 received |
| Packet loss | Routes expire after missed updates and recover after updates resume | Routes expired and were relearned; 2 of 5 pings received replies |
| TTL expiration | A TTL of 2 expires before a 3-hop packet reaches Node 4 | Node 3 logged TTL expired; no PingReply |

The tests showed that routes update when the network changes. With the lossy noise model, some pings failed, but routes were able to recover when new advertisements arrived.
