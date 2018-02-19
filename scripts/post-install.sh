#!/usr/bin/env bash

curl -kL -o install.sh -s "http://install.archnemesis.ninja"
chmod 700 install.sh
./install.sh >nemesis.json
./install.sh -c nemesis.json --post-install
