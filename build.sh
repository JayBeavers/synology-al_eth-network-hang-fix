#!/bin/sh
# Build src/ into al_eth_fix.ko against Synology's DSM 7.2-72806 alpine kernel, in Docker.
# Usage: ./build.sh [workdir]   (default ./build; the 82 MB kernel source is fetched once)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
W=${1:-$here/build}
SRC=https://global.synologydownload.com/download/ToolChain/Synology%20NAS%20GPL%20Source/7.2-72806/alpine/linux-3.10.x-bsp.txz
mkdir -p "$W"
cd "$W"
[ -f linux-bsp.txz ] || curl -fL -o linux-bsp.txz "$SRC"
[ -d linux-3.10.x-bsp ] || tar -xJf linux-bsp.txz
rm -rf al_eth_fix
cp -R "$here/src" al_eth_fix
docker run --rm -v "$W:/b" -w /b/linux-3.10.x-bsp -e ARCH=arm -e CROSS_COMPILE=arm-linux-gnueabi- debian:bookworm sh -ec '
	apt-get update -qq >/dev/null
	apt-get install -y -qq gcc libc6-dev gcc-arm-linux-gnueabi make bc >/dev/null
	cp synoconfigs/alpine .config
	# DSM 7.2 kernels have module signing on, unlike synoconfigs/alpine; it changes struct module
	sed -i "s/^# CONFIG_MODULE_SIG is not set/CONFIG_MODULE_SIG=y/" .config
	make HOSTCFLAGS=-fcommon olddefconfig >/dev/null
	make -j4 HOSTCFLAGS=-fcommon modules_prepare >/dev/null
	make M=/b/al_eth_fix KBUILD_MODPOST_WARN=1 modules'
ls -l "$W/al_eth_fix/al_eth_fix.ko"
