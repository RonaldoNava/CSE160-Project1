configuration NDiscoveryC {
    provides interface NDiscovery;
    uses interface SimpleSend as Sender;
}

implementation {
    components NDiscoveryP;
    components new TimerMilliC() as myTimerC;

    NDiscovery = NDiscoveryP;
    NDiscoveryP.periodicTimer -> myTimerC;
    NDiscoveryP.Sender = Sender;
}