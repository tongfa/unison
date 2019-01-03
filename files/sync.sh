#!/usr/bin/env bash
#Exit on the error
set -eo pipefail nounset errexit

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

export UNISON_UID=$(id -u)
export UNISON_GID=$(id -g)
log_heading "Setting up HOME for user uid ${UNISON_UID}."
sudo chown -R ${UNISON_UID}:${UNISON_GID} ${HOME} ${SYNC_DESTINATION}

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

# Create non-root user
if [[ "$UNISON_USER" != "root" ]]; then
  log_heading "Preparing to run as non-root user."
  log_heading "Setting up /home/${UNISON_USER}"
  HOME="/home/${UNISON_USER}"

  # Create group, if it does not exist
  if ! grep -q "$UNISON_GROUP" /etc/group; then
      log_info "Creating group $UNISON_GROUP"
      addgroup -g "$UNISON_GID" -S "$UNISON_GROUP"
  fi

  # Create user, if it does not exist
  if ! grep -q "$UNISON_USER" /etc/passwd; then
      log_info "Creating user $UNISON_USER (UID=$UNISON_UID,GID=$UNISON_GID)"
      adduser -u "$UNISON_UID" -D -S -G "$UNISON_GROUP" "$UNISON_USER" -s "$SHELL"
  fi

  # Create unison directory
  log_info "Creating ${HOME}/.unison"
  mkdir -p "${HOME}/.unison" || true

  # Own the home directory
  log_info "Applying user permissions to ${HOME}"
  chown -R "${UNISON_USER}:${UNISON_GROUP}" "${HOME}"
  log_info "Applying user permissions to destination"
  chown -R "${UNISON_USER}:${UNISON_GROUP}" "${SYNC_DESTINATION}"
fi

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

# # If bg-sync runs with this environment variable set, we'll try to set the config
# # appropriately, but there's not much we can do if we're not allowed to do that.
# log_heading "Attempting to set maximum inotify watches to $SYNC_MAX_INOTIFY_WATCHES"
# log_info "If the container exits with 'Operation not allowed', make sure that"
# log_info "the container is running in privileged mode."
# if [[ -z "$(sysctl -p)" ]]; then
#     printf "fs.inotify.max_user_watches=$SYNC_MAX_INOTIFY_WATCHES\n" | tee -a /etc/sysctl.conf && 
#       sysctl -p
# else
#     log_info "Looks like /etc/sysctl.conf already has fs.inotify.max_user_watches defined."
#     log_info "Skipping this step."
# fi

log_heading "Calculating number of files in $SYNC_SOURCE in the background"
log_info "in order to set fs.inotify.max_user_watches"
sudo sysctl -w fs.inotify.max_user_watches=${SYNC_MAX_INOTIFY_WATCHES:-20000}
/set_max_user_watches.sh ${SYNC_SOURCE} 2>&1 >/dev/stdout &

if [ -z "$(ls -A $SYNC_DESTINATION)" ]; then
  log_heading "SYNC_DESTINATION was empty so performing initial rsync from SYNC_SOURCE=${SYNC_SOURCE} to SYNC_DESTINATION=${SYNC_DESTINATION}"
  rsync -a "${SYNC_SOURCE}/" "${SYNC_DESTINATION}/"
  log_heading "initial rsync from ${SYNC_SOURCE} to ${SYNC_DESTINATION} is complete"
fi

# Generate a unison profile so that we don't have a million options being passed
# to the unison command.
log_heading "Generating Unison profile"
mkdir -p "${HOME}/.unison"

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
prefer=$SYNC_PREFER
repeat=watch
# DO NOT BE SILENT. That's how we know what Unison is doing
silent = false
logfile=/dev/stdout

# Files to ignore
ignore = Name *___jb_tmp___*
ignore = Name {.*,*}.sw[pon]

# Additional user configuration
$SYNC_EXTRA_UNISON_PROFILE_OPTS

" > ${HOME}/.unison/default.prf

log_heading "Profile:"
cat ${HOME}/.unison/default.prf

# Start syncing files.
log_heading "Starting unison continuous sync."

exec unison -numericids default
