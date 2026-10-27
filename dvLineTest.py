from TestSim import TestSim

def main():
    s = TestSim()

    # Initialize simulation
    s.runTime(1)

    # Load topology and noise model
    s.loadTopo("dv_line4.topo")
    s.loadNoise("no_noise.txt")

    # Boot all four nodes
    s.bootAll()

    # Enable debugging channels
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)

    # Allow Neighbor Discovery and DV to converge
    s.runTime(80)

    print("=== DV LINE AFTER CONVERGENCE ===")

    # Print routing tables for nodes 1 and 4
    s.routeDMP(1)
    s.routeDMP(4)
    s.runTime(3)

    # Test multi-hop IP forwarding
    s.ping(1, 4, "DV line")
    s.runTime(15)

    print("=== DV LINE TEST COMPLETE ===")


if __name__ == '__main__':
    main()
