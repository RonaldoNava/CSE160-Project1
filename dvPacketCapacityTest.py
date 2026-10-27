from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    s.loadTopo("dv_ring20.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)

    s.runTime(160)

    print("=== MULTI-PACKET DV TEST ===")

    s.routeDMP(1)
    s.runTime(3)

    s.ping(1, 12, "DV multi packet")
    s.runTime(25)

    print("=== TEST COMPLETE ===")


if __name__ == '__main__':
    main()
