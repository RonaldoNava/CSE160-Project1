from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    s.loadTopo("dv_line4.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)

    s.runTime(80)

    print("=== BEFORE PARTITION ===")
    s.routeDMP(1)
    s.runTime(3)
    s.ping(1, 4, "Before partition")
    s.runTime(12)

    print("=== REMOVING LINK 2-3 ===")
    s.r.remove(2, 3)
    s.r.remove(3, 2)

    # Wait for neighbor expiration, withdrawals, and convergence
    s.runTime(90)

    print("=== AFTER PARTITION ===")
    s.routeDMP(1)
    s.runTime(3)
    s.ping(1, 4, "Disconnected")
    s.runTime(12)

    print("=== RESTORING LINK 2-3 ===")
    s.r.add(2, 3, -54.0)
    s.r.add(3, 2, -54.0)

    s.runTime(90)

    print("=== AFTER RECOVERY ===")
    s.routeDMP(1)
    s.runTime(3)
    s.ping(1, 4, "Recovered")
    s.runTime(15)

    print("=== DV PARTITION TEST COMPLETE ===")


if __name__ == '__main__':
    main()
