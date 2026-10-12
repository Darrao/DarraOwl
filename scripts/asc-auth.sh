# Sourced by testflight.sh and release-mac.sh. With an App Store Connect API
# key, kept outside the repository:
#   ~/.appstoreconnect/darraowl.env                  ASC_KEY_ID=… and ASC_ISSUER_ID=…
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
# xcodebuild and notarytool sign in with it. Without it: the account signed in
# to Xcode, and the notarytool profile "DarraOwl".
XCODE_AUTH=()
NOTARY_AUTH=(--keychain-profile DarraOwl)
ASC_ENV="$HOME/.appstoreconnect/darraowl.env"
if [ -f "$ASC_ENV" ]; then
  # Read, not sourced: nothing in that file runs.
  ASC_KEY_ID="$(sed -n 's/^ASC_KEY_ID=//p' "$ASC_ENV")"
  ASC_ISSUER_ID="$(sed -n 's/^ASC_ISSUER_ID=//p' "$ASC_ENV")"
  ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
  if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ] || [ ! -f "$ASC_KEY" ]; then
    echo "Clé App Store Connect incomplète : $ASC_ENV (ASC_KEY_ID, ASC_ISSUER_ID) et $ASC_KEY." >&2
    exit 1
  fi
  XCODE_AUTH=(-authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  NOTARY_AUTH=(--key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi
