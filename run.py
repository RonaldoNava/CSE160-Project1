from __future__ import print_function
import re
import sys
from TestSim import TestSim

# Command IDs from includes/command.h.
CMD_TEST_CLIENT = 4
CMD_TEST_SERVER = 5
CMD_CLIENT_CLOSE = 7
CMD_TEST_DROP_DATA = 8


def cmdTestServer(s, serverAddress, listenPort):
    s.sendCMD(CMD_TEST_SERVER, serverAddress, chr(listenPort))


def cmdTestClient(s, clientAddress, serverAddress, srcPort, destPort, transferBytes):
    if not 0 < transferBytes <= 60000:
        raise ValueError('unsupported transfer size')
    s.sendCMD(CMD_TEST_CLIENT, clientAddress, ''.join(chr(v) for v in
              [serverAddress, srcPort, destPort, transferBytes >> 8, transferBytes & 255]))


def cmdClientClose(s, clientAddress, serverAddress, srcPort, destPort):
    s.sendCMD(CMD_CLIENT_CLOSE, clientAddress,
              ''.join(chr(v) for v in [serverAddress, srcPort, destPort]))


def advance(s, seconds):
    end = s.t.time() + int(seconds * s.t.ticksPerSecond())
    while s.t.time() < end:
        if not s.t.runNextEvent():
            raise RuntimeError('No simulation events remain')


def main():
    scenario = sys.argv[1] if len(sys.argv) > 1 else 'clean'
    if scenario not in ('clean', 'loss', 'zero-window'):
        raise SystemExit('Usage: python -u run.py [clean|loss|zero-window] [bytes]')

    # Zero-window needs more data than the receiver's 128-byte buffer.
    default_bytes = 145 if scenario == 'zero-window' else 25
    total = int(sys.argv[2]) if len(sys.argv) > 2 else default_bytes
    if not 1 <= total <= 60000:
        raise SystemExit('Bytes must be 1..60000')
    if scenario == 'zero-window' and total <= 128:
        raise SystemExit('zero-window needs at least 129 bytes')

    # Port 21 activates a test-only read pause in Node.nc.
    # The normal test server continues to use port 20.
    server_port = 21 if scenario == 'zero-window' else 20

    s = TestSim()
    s.t.randomSeed(160)
    s.loadTopo('dv_line4.topo')
    s.loadNoise('no_noise.txt')
    s.bootAll()

    path = 'project3_' + scenario.replace('-', '_') + '_' + str(total) + '.log'
    log = open(path, 'w')
    s.addChannel('Project3TGen', log)

    # Give routing time to start and check the route with a ping.
    advance(s, 90)
    s.ping(1, 4, 'project3')
    advance(s, 10)

    cmdTestServer(s, 4, server_port)
    advance(s, 2)
    if scenario == 'loss':
        s.sendCMD(CMD_TEST_DROP_DATA, 4, 'drop')
        advance(s, 1)

    cmdTestClient(s, 1, 4, 10, server_port, total)

    # The zero-window demo pauses receiver reads for 25 simulated seconds.
    # Allow enough time for the transfer and retransmissions to finish.
    transfer_time = max(30, 20 + ((total + 10) // 11) * 4)
    if scenario == 'zero-window':
        transfer_time += 30
    advance(s, transfer_time)
    cmdClientClose(s, 1, 4, 10, server_port)
    advance(s, 45)

    log.flush()
    log.close()
    with open(path, 'r') as source:
        output = source.read()

    print('\n=== PROJECT 3: ' + scenario + ' ===')
    if scenario == 'zero-window':
        # Print the useful demo lines instead of every packet.
        for line in output.splitlines():
            if any(word in line for word in (
                    'TEST_READ_PAUSE', 'TEST_READ_RESUME',
                    'wnd=0', 'WINDOW_CHECK', 'ACKED total=',
                    'CLOSE_REQUEST', 'APP_FINAL', 'FAIL')):
                print(line)
    else:
        print(output)

    finals = re.findall(
        r'node=(\d+) fd=(\d+) APP_FINAL result=(\w+) accepted=(\d+) acked=(\d+) consumed=(\d+) mismatches=(\d+)',
        output)
    client = any(n == '1' and status == 'OK' and int(a) == total and int(k) == total
                 for n, fd, status, a, k, c, m in finals)
    server = any(n == '4' and status == 'OK' and int(c) == total and int(m) == 0
                 for n, fd, status, a, k, c, m in finals)
    ping = 'node=1 PING_REPLY from=4' in output
    loss = (scenario != 'loss' or ('TEST_DROP' in output and 'DATA_RETX' in output))

    # For the demo, confirm the buffer filled, the sender checked the
    # closed window, and the receiver eventually resumed reading.
    window_ok = True
    if scenario == 'zero-window':
        pause = re.search(r'TEST_READ_PAUSE', output)
        zero = re.search(r'DATA_RX[^\n]*wnd=0', output)
        check = re.search(r'WINDOW_CHECK_TX peerWnd=0', output)
        resume = re.search(r'TEST_READ_RESUME', output)
        window_ok = bool(pause and zero and check and resume and
                         pause.start() < zero.start() < check.start() < resume.start())

    print('Expected bytes: %d | routing: %s | client: %s | receiver: %s | loss recovery: %s | zero-window demo: %s'
          % (total, ping, client, server, loss, window_ok))
    passed = ping and client and server and loss and window_ok
    print('RESULT: ' + ('PASS' if passed else 'FAIL'))
    print('Log: ' + path)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
