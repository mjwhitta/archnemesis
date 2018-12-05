#!/usr/bin/env bash

curl -kL -o install.sh -s "https://install.archnemesis.ninja"
chmod 700 install.sh
./install.sh | sed -r "s/(\"gui\": \")true(\")/\1false\2/" \
    >/tmp/cli.json
echo "Now run: ./install.sh -c /tmp/cli.json"
