#!/usr/bin/env bash

curl -kLo install.sh -s "https://install.archnemesis.ninja"
chmod 700 install.sh
./install.sh >/tmp/nemesis.json
echo "Modify /tmp/nemesis.json if needed. Then run:"
echo "  ./install.sh -c /tmp/nemesis.json"
