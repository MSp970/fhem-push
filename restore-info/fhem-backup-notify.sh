#!/bin/bash
MSG="$1"
PHONE="491741536723"
APIKEY="3612010"
curl -s --max-time 20 "https://api.callmebot.com/whatsapp.php?phone=$PHONE&apikey=$APIKEY&text=$(echo "$MSG" | sed 's/ /+/g')" > /dev/null
