WINDOWS HARDWARE VALIDATOR GUI - V15
====================================

Runs on Windows PowerShell 5.1, which is built into Windows 10/11. Nothing
needs to be installed. Copy the WHOLE folder (including lib\ and ui\) to the
USB drive; the launchers will not work with only the .ps1 file.

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
    HardwareValidator_GUI.ps1     Entry point and main window
    Launch_Production_Mode.bat
    Launch_Engineer_Mode.bat

    lib\                          Logic (no UI)
        Common.ps1                Paths and helpers
        Integrity.ps1             SHA-256 manifests
        Identity.ps1              Hardware fingerprint and change approvals
        Hardware.ps1              Hardware snapshot and computer rename
        ConfigModel.ps1           Config load/save/normalize/capture
        Validation.ps1            Compares hardware to a config
        Reports.ps1               Summary reports and history
    ui\                           WinForms windows
        Dialogs.ps1
        CaptureWorkflow.ps1
        ConfigEditor.ps1
        ValidationWorkflow.ps1
    tests\
        Run-Tests.ps1             Logic tests (no install needed)

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


V15 - CONFIG EDITOR, OPTIONAL COMPONENTS, RENAME CONFIRMATION, FIXES
--------------------------------------------------------------------

CONFIG EDITOR (Engineer Mode)
    Select a configuration and click "Edit Selected Config". Tabs:
        General  - manufacturer, model, CPU text, minimum cores / logical
                   CPUs (0 = not checked), minimum RAM, DIMM count
        Storage  - disk name text, bus type, minimum GB, Required
        Network  - adapter text, Required, link must be Up, minimum Mbps
                   (blank = no minimum)
        GPU      - GPU name text, Required
    Type in the blank last row to add a component. Select a row and click
    Remove Selected Row to delete one. Save re-registers the config's
    SHA-256, so Production mode accepts the edited file. The config name
    cannot be changed because it is paired with the .bitcfg file name.
    After a capture, the validator offers to open the editor straight away.

REQUIRED / OPTIONAL COMPONENTS
    Every disk, network adapter and GPU has a Required flag. Captures save
    everything as Required, and older configs without the flag are treated
    as Required.
        Required, missing           -> FAIL
        Optional, missing           -> INFO (does not fail the unit)
        Installed but out of spec   -> FAIL, even when optional
    Each configured component must match a different physical device, so a
    config with two identical disks needs two disks installed.

WI-FI
    Wireless adapters never have a minimum link speed enforced. This also
    applies to older configs that captured a Wi-Fi link speed. Wired
    adapters still check their minimum link speed.

COMPUTER RENAME
    The rename prompt appears only when the entered serial number differs
    from the current computer name. It shows both names and asks the
    operator to confirm the serial; the default button is No. Choosing No
    stops validation so the serial can be corrected, before anything is
    renamed or a report is filed. If a rename to that serial is already
    pending a restart, no second prompt is shown.
    All-numeric serials are rejected because Windows does not allow
    all-numeric computer names.

OTHER FIXES
    - config_manifest no longer appears in the Configuration list, and it
      cannot be used as a configuration name.
    - Logical CPU minimum is now checked. A disk with health Warning or
      Unhealthy fails.
    - Capture asks about replacing an existing config before touching the
      .bitcfg. An existing .bitcfg that is unregistered or modified is no
      longer silently re-trusted.
    - A hardware change approval no longer approves the PREVIOUS hardware
      (swapping the original parts back in requires a new approval).
    - Hardware names containing [ ] * ? are matched literally.
    - The report's "BurnInTest Config" line uses the real .bitcfg file name.
    - The result banner resets instead of staying on "RUNNING..." when
      validation is stopped before it runs.

TESTS
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
    Covers the logic only. The windows and real hardware still need a
    manual run on a test station.
