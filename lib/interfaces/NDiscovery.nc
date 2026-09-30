interface NDiscovery {
    command void start();
    command void receive(pack msg, uint16_t source);
    command void printNeighbors();
    command bool isCurrentNeighbor(uint16_t nodeID);
    command uint8_t getNeighborCount();
    command bool getNeighbor(uint8_t index, uint16_t* nodeID, uint8_t* quality, bool* active);
}