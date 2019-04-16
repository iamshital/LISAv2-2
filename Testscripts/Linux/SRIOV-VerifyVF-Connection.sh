#!/bin/bash

# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# Description:
#   Basic SR-IOV test checks connectivity SR-IOV between two VMs
#   Steps:
#   1. Verify/install pciutils package
#   2. Using the lspci command, examine the NIC with SR-IOV support
#   3. Check network capability
#   4. Send a 1GB file from VM1 to VM2
# Note: This script can handle multiple SR-IOV interfaces
#
########################################################################
remote_user="root"
if [ ! -e sriov_constants.sh ]; then
    cp /${remote_user}/sriov_constants.sh .
fi

# Source SR-IOV_Utils.sh. This is the script that contains all the
# SR-IOV basic functions (checking drivers, checking VFs, assigning IPs)
. SR-IOV-Utils.sh || {
    echo "ERROR: unable to source SR-IOV_Utils.sh!"
    echo "TestAborted" > state.txt
    exit 0
}

# Check if the SR-IOV driver is in use
VerifyVF
if [ $? -ne 0 ]; then
    LogErr "VF is not loaded! Make sure you are using compatible hardware"
    SetTestStateFailed
    exit 0
fi

if [ "$rescind_pci" = "yes" ]; then
    # call rescind function with param SRIOV
    if ! RescindPCI "SR-IOV"; then
        LogErr "Could not rescind pci device."
        SetTestStateFailed
        exit 0
    fi
fi

# Create an 1gb file to be sent from VM1 to VM2
Create1Gfile
if [ $? -ne 0 ]; then
    LogErr "Could not create the 1gb file on VM1!"
    SetTestStateFailed
    exit 0
fi

# Check if the VF count inside the VM is the same as the expected count
vf_count=$(find /sys/devices -name net -a -ipath '*vmbus*' | grep pci | wc -l)
if [ "$vf_count" -ne "$NIC_COUNT" ]; then
    LogErr "Expected VF count: $NIC_COUNT. Actual VF count: $vf_count"
    SetTestStateFailed
    exit 0
fi
UpdateSummary "Expected VF count: $NIC_COUNT. Actual VF count: $vf_count"
LogMsg "Updating test case state to completed"
SetTestStateCompleted
exit 0