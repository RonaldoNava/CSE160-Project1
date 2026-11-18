from __future__ import print_function
import re
import sys
from TestSim import TestSim

# Existing CommandMsg uses byte values; command target is the first address.
CMD_TEST_CLIENT=4
CMD_TEST_SERVER=5
CMD_CLIENT_CLOSE=7
CMD_TEST_DROP_DATA=8

def cmdTestServer(s, serverAddress, listenPort):
    s.sendCMD(CMD_TEST_SERVER,serverAddress,chr(listenPort))

def cmdTestClient(s,clientAddress,serverAddress,srcPort,destPort,transferBytes):
    if not 0<transferBytes<=60000: raise ValueError('unsupported transfer size')
    s.sendCMD(CMD_TEST_CLIENT,clientAddress,''.join(chr(v) for v in
              [serverAddress,srcPort,destPort,transferBytes>>8,transferBytes&255]))

def cmdClientClose(s,clientAddress,serverAddress,srcPort,destPort):
    s.sendCMD(CMD_CLIENT_CLOSE,clientAddress,''.join(chr(v) for v in [serverAddress,srcPort,destPort]))

def advance(s,seconds):
    end=s.t.time()+int(seconds*s.t.ticksPerSecond())
    while s.t.time()<end:
        if not s.t.runNextEvent(): raise RuntimeError('No simulation events remain')

def main():
    scenario=sys.argv[1] if len(sys.argv)>1 else 'clean'
    if scenario not in ('clean','loss'): raise SystemExit('Usage: python -u run.py [clean|loss] [bytes]')
    total=int(sys.argv[2]) if len(sys.argv)>2 else 25
    if not 1<=total<=60000: raise SystemExit('Bytes must be 1..60000')
    s=TestSim(); s.t.randomSeed(160)
    s.loadTopo('dv_line4.topo'); s.loadNoise('no_noise.txt'); s.bootAll()
    path='midreview_'+scenario+'.log'
    log=open(path,'w')
    s.addChannel('Project3TGen',log)
    # Warm up routing, then verify ping before starting transport.
    advance(s,90); s.ping(1,4,'midreview'); advance(s,10)
    cmdTestServer(s,4,20); advance(s,2)
    if scenario=='loss': s.sendCMD(CMD_TEST_DROP_DATA,4,'drop'); advance(s,1)
    cmdTestClient(s,1,4,10,20,total)
    # Fixed simulated schedule: allow time for handshake, retries and transfer.
    advance(s, max(30, 20+((total+10)//11)*4))
    cmdClientClose(s,1,4,10,20); advance(s,45)
    log.flush()
    with open(path,'r') as source: output=source.read()
    print('\n=== PROJECT 3 MID-REVIEW: '+scenario+' ===')
    print(output)
    # Compare receiver length with the driver's expected length, not just pattern.
    finals=re.findall(r'node=(\d+) fd=(\d+) APP_FINAL result=(\w+) accepted=(\d+) acked=(\d+) consumed=(\d+) mismatches=(\d+)',output)
    client=any(n=='1' and status=='OK' and int(a)==total and int(k)==total for n,fd,status,a,k,c,m in finals)
    server=any(n=='4' and status=='OK' and int(c)==total and int(m)==0 for n,fd,status,a,k,c,m in finals)
    ping='node=1 PING_REPLY from=4' in output
    loss=(scenario=='clean' or ('TEST_DROP' in output and 'DATA_RETX' in output))
    print('Expected bytes: %d | routing: %s | client: %s | receiver: %s | loss recovery: %s' % (total,ping,client,server,loss))
    passed=ping and client and server and loss
    print('RESULT: '+('PASS' if passed else 'FAIL'))
    print('Log: '+path)
    return 0 if passed else 1

if __name__=='__main__': sys.exit(main())
