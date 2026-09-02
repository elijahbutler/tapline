#!/bin/sh

set -eu

project_file="Tapline.xcodeproj/project.pbxproj"
checkout_name=$(basename "$PWD")

if [ "$checkout_name" = "tapline" ]; then
    exit 0
fi

CHECKOUT_NAME="$checkout_name" perl -0pi -e 's/\Q$ENV{CHECKOUT_NAME}\E/tapline/g' "$project_file"
