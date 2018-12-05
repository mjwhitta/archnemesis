#!/usr/bin/env bash

curl -kL -o install.sh -s "https://install.archnemesis.ninja"
chmod 700 install.sh
./install.sh >/tmp/nemesis.json
./install.sh -c /tmp/nemesis.json --post-install
