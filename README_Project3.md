# CSE 160 – Project 3: Reliable Transport

## Overview

For Project 3, I built reliable transport on top of my Project 2 Distance Vector (DV) routing. My transport establishes connections, sends bytes in order, retransmits data when needed, controls how much the receiver can accept, and closes connections. The test application in `Node.nc` generates data and checks the received bytes.

## How it works

- **Connection:** SYN, SYN-ACK, and ACK establish a connection. FIN and ACKs close it.
- **Reliability:** Sliding window, cumulative ACKs, and Go-Back-N retransmission after a timeout.
- **Flow control:** Each socket has a 128-byte circular send buffer and a 128-byte receive buffer. The sender follows the receiver's advertised window. When it becomes zero, `windowCheck` checks whether there is room again.
- **Routing:** Uses my Project 2 DV implementation, Neighbor Discovery, and IP forwarding.

Key files include `Node.nc`, `lib/modules/TransportP.nc`, `includes/socket.h`, `includes/transport_packet.h`, `TestSim.py`, `run.py`, and the Project 2 routing modules.

## Packet format and limits

The transport header is **9 bytes**: source port (1), destination port (1), flags (1), sequence number (2), ACK number (2), receive window (1), and data length (1). A packet can carry up to **11 bytes** of DATA. I use SYN, ACK, FIN, DATA, and WINDOW_CHECK flags.

Sequence and ACK numbers are 16-bit. My implementation does not support sequence-number wraparound: initial sequence numbers are **100–4195**, and writes stop before **65534**. The test generator supports **1–60000 bytes**.

| Setting | Value |
|---|---|
| Socket records | 3 per node |
| Send / receive buffers | 128 bytes each |
| Maximum outstanding DATA | 33 bytes |
| Transport timer | 100 ms |
| Retransmission timeout / retries | 3 seconds / 5 retries |
| Zero-window check | Every 3 seconds while needed |
| Connection stall limit | 60 seconds |
| TIME_WAIT | 20 seconds |
| DV updates | 10 seconds |
| DV route / peer capacity | 32 routes / 8 peers |
| Neighbor Discovery | 5 seconds |

## Build and run

Run these inside the TinyOS Docker container from the project folder:

```bash
make clean
make micaz sim
```

Run the Python scripts in the TinyOS Docker environment after building; the build generates the TOSSIM simulation files.


The Python command helpers in `run.py` are:

```python
def cmdTestServer(s, serverAddress, listenPort):
def cmdTestClient(s, clientAddress, serverAddress, srcPort, destPort, transferBytes):
def cmdClientClose(s, clientAddress, serverAddress, srcPort, destPort):
```

I also added `TestSim.testServer(self, node)` and `TestSim.testClient(self, node)` for the supplied scripts. They default to server **1:20**, client port **10**, and **25 bytes**.

### Test commands

```bash
python -u run.py clean             # Normal 25-byte transfer
python -u run.py loss              # Drop DATA and show retransmission
python -u run.py clean 145         # Transfer more than one buffer
python -u run.py zero-window 145   # Pause receiver reads, then resume
python -u testA.py > testA.log 2>&1
python -u testB.py > testB.log 2>&1
python -u testB_local.py > testB_local.log 2>&1
```

The first four tests use `dv_line4.topo` and `no_noise.txt` (stored in `topo/` and `noise/`). Test A uses `tuna-melt.topo` with `no_noise.txt`. Test B uses `pizza.topo` with `meyer-heavy.txt`. My local heavy-noise test uses the same supplied pizza topology and noise but starts the client on Node 4 instead of Node 13.

For **`zero-window`**, the demo uses server port **21**, while normal tests use port **20**. In `Node.nc`, the test consumer pauses its reads for **25 simulated seconds after accepting the connection**, allowing the 128-byte receive buffer to fill. The receiver advertises a zero window, and the sender stops DATA transmissions and sends `WINDOW_CHECK` packets. After the pause, the receiver reads again and the remaining bytes are delivered. The pause only applies to the demo connection, not normal sockets.

The new script writes separate logs such as `project3_clean_25.log` and `project3_zero_window_145.log`. It prints `RESULT: PASS` only when its required checks succeed. To inspect the demo:

```bash
grep -E 'TEST_READ_PAUSE|wnd=0|WINDOW_CHECK|TEST_READ_RESUME|APP_FINAL' project3_zero_window_145.log
```

The `RESULT` line is printed by `run.py` to the terminal, not saved inside the `.log` file. In my successful zero-window run, Node 4 advertised `wnd=0`, Node 1 sent four `WINDOW_CHECK` packets, and Node 4 resumed reading at simulated time `131600`. All 145 bytes were acknowledged and consumed with zero mismatches. The sender resumed after reading restarted; this run does not specifically prove recovery from a lost window-update ACK, which I tested separately.

## Test results

| Test | Result |
|---|---|
| Clean 25-byte transfer | PASS |
| Intentional DATA loss | PASS; retransmission recovered |
| 145-byte clean transfer | PASS |
| Repeatable `zero-window` scenario | **PASS**; 145 bytes delivered, four window checks while full, and successful close |
| Lost window-update recovery | PASS in an earlier temporary ACK-drop test |
| Test A, Node 4 to Node 1 | PASS for handshake and 25 bytes |
| Local heavy-noise test, Node 4 to Node 1 | PASS; 145 bytes, retransmission, and close |
| Original instructor Test B, Node 13 to Node 1 | Did not connect: Node 13 had no route to Node 1 |

I did **not** modify the instructor's `pizza.topo`. The successful full-transfer tests finished with all bytes acknowledged, zero mismatches, and both connections closed.
