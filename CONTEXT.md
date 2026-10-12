# Hardware Validator

Checks that a physical unit's hardware matches the build it is supposed to be, at each test phase of the burn-in process, and records the result against the unit's serial.

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

**Boot Drive**:
The Windows drive a unit is running during validation. Depending on the station, it is either the unit's own disk or a shared test drive moved from unit to unit.
_Avoid_: Image, OS drive

**Stale Name**:
A computer name that belongs to a different unit, carried over when a shared Boot Drive moves to the next unit.
_Avoid_: Stale hostname

**Hardware Fingerprint**:
The identity of a unit's physical motherboard, taken from its firmware IDs (system UUID, BIOS serial and baseboard serial). It tells a unit's own history apart from another unit's.
_Avoid_: Hardware identity, hardware ID

**Hardware Change**:
An approved, recorded replacement of a unit's motherboard. The unit keeps its Unit Serial and test history; the new Hardware Fingerprint becomes its baseline.
_Avoid_: Hardware swap, replacement

## Builds

**Config**:
The known-good hardware specification for one exact build (SKU). Two units of the same model with different RAM, storage or cards are different Configs.
_Avoid_: Configuration file, profile, model

**Capture**:
Creating a Config by recording the hardware of a known-good unit, then reviewing it.
_Avoid_: Snapshot (that is the raw hardware reading), import

**Required Component**:
A disk, network adapter or GPU in a Config that must be present for the unit to pass. Components are required unless marked optional.

**Optional Component**:
A disk, network adapter or GPU in a Config that may be absent. If it is installed, it must still meet its spec. Rarely used, because a Config describes one exact build.

## Process

**Test Phase**:
One stage of the burn-in process at which a unit is validated: Tier, Pre-Oven, Oven, Post-Oven.
_Avoid_: Stage, step

**Tier**:
The intake grading phase, when a unit first arrives and is graded by condition.
_Avoid_: Intake, grading (as phase names)

## Roles

**Engineer Mode**:
The mode in which engineers capture and edit Configs. Kept separate to prevent accidental changes, not as a security boundary.

**Production Mode**:
The mode operators use to validate units against existing Configs. It cannot create or edit Configs, but may approve a hardware change.
