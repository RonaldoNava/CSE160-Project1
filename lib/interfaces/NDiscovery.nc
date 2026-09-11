interface NDiscovery {
    command void start();
    command void printNeighbors();
    command bool isCurrentNeighbor(uint16_t nodeID);
    command void recordNeighbor(uint16_t nodeID);
}