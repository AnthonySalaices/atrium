#!/usr/bin/env bash
# Put a line of text on a panel inside the headset.
#   tools/say.sh "look at the top row"
exec curl -s -X POST --data-binary "$*" http://127.0.0.1:7572/api/say
