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

.SYNOPSIS  

    Updates operating system images in WDS using a WSUS repository.

.DESCRIPTION  

    Updates all images in WDS using a WSUS repository. This script requires input,
    so in it's current state it must be run interactively. This script requires
    WDS running on Windows Server 2012 R2, which provides PowerShell cmdlets for
    managing Deployment Services.

    The script will request a "Scratch Folder." This folder should reside on a
    drive with plenty of room for extracting and mounting the WIM images. It will
    also ask for the path to the WSUSContent directory, which is a shared folder
    where WSUS stores all of it's updates.

.NOTES  

    Author : Brian Reich <breich@reich-consulting.net

.LINK  

    https://github.com/breich/UpdateWdsFromWsus
    
.EXAMPLE  

    Update WDS images using C:\Temp as a the "scratch" folder where images will
    be extracted, and use Z:\ as the location to look for the WSUS repository.
    In this example, Z: is a network drive mapped to the WSUSContent share on
    WSUS server:
    
    Update-WdsFromWsus -ScratchFolder "C:\Temp" -WsusContent "Z:\"
    
.RETURNVALUE  

    Returns true if the update succeeded, false if not.
    
.PARAMETER ScratchFolder

    The path to a folder that can be used to extract and work with WIM files
    from the WDS server. The folder should be on a drive that has plenty of
    space to work with extracted images.

.PARAMETER WsusContent

    The path to the WSUS "WSUSContent" share where updates are stored. You
    can specify the network path to the share, or you could map a network
    drive to the share and specify the drive name.
#>
function Update-WdsFromWsus() {

    Param(
        [string] $ScratchFolder,
        [string] $WsusContent
    )

    
    # Make sure temp path exists
    if( (Test-Path -Path $ScratchFolder ) -eq $false ) {
        Write-Host "Temp Folder $ScratchFolder doesn't exist, creating it."
        $createPath = New-Item -Path $ScratchFolder -ItemType directory

        if( $createPath -eq $false ) {

            Write-Host "Failed to create scratch path $ScratchFolder. Exiting."
            return $false
        }
    }

    $Images = Get-WdsInstallImage

    # Update each image.
    foreach( $Image in $Images ) {
        Update-WdsImage -Image $Image -Scratch $ScratchFolder -WsusContent $WsusContent
    }
}

<# 
    .SUMMARY Updates a specific image in the WDS repository.
#>
function Update-WdsImage() {

    
    Param(
        $Image,
        $ScratchFolder,
        $WsusContent
    )
    
    $ExportDestination    = "$ScratchFolder\" + $image.FileName
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
    $MountPath = "$ScratchFolder\$OldImageName"
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

$ScratchFolder = Read-Host "Enter the location to use as a scratch folder (ex. C:\Temp)"
$wsus    = Read-Host "Enter the location of the WSUS Repository (ex. Z:\WsusContent)"
$foo = Update-WdsFromWsus -Scratch $ScratchFolder -WsusContent $wsus