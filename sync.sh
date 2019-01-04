#!/usr/bin/env bash

# Exit on the error
set -eo pipefail

# Log output formatters
log_heading() {
  echo ""
  echo "==> $*"
}

log_info() {
  echo "-----> $*"
}

log_error_exit() {
  echo " !  Error:"
  echo " !     $*"
  echo " !     Aborting!"
  exit 1
}

#
# Set defaults for all variables that we depend on (if they aren't already set in env).
#

# The source for the sync. This will also be recursively monitored by inotifywatch.
: "${SYNC_SOURCE:="/source"}"

# The destination for sync. When files are changed in the source, they are automatically
# synced to the destination.
: "${SYNC_DESTINATION:="/destination"}"

# The preferred approach to deal with conflicts
: "${SYNC_PREFER:=$SYNC_SOURCE}"

# If set, there will be more verbose log output from various commands that are
# run by this script.
: "${SYNC_VERBOSE:="0"}"

# If set, this script will attempt to increase the inotify limit accordingly.
# This option REQUIRES that the container be run as a privileged container.
: "${SYNC_MAX_INOTIFY_WATCHES:=""}"

# This variable will be appended to the end of the Unison profile.
: "${SYNC_EXTRA_UNISON_PROFILE_OPTS:=""}"

# If set, the source will allow files to be deleted.
: "${SYNC_NODELETE_SOURCE:="1"}"

### --------------------- RUNTIME --------------------- ###

# note we deal with uid, gid directly instead of their names for several reasons:
# 1). Alpine Linux native user management only supports up to 256000, and some users
#     report id's much higher than that.
# 2). The mapping of names and ids may be different on this container versus the host
#     or versus other containers.  Its simpler to just do things by id.
# 3). There are edge case complications when specifying existing user or group names
#     and also their ID's, since the system already assigned an ID for these names.
# 4). It's possible to do things by id without having user accounts, eliminating the need
#     for user management.

# Own the destination directory
log_info "Applying user permissions to destination ${UNISON_UID}:${UNISON_GID}"
chown -R "${UNISON_UID}:${UNISON_GID}" "${SYNC_DESTINATION}"

log_heading "Starting bg-sync"

# Dump the configuration to the log to aid bug reports.
log_heading "Configuration:"
log_info "SYNC_SOURCE:                  $SYNC_SOURCE"
log_info "SYNC_DESTINATION:             $SYNC_DESTINATION"
log_info "SYNC_VERBOSE:                 $SYNC_VERBOSE"
if [[ -n "${SYNC_MAX_INOTIFY_WATCHES}" ]]; then
  log_info "SYNC_MAX_INOTIFY_WATCHES:     $SYNC_MAX_INOTIFY_WATCHES"
fi

# Validate values as much as possible.
[[ -d "$SYNC_SOURCE" ]] || log_error_exit "Source directory '$SYNC_SOURCE' does not exist!"
[[ -d "$SYNC_DESTINATION" ]] || log_error_exit "Destination directory '$SYNC_DESTINATION' does not exist!"
[[ "$SYNC_SOURCE" != "$SYNC_DESTINATION" ]] || log_error_exit "Source and destination must be different directories!"

# If SYNC_EXTRA_UNISON_PROFILE_OPTS is set, you're voiding the warranty.
if [[ -n "$SYNC_EXTRA_UNISON_PROFILE_OPTS" ]]; then
  log_info ""
  log_info "IMPORTANT:"
  log_info ""
  log_info "You have added additional options to the Unison profile. The capability of doing"
  log_info "so is supported, but the results of what Unison might do are *not*."
  log_info ""
  log_info "Proceed at your own risk."
  log_info ""
fi

# If verbose mode is off, add the --quiet option to rsync calls.
if [[ "$SYNC_VERBOSE" == "0" ]]; then
  SYNC_RSYNC_ARGS="$SYNC_RSYNC_ARGS --quiet"
fi

# If bg-sync runs with this environment variable set, we'll try to set the config
# appropriately, but there's not much we can do if we're not allowed to do that.
log_heading "Attempting to set maximum inotify watches to $SYNC_MAX_INOTIFY_WATCHES"
log_info "If the container exits with 'Operation not allowed', make sure that"
log_info "the container is running in privileged mode."
if [[ -z "$(sysctl -p)" ]]; then
    printf "fs.inotify.max_user_watches=$SYNC_MAX_INOTIFY_WATCHES\n" | tee -a /etc/sysctl.conf && 
      sysctl -p
else
    log_info "Looks like /etc/sysctl.conf already has fs.inotify.max_user_watches defined."
    log_info "Skipping this step."
fi

# Generate a unison profile so that we don't have a million options being passed
# to the unison command.
log_heading "Generating Unison profile"

# unison reads environment variable UNISON for it's "home".
export UNISON=/unison
mkdir -p ${UNISON}
chown "${UNISON_UID}:${UNISON_GID}" ${UNISON}

unisonsilent="false"

nodelete=""
if [[ "$SYNC_NODELETE_SOURCE" == "1" ]]; then
  nodelete="nodeletion=$SYNC_SOURCE"
fi

prefer="$SYNC_SOURCE"
if [[ -z "${SYNC_PREFER}" ]]; then
  prefer="${SYNC_PREFER}"
fi

echo "
root = $SYNC_SOURCE
root = $SYNC_DESTINATION

# Sync options

# automatically accept default (nonconflicting) actions
auto = true
# keep backup copies of all files
backups = false
# batch mode: ask no questions at all
batch = true
# suppress the 'contacting server' message during startup
contactquietly = true
# do fast update detection (true/false/default)
fastcheck = true
# lof file location
log = false
# logfile=/tmp/unison.log

maxthreads = 10
$nodelete
# Set preferred source during conflicts
prefer = $SYNC_PREFER
repeat = watch
# DO NOT BE SILENT. That's how we know what Unison is doing
silent = false

# Files to ignore
ignore = Name *___jb_tmp___*
ignore = Name {.*,*}.sw[pon]

# Additional user configuration
$SYNC_EXTRA_UNISON_PROFILE_OPTS

" > ${UNISON}/default.prf

log_heading "Profile:"
cat ${UNISON}/default.prf

# Start syncing files.
log_heading "Starting continuous sync."

if [[ "$UNISON_UID" != "0" ]]; then
  # note that running with the specified uid,gid has the desirable side effect
  #  of "squashing" the uid,gid in the source when writing files into the destination.
  su-exec ${UNISON_UID}:${UNISON_GID} unison default
else
  # note that gid,uid get squashed to 0,0 in this case in SYNC_DESTINATION.
  unison default
fi
