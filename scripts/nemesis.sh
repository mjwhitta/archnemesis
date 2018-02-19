#!/usr/bin/env bash

curl -kL -o install.sh -s "http://install.archnemesis.ninja"
chmod 700 install.sh
./install.sh >nemesis.json
echo "Now run: ./install.sh -c nemesis.json"
