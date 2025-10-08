#!/bin/bash

# Function to download and install OpenShift CLI
install_oc() {
    local version=$1
    local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$version/openshift-client-linux.tar.gz"
    local filename="openshift-client-linux.tar.gz"

    echo "Downloading OpenShift CLI version $version..."
    curl -LO $url

    echo "Extracting OpenShift CLI..."
    tar xzf $filename

    echo "Moving OpenShift CLI to /usr/local/bin..."
    sudo mv oc /usr/local/bin/

    echo "Cleaning up..."
    rm $filename kubectl

    echo "OpenShift CLI installed successfully!"
}

# Main script
echo "Setting up OpenShift CLI..."

# Try to install the latest version first
latest_version=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/release.txt | grep 'Name:' | awk '{print $2}')
install_oc $latest_version

# Check if installation was successful
if ! oc version &> /dev/null; then
    echo "Latest version not compatible. Trying an older version..."
    install_oc "4.10.0"  # You can adjust this version if needed
fi

# Verify installation
oc version
