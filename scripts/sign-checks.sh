#!/bin/sh
# The bundle signature validators for build-mac.sh, shared with the gate.
#
# Sourced, never executed directly: build-mac.sh drives them against the real
# build, scripts/check-protocol.sh drives them against controlled fixtures.
#
# The team identifier is read from the code signature itself (codesign
# -dvvv): TeamIdentifier is signature metadata, not an Info.plist key -
# PlistBuddy pointed at a .app directory reads nothing. Every line scan runs
# as a while-read loop over a here-doc, never a pipe: grep -q's early exit
# SIGPIPEs its writer under set -o pipefail.

# The bundle's TeamIdentifier from its signature, or empty when the
# signature carries none (the line is "TeamIdentifier=not set" for ad-hoc
# signatures, handled by the caller).
signature_team_identifier() {
    _sig_cs=$(codesign -dvvv "$1" 2>&1 || true)
    _sig_team=""
    while IFS= read -r _sig_line; do
        case "$_sig_line" in
            TeamIdentifier=*) _sig_team=${_sig_line#TeamIdentifier=}; break ;;
        esac
    done <<EOF_SIG
$_sig_cs
EOF_SIG
    printf '%s' "$_sig_team"
}

# The signed-mode validator: a real (non-ad-hoc) signature whose team is set,
# with the app's application identifier and keychain access groups intact.
validate_signed_bundle() {
    _val_bundle=$1
    codesign --verify --deep --strict "$_val_bundle"
    _val_ent=$(codesign -d --entitlements - "$_val_bundle" 2>/dev/null || true)
    _val_has_appid=0
    _val_has_keychain=0
    while IFS= read -r _val_line; do
        case "$_val_line" in *application-identifier*) _val_has_appid=1 ;; esac
        case "$_val_line" in *keychain-access-groups*) _val_has_keychain=1 ;; esac
    done <<EOF_VAL
$_val_ent
EOF_VAL
    [ "$_val_has_appid" = 1 ] || { echo "FAIL: signed bundle lost its application identifier" >&2; return 1; }
    [ "$_val_has_keychain" = 1 ] || { echo "FAIL: signed bundle lost its keychain access groups" >&2; return 1; }
    _val_team=$(signature_team_identifier "$_val_bundle")
    if [ -z "$_val_team" ] || [ "$_val_team" = "not set" ]; then
        echo "FAIL: signed bundle has no TeamIdentifier" >&2
        return 1
    fi
    echo "OK: signed bundle carries identity, application identifier and keychain groups (team $_val_team)"
}

# The ad-hoc-mode validator: a signature is present, verifies strictly, and is
# ad-hoc.
validate_adhoc_bundle() {
    _val_bundle=$1
    codesign --verify --deep --strict "$_val_bundle"
    _val_cs=$(codesign -dvvv "$_val_bundle" 2>&1 || true)
    _val_flags=""
    while IFS= read -r _val_line; do
        case "$_val_line" in
            *flags=*) _val_flags=$_val_line ;;
        esac
    done <<EOF_VAL
$_val_cs
EOF_VAL
    case "$_val_flags" in
        *"flags=0x2(adhoc)"*) : ;;
        *) echo "FAIL: adhoc bundle is not ad-hoc signed" >&2; return 1 ;;
    esac
    echo "OK: adhoc bundle is ad-hoc signed"
}
