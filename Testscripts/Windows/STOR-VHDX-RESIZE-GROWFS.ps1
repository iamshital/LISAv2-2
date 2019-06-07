# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

<#
.Synopsis
	Verify if the filesystem can be resized after a VHDx Hard Disk resizing.
.Description
	This is a PowerShell test case script that implements Dynamic
	Resizing of VHDX and growing the filesystem
	Ensures that the VM sees the newly attached VHDx Hard Disk and resizes the
	filesystem after the disk resizing
	Creates partitions, filesytem, mounts partitions, sees if it can perform
	Read/Write operations on the newly created partitions and deletes partitions
	A typical test case definition for this test script would look
	similar to the following:
.Parameter testParams
	Test data for this test case
#>

Param([String] $TestParams)

$ErrorActionPreference = "Stop"
$testResult = "FAIL"

# If the vm has more than one disk controller, the order in which their corresponding device nodes are added is arbitrary
# This may result in device names like /dev/sda and /dev/sdc switching around on each boot
Function Get-DeviceName
{
	param ($ip, $port)
	$scriptContent = @'
#! /bin/bash
devlist=(/dev/sda /dev/sdb /dev/sdc)
for dev in "${devlist[@]}"; do
    # Skip the OS disk
    fdisk -l $dev | grep -i "Linux filesystem" > /dev/null
    if [ 0 -eq $? ]; then
        continue
    fi
    # Skip the resource disk
    fdisk -l $dev | grep -i "1 GiB" > /dev/null
        if [ 0 -eq $? ]; then
        continue
    fi
    deviceName=$dev
done
echo "$deviceName"
'@
	Set-Content "$LogDir\get_device_name.sh" $scriptContent
	Copy-RemoteFiles -uploadTo $ip -port $port -files "$LogDir\get_device_name.sh" -username $user -password $password -upload
	$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "bash get_device_name.sh" -runAsSudo
	return $ret
}

Function Set-HardDiskSize
{
	param ($vhdPath, $newSize, $controllerType, $vmName, $hvServer, $ip, $port, $testParameters)

	# for IDE & offline need to stop VM before resize
	if ( $controllerType -eq "IDE" -or $testParameters.Offline -eq "True") {
		Write-LogInfo "Stopping VM if it is an IDE disk or Offline is True"
		Stop-VM -VMName $vmName -ComputerName $hvServer -force
	}

	$newVhdxSize = Convert-StringToUInt64 $newSize
	Resize-VHD -Path $vhdPath -SizeBytes ($newVhdxSize) -ComputerName $hvServer
	if (-not $?) {
		Throw "Unable to grow VHDX file ${vhdPath}"
	}

	# Now start the VM for IDE or Offline
	if ( $controllerType -eq "IDE" -or $testParameters.Offline -eq "True" ) {
		$timeout = 300
		Start-VM -Name $vmName -ComputerName $hvServer
		if (-not (Wait-ForVMToStartKVP $vmName $hvServer $timeout )) {
			Throw "${vmName} failed to start"
		} else {
			Write-LogInfo "Started VM ${vmName}"
		}
	}

	# check file size after resize
	$vhdxInfoResize = Get-Vhd -Path $vhdPath -ComputerName $hvServer
	if ( $newSize.contains("GB") -and $vhdxInfoResize.Size/1gb -ne $newSize.Trim("GB") ) {
		Throw "Failed to Resize Disk to new Size"
	}

	Write-LogInfo "Check if the guest detects the new space"
	$deviceName = Get-DeviceName -ip $ip -port $port
	Write-LogInfo "The disk device name: $deviceName"
	$sd = "$deviceName" -replace "/dev/",""
	$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "echo 'deviceName=$deviceName' >> constants.sh" -runAsSudo
	# Do a request & rescan to refresh the disks info
	$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "fdisk -l > /dev/null" -runAsSudo
	$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "echo 1 > /sys/block/$sd/device/rescan" -runAsSudo
	$diskSize = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "fdisk -l $deviceName 2> /dev/null | grep Disk | grep $sd | cut -f 5 -d ' '" -runAsSudo
	if (-not $diskSize) {
		Throw "Unable to determine disk size from within the guest after growing the VHDX"
	}
	if ($diskSize -ne $newVhdxSize) {
		Throw "VM ${vmName} detects a disk size of ${diskSize}, not the expected size of ${newVhdxSize}"
	}

	# Make sure if we can perform Read/Write operations on the guest VM
	# if file size larger than 2T (2048G), use parted to format disk
	$guestScript = "STOR_VHDXResize_PartitionDisk.sh"
	$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "echo 'rerun=yes' >> constants.sh" -runAsSudo
	$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "./$guestScript" -runAsSudo
	if (-not $ret) {
		Throw "Running '${guestScript}'script failed on VM. check VM logs , exiting test case execution"
	}
	Write-LogInfo "The guest detects the new size after resizing ($diskSize)"
} # End function

Function Main
{
	param ($vmName, $hvServer, $ip, $port, $testParameters)
	$resultArr = @()

	try {
		# if host build number lower than 9600, skip test
		$BuildNumber = Get-HostBuildNumber $hvServer
		if ($BuildNumber -lt 9600) {
			$testResult = "ABORTED"
			Throw "Build number less than 9600"
		}

		if ($testParameters.Contains("IDE")) {
			$controllerType = "IDE"
			$vmGeneration = Get-VMGeneration $vmName $hvServer
			if ($vmGeneration -eq 2 ) {
				$testResult = "ABORTED"
				Throw "Generation 2 VM does not support IDE disk, skip test"
			}
		}
		elseif ($testParameters.Contains("SCSI")) {
			$controllerType = "SCSI"
		}
		else {
			$testResult = "ABORTED"
			Throw "Could not determine ControllerType"
		}

		# Find the vhdx drive to operate on
		$vhdxDrive = Get-VMHardDiskDrive -VMName $vmName  -ComputerName $hvServer -ControllerLocation 1
		if (-not $vhdxDrive) {
			$testResult = "FAIL"
			Throw "No suitable virtual hard disk drives attached VM ${vmName}"
		}

		Write-LogInfo "Check if the virtual disk file exists"
		$vhdPath = $vhdxDrive.Path
		$vhdxInfo = Get-RemoteFileInfo $vhdPath $hvServer
		if (-not $vhdxInfo) {
			$testResult = "FAIL"
			Throw "The vhdx file (${vhdPath} does not exist on server ${hvServer}"
		}

		Write-LogInfo "Verify the file is a .vhdx"
		if (-not $vhdPath.EndsWith(".vhdx") -and -not $vhdPath.EndsWith(".avhdx")) {
			$testResult = "FAIL"
			Throw "$controllerType $vhdxDrive.ControllerNumber $vhdxDrive.ControllerLocation virtual disk is not a .vhdx file."
		}

		$fileSystems = $testParameters.fileSystems.Trim("(",")")
		$fileSystems = @($fileSystems.Split(" "))
		foreach ($fs in $fileSystems) {
			# Make sure there is sufficient disk space to grow the VHDX to the specified size
			$deviceID = $vhdxInfo.Drive
			$diskInfo = Get-CimInstance -Query "SELECT * FROM Win32_LogicalDisk Where DeviceID = '${deviceID}'" -ComputerName $hvServer
			if (-not $diskInfo) {
				$testResult = "FAIL"
				Throw "Unable to collect information on drive ${deviceID}"
			}
			$sizeFlag = Convert-StringToUInt64 "20GB"
			if ($diskInfo.FreeSpace -le $sizeFlag + 10MB) {
				$testResult = "FAIL"
				Throw "Insufficent disk free space, This test case requires ${testParameters.NewSize} free, Current free space is $($diskInfo.FreeSpace)"
			}

			$deviceName = Get-DeviceName -ip $ip -port $port
			Write-LogInfo "The disk device name: $deviceName"
			# Make sure if we can perform Read/Write operations on the guest VM
			$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "echo 'fs=$fs' >> constants.sh" -runAsSudo
			$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "sed -i '/rerun=yes/d' constants.sh" -runAsSudo
			$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "echo 'deviceName=$deviceName' >> constants.sh" -runAsSudo
			$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "./STOR_VHDXResize_GrowFSAfterResize.sh" -runAsSudo
			if (-not $ret) {
				$testResult = "FAIL"
				Throw "Running '${guestScript}'script failed on VM. check VM logs , exiting test case execution"
			}

			if ($null -ne $testParameters.newSize) {
				$newSize = $testParameters.newSize
				Set-HardDiskSize $vhdPath $newSize $controllerType $vmName $hvServer $ip $port $testParameters
			}
			$newVhdxSize = $newVhdxSize + 1GB
			$ret = Run-LinuxCmd -ip $ip -port $port -username $user -password $password -command "sed -i '/fs=$fs/d' constants.sh" -runAsSudo
		}
		$testResult = "PASS"

	} catch {
		$testResult = "FAIL"
		$ErrorMessage =  $_.Exception.Message
		$ErrorLine = $_.InvocationInfo.ScriptLineNumber
		Write-LogErr "$ErrorMessage at line: $ErrorLine"

	} finally {
		Stop-VM -VMName $vmName -ComputerName $hvServer -force
		Remove-VMHardDiskDrive -VMHardDiskDrive $vhdxDrive
		Remove-Item $vhdPath
		Start-VM -Name $vmName -ComputerName $hvServer
		$resultArr += $testResult
	}

	return Get-FinalResultHeader -resultarr $resultArr
} # end Main

Main -vmName $VM.RoleName -hvServer $VM.HyperVHost -ip $VM.PublicIP -port $VM.SSHPort -testParameters (ConvertFrom-StringData $TestParams.Replace(";","`n"))
