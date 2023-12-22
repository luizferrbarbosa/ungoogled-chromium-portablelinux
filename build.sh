#!/bin/bash

# directories
# ==================================================
root_dir="$(dirname $(readlink -f $0))"
patches_dir="${root_dir}/patches"
main_repo="${root_dir}/ungoogled-chromium"

build_dir="${root_dir}/build"
download_cache="${build_dir}/download_cache"
src_dir="${build_dir}/src"

# env vars
# ==================================================
export LLVM_VERSION=${LLVM_VERSION:=16}
export AR=${AR:=llvm-ar-${LLVM_VERSION}}
export NM=${NM:=llvm-nm-${LLVM_VERSION}}
export CC=${CC:=clang-${LLVM_VERSION}}
export CXX=${CXX:=clang++-${LLVM_VERSION}}
export LLVM_BIN=${LLVM_BIN:=/usr/lib/llvm-${LLVM_VERSION}/bin}

# clean
# ==================================================
echo "cleaning up directories"
rm -rf "${src_dir}" "${build_dir}/domsubcache.tar.gz"
mkdir -p "${src_dir}/out/Default" "${download_cache}"

## fetch sources
# ==================================================
"${main_repo}/utils/downloads.py" retrieve -i "${main_repo}/downloads.ini" -c "${download_cache}"
"${main_repo}/utils/downloads.py" unpack -i "${main_repo}/downloads.ini" -c "${download_cache}" "${src_dir}"

# prepare sources
# ==================================================
## apply ungoogled-chromium patches
"${main_repo}/utils/prune_binaries.py" "${src_dir}" "${main_repo}/pruning.list"
"${main_repo}/utils/patches.py" apply "${src_dir}" "${main_repo}/patches"
"${main_repo}/utils/domain_substitution.py" apply -r "${main_repo}/domain_regex.list" -f "${main_repo}/domain_substitution.list" -c "${build_dir}/domsubcache.tar.gz" "${src_dir}"

## apply own patches needed for build
cd "${src_dir}"
# revert addition of check for a certain llvm package version (seems to be introduced in chromium 107.xx)
patch -Rp1 -i ${patches_dir}/REVERT-clang-version-check.patch
# hack to disable rust version check (introduced with chromium 115.xx)
patch -Np1 -i ${patches_dir}/rust-version-check.patch
# revert addition of compiler flag that needs newer clang (taken from ungoogled-chromium-archlinux)
patch -Rp1 -i ${patches_dir}/REVERT-disable-autoupgrading-debug-info.patch
# use the --oauth2-client-id= and --oauth2-client-secret= switches for setting GOOGLE_DEFAULT_CLIENT_ID
# and GOOGLE_DEFAULT_CLIENT_SECRET at runtime (taken from ungoogled-chromium-archlinux)
patch -Np1 -i ${patches_dir}/use-oauth2-client-switches-as-default.patch
# Disable kGlobalMediaControlsCastStartStop by default
# https://crbug.com/1314342
patch -Np1 -i ${patches_dir}/disable-GlobalMediaControlsCastStartStop.patch
# fix missing includes in av1_vaapi_video_encoder_delegate.cc
patch -Np1 -i ${patches_dir}/av1_vaapi_video_encoder_delegate.patch
# fix compile error concerning narrowing from/to int/long/unsigned in static initializer (new since latest clang-18 version)
patch -Np1 -i ${patches_dir}/add_casts_in_static_initializers.patch

## Link to system tools required by the build
mkdir -p third_party/node/linux/node-linux-x64/bin && ln -s /usr/bin/node third_party/node/linux/node-linux-x64/bin

### build
# ==================================================
## flags
llvm_resource_dir=$("$CC" --print-resource-dir)
export CXXFLAGS+=" -resource-dir=${llvm_resource_dir} -B${LLVM_BIN}"
export CPPFLAGS+=" -resource-dir=${llvm_resource_dir} -B${LLVM_BIN}"
export CFLAGS+=" -resource-dir=${llvm_resource_dir} -B${LLVM_BIN}"
#
cat "${main_repo}/flags.gn" "${root_dir}/flags.gn" >"${src_dir}/out/Default/args.gn"

# install sysroot if according gn flag is present
if grep -q -F "use_sysroot=true" "${src_dir}/out/Default/args.gn"; then
    # adjust host name to download sysroot files from (see e.g. https://github.com/ungoogled-software/ungoogled-chromium/issues/1846)
    sed -i 's/commondatastorage.9oo91eapis.qjz9zk/commondatastorage.googleapis.com/g' ./build/linux/sysroot_scripts/sysroots.json
    ./build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
fi

## execute build
./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles
./out/Default/gn gen out/Default --fail-on-unused-args

ninja -C out/Default chrome chrome_sandbox chromedriver
