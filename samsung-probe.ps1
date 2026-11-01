<#
.SYNOPSIS
  READ-ONLY discovery of Samsung-specific software and interfaces on this PC.
  Nothing here changes any setting. In particular it never calls the
  root\Samsung BiosManager methods (Set / Save / SetPassword / LoadDefault).
#>

function Section($t) { "`n=== $t ===" }

Section 'Samsung Store apps (current user)'
Get-AppxPackage *samsung* -ErrorAction SilentlyContinue |
  Sort-Object Name | Select-Object Name, Version | Format-Table -AutoSize

Section 'Samsung-related services'
Get-CimInstance Win32_Service |
  Where-Object { $_.Name -match 'samsung|galaxy|^GBExperience$|AISelect' -or $_.PathName -match 'Samsung' } |
  Select-Object Name, State | Sort-Object Name | Format-Table -AutoSize

Section 'Samsung drivers (Win32_PnPSignedDriver)'
Get-CimInstance Win32_PnPSignedDriver |
  Where-Object { $_.Manufacturer -match 'Samsung' -and $_.DeviceName } |
  Select-Object DeviceName, DriverVersion | Format-Table -AutoSize

Section 'Samsung ACPI device (firmware-defined hardware)'
Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like 'ACPI\SAM*' } |
  Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize -Wrap

Section 'WMI: is there a root\Samsung namespace?'
$ns = Get-CimInstance -Namespace root -ClassName __NAMESPACE | Where-Object Name -eq 'Samsung'
if ($ns) {
  'Yes. Non-system classes:'
  Get-CimClass -Namespace root\Samsung |
    Where-Object { $_.CimClassName -notmatch '^(__|CIM_|MSFT_)' } |
    ForEach-Object {
      "  $($_.CimClassName)  -  $($_.CimClassQualifiers['Description'].Value)"
      foreach ($m in $_.CimClassMethods) {
        $sig = ($m.Parameters | ForEach-Object {
          $dir = if ($_.Qualifiers['In']) { 'in' } else { 'out' }
          "$dir $($_.CimType) $($_.Name)"
        }) -join ', '
        "      method $($m.Name)($sig)"
      }
    }
  ''
  'Reading instances requires an elevated (administrator) session; this script does not attempt it.'
} else { 'No.' }

Section 'Other vendor WMI namespaces of interest'
Get-CimInstance -Namespace root -ClassName __NAMESPACE |
  Where-Object Name -in 'Intel_ME', 'Samsung', 'Hardware', 'WMI' | Select-Object -ExpandProperty Name
