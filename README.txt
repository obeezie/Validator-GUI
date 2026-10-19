WINDOWS HARDWARE VALIDATOR GUI - V22
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
Each unit's Validation Runs are kept per Unit Serial (Reports\<UnitSerial>\),
looked up by the serial the operator types, not by the Windows computer
name. A shared test drive that moves from unit to unit still carries the
previous unit's computer name; that name is simply renamed (with the usual
confirmation) and is not treated as a hardware change.

Until a serial is typed, the identity status uses the computer name as a
guess. After the operator leaves the Serial Number box, the status and the
auto-selected Config update for that serial.

RUN NUMBERS
-----------
Every run gets the next Run Number for its Unit Serial, shown in the report
("Run Number : 3") and the file name:

    <UnitSerial>_Run003_<Phase>_<yyyyMMdd_HHmmss>_Hardware_Validation_Summary.txt

"Latest run" means the highest Run Number, because a unit's clock can be
wrong (for example after a motherboard swap). Reports from before Run
Numbers count as earlier runs, ordered by the timestamp in their file name.

SYSTEM TRAVELER CONFIRMATION
----------------------------
At every Tier run, and on any run of a unit that has never been confirmed,
the validator lists every detected MAC address (wired, Wi-Fi and Bluetooth,
including adapters the Config does not use) and asks whether they match the
unit's System Traveler. The default answer is No.

    No  - validation stops and nothing is recorded. Check that the unit,
          its serial label and the traveler belong together, and that the
          MAC addresses were programmed.
    Yes - those MAC addresses become the unit's baseline, replacing any
          earlier confirmation.

Fixing wrongly assigned MAC addresses: correct the MACs, then re-run Tier
and confirm the correct addresses against the traveler. Both Production and
Engineer modes can confirm.

MAC ADDRESS CHECK
-----------------
Runs at other phases must have exactly the confirmed set of MAC addresses
(the adapter model may differ; the addresses may not). Any difference FAILS
the run and is listed as Missing / Unexpected. A failed run never changes
the baseline. MAC addresses are checked after a motherboard replacement too,
because assigned MAC addresses do not change with the board.

Note: Windows only shows a Bluetooth MAC address when the Bluetooth network
adapter ("Bluetooth Device (Personal Area Network)") is present.

NETWORK ADAPTERS IN RESULTS AND REPORTS
---------------------------------------
Only the adapters the Config lists are checked and shown (results table,
Detected MAC Addresses box and report). An optional adapter that is not
installed gets no row. Windows' "#2"/"#3" numbering of identical adapters is
ignored when matching, so re-enumeration between phases does not fail a run.

REQUIRED DEVICES (DEVICE MANAGER)
---------------------------------
A Config can list devices a test procedure expects in Device Manager, such
as a boot shield. Add them in Engineer Mode: Edit Selected Config, Devices
tab, either "Add Device from This Unit..." (pick from what Device Manager
shows; built-in system devices are hidden unless ticked) or by typing a
hardware ID. Each listed device must be present in Device Manager;
otherwise the run FAILS. Only presence is checked: a missing or failed
driver does not fail the run, because drivers are the customer's
responsibility. Unplugged devices that Windows still remembers do not count
as present. Listing the same hardware ID twice requires two such devices.
Removing a device row in the editor and saving stops it being checked.
Capture does not add devices.

HARDWARE REPLACEMENT
--------------------
If a unit's latest run was recorded on a different motherboard, the
validator asks whether the motherboard was replaced (default No).
Production and Engineer modes may approve it after entering a reason.
Choosing No stops validation so a mistyped serial can be corrected.
The approval is saved in that unit's report folder only when the run
completes; a run stopped at any question leaves no files behind.

CONFIG EDITOR (Engineer Mode)
-----------------------------
Select a configuration and click "Edit Selected Config". Tabs:

    General  - manufacturer, model, CPU text, minimum cores / logical
               CPUs (0 = not checked), minimum RAM, DIMM count
    Storage  - disk name text, bus type, minimum GB, Required
    Network  - adapter text, Required, link must be Up, minimum Mbps
               (blank = no minimum)
    GPU      - GPU name text, Required
    Devices  - Required Devices: label, hardware ID, Required

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
        UnitHistory.ps1           Runs, Run Numbers, Baseline, approvals
        ValidationRun.ps1         One Validation Run: order, questions, outcome
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

V22 - REQUIRED DEVICES: PRESENCE ONLY
    - A Required Device passes when it is present in Device Manager,
      whatever its driver state. Unplugged devices still fail.

V21 - FIELD FIXES
    - Every Tier run re-confirms MAC addresses against the System
      Traveler and replaces the unit's confirmed MACs (fixes wrongly
      assigned MACs).
    - Adapter matching ignores Windows' "#n" numbering.
    - Only the Config's adapters appear in results and reports; missing
      optional adapters get no row. The traveler still covers every MAC.
    - Required Devices: Device Manager checks configured in the editor's
      new Devices tab.

V20 - VALIDATION RUN MOVED OUT OF THE WINDOW CODE
    - The rules of a run (order of checks and questions, when to stop,
      when to rename, what gets recorded) now live in
      lib\ValidationRun.ps1 instead of the main window code.
    - Operator questions and machine access (hardware reads, computer
      name, pending rename, rename) are passed in, so whole runs are
      covered by tests\Run-Tests.ps1 with scripted answers.
    - No change in behaviour for operators.

V19 - UNIT HISTORY AND SYSTEM TRAVELER CONFIRMATION
    - Run Numbers decide the latest run instead of file times.
    - One-time System Traveler confirmation of MAC addresses per unit;
      later runs must match it exactly. Failed runs no longer become the
      MAC baseline.
    - MAC addresses are compared by address only, and are checked after a
      motherboard replacement.
    - Questions come after all automatic checks, and nothing is written
      until the run completes (no stray approval files).
    - Report reading/writing consolidated in lib\UnitHistory.ps1
      (replaces lib\Reports.ps1).

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
