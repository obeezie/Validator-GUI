# Engineer Mode: edit a captured hardware configuration.
# Saving re-registers the file's SHA-256 so Production mode accepts it.

function New-EditorTextBox {
    param($Parent, [string]$Label, [int]$Y, [string]$Value, [switch]$ReadOnly)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Label
    $lbl.Location = New-Object System.Drawing.Point(15, ($Y + 4))
    $lbl.Size = New-Object System.Drawing.Size(190, 20)
    $Parent.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(210, $Y)
    $txt.Size = New-Object System.Drawing.Size(600, 24)
    $txt.Text = $Value
    $txt.ReadOnly = [bool]$ReadOnly
    $Parent.Controls.Add($txt)

    return $txt
}

function New-EditorNumber {
    param(
        $Parent, [string]$Label, [int]$Y, [double]$Value,
        [double]$Minimum, [double]$Maximum, [int]$DecimalPlaces = 0,
        [string]$Hint = ""
    )

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Label
    $lbl.Location = New-Object System.Drawing.Point(15, ($Y + 4))
    $lbl.Size = New-Object System.Drawing.Size(190, 20)
    $Parent.Controls.Add($lbl)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point(210, $Y)
    $num.Size = New-Object System.Drawing.Size(120, 24)
    $num.DecimalPlaces = $DecimalPlaces
    $num.Minimum = [decimal]$Minimum
    $num.Maximum = [decimal]$Maximum
    $num.Increment = if ($DecimalPlaces -gt 0) { [decimal]0.5 } else { [decimal]1 }
    $num.Value = [decimal][math]::Min([math]::Max($Value, $Minimum), $Maximum)
    $Parent.Controls.Add($num)

    if ($Hint) {
        $hintLabel = New-Object System.Windows.Forms.Label
        $hintLabel.Text = $Hint
        $hintLabel.ForeColor = [System.Drawing.Color]::DimGray
        $hintLabel.Location = New-Object System.Drawing.Point(340, ($Y + 4))
        $hintLabel.Size = New-Object System.Drawing.Size(470, 20)
        $Parent.Controls.Add($hintLabel)
    }

    return $num
}

# Columns: array of @{ Name; Header; Type = "Text" | "Check" | "Note"; Width; Default }
# "Note" columns are read-only, informational text that is not saved.
function New-EditorGrid {
    param([object[]]$Columns)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AutoGenerateColumns = $false
    $grid.AllowUserToAddRows = $true
    $grid.AllowUserToDeleteRows = $true
    $grid.RowHeadersWidth = 30
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

    $defaults = @{}

    foreach ($c in $Columns) {
        if ($c.Type -eq "Check") {
            $col = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
            $defaults[$c.Name] = [bool]$c.Default
        } else {
            $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            if ($c.Type -eq "Note") {
                $col.ReadOnly = $true
                $col.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray
            }
        }

        $col.Name = $c.Name
        $col.HeaderText = $c.Header
        $col.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable

        if ($c.Width -gt 0) {
            $col.Width = $c.Width
        } else {
            $col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        }

        [void]$grid.Columns.Add($col)
    }

    # New rows start with checkbox defaults (Required = checked).
    $grid.Tag = $defaults
    $grid.Add_DefaultValuesNeeded({
        param($sender, $e)
        foreach ($key in $sender.Tag.Keys) {
            $e.Row.Cells[$key].Value = $sender.Tag[$key]
        }
    })

    return $grid
}

function Format-EditorNumber {
    param($Value)

    if ($null -eq $Value) { return "" }
    return ([double]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Add-EditorGridRow {
    param($Grid, [object[]]$Values)
    [void]$Grid.Rows.Add($Values)
}

function Get-EditorGridRows {
    param($Grid)

    [void]$Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    [void]$Grid.EndEdit()

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($r in $Grid.Rows) {
        if ($r.IsNewRow) { continue }

        $row = @{}
        foreach ($c in $Grid.Columns) {
            $row[$c.Name] = $r.Cells[$c.Name].Value
        }
        $rows.Add($row)
    }

    return @($rows)
}

function New-EditorGridTab {
    param($Tabs, [string]$Title, $Grid, [string]$Hint)

    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Title
    $page.Padding = New-Object System.Windows.Forms.Padding(8)

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = $Hint
    $hintLabel.Dock = [System.Windows.Forms.DockStyle]::Top
    $hintLabel.Height = 40
    $hintLabel.ForeColor = [System.Drawing.Color]::DimGray

    $page.Controls.Add($Grid)
    $page.Controls.Add($hintLabel)
    $Grid.BringToFront()

    $Tabs.TabPages.Add($page)
}

# Returns $true when the configuration was saved.
function Show-ConfigEditor {
    param([string]$ConfigBaseName)

    if ($script:AppMode -ne "Engineer") {
        Show-Message -Icon Warning -Title "Engineer Mode Required" -Text "Configuration editing is available only in Engineer mode."
        return $false
    }

    $path = Get-ConfigPath $ConfigBaseName

    if (-not (Test-Path $path)) {
        Show-Message -Icon Error -Title "Configuration Missing" -Text "Configuration file not found:`n$path"
        return $false
    }

    try {
        $config = Read-HardwareConfig -Path $path
    }
    catch {
        Show-ErrorWithLog $_ "Unable to Read Configuration"
        return $false
    }

    $integrity = Test-ConfigIntegrity -ConfigPath $path

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Edit Configuration - $ConfigBaseName"
    $dlg.StartPosition = "CenterParent"
    $dlg.Size = New-Object System.Drawing.Size(900,620)
    $dlg.MinimumSize = New-Object System.Drawing.Size(760,480)
    $dlg.ShowInTaskbar = $false

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill

    # --- General tab -------------------------------------------------------
    $general = New-Object System.Windows.Forms.TabPage
    $general.Text = "General"
    $general.AutoScroll = $true

    $y = 15
    if (-not $integrity.Valid) {
        $warn = New-Object System.Windows.Forms.Label
        $warn.Text = "Warning: $($integrity.Detail) Saving will register the edited contents as known-good."
        $warn.ForeColor = [System.Drawing.Color]::DarkRed
        $warn.Location = New-Object System.Drawing.Point(15, $y)
        $warn.Size = New-Object System.Drawing.Size(800, 36)
        $general.Controls.Add($warn)
        $y += 42
    }

    $txtName = New-EditorTextBox $general "Configuration name:" $y $config.Name -ReadOnly; $y += 34
    $txtManufacturer = New-EditorTextBox $general "System manufacturer (exact):" $y $config.System.Manufacturer; $y += 34
    $txtModel = New-EditorTextBox $general "System model (exact):" $y $config.System.Model; $y += 34
    $txtCpu = New-EditorTextBox $general "CPU model contains:" $y $config.CPU.ModelContains; $y += 34
    $numCores = New-EditorNumber $general "CPU minimum cores:" $y $config.CPU.MinimumCores 1 1024; $y += 34
    $numLogical = New-EditorNumber $general "CPU minimum logical CPUs:" $y $config.CPU.MinimumLogicalCPUs 0 4096 -Hint "0 = not checked"; $y += 34
    $numMemory = New-EditorNumber $general "Memory minimum total GB:" $y $config.Memory.MinimumTotalGB 0.01 100000 -DecimalPlaces 2 -Hint "Capture sets this to 95% of installed RAM"; $y += 34
    $numDimms = New-EditorNumber $general "Expected DIMM count (exact):" $y $config.Memory.ExpectedDIMMs 0 256; $y += 34

    $tabs.TabPages.Add($general)

    # --- Component tabs ----------------------------------------------------
    $requiredHint = "Uncheck Required to make a component optional: it may be absent, but if installed it must still meet its limits. Type in the last (blank) row to add a component; select a row and use Remove Selected Row to delete one."

    $gridStorage = New-EditorGrid @(
        @{ Name = "FriendlyNameContains"; Header = "Disk name contains"; Type = "Text"; Width = 0 },
        @{ Name = "BusType"; Header = "Bus type (exact)"; Type = "Text"; Width = 130 },
        @{ Name = "MinimumGB"; Header = "Minimum GB"; Type = "Text"; Width = 110 },
        @{ Name = "Required"; Header = "Required"; Type = "Check"; Width = 80; Default = $true }
    )
    foreach ($d in @($config.Storage.PhysicalDisks)) {
        Add-EditorGridRow $gridStorage @([string]$d.FriendlyNameContains, [string]$d.BusType, (Format-EditorNumber $d.MinimumGB), [bool]$d.Required)
    }
    New-EditorGridTab $tabs "Storage" $gridStorage $requiredHint

    $gridNetwork = New-EditorGrid @(
        @{ Name = "AdapterContains"; Header = "Adapter description contains"; Type = "Text"; Width = 0 },
        @{ Name = "Required"; Header = "Required"; Type = "Check"; Width = 80; Default = $true },
        @{ Name = "RequireUp"; Header = "Link must be Up"; Type = "Check"; Width = 110; Default = $false },
        @{ Name = "MinimumLinkMbps"; Header = "Min link Mbps (blank = none)"; Type = "Text"; Width = 170 },
        @{ Name = "Note"; Header = "Note"; Type = "Note"; Width = 230 }
    )
    foreach ($a in @($config.Network.Adapters)) {
        Add-EditorGridRow $gridNetwork @(
            [string]$a.AdapterContains, [bool]$a.Required, [bool]$a.RequireUp,
            (Format-EditorNumber $a.MinimumLinkMbps),
            (Get-NetworkAdapterEditorNote -AdapterContains ([string]$a.AdapterContains) -MinimumLinkMbps ([string](Format-EditorNumber $a.MinimumLinkMbps)))
        )
    }
    # Keep the note in step with what the engineer types.
    $gridNetwork.Add_CellValueChanged({
        param($sender, $e)
        if ($e.RowIndex -lt 0) { return }
        $colName = $sender.Columns[$e.ColumnIndex].Name
        if ($colName -ne "AdapterContains" -and $colName -ne "MinimumLinkMbps") { return }
        $row = $sender.Rows[$e.RowIndex]
        $row.Cells["Note"].Value = Get-NetworkAdapterEditorNote `
            -AdapterContains ([string]$row.Cells["AdapterContains"].Value) `
            -MinimumLinkMbps ([string]$row.Cells["MinimumLinkMbps"].Value)
    })
    New-EditorGridTab $tabs "Network" $gridNetwork "$requiredHint Wireless adapters never enforce a minimum link speed."

    $gridGpu = New-EditorGrid @(
        @{ Name = "ModelContains"; Header = "GPU name contains"; Type = "Text"; Width = 0 },
        @{ Name = "Required"; Header = "Required"; Type = "Check"; Width = 80; Default = $true }
    )
    foreach ($g in @($config.GPU.Adapters)) {
        Add-EditorGridRow $gridGpu @([string]$g.ModelContains, [bool]$g.Required)
    }
    New-EditorGridTab $tabs "GPU" $gridGpu $requiredHint

    # --- Bottom buttons ----------------------------------------------------
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottom.Height = 52
    # Size the panel before adding right-anchored buttons so their anchor
    # distances are measured from the final width.
    $bottom.Width = $dlg.ClientSize.Width

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "Remove Selected Row"
    $btnRemove.Location = New-Object System.Drawing.Point(12,10)
    $btnRemove.Size = New-Object System.Drawing.Size(160,32)
    $bottom.Controls.Add($btnRemove)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Size = New-Object System.Drawing.Size(110,32)
    $btnSave.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnSave.Location = New-Object System.Drawing.Point(($dlg.ClientSize.Width - 240),10)
    $bottom.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Size = New-Object System.Drawing.Size(110,32)
    $btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnCancel.Location = New-Object System.Drawing.Point(($dlg.ClientSize.Width - 122),10)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $bottom.Controls.Add($btnCancel)

    $dlg.Controls.Add($tabs)
    $dlg.Controls.Add($bottom)
    $tabs.BringToFront()
    $dlg.CancelButton = $btnCancel

    $state = @{ Saved = $false }

    $btnRemove.Add_Click({
        $grid = $null
        switch ($tabs.SelectedTab.Text) {
            "Storage" { $grid = $gridStorage }
            "Network" { $grid = $gridNetwork }
            "GPU"     { $grid = $gridGpu }
        }

        if ($null -eq $grid -or $null -eq $grid.CurrentRow -or $grid.CurrentRow.IsNewRow) {
            Show-Message -Title "Remove Row" -Text "Open the Storage, Network or GPU tab and click a row to remove first."
            return
        }

        $grid.Rows.Remove($grid.CurrentRow)
    })

    $btnSave.Add_Click({
        try {
            $generalValues = @{
                Name = $config.Name
                Manufacturer = $txtManufacturer.Text
                Model = $txtModel.Text
                CpuModelContains = $txtCpu.Text
                MinimumCores = [int]$numCores.Value
                MinimumLogicalCPUs = [int]$numLogical.Value
                MinimumTotalGB = [double]$numMemory.Value
                ExpectedDIMMs = [int]$numDimms.Value
            }

            $edited = ConvertFrom-ConfigEditorData `
                -General $generalValues `
                -StorageRows @(Get-EditorGridRows $gridStorage) `
                -NetworkRows @(Get-EditorGridRows $gridNetwork) `
                -GpuRows @(Get-EditorGridRows $gridGpu)

            if (@($edited.Errors).Count -gt 0) {
                Show-Message -Icon Warning -Title "Fix These Problems Before Saving" -Text ([string]::Join([Environment]::NewLine, @($edited.Errors)))
                return
            }

            $confirm = Confirm-Message -Title "Save Configuration?" -Text (
                "Save changes to '$ConfigBaseName'?`n`n" +
                "The integrity record will be updated so Production mode accepts the edited configuration."
            )
            if (-not $confirm) { return }

            Save-HardwareConfig -Config $edited.Config -Path $path
            $state.Saved = $true
            $dlg.Close()
        }
        catch {
            Show-ErrorWithLog $_ "Unable to Save Configuration"
        }
    })

    [void]$dlg.ShowDialog($script:form)
    $dlg.Dispose()

    if ($state.Saved) {
        Show-Message -Title "Configuration Saved" -Text "Configuration '$ConfigBaseName' was saved and integrity-registered."
    }

    return [bool]$state.Saved
}
