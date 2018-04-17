#!/bin/bash
shopt -s extglob

function include_env() {
    DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    if [ ! -f ${PWD}/dockwrap-env!(.sample) ]; then
        echo "You need to init the environment using 'dockwrap init' in your working directory in order to use this feature" && exit -1
    fi
    source ${PWD}/dockwrap-env!(.sample)
}

function ask_confirmation() {
  echo -n -e "Are you sure you want to $1"
  read -p " [y/n] " -n 1 -r
  echo    # (optional) move to a new line
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
      exit 1
  fi
}

function dns_update() {
  if [ -z "$ZONE" ] || [ -z "$DNS_SERVER" ]; then
      echo "You need to export two environment variables named ZONE and DNS_SERVER in order to dynamically update a DNS server!" && return;
  fi

	NSUPDATE=$(which nsupdate)
	if [ -z "$NSUPDATE" ]; then
		echo "You need to install bind9 and allow-update on 127.0.0.1 for localhost. in order to user the dynamic DNS feature of this script"
	else
	    for DOMAIN in "${SUBDOMAIN[@]}"
        do
          nsupdate << EOF
            server $DNS_SERVER
            update $1 $DOMAIN.$ZONE $2 A $3
            send
EOF
# the tabs in front of the EOF is problematic, do not indent the previous line!
            if [ $? -ne 0 ]; then
              echo "Dynamic DNS update failed, please check that you are allowed to update zone $ZONE on DNS server $DNS_SERVER" 1>&2
              return $?
            fi
        done
	fi
}

function d() {
  if [ -n "$RUN_ON_REMOTE" ]; then
    if [ -n "$DOCKER_REMOTE_DAEMON" ]; then
      docker -H $DOCKER_REMOTE_DAEMON "$@"
    else
      echo "You need to defined the environment variable DOCKER_REMOTE_DAEMON to run remote commands"
      exit 1
    fi
  else
    docker "$@"
  fi
}

# Check if a container is running or has been stopped
function container_state() {
  d inspect --format '{{ .State.Running }}' $CONTAINER_NAME 2>/dev/null
}

# Get a container's IP address
function container_ip_addr() {
  d inspect --format '{{ .NetworkSettings.IPAddress }}' $CONTAINER_NAME 2>/dev/null
}

function container_volumes() {
  d inspect --format '{{ .Volumes }}' $CONTAINER_NAME 2>/dev/null
}

##
# Step 1: build an image and tag it
##
function build_image() {
  include_env
  DOCKER_OPTS="build -t $TAG:$VERSION ."
  d ${DOCKER_OPTS} $@
}

##
# This is a wrapper to enforce a lifecycle for your Dockerized app
# 1. If a container is not running, spawn a new one based on the image your built
# 2. If the container is running, do nothing
# 3. If the container was stopped, start it again
##
function start_container() {
  include_env

  STATE=$(container_state)
  if [[ $STATE == "true" ]]; then
    echo "A container for this app is already running."
    exit 1
  elif [[ $STATE == "false" ]]; then
    echo "There is a stopped container. I'll start it for you."
    DOCKER_OPTS="start $CONTAINER_NAME"
  else
    echo "Spawning a new container from image $TAG:$VERSION"
    DOCKER_OPTS="run -d -t -i --name $CONTAINER_NAME $ADDITIONAL_OPTS $VOLUME_OPTS $TAG:$VERSION $2"
  fi

  CID=$(d ${DOCKER_OPTS})
  [ $? -ne 0 ] && return;

  IP=$(container_ip_addr)
  if [ -n "$ZONE" ]  && [ -n "$SUBDOMAIN" ]; then
      dns_update "delete"
      dns_update "add" "5" "$IP"
      if [ $? -ne 0 ]; then
        echo "Dynamic DNS update failed for $IP."
      else
        echo -n "You can now access "
        for DOMAIN in "${SUBDOMAIN[@]}"
        do
            echo -n -e "\e[1m$DOMAIN.$ZONE\e[0m "
        done
        echo " => $IP - happy testing!"
      fi
  else
      echo -e "The new container got \e[1m$IP\e[0m"
      echo
  fi
  if [[ $1 == "debug" ]]; then
    DOCKER_OPTS="attach $CID"
    d ${DOCKER_OPTS}
  fi
}

function logtail_container() {
  include_env
  STATE=$(container_state)
  if [[ $STATE == "true" ]]; then
    d logs -f -t $CONTAINER_NAME
  elif [[ $STATE == "false" ]]; then
    echo "Container $CONTAINER_NAME is not running."
  fi
}

function stop_container() {
  include_env
  STATE=$(container_state)
  if [[ $STATE == "true" ]]; then
    d stop ${CONTAINER_NAME}
    if [ -n "$ZONE" ]  && [ -n "$SUBDOMAIN" ]; then
      dns_update "delete"
    fi
  fi
}

function commit_container() {
  include_env
	d commit -a ${USER} ${CONTAINER_NAME} ${TAG}:${VERSION}
}

function remove_container() {
  include_env
  ask_confirmation "remove container $CONTAINER_NAME (with all of its data)?"
  d rm -v $1 ${CONTAINER_NAME}
}

function remove_image() {
  include_env
  ask_confirmation "remove image $TAG?"
  d rmi ${TAG}
}

function container_info() {
  include_env
  STATE=$(container_state)
  if [[ $STATE == "true" ]]; then
    IP=$(container_ip_addr)
    VOLUMES=$(container_volumes)
    DNS="$SUBDOMAIN.$ZONE"

    echo "IP address: $IP"
    echo "DNS: $DNS"
    echo "Mounted volumes: $VOLUMES"
    echo "Running processes"
    d top ${CONTAINER_NAME}
  elif [[ $STATE == "false" ]]; then
    echo "Container $CONTAINER_NAME is not running."
    VOLUMES=$(container_volumes)
    echo "Mounted volumes: $VOLUMES"
  else
    echo "You need to spawn a new container from $TAG once before using dockwrap info"
  fi
}

function exec_in_container() {
  include_env
  STATE=$(container_state)
  if [[ $STATE == "true" ]]; then
    if [ -z "$1" ]; then
      ARGS="/bin/bash"
    else
      ARGS=$1
    fi
    d exec -i -t ${CONTAINER_NAME} $ARGS
  else
    echo "The container is not running."
  fi
}

function clean_stopped_containers() {
	ask_confirmation "clean stopped containers? \e[1;31mYou might LOSE IMPORTANT DATA if you did not commit changes\e[0m"
	d rm $(docker ps -aq --no-trunc -f "status=exited") > /dev/null 2>&1
}

function clean_untagged_images() {
  ask_confirmation "clean untagged images (like intermediate images from aborted builds)?"
  d rmi $(docker images -f "dangling=true" -q) > /dev/null 2>&1
}

function init_env() {
if [ -f ${PWD}/dockwrap-env!(.sample) ]; then
  echo "dockwrap-env already exists." && return;
fi

cat > $PWD/dockwrap-env << EOL
#!/bin/bash

## Configuration variables

# This is the Docker tag to use
APP="$(echo $(basename $(dirname $PWD)) | tr '[A-Z]' '[a-z]')"
SERVICE="$(echo $(basename $PWD) |  tr '[A-Z]' '[a-z]')"

TAG="\$APP/\$SERVICE"
VERSION="latest"

# The container name to use
CONTAINER_NAME="\$APP-\$SERVICE"

## Uncomment if you want to enable dynamic DNS updates
# The hostname or IP addres of the DNS server you want to send updates to
# DNS_SERVER="localhost"

# The zone your local bind9 instance has authority for
# ZONE="yourdomain.tld"

# The subdomain to assign when the DNS zone is updated, the final address will be of the form of \$SUBDOMAIN.\$ZONE
# SUBDOMAIN=("subdomain-1", "subdomain-2")

# Volume options
# VOLUME_OPTS="-v path/to/my/source:/var/www"

# Additional docker run options
# ADDITIONAL_OPTS="--link db:db"
# ADDITIONAL_OPTS="--env MY_ENV_VAR=/path/"

if [[ "$(basename -- "$0")" == "dockwrap-env" ]]; then
    echo "Don't run $0, use Dockwrap!" >&2
    exit 1
fi

EOL
}

function install_script() {
    DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    ln -s "$DIR/$0" "/usr/local/bin/dockwrap"
    [ $? -ne 0 ] && echo "Failed to install the dockwrap script in the PATH" && return
    echo "You can now use Dockwrap everywhere!"
}

function show_help() {
cat << EOF
Usage: $0 [--remote] [OPTION]

This script wraps Docker.io commands to build, tag and run an image / container.
It also supports dynamically updating a DNS zone when a new container is spawned (requires nsupdate).

All the commands can be executed on a remote docker daemon, when running with --remote and using
the environment variable DOCKER_REMOTE_DAEMON.

OPTIONS:
  help		Show this message

CORE FUNCTIONS:

  build		Build the image using the Dockerfile in the current directory and tags it
  run		Spawn a new container in detached mode, if a container already exists, start it
  logs		Follow the output of the container's entrypoint process
  stop		Stop the running container
  attach	Spawn a new container with a TTY
  exec		Exec the specified command inside a running container, defaults to /bin/bash
  commit	Commit the named container and tag it as the latest version of the image
  rm		Stop the container then remove it
  rmi		Remove the image
  info		Get the status of the running container, its IP address, and the DNS domain you can use

HELPER FUNCTIONS:

  tidy		Delete stopped containers images and untagged images to regain volume space

EOF
exit 1
}

if [ $# -eq 0 ]
then
	show_help
fi

if [[ $1 == "--remote" ]]; then
  RUN_ON_REMOTE="true"
  shift
fi

for var in "$@"
  do
  case "$1" in
    # Dockwrap specific options
    init)          init_env
                   ;;
    install)       install_script
                   ;;

    # Docker wrapper options
    build)         build_image
                   ;;
    run|start)     start_container $1
                   shift
                   ;;
    stop)          stop_container
                   ;;
    attach|debug)  start_container $1
                   stop_container
                   shift
                   ;;
    shell)         exec_in_container
                   ;;
    exec)          shift
                   exec_in_container $1
                   shift
                   ;;
    commit)        echo "Stopping the running container"
                   stop_container
                   commit_container
                   ;;
    rm|destroy)    remove_container "-f"
                   ;;
    info)          container_info
                   ;;
    tidy|cleanup)  clean_stopped_containers
                   clean_untagged_images
                   ;;
    rmi|remove)    remove_image
                   ;;
    *)             show_help && exit 1
                   ;;
  esac
  shift
done
