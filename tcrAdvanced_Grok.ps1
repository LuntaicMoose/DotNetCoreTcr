param (
    [string]$folder,
    [string]$testProjectSuffix = ".Tests"
)

$script:debounceTime = Get-Date
$script:debounceInterval = 1
$script:tcrPaused = $false
$script:tcrRunning = $false

Function Test-Debounce($eventTime) {
    $timeDifference = ($eventTime - $script:debounceTime).TotalSeconds
    if ($timeDifference -lt $script:debounceInterval) { return $true }
    $script:debounceTime = $eventTime
    return $false
}

Function Get-TestOutcome($testOutput) {
    switch -Regex ($testOutput) {
        "Build FAILED." { return "BuildFailed" }
        "No test matches the given testcase" { return "NoTestsFound" }
        "Test Run Successful." { return "TestsPassed" }
        "Starting test execution.*Failed:\s*(\d+)" {
            $failedCount = [int][regex]::Match($testOutput, "Failed:\s*(\d+)").Groups[1].Value
            if ($failedCount -gt 0) { return "TestsFailed" }
        }
        "System.NotImplementedException" {
            $nieCount = ([regex]::Matches($testOutput, "System.NotImplementedException")).Count
            $failedCount = [int][regex]::Match($testOutput, "Failed:\s*(\d+)").Groups[1].Value
            if ($nieCount -eq 1 -and $failedCount -le 1) { return "SingleNotImplemented" }
        }
        default { return "Unknown" }
    }
}

Function Invoke-TCR($eventInfo) {
    if (Test-Debounce $eventInfo.TimeGenerated) { return }
    Write-Host "`nFile $($eventInfo.SourceEventArgs.Name) $($eventInfo.SourceEventArgs.ChangeType) at $($eventInfo.TimeGenerated)"
    
    $testResults = Invoke-RunTests $eventInfo.SourceEventArgs.FullPath
    if (-not $testResults) {
        Write-Host "### No test results." -ForegroundColor Yellow
        return
    }

    $outcome = Get-TestOutcome $testResults
    Write-Host "### Test Outcome: $outcome" -ForegroundColor Cyan

    switch ($outcome) {
        "TestsPassed" { Write-Host "### Committing" -ForegroundColor Green; [System.Console]::Beep(1200, 200); [System.Console]::Beep(1400, 500); Invoke-Commit }
        "TestsFailed" { Write-Host "### Reverting" -ForegroundColor Red; [System.Console]::Beep(500, 200); [System.Console]::Beep(300, 500); Invoke-Revert }
        "BuildFailed" { Write-Host "### Build failed, reverting" -ForegroundColor Magenta; [System.Console]::Beep(400, 200); [System.Console]::Beep(300, 200); Invoke-Revert }
        "SingleNotImplemented" { Write-Host "### Single NotImplementedException, no change" -ForegroundColor Cyan; [System.Console]::Beep(800, 200) }
        "NoTestsFound" { Write-Host "### No tests found" -ForegroundColor Yellow }
        "Unknown" { Write-Host "### Unknown outcome" -ForegroundColor Yellow }
    }
}

Function Invoke-Commit {
    if (-not (git status --porcelain *.cs)) {
        Write-Host "No changes to commit." -ForegroundColor Yellow
        return
    }
    $commitMsg = Get-CommitMessage
    if ($commitMsg) {
        Write-Host "### Committing: $commitMsg" -ForegroundColor Green
        Invoke-Command "git add *.cs *.csproj *.sln"
        Invoke-Command "git commit -m '$commitMsg'"
        Invoke-Command "git pull --rebase"
        Invoke-Command "git push"
    } else {
        Write-Host "Commit canceled." -ForegroundColor Yellow
    }
}

Function Invoke-Revert {
    Write-Host "### Reverting changes" -ForegroundColor Red
    Invoke-Command "git clean -df -e **.Tests"
    Invoke-Command "git checkout HEAD -- *.cs *.sln :!**Tests.cs"
    if ($LASTEXITCODE -ne 0) { Write-Host "Revert failed. Git error: [LASTEXITCODE=$LASTEXITCODE]" -ForegroundColor Red }
}

Function Invoke-Command($cmd) {
    Write-Host "Executing [$cmd]" -ForegroundColor Yellow
    & $cmd.Split(" ")[0] ($cmd.Split(" ", 2)[1]) | Write-Host
}

Function Invoke-RunTests($path) {
    $results = Get-RetrievePaths $path
    if (-not $results.success) {
        Write-Host "No csproj found." -ForegroundColor Red
        return
    }

    $isTestProject = $results.csprojName.EndsWith($testProjectSuffix)
    $testProjectPath = if ($isTestProject) { "$($results.csprojPath)\$($results.csprojName).csproj" } else { "$($results.csprojPath)$testProjectSuffix\$($results.csprojName)$testProjectSuffix.csproj" }
    $testClassFilter = if ($isTestProject) { "$($results.changedFqn).$($results.changedName)" } else { "$($results.changedFqn).Tests.$($results.changedName)Tests" }

    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $job = Start-Job -ScriptBlock {
            param ($proj, $filter)
            dotnet test $proj --no-restore --configuration DEBUG --filter "FullyQualifiedName~$filter" -v n
        } -ArgumentList $testProjectPath, $testClassFilter

        while ($job.State -eq 'Running') {
            Test-TestRunElapsed $stopwatch
            Start-Sleep -Milliseconds 100
        }

        $output = Receive-Job -Job $job
        Remove-Job -Job $job
        $stopwatch.Stop()
        Test-TestRunElapsed $stopwatch
        Write-Host ""
        $output | Write-Host
        return $output
    } catch {
        Write-Host "Test error: $_" -ForegroundColor Red
    }
}

Function Test-TestRunElapsed($stopwatch) {
    $elapsed = $stopwatch.Elapsed.ToString("hh\:mm\:ss\.fff")
    Write-Host -NoNewline "`rTest Run Time: ($elapsed)" -ForegroundColor White
}

Function Get-RetrievePaths($path) {
    $csprojFile = $null
    $directory = Split-Path $path -Parent
    while ($directory -and -not $csprojFile) {
        $csprojFile = Get-ChildItem -Path $directory -Filter *.csproj -File -ErrorAction SilentlyContinue
        $directory = Split-Path $directory -Parent
    }

    if (-not $csprojFile) { return @{ success = $false } }
    $changedFileName = [System.IO.Path]::GetFileNameWithoutExtension($path)
    $csprojFileName = [System.IO.Path]::GetFileNameWithoutExtension($csprojFile.FullName)
    $relativePath = $path.Substring($csprojFile.DirectoryName.Length + 1) -replace '\\', '.' -replace '\.cs$', ''

    return @{
        success = $true
        csprojPath = $csprojFile.DirectoryName
        csprojName = $csprojFileName
        changedName = $changedFileName
        changedFqn = $relativePath
    }
}

Function Register-Watcher {
    Write-Host "Watching $folder"
    New-Object IO.FileSystemWatcher $folder, "*.cs" -Property @{ IncludeSubdirectories = $true; EnableRaisingEvents = $true }
}

Function Show-Spinner($spinnerChars = @('|', '/', '-', '\'), $currentIndex = 0) {
    Write-Host "`r$($spinnerChars[$currentIndex])" -NoNewline
    ($currentIndex + 1) % $spinnerChars.Length
}

Function Invoke-DoTheWork {
    $FileSystemWatcher = Register-Watcher
    $Action = {
        if ($script:tcrPaused) { return }
        $filePath = $event.SourceEventArgs.FullPath
        if ($filePath -match "\\obj\\" -or -not ($filePath -match "\.cs$|\.csproj$")) { return }
        
        $script:tcrRunning = $true
        Invoke-TCR $event
        $script:tcrRunning = $false
    }

    $handlers = . {
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Changed" -Action $Action -SourceIdentifier FSChange
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Created" -Action $Action -SourceIdentifier FSCreate
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Deleted" -Action $Action -SourceIdentifier FSDelete
        Register-ObjectEvent -InputObject $FileSystemWatcher -EventName "Renamed" -Action $Action -SourceIdentifier FSRename
    }

    try {
        $spinnerIndex = 0
        while ($true) {
            if ([System.Console]::KeyAvailable) {
                if ([System.Console]::ReadKey($true).Key -eq 'P') {
                    $script:tcrPaused = -not $script:tcrPaused
                    Write-Host "`r$($script:tcrPaused ? 'Paused. Press P to resume.' : 'Resumed.')" -ForegroundColor ($script:tcrPaused ? 'Yellow' : 'Green')
                }
            }
            if (-not $script:tcrPaused -and -not $script:tcrRunning) {
                $spinnerIndex = Show-Spinner -currentIndex $spinnerIndex
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        Write-Host "`nExiting."
        $handlers | ForEach-Object { Unregister-Event -SourceIdentifier $_.Name; Remove-Job $_ }
        $FileSystemWatcher.Dispose()
    }
}

Add-Type -AssemblyName System.Windows.Forms
Function Get-CommitMessage {
    # Create the form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Arlo Commit Notation Message"
    $form.Size = New-Object System.Drawing.Size(440, 380)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog # Prevent resizing
    $form.MaximizeBox = $false # Disable maximize button
    $form.MinimizeBox = $false # Disable minimize button

    # Create a text box
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Size = New-Object System.Drawing.Size(400, 20)
    $textBox.Location = New-Object System.Drawing.Point(10, 10)
    $textBox.Font = New-Object System.Drawing.Font("Courier New", 18) # Set monospace font
    $form.Controls.Add($textBox)

    # Handle the KeyDown event for the text box
    $textBox.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })

    # Create a wide label between the text box and buttons
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
    $infoLabel.Font = New-Object System.Drawing.Font("Courier New", 10) # Set monospace font
    $form.Controls.Add($infoLabel)
    
    $renameButton = New-Object System.Windows.Forms.Button
    $renameButton.Text = "Rename"
    $renameButton.Location = New-Object System.Drawing.Point(10, 270)
    $renameButton.Add_Click({
        $textBox.Text = ". r Rename"
    })
    $form.Controls.Add($renameButton)

    $inlineButton = New-Object System.Windows.Forms.Button
    $inlineButton.Text = "Inline"
    $inlineButton.Location = New-Object System.Drawing.Point(90, 270)
    $inlineButton.Add_Click({
        $textBox.Text = ". r Inline"
    })
    $form.Controls.Add($inlineButton)

    $extractMethodButton = New-Object System.Windows.Forms.Button
    $extractMethodButton.Text = "Extract Method"
    $extractMethodButton.Location = New-Object System.Drawing.Point(170, 270)
    $extractMethodButton.Add_Click({
        $textBox.Text = ". r Extract Method"
    })
    $form.Controls.Add($extractMethodButton)

    $extractVariableMethod = New-Object System.Windows.Forms.Button
    $extractVariableMethod.Text = "Extract Variable"
    $extractVariableMethod.Location = New-Object System.Drawing.Point(250, 270)
    $extractVariableMethod.Add_Click({
        $textBox.Text = ". r Extract Variable"
    })
    $form.Controls.Add($extractVariableMethod)

    $deleteClutterButton = New-Object System.Windows.Forms.Button
    $deleteClutterButton.Text = "Formatting"
    $deleteClutterButton.Location = New-Object System.Drawing.Point(330, 270)
    $deleteClutterButton.Add_Click({
        $textBox.Text = ". a formatting"
    })
    $form.Controls.Add($deleteClutterButton)

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

$originalFolder = Get-Location
try {
    Set-Location $folder
    Write-Host "Changed to $folder"
    Invoke-DoTheWork
} finally {
    Set-Location $originalFolder
    Write-Host "Returned to $originalFolder"
}