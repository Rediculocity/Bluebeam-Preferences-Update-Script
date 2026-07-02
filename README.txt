========================================
BLUEBEAM PREFERENCES UPDATER
========================================

PURPOSE:
This tool updates your Bluebeam Revu configuration with:
- Custom color palette
- Required toolset paths (adds missing, fixes wrong paths)
- Stamp directory (auto-selects based on your permissions)
- Template directory (auto-selects based on your permissions)
- Line Sets in every profile (adds missing, fixes wrong paths)
- Hatch Sets in every profile (adds missing, fixes wrong paths)

FILES UPDATED:
- UserPreferences.xml    (colors, toolsets, stamp & template directories)
- *.bpx profile files    (line sets and hatch sets, all profiles)

FILES INCLUDED:
- Run.bat                           (Double-click this to run)
- UpdateBluebeamPreferences.ps1     (Main PowerShell script)
- config.json                       (Configuration - colors, toolsets, line/hatch sets)
- README.txt                        (This file)
- QUICK_START.txt                   (Short version of these instructions)
- CONFIG_GUIDE.txt                  (How to customize config.json)
- CHANGELOG.txt                     (Version history)

========================================
INSTRUCTIONS:
========================================

1. DOUBLE-CLICK "Run.bat"
   This will launch the updater with the correct permissions.

   NOTE: The tool will automatically check if Bluebeam is running
         and prompt you to close it if necessary.

2. CLOSE BLUEBEAM (if prompted)
   If Bluebeam Revu is running, you'll see a warning message.
   Close Bluebeam and select option 1 to continue.

3. CHOOSE WHAT TO UPDATE
   You will be prompted to choose what to update:
   - Option 1: Replace Custom Colors
   - Option 2: Update Toolsets
   - Option 3: Update Stamp Directory
   - Option 4: Update Template Directory
   - Option 5: Update Line Sets (all profiles)
   - Option 6: Update Hatch Sets (all profiles)
   - Option 7: All of the above
   - Option 8: Exit without changes

4. BACKUP IS AUTOMATIC
   The tool automatically creates a backup of every file before
   changing it. Backups are stored in:
   C:\Users\[YourName]\AppData\Roaming\Bluebeam Software\Revu\[Version]\Backups\

   Only the 10 most recent backups per file are kept - older ones
   are removed automatically.

5. VERIFY THE CHANGES
   After running, open Bluebeam Revu and verify:
   - Custom colors appear correctly
   - Toolsets are loaded and accessible
   - Stamp directory points to accessible location
   - Template directory points to accessible location
   - Line styles and hatch patterns are available in each profile

========================================
SILENT / UNATTENDED MODE:
========================================

For IT deployment (Intune, GPO, login scripts), run with -All to
apply every update without any prompts:

   Run.bat -All

or directly:

   PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File UpdateBluebeamPreferences.ps1 -All

Exit codes:
   0 = success
   1 = error occurred
   2 = Bluebeam Revu was running (nothing changed)

========================================
TROUBLESHOOTING:
========================================

PROBLEM: "No Bluebeam profile folder found"
SOLUTION: When prompted, manually enter the full path to your file.
          Typical location: C:\Users\[YourName]\AppData\Roaming\Bluebeam Software\Revu\21\UserPreferences.xml

PROBLEM: Script won't run / execution policy error
SOLUTION: Right-click "Run.bat" and select "Run as Administrator"

PROBLEM: Changes didn't apply
SOLUTION: 1. Check that Bluebeam was closed when running the tool
          2. Check the backup folder to verify a backup was created
          3. Review any error messages in the window

PROBLEM: Need to restore from backup
SOLUTION: 1. Navigate to the Backups folder (see location above)
          2. Find the backup you want (named like Revu_20260702_171500.bpx
             or UserPreferences_20260702_171500.xml)
          3. Copy it back to the Revu folder and rename it to the
             original file name (e.g. Revu.bpx or UserPreferences.xml)

========================================
CUSTOMIZATION:
========================================

To modify what gets applied, edit "config.json" in a text editor.
See CONFIG_GUIDE.txt for a full explanation of every section:
- customColors:        Color values (negative integers, ARGB format)
- toolsets:            Toolset paths and titles
- lineSets:            Line style sets applied to every profile
- hatchSets:           Hatch pattern sets applied to every profile
- stampDirectories:    Priority-ordered list of stamp folder paths
- templateDirectories: Priority-ordered list of template folder paths

HOW MATCHING WORKS (toolsets, line sets, hatch sets):
The script identifies entries by their FILE NAME (e.g. "Advanced.blx").
- If no entry with that file name exists  -> it is ADDED
- If an entry exists but the path differs -> the path is CORRECTED
  to the config value (the config is the source of truth)
- If the entry already matches            -> it is left alone
This means the tool is safe to run repeatedly.

========================================
NETWORK DEPLOYMENT:
========================================

This tool can be run from a network location:
1. Place all files in a shared network folder
2. Users can double-click "Run.bat" from the network location
3. Changes are applied to their local Bluebeam files
4. Each user gets their own backups in their local AppData folder

========================================
SUPPORT:
========================================

For issues or questions, contact your IT administrator.

Version: 2.0
Last Updated: 2026-07-02
