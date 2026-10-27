
configuration DVC
{
    provides interface DistanceVector;

    uses interface NDiscovery;
    uses interface SimpleSend as Sender;
}

implementation
{
    components DVP;
    components new TimerMilliC() as DVPeriodicTimer;
    components new TimerMilliC() as DVSendTimer;
    components new TimerMilliC() as DVTriggerTimer;
    components RandomC;

    DistanceVector = DVP.DistanceVector;

    DVP.NDiscovery = NDiscovery;
    DVP.Sender = Sender;

    DVP.periodicTimer->DVPeriodicTimer;
    DVP.sendTimer->DVSendTimer;
    DVP.triggerTimer->DVTriggerTimer;

    DVP.Random->RandomC;
}
