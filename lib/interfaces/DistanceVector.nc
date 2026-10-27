
#include "../../includes/packet.h"

interface DistanceVector
{
    command void start();

    command void receive(pack msg, uint16_t linkSource);

    command uint16_t getNextHop(uint16_t destination);

    command uint8_t getCost(uint16_t destination);

    command void printRoutingTable();

    event void routeChanged();
}
