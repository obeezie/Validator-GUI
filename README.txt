WINDOWS HARDWARE VALIDATOR GUI - V18
====================================

Runs on Windows PowerShell 5.1, which is built into Windows 10/11. Nothing
needs to be installed. Copy the WHOLE folder (including lib\ and ui\) to the
USB drive; the launchers will not work with only the .ps1 file.

ENGINEER MODE - NEW CONFIG CAPTURE
----------------------------------
When an engineer captures a new hardware configuration:

1. The engineer names the configuration. If that name already exists, the
   validator asks before replacing it.
2. Network-link warnings are shown if physical NICs are down.
3. The full known-good hardware snapshot is reviewed and confirmed.
4. The configuration is saved to Configs\<ConfigName>.json and
   integrity-registered.
5. The validator offers to open the config editor straight away.

PRODUCTION MODE
---------------
Production Mode cannot create or edit configurations.

When Validate System is clicked, the selected Configs\<SelectedConfig>.json
must match its integrity record, otherwise validation stops.

INTEGRITY
---------
Hardware configs are SHA-256 registered in:

    Configs\config_manifest.json

Validation refuses to continue when a config has been modified outside the
validator after Engineer Mode registered it. Capturing or saving in the
config editor registers the new contents.

UNIT HISTORY AND SHARED BOOT DRIVES
-----------------------------------
Test history is kept per Unit Serial (Reports\<UnitSerial>\), and the
validator looks it up by the serial the operator types, not by the Windows
computer name. A shared test drive that moves from unit to unit still
carries the previous unit's computer name; that name is simply renamed
(with the usual confirmation) and is not treated as a hardware change.

Until a serial is typed, the identity status uses the computer name as a
guess. After the operator leaves the Serial Number box, the status and the
auto-selected Config update for that serial.

HARDWARE REPLACEMENT
--------------------
If a Unit Serial's latest report was recorded on a different motherboard,
the validator asks whether the motherboard was replaced (default No).
Production and Engineer modes may approve it after entering a reason; the
approval is saved in that unit's report folder. Choosing No stops
validation so a mistyped serial can be corrected.

CONFIG EDITOR (Engineer Mode)
-----------------------------
Select a configuration and click "Edit Selected Config". Tabs:

    General  - manufacturer, model, CPU text, minimum cores / logical
               CPUs (0 = not checked), minimum RAM, DIMM count
    Storage  - disk name text, bus type, minimum GB, Required
    Network  - adapter text, Required, link must be Up, minimum Mbps
               (blank = no minimum)
    GPU      - GPU name text, Required

Type in the blank last row to add a component. Select a row and click
Remove Selected Row to delete one. Save re-registers the config's SHA-256,
so Production mode accepts the edited file. The config name cannot be
changed in the editor; capture a new config under the new name instead.

REQUIRED / OPTIONAL COMPONENTS
------------------------------
Every disk, network adapter and GPU has a Required flag. Captures save
everything as Required, and older configs without the flag are treated as
Required.

    Required, missing           -> FAIL
    Optional, missing           -> INFO (does not fail the unit)
    Installed but out of spec   -> FAIL, even when optional

Each configured component must match a different physical device, so a
config with two identical disks needs two disks installed.

WI-FI
-----
Wireless adapters never have a minimum link speed enforced. This also
applies to older configs that captured a Wi-Fi link speed. Wired adapters
still check their minimum link speed. The editor's Network tab shows a Note
on rows that look wireless, including when an old minimum is being ignored.

LOGICAL CPUS
------------
The minimum logical CPU count is checked (V15+). Captures store the full
thread count, so a unit with Hyper-Threading/SMT disabled will FAIL. Set the
minimum to 0 in the editor to stop checking it for a config.

COMPUTER RENAME
---------------
The rename prompt appears only when the entered serial number differs from
the current computer name. It shows both names and asks the operator to
confirm the serial; the default button is No. Choosing No stops validation
so the serial can be corrected, before any checks run or a report is filed.

The computer is renamed only when every check PASSES. A failing unit keeps
its current name (the report says the rename was skipped), but the report is
still filed under the entered serial.

If a rename to that serial is already pending a restart, no second prompt is
shown. If the name already matches the serial but Windows has a rename to a
DIFFERENT name pending, validation stops and asks for a restart first.

All-numeric serials are rejected because Windows does not allow all-numeric
computer names.

PORTABLE FOLDER STRUCTURE
-------------------------
HardwareValidator\
    HardwareValidator_GUI.ps1     Entry point and main window
    Launch_Production_Mode.bat
    Launch_Engineer_Mode.bat

    lib\                          Logic (no UI)
        Common.ps1                Paths and helpers
        Integrity.ps1             SHA-256 manifest
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
    Reports\

TESTS
-----
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

Covers the logic only. The windows and real hardware still need a manual
run on a test station.


CHANGE HISTORY
==============

V18 - SHARED BOOT DRIVE FIX
    - Unit history and hardware-change checks use the typed Unit Serial
      instead of the Windows computer name. Previously, moving a shared
      test drive to the next unit looked like a motherboard replacement:
      validation either stopped or saved a false approval under the
      previous unit's serial.

V17 - REVIEW FIXES
    - The computer is renamed only after validation passes.
    - Validation stops when the name matches the serial but a rename to a
      different name is pending.
    - Editor Network tab shows a Note for wireless rows.

V16 - BURNINTEST PAIRING REMOVED
    The .bitcfg requirement is gone everywhere: capture no longer asks for
    one, validation no longer checks for one, the "Open BIT Config Folder"
    button is removed, and reports no longer have a "BurnInTest Config"
    line. An existing BurnInTestConfigs\ folder is ignored and can be
    deleted.

V15 - CONFIG EDITOR, OPTIONAL COMPONENTS, RENAME CONFIRMATION, FIXES
    - Config editor, Required/optional components, Wi-Fi speed no longer
      enforced, rename confirmation (see sections above).
    - Code split into lib\ and ui\ files, with logic tests.
    - config_manifest no longer appears in the Configuration list, and it
      cannot be used as a configuration name.
    - Logical CPU minimum is now checked. A disk with health Warning or
      Unhealthy fails.
    - A hardware change approval no longer approves the PREVIOUS hardware
      (swapping the original parts back in requires a new approval).
    - Hardware names containing [ ] * ? are matched literally.
    - The result banner resets instead of staying on "RUNNING..." when
      validation is stopped before it runs.

V12 - V14
    BurnInTest .bitcfg pairing and SHA-256 integrity manifests added (V12);
    Engineer Mode button layout fixes (V13, V14).
