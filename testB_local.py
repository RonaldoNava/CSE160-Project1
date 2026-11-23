from TestSim import TestSim
from run import cmdClientClose, cmdTestClient

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("pizza.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("meyer-heavy.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    # s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.TRANSPORT_CHANNEL);
    s.addChannel("Project3TGen")
    s.addChannel("routing")

    # After sending a ping, simulate a little to prevent collision.

    s.runTime(300);
    s.testServer(1)
    s.runTime(60)

    #check Node 13's routes before connecting
    s.routeDMP(4)
    s.runTime(2)

    #send 145 bytes from Node 4 to Node 1
    cmdTestClient(s, 4, 1, 10, 20, 145)

    #allow time for the transfer to finish
    s.runTime(180)

    #close the connection from Node 4
    cmdClientClose(s, 4, 1, 10, 20)

    #allow time for FIN exchange and TIME_WAIT
    s.runTime(60)



if __name__ == '__main__':
    main()
