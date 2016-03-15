# DataIntegrity
Follow below steps to run for data corruption in StorSimple volumes:
* Create Azure Automation Account
* Upload below scripts in automation account & publish both the scripts
    * Check-StorSimpleVolume-AssetsInput
    * Check-StorSimpleVolume-DiskIntegrity
* Create below credentials in automation account
    * AzureCredential
       - A credential containing an Org Id username, password with access to this Azure subscription
         Multi Factor Authentication must be disabled for this credential
    * VMCredential
       - A credential containing an username, password with access to Virtual Machine
    * MailCredential
       - A credential containing an Org Id username, password

* Run Check-StorSimpleVolume-AssetsInput script
    - This script lets you create the assets needed for the StorSimple data integrity checker which is uploaded.
  Once all assets created then run below step
* Run Check-StorSimpleVolume-DiskIntegrity script
    - This script lets you set up scheduled checks for data corruption in StorSimple volumes and sends a report with the results after every check. It works by cloning StorSimple volumes on to a StorSimple Cloud appliance, connects the volumes to a VM in Azure and runs chkdsk util
