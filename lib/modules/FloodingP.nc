#include "../../includes/packet.h"

module FloodingP{provides interface Flooding;
}

implementation
{

    command void Flooding.start() {}
    command void Flooding.flood(pack msg) {}
    command void Flooding.receive(pack msg) {}
}