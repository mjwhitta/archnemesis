#!/usr/bin/env bash

curl -kLo install.sh -s "https://install.archnemesis.ninja"
chmod 700 install.sh
./install.sh | sed -r "s/(\"gui\": \")true(\")/\1false\2/" \
    >/tmp/cli.json
echo "Modify /tmp/cli.json if needed. Then run:"
echo "  ./install.sh -c /tmp/cli.json"
