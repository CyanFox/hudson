#!/usr/bin/env bash

function check_result {
  if [ "0" -ne "$?" ]
  then
    echo $1
    exit 1
  fi
}

if [ -z "$HOME" ]
then
  echo HOME not in environment, guessing...
  export HOME=$(awk -F: -v v="$USER" '{if ($1==v) print $6}' /etc/passwd)
fi

if [ -z "$WORKSPACE" ]
then
  echo WORKSPACE not specified
  exit 1
fi

CLEAN_TYPE=clean

REPO_BRANCH=ics

if [ -z "$RECOVERY_IMAGE_URL" ]
then
  echo RECOVERY_IMAGE_URL not specified
  exit 1
fi

if [ -z "$SYNC_PROTO" ]
then
  SYNC_PROTO=http
fi

# colorization fix in Jenkins
export CL_PFX="\"\033[34m\""
export CL_INS="\"\033[32m\""
export CL_RST="\"\033[0m\""

cd $WORKSPACE
rm -rf $WORKSPACE/../recovery/archive
mkdir -p $WORKSPACE/../recovery/archive
export BUILD_NO=$BUILD_NUMBER
unset BUILD_NUMBER

export PATH=~/bin:$PATH

export USE_CCACHE=1
export BUILD_WITH_COLORS=0

REPO=$(which repo)
if [ -z "$REPO" ]
then
  mkdir -p ~/bin
  curl https://dl-ssl.google.com/dl/googlesource/git-repo/repo > ~/bin/repo
  chmod a+x ~/bin/repo
fi

git config --global user.name $(whoami)@$NODE_NAME
git config --global user.email jenkins@cyanogenmod.com

mkdir -p $REPO_BRANCH
cd $REPO_BRANCH

rm -rf .repo/manifests*
repo init -u $SYNC_PROTO://github.com/CyanogenMod/android.git -b $REPO_BRANCH
check_result "repo init failed."

# make sure ccache is in PATH
export PATH="$PATH:/opt/local/bin/:$PWD/prebuilt/$(uname|awk '{print tolower($0)}')-x86/ccache"

if [ -f ~/.jenkins_profile ]
then
  . ~/.jenkins_profile
fi

cp $WORKSPACE/hudson/recovery.xml .repo/local_manifest.xml

echo Manifest:
cat .repo/manifests/default.xml

echo Syncing...
# clear all devices from previous builds.
rm -rf device
repo sync -d > /dev/null 2> /tmp/jenkins-sync-errors.txt
check_result "repo sync failed."
echo Sync complete.

. build/envsetup.sh

echo Building unpackbootimg.
lunch generic_armv5-userdebug
make -j32 otatools

UNPACKBOOTIMG=$(ls out/host/**/bin/unpackbootimg)
if [ -z "$UNPACKBOOTIMG" ]
then
  echo unpackbootimg not found
  exit 1
fi

echo Retrieving recovery image.
curl $RECOVERY_IMAGE_URL > /tmp/recovery.img
check_result "Recovery image download failed."

echo Unpacking recovery image.
mkdir -p /tmp/recovery
unpackbootimg -i /tmp/recovery.img -o /tmp/recovery
check_result "unpacking the boot image failed."
pushd .
cd /tmp/recovery
mkdir ramdisk
cd ramdisk
gunzip -c ../recovery.img-ramdisk.gz | cpio -i
check_result "unpacking the boot image failed (gunzip)."
popd

function getprop {
  cat /tmp/recovery/ramdisk/default.prop | grep $1 | cut -d = -f 2
}

MANUFACTURER=$(getprop ro.product.manufacturer)
DEVICE=$(getprop ro.product.device)

if [ -z "$MANUFACTURER" ]
then
  echo ro.product.manufacturer not found
  exit 1
fi

if [ -z "$DEVICE" ]
then
  echo ro.product.device not found
  exit 1
fi

build/tools/device/mkvendor.sh $MANUFACTURER $DEVICE /tmp/recovery.img

lunch cm_$DEVICE-userdebug
check_result "lunch failed."

# save manifest used for build (saving revisions as current HEAD)
repo manifest -o $WORKSPACE/../recovery/archive/manifest.xml -r

if [ ! "$(ccache -s|grep -E 'max cache size'|awk '{print $4}')" = "50.0" ]
then
  ccache -M 50G
fi

make $CLEAN_TYPE
mka recoveryzip recoveryimage
check_result "Build failed."

if [ -f $OUT/utilties/update.zip ]
then
  cp $OUT/utilties/update.zip $WORKSPACE/../recovery/archive/recovery.zip
fi
if [ -f $OUT/recovery.img ]
then
  cp $OUT/recovery.img $WORKSPACE/../recovery/archive
fi

# chmod the files in case UMASK blocks permissions
chmod -R ugo+r $WORKSPACE/../recovery/archive
