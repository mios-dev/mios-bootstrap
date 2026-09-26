<!-- AI-hint: Index of the MiOS-Xbox / Windows-ISO pipeline design, spec and research notes under field/autounattend/docs/. Every doc here is linked from this page so none is an orphan. -->
<!-- AI-related: field/autounattend/Build-MiOSXboxISO.ps1, field/autounattend/New-MiOSISO.ps1, field/autounattend/New-MiOSAutounattend.ps1, field/autounattend/mios-build-iso.sh, installation/MiOS-Field.bat -->

# field/autounattend docs

Design, spec and research notes for the MiOS-Xbox Windows ISO pipeline in
`field/autounattend/` (`Build-MiOSXboxISO.ps1`, `New-MiOSISO.ps1`,
`New-MiOSAutounattend.ps1`, `mios-build-iso.sh`). The scripts are the
source of truth; these notes explain why they work the way they do.

## Spec and contract

- [MiOS-Xbox-provisioning-spec.md](MiOS-Xbox-provisioning-spec.md): the
  operator-defined provisioning spec that the Xbox fix work is checked against.
- [MiOS-Xbox-fix-blueprint.md](MiOS-Xbox-fix-blueprint.md): how each item in
  the spec maps to a `mios.toml` key and to the script that emits it.

## Pipeline

- [uup-autounattend-dism-iso-flow.md](uup-autounattend-dism-iso-flow.md): the
  Windows path, UUP Dump to autounattend to DISM to ISO.
- [linux-uup-iso-build.md](linux-uup-iso-build.md): the Linux path
  (`mios-build-iso.sh`), for hosts with no Windows elevation.
- [dism-native-conversion-map.md](dism-native-conversion-map.md): which NTLite
  preset entries have a DISM equivalent and which do not.
- [pre-logon-system-services.md](pre-logon-system-services.md): running MiOS
  services before anyone logs on.
- [remote-build-auth.md](remote-build-auth.md): starting the automated build
  from a remote session.

## Research and findings

- [oem-dism-techniques-2026-07-06.md](oem-dism-techniques-2026-07-06.md): OEM
  and DISM techniques checked against Microsoft's docs.
- [flash-log-bugs-2026-07-23.md](flash-log-bugs-2026-07-23.md): bugs found in
  real flash logs.
- [pipeline-review-followups.md](pipeline-review-followups.md): findings from
  the pipeline review, including the ones still open.
