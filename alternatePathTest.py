from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    s.loadTopo("alternate_path.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)

    # Initial convergence
    s.runTime(35)

    print("=== BEFORE FAILURE ===")
    s.routeDMP(1)
    s.runTime(2)

    s.ping(1, 4, "Before failure")
    s.runTime(10)

    # Remove link 2 <-> 4, keeping both nodes on
    print("=== REMOVING LINK 2-4 ===")
    s.r.remove(2, 4)
    s.r.remove(4, 2)

    # Allow ND, LSAs, and Dijkstra to converge
    s.runTime(45)

    print("=== AFTER FAILURE ===")
    s.routeDMP(1)
    s.runTime(2)

    s.ping(1, 4, "After failure")
    s.runTime(12)

    # Restore the original bidirectional link
    print("=== RESTORING LINK 2-4 ===")
    s.r.add(2, 4, -54.0)
    s.r.add(4, 2, -54.0)

    s.runTime(45)

    print("=== AFTER RECOVERY ===")
    s.routeDMP(1)
    s.runTime(2)

    s.ping(1, 4, "After recovery")
    s.runTime(12)

    print("=== TEST COMPLETE ===")


if __name__ == '__main__':
    main()