# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param([object] $AllVmData,
	  [object] $CurrentTestData)

function Main {
	# Create test result
	$superUser = "root"
	$resultArr = @()
	$currentTestResult = Create-TestResultObject

	try {
		$noClient = $true
		$noServer = $true
		foreach ($vmData in $allVMData) {
			if ($vmData.RoleName -imatch "client") {
				$clientVMData = $vmData
				$noClient = $false
			}
			elseif ($vmData.RoleName -imatch "server") {
				$noServer = $false
				$serverVMData = $vmData
			}
		}
		if ($noClient) {
			Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
		}
		if ($noServer) {
			Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
		}
		#region CONFIGURE VM FOR TERASORT TEST
		Write-LogInfo "CLIENT VM details :"
		Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
		Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
		Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
		Write-LogInfo "  Internal IP : $($clientVMData.InternalIP)"
		Write-LogInfo "SERVER VM details :"
		Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
		Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
		Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"
		Write-LogInfo "  Internal IP : $($serverVMData.InternalIP)"

		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
		Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
		#endregion

		Write-LogInfo "Getting Active NIC Name."
		$getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
		$clientNicName = (Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command $getNicCmd).Trim()
		$serverNicName = (Run-LinuxCmd -ip $clientVMData.PublicIP -port $serverVMData.SSHPort -username $superUser -password $password -command $getNicCmd).Trim()
		if ($serverNicName -eq $clientNicName) {
			Write-LogInfo "Client and Server VMs have same nic name: $clientNicName"
		} else {
			Throw "Server and client SRIOV NICs are not same."
		}
		if ($currentTestData.AdditionalHWConfig.Networking -imatch "SRIOV") {
			$DataPath = "SRIOV"
		} else {
			$DataPath = "Synthetic"
		}
		Write-LogInfo "CLIENT $DataPath NIC: $clientNicName"
		Write-LogInfo "SERVER $DataPath NIC: $serverNicName"

		Write-LogInfo "Generating constants.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		Add-Content -Value "vms=$($serverVMData.RoleName),$($clientVMData.RoleName)" -Path $constantsFile
		Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
		Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
		Add-Content -Value "nicName=eth1" -Path $constantsFile
		Add-Content -Value "pciAddress=0002:00:02.0" -Path $constantsFile

		foreach ($param in $currentTestData.TestParameters.param) {
			Add-Content -Value "$param" -Path $constantsFile
			if ($param -imatch "modes") {
				$modes = ($param.Replace("modes=",""))
			}
		}
		$currentKernelVersion = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort `
				-username $user -password $password -command "uname -r"
		if (Is-DpdkCompatible -KernelVersion $currentKernelVersion -DetectedDistro $global:DetectedDistro) {
			Write-LogInfo "Confirmed Kernel version supported: $currentKernelVersion"
		} else {
			Write-LogWarn "Unsupported Kernel version: $currentKernelVersion or unsupported distro $($global:DetectedDistro)"
			return $global:ResultSkipped
		}

		Write-LogInfo "constants.sh created successfully..."
		Write-LogInfo "test modes : $modes"
		Write-LogInfo (Get-Content -Path $constantsFile)
		#endregion

		#region EXECUTE TEST
		$myString = @"
cd /root/
./dpdkTestPmd.sh 2>&1 > dpdkConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
		Set-Content "$LogDir\StartDpdkTestPmd.sh" $myString
		Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files "$constantsFile,$LogDir\StartDpdkTestPmd.sh" -username $superUser -password $password -upload

		Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "chmod +x *.sh" | Out-Null
		$testJob = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "./StartDpdkTestPmd.sh" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ((Get-Job -Id $testJob).State -eq "Running") {
			$currentStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "tail -2 dpdkConsoleLogs.txt | head -1"
			Write-LogInfo "Current Test Status : $currentStatus"
			Wait-Time -seconds 20
		}
		$finalStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -command "cat /root/state.txt"
		Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -download -downloadTo $LogDir -files "*.csv, *.txt, *.log"

		if ($finalStatus -imatch "TestFailed") {
			Write-LogErr "Test failed. Last known status : $currentStatus."
			$testResult = "FAIL"
		}
		elseif ($finalStatus -imatch "TestAborted") {
			Write-LogErr "Test Aborted. Last known status : $currentStatus."
			$testResult = "ABORTED"
		}
		elseif ($finalStatus -imatch "TestCompleted") {
			Write-LogInfo "Test Completed."
			$testResult = "PASS"
			Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username $superUser -password $password -download -downloadTo $LogDir -files "*.tar.gz"
		}
		elseif ($finalStatus -imatch "TestRunning") {
			Write-LogInfo "Powershell background job for test is completed but VM is reporting that test is still running. Please check $LogDir\dpdkConsoleLogs.txt"
			Write-LogInfo "Content of summary.log : $testSummary"
			$testResult = "PASS"
		}

		$testpmdDataCsv = Import-Csv -Path $LogDir\dpdkTestPmd.csv
		if ($testResult -eq "PASS") {
			Write-LogInfo "Generating the performance data for database insertion"
			$properties = Get-VMProperties -PropertyFilePath "$LogDir\VM_properties.csv"
			$testDate = $(Get-Date -Format yyyy-MM-dd)
			foreach ($mode in $testpmdDataCsv) {
				$resultMap = @{}
				if ($properties) {
					$resultMap["GuestDistro"] = $properties.GuestDistro
					$resultMap["HostOS"] = $properties.HostOS
					$resultMap["KernelVersion"] = $properties.KernelVersion
				}
				$resultMap["HostType"] = "Azure"
				$resultMap["HostBy"] = $global:TestLocation
				$resultMap["GuestOSType"] = "Linux"
				$resultMap["GuestSize"] = $clientVMData.InstanceSize
				$resultMap["IPVersion"] = "IPv4"
				$resultMap["ProtocolType"] = "TCP"
				$resultMap["TestPlatFrom"] = $global:TestPlatForm
				$resultMap["TestCaseName"] = $global:GlobalConfig.Global.Azure.ResultsDatabase.testTag
				$resultMap["TestDate"] = $testDate
				$resultMap["LISVersion"] = "Inbuilt"
				$resultMap["DataPath"] = $DataPath
				$resultMap["DPDKVersion"] = $mode.DpdkVersion
				$resultMap["TestMode"] = $mode.TestMode
				$resultMap["Cores"] = [int32]($mode.Cores)
				$resultMap["Max_Rxpps"] = [int64]($mode.MaxRxPps)
				$resultMap["Txpps"] = [int64]($mode.TxPps)
				$resultMap["Rxpps"] = [int64]($mode.RxPps)
				$resultMap["Fwdpps"] = [int64]($mode.FwdPps)
				$resultMap["Txbytes"] = [int64]($mode.TxBytes)
				$resultMap["Rxbytes"] = [int64]($mode.RxBytes)
				$resultMap["Fwdbytes"] = [int64]($mode.FwdBytes)
				$resultMap["Txpackets"] = [int64]($mode.TxPackets)
				$resultMap["Rxpackets"] = [int64]($mode.RxPackets)
				$resultMap["Fwdpackets"] = [int64]($mode.FwdPackets)
				$resultMap["Tx_PacketSize_KBytes"] = [Decimal]($mode.TxPacketSize)
				$resultMap["Rx_PacketSize_KBytes"] = [Decimal]($mode.RxPacketSize)
				Write-LogInfo "Collected performance data for $($mode.TestMode) mode."
				$currentTestResult.TestResultData += $resultMap
			}
		}
		Write-LogInfo "Test result : $testResult"
		Write-LogInfo ($testpmdDataCsv | Format-Table | Out-String)
	} catch {
		$ErrorMessage =  $_.Exception.Message
		$ErrorLine = $_.InvocationInfo.ScriptLineNumber
		Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
		$testResult = "FAIL"
	} finally {
		if (!$testResult) {
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}
	$currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
	return $currentTestResult
}

Main
