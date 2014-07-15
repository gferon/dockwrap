# Dockwrap
Dockwrap is a small utility written in Bash designed to help you test/run your application in a Docker container.

By default, Docker spawns a new container from an image when you use `docker run`, and you usually have to repeat a lot of commands and know complex arguments if you want to build, run and stop your app while testing it.

Furthermore, Docker randomly assigns IP addresses in the range provided by the bridged interface specified by the `--bridge` parameter, or the CIDR range provided by `--bip`. This means you'll get a new IP each time you start a new container. This tool is able to perform dynamic DNS updates to assign one or multiple sub-domain in a zone to the IP address allocated by Docker. This is very useful for testing purposes. The feature has been tested with the default configuration of Bind9 on Ubuntu. You need the `nsupdate` tool which is provided by the package `nsupdate` on Debian/Ubuntu.

## Installation
Clone the repo or download the file directly with: `wget https://github.com/gferon/dockwrap/blob/master/dockwrap.sh`

## Usage
Usage: dockwrap [--remote] [OPTIONS]

You can chain multiple options, like `dockwrap build destroy run`

All the commands can be executed on a remote docker daemon, when running with `--remote` and using
the environment variable DOCKWRAP_REMOTE_DAEMON. The remote [docker daemon needs to listen on a TCP socket](https://docs.docker.com/articles/basics/#bind-docker-to-another-hostport-or-a-unix-socket) for this feature to work.

### Environment variables
First, you need to run `dockwrap init` in the directory containing your Dockerfile. This will create a sample `dockwrap-env.sh` file which contains all the host-specific settings which are detailed later on this page.
* `TAG` - the tag to use when building the image
* `VERSION` - the version to use along with the tag (Docker defaults to 'latest')
* `CONTAINER_NAME` - the name to assign when spawning a new container from the image, this is used by Dockwrap to enforce a "lifecycle" on your containerized app, you won't be able to spawn multiple instances of your app
* `DNS_SERVER` - the DNS server to use for dynamic updates
* `ZONE` - the DNS zone you have the right to update (usually localhost on a dev machine)
* `SUBDOMAIN` - all the subdomains you want to add on the DNS server
* `VOLUME_OPTS` - this is where you can define the shared folders between the host and the container
* `ADDITIONAL_OPTS` - any kind of additional options you want to pass to `docker run`
* `BROWSE_BASE_URL` - the base URL used when running `dockwrap browse`
* `BROWSE_PATH` - the path of your app for `dockwrap browse`

Don't forget to exclude the `dockwrap-env.sh` file from your git repo is you are multiple users, as all the variables contained in the file are host-specific.

### Core functions
* `build` - Build the image using the Dockerfile in the current directory and tag it
* `start` - Spawn a new container in detached mode with a pseudo-tty. If a container named `CONTAINER_NAME` already exists, start it. If the container permits it (uses CMD and not ENTRYPOINT) you can specify a different command like `dockwrap run /bin/bash`.
* `stop` - Stop the running container
* `debug` - Same as `start` except we `docker attach` after starting the container
* `commit` - Commit the named container and tag it as the latest version of the image
* `destroy` - Stop then remove the running container, this is a destructive operation
* `info` - Get the status of the running container, its IP address, and the DNS domain you can use

### Helper functions
* `tidy` - Delete stopped containers images and untagged images to regain volume space
* `browse` - Open the default browser

## Disclaimer

I know I'm somewhat reinventing the wheel here, but I really wanted an integrated solution I could quickly modify without any kind of external dependencies, except a DNS server.
