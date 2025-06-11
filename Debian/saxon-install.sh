#!/bin/sh

# Exit immediately if a command exits with a non-zero status.
set -e

echo "Starting SaxonC installation on Debian..."

# --- Install Build Dependencies ---
echo "Installing build dependencies..."
    # Update the packages for security
apt-get update -y  \
    && apt-get install -y --no-install-recommends \
    icu-devtools \
    libicu-dev \
    libxml2-dev \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# --- SaxonC Installation ---
SAXON_TMP_DIR="/tmp/saxon"
mkdir -p "$SAXON_TMP_DIR"
cd "$SAXON_TMP_DIR"

echo "Detecting system architecture and latest SaxonC version..."
UNAME_ARCH=$(uname -m)
DOWNLOAD_ARCH_COMPONENT=""

case "$UNAME_ARCH" in
    x86_64) DOWNLOAD_ARCH_COMPONENT="linux-x86_64";;
    aarch64|arm64) DOWNLOAD_ARCH_COMPONENT="linux-aarch64";;
    *)
        echo "Error: Unsupported architecture: '$UNAME_ARCH'. Script needs Linux x86_64 or aarch64/arm64. Exiting." >&2
        exit 1
        ;;
esac

echo "Detected architecture: ${UNAME_ARCH}"

ALL_OUTPUT=$(curl -s https://www.saxonica.com/products/latest.xml | \
grep -A 1 -E '<h2>SaxonC 13</h2>|<h2>SaxonC 12</h2>' | \
awk '/<h2>SaxonC 13<\/h2>/ {f13=1;next} /<h2>SaxonC 12<\/h2>/ {if(!f13){f12=1;next}} {if(f13||f12){match($0, /[0-9]+(\.[0-9]+)*/);if(RSTART>0){v=substr($0, RSTART, RLENGTH); \
if(f13){print "SaxonC 13: " v}else{print "SaxonC 12: " v}; \
split(v,p,"."); \
mv=p[1];dv=p[1]; \
for(i=2;i<=length(p);i++){dv=dv"-"p[i]}; \
if(length(p)==2){dv=dv"-0"}else if(length(p)==1){dv=dv"-0-0"}; \
print mv,dv; exit}}}')

if [ -z "$ALL_OUTPUT" ]; then
    echo "Error: Could not determine latest SaxonC version." >&2
    exit 1
fi

DETECTED_VERSION_DISPLAY_LINE=$(echo "$ALL_OUTPUT" | head -n 1)
MACHINE_READABLE_INFO=$(echo "$ALL_OUTPUT" | tail -n 1)
MAJOR_VER=$(echo "$MACHINE_READABLE_INFO" | awk '{print $1}')
FORMATTED_VER=$(echo "$MACHINE_READABLE_INFO" | awk '{print $2}')

echo "$DETECTED_VERSION_DISPLAY_LINE"
CONSTRUCTED_URL="https://downloads.saxonica.com/SaxonC/HE/${MAJOR_VER}/SaxonCHE-${DOWNLOAD_ARCH_COMPONENT}-${FORMATTED_VER}.zip"
echo "Downloading from: $CONSTRUCTED_URL"
curl -L -o saxon.zip "$CONSTRUCTED_URL"
unzip saxon.zip
rm saxon.zip

# 1. Move the entire SaxonCHE distribution to /usr/local/SaxonCHE
#    This ensures its structure is intact for the PHP extension's configure script.
echo "Moving SaxonCHE distribution to /usr/local/SaxonCHE..."
mv "SaxonCHE-${DOWNLOAD_ARCH_COMPONENT}-${FORMATTED_VER}/SaxonCHE" /usr/local/SaxonCHE

# 2. Move the PHP source to a temporary location for compilation
echo "Moving PHP source to temporary location..."
mv "SaxonCHE-${DOWNLOAD_ARCH_COMPONENT}-${FORMATTED_VER}/php/src" "$SAXON_TMP_DIR"

# 3. Clean up the original extracted directory from the zip
echo "Cleaning up extracted directory..."
rm -rf "SaxonCHE-${DOWNLOAD_ARCH_COMPONENT}-${FORMATTED_VER}"

# 4. Compile Saxon PHP extension
echo "Compiling Saxon PHP extension..."
cd "$SAXON_TMP_DIR/src"
phpize
./configure --with-saxon=/usr/local/SaxonCHE LDFLAGS="-L/usr/local/SaxonCHE/lib"
make
make install

# Move the modules to the specific modules folder of PHP
echo "Moving PHP modules to extension directory..."
# Use `php-config --extension-dir` to get the correct directory
EXTENSION_DIR=$(php-config --extension-dir)
if [ -d "$EXTENSION_DIR" ]; then
    mv "$SAXON_TMP_DIR/src/modules"/* "$EXTENSION_DIR"/
else
    echo "Error: PHP extension directory not found at $EXTENSION_DIR" >&2
    exit 1
fi

# 5. NOW, after the PHP extension is compiled, move the core SaxonC shared libraries
#    to a default linker path for runtime discovery.
echo "Moving core SaxonC shared libraries to /usr/local/lib..."
mv /usr/local/SaxonCHE/lib/*.so* /usr/local/lib/

# 6. Enable the PHP extension
echo "Enabling Saxon PHP extension..."
# Determine PHP configuration directory. Common paths: /etc/php/{PHP_VERSION}/mods-available or /etc/php/{PHP_VERSION}/cli/conf.d
# Let's try to find a common conf.d path for CLI
PHP_INI_DIR=$(php-config --ini-dir 2>/dev/null || echo "/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/cli")
if [ -d "${PHP_INI_DIR}/conf.d" ]; then
    echo "extension=saxon.so" > "${PHP_INI_DIR}/conf.d/saxon.ini"
elif [ -d "/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/mods-available" ]; then
    echo "extension=saxon.so" > "/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/mods-available/saxon.ini"
    phpenmod saxon
else
    echo "Warning: Could not determine PHP configuration directory. You may need to enable 'saxon.so' manually." >&2
fi


# 7. Clean up build dependencies and temporary files
echo "Cleaning up build dependencies and temporary files..."
apt-get purge -y --auto-remove \
    icu-devtools \
    libicu-dev \
    libxml2-dev \
    unzip
rm -rf /tmp/*

echo "SaxonC installation complete!"