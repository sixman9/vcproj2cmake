#!/bin/sh -e

# Simple forwarder to the actual Ruby install script,
# mostly for UNIX-based people who tend towards an installation
# via a shell script.


# if the call came via symlink, then use its target instead:
arg="${0}"; [[ -L "${0}" ]] && arg="$(stat -f '%Y' "${0}")"

# now do exactly as chriswaco + LN2 said (minor syntax tweaks by me):
script_location="$(2>/dev/null cd "${arg%/*}" >&2; echo "$(pwd -P)/${arg##*/}")"
script_path="$(dirname "$script_location")"


echo "Welcome to the guided install of vcproj2cmake!"
echo "Will now redirect to Ruby script..."

ruby_bin="$(which ruby)"

if [ -z "${ruby_bin}" ]; then
  echo "ERROR: no Ruby binary found, please install a Ruby package!" 2>&1;
  exit 1
fi

"${ruby_bin}" "${script_path}/install_me_fully_guided.rb"
