<#
.DESCRIPTION
    This runbook starts the StorSimple Virtual Appliance (SVA) & Virtual Machine (VM) in case these are in a shut down state. 
    This runbook reads all volumes info based on VolumeContainers asset.  After that it clones the fetched volumes on to the target Device.
    This runbook creates a script and stores it in a storage account. This script will connect the iSCSI target and mount the volumes on the VM. It then uses the Custom VM Script Extension to run the script on the VM.
    This runbook verifies the CHKDSK result on all mounted volumes. Once the CHKDSK execution completes.
    This runbook deletes all the volumes and volume contaienrs on the target device.
    This runbook also shuts downs the SVA & VM.
     
.ASSETS 
    AzureCredential [Windows PS Credential]:
        A credential containing an Org Id username, password with access to this Azure subscription
        Multi Factor Authentication must be disabled for this credential
    
    VMCredential [Windows PS Credential]:
        A credential containing an username, password with access to Virtual Machine
         
    AzureSubscriptionName: The name of the Azure Subscription
    ResourceName: The name of the StorSimple resource
    StorSimRegKey: The registration key for the StorSimple manager
    StorageAccountName: The storage account name in which the script will be stored
    StorageAccountKey: The access key for the storage account
    SourceDeviceName: The Device which has to be verified disk status
    TargetDeviceName: The Device on which the containers are to be cloned
    VMName: The name of the Virtual machine which has to be used for mount the volumes & verify the disk status.
    VMServiceName: The Cloud service name where Virtual machine is running
    VolumeContainers: A comma separated string of volume containers present on the Device that need to be checked, ex - "VolCon1,VolCon2"
    
    MailCredential [Windows PS Credential]: 
        A credential containing an Org Id username, password

    MailSmtpServer: The name of the SmtpServer
    MailPort (Optional): Port number of SmtpServer. Not mandatory when the port no is 25 (Default)
    MailTo: To email address to send final CHKDSK result
    MailCc (Optional): Cc email address to send final CHKDSK result.

.NOTES:
	Multi Factor Authentication must be disabled to execute this runbook
	If a volume doesn't have at least one backup then it'll be skipped to verify data integrity
	If a volume already exists in the target device then it'll be skipped from cloning
	Multiple email addresses cannot support in To / Cc address field
#>

workflow Check-StorSimpleVolume-DiskIntegrity
{
    $AcrName = "VMName-chkdsk-vm-acr"
    $ScriptName = "chkdsk-volumename.ps1"
    $SourceBlob = "https://StorageAccountName.blob.core.windows.net/"
    $ChkDskLogFile = "C:\Users\Public\Documents\chkdsk-log-DriveLetter-drive.log"
    $ChkDskLogFolderPath = ($ChkDskLogFile | Split-Path)
	$ScriptContainer = "chkdsk-scriptcontainer"  # The name of the Storage Container in which the script will be stored
    
    # TImeout inputs
    $SLEEPTIMEOUT = 60 # Value in seconds 
    $SLEEPTIMEOUTSMALL = 10 # Value in seconds
    $SLEEPTIMEOUTLARGE = 300 # Value in seconds
    
    # Fetch all Automation Variable data
    Write-Output "Fetching assets info"
    $AzureCredential = Get-AutomationPSCredential -Name "AzureCredential"
    If ($AzureCredential -eq $null) 
    {
        throw "The AzureCredential asset has not been created in the Automation service."  
    }
        
    $VMCredential = Get-AutomationPSCredential -Name "VMCredential"
    If ($VMCredential -eq $null) 
    {
        throw "The VMCredential asset has not been created in the Automation service."  
    }
    
    $SubscriptionName = Get-AutomationVariable –Name "AzureSubscriptionName"
    if ($SubscriptionName -eq $null) 
    { 
        throw "The AzureSubscriptionName asset has not been created in the Automation service."  
    }
    
    $RegistrationKey = Get-AutomationVariable -Name "StorSimRegKey"
    if ($RegistrationKey -eq $null) 
    { 
        throw "The StorSimRegKey asset has not been created in the Automation service."  
    }

    $ResourceName = Get-AutomationVariable –Name "ResourceName" 
    if ($ResourceName -eq $null) 
    { 
        throw "The ResourceName asset has not been created in the Automation service."  
    }
    
    $StorageAccountName = Get-AutomationVariable –Name "StorageAccountName" 
    if ($StorageAccountName -eq $null) 
    { 
        throw "The StorageAccountName asset has not been created in the Automation service."  
    }
    $SourceBlob = $SourceBlob.Replace("StorageAccountName", $StorageAccountName)
        
    $StorageAccountKey = Get-AutomationVariable –Name "StorageAccountKey" 
    if ($StorageAccountKey -eq $null) 
    { 
        throw "The StorageAccountKey asset has not been created in the Automation service."  
    }
    
    $ContainerNames = Get-AutomationVariable –Name "VolumeContainers"
    if ($ContainerNames -eq $null) 
    { 
        throw "The VolumeContainers asset has not been created in the Automation service."  
    }
    elseIf($ContainerNames -eq "" -or $ContainerNames.Length -eq 0) {
        throw "The VolumeContainers asset left blank. Please provide valid data"
    }
    $VolumeContainers =  ($ContainerNames.Split(",").Trim() | sort)
     
    $DeviceName = Get-AutomationVariable –Name "SourceDeviceName" 
    if ($DeviceName -eq $null)
    { 
        throw "The SourceDeviceName asset has not been created in the Automation service."  
    }

    $TargetDeviceName= Get-AutomationVariable –Name "TargetDeviceName" 
    if ($TargetDeviceName -eq $null)
    {
        throw "The TargetDeviceName asset has not been created in the Automation service."  
    }

    $VMName = Get-AutomationVariable –Name "VMName"
    if ($VMName -eq $null) 
    { 
        throw "The VMName asset has not been created in the Automation service."  
    }

    $VMServiceName = Get-AutomationVariable –Name "VMServiceName"
    if ($VMServiceName -eq $null) 
    { 
        throw "The VMServiceName asset has not been created in the Automation service."  
    }

    $MailCredential = Get-AutomationPSCredential -Name "MailCredential"
    If ($MailCredential -eq $null) 
    {
        throw "The MailCredential asset has not been created in the Automation service."  
    }
    
    $MailFrom = $MailCredential.UserName
    if ($MailFrom -eq $null) 
    { 
        throw "Unable to fetch username from MailCredential asset."  
    }

    $MailTo = Get-AutomationVariable –Name "MailTo"
    if ($MailTo -eq $null) 
    { 
        throw "The MailTo asset has not been created in the Automation service."  
    }
    
    $MailSmtpServer = Get-AutomationVariable –Name "MailSmtpServer"
    if ($MailSmtpServer -eq $null) 
    { 
        throw "The MailSmtpServer asset has not been created in the Automation service."  
    }

    $MailCc = Get-AutomationVariable –Name "MailCc"
    $MailPort = Get-AutomationVariable –Name "MailSmtpPortNo"
    
    
    # Remove VM service extension 
    $VMServiceName = $VMServiceName -replace ".cloudapp.net", ""

    # Connect to Azure
    Write-Output "Connecting to Azure"
    $AzureAccount = Add-AzureAccount -Credential $AzureCredential      
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $SubscriptionName          
    If (($AzureSubscription -eq $null) -or ($AzureAccount -eq $null)) 
    {
        throw "Unable to connect to Azure"
    }
    
    # Connect to StorSimple 
    Write-Output "Connecting to StorSimple"                
    $StorSimpleResource = Select-AzureStorSimpleResource -ResourceName $ResourceName -RegistrationKey $RegistrationKey
    If ($StorSimpleResource -eq $null) 
    {
        throw "Unable to connect to StorSimple"
    }
    
    # Set Current Storage Account for the subscription
    Write-Output "Setting the storage account for the subscription"
    try {
        Set-AzureSubscription -SubscriptionName $SubscriptionName -CurrentStorageAccountName $StorageAccountName
    }
    catch {
        throw "Unable to set the storage account for the subscription"
    }
    
    $TargetDevice = Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName
    if ($TargetDevice -eq $null) 
    {
        throw "Target device $TargetDeviceName does not exist"
    }

    $TargetVM = Get-AzureVM -Name $VMName -ServiceName $VMServiceName
    if ($TargetVM -eq $null)
    {
        throw "VMName or VMServiceName asset is incorrect"
    }
    
    # Add all devices & VMs which are to be Turn on when the process starts & Turn off in the end 
    $SystemList = @()
    $SVAProp = @{ Type="SVA"; Name=$TargetDeviceName; ServiceName=$TargetDeviceName; Status=$TargetDevice.Status }
    $SVAObj = New-Object PSObject -Property $SVAProp
    $SystemList += $SVAObj
    $VMProp = @{ Type = "VM"; Name=$VMName; ServiceName=$VMServiceName; Status=$TargetVM.Status }
    $VMObj = New-Object PSObject -Property $VMProp
    $SystemList += $VMObj
    
    # Turning the SVA on
    Write-Output "Attempting to turn on the SVA & VM"
    foreach ($SystemInfo in $SystemList) 
    {
        InlineScript
        {
            $SystemInfo = $Using:SystemInfo
            $Name = $SystemInfo.Name
            $ServiceName = $SystemInfo.ServiceName
            $SystemType = $SystemInfo.Type
            $SLEEPTIMEOUTSMALL = $Using:SLEEPTIMEOUTSMALL
            
            $status = "Offline"
            If ($SystemInfo.Status -eq "Online" -or $SystemInfo.Status -eq "ReadyRole") { 
                $status = "Online"
            }
        
            if ($status -ne "Online" )
            {
                Write-Output " Starting the $SystemType ($Name)"
                $RetryCount = 0
                while ($RetryCount -lt 2)
                {
                    $Result = Start-AzureVM -Name $Name -ServiceName $ServiceName 
                    if ($Result.OperationStatus -eq "Succeeded")
                    {
                        Write-Output "  $SystemType succcessfully turned on ($Name)"   
                        break
                    }
                    else
                    {
                        if ($RetryCount -eq 0) {
                            Write-Output "  Retrying turn on the $SystemType ($Name)"
                        }
                        else {
                            throw "  Unable to start the $SystemType ($Name)"
                        }
                                    
                        # Sleep for 10 seconds before trying again                 
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        $RetryCount += 1   
                    }
                }
                
                $TotalTimeoutPeriod = 0
                while($true)
                {
                    Start-Sleep -s $SLEEPTIMEOUTSMALL
                    If ($SystemType -eq "SVA") {
                        $SVA =  Get-AzureStorSimpleDevice -DeviceName $Name
                        if($SVA.Status -eq "Online")
                        {
                            Write-Output "  SVA ($Name) status is now online"
                            break
                        }
                    }
                    elseIf ($SystemType -eq "VM") {
                        $VM =  Get-AzureVM -Name $Name -ServiceName $ServiceName
                        if($VM.Status -eq "ReadyRole")
                        {
                            Write-Output "  VM ($Name) is now ready state"
                            break
                        }
                    }
                    
                    $TotalTimeoutPeriod += $SLEEPTIMEOUTSMALL
                    if ($TotalTimeoutPeriod -gt 540) #9 minutes
                    {
                        throw "  Unable to bring the $SystemType online"
                    }
                }
            }
            elseIf ($SystemType -eq "SVA") {
                Write-Output " SVA ($Name) is online"
            }
            elseIf ($SystemType -eq "VM") {
                Write-Output " VM ($Name) is ready state"
            }
        }
    }
    
    Write-Output "Fetching VM WinRMUri"
    $VMWinRMUri = InlineScript { 
        try {
            # Get the Azure certificate for remoting into this VM
            $winRMCert = (Get-AzureVM -ServiceName $Using:VMServiceName -Name $Using:VMName | select -ExpandProperty vm).DefaultWinRMCertificateThumbprint   
            $AzureX509cert = Get-AzureCertificate -ServiceName $Using:VMServiceName -Thumbprint $winRMCert -ThumbprintAlgorithm sha1
    
            # Add the VM certificate into the LocalMachine
            if ((Test-Path Cert:\LocalMachine\Root\$winRMCert) -eq $false)
            {
                # "VM certificate is not in local machine certificate store - adding it"
                $certByteArray = [System.Convert]::fromBase64String($AzureX509cert.Data)
                $CertToImport = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certByteArray)
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
                $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                $store.Add($CertToImport)
                $store.Close()
            }
    		
    		# Return the WinRMUri so that it can be used to connect to the VM
    		Get-AzureWinRMUri -ServiceName $Using:VMServiceName -Name $Using:VMName
        }
        catch {
            throw "Unable to fetch VM WinRMUri"
        }     
    }
    
    if ($VMWinRMUri -eq $null) {
        throw "Unable to fetch VM WinRMUri"
    }
    
    Write-Output "Fetching VM IQN"
    $VMIQN = InlineScript
    {
        Invoke-Command -ConnectionUri $Using:VMWinRMUri -Credential $Using:VMCredential -ScriptBlock {
            param([Int]$SLEEPTIMEOUTSMALL)
            # Starting the iSCSI service 
            Start-Service msiscsi
            Start-Sleep -s $SLEEPTIMEOUTSMALL
            Set-Service msiscsi -StartupType "Automatic"
            
            # Getting VM initiator
            $IQN = (Get-InitiatorPort).NodeAddress
            
            # Output of InlineScript
            $IQN
        } -Argumentlist $Using:SLEEPTIMEOUTSMALL
    }
    
    If ($VMIQN -eq $NUll ) {
        throw "Unable to fetch the ACR of VM ($VMName)"
    }
    else 
    {
        # Replace actual VM Name
        $AcrName = $AcrName -replace "VMName", "$VMName"
        
        # Fetch existing ACR details
        $AvailableACRList = Get-AzureStorSimpleAccessControlRecord        
        $VMAcr = ($AvailableACRList | Where-Object { $_.InitiatorName -eq $VMIQN -or $_.Name -eq $AcrName })
        If ($VMAcr -eq $null)
        {
            Write-Output "Adding ACR ($AcrName) to the resource"
            $AcrCreation=New-AzureStorSimpleAccessControlRecord -ACRName $AcrName -IQNInitiatorName $VMIQN -WaitForComplete -ErrorAction:SilentlyContinue
            If ($AcrCreation -eq $null) {
                throw "ACR ($AcrName) could not be added to the resource"
            }
        
            $VMAcr = Get-AzureStorSimpleAccessControlRecord -ACRName $AcrName
        }
        
        $AcrName = $VMAcr.Name
    }
    
    Write-Output "Attempting to fetch the volume list"
    InlineScript
    {
        $DeviceName = $Using:DeviceName
        $TargetDeviceName = $Using:TargetDeviceName
        $VolumeContainers = $Using:VolumeContainers
        $VMAcr = $Using:VMAcr
        $SLEEPTIMEOUTSMALL = $Using:SLEEPTIMEOUTSMALL
     
        $VolList = @()   
        $TotalVolumesCount = 0
        foreach ($ContainerName in $VolumeContainers)
        {
            $ContainerData = Get-AzureStorSimpleDeviceVolumeContainer -DeviceName $DeviceName -VolumeContainerName $ContainerName -ErrorAction:SilentlyContinue
            if ($ContainerData -eq $null) {
                throw "  Volume container ($ContainerName) not exists in Device ($DeviceName)"
            }
            
            $TotalVolumesCount += $ContainerData.VolumeCount
            If ($ContainerData.VolumeCount -eq 0) {
                Write-Output "  Volume container ($ContainerName) has zero volumes"
                continue
            }
            
            $volumes = Get-AzureStorSimpleDeviceVolumeContainer -DeviceName $DeviceName -VolumeContainerName $ContainerName | Get-AzureStorSimpleDeviceVolume -DeviceName $DeviceName -ErrorAction:SilentlyContinue
            foreach ($volume in ($volumes | Sort-Object {$_.Name}))
            { 
                $VolumeProp = @{ ContainerName=$ContainerName; Volume=$volume; HasBackup=$null; IsClonedAlready=$false }
                $VolObj = New-Object PSObject -Property $VolumeProp
                $VolList += $VolObj
            }
        }

        if ($TotalVolumesCount -eq 0) {
            throw "  No volumes exist in the containers"
        }
        
        # Clone all the volumes in the volume containers as per the latest backup
        Write-Output "Triggering and waiting for clone(s) to finish"
        foreach ($VolumeObj in $VolList)
        {
            $volume = $VolumeObj.Volume
            $targetdevicevolume = Get-AzureStorSimpleDeviceVolume -DeviceName $TargetDeviceName -VolumeName $volume.Name -ErrorAction:SilentlyContinue
            if ($targetdevicevolume -ne $null)
            {
                # Skipped volume cloning due to cloned volume already available; it may not be deleted in previous process
                $VolumeObj.IsClonedAlready = $true
                Write-Output "  Volume ($($volume.Name)) already exists" 
                continue
            }

            $backups = $volume | Get-AzureStorSimpleDeviceBackup -DeviceName $DeviceName | Where-Object {$_.Type -eq "CloudSnapshot"} | Sort "CreatedOn" -Descending
            if ($backups -eq $null) {
                $VolumeObj.HasBackup = $false
                Write-Output "  *No backup exists for the volume ($($volume.Name)) - volume container ($($VolumeObj.ContainerName))"
                continue
            }

            # Gives the latest backup
            $latestBackup = $backups[0]
            $VolumeObj.HasBackup = $true
            $VolumeObj.IsClonedAlready = $false
            
            # Match the volume name with the volume data inside the backup
            $snapshots = $latestBackup.Snapshots
            $snapshotToClone = $null
            foreach ($snapshot in $snapshots)
            {
                if ($snapshot.Name -eq $volume.name)
                {
                    $snapshotToClone = $snapshot
                    break
                }
            }

            $jobID = Start-AzureStorSimpleBackupCloneJob -SourceDeviceName $DeviceName -TargetDeviceName $TargetDeviceName -BackupId $latestBackup.InstanceId -Snapshot $snapshotToClone -CloneVolumeName $volume.Name -TargetAccessControlRecords $VMAcr -Force
            if ($jobID -eq $null)
            {
                throw "  Clone couldn't be initiated for volume ($($volume.Name)) - volume container ($($VolumeObj.ContainerName))"
            }
                
            $checkForSuccess = $true
            while ($true)
            {
                $status = Get-AzureStorSimpleJob -InstanceId $jobID
                Start-Sleep -s $SLEEPTIMEOUTSMALL
                if ( $status.Status -ne "Running")
                {
                    if ( $status.Status -ne "Completed") {
                        $checkForSuccess = $false
                    }
                    break
                }
            }

            if ($checkForSuccess) {
                Write-Output "  Clone successful for volume ($($volume.Name))"
            }
            else {
                throw "  Clone unsuccessful for volume ($($volume.Name))"
            }
        }
    }
    
    # Fetching IQN & IP Address of the Virtual device
    $SVAIP = (Get-AzureVM -ServiceName $TargetDeviceName -Name $TargetDeviceName).IpAddress
    If ($SVAIP -eq $null) {
        throw "Unable to get the IP Address of Azure VM ($TargetDeviceName)"
    }
    
    $SVAIQN = (Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName).TargetIQN
    If ($SVAIQN -eq $null) {
        throw "Unable to fetch IQN of the SVA ($TargetDeviceName)"
    }
    
    # Create the iSCSI target portal and mount the volumes, return the drive letters of the mounted StorSimple volumes
    Write-Output "Create the iSCSI target portal and mount the volumes"
    
    $RetryCount = 0
    while ($RetryCount -lt 2)
    {
        try
        {
            $drives = InlineScript {
                Invoke-Command -ConnectionUri $Using:VMWinRMUri -Credential $Using:VMCredential -ScriptBlock { 
                    param([String]$SVAIP, [String]$SVAIQN, [Int]$SLEEPTIMEOUTSMALL)
                    
                        # Disconnect all connected hosts
                        Get-IscsiTarget | Disconnect-IscsiTarget -Confirm:$false -ErrorAction:SilentlyContinue
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        
                        # Remove all connected hosts
                        Get-IscsiTargetPortal | Remove-IscsiTargetPortal -Confirm:$false -ErrorAction:SilentlyContinue
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        
                        Update-StorageProviderCache
                        Update-HostStorageCache 
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        
                        # Collect drive list
                        $initialdisks = (Get-Volume | Where-Object {$_.FileSystem -eq 'NTFS'})
                        if ($initialdisks -eq $null) {
                            throw "Unable to get the volumes on the VM"
                        }
                        
                        $newportal = New-IscsiTargetPortal -TargetPortalAddress $SVAIP -ErrorAction:SilentlyContinue
                        If ($newportal -eq $null) {
                            throw "Unable to create a new iSCSI target portal"
                        }
                        
                        $connection = Connect-IscsiTarget -NodeAddress $SVAIQN -IsPersistent $true -ErrorAction:SilentlyContinue
                        $sess = Get-IscsiSession
                        If ($sess -eq $null) {
                            throw "Unable to connect the iSCSI target (SVA)"
                        }
                        
                        Update-StorageProviderCache
                        Update-HostStorageCache
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                                    
                        # Collect drive list after mount
                        $finaldisks = (Get-Volume | Where-Object {$_.FileSystem -eq 'NTFS'})
                        if ($finaldisks -eq $null) {
                            throw "Unable to get the volumes after mounting"
                        }
                        
                        $drives = ((Compare-Object $initialdisks $finaldisks -Property 'DriveLetter' | where {$_.SideIndicator -eq "=>"}).DriveLetter | Sort)
                        
                        # Output of InlineScript
                        ($drives -Join ",")
                        
                } -Argumentlist $Using:SVAIP,$Using:SVAIQN,$Using:SLEEPTIMEOUTSMALL
                
            }
        } catch [Exception] {
            Write-Output $_.Exception.GetType().FullName;
            Write-Output $_.Exception.Message;
        }
        
        if ($drives -eq $null -or $drives.Length -eq 0) {
            if ($RetryCount -eq 0) {
                Write-Output "  Retrying for drive letters of the mounted StorSimple volumes"
            }
            else {
                Write-Output "  Unable to read the StorSimple drives"
            }
            
            # Sleep for 10 seconds before trying again
            Start-Sleep -s $SLEEPTIMEOUTSMALL
            $RetryCount += 1
        }
        else {
            $RetryCount = 2 # To stop the iteration; similar as 'break' statement
        }
    }
    
    if ($drives -eq $null -or $drives.Length -eq 0) {
        throw "Unable to read StorSimple drives"
    }
    
    Write-Output "Drive letters: $drives"
    
    # Set Drivelist
    $DrivesCol = $drives.Split(",").Trim()
    $DriveList = @()
    foreach ($driveletter in $DrivesCol) {
        $DriveProp = @{ DriveLetter=$driveletter; IsChkDskExecutionDone=$null; HasBadSectors=$null; HasNoSummaryInfo=$null }
        $DriveObject = New-Object PSObject -Property $DriveProp
        $DriveList += $DriveObject
    }
            
    Write-Output "Attempting to trigger CHKDSK command"
    InlineScript 
    {
        $ScriptContainer = $Using:ScriptContainer
        $ScriptName = $Using:ScriptName
        $VMName = $Using:VMName
        $VMServiceName = $Using:VMServiceName
        $TargetDeviceName = $Using:TargetDeviceName 
        $DeviceName = $Using:DeviceName 
        $StorageAccountName = $Using:StorageAccountName
        $StorageAccountKey = $Using:StorageAccountKey
        $SourceBlob = $Using:SourceBlob
        $DriveList = $Using:DriveList
        $ChkDskLogFile = $Using:chkdskLogFile
        
        # Convert to lower case coz volume container name allows lower case letters, numbers & hypens
        $ScriptContainer = $ScriptContainer.ToLower()
         
        # Create Storage Account Credential
        $sac = Get-AzureStorSimpleStorageAccountCredential -StorageAccountName $StorageAccountName -ErrorAction:SilentlyContinue 
        If ($sac -eq $null) {
            $sac = New-SSStorageAccountCredential -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -UseSSL $false -ErrorAction:SilentlyContinue -WaitForComplete
            if ($sac -eq $null) {
                throw "  Unable to create a Storage Account Credential ($StorageAccountName)"
            }
        }
                  
        $context = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
        if ($context -eq $null) {
            throw "  Unable to create a new storage context"
        }
        
        $container = Get-AzureStorageContainer -Name $ScriptContainer -Context $context -ErrorAction:SilentlyContinue
        if ($container -eq $null) {
            $newcontainer = New-AzureStorageContainer -Name $ScriptContainer -Context $context
            if ($newcontainer -eq $null) {
                throw "  Unable to create a container to store the script ($ScriptContainer)"
            }
        }       
        
        $chkdskcmd += "CHKDSK DriveLetter: > `'$ChkDskLogFile`'; `n"        
        $text = "Get-ChildItem `'$Using:ChkDskLogFolderPath`' `'chkdsk-log-*.log`' -Force | Remove-Item -Confirm:`$false -Force; `n"
        $text += "Start-Sleep -s $($Using:SLEEPTIMEOUT); `n"
        foreach ($driveLetter in $DriveList.DriveLetter) {
            $text += ($chkdskcmd -replace "DriveLetter", "$driveLetter")
        }
        
        $ScriptName = 'chkdsk-' + $VMName + '.ps1'
        $Scriptfilename = "c:\file-chkdsk-" + $VMName + ".ps1"
        $text | Set-Content $Scriptfilename
          
        $uri = Set-AzureStorageBlobContent -Blob $ScriptName -Container $ScriptContainer -File $Scriptfilename -context $context -Force
        if ($uri -eq $null) 
        {
            throw "Unable to Write script to the container ($Scriptfilename)"
        }
        $sasuri = New-AzureStorageBlobSASToken -Container $ScriptContainer -Blob $ScriptName -Permission r -FullUri -Context $context
        if ($sasuri -eq $null) 
        {
            throw "Unable to get the URI for the script ($ScriptContainer)"
        }
        $AzureVM = Get-AzureVM -ServiceName $VMServiceName -Name $VMName       
        if ($AzureVM -eq $null) 
        {
            throw "Unable to access the Azure VM ($VMName)"
        }
        $extension = $AzureVM.ResourceExtensionStatusList | Where-Object {$_.HandlerName -eq "Microsoft.Compute.CustomScriptExtension"}
        if ($extension -ne $null) 
        {
            Write-Output "  Uninstalling custom script extension" 
            $result = Set-AzureVMCustomScriptExtension -Uninstall -ReferenceName CustomScriptExtension -VM $AzureVM | Update-AzureVM
        }
                           
        Write-Output "  Installing custom script extension" 
        $result = Set-AzureVMExtension -ExtensionName CustomScriptExtension -VM $AzureVM -Publisher Microsoft.Compute -Version 1.7 | Update-AzureVM    
                                        
        Write-Output "  Running script on the VM"         
        $result = Set-AzureVMCustomScriptExtension -VM $AzureVM -FileUri $sasuri -Run $ScriptName | Update-AzureVM
    }

    # Sleep for 60 seconds before initiate to verify the CHKDSK status
    Start-Sleep -s $SLEEPTIMEOUT
    
    Write-Output "Attempting to fetch the CHKDSK result"
    Write-Output "CHKDSK Logs location: $ChkDskLogFolderPath"
    $HasChkDskFailures = $false
    $IsChkDskExecutionCompletedForAllDisks = $false
    $IterationIndex = 1
    $ChkDskCompletedDrivesCount = 0
    While ($IsChkDskExecutionCompletedForAllDisks -eq $false)
    {
        foreach ($DriveObj in $DriveList)
        {
            if ($DriveObj.IsChkDskExecutionDone -ne $true) 
            {
                $LogFilePath = ($ChkDskLogFile -replace "DriveLetter", "$($DriveObj.DriveLetter)")
                $ChkDskProgressState=InlineScript 
                {
                    Invoke-Command -ConnectionUri $Using:VMWinRMUri -Credential $Using:VMCredential -ScriptBlock {
                        param([String]$LogFilePath)
                        
                        If (Test-Path $LogFilePath) 
                        {
                            # CHKDSK log file generated
                            $LogStatus = 0
                            
                            $StartDate = (Get-ItemProperty -Path $LogFilePath).LastWriteTime
                            $EndDate = Get-Date
                            $LastWriteTimeInMinutes = (NEW-TIMESPAN -Start $StartDate -End $EndDate).Minutes
                            $LastWriteTimeInHours = (NEW-TIMESPAN -Start $StartDate -End $EndDate).Hours
                            
                            If ($LastWriteTimeInMinutes -ge 1)
                            {
                                $logEndTag = "allocation units available on disk"
                                $zeroBadSectorTag = "0 KB in bad sectors"
                                $IsSummaryFound = ((Select-String $LogFilePath -pattern $logEndTag) -ne $null)
                                $IsZeroBadSectorFound = ((Select-String $LogFilePath -pattern $zeroBadSectorTag) -ne $null)
                                
                                If ($IsSummaryFound -and $IsZeroBadSectorFound) {
                                    # Log file & Summary info available & Zero bad sectors found in the log file
                                    $LogStatus = 1
                                }
                                elseIf ($IsSummaryFound -and $IsZeroBadSectorFound -eq $false) {
                                    # Log file & Summary info available & Has bad sectors found in the log file
                                    $LogStatus = 2
                                }
                                elseIf ($LastWriteTimeInHours -ge 2) {
                                    # Log file available but expected summary not found
                                    $LogStatus = 3
                                }
                                else {
                                    # Log file found but summary not available.. May have a chance of CHKDSK is still in progress..
                                    $LogStatus = 4
                                }
                            }
                            else {
                                # CHKDSK process still running
                                $LogStatus = 5
                            }
                        }
                        else {
                            # CHKDSK log file not found at specified location
                            $LogStatus = 6
                        }
                        # Output of InlineScript
                        $LogStatus
                    } -Argumentlist $Using:LogFilePath
                }
                
                $DriverStatus = "CHKDSK execution in progress"
                If ($ChkDskProgressState -eq 1 -or $ChkDskProgressState -eq 2 -or $ChkDskProgressState -eq 3) {
                    $DriverStatus = "CHKDSK execution completed"
                }
                
                Write-Output "  Drive: $($DriveObj.DriveLetter)  Status: $DriverStatus"
                
                # Update current drive status
                InlineScript {
                    $DriveObj = $Using:DriveObj
                    $ChkDskProgressState = $Using:ChkDskProgressState
                    $DriveObj.IsChkDskExecutionDone = ($ChkDskProgressState -eq 1 -or $ChkDskProgressState -eq 2 -or $ChkDskProgressState -eq 3)
                    $DriveObj.HasBadSectors = ($ChkDskProgressState -eq 2)
                    $DriveObj.HasNoSummaryInfo = ($ChkDskProgressState -eq 3)
                }
                
                # Set CHKDSK Status            
                If ($ChkDskProgressState -eq 2 -or $ChkDskProgressState -eq 3) { 
                    $HasChkDskFailures = $true
                    $ChkDskCompletedDrivesCount++
                }
                elseIf ($ChkDskProgressState -eq 1) {
                    $ChkDskCompletedDrivesCount++
                }
            }
        }
        Write-Output " Completed drive(s): $ChkDskCompletedDrivesCount"
        Write-Output " Total drives: $($DriveList.Length)"
        # Verify whether all drives chkdsk process completed or not
        $IsChkDskExecutionCompletedForAllDisks = ($ChkDskCompletedDrivesCount -eq $DriveList.Length)
        If ($IsChkDskExecutionCompletedForAllDisks -eq $false) { 
            Write-Output "  CHKDSK execution process still running..."
            Write-Output "  Waiting for sleep ($SLEEPTIMEOUTLARGE seconds) to be finished"
            Start-Sleep -s $SLEEPTIMEOUTLARGE
        }
        
        $IterationIndex += 1
    }
    
    $MailMessage = "<html><head><style>body { font-family:'calibri'; font-size:'11pt'; color: #3366CC; }td.uppercase { text-transform: uppercase; } td.success { color: #2C6700; font-style: italic; } td.fail { color: #F20056; font-style: italic; } h1 { padding-bottom: 5pt; }</style></head><body><table cellpadding='2' cellspacing='0'><tr><td colspan='2'><h1>CHKDSK Report</h1></td></tr>"
    $MailMessage += "<tr><td style='width: 180pt;'>Device name: </td><td class='uppercase'>$DeviceName</td></tr>"
    $MailMessage += "<tr><td>Target Device name: </td><td class='uppercase'>$TargetDeviceName</td></tr>"
    $MailMessage += "<tr><td>Virtual machine name: </td><td class='uppercase'>$VMName</td></tr>"
    $MailMessage += "<tr><td>Volume containers: </td><td class='uppercase'>$VolumeContainers</td></tr>"
    $MailMessage += "<tr><td>CHKDSK Log files location: </td><td>$ChkDskLogFolderPath</td></tr>"
    $MailMessage += "<tr><td colspan='2' style='padding-top: 10pt; font-weight: bold;'>CHKDSK Result</td></tr>"

    If ($HasChkDskFailures)
    {
        Write-Output "`n `n `nCHKDSK Result: "
        Write-Output "  Windows has scanned the file system and found disk failures."
        $MailMessage += "<tr><td colspan='2' class='fail'>Windows has scanned the file system and found disk failures.</td></tr>"
        
        Write-Output "`n `n `nSUMMARY DETAILS "
        $MailMessage += "<tr><td colspan='2' style='padding-top: 25pt; font-weight: bold;' class='uppercase'>Summary details </td></tr>"
        $failuredrives = ($DriveList | Where-Object { $_.HasBadSectors })
        If ($failuredrives -ne $null)
        {
            $ChkDskFailureDrives = $($failuredrives.DriveLetter) -Join ","
            $MailMessage += "<tr><td>Drives where chkdsk found failures: </td><td class='uppercase'>$ChkDskFailureDrives</td></tr>"
            Write-Output "  Drives where chkdsk found failures: $ChkDskFailureDrives"
            
        }
        $nosummarydrives = ($DriveList | Where-Object { $_.HasNoSummaryInfo })
        If ($nosummarydrives -ne $null)
        {
            $SummaryNotFound = $($nosummarydrives.DriveLetter) -Join ","
            $MailMessage += "<tr><td>Drives where chkdsk could not run: </td><td class='uppercase'>$SummaryNotFound</td></tr>"
            Write-Output "  Drives where chkdsk could not run: $SummaryNotFound"
        }
        
        $MailMessage += "<tr><td colspan='2' style='padding-top: 20pt;'><i>Note: </i>Skipped to cleanup of volumes & volume containers.</td></tr>"
        $MailMessage += "<tr><td colspan='2' style='padding-bottom: 20pt;'><i>Please log in to the VM to see details of drives with failures</td></tr>" 
        Write-Output "  Skipped to cleanup volumes & volume containers."
        Write-Output "`n `n `nPlease log in to the VM to see details of drives with failures"
    }
    else
    {
        $MailMessage += "<tr><td colspan='2' class='success'  style='padding-bottom: 20pt; font-style: italic;'>Windows has scanned the file system and found no problems.</td></tr>"
        
        # Disconnect the target portal
        Write-Output "Disconnect the target portal & Unmount the StorSimple volume"
        $RetryCount = 0
        while ($RetryCount -lt 2)
        {
            $drivesAfterUnMount = InlineScript {
                Invoke-Command -ConnectionUri $Using:VMWinRMUri -Credential $Using:VMCredential -ScriptBlock { 
                    param([Int]$SLEEPTIMEOUTSMALL)
                    
                        # Disconnect all connected hosts
                        Get-IscsiTarget | Disconnect-IscsiTarget -Confirm:$false -ErrorAction:SilentlyContinue
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        
                        # Remove all connected hosts
                        Get-IscsiTargetPortal | Remove-IscsiTargetPortal -Confirm:$false -ErrorAction:SilentlyContinue
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        
                        Update-StorageProviderCache
                        Update-HostStorageCache 
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        
                        $drives = ((Get-Volume | Where-Object {$_.FileSystem -eq 'NTFS'}).DriveLetter | Sort)
                        
                        # Output of InlineScript
                        ($drives -Join ",")
                        
                } -Argumentlist $Using:SLEEPTIMEOUTSMALL
            }
            
            if ($drivesAfterUnMount -eq $null -or $drivesAfterUnMount.Length -eq 0 ) {
                if ($RetryCount -eq 0) {
                    Write-Output "  Retrying for disconnect the target portal & Unmount the StorSimple volume"
                }
                else {
                    Write-Output "  Unable to disconnect the target portal & Unmount the StorSimple volume"
                }
                
                # Sleep for 10 seconds before trying again
                Start-Sleep -s $SLEEPTIMEOUTSMALL
                $RetryCount += 1
            }
            else {
                $RetryCount = 2 # To stop the iteration; same as 'break' statement
            }
        }

        Write-Output "Initiating cleanup of volumes & volume containers"
        InlineScript
        {
            $TargetDeviceName = $Using:TargetDeviceName
            $VolContainerList = $Using:VolContainerList
            $SLEEPTIMEOUTSMALL = $Using:SLEEPTIMEOUTSMALL
            $SLEEPTIMEOUTLARGE = $Using:SLEEPTIMEOUTLARGE
            
            $VolumeContainers = Get-AzureStorSimpleDeviceVolumeContainer -DeviceName $TargetDeviceName
            if ($VolumeContainers -ne $null)
            {
                Write-Output " Deleting Volumes"
                foreach ($Container in $VolumeContainers) 
                {                
                    $Volumes = Get-AzureStorSimpleDeviceVolume -DeviceName $TargetDeviceName -VolumeContainer $Container  
                    if ($Volumes -ne $null -and $Container.VolumeCount -gt 0)
                    {
                        foreach ($Volume in $Volumes) 
                        {
                            $RetryCount = 0
                            while ($RetryCount -lt 2)
                            {
                                $isSuccessful = $true
                                $id = Set-AzureStorSimpleDeviceVolume -DeviceName $TargetDeviceName -VolumeName $Volume.Name -Online $false -WaitForComplete -ErrorAction:SilentlyContinue
                                if (($id -eq $null) -or ($id[0].TaskStatus -ne "Completed"))
                                {
                                    Write-Output "  Volume ($($Volume.Name)) could not be taken offline"
                                    $isSuccessful = $false
                                }
                                else
                                {
                                    $id = Remove-AzureStorSimpleDeviceVolume -DeviceName $TargetDeviceName -VolumeName $Volume.Name -Force -WaitForComplete -ErrorAction:SilentlyContinue
                                    if (($id -eq $null) -or ($id.TaskStatus -ne "Completed"))
                                    {
                                        Write-Output "  Volume ($($Volume.Name)) could not be deleted"
                                        $isSuccessful = $false
                                    }
                                    
                                }
                                if ($isSuccessful) {
                                    Write-Output "  Volume ($($Volume.Name)) deleted"
                                    break
                                }
                                else
                                {
                                    if ($RetryCount -eq 0) {
                                        Write-Output "   Retrying for volumes deletion"
                                    }
                                    else {
                                        throw "  Unable to delete Volume ($($Volume.Name))"
                                    }
                                                     
                                    Start-Sleep -s $SLEEPTIMEOUTSMALL
                                    $RetryCount += 1   
                                }
                            }
                        }
                    }
                }
                
                Start-Sleep -s $Using:SLEEPTIMEOUT
                Write-Output " Deleting Volume Containers"
                foreach ($Container in $VolumeContainers) 
                {
                    $RetryCount = 0 
                    while ($RetryCount -lt 2)
                    {
                        $id = Remove-AzureStorSimpleDeviceVolumeContainer -DeviceName $TargetDeviceName -VolumeContainer $Container -Force -WaitForComplete -ErrorAction:SilentlyContinue
                        if ($id -eq $null -or $id.TaskStatus -ne "Completed")
                        {
                            Write-Output "  Volume Container ($($Container.Name)) could not be deleted"   
                            if ($RetryCount -eq 0) {
                                Write-Output "  Retrying for volume container deletion"
                            }
                            else {
                                Write-Output "  Unable to delete Volume Container ($($Container.Name))" # throw
                            }
                            Start-Sleep -s $SLEEPTIMEOUTSMALL
                            $RetryCount += 1
                        }
                        else
                        {
                            Write-Output "  Volume Container ($($Container.Name)) deleted"
                            break
                        }
                    }
                }
            }
        }
        
        Write-Output "Attempting to shutdown the SVA & VM"
        foreach ($SystemInfo in $SystemList)
        {
            InlineScript
            {
                $SystemInfo = $Using:SystemInfo
                $Name = $SystemInfo.Name
                $ServiceName = $SystemInfo.ServiceName
                $SystemType = $SystemInfo.Type
                $SLEEPTIMEOUTSMALL = $Using:SLEEPTIMEOUTSMALL
                
                $RetryCount = 0
                while ($RetryCount -lt 2)
                {   
                    $Result = Stop-AzureVM -ServiceName $ServiceName -Name $Name -Force
                    if ($Result.OperationStatus -eq "Succeeded")
                    {
                        Write-Output "  $SystemType ($Name) succcessfully turned off"   
                        break
                    }
                    else
                    {
                        if ($RetryCount -eq 0) {
                            Write-Output "  Retrying for $SystemType ($Name) shutdown"
                        }
                        else {
                            Write-Output "  Unable to stop the $SystemType ($Name)"
                        }
                                         
                        Start-Sleep -s $SLEEPTIMEOUTSMALL
                        $RetryCount += 1   
                    }
                }
            }
        }
    }
    
    # Send summary info
    Write-Output "Attempting to send an e-mail"
    $MailSubject = "CHKDSK Status on " + [string](Get-Date -Format dd) + "-" + [string](Get-Date -Format MMM) + "-" + [string](Get-Date -Format yyyy)
    $MailMessage += "<tr><td colspan='2' style='font-style: italic;'>Please don't reply to this Message as this is a system generated Email.</td></tr></table></body></html>"
    InlineScript 
    {
        $MailFrom = $Using:MailFrom
        $MailTo = $Using:MailTo
        $MailCc = $Using:MailCc
        $MailSubject = $Using:MailSubject
        $MailMessage = $Using:MailMessage
        $MailSmtpServer = $Using:MailSmtpServer
        $MailPort = $Using:MailPort
        $MailCredential = $Using:MailCredential
        
        If ([string]::IsNullOrEmpty($MailPort) -eq $false -and [string]::IsNullOrEmpty($MailCc) -eq $false) {
            Send-MailMessage -From $MailFrom -To $MailTo -Cc $MailCc `
            -Subject $MailSubject -Body $MailMessage -SmtpServer $MailSmtpServer -Port $MailPort `
            -BodyAsHtml:$true -UseSSl:$true -Credential $MailCredential
        }
        elseIf ([string]::IsNullOrEmpty($MailPort) -eq $false -and [string]::IsNullOrEmpty($MailCc)) {
            Send-MailMessage -From $MailFrom -To $MailTo `
            -Subject $MailSubject -Body $MailMessage -SmtpServer $MailSmtpServer -Port $MailPort `
            -BodyAsHtml:$true -UseSSl:$true -Credential $MailCredential
        }
        elseIf ([string]::IsNullOrEmpty($MailPort) -and [string]::IsNullOrEmpty($MailCc) -eq $false) {
            Send-MailMessage -From $MailFrom -To $MailTo -Cc $MailCc `
            -Subject $MailSubject -Body $MailMessage -SmtpServer $MailSmtpServer `
            -BodyAsHtml:$true -UseSSl:$true -Credential $MailCredential
        }
        else {
            Send-MailMessage -From $MailFrom -To $MailTo `
            -Subject $MailSubject -Body $MailMessage -SmtpServer $MailSmtpServer `
            -BodyAsHtml:$true -UseSSl:$true -Credential $MailCredential
        }
        
        Write-Output "  E-Mail sent successfully"
    }
    
    If ($HasChkDskFailures -eq $false) {
        Write-Output "`n `n `nCHKDSK Result: "
        Write-Output "  Windows has scanned the file system and found no problems."
    }
    
    Write-Output "Job completed"
}
