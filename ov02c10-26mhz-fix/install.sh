#!/bin/bash
# Install patched ov02c10 driver with 26 MHz clock support via DKMS
# For Samsung Galaxy Book 3/4 with Raptor Lake IPU6 (26 MHz external clock)
#
# This driver is loaded *instead of* the in-tree ov02c10 module. For that
# override to actually take effect on the next boot, three things have to be
# true, and this installer now checks all of them explicitly:
#   1. The module builds against the running kernel's headers.
#   2. The DKMS .ko lands in /lib/modules/$(uname -r)/updates/ and wins depmod.
#   3. Under Secure Boot the module is signed with an *enrolled* MOK key —
#      otherwise the kernel silently rejects it and falls back to the signed
#      in-tree driver, which still rejects the 26 MHz clock (issue #54).

set -e

DKMS_NAME="ov02c10"
DKMS_VERSION="1.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash install.sh"
    exit 1
fi

# ── Package manager detection ───────────────────────────────────────────────
if command -v apt >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
else
    PKG_MGR=""
fi

# ── dkms ────────────────────────────────────────────────────────────────────
if ! command -v dkms >/dev/null 2>&1; then
    echo "dkms is not installed. Installing..."
    case "$PKG_MGR" in
        apt) apt install -y dkms ;;
        dnf) dnf install -y dkms ;;
        *)   echo "Error: Could not install dkms. Please install it manually."; exit 1 ;;
    esac
fi

# ── Kernel headers ──────────────────────────────────────────────────────────
# Without headers for the *running* kernel the DKMS build fails and the stock
# driver keeps loading. On Ubuntu/Zorin a freshly-installed HWE/mainline kernel
# sometimes has no matching linux-headers-$(uname -r); fall back to the generic
# metapackage so a later kernel still gets the module auto-rebuilt.
if [ ! -d "/lib/modules/${KVER}/build" ]; then
    echo "Kernel headers for ${KVER} not found. Installing..."
    case "$PKG_MGR" in
        apt)
            apt install -y "linux-headers-${KVER}" 2>/dev/null \
                || apt install -y linux-headers-generic 2>/dev/null || true
            ;;
        dnf)
            dnf install -y "kernel-devel-${KVER}" 2>/dev/null \
                || dnf install -y kernel-devel 2>/dev/null || true
            ;;
        *)
            echo "Error: Could not install kernel headers. Please install them manually."
            exit 1
            ;;
    esac
    if [ ! -d "/lib/modules/${KVER}/build" ]; then
        echo ""
        echo "ERROR: Kernel headers for ${KVER} are still missing."
        echo "       The DKMS module cannot be built without them. Install the"
        echo "       headers package that matches \`uname -r\` and re-run this script."
        exit 1
    fi
fi

# ── Clean up stale clk_freq modprobe.d entries ──────────────────────────────
# Older community workarounds (and earlier revisions of this fix) tried to pass
# `options ov02c10 clk_freq=...`. This driver has no such module parameter, so
# the kernel logs the harmless-but-confusing line:
#     ov02c10: unknown parameter 'clk_freq' ignored
# It is NOT the cause of the camera failure, but it muddies diagnosis (issue
# #54), so neutralise it and tell the user.
STALE_FOUND=false
for f in /etc/modprobe.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -Eq '^[[:space:]]*options[[:space:]]+ov02c10\b.*clk_freq' "$f"; then
        cp -a "$f" "${f}.ov02c10-26mhz.bak"
        sed -i -E 's/^([[:space:]]*options[[:space:]]+ov02c10\b.*clk_freq.*)$/# disabled by ov02c10-26mhz-fix (clk_freq is not a valid ov02c10 module parameter): \1/' "$f"
        echo "  Neutralised stale 'clk_freq' option in ${f} (backup: ${f}.ov02c10-26mhz.bak)"
        STALE_FOUND=true
    fi
done
$STALE_FOUND && echo "  (The 'unknown parameter clk_freq ignored' dmesg line will be gone after reboot.)"

# ── Secure Boot: configure DKMS to sign with a MOK key ──────────────────────
# A built-but-unsigned (or signed-but-unenrolled) module is silently rejected
# under Secure Boot, and the kernel then loads the distro-signed in-tree
# ov02c10 — which still rejects the 26 MHz clock. That is exactly the issue
# #54 symptom: "ran the fix, rebooted, still 'external clock 26000000 is not
# supported'". Mirror the proven speaker-fix signing/enrollment flow.
MOK_CERT=""
MOK_KEY=""
SECURE_BOOT=false
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    SECURE_BOOT=true
fi

if $SECURE_BOOT && [ "$PKG_MGR" = "dnf" ]; then
    MOK_KEY="/etc/pki/akmods/private/private_key.priv"
    MOK_CERT="/etc/pki/akmods/certs/public_key.der"
    if [ ! -f "$MOK_KEY" ] || [ ! -f "$MOK_CERT" ]; then
        echo "Generating MOK key for Secure Boot module signing..."
        dnf install -y kmodtool akmods mokutil openssl >/dev/null 2>&1 || true
        kmodgenca -a 2>/dev/null || true
    fi
    if [ -f "$MOK_KEY" ] && [ -f "$MOK_CERT" ]; then
        mkdir -p /etc/dkms/framework.conf.d
        cat > /etc/dkms/framework.conf.d/ov02c10-mok-keys.conf << SIGNEOF
# MOK key for Secure Boot module signing (set up by ov02c10-26mhz-fix)
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
SIGNEOF
    else
        MOK_KEY=""; MOK_CERT=""
    fi
fi

if $SECURE_BOOT && [ "$PKG_MGR" = "apt" ]; then
    if [ -f /var/lib/dkms/mok.key ] && [ -f /var/lib/dkms/mok.pub ]; then
        MOK_KEY="/var/lib/dkms/mok.key";            MOK_CERT="/var/lib/dkms/mok.pub"
    elif [ -f /var/lib/shim-signed/mok/MOK.priv ] && [ -f /var/lib/shim-signed/mok/MOK.der ]; then
        MOK_KEY="/var/lib/shim-signed/mok/MOK.priv"; MOK_CERT="/var/lib/shim-signed/mok/MOK.der"
    else
        echo "No MOK signing key found. Trying to set one up..."
        command -v update-secureboot-policy >/dev/null 2>&1 || apt install -y shim-signed >/dev/null 2>&1 || true
        command -v update-secureboot-policy >/dev/null 2>&1 && update-secureboot-policy --new-key 2>/dev/null || true
        if [ -f /var/lib/shim-signed/mok/MOK.priv ] && [ -f /var/lib/shim-signed/mok/MOK.der ]; then
            MOK_KEY="/var/lib/shim-signed/mok/MOK.priv"; MOK_CERT="/var/lib/shim-signed/mok/MOK.der"
        elif [ -f /var/lib/dkms/mok.key ] && [ -f /var/lib/dkms/mok.pub ]; then
            MOK_KEY="/var/lib/dkms/mok.key";            MOK_CERT="/var/lib/dkms/mok.pub"
        fi
    fi
    if [ -n "$MOK_KEY" ] && [ -n "$MOK_CERT" ]; then
        echo "Configuring DKMS to sign modules with MOK key: $MOK_CERT"
        mkdir -p /etc/dkms/framework.conf.d
        cat > /etc/dkms/framework.conf.d/ov02c10-mok-keys.conf << SIGNEOF
# MOK key for Secure Boot module signing (set up by ov02c10-26mhz-fix)
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
SIGNEOF
    else
        echo ""
        echo "WARNING: Secure Boot is ON but no MOK signing key could be set up."
        echo "         The patched module will build unsigned and the kernel will"
        echo "         reject it, falling back to the in-tree driver (still no"
        echo "         26 MHz support). Either disable Secure Boot in BIOS, or:"
        echo "           sudo apt install shim-signed"
        echo "           sudo update-secureboot-policy --new-key"
        echo "           sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"
        echo "         Then reboot, complete MOK enrollment, and re-run this installer."
        echo ""
    fi
fi

# ── Remove any previous build/source ────────────────────────────────────────
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    echo "Removing existing DKMS module..."
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
fi
rm -rf "${SRC_DIR}"

# ── Copy source ─────────────────────────────────────────────────────────────
echo "Copying source files to ${SRC_DIR}..."
mkdir -p "${SRC_DIR}"
cp "${SCRIPT_DIR}/ov02c10.c"  "${SRC_DIR}/"
cp "${SCRIPT_DIR}/Makefile"   "${SRC_DIR}/"
cp "${SCRIPT_DIR}/dkms.conf"  "${SRC_DIR}/"

# ── Build & install ─────────────────────────────────────────────────────────
echo "Building and installing DKMS module..."
dkms add "${DKMS_NAME}/${DKMS_VERSION}"
if ! dkms build "${DKMS_NAME}/${DKMS_VERSION}"; then
    echo ""
    echo "ERROR: DKMS build failed for ${DKMS_NAME}/${DKMS_VERSION} on kernel ${KVER}."
    MAKELOG="/var/lib/dkms/${DKMS_NAME}/${DKMS_VERSION}/build/make.log"
    if [ -f "$MAKELOG" ]; then
        echo "       Last lines of the build log (${MAKELOG}):"
        tail -n 25 "$MAKELOG" | sed 's/^/         /'
    fi
    echo ""
    echo "       The stock driver is unchanged; the camera will still not work."
    echo "       Most common cause is a kernel-API change vs. this driver copy."
    echo "       Please open/comment on issue #54 with the log above and your"
    echo "       kernel version (uname -r)."
    exit 1
fi
dkms install "${DKMS_NAME}/${DKMS_VERSION}"

# ── Secure Boot: verify signed + enrolled ───────────────────────────────────
if $SECURE_BOOT; then
    MOD_PATH=$(find "/lib/modules/${KVER}" -name "ov02c10.ko*" 2>/dev/null | grep "/updates/" | head -1)
    [ -z "$MOD_PATH" ] && MOD_PATH=$(find "/lib/modules/${KVER}" -name "ov02c10.ko*" 2>/dev/null | head -1)
    if [ -n "$MOD_PATH" ] && ! modinfo "$MOD_PATH" 2>/dev/null | grep -qi "^sig"; then
        echo ""
        echo "WARNING: Secure Boot is on but the module is NOT signed. Rebuilding..."
        dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
        dkms add "${DKMS_NAME}/${DKMS_VERSION}"
        dkms build "${DKMS_NAME}/${DKMS_VERSION}"
        dkms install "${DKMS_NAME}/${DKMS_VERSION}"
        MOD_PATH=$(find "/lib/modules/${KVER}" -name "ov02c10.ko*" 2>/dev/null | grep "/updates/" | head -1)
    fi
    if [ -n "$MOD_PATH" ] && modinfo "$MOD_PATH" 2>/dev/null | grep -qi "^sig"; then
        echo "  ✓ Module is signed for Secure Boot"
    fi

    # Confirm the certificate is actually enrolled — otherwise a correctly
    # signed module is still rejected and the in-tree driver wins.
    MOK_ENROLL_PENDING=false
    LAST_CERT=""
    for CERT in "$MOK_CERT" /var/lib/dkms/mok.pub /var/lib/shim-signed/mok/MOK.der /etc/pki/akmods/certs/public_key.der; do
        [ -n "$CERT" ] && [ -f "$CERT" ] || continue
        if mokutil --test-key "$CERT" 2>/dev/null | grep -q "is already enrolled"; then
            echo "  ✓ MOK signing key is enrolled: $CERT"; MOK_ENROLL_PENDING=false; break
        fi
        FP=$(openssl x509 -in "$CERT" -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//')
        if [ -n "$FP" ] && mokutil --list-new 2>/dev/null | grep -qi "$FP"; then
            echo "  ✓ MOK signing key import is queued (pending reboot): $CERT"; MOK_ENROLL_PENDING=false; break
        fi
        MOK_ENROLL_PENDING=true; LAST_CERT="$CERT"
    done
    if $MOK_ENROLL_PENDING && [ -n "$LAST_CERT" ]; then
        echo ""
        echo "WARNING: Secure Boot is on, but the MOK signing key is NOT enrolled."
        echo "         Until it is, the kernel rejects the patched module and loads"
        echo "         the in-tree driver, so the 26 MHz error will persist."
        echo ""
        echo ">>> Queuing MOK enrollment now. You'll set a one-time password and must"
        echo ">>> re-enter it on the blue MOK Manager screen on the next boot."
        echo ">>> Cert: ${LAST_CERT}"
        echo ""
        if ! mokutil --import "$LAST_CERT"; then
            echo "         Enrollment NOT queued. Retry: sudo mokutil --import ${LAST_CERT}"
        fi
        echo ""
    fi
fi

# ── Make sure the override wins on next boot ────────────────────────────────
echo "Refreshing module dependencies and initramfs..."
depmod -a "${KVER}" || true
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u
elif command -v dracut >/dev/null 2>&1; then
    dracut --force
elif command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P
else
    echo "Warning: could not rebuild initramfs. Reboot may still load the stock driver."
fi

# ── Reload the module now (best effort) ─────────────────────────────────────
echo "Reloading ov02c10 module..."
if lsmod | grep -q "^ov02c10"; then
    rmmod ov02c10 2>/dev/null || echo "Warning: could not unload ov02c10 (in use). Reboot to apply."
fi
modprobe ov02c10 2>/dev/null || true

# ── Final verification: which ov02c10 actually wins? ────────────────────────
echo ""
LOADED_PATH=$(modinfo ov02c10 2>/dev/null | grep "^filename:" | awk '{print $2}')
if echo "$LOADED_PATH" | grep -q "/updates/"; then
    echo "  ✓ Patched DKMS module is the one modprobe resolves: ${LOADED_PATH}"
    if dmesg 2>/dev/null | grep -qi "external clock 26000000 is not supported"; then
        echo "  ℹ dmesg still shows the old 26 MHz rejection from before this install."
        echo "    Reboot, then re-check: dmesg | grep -i ov02c10"
    fi
else
    echo "  ⚠ modprobe still resolves the STOCK module: ${LOADED_PATH:-<not found>}"
    echo "    The patched driver will not take effect. Likely causes:"
    if $SECURE_BOOT; then
        echo "      • Secure Boot rejecting the module (complete MOK enrollment on reboot)"
    fi
    echo "      • A reboot is required for /updates/ to take priority"
    echo "      • Check: mokutil --sb-state ; modinfo ov02c10 | grep filename"
fi

echo ""
echo "Done. Reboot, then verify with:"
echo "  dmesg | grep -i ov02c10        # no 'external clock 26000000 is not supported'"
echo "  modinfo ov02c10 | grep filename # path should contain /updates/"
echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "IMPORTANT — this fix only repairs the kernel SENSOR driver."
echo "It does NOT set up libcamera or the camera relay. On its own,"
echo "'cam -l' will still show no cameras (e.g. Ubuntu/Zorin ship"
echo "libcamera 0.2.0, which has no IPU6 software-ISP pipeline)."
echo ""
echo "After this reboots cleanly, run the full webcam fix to build a"
echo "working libcamera from source and stand up the camera relay:"
echo ""
echo "  cd ${SCRIPT_DIR}/../webcam-fix-libcamera && sudo bash install.sh"
echo "──────────────────────────────────────────────────────────────────────"
echo ""
echo "To uninstall: sudo bash ${SCRIPT_DIR}/uninstall.sh"
