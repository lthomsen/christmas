#!/bin/zsh
# Measures CPU used by JuleHygge and WindowServer over N seconds (default 30), as % of one core.
# Usage: ./measure.sh [seconds]   (the newest JuleHygge process is the app; the other is its supervisor)
secs=${1:-30}
cpu() { ps -o time= -p $1 | awk -F'[:.]' '{ if (NF==4) print ($1*3600+$2*60+$3)+$4/100; else print ($1*60+$2)+$3/100 }'; }
app=$(pgrep -x JuleHygge | tail -1); ws=$(pgrep -x WindowServer)
[[ -z $app ]] && { echo "JuleHygge kører ikke"; exit 1; }
a0=$(cpu $app); w0=$(cpu $ws); sleep $secs; a1=$(cpu $app); w1=$(cpu $ws)
echo "JuleHygge:    $(( (a1-a0)*100/secs )) % af én kerne"
echo "WindowServer: $(( (w1-w0)*100/secs )) % af én kerne (inkl. alt andet på skærmen)"
