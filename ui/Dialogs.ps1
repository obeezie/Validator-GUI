# Small WinForms dialog helpers shared by the UI files.

function Show-Message {
    param(
        [string]$Text,
        [string]$Title,
        [ValidateSet("Information","Warning","Error","Question")]
        [string]$Icon = "Information"
    )

    if ($null -ne $script:form) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $script:form, $Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::$Icon
        )
    } else {
        [void][System.Windows.Forms.MessageBox]::Show(
            $Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::$Icon
        )
    }
}

# Yes/No question. Returns $true only when the user clicks Yes.
# -DefaultNo makes "No" the default button so an accidental Enter is safe.
function Confirm-Message {
    param(
        [string]$Text,
        [string]$Title,
        [ValidateSet("Information","Warning","Error","Question")]
        [string]$Icon = "Question",
        [switch]$DefaultNo
    )

    $defaultButton = if ($DefaultNo) {
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    } else {
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1
    }

    if ($null -ne $script:form) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:form, $Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::$Icon,
            $defaultButton
        )
    } else {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::$Icon,
            $defaultButton
        )
    }

    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Read-TextInput {
    param(
        [string]$Prompt,
        [string]$Title,
        [string]$Default = ""
    )

    return [string][Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $Default)
}

function Show-ErrorWithLog {
    param(
        $ErrorRecord,
        [string]$Title
    )

    Write-ErrorLog $ErrorRecord
    Show-Message -Text "$($ErrorRecord.Exception.Message)`n`nFull details were written to:`n$script:ErrorLog" -Title $Title -Icon Error
}
