#include <Timer.h>

configuration TransportC {
    provides interface Transport;

    uses interface IP;
}

implementation {
    components TransportP;
    components new TimerMilliC() as TransportTimer;
    components RandomC;

    Transport = TransportP.Transport;

    TransportP.IP = IP;

    TransportP.transportTimer -> TransportTimer;
    TransportP.Random -> RandomC;
}