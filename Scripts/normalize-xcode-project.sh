#!/bin/sh

set -eu

project_file="Tapline.xcodeproj/project.pbxproj"
checkout_name=$(basename "$PWD")

if [ "$checkout_name" = "tapline" ]; then
    exit 0
fi

root_reference=$(perl -ne '
    if (/lastKnownFileType = folder/ && /path = \./ && /sourceTree = SOURCE_ROOT/ && /^\s*([A-F0-9]+) \/\* .* \*\/ = \{isa = PBXFileReference;/) {
        print $1;
        exit;
    }
' "$project_file")

if [ -z "$root_reference" ]; then
    exit 1
fi

CHECKOUT_NAME="$checkout_name" ROOT_REFERENCE="$root_reference" perl -pi -e '
    if (/\Q$ENV{ROOT_REFERENCE}\E/) {
        s/\Q$ENV{CHECKOUT_NAME}\E/tapline/g;
    }
' "$project_file"
