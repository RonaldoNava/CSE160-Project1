configuration LSC {
    provides interface LinkState;

    uses interface NDiscovery;
    uses interface Flooding ;
}

implementation{
    components LSP;
    components new TimerMilliC() as RoutingTimerC;
    components new TimerMilliC() as LSATimerC;

    LinkState = LSP.LinkState;

    LSP.NDiscovery = NDiscovery;
    LSP.Flooding = Flooding;

    LSP.routingTimer -> RoutingTimerC;
    LSP.lsaTimer -> LSATimerC;
}