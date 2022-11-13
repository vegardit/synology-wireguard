#!/bin/bash
if [ -z ${IS_IN_CONTAINER+x} ]; then
    echo "This script expect to be run inside a docker container" 1>&2
    exit 1
fi

if [ -z ${PACKAGE_ARCH+x} ]; then
    echo "PACKAGE_ARCH is undefined. Please find and set you package arch:" 1>&2
    echo "https://www.synology.com/en-global/knowledgebase/DSM/tutorial/Compatibility_Peripherals/What_kind_of_CPU_does_my_NAS_have" 1>&2
    exit 2
fi

if [ -z ${DSM_VER+x} ]; then
    echo "DSM_VER is undefined. This should a version number like 6.2" 1>&2
    exit 3
fi

# Ensure that we are working directly in the root file system. Though this
# should always be the case in containers.
cd /

# Make the script quit if there are errors
set -e

export WIREGUARD_VERSION=$(wget -q https://git.zx2c4.com/wireguard-linux-compat/refs/ -O - | grep -oP '\/wireguard-linux-compat\/tag\/\?h=v\K[.0-9]*' | head -n 1)
export WIREGUARD_TOOLS_VERSION=$(wget -q https://git.zx2c4.com/wireguard-tools/refs/ -O - | grep -oP '\/wireguard-tools\/tag\/\?h=v\K[.0-9]*' | head -n 1)
export LIBMNL_VERSION=$(wget -q 'https://netfilter.org/projects/libmnl/files/?C=M;O=D' -O - | grep -oP 'a href="libmnl-\K[0-9.]*' | head -n 1 | sed 's/.\{1\}$//')

echo "WireGuard version:        $WIREGUARD_VERSION"
echo "WireGuard tools version:  $WIREGUARD_TOOLS_VERSION"
echo "libmnl version:           $LIBMNL_VERSION"
echo

# Fetch Synology toolchain
if [[ ! -d /pkgscripts-ng ]] || [ -z "$(ls -A /pkgscripts-ng)" ]; then
    clone_args=""
    # If the DSM version is 7.0, use the DSM7.0 branch of pkgscripts-ng
    if [[ "$DSM_VER" =~ ^7\.[0-9]+$ ]]; then
        clone_args="-b DSM${DSM_VER}"
        export PRODUCT="DSM"
    fi
    git clone ${clone_args} https://github.com/SynologyOpenSource/pkgscripts-ng
else
    echo "Existing pkgscripts-ng repo found. Pulling latest from origin."
    cd /pkgscripts-ng
    git pull origin
    cd /
fi

# Configure the package according to the DSM version
if [[ "$DSM_VER" =~ ^7\.[0-9]+$ ]]; then
    os_min_ver="7.0-40000"
    pkgscripts_args=""

    # Synology has added a strict requirement on DSM 7.0 to prevent packages
    # not signed by Synology from running with root privileges.
    # Change the permission to run the package to lower in order
    # to successfully install the package.
    run_as="package"

    # For Virtual DSM 7.0 (vkmx64) the wireguard kernel module
    # requires a spinlock implementation patch
    if [[ "$PACKAGE_ARCH" =~ ^(kvmx64)$ ]]; then
        export APPLY_SPINLOCK_PATCH=1
    fi
else
    os_min_ver="6.0-5941"
    run_as="root"
    pkgscripts_args="-S"
fi

package_dir=`dirname $0`
cp -p "$package_dir/template/INFO.sh" "$package_dir/INFO.sh" && sed -i "s/OS_MIN_VER/$os_min_ver/" "$package_dir/INFO.sh"
cp -p "$package_dir/template/conf/privilege" "$package_dir/conf/privilege" && sed -i "s/RUN_AS/$run_as/" "$package_dir/conf/privilege"
cp -p "$package_dir/template/SynoBuildConf/depends" "$package_dir/SynoBuildConf/depends" && sed -i "s/DSM_VER/$DSM_VER/" "$package_dir/SynoBuildConf/depends"

# Install the toolchain for the given package arch and DSM version
build_env="/build_env/ds.$PACKAGE_ARCH-$DSM_VER"

if [ ! -d "$build_env" ]; then
    if [ -f "/toolkit_tarballs/base_env-$DSM_VER.txz" ] && [ -f "/toolkit_tarballs/ds.$PACKAGE_ARCH-$DSM_VER.env.txz" ] && [ -f "/toolkit_tarballs/ds.$PACKAGE_ARCH-$DSM_VER.dev.txz" ]; then
        pkgscripts-ng/EnvDeploy -p $PACKAGE_ARCH -v $DSM_VER -t /toolkit_tarballs
    else
        pkgscripts-ng/EnvDeploy -p $PACKAGE_ARCH -v $DSM_VER
    fi

    # Ensure the installed toolchain has support for CA signed certificates.
    # Without this wget on https:// will fail
    cp /etc/ssl/certs/ca-certificates.crt "$build_env/etc/ssl/certs/"

    # workaround for https://github.com/runfalk/synology-wireguard/issues/109
    # Add patched version of DST Root CA X3 certificate https://crt.sh/?d=8395
    cat <<EOF >> "$build_env/etc/ssl/certs/ca-certificates.crt"
-----BEGIN CERTIFICATE-----
MIIDSjCCAjKgAwIBAgIQRK+wgNajJ7qJMDmGLvhAazANBgkqhkiG9w0BAQUFADA/
MSQwIgYDVQQKExtEaWdpdGFsIFNpZ25hdHVyZSBUcnVzdCBDby4xFzAVBgNVBAMT
DkRTVCBSb290IENBIFgzMB4XDTAwMDkzMDIxMTIxOVoXDTI0MDkzMDE4MTQwM1ow
PzEkMCIGA1UEChMbRGlnaXRhbCBTaWduYXR1cmUgVHJ1c3QgQ28uMRcwFQYDVQQD
Ew5EU1QgUm9vdCBDQSBYMzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
AN+v6ZdQCINXtMxiZfaQguzH0yxrMMpb7NnDfcdAwRgUi+DoM3ZJKuM/IUmTrE4O
rz5Iy2Xu/NMhD2XSKtkyj4zl93ewEnu1lcCJo6m67XMuegwGMoOifooUMM0RoOEq
OLl5CjH9UL2AZd+3UWODyOKIYepLYYHsUmu5ouJLGiifSKOeDNoJjj4XLh7dIN9b
xiqKqy69cK3FCxolkHRyxXtqqzTWMIn/5WgTe1QLyNau7Fqckh49ZLOMxt+/yUFw
7BZy1SbsOFU5Q9D8/RhcQPGX69Wam40dutolucbY38EVAjqr2m7xPi71XAicPNaD
aeQQmxkqtilX4+U9m5/wAl0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNV
HQ8BAf8EBAMCAQYwHQYDVR0OBBYEFMSnsaR7LHH62+FLkHX/xBVghYkQMA0GCSqG
SIb3DQEBBQUAA4IBAQCjGiybFwBcqR7uKGY3Or+Dxz9LwwmglSBd49lZRNI+DT69
ikugdB/OEIKcdBodfpga3csTS7MgROSR6cz8faXbauX+5v3gTt23ADq1cEmv8uXr
AvHRAosZy5Q6XkjEGB5YGV8eAlrwDPGxrancWYaLbumR9YbK+rlmM6pZW87ipxZz
R8srzJmwN0jP41ZL9c8PDHIyh8bwRLtTcm1D9SZImlJnt1ir/md2cXjbDaJWFBM5
JDGFoqgCWjBH4d1QB7wCCZAA62RjYJsWvIjJEubSfZGL+T0yjWW06XyxV3bqxbYo
Ob8VZRzI9neWagqNdwvYkQsEjgfbKbYK7p2CNTUQ
-----END CERTIFICATE-----
EOF
fi

# Patch WireGuard to use its own included memneq implementation if architecture
# does not have built in memneq support.
if [ -z ${APPLY_MEMNEQ_PATCH+x} ]; then
  source "/pkgscripts-ng/include/platform.$PACKAGE_ARCH"
  if [ ! -z ${ToolChainSysRoot64} ]; then
    ToolChainSysRoot="$ToolChainSysRoot64"
  elif [ ! -z ${ToolChainSysRoot32} ]; then
    ToolChainSysRoot="$ToolChainSysRoot32"
  fi
  if ! grep -q "int crypto_memneq" "$build_env/$ToolChainSysRoot/usr/lib/modules/DSM-$DSM_VER/build/include/crypto/algapi.h"; then
    export APPLY_MEMNEQ_PATCH=1
  elif grep -q "#if defined(CONFIG_SYNO_BACKPORT_ARM_CRYPTO)" "$build_env/$ToolChainSysRoot/usr/lib/modules/DSM-$DSM_VER/build/include/crypto/algapi.h" && \
  ! grep -qx "CONFIG_SYNO_BACKPORT_ARM_CRYPTO=y" "$build_env/$ToolChainSysRoot/usr/lib/modules/DSM-$DSM_VER/build/.config"; then
    export APPLY_MEMNEQ_PATCH=1
  fi
fi

# Disable quit if errors to allow printing of logfiles
set +e

# Build packages
#   -p              package arch
#   -v              DSM version
#   -S              no signing
#   --build-opt=-J  prevent parallel building (required)
#   --print-log     save build logs
#   -c WireGuard    project path in /source
pkgscripts-ng/PkgCreate.py \
    -p $PACKAGE_ARCH \
    -v $DSM_VER \
    ${pkgscripts_args} \
    --build-opt=-J \
    --print-log \
    -c WireGuard

# Save package builder exit code. This allows us to print the logfiles and give
# a non-zero exit code on errors.
pkg_status=$?

# Clean up the build environment
rm "$package_dir/INFO.sh" "$package_dir/conf/privilege" "$package_dir/SynoBuildConf/depends"

echo "Build log"
echo "========="
cat "$build_env/logs.build"
echo

echo "Install log"
echo "==========="
cat "$build_env/logs.install"
echo

exit $pkg_status
