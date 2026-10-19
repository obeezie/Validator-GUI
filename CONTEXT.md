# Hardware Validator

Checks that a technician is testing the unit their System Traveler describes, and that its hardware matches the build it is supposed to be, at each test phase of the burn-in process. Results are recorded against the unit's serial.

## Units and identity

**Unit**:
The physical machine being validated.
_Avoid_: System, computer, device, machine

**Unit Serial**:
Our own serial number for a unit, printed on its label and typed in by the operator. Test history is kept under it, and the Windows computer name of the Boot Drive the unit is running is set to it.
_Avoid_: Serial number (unqualified), computer name, hostname

**BIOS Serial**:
The manufacturer's serial number stored in the unit's firmware. It is usually different from the Unit Serial and is used only to recognize the physical hardware.
_Avoid_: OEM serial, Unit Serial

**System Traveler**:
The paperwork that travels with a unit. It holds the unit's documented identity: its Unit Serial, the serial numbers of each board, and its Assigned MAC Addresses.
_Avoid_: Traveler sheet, documentation, paperwork

**Assigned MAC Address**:
A MAC address the assembler programs onto a unit's network adapter with the adapter vendor's tool, and records on the System Traveler. It belongs to the unit, not to the board: replacing a board or adapter does not change it.
_Avoid_: Burned-in MAC, hardware MAC

**Boot Drive**:
The Windows drive a unit is running during validation. Depending on the station, it is either the unit's own disk or a shared test drive moved from unit to unit.
_Avoid_: Image, OS drive

**Stale Name**:
A computer name that belongs to a different unit, carried over when a shared Boot Drive moves to the next unit.
_Avoid_: Stale hostname

**Hardware Fingerprint**:
The identity of a unit's physical motherboard, taken from its firmware IDs (system UUID, BIOS serial and baseboard serial). It confirms the technician is testing the same physical unit as that Unit Serial's earlier runs.
_Avoid_: Hardware identity, hardware ID

**Hardware Change**:
An approved, recorded replacement of a unit's motherboard. The unit keeps its Unit Serial, test history and Assigned MAC Addresses; the new Hardware Fingerprint becomes its Baseline.
_Avoid_: Hardware swap, replacement

## Builds

**Config**:
The known-good hardware specification for one exact build (SKU). Two units of the same model with different RAM, storage or cards are different Configs.
_Avoid_: Configuration file, profile, model

**Capture**:
Creating a Config by recording the hardware of a known-good unit, then reviewing it.
_Avoid_: Snapshot (that is the raw hardware reading), import

**Required Component**:
A disk, network adapter, GPU or Required Device in a Config that must be present for the unit to pass. Components are required unless marked optional.

**Optional Component**:
A component in a Config that may be absent. If it is installed, it must still meet its spec. Rarely used, because a Config describes one exact build.

**Required Device**:
A device a test procedure expects to see in Device Manager (for example a boot shield), listed in a Config by its hardware ID. It must be present for the unit to pass; its driver state is not checked, because installing drivers is the customer's responsibility.
_Avoid_: PnP device, driver check

## Process

**Test Phase**:
One stage of the burn-in process at which a unit is validated: Tier, Pre-Oven, Oven, Post-Oven.
_Avoid_: Stage, step

**Validation Run**:
One validation of a unit at a Test Phase, recorded in its Unit History whether it passed or failed.
_Avoid_: Test, check, report (the report is the record of a run)

**Run Number**:
The position of a Validation Run in its unit's history: 1 for the first run of that Unit Serial, then 2, 3 and so on. It decides which run is latest, because a unit's clock cannot be trusted.
_Avoid_: Timestamp order

**Unit History**:
Every Validation Run and Hardware Change recorded under one Unit Serial.
_Avoid_: Reports folder, log

**Traveler Confirmation**:
The operator's confirmation that the MAC addresses detected on the unit (wired, Wi-Fi and Bluetooth) match its System Traveler. It is asked at every Tier run, and on any run of a unit that has none yet; each new one replaces the unit's confirmed MAC addresses. Answering No stops the run without recording anything.
_Avoid_: MAC approval, traveler check

**Baseline**:
What a unit's next run is compared against. Its motherboard (Hardware Fingerprint) and Config come from its latest run of any result; its MAC addresses are the ones confirmed in its latest Traveler Confirmation, and every other run must have exactly that set.
_Avoid_: Previous summary, last report

**Tier**:
The intake grading phase, when a unit first arrives and is graded by condition.
_Avoid_: Intake, grading (as phase names)

## Roles

**Engineer Mode**:
The mode in which engineers capture and edit Configs. Kept separate to prevent accidental changes, not as a security boundary.

**Production Mode**:
The mode operators use to validate units against existing Configs. It cannot create or edit Configs, but may approve a hardware change.
