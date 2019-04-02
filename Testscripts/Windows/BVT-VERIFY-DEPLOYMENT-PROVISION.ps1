# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

function Main {
	try {
		$counter = 1
		LogMsg "Your VMs are ready to use..."
        foreach ( $item in $isDeployed.Split("^") )
        {
            $currentTestResult.TestSummary +=  CreateResultSummary -testResult "$item" -metaData "Resource Group" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
			$subID = $($xmlConfig.config.Azure.General.SubscriptionID)
			$subID = $subID.Trim()
            $currentTestResult.TestSummary +=  CreateResultSummary -testResult "https://ms.portal.azure.com/#resource/subscriptions/$subID/resourceGroups/$item/overview" -metaData "WebURL" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        }
        foreach ( $vm in $allVMData )
        {
            
            if ( $GuestOSType -eq "Linux" )
            {
                LogMsg "VM #$counter`: $($vm.PublicIP):$($vm.SSHPort)"
                $currentTestResult.TestSummary +=  CreateResultSummary -testResult "$($vm.Status)" -metaData "VM #$counter` : $($vm.PublicIP) : $($vm.SSHPort) " -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            }
            else
            {
                LogMsg "VM #$counter`: $($vm.PublicIP):$($vm.RDPPort)"
                $currentTestResult.TestSummary +=  CreateResultSummary -testResult "$($vm.Status)" -metaData "VM #$counter` : $($vm.PublicIP) : $($vm.RDPPort) " -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            }
            $counter++
        }
		LogMsg "Test Result : PASS."
		$testResult = "PASS"
	}
	catch {
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"
	}
	Finally {
		$metaData = ""
		if (!$testResult) {
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}

    $currentTestResult.TestResult = GetFinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}

Main
