# -------------------------------------------------------------------------------------
#
# Copyright (c) 20022, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# --------------------------------------------------------------------------------------

<#
    .DESCRIPTION
        A Powershell Script to sync certificates with Virtual Network Gateway
        
            Note: A newly deployed Virtual Network Gateway requires at least single CA root certificate to be configured in 
            order to execute this Automation Runbook.

            This Automation Runbook fetches CA certificates from configured GitHub repository and sync them with the respective
            VPN Gateway.
#>

# Function to extract certificate content from .pem
Function GetCertificateContent {

    param (
        [Parameter(Mandatory)]
        [String] $CertificatePath
    )

    $PEMHEADER = '-----BEGIN CERTIFICATE-----'
    $PEMFOOTER = '-----END CERTIFICATE-----'

    $CertificateContent = (Get-Content "${CertificatePath}" -EA Stop) -join ''
    $CertificateContent.Replace($PEMHEADER,'').Replace($PEMFOOTER,'')
}

$RepositoryOrganization    = Get-AutomationVariable -Name "av-repository-org"
$RepositoryName            = Get-AutomationVariable -Name "av-repository-name"
$RepositoryBranch          = Get-AutomationVariable -Name "av-repository-branch"
$SubscriptionID            = Get-AutomationVariable -Name "av-subscription-id"
$ResourceGroupName         = Get-AutomationVariable -Name "av-resource-group"
$VirtualNetworkGatewayName = Get-AutomationVariable -Name "av-vnetgw-name"
$GitHubCredential          = Get-AutomationPSCredential -Name "ac-github-pat"
$Token                     = $GitHubCredential.GetNetworkCredential().Password

$ZipFile          = "C:\$RepositoryName.zip"
$OutputFolder     = "C:\$RepositoryName\$RepositoryBranch"
$RepositoryZipUrl = "https://api.github.com/repos/$RepositoryOrganization/$RepositoryName/zipball/$RepositoryBranch"

if (!$Token) {
    throw("'GitHubToken' variable asset does not exist or is empty.")
}

try {
    "Logging in to Azure..."
    Connect-AzAccount -Identity -SubscriptionId $SubscriptionID
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}

# Download the GitHub repository as zip
Invoke-RestMethod -Uri $RepositoryZipUrl -Headers @{"Authorization" = "token $Token"} -OutFile $ZipFile

# Extract the downloaded GitHub zip
Expand-Archive -Path $ZipFile -DestinationPath $OutputFolder -Verbose

# Remove the zip from temporary machine
Remove-Item -Path $ZipFile -Force

# Fetch the output path to the downloaded repository
$OutputPath = (ls $OutputFolder)

# Get all root CA certificated from repository
$RootCertificates = (Get-ChildItem -Filter *.pem -Path $OutputFolder/$OutputPath).BaseName

# Get all root certs from VPN Gateway
$VPNRootCertificates = Get-AzVpnClientRootCertificate -ResourceGroupName $ResourceGroupName -VirtualNetworkGatewayName $VirtualNetworkGatewayName | Select -Property Name,PublicCertData
$VPNCertificates     = $VPNRootCertificates | Select -ExpandProperty Name

# List all CA certificates that are need to be added to the VPN Gateway
$CertificatesToAdd = ($RootCertificates | Where {$VPNCertificates -NotContains $_})
if ($CertificatesToAdd) { $CertificatesToAdd = $CertificatesToAdd.Split("`n`r") }

# List all CA certificates that are to be removed from the VPN Gateway
$CertificatesToRemove = ($VPNCertificates | Where {$RootCertificates -NotContains $_})
if ($CertificatesToRemove) { $CertificatesToRemove = $CertificatesToRemove.Split("`n`r") }

Write-Output ("Root certificates to add: " + $(If ([string]::IsNullOrEmpty($CertificatesToAdd)) { "None" } Else { $CertificatesToAdd }))
Write-Output ("Root certificates to remove: " + $(If ([string]::IsNullOrEmpty($CertsToRemove)) { "None" } Else { $CertsToRemove }))

# Add CA certificates to the VPN Gateway
foreach ($Cert in $CertificatesToAdd) {

    Write-Output ("Adding certificate: $Cert to VPN Gateway")

    $CertificateContent = GetCertificateContent -CertPath "${OutputFolder}\${OutputPath}\${Cert}.pem"
    $Output             = Add-AzVpnClientRootCertificate -PublicCertData $CertificateContent -ResourceGroupName $ResourceGroupName -VirtualNetworkGatewayName $VirtualNetworkGatewayName -VpnClientRootCertificateName $Cert

    # Handle error scenario
}

# Remove CA certificates from VPN Gateway
foreach ($Cert in $CertificatesToRemove) {

    Write-Output ("Removing certificate: $Cert from VPN Gateway")

    $CertificateContent = $VPNRootCertificates | Where-Object -Property Name -eq -Value $Cert | Select -ExpandProperty PublicCertData
    $Output             = Remove-AzVpnClientRootCertificate -PublicCertData $CertificateContent -ResourceGroupName $ResourceGroupName -VirtualNetworkGatewayName $VirtualNetworkGatewayName -VpnClientRootCertificateName $Cert

    # Handle error scenario
}

# Remove extracted GitHub repository folder and clean
Remove-Item -Path $OutputFolder/$OutputPath -Force -Recurse
