configuration NDiscoveryC {
    provides interface NDiscovery;
}

implementation {
    components NDiscoveryP;
    components new TimerMilliC() as myTimerC;

    NDiscovery = NDiscoveryP;
    NDiscoveryP.periodicTimer -> myTimerC;
}