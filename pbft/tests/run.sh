#!/bin/sh

build_dir="~/Desktop/project/ocaml/_build"
~/Desktop/project/ocaml/_build/default/pbft/src/server/server.exe -ports 5000 -ports 6000 -ports 7000 -ports 8000 -me 0 &
~/Desktop/project/ocaml/_build/default/pbft/src/server/server.exe -ports 5000 -ports 6000 -ports 7000 -ports 8000 -me 1 &
~/Desktop/project/ocaml/_build/default/pbft/src/server/server.exe -ports 5000 -ports 6000 -ports 7000 -ports 8000 -me 2 &
~/Desktop/project/ocaml/_build/default/pbft/src/server/server.exe -ports 5000 -ports 6000 -ports 7000 -ports 8000 -me 3 &
