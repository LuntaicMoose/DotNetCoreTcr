# Accept a folder path as a parameter

param (
    [string]$folder,
    [string]$testProjectSuffix = ".Tests"
)

#region Variables
# Declare variables at the beginning of the script
$script:debounceTime = (Get-Date)
$script:debounceInterval = 1 # Debounce interval in seconds
$script:tcrPaused = $false
$script:tcrRunning = $false
#endregion

#region Helper Functions
# Enables debouncing repeated triggers
Function Test-Debounce {
    param([DateTime]$time)
    $timeDifference = ($time - $script:debounceTime).TotalSeconds
    if ($timeDifference -lt $script:debounceInterval) {
        return $true
    }
    $script:debounceTime = $time
    return $false
}

# Helper function to minimize clutter in other methods
function Invoke-Command {
    param([string]$command)
    Invoke-Expression -Command $command | Write-Host
}

function Show-Spinner {
    param (
        [string[]]$spinnerChars = @('|', '/', '-', '\'),
        [int]$currentIndex = 0
    )
    Write-Host "`r$($spinnerChars[$currentIndex])" -NoNewline
    return ($currentIndex + 1) % $spinnerChars.Length
}
#endregion

#region Test Analysis Functions
function Test-OnlySingleNotImplementedException {
    param([string]$testResults)
    $nie = Test-SingleNotImplementedException $testResults
    $nmf = Test-NotMultipleFailedTests $testResults
    return $nie -and $nmf
}

function Test-SingleNotImplementedException {
    param([string]$testOutput)
    $count = ([regex]::Matches($testOutput, "System.NotImplementedException: The method or operation is not implemented." )).count
    return $count -eq 1
}

function Test-NotMultipleFailedTests {
    param([string]$testOutput)
    $match = [regex]::Match($testOutput, "Failed:\s*(\d+)")
    if ($match.Success) {
        $failedCount = [int]$match.Groups[1].Value
        return $failedCount -le 1
    }
    return $false
}

function Test-ProbableProjectCreation {
    param([string]$testOutput)
    return $testOutput -Match "Project file does not exist."
}

function Test-NoTestsFound {
    param([string]$testOutput)
    return $testOutput -Match "No test matches the given testcase"
}

function Test-TestsPassed {
    param([string]$testOutput)
    return $testOutput -Match "Test Run Successful."
}

function Test-TestsFailed {
    param([string]$testOutput)
    return (Test-TestRunStarted $testOutput) -and (Test-BuildFailed $testOutput)
}

function Test-BuildFailed {
    param([string]$testOutput)
    return $testOutput -Match "Build FAILED."
}

function Test-TestRunStarted {
    param([string]$testOutput)
    return $testOutput -Match "Starting test execution, please wait..."
}
#endregion

#region Git Operations
function Get-GitChanges {
    $gitStatusOutput = git status --porcelain *.cs
    Write-Host "### Found changes in the repository [$gitStatusOutput]" -ForegroundColor Blue
    return $gitStatusOutput
}

# Commits our code, rebases, pushes to the server
function Invoke-Commit {
    if (-not $(Get-GitChanges)) {
        Write-Host "No changes to commit." -ForegroundColor Yellow
        return
    }

    $commitMsg = Get-CommitMessage
    if (-not $commitMsg) {
        Write-Host "Commit canceled by user." -ForegroundColor Yellow
        return
    }
    Write-Host "### Committing changes with message: $commitMsg" -ForegroundColor Green
    Invoke-Command "git add *.cs *.csproj *.sln"
    Invoke-Command "git commit -m '$commitMsg'"
    Invoke-Command "git pull --rebase"
    Invoke-Command "git push"
}

# Reset our code folder
function Invoke-Revert {
    # Nuke directories
    Invoke-Command "git clean -df -e **.Tests"
    # Restore files
    Invoke-Command "git checkout HEAD -- *.cs *.sln :!**Tests.cs"
    if($LASTEXITCODE -ne 0){
        Write-Host "Unable to revert. Git's broke somewhere. [LASTEXITCODE=$LASTEXITCODE]" -ForegroundColor Red
    }
}
#endregion

#region Path Helpers
function Get-RetrievePaths {
    param([string]$path)
    $csprojFile = $null
    $directory = Split-Path -Path $path -Parent
    $changedFilePath = $directory
    
    while ($directory) {
        $csprojFile = Get-ChildItem -Path $directory -Filter *.csproj -File -ErrorAction SilentlyContinue
        if ($csprojFile) { break }
        $directory = Split-Path -Path $directory -Parent
    }

    if (-not $csprojFile) {
        Write-Host "No csproj file found in the directory hierarchy starting from $path"
    }

    # Extract the file name, no extension, from $path
    $changedFileName = [System.IO.Path]::GetFileNameWithoutExtension($path)
    $csprojFileName = [System.IO.Path]::GetFileNameWithoutExtension($csprojFile.FullName)

    # Get relative path for namespace calculation
    $relativePath = $changedFilePath.Substring($changedFilePath.LastIndexOf('\') + 1)
    $relativePath = $relativePath -replace '\\', '.'

    return @{
        success = [bool]$csprojFile
        csprojPath = $directory
        csprojName = $csprojFileName
        changedPath = $changedFilePath
        changedName = $changedFileName
        changedFqn = $relativePath
    }
}
#endregion

#region Test Execution
function Test-TestRunElapsed {
    param([System.Diagnostics.Stopwatch]$stopwatch)
    $elapsedTime = $stopwatch.Elapsed.ToString("hh\:mm\:ss\.fff")
    Write-Host -NoNewline "`rTest Run Time: (" -ForegroundColor White
    Write-Host -NoNewline $elapsedTime -ForegroundColor Green
    Write-Host -NoNewline ")" -ForegroundColor White
}

function Invoke-RunTests {
    param([string]$path)
    $results = Get-RetrievePaths $path

    if($results.success -eq $false) {
        Write-Host "No csproj file found. Cannot run tests."
        return; 
    }

    # Check if the csprojName ends in .Tests
    $isTestProject = $results.csprojName.EndsWith($testProjectSuffix)

    if($isTestProject) {
        $testProjectPath = "$($results.csprojPath)\$($results.csprojName).csproj"
        $testClassFilter = "$($results.changedFqn).$($results.changedName)"
    } else {
        $testProjectPath = "$($results.csprojPath)$testProjectSuffix\$($results.csprojName)$testProjectSuffix.csproj"
        $testClassFilter = "$($results.changedFqn)$testProjectSuffix.$($results.changedName)$testProjectSuffix"
    }

    try {
        # Start a stopwatch to track elapsed time
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Run the command in a separate thread while updating elapsed time
        $job = Start-Job -ScriptBlock {
            param ($testProjectPath, $testClassFilter)
            dotnet test $testProjectPath --no-restore --configuration DEBUG --filter "FullyQualifiedName~$testClassFilter" -v n
            return $output
        } -ArgumentList $testProjectPath, $testClassFilter

        # Display elapsed time while the job is running
        while ($job.State -eq 'Running') {
            Test-TestRunElapsed $stopwatch
            Start-Sleep -Milliseconds 100
        }

        # Wait for the job to complete
        $output = Receive-Job -Job $job
        Remove-Job -Job $job

        # Stop the stopwatch
        $stopwatch.Stop()

        Test-TestRunElapsed $stopwatch

        Write-Host ""

        $output | ForEach-Object { Write-Host $_ }

        return $output
    } catch {
        Write-Host "Error running tests: $_" -ForegroundColor Red
    }
}
#endregion

#region UI Components
Add-Type -AssemblyName System.Windows.Forms
function Get-CommitMessage {
    # Create the form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Arlo Commit Notation Message"
    $form.Size = New-Object System.Drawing.Size(440, 380)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    # Create a text box
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Size = New-Object System.Drawing.Size(400, 20)
    $textBox.Location = New-Object System.Drawing.Point(10, 10)
    $textBox.Font = New-Object System.Drawing.Font("Courier New", 18)
    $form.Controls.Add($textBox)

    # Handle the KeyDown event for the text box
    $textBox.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })

    # Create info label
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "
| RISK LEVEL        | CORE INTENTIONS       |
|-------------------|-----------------------|
| Proven Safe : '.' | F|f : Feature         |
| Validated   : '^' | B|b : Bug Fix         |
| Risky       : '!' | R|r : Refactoring     |
| Broken      : '@' | D|d : Documentation   |
|                   | E|e : Environment     |
|                   | t   : Tests Only      |
|-------------------|-----------------------|
Examples
  . r rename variable
  ! B fixed spelling on lable
  ^ R manually extracted cohesive class
"
    $infoLabel.AutoSize = $true
    $infoLabel.Location = New-Object System.Drawing.Point(10, 50)
    $infoLabel.Size = New-Object System.Drawing.Size(360, 20)
    $infoLabel.Font = New-Object System.Drawing.Font("Courier New", 10)
    $form.Controls.Add($infoLabel)
    
    # Create quick action buttons with consistent pattern
    $buttonConfigs = @(
        @{ Text = "Rename"; X = 10; Message = ". r Rename" },
        @{ Text = "Inline"; X = 90; Message = ". r Inline" },
        @{ Text = "Extract Method"; X = 170; Message = ". r Extract Method" },
        @{ Text = "Extract Variable"; X = 250; Message = ". r Extract Variable" },
        @{ Text = "Formatting"; X = 330; Message = ". a formatting" }
    )
    
    foreach ($config in $buttonConfigs) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $config.Text
        $button.Location = New-Object System.Drawing.Point($config.X, 270)
        $buttonMessage = $config.Message
        $button.Add_Click({ $textBox.Text = $buttonMessage })
        $form.Controls.Add($button)
    }

    # Create an OK button
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Location = New-Object System.Drawing.Point(250, 300)
    $okButton.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($okButton)

    # Create a Cancel button
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(330, 300)
    $cancelButton.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($cancelButton)

    # Show the form
    $dialogResult = $form.ShowDialog()

    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text
    } else {
        return $null
    }
}
#endregion

#region Core TCR Functions
# The Core Workload
Function Invoke-TCR {
    param($eventInfo)
    if (Test-Debounce $eventInfo.TimeGenerated) {
        return
    }
    
    Write-Host ""
    $name = $eventInfo.SourceEventArgs.Name
    $changeType = $eventInfo.SourceEventArgs.ChangeType
    $timeStamp = $eventInfo.TimeGenerated
    
    $path = $eventInfo.SourceEventArgs.FullPath
    Write-Host "The file $name at $path was $changeType at $timeStamp"

    $testResults = Invoke-RunTests $path

    Write-Host "### Tests Run - checking results"

    if (-not $testResults) {
        Write-Host "### No test results. Cannot determine outcome." -ForegroundColor Yellow
        return
    }

    # Process test results with clean branching logic
    switch ($true) {
        { Test-NoTestsFound $testResults } {
            Write-Host "### No tests found. Cannot determine outcome." -ForegroundColor Yellow
            return
        }
        { Test-OnlySingleNotImplementedException $testResults } {
            Write-Host "### A single NotImplementedException is allowed. No Change." -ForegroundColor Cyan
            [System.Console]::Beep(800, 200)
            return
        }
        { Test-TestsPassed $testResults } {
            Write-Host "### Tests Passed. Committing." -ForegroundColor Green
            [System.Console]::Beep(1200, 200)
            [System.Console]::Beep(1400, 500)
            Invoke-Commit
            return
        }
        { Test-TestsFailed $testResults } {
            Write-Host "### Tests failed. Reverting." -ForegroundColor Red
            [System.Console]::Beep(500, 200)
            [System.Console]::Beep(300, 500)
            Invoke-Revert
            return
        }
        { Test-BuildFailed $testResults } {
            Write-Host "### Build failed. Reverting." -ForegroundColor Magenta
            [System.Console]::Beep(400, 200)
            [System.Console]::Beep(300, 200)
            Invoke-Revert
            return
        }
        default {
            Write-Host "### Undefined test result state." -ForegroundColor Yellow
        }
    }
}
#endregion

#region File System Watcher
# Builds our Watcher
function Register-Watcher {
    Write-Host "Watching $folder"
    $filter = "*.cs"
    $watcher = New-Object IO.FileSystemWatcher $folder, $filter -Property @{ 
        IncludeSubdirectories = $true
        EnableRaisingEvents = $true
    }

    return $watcher
}

function Invoke-DoTheWork {
    $FileSystemWatcher = Register-Watcher
    $Action = {
        if ($script:tcrPaused) { 
            return
        }
         
        $filePath = $event.SourceEventArgs.FullPath
        # Skip obj directory files and non-cs/csproj files
        if ($filePath -match "\\obj\\") {
            return
        }

        if ($filePath -match "\.cs$" -or $filePath -match "\.csproj$") {
            $script:tcrRunning = $true
            Invoke-TCR $event
            $script:tcrRunning = $false
        }
    }
    
    # Add event handlers
    $handlers = . {
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Changed" -Action $Action -SourceIdentifier FSChange
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Created" -Action $Action -SourceIdentifier FSCreate
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Deleted" -Action $Action -SourceIdentifier FSDelete
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Renamed" -Action $Action -SourceIdentifier FSRename
    }

    try {
        $spinnerIndex = 0
        
        # Consolidated main loop with clear pause/resume handling
        do {
            # Check for key press to toggle pause
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true).Key
                if ($key -eq 'P') {
                    $script:tcrPaused = -not $script:tcrPaused
                    $pauseStatus = if ($script:tcrPaused) { "Paused. Press 'P' again to resume." } else { "Resumed." }
                    $color = if ($script:tcrPaused) { "Yellow" } else { "Green" }
                    Write-Host "`r$pauseStatus" -ForegroundColor $color
                }
            }

            # Handle paused state
            if ($script:tcrPaused) {
                Start-Sleep -Milliseconds 100
                continue
            }

            # Simplified waiting with/without spinner
            if ($script:tcrRunning) {
                Wait-Event -Timeout 1
            } else {
                $spinnerIndex = Show-Spinner -currentIndex $spinnerIndex
                Wait-Event -Timeout 1
            }
        } while ($true)
    }
    finally {
        # Clean up resources
        Write-Host "`nExiting. Thank you for playing!"
        Unregister-Event -SourceIdentifier FSChange
        Unregister-Event -SourceIdentifier FSCreate
        Unregister-Event -SourceIdentifier FSDelete
        Unregister-Event -SourceIdentifier FSRename
        $handlers | Remove-Job
        $FileSystemWatcher.EnableRaisingEvents = $false
        $FileSystemWatcher.Dispose()
        "Event Handler disabled."
    }
}
#endregion

# Trap Ctrl+C to gracefully exit
trap {
    Write-Host "Ctrl+C pressed. Exiting..."
    break
}

# Save the current directory
$originalFolder = Get-Location

try {
    # Change to the passed-in folder
    Set-Location $folder
    Write-Host "Changed directory to $folder"

    # Perform the work
    Invoke-DoTheWork
}
finally {
    # Change back to the original directory
    Set-Location $originalFolder
    Write-Host "Returned to original directory: $originalFolder"
}