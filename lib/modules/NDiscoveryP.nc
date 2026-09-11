#include <Timer.h>
#include "../../includes/channels.h"

module NDiscoveryP {
    uses interface Timer<TMilli> as periodicTimer;

    provides interface NDiscovery;
}

implementation {

    command void NDiscovery.start() {
        call periodicTimer.startPeriodic(5000);
        dbg(NEIGHBOR_CHANNEL, "Neighbor discovery started\n");
    }

    event void periodicTimer.fired() {
        dbg(NEIGHBOR_CHANNEL, "Neighbor discovery timer fired\n");
    }

    command void NDiscovery.printNeighbors() {
    }

    command bool NDiscovery.isCurrentNeighbor(uint16_t nodeID) {
        return FALSE;
    }

    command void NDiscovery.recordNeighbor(uint16_t nodeID) {
    }
}