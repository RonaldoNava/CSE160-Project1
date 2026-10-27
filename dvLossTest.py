from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    s.loadTopo("dv_line4.topo")
    s.loadNoise("lossy_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)
    s.addChannel(s.NEIGHBOR_CHANNEL)

    # Allow additional time for lossy discovery and DV updates
    s.runTime(200)

    print("=== LOSSY DV ROUTING TABLES ===")

    s.routeDMP(1)
    s.routeDMP(4)
    s.runTime(5)

    print("=== LOSSY PING TEST ===")

    for i in range(5):
        s.ping(1, 4, "Loss test %d" % i)
        s.runTime(20)

    print("=== LOSS TEST COMPLETE ===")


if __name__ == '__main__':
    main()
