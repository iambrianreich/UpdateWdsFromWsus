<#

.SUMMARY

Updates all images in WDS using a WSUS repository. This script requires input,
so in it's current state it must be run interactively. This script requires
WDS running on Windows Server 2012 R2, which provides PowerShell cmdlets for
managing Deployment Services.

The script will request a "Scratch Folder." This folder should reside on a
drive with plenty of room for extracting and mounting the WIM images. It will
also ask for the path to the WSUSContent directory, which is a shared folder
where WSUS stores all of it's updates.

.SEE

Some VBScript that inspired this script:
http://technet.microsoft.com/en-us/magazine/hh825626.aspx

.AUTHOR

Brian Reich <breich@reich-consulting.net

#>
function Update-WdsFromWsus() {

    Param(
        [string] $Scratch,
        [string] $WsusContent
    )

    
    # Make sure temp path exists
    if( (Test-Path -Path $Scratch ) -eq $false ) {
        Write-Host "Temp Folder $Scratch doesn't exist, creating it."
        $createPath = New-Item -Path $Scratch -ItemType directory

        if( $createPath -eq $false ) {

            Write-Host "Failed to create scratch path $Scratch. Exiting."
            return $false
        }
    }

    $Images = Get-WdsInstallImage

    # Update each image.
    foreach( $Image in $Images ) {
        Update-WdsImage -Image $Image -Scratch $Scratch -WsusContent $WsusContent
    }
}

<# 
    .SUMMARY Updates a specific image in the WDS repository.
#>
function Update-WdsImage() {

    
    Param(
        $Image,
        $Scratch,
        $WsusContent
    )
    
    $ExportDestination    = "$Scratch\" + $image.FileName
    $ImageName      = $Image.ImageName
    $ImageNameParts = $ImageName.Split("|")
    $ImageName      = $ImageNameParts[0].Trim() + " | (Updated " + (Get-Date).ToShortDateString() + " via " + $MyInvocation.MyCommand.Name + ")"
    $FileName       = $Image.FileName
    $ImageGroup     = $Image.ImageGroup
    $OldImageName   = $Image.ImageName
    $Index          = $Image.Index 

    Write-Host "Updating " $OldImageName " (" $Image.FileName ")"

    Write-Host ".... Exporting $OldImageName to $ExportDestination"
    $Export = Export-WdsInstallImage  -Destination $ExportDestination -ImageName $OldImageName -FileName $FileName -ImageGroup $ImageGroup -NewImageName $ImageName -ErrorAction SilentlyContinue

    
    # Verify that mounting succeeded.
    if( $export -eq $null ) {

        Write-Host ".... Exporting $OldImageName to $exportDestination failed. Quitting."
        return $false;
    }

    # Create Mount path.
    $MountPath = "$Scratch\$OldImageName"
    if( ( Test-Path -Path $MountPath ) -eq $false ) {
        Write-Host ".... Mount Folder $MountPath doesn't exist, creating it."
        $crap = New-Item -Path $MountPath -ItemType directory
        
    }
    Write-Host ".... Mounting $OldImageName to $MountPath. Please be patient."
    $mount = Mount-WindowsImage -ImagePath $exportDestination -Path $MountPath -Index $Index -CheckIntegrity  -ErrorAction SilentlyContinue

    # Verify Mount.
    if( $mount -eq $null ) {

        Write-Host ".... Failed to mount $OldImageName to $MountPath. Quitting."
        return $false
    }

    Write-Host "Adding WSUS Packages from ""$WsusContent"" to Windows Image Mounted at ""$MountPath"" "
    
    $updatFolders = Get-ChildItem -Path $WsusContent
    
    foreach ($folder in $updatFolders) {
        Add-WindowsPackage -PackagePath $folder.FullName -Path $MountPath  -ErrorAction SilentlyContinue
    }
    
    # Dismount
    Write-Host ".... Dismounting and saving $OldImageName."
    $dismount = Dismount-WindowsImage -Path $MountPath -Save  -ErrorAction SilentlyContinue

    if( $dismount -eq $null ) {

        Write-Host "Failed to dismount and save changes to $OldImageName. Quitting."
        return $false
    }

    # Delete Mount Path
    Write-Host ".... Deleting mount path $MountPath"
    $deleteMountPath = Remove-Item -Path $MountPath

    Write-Host ".... Importing image to WDS"
    
    # The Import needs to be called differently depending on whether or not there's an UnattendFile.
    # If Import-WdsInstallImage is called with an empty or null UnattendFile, import fails.
    if( $Image.UnattendFile -eq $null -or $Image.UnattendFile -eq "" ) {
        Write-Host " Import-WdsInstallImage -ImageGroup $Image.ImageGroup -Path $ExportDestination -ImageName -DisplayOrder 0 -NewImageName $ImageName"
        $import = Import-WdsInstallImage -ImageGroup $Image.ImageGroup -Path $ExportDestination -DisplayOrder 0 -NewImageName $ImageName
    } else {
        $import = Import-WdsInstallImage -ImageGroup $Image.ImageGroup -UnattendFile $Image.UnattendFile -Path $ExportDestination -ImageName $OldImageName -DisplayOrder 0 -NewImageName $ImageName

    }

    if( $import -eq $null ) {

        Write-Host "Failed to import modified image to server. Quitting."
        return $false
    }

    # Delete  Export
    Write-Host ".... Removing Exported file $exportDestination"
    Remove-Item -Path $ExportDestination -Recurse  -ErrorAction SilentlyContinue
}

Write-Host "This script will update all of the images on the local WSUS folder"
Write-Host "with updates from WSUS.  You need to provide a location to use for"
Write-Host "temporary files, and the path to your WsusContent folder. This"
Write-Host "process can take a while, so consider running it over the weekend."
Write-Host ""

$scratch = Read-Host "Enter the location to use as a scratch folder (ex. C:\Temp)"
$wsus    = Read-Host "Enter the location of the WSUS Repository (ex. Z:\WsusContent)"
$foo = Update-WdsFromWsus -Scratch $scratch -WsusContent $wsus