#!/bin/bash

BASEDIR=$(dirname $0)

VGPU="NVIDIA-Linux-x86_64-580.178.05-vgpu-kvm"
GNRL="NVIDIA-Linux-x86_64-580.178.04"

VER_VGPU=`echo ${VGPU} | awk -F- '{print $4}'`
VER_GNRL=`echo ${GNRL} | awk -F- '{print $4}'`
if [ "$(printf '%s\n' "${VER_GNRL}" "${VER_VGPU}" | sort -V | head -n1)" = "${VER_GNRL}" ]; then
    LWR="${GNRL}"
    VER_LWR="${VER_GNRL}"

    HGR="${VGPU}"
    VER_HGR="${VER_VGPU}"

    IS_GNRL_LWR=true
else
    LWR="${VGPU}"
    VER_LWR="${VER_VGPU}"

    HGR="${GNRL}"
    VER_HGR="${VER_GNRL}"

    IS_GNRL_LWR=false
fi

MRGD="NVIDIA-Linux-x86_64-${VER_HGR}-merged"
TARGET="${MRGD}"


# ===== OPTIONS =====
PATCH=false
REPACK=false
CLEAN=true
VERBOSE=false
while [ $# -gt 0 ]
do
    case "$1" in
        -p|--patch)
            PATCH=true
            TARGET="${MRGD}-patched"
            shift
            ;;
        -r|--repack)
            REPACK=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -k|--keep-directories)
            CLEAN=false
            shift
            ;;
        *)
            die "Unknown option $1"
            ;;
    esac
done

# ===== FUNCTIONS =====
die() {
    echo "$@"
    exit 1
}

extract() {
    TDIR="${1%.run}"
    if [ -d ${TDIR} ]; then
        echo "WARNING: skipping extract of ${1} as it seems already extracted in ${TDIR}"
        return
    fi

    [ -e ${1} ] || die "${1} not found in $BASEDIR"

    $REPACK && sh ${1} --lsm > ${TARGET}.lsm
    sh ${1} --extract-only --target ${TDIR}
    echo
}

blobpatch_byte() {
    CHK=$(od -t x1 -A n --skip-bytes=0x${2} --read-bytes=1 "${1}" 2>/dev/null | tr -d ' \n')
    if [ "${CHK^^}" = "${3}" ]; then
        echo -e -n "\x${4}" | dd of=${1} seek=`printf "%d" 0x${2}` bs=1 count=1 conv=notrunc &>/dev/null
    else
        die "blobpatch_byte failed: expected ${3}, got ${CHK^^} at address 0x${2}"
    fi
}
blobpatch() {
    local status=2

    while read addr a b
    do
        if [ -z "${addr}" -o "${addr#\#}" != "${addr}" ]; then
            # skip empty lines and commeted-out lines
            continue
        elif [ "${addr%:}" != "${addr}" -a -n "${a}" -a -n "${b}" ]; then
            blobpatch_byte ${1} ${addr%:} ${a} ${b}
        else
            sum=`sha256sum -b ${1} | awk '{print $1}'`
            if [ "${sum}" = "${addr}" ]; then
                status=$(($status - 1))
            fi
        fi
    done < ${2}

    [ $status -ne 0 ] && die "${2} failed to apply"
}

applypatch() {
    patch -d ${1} -p1 --no-backup-if-mismatch -f -s < "$BASEDIR/patches/${2}"
    return $?
}

# ===== REQUIREMENTS =====
ZSTD=true

if $PATCH; then
    for cmd in cargo patchelf; do
        command -v "$cmd" &> /dev/null || die "$cmd not found"
    done
elif $REPACK; then
    command -v zstd || ZSTD=false
fi

# ===== MERGE =====
extract ${VGPU}.run
extract ${GNRL}.run

printf '\n%s\n' "CREATING MERGED DRIVER"
rm -rf ${MRGD}
mkdir ${MRGD}

echo -n "Moving files..."
cp -rp ${LWR}/. ${MRGD}
rm ${MRGD}/libnvidia-ml.so.${VER_LWR}

cp -rpf ${HGR}/. ${MRGD}
if $IS_GNRL_LWR; then
    for i in .manifest sandboxutils-filelist.json
    do
        cp -pf ${GNRL}/$i ${MRGD}/$i
    done
else
    for i in kernel/{nvidia/{nvidia-sources.Kbuild,nv-kernel.o_binary},conftest.sh} nvidia-bug-report.sh
    do
        cp -pf ${VGPU}/$i ${MRGD}/$i
    done
fi
echo "DONE"

echo -n "Merging .manifest file..."
sed -i "s/^${VER_LWR}$/${VER_HGR}/" ${MRGD}/.manifest
sed -i '/^nvidia .*nvidia-drm/s/  / nvidia-vgpu-vfio /' ${MRGD}/.manifest
diff -u ${VGPU}/.manifest ${GNRL}/.manifest \
| grep -B 1 '^-.* MODULE:\(vgpu\|installer\)$' | grep -v '^--$' \
| sed -e '/^ / s:/:\\/:g' -e 's:^ \(.*\):/\1/ a \\:' -e 's:^-\(.*\):\1\\:' | head -c -2 \
| sed -e ':append' -e '/\\\n\// b found' -e N -e 'b append' -e ':found' -e 's:\\\n/:\n/:' \
> manifest-merge.sed
sed -f manifest-merge.sed -i ${MRGD}/.manifest
sed -i "/libnvidia-ml/{/NATIVE/s/${VER_LWR}/${VER_HGR}/g}" ${MRGD}/.manifest
rm manifest-merge.sed
echo "DONE"

echo -n "Merging sandboxutils-filelist.json file..."
sed -i "0,/libnvidia-ml\.so\.[0-9.]\+/s//libnvidia-ml.so.${VER_HGR}/" ${MRGD}/sandboxutils-filelist.json
cat ${VGPU}/sandboxutils-filelist.json \
| sed -n -e '/"libnvidia-vgpu.so./{x;p;x}' -e 'h' -e '/"libnvidia-vgpu.so./,$p' \
| head -n -1 | sed -z -e 's:\n$:,:' > json-merge.json
JSON_MERGE=$(sed -e 's:$:\\n:' json-merge.json | tr -d '\n')
sed -i ':a;N;$!ba;s|\( *{\n[^\n]*"libcuda\.so\..*$\)|'"${JSON_MERGE}"'\1|' ${MRGD}/sandboxutils-filelist.json
rm json-merge.json

applypatch ${MRGD} disable-nvidia-blob-version-check.patch
echo "${MRGD}: Merged ${LWR} & ${HGR} drivers\n" >> ${MRGD}/pkg-history.txt

echo "DONE"

# ===== UNLOCK =====
if $PATCH; then
    rm -rf ${TARGET}
    cp -rp ${MRGD} ${TARGET}
# rbqvq/vgpu_unlock-rs
    echo -n "Applying unlocker..."
    blobpatch ${MRGD}/kernel/nvidia/nv-kernel.o_binary "$BASEDIR/patches/blob-${VER_VGPU}.diff"
    (cd "$BASEDIR/unlock" && cargo build -rq)
    cp -p "$BASEDIR/unlock/target/release/libvgpu_unlock_rs.so" ${TARGET}
    (cd ${TARGET} && patchelf --add-needed libvgpu_unlock_rs.so nvidia-vgpu{d,-mgr})
    echo 'libvgpu_unlock_rs.so 0755 VGX_LIB NATIVE MODULE:vgpu' >> ${TARGET}/.manifest
    echo "${TARGET}: Added rbqvq/vgpu_unlock-rs patch\n" >> ${MRGD}/pkg-history.txt
    echo "DONE"
fi

# ===== MERGE PATCH =====
echo -n "Integrating blob hooks..."
cp -p "$BASEDIR/patches/nv-hooks.c" ${TARGET}/kernel/nvidia
echo 'NVIDIA_SOURCES += nvidia/nv-hooks.c' >> ${TARGET}/kernel/nvidia/nvidia-sources.Kbuild
echo 'OBJECT_FILES_NON_STANDARD_nv-hooks.o := y' >> ${TARGET}/kernel/nvidia/nvidia.Kbuild
sed -i ${TARGET}/.manifest -e '/^kernel\/nvidia\/i2c_nvswitch.c / a \
kernel/nvidia/nv-hooks.c 0644 KERNEL_MODULE_SRC INHERIT_PATH_DEPTH:1 MODULE:vgpu'

applypatch ${TARGET} setup-vup-hooks.patch
objcopy --add-symbol vup_blob_start=.text:0x0,global,function ${MRGD}/kernel/nvidia/nv-kernel.o_binary ${TARGET}/kernel/nvidia/nv-kernel.o_binary
BLOB_SIZE=$(size -Ax ${TARGET}/kernel/nvidia/nv-kernel.o_binary | awk '$1==".text"{print $2}')
sed -e '/^NVIDIA_CFLAGS += .*BIT_MACROS$/aNVIDIA_CFLAGS += -DBLOB_TEXT_SIZE='"${BLOB_SIZE}" -i ${TARGET}/kernel/nvidia/nvidia.Kbuild
$IS_GNRL_LWR && sed -i "s/^\([[:space:]]*\.versionString = \)NV_VERSION_STRING,/\1\"${VER_GNRL}\",/" ${TARGET}/kernel/nvidia-drm/nvidia-drm.c
blobpatch ${TARGET}/libnvidia-ml.so.${VER_HGR} "$BASEDIR/patches/libnvidia-ml.so.${VER_HGR}.diff"
echo "DONE"

# ===== FINALIZE =====
if $REPACK; then
    $VERBOSE || REPACK_OPTS="--silent"
    [ -e ${TARGET}.lsm ] && REPACK_OPTS="${REPACK_OPTS} --lsm ${TARGET}.lsm"
    [ -e ${TARGET}/pkg-history.txt ] && REPACK_OPTS="${REPACK_OPTS} --pkg-history ${TARGET}/pkg-history.txt"
    $ZSTD && REPACK_OPTS="${REPACK_OPTS} --zstd --embed-decompress $(which zstd)"

    printf '\n%s\n' "CREATING ${TARGET}.run FILE"
    ./${TARGET}/makeself.sh ${REPACK_OPTS} --version-string "${VER_HGR}" --target-os Linux --target-arch x86_64 \
        ${TARGET} ${TARGET}.run \
        "NVIDIA Accelerated Graphics Driver for Linux-x86_64 ${TARGET#NVIDIA-Linux-x86_64-}" \
        ./nvidia-installer -m kernel
    
    rm -f ${TARGET}.lsm
fi

if $CLEAN; then
    printf '\n%s' "Cleaning up..."
    rm -rf ${VGPU} ${GNRL}
    $PATCH && rm -rf ${MRGD}
    $REPACK && rm -rf ${TARGET}
    echo "DONE"
fi
