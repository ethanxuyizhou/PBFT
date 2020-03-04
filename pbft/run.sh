#!/bin/sh

set -e -u
client_command="${PBFT_BUILD_DIR}/client/client.exe"
server_command="${PBFT_BUILD_DIR}/server/server.exe"

host_and_ports=""
count=$1
ports=($(shuf -i 4000-5000 -n $1))
for port in ${ports[@]}
do
  host_and_ports+="-host-and-port localhost:$port "
done

me=0

while (( $me < $count ))
do
  eval "${server_command} ${host_and_ports}-me ${me} &"
  let "me+=1"
done

eval "${client_command} ${host_and_ports}-name 1 &"
open "${PBFT_BUILD_DIR}/app/index.html"

trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT
tail -f /dev/null
