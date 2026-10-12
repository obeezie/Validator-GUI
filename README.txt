WINDOWS HARDWARE VALIDATOR GUI - V12
====================================

BURNINTEST CONFIG PAIRING
-------------------------
Every hardware validator configuration now requires a matching BurnInTest
configuration.

Example:

    Configs\Config_A.json
    BurnInTestConfigs\Config_A.bitcfg

The base filenames must match.

ENGINEER MODE - NEW CONFIG CAPTURE
----------------------------------
When an engineer captures a new hardware configuration:

1. The full known-good hardware snapshot is reviewed.
2. Network-link warnings are shown if physical NICs are down.
3. The validator checks for:

       BurnInTestConfigs\<ConfigName>.bitcfg

4. If the file is missing, capture is NOT finalized.

The engineer is shown three options:

    Check Again
        Use this after creating the .bitcfg in BurnInTest and placing it in the
        BurnInTestConfigs folder.

    Link Existing...
        Select an existing .bitcfg. The validator copies it into the correct
        BurnInTestConfigs folder and renames it to match the hardware config.

    Cancel Capture
        Stops the hardware configuration capture.

Only after the required .bitcfg exists does the validator save/finalize the
new .json hardware configuration.

ENGINEER MODE BUTTON
--------------------
Engineer Mode includes an Open BIT Config Folder button.

PRODUCTION MODE
---------------
Production Mode cannot create configurations.

When Validate System is clicked, the validator requires BOTH:

    Configs\<SelectedConfig>.json
    BurnInTestConfigs\<SelectedConfig>.bitcfg

If the matching .bitcfg is missing, validation stops.

INTEGRITY
---------
Both the hardware JSON and BurnInTest .bitcfg files are SHA-256 registered.

Manifests:

    Configs\config_manifest.json
    BurnInTestConfigs\bitcfg_manifest.json

Production validation refuses to continue when either file has been modified
after Engineer Mode registered it.

EXISTING CONFIG MIGRATION
-------------------------
Older hardware configs created before V12 will need a matching .bitcfg added
through Engineer mode before Production mode can use them.

HARDWARE REPLACEMENT
--------------------
Production and Engineer modes may still approve legitimate hardware replacement
after reviewing the changed hardware IDs and entering a reason.

PORTABLE FOLDER STRUCTURE
-------------------------
HardwareValidator\
    HardwareValidator_GUI.ps1
    Launch_Production_Mode.bat
    Launch_Engineer_Mode.bat

    Configs\
    BurnInTestConfigs\
    Reports\


V13 UI FIX
----------
The Engineer Mode "Open BIT Config Folder" button was overlapping the existing
main button row.

It has been moved to its own row below the main action buttons, and the result
area has been shifted down slightly to keep the layout clean.


V14 UI FIX
----------
The Engineer Mode "Open BIT Config Folder" button has been moved to a dedicated
row below the Configuration / Serial Number / Test Phase input fields.

The overall result and validation table were moved farther down so the button
does not overlap any dropdowns or status labels.
