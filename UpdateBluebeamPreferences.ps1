#Requires -Version 5.1

<#
.SYNOPSIS
    Updates Bluebeam Revu preferences and profiles with company-standard settings.

.DESCRIPTION
    This script modifies Bluebeam Revu configuration files:

    UserPreferences.xml:
    - Replaces the CustomColors section with values from config.json
    - Adds or repaths toolsets from config.json
    - Updates stamp directory path (first accessible path wins)
    - Updates template directory path (first accessible path wins)

    Profile files (*.bpx):
    - Adds or repaths Line Sets (Record Key="LineSetManager")
    - Adds or repaths Hatch Sets (Record Key="HatchSetManager")

    Creates a timestamped backup before changing any file. Backups are
    pruned automatically (the most recent 10 per file are kept).

.PARAMETER All
    Runs every update non-interactively (no menu, no prompts).
    Intended for deployment via Intune/GPO/login scripts.
    Exit codes: 0 = success, 1 = error, 2 = Bluebeam is running.

.EXAMPLE
    .\UpdateBluebeamPreferences.ps1
    Runs interactively with a menu.

.EXAMPLE
    .\UpdateBluebeamPreferences.ps1 -All
    Applies all updates silently.

.NOTES
    Author: Knit
    Version: 2.0
    Requires: PowerShell 5.1 or higher
#>

[CmdletBinding()]
param(
    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script configuration
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "config.json"
$BackupsToKeep = 10

# ============================================================
# Output helpers
# ============================================================

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# ============================================================
# Bluebeam process detection
# ============================================================

function Test-BluebeamRunning {
    $revuProcesses = @(Get-Process -Name "Revu*" -ErrorAction SilentlyContinue)
    return ($revuProcesses.Count -gt 0)
}

function Wait-ForBluebeamClose {
    while ($true) {
        if (-not (Test-BluebeamRunning)) {
            return $true
        }

        Write-ColorOutput "`n========================================" -Color Yellow
        Write-ColorOutput "WARNING: Bluebeam Revu is Currently Running!" -Color Yellow
        Write-ColorOutput "========================================" -Color Yellow
        Write-ColorOutput "`nBluebeam Revu MUST be closed before updating preferences." -Color White
        Write-ColorOutput "Modifying preferences while Bluebeam is open can cause data loss." -Color Red
        Write-ColorOutput "`nPlease choose an option:" -Color White
        Write-ColorOutput "  1. I have closed Bluebeam (check again)" -Color White
        Write-ColorOutput "  2. Exit without making changes" -Color White

        $choice = Read-Host "`nEnter your choice (1-2)"

        switch ($choice) {
            "1" {
                if (-not (Test-BluebeamRunning)) {
                    Write-ColorOutput "`nBluebeam Revu is now closed. Continuing..." -Color Green
                    return $true
                }
                Write-ColorOutput "`nBluebeam Revu is still running. Please close all Bluebeam windows." -Color Red
            }
            "2" {
                Write-ColorOutput "`nExiting without changes." -Color Yellow
                return $false
            }
            default {
                Write-ColorOutput "`nInvalid choice. Please select 1 or 2." -Color Red
            }
        }
    }
}

# ============================================================
# File location and backup
# ============================================================

function Find-BluebeamProfileFolder {
    # Finds the newest Revu version folder that contains a UserPreferences.xml.
    # Handles both year-style (2018, 2019) and short-style (20, 21) folder names.
    $revuRoot = Join-Path $env:APPDATA "Bluebeam Software\Revu"

    if (-not (Test-Path $revuRoot)) {
        return $null
    }

    $candidates = @()
    foreach ($dir in (Get-ChildItem -Path $revuRoot -Directory)) {
        $versionNumber = 0
        if (-not [int]::TryParse($dir.Name, [ref]$versionNumber)) {
            continue
        }
        if (-not (Test-Path (Join-Path $dir.FullName "UserPreferences.xml"))) {
            continue
        }
        # Normalize short version names (20, 21) to full years for sorting
        if ($versionNumber -lt 100) {
            $versionNumber += 2000
        }
        $candidates += [pscustomobject]@{
            Path    = $dir.FullName
            Version = $versionNumber
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $best = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    return $best.Path
}

function Backup-File {
    param([string]$FilePath)

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path (Split-Path $FilePath) "Backups"

    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir | Out-Null
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $extension = [System.IO.Path]::GetExtension($FilePath)
    $backupFile = Join-Path $backupDir ("{0}_{1}{2}" -f $baseName, $timestamp, $extension)
    Copy-Item -Path $FilePath -Destination $backupFile -Force

    # Prune old backups of this file, keeping the most recent ones
    $pattern = "{0}_*{1}" -f $baseName, $extension
    $oldBackups = @(Get-ChildItem -Path $backupDir -Filter $pattern -File |
        Sort-Object Name -Descending |
        Select-Object -Skip $BackupsToKeep)
    foreach ($old in $oldBackups) {
        Remove-Item -Path $old.FullName -Force -ErrorAction SilentlyContinue
    }

    return $backupFile
}

# ============================================================
# XML helpers
# ============================================================

function Read-XmlFile {
    param([string]$Path)

    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($Path)
    # Comma prevents PowerShell from enumerating the document's child nodes
    return , $doc
}

function Save-XmlFile {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [string]$Path,
        [string]$BackupFile
    )

    $XmlDoc.Save($Path)

    # Verify the saved file parses; restore the backup if it doesn't
    try {
        $verify = New-Object System.Xml.XmlDocument
        $verify.Load($Path)
    }
    catch {
        if ($BackupFile -and (Test-Path $BackupFile)) {
            Copy-Item -Path $BackupFile -Destination $Path -Force
            throw "Saved file failed XML validation and was restored from backup: $BackupFile"
        }
        throw
    }
}

function Get-OrCreateRecord {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [string]$Key
    )

    $record = $XmlDoc.SelectSingleNode("//Record[@Key='$Key']")

    if ($null -eq $record) {
        Write-ColorOutput "  Creating new $Key record..." -Color Gray
        $record = $XmlDoc.CreateElement("Record")
        $record.SetAttribute("Key", $Key)
        $XmlDoc.DocumentElement.AppendChild($record) | Out-Null
    }

    return $record
}

function Add-ChildElement {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [System.Xml.XmlElement]$Parent,
        [string]$Name,
        [string]$Value
    )

    $child = $XmlDoc.CreateElement($Name)
    $child.InnerText = $Value
    $Parent.AppendChild($child) | Out-Null
    return $child
}

# ============================================================
# Configuration
# ============================================================

function Load-Configuration {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath"
    }

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    return $config
}

function Test-ConfigHasSection {
    param(
        [PSCustomObject]$Config,
        [string]$Section
    )
    return ($Config.PSObject.Properties.Name -contains $Section)
}

# ============================================================
# Path expansion and accessibility
# ============================================================

function Expand-UserPath {
    param([string]$Path)

    # Replace C:\Users\{USERNAME} with the actual user profile directory.
    # This handles domain-joined computers correctly (e.g., jdoe.DOMAIN).
    $expanded = $Path.Replace('C:\Users\{USERNAME}', $env:USERPROFILE)
    $expanded = $expanded.Replace('{USERNAME}', $env:USERNAME)
    return $expanded
}

function Test-DirectoryAccessible {
    param([string]$Path)

    try {
        if (Test-Path -Path $Path -PathType Container) {
            # Try to list contents to verify read access
            Get-ChildItem -Path $Path -ErrorAction Stop | Out-Null
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

function Get-FirstAccessibleDirectory {
    param(
        [array]$Directories,
        [string]$Label
    )

    Write-ColorOutput "`nChecking $Label directory paths (in priority order)..." -Color Cyan

    foreach ($dir in $Directories) {
        $expandedPath = Expand-UserPath -Path $dir
        Write-ColorOutput "  Testing: $expandedPath" -Color Gray

        if (Test-DirectoryAccessible -Path $expandedPath) {
            Write-ColorOutput "  [OK] Accessible!" -Color Green
            return $expandedPath
        }
        Write-ColorOutput "  [X] Not accessible" -Color DarkGray
    }

    Write-ColorOutput "`n  Warning: No accessible $Label directories found!" -Color Yellow
    return $null
}

# ============================================================
# UserPreferences.xml updates
# ============================================================

function Update-CustomColors {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [PSCustomObject]$Config
    )

    Write-ColorOutput "`nUpdating Custom Colors..." -Color Cyan

    $prefsDict = Get-OrCreateRecord -XmlDoc $XmlDoc -Key "PreferencesDictionary"

    # Build the desired CustomColors node
    $newColors = $XmlDoc.CreateElement("CustomColors")
    $colorKeys = @("Color0", "Color1", "Color2", "Color3", "Color4", "Color5", "Color6", "Color7",
                   "Color8", "Color9", "Color10", "Color11", "Color12", "Color13", "Color14", "Color15")

    foreach ($key in $colorKeys) {
        if ($Config.customColors.PSObject.Properties.Name -contains $key) {
            Add-ChildElement -XmlDoc $XmlDoc -Parent $newColors -Name $key -Value $Config.customColors.$key.ToString() | Out-Null
        }
    }
    Add-ChildElement -XmlDoc $XmlDoc -Parent $newColors -Name "Count" -Value $Config.customColors.Count.ToString() | Out-Null

    # Compare against existing colors; skip if already identical
    $existingColors = $XmlDoc.SelectSingleNode("//CustomColors")

    if ($null -ne $existingColors -and $existingColors.OuterXml -eq $newColors.OuterXml) {
        Write-ColorOutput "  Custom colors already up to date." -Color Gray
        return 0
    }

    if ($null -ne $existingColors) {
        $existingColors.ParentNode.ReplaceChild($newColors, $existingColors) | Out-Null
        Write-ColorOutput "  + Replaced CustomColors section" -Color Green
    }
    else {
        $prefsDict.AppendChild($newColors) | Out-Null
        Write-ColorOutput "  + Added CustomColors section to PreferencesDictionary" -Color Green
    }

    return 1
}

function Update-Toolsets {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [PSCustomObject]$Config
    )

    Write-ColorOutput "`nUpdating Toolsets..." -Color Cyan

    $toolSetManager = Get-OrCreateRecord -XmlDoc $XmlDoc -Key "ToolSetManager"

    $addedCount = 0
    $repathedCount = 0
    $skippedCount = 0

    foreach ($toolset in $Config.toolsets) {
        # Toolsets are identified by their file name, so entries with a stale
        # directory get repathed instead of duplicated.
        $configLeaf = [System.IO.Path]::GetFileName($toolset.Path)
        $existingToolset = $null

        foreach ($ts in $toolSetManager.SelectNodes("ToolSet")) {
            $pathNode = $ts.SelectSingleNode("Path")
            if ($null -ne $pathNode) {
                $existingLeaf = [System.IO.Path]::GetFileName($pathNode.InnerText)
                if ($existingLeaf -ieq $configLeaf) {
                    $existingToolset = $ts
                    break
                }
            }
        }

        if ($null -eq $existingToolset) {
            $toolSetNode = $XmlDoc.CreateElement("ToolSet")
            Add-ChildElement -XmlDoc $XmlDoc -Parent $toolSetNode -Name "Path" -Value $toolset.Path | Out-Null
            Add-ChildElement -XmlDoc $XmlDoc -Parent $toolSetNode -Name "Title" -Value $toolset.Title | Out-Null
            $toolSetManager.AppendChild($toolSetNode) | Out-Null

            Write-ColorOutput "  + Added: $($toolset.Title) ($configLeaf)" -Color Green
            $addedCount++
        }
        else {
            $changed = $false

            $pathNode = $existingToolset.SelectSingleNode("Path")
            if ($pathNode.InnerText -ne $toolset.Path) {
                Write-ColorOutput "  ~ Repathed: $($toolset.Title) ($configLeaf)" -Color Yellow
                Write-ColorOutput "      Old: $($pathNode.InnerText)" -Color Gray
                Write-ColorOutput "      New: $($toolset.Path)" -Color Gray
                $pathNode.InnerText = $toolset.Path
                $changed = $true
            }

            $titleNode = $existingToolset.SelectSingleNode("Title")
            if ($null -eq $titleNode) {
                $titleNode = Add-ChildElement -XmlDoc $XmlDoc -Parent $existingToolset -Name "Title" -Value $toolset.Title
                $changed = $true
            }
            elseif ($titleNode.InnerText -ne $toolset.Title) {
                $titleNode.InnerText = $toolset.Title
                $changed = $true
            }

            if ($changed) {
                $repathedCount++
            }
            else {
                Write-ColorOutput "  - Already correct: $($toolset.Title) ($configLeaf)" -Color Gray
                $skippedCount++
            }
        }
    }

    Write-ColorOutput "`n  Summary: $addedCount added, $repathedCount updated, $skippedCount already correct" -Color Cyan

    return ($addedCount + $repathedCount)
}

function Update-DirectorySetting {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [string]$RecordKey,
        [string[]]$ElementPath,
        [string]$NewValue
    )

    $record = Get-OrCreateRecord -XmlDoc $XmlDoc -Key $RecordKey

    $node = $record
    foreach ($name in $ElementPath) {
        $child = $node.SelectSingleNode($name)
        if ($null -eq $child) {
            Write-ColorOutput "  Creating new $name element..." -Color Gray
            $child = $XmlDoc.CreateElement($name)
            $node.AppendChild($child) | Out-Null
        }
        $node = $child
    }

    $oldValue = $node.InnerText

    if ($oldValue -eq $NewValue) {
        Write-ColorOutput "  Path unchanged (already set to correct directory)" -Color Gray
        return 0
    }

    $node.InnerText = $NewValue
    Write-ColorOutput "  Old path: $oldValue" -Color Gray
    Write-ColorOutput "  New path: $NewValue" -Color Green
    Write-ColorOutput "  [SUCCESS] Directory updated!" -Color Green
    return 1
}

function Update-StampDirectory {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [PSCustomObject]$Config
    )

    Write-ColorOutput "`nUpdating Stamp Directory..." -Color Cyan

    $stampDir = Get-FirstAccessibleDirectory -Directories $Config.stampDirectories -Label "stamp"

    if ($null -eq $stampDir) {
        Write-ColorOutput "  Cannot update stamp directory - no accessible paths found." -Color Yellow
        return 0
    }

    return Update-DirectorySetting -XmlDoc $XmlDoc -RecordKey "PreferencesDictionary" -ElementPath @("AddStamp", "Directory") -NewValue $stampDir
}

function Update-TemplateDirectory {
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [PSCustomObject]$Config
    )

    Write-ColorOutput "`nUpdating Template Directory..." -Color Cyan

    $templateDir = Get-FirstAccessibleDirectory -Directories $Config.templateDirectories -Label "template"

    if ($null -eq $templateDir) {
        Write-ColorOutput "  Cannot update template directory - no accessible paths found." -Color Yellow
        return 0
    }

    return Update-DirectorySetting -XmlDoc $XmlDoc -RecordKey "TemplateData" -ElementPath @("Path") -NewValue $templateDir
}

# ============================================================
# Profile (*.bpx) updates: Line Sets and Hatch Sets
# ============================================================

function Update-SetRecord {
    <#
        Adds or repaths entries in a LineSetManager or HatchSetManager record.
        Entries are identified by the file name portion of their Path, so an
        entry pointing at the right file in the wrong location gets repathed
        rather than duplicated. Config Title and Path are enforced.
        Returns the number of changes made.
    #>
    param(
        [System.Xml.XmlDocument]$XmlDoc,
        [string]$RecordKey,      # "LineSetManager" or "HatchSetManager"
        [string]$ElementName,    # "LineSet" or "HatchSet"
        [array]$Sets,
        [bool]$IsLineSet
    )

    $changes = 0
    $record = $XmlDoc.SelectSingleNode("//Record[@Key='$RecordKey']")

    if ($null -eq $record) {
        Write-ColorOutput "    Creating new $RecordKey record..." -Color Gray
        $record = $XmlDoc.CreateElement("Record")
        $record.SetAttribute("Key", $RecordKey)
        $XmlDoc.DocumentElement.AppendChild($record) | Out-Null

        # Seed the Standard entry so the built-in set stays available
        $standard = $XmlDoc.CreateElement($ElementName)
        if ($IsLineSet) {
            $standard.SetAttribute("Type", "Standard")
            $standard.SetAttribute("Index", "0")
            Add-ChildElement -XmlDoc $XmlDoc -Parent $standard -Name "Hidden" -Value "False" | Out-Null
        }
        else {
            $standard.SetAttribute("Index", "0")
            Add-ChildElement -XmlDoc $XmlDoc -Parent $standard -Name "Title" -Value "Standard" | Out-Null
            Add-ChildElement -XmlDoc $XmlDoc -Parent $standard -Name "Path" -Value "Standard.bhx" | Out-Null
            Add-ChildElement -XmlDoc $XmlDoc -Parent $standard -Name "Hidden" -Value "False" | Out-Null
        }
        $record.AppendChild($standard) | Out-Null
        $changes++
    }

    foreach ($set in $Sets) {
        $configLeaf = [System.IO.Path]::GetFileName($set.Path)
        $existing = $null

        foreach ($node in $record.SelectNodes($ElementName)) {
            $pathNode = $node.SelectSingleNode("Path")
            if ($null -ne $pathNode) {
                $existingLeaf = [System.IO.Path]::GetFileName($pathNode.InnerText)
                if ($existingLeaf -ieq $configLeaf) {
                    $existing = $node
                    break
                }
            }
        }

        if ($null -eq $existing) {
            $newSet = $XmlDoc.CreateElement($ElementName)
            if ($IsLineSet) {
                $newSet.SetAttribute("Type", "Custom")
            }
            $newSet.SetAttribute("Index", "0")  # renumbered below
            Add-ChildElement -XmlDoc $XmlDoc -Parent $newSet -Name "Title" -Value $set.Title | Out-Null
            Add-ChildElement -XmlDoc $XmlDoc -Parent $newSet -Name "Path" -Value $set.Path | Out-Null
            Add-ChildElement -XmlDoc $XmlDoc -Parent $newSet -Name "Hidden" -Value "False" | Out-Null
            $record.AppendChild($newSet) | Out-Null

            Write-ColorOutput "    + Added: $($set.Title) ($configLeaf)" -Color Green
            $changes++
        }
        else {
            $pathNode = $existing.SelectSingleNode("Path")
            if ($pathNode.InnerText -ne $set.Path) {
                Write-ColorOutput "    ~ Repathed: $($set.Title) ($configLeaf)" -Color Yellow
                Write-ColorOutput "        Old: $($pathNode.InnerText)" -Color Gray
                Write-ColorOutput "        New: $($set.Path)" -Color Gray
                $pathNode.InnerText = $set.Path
                $changes++
            }

            $titleNode = $existing.SelectSingleNode("Title")
            if ($null -eq $titleNode) {
                Add-ChildElement -XmlDoc $XmlDoc -Parent $existing -Name "Title" -Value $set.Title | Out-Null
                $changes++
            }
            elseif ($titleNode.InnerText -ne $set.Title) {
                $titleNode.InnerText = $set.Title
                $changes++
            }
        }
    }

    # Renumber indexes so they stay sequential in document order
    $index = 0
    foreach ($node in $record.SelectNodes($ElementName)) {
        if ($node.GetAttribute("Index") -ne "$index") {
            $node.SetAttribute("Index", "$index")
            $changes++
        }
        $index++
    }

    return $changes
}

function Update-Profiles {
    param(
        [string]$ProfileFolder,
        [PSCustomObject]$Config,
        [bool]$IncludeLineSets,
        [bool]$IncludeHatchSets
    )

    Write-ColorOutput "`nUpdating Profiles (*.bpx)..." -Color Cyan

    # Non-recursive on purpose: skips built-in profiles in the _BuiltIn subfolder
    $bpxFiles = @(Get-ChildItem -Path $ProfileFolder -Filter "*.bpx" -File)

    if ($bpxFiles.Count -eq 0) {
        Write-ColorOutput "  No profile (.bpx) files found in $ProfileFolder" -Color Yellow
        return 0
    }

    $updatedFiles = 0

    foreach ($bpx in $bpxFiles) {
        Write-ColorOutput "`n  Profile: $($bpx.Name)" -Color White

        $doc = Read-XmlFile -Path $bpx.FullName
        $changes = 0

        if ($IncludeLineSets -and (Test-ConfigHasSection -Config $Config -Section "lineSets")) {
            $changes += Update-SetRecord -XmlDoc $doc -RecordKey "LineSetManager" -ElementName "LineSet" -Sets $Config.lineSets -IsLineSet $true
        }

        if ($IncludeHatchSets -and (Test-ConfigHasSection -Config $Config -Section "hatchSets")) {
            $changes += Update-SetRecord -XmlDoc $doc -RecordKey "HatchSetManager" -ElementName "HatchSet" -Sets $Config.hatchSets -IsLineSet $false
        }

        if ($changes -gt 0) {
            $backup = Backup-File -FilePath $bpx.FullName
            Save-XmlFile -XmlDoc $doc -Path $bpx.FullName -BackupFile $backup
            Write-ColorOutput "    Saved ($changes change(s)). Backup: $(Split-Path $backup -Leaf)" -Color Green
            $updatedFiles++
        }
        else {
            Write-ColorOutput "    No changes needed." -Color Gray
        }
    }

    Write-ColorOutput "`n  Summary: $updatedFiles of $($bpxFiles.Count) profile(s) updated" -Color Cyan

    return $updatedFiles
}

# ============================================================
# Task runner
# ============================================================

function Invoke-SelectedUpdates {
    param(
        [string]$ProfileFolder,
        [string]$PrefsFile,
        [PSCustomObject]$Config,
        [string[]]$Tasks
    )

    # --- UserPreferences.xml tasks ---
    $prefsTasks = @($Tasks | Where-Object { $_ -in @("Colors", "Toolsets", "Stamps", "Templates") })

    if ($prefsTasks.Count -gt 0) {
        Write-ColorOutput "`nLoading UserPreferences.xml..." -Color White
        $doc = Read-XmlFile -Path $PrefsFile

        $changes = 0
        if ($Tasks -contains "Colors")    { $changes += Update-CustomColors -XmlDoc $doc -Config $Config }
        if ($Tasks -contains "Toolsets")  { $changes += Update-Toolsets -XmlDoc $doc -Config $Config }
        if ($Tasks -contains "Stamps")    { $changes += Update-StampDirectory -XmlDoc $doc -Config $Config }
        if ($Tasks -contains "Templates") { $changes += Update-TemplateDirectory -XmlDoc $doc -Config $Config }

        if ($changes -gt 0) {
            Write-ColorOutput "`nSaving UserPreferences.xml..." -Color White
            $backup = Backup-File -FilePath $PrefsFile
            Save-XmlFile -XmlDoc $doc -Path $PrefsFile -BackupFile $backup
            Write-ColorOutput "Saved. Backup: $backup" -Color Green
        }
        else {
            Write-ColorOutput "`nUserPreferences.xml: no changes were necessary." -Color Yellow
        }
    }

    # --- Profile (*.bpx) tasks ---
    $includeLineSets = $Tasks -contains "LineSets"
    $includeHatchSets = $Tasks -contains "HatchSets"

    if ($includeLineSets -or $includeHatchSets) {
        Update-Profiles -ProfileFolder $ProfileFolder -Config $Config -IncludeLineSets $includeLineSets -IncludeHatchSets $includeHatchSets | Out-Null
    }
}

# ============================================================
# Main
# ============================================================

function Main {
    Write-ColorOutput "========================================" -Color Cyan
    Write-ColorOutput "Bluebeam Preferences Updater v2.0" -Color Cyan
    Write-ColorOutput "========================================`n" -Color Cyan

    $interactive = -not $All

    try {
        # Check if Bluebeam is running
        if ($interactive) {
            if (-not (Wait-ForBluebeamClose)) {
                Read-Host "`nPress Enter to exit"
                exit 0
            }
        }
        elseif (Test-BluebeamRunning) {
            Write-ColorOutput "ERROR: Bluebeam Revu is running. Close it and re-run." -Color Red
            exit 2
        }

        # Load configuration
        Write-ColorOutput "Loading configuration..." -Color White
        $config = Load-Configuration -ConfigPath $ConfigFile
        Write-ColorOutput "Configuration loaded successfully.`n" -Color Green

        # Locate the Bluebeam profile folder and UserPreferences.xml
        Write-ColorOutput "Searching for Bluebeam profile folder..." -Color White
        $profileFolder = Find-BluebeamProfileFolder

        if ($null -eq $profileFolder) {
            if (-not $interactive) {
                Write-ColorOutput "ERROR: No Bluebeam profile folder with UserPreferences.xml found." -Color Red
                exit 1
            }
            Write-ColorOutput "`nUserPreferences.xml not found automatically." -Color Yellow
            Write-ColorOutput "Please enter the full path to your UserPreferences.xml file:" -Color Yellow
            $manualPath = Read-Host "Path"

            if (-not (Test-Path $manualPath)) {
                Write-ColorOutput "ERROR: File not found: $manualPath" -Color Red
                Read-Host "`nPress Enter to exit"
                exit 1
            }
            $profileFolder = Split-Path -Parent $manualPath
        }

        $prefsFile = Join-Path $profileFolder "UserPreferences.xml"
        Write-ColorOutput "Found: $prefsFile`n" -Color Green

        $allTasks = @("Colors", "Toolsets", "Stamps", "Templates", "LineSets", "HatchSets")

        # Silent mode: run everything and exit
        if (-not $interactive) {
            Invoke-SelectedUpdates -ProfileFolder $profileFolder -PrefsFile $prefsFile -Config $config -Tasks $allTasks
            Write-ColorOutput "`nAll updates completed." -Color Green
            exit 0
        }

        # Interactive menu loop
        while ($true) {
            Write-ColorOutput "========================================" -Color Cyan
            Write-ColorOutput "What would you like to update?" -Color Yellow
            Write-ColorOutput "  1. Replace Custom Colors" -Color White
            Write-ColorOutput "  2. Update Toolsets" -Color White
            Write-ColorOutput "  3. Update Stamp Directory" -Color White
            Write-ColorOutput "  4. Update Template Directory" -Color White
            Write-ColorOutput "  5. Update Line Sets (all profiles)" -Color White
            Write-ColorOutput "  6. Update Hatch Sets (all profiles)" -Color White
            Write-ColorOutput "  7. All of the above" -Color White
            Write-ColorOutput "  8. Exit" -Color White

            $choice = Read-Host "`nEnter your choice (1-8)"

            if ($choice -eq "8") {
                Write-ColorOutput "`nExiting. Thank you for using Bluebeam Preferences Updater!" -Color Cyan
                break
            }

            $tasks = switch ($choice) {
                "1" { @("Colors") }
                "2" { @("Toolsets") }
                "3" { @("Stamps") }
                "4" { @("Templates") }
                "5" { @("LineSets") }
                "6" { @("HatchSets") }
                "7" { $allTasks }
                default { $null }
            }

            if ($null -eq $tasks) {
                Write-ColorOutput "`nInvalid choice. Please select 1-8." -Color Red
                Start-Sleep -Seconds 2
                continue
            }

            Invoke-SelectedUpdates -ProfileFolder $profileFolder -PrefsFile $prefsFile -Config $config -Tasks $tasks

            Write-ColorOutput "`n========================================" -Color Cyan
            Write-ColorOutput "Done. Returning to menu..." -Color Cyan
            Write-ColorOutput "========================================`n" -Color Cyan
        }
    }
    catch {
        Write-ColorOutput "`n========================================" -Color Red
        Write-ColorOutput "ERROR OCCURRED" -Color Red
        Write-ColorOutput "========================================" -Color Red
        Write-ColorOutput $_.Exception.Message -Color Red
        Write-ColorOutput "`nBackups (if any) are in the Backups folder next to the modified files." -Color Yellow

        if ($interactive) {
            Read-Host "`nPress Enter to exit"
        }
        exit 1
    }

    if ($interactive) {
        Write-ColorOutput "`n" -Color White
        Read-Host "Press Enter to exit"
    }
}

# Run main function
Main
