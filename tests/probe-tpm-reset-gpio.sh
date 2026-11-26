#!/usr/bin/env bash
# Run ON THE PI: find whether the TPM's RST# line is wired to a GPIO.
# For each free GPIO: save its state, pulse it low 10 ms, restore it, then ask the TPM for random
# bytes. A reset TPM refuses everything with TPM_RC_INITIALIZE (0x100) until TPM2_Startup.
# Skips GPIO 0/1 (HAT ID EEPROM), 2/3 (I2C), 7-11 (SPI0 + TPM), 14/15 (UART console).
set -u
CANDIDATES=${*:-"4 5 6 12 13 16 17 18 19 20 21 22 23 24 25 26 27"}

tpm_ok() { tpm2_getrandom --hex 4 >/dev/null 2>&1; }

if ! tpm_ok; then
    echo "TPM not answering before the probe; run tpm2_startup -c first"; exit 1
fi

for g in $CANDIDATES; do
    before=$(pinctrl get "$g")
    pinctrl set "$g" op dl; sleep 0.01
    pinctrl set "$g" op dh; sleep 0.05
    # restore function/pull as it was (most free pins are inputs with a pull)
    func=$(echo "$before" | awk '{print $2}'); pull=$(echo "$before" | awk '{print $3}')
    case $func in
        ip) [ "$pull" = "--" ] && pull=pn; pinctrl set "$g" ip "${pull:-pn}" ;;
        op) level=$(echo "$before" | grep -q '| hi' && echo dh || echo dl); pinctrl set "$g" op "$level" ;;
        *)  pinctrl set "$g" "$func" ;;
    esac
    after=$(pinctrl get "$g")
    if tpm_ok; then
        echo "GPIO$g: no effect           (pin: $after)"
    else
        err=$(tpm2_getrandom --hex 4 2>&1 | grep -oiE 'TPM_RC_[A-Z_]+|0x[0-9a-f]+' | head -1)
        echo "GPIO$g: TPM RESET ($err)  (pin: $after)"
        echo "restarting TPM with tpm2_startup -c"
        tpm2_startup -c && tpm_ok && echo "TPM back up"
        exit 0
    fi
done
echo "no candidate GPIO resets the TPM"
