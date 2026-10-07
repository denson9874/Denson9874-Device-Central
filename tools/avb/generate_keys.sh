#!/usr/bin/env bash
set -e

# ==============================================================================
# ExpressiveOS AVB 2.0 & Platform Release Key Generation Tool
# ==============================================================================

KEY_DIR="vendor/expressive/keys"
mkdir -p "${KEY_DIR}"

echo "Generating AVB 2.0 RSA-4096 signing key..."
openssl genrsa -out "${KEY_DIR}/avb_custom_key.pem" 4096

echo "Extracting AVB public key for Titan M bootloader enrollment..."
# If avbtool is installed in path or prebuilts
if command -v avbtool &> /dev/null; then
    avbtool extract_public_key --key "${KEY_DIR}/avb_custom_key.pem" --output "${KEY_DIR}/avb_custom_key.img"
else
    # Fallback OpenSSL extraction
    openssl rsa -in "${KEY_DIR}/avb_custom_key.pem" -pubout -out "${KEY_DIR}/avb_custom_key.pub"
    cp "${KEY_DIR}/avb_custom_key.pub" "${KEY_DIR}/avb_custom_key.img"
fi

echo "Generating Platform release keys..."
KEYS=("releasekey" "platform" "shared" "media" "networkstack")
SUBJECT="/C=US/ST=California/L=MountainView/O=ExpressiveOS/OU=Platform/CN=ExpressiveOS/emailAddress=denson9874@expressivelauncher.com"

for KEY in "${KEYS[@]}"; do
    if [ ! -f "${KEY_DIR}/${KEY}.pk8" ]; then
        echo "Creating ${KEY}..."
        openssl genrsa -out "${KEY_DIR}/${KEY}.key" 2048
        openssl req -new -x509 -key "${KEY_DIR}/${KEY}.key" -out "${KEY_DIR}/${KEY}.x509.pem" -days 10000 -subj "${SUBJECT}"
        openssl pkcs8 -in "${KEY_DIR}/${KEY}.key" -topk8 -outform DER -out "${KEY_DIR}/${KEY}.pk8" -nocrypt
        rm -f "${KEY_DIR}/${KEY}.key"
    fi
done

echo "✓ Keys successfully generated in ${KEY_DIR}!"
echo "  - AVB Key: ${KEY_DIR}/avb_custom_key.img (Flash to Pixel 11 Pro/XL to lock bootloader)"
