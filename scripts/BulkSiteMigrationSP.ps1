# Copy OneDrive for Business sites from a source tenant to a destination tenant
# Use a runspace pool to execute a scriptblock asynchronously
Import-Module Sharegate

# ShareGate settings

# Incremental site copy
$copySettings = New-CopySettings -OnContentItemExists IncrementalUpdate

# Custom property template for copy filtering
$propertyTemplate = New-PropertyTemplate -AuthorsAndTimestamps -VersionHistory -Permissions -WebParts -NoLinkCorrection -ExcludeFileExtension {pkr; skr;} #-VersionLimit 10 

# Add User And Group Mapping
$mappingSettings = New-MappingSettings
# Import user/group mapping file
$mappingSettings = Import-UserAndGroupMapping -MappingSettings $mappingSettings -Path ".\UserMappings.sgum"
$mappingSettings = Set-UserAndGroupMapping -MappingSettings $mappingSettings -UnresolvedUserOrGroup -Destination "Inactive users group"

# Vars
$csvFile = ".\OneDriveMappingsTable.csv"
$oneDriveSitesHash = new-object System.Collections.Hashtable

# Use previously created secure string
$secureString1 = ""
# SP username
$srcUsername = ""
$srcPassword = ConvertTo-SecureString $secureString1

# Import a CSV file into memory
$table = Import-CSV $csvFile -Delimiter ","

function Copy-OneDriveSiteAsync {

    Param(
        $oneDriveSitesHash
    )

    # Connect to destination tenants with admin privileges
    $connectionSrc = Connect-Site -Url https://yourSite-admin.sharepoint.com -Username $srcUsername -Password $srcPassword
    $connectionDst = Connect-Site -Url https://yourSite-admin.sharepoint.com -Browser
  
    # Create and open runspace pool, setup runspaces array with min and max threads
    $pool = [RunspaceFactory]::CreateRunspacePool(1, 4)
    $pool.ApartmentState = "MTA"
    $pool.Open()
    #$pool.BeginOpen()
    $runspaces = new-object System.Collections.ArrayList
    $results = new-object System.Collections.ArrayList

    # scriptblock with logic to run in each runspace
    # Scriptblock with the copy-content command
    $scriptBlock = {
        Param (
            $oneDriveSitesHash,
            [string]$srcSiteURL,
            $connectionSrc,
            $connectionDst,
            $mappingSettings,
            $propertyTemplate,
            $copySettings
        )
        # Reset site variables to prevent mismatches during reconnection
        Set-Variable dstSiteUrl, srcSite, dstsite, srcList, dstList, copyContent
        Clear-Variable dstSiteURL
        Clear-Variable srcSite
        Clear-Variable dstSite
        Clear-Variable srcList
        Clear-Variable dstList
        Clear-Variable copyContent
        # The hash key is the source URL, the hash value is the destination URL 
        $dstSiteURL = $oneDriveSitesHash[$srcSiteURL]

        # Connect to personal OneDrive site and apply tenant permissions
        $srcSite = Connect-Site -Url $srcSiteURL -UseCredentialsFrom $connectionSrc
        $dstSite = Connect-Site -Url $dstSiteURL -UseCredentialsFrom $connectionDst

        # Get a list of all files on the site
        $srcList = Get-List -Site $srcSite -Name "Documents" #-Filter "-NE '*.skr' -or '*.pkr'"    
        $dstList = Get-List -Site $dstSite -Name "Documents"

        # Run the copy if the hash key and value match
        if($dstSiteURL -eq $oneDriveSitesHash[$srcSiteURL])
        {
            # Run copy command with mappings and incremental copy settings
            $copyContent = Copy-Content -SourceList $srcList -DestinationList $dstList -MappingSettings $mappingSettings -Template $propertyTemplate -CopySettings $copySettings

            # Export a report with the session ID as the filename
            Export-Report $copyContent -Path ".\Documents\SP-Migration\TestCopySiteReports\"
        }
    }
    
    # For tracking runspace messages
    $runspaceMessages = New-Object 'System.Management.Automation.PSDataCollection[psobject]'

    # Iterate over hash table, assign each key/value pair to a runspace in the pool, attach the script block and parameter values to the runspace, invoke the runspace
    Set-Variable srcSiteURL
    foreach($item in $oneDriveSitesHash.GetEnumerator())
    {
        Clear-Variable srcSiteURL      
        $srcSiteURL = $item.Key
        # create runspace
        $runspace = [PowerShell]::Create()
        # Add the scriptblock and arguments to the runspace
        [void]$runspace.AddScript($scriptblock).AddArgument($oneDriveSitesHash).AddArgument($srcSiteURL).AddArgument($connectionSrc).AddArgument($connectionDst).AddArgument($mappingSettings).AddArgument($propertyTemplate).AddArgument($copySettings)               
        # Associate our runspace with the pool
        $runspace.RunspacePool = $pool
        # Invoke runspace, include runspaceMessages params for both input and output
        $runspaces.Add([PSCustomObject]@{ RunSpace = $runspace; Status = $runspace.BeginInvoke($runspaceMessages, $runspaceMessages) })  
    }
    
    # Store runspace results for each task
    while ($runspaces.Status -ne $null) 
    {
        $completed = $runspaces | Where-Object { $_.Status.IsCompleted -eq $true }
        $completed | ForEach-Object {
            $result = $_.RunSpace.EndInvoke($_.Status)
            # Display output from runspace
            $runspaceMessages
            $results.Add($result)
            # free up the runspace resources to make room
            $_.Status = $null
        }
    }

    # free up all the pool resources
    $pool.Close()
    $pool.Dispose()
    Write-Host "Jobs Done!"
    # Export a report with the session ID as the filename
    return $results
}

# Create a hashtable with each users' source site URL as the key and the destination site URL as the value from the imported CSV file.
function hashMyCSV
{
    Set-Variable srcSite, dstSite
    foreach ($row in $table) 
    {
        Clear-Variable srcSite
        Clear-Variable dstSite
        $srcSite = $row.SourceSite
        $dstSite = $row.DestinationSite
        $oneDriveSitesHash[$srcSite] = $dstSite
    }

    # Call the Copy function and pass it the hash
    Copy-OneDriveSiteAsync($oneDriveSitesHash)
}

# Start script
hashMyCSV