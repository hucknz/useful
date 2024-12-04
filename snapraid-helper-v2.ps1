 # Set the .ini file path
$ScriptName = $MyInvocation.MyCommand.Name
$HomePath = "C:\SnapRAID\Script"  # Update this path if necessary
$ConfigFile = Join-Path $HomePath "snapraid-helper.ini"

# Ensure the .ini file exists
if (!(Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile"
    exit 1
}

# Load the configuration into a hashtable
$config = @{}
Get-Content $ConfigFile | ForEach-Object {
    if (-not ($_.StartsWith(";")) -and ($_.Trim() -ne "")) {
        $key, $value = $_ -split "=", 2
        $config[$key.Trim()] = $value.Trim()
    }
}

# Validate important config values
$requiredConfigs = @("TmpOutputPath", "TmpOutputFile", "SnapRAIDPath", "SnapRAIDExe", "SnapRAIDConfig", "LogPath", "LogFileName", "pingURL", "SnapRAIDEnableScrub", "ScrubFrequencyDays", "LastScrubDate")
foreach ($element in $requiredConfigs) {
    if (-not $config[$element]) {
        Write-Host "$element is missing in the config file."
        exit 1
    }
}

# Global variables
$global:PreProcessHasRun = 0
$global:ServicesStarted = 0
$global:ServicesStopped = 0
$global:DiffChanges = 99

# Set up UTF8 console if enabled in config
if ($config["UTF8Console"] -eq 1) { chcp 65001 }

# Set Paths
$TmpOutput = Join-Path $config["TmpOutputPath"] $config["TmpOutputFile"]
$SnapRAIDLogfile = Join-Path $config["LogPath"] "snapraid_operations.log"
$TranscriptLogfile = Join-Path $config["LogPath"] $config["LogFileName"]

# Ensure Paths Exist
if (!(Test-Path $config["TmpOutputPath"])) { New-Item -ItemType Directory -Path $config["TmpOutputPath"] }
if (!(Test-Path $config["LogPath"])) { New-Item -ItemType Directory -Path $config["LogPath"] }

function Send-Ping {
    param (
        [string]$pingURL = $config["pingURL"],
        [string]$jobstatus,
        [string]$payload = ""
    )
    if ([string]::IsNullOrEmpty($pingURL)) {
        Write-Host "pingURL is not set. Skipping ping."
        return
    }

    try {
        $url = switch ($jobstatus) {
            "success" { $pingURL }
            "fail" { "$pingURL/fail" }
            "start" { "$pingURL/start" }
            default { 
                Write-Host "Invalid job status: '$jobstatus'. No ping sent."
                return
            }
        }

        $headers = @{ "Content-Type" = "application/json" }
        if ($payload -ne "") {
            # Send as POST request with payload
            Invoke-WebRequest -Uri $url -Method POST -Headers $headers -Body $payload -UseBasicParsing -TimeoutSec 10
            Write-Host "Ping with payload sent to $url"
        } else {
            # Send without payload (GET request)
            Invoke-WebRequest -Uri $url -Method GET -UseBasicParsing -TimeoutSec 10
            Write-Host "Ping sent to $url"
        }
    } catch {
        Write-Host "Failed to send ping for status '$jobstatus': $_"
    }
}

function Ensure-LogFile {
    $logFiles = @($SnapRAIDLogfile, $TranscriptLogfile)
    foreach ($logFile in $logFiles) {
        if (!(Test-Path $logFile)) {
            try {
                New-Item -Path $logFile -ItemType File -Force
                Write-Host "Log file created: $logFile"
            } catch {
                Write-Host "ERROR: Unable to create log file $logFile. $($_.Exception.Message)"
                Send-Ping -jobstatus "fail" -payload $outcomeMessage
                exit 1
            }
        }

        try {
            $acl = Get-Acl $logFile
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone", "FullControl", "Allow")
            $acl.SetAccessRule($accessRule)
            Set-Acl $logFile $acl

            $stream = [System.IO.File]::OpenWrite($logFile)
            $stream.Close()
            Write-Host "Log file is writable and permissions set: $logFile"
        } catch {
            Write-Host "ERROR: Unable to set permissions or write to log file $logFile. $($_.Exception.Message)"
            Send-Ping -jobstatus "fail" -payload $outcomeMessage
            exit 1
        }
    }
}

function Manage-LogFile {
    if (Test-Path $TranscriptLogfile) { 
        $file = Get-Item $TranscriptLogfile
        $maxSizeInBytes = if ($config["LogFileMaxSize"] -match '(\d+)\s*mb') {
            [long]($Matches[1]) * 1MB
        } else {
            25MB  # Default to 25MB if parsing fails
        }
        
        if ($file.length -ge $maxSizeInBytes) {
            $i = [int]$config["LogFileZipCount"]
            while ($i -gt 1) {
                $j = $i - 1
                if (Test-Path "$TranscriptLogfile.$j.zip") {
                    Rename-Item "$TranscriptLogfile.$j.zip" "$TranscriptLogfile.$i.zip" -Force
                }
                $i--
            }
            Compress-Archive $TranscriptLogfile "$TranscriptLogfile.1.zip" -Force
            Remove-Item $TranscriptLogfile -Force
            New-Item $TranscriptLogfile -ItemType File
        }
    }
}

function Run-SnapRAID {
    param ($command)
    $snapraidCmd = Join-Path $config["SnapRAIDPath"] $config["SnapRAIDExe"]
    $snapraidConfigPath = Join-Path $config["SnapRAIDPath"] $config["SnapRAIDConfig"]

    try {
        Write-Host "Running SnapRAID command: $snapraidCmd -c $snapraidConfigPath $command -l $SnapRAIDLogfile"
        Write-Host "Current working directory: $(Get-Location)"
        Write-Host "SnapRAID executable exists: $(Test-Path $snapraidCmd)"
        Write-Host "SnapRAID config exists: $(Test-Path $snapraidConfigPath)"
        Write-Host "Log file exists and is writable: $(Test-Path $SnapRAIDLogfile -PathType Leaf) and $((Get-Acl $SnapRAIDLogfile).AccessToString)"

        # Ensure the output file exists before reading
        if (-not (Test-Path $TmpOutput)) {
            New-Item -Path $TmpOutput -ItemType File -Force
        }

        # Execute the SnapRAID command and capture the output
        $output = & "$snapraidCmd" -c "$snapraidConfigPath" $command -l "$SnapRAIDLogfile" 2>&1

        # Handle warnings gracefully
        if ($output -match "WARNING!") {
            if ($SnapRAIDLogfile) {
                Write-Output "SnapRAID Warning: $output" | Out-File -FilePath $SnapRAIDLogfile -Append
            }
        }

        # Check exit code
        if ($LASTEXITCODE -ne 0) {
            if ($command -eq "diff" -and $LASTEXITCODE -eq 2) {
                Write-Host "SnapRAID diff detected changes. Exit code 2 is expected in this case."
                $global:DiffChanges = $LASTEXITCODE
            } else {
                throw "SnapRAID $command failed with exit code $LASTEXITCODE. Check $SnapRAIDLogfile for details."
            }
        } else {
            $global:DiffChanges = 0
        }

        Write-Host "SnapRAID $command completed successfully."
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)"
        if ($SnapRAIDLogfile) {
            "SnapRAID Command: $snapraidCmd -c $snapraidConfigPath $command -l $SnapRAIDLogfile" | Out-File -FilePath $SnapRAIDLogfile -Append
            "Error: $($_.Exception.Message)" | Out-File -FilePath $SnapRAIDLogfile -Append
        } else {
            Write-Host "ERROR: SnapRAID log file path is not set."
        }
        Send-Ping -jobstatus "fail" -payload $outcomeMessage
        Stop-Transcript
        exit 1
    }
}

function Manage-Services {
    param ($action)
    if ($config["ServiceEnable"] -eq 1) {
        $ServiceList = $config["ServiceName"].Split(",").Trim('"')
        foreach ($service in $ServiceList) {
            if ($action -eq "stop") { Stop-Service $service }
            if ($action -eq "start") { Start-Service $service }
        }
    }
}

function Start-Pre-Process {
    if ($config["ProcessEnable"] -eq 1) {
        Write-Host "Starting Pre-Process"
        & $config["ProcessPre"]
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Pre-Process failed with exit code $LASTEXITCODE"
            Send-Ping -jobstatus "fail" -payload $outcomeMessage
            Stop-Transcript
            exit 1
        }
    }
}

function Start-Post-Process {
    if ($config["ProcessEnable"] -eq 1) {
        Write-Host "Starting Post-Process"
        & $config["ProcessPost"]
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Post-Process failed with exit code $LASTEXITCODE"
            Send-Ping -jobstatus "fail" -payload $outcomeMessage
            Stop-Transcript
            exit 1
        }
    }
}

function Check-EventLogs {
    if ($config["EventLogEnable"] -eq 1) {
        $EventLogEntryTypeList = $config["EventLogEntryType"].Replace('"', '').Trim().Split(",")
        $EventLogSourcesList = $config["EventLogSources"].Replace('"', '').Trim().Split(",")

        try {
            $eventLogs = Get-WinEvent -LogName System -FilterHashtable @{
                EntryType = $EventLogEntryTypeList
                ProviderName = $EventLogSourcesList
                StartTime = (Get-Date).AddDays([int]$config["EventLogDays"])
            } -ErrorAction Stop

            if ($eventLogs.Count -gt 0 -and $config["EventLogHaltOnDiskError"] -eq 1) {
                Write-Host "WARN: Disk Errors found in event logs, halting SnapRAID operation."
                Send-Ping -jobstatus "fail" -payload $outcomeMessage
                Stop-Transcript
                exit 1
            }
        } catch [System.Management.Automation.CommandNotFoundException] {
            Write-Host "WARN: Get-WinEvent cmdlet not found. Skipping event log check."
        } catch {
            Write-Host "INFO: No relevant event logs found. Continuing with SnapRAID operations."
        }
    }
}

function Check-Content-Files {
    foreach ($element in $config["SnapRAIDContentFiles"].Split(",")) {
        if (!(Test-Path $element)){
            $message = "ERROR: Content file ($element) not found!"
            Write-Host $message -ForegroundColor red -backgroundcolor yellow
            Send-Ping -jobstatus "fail" -payload $outcomeMessage
            Stop-Transcript
            exit 1
        }
    }
}

function Should-Run-Scrub {
    param (
        [int]$frequencyDays,
        [datetime]$lastScrubDate
    )
    $currentDate = Get-Date
    $nextScrubDate = $lastScrubDate.AddDays($frequencyDays)
    if ($currentDate -ge $nextScrubDate) {
        return $true
    } else {
        return $false
    }
}

function Update-LastScrubDate {
    param (
        [string]$configFilePath,
        [datetime]$newDate
    )
    # Read all lines
    $lines = Get-Content $configFilePath
    # Update the LastScrubDate line
    $updatedLines = $lines | ForEach-Object {
        if ($_ -match "^LastScrubDate\s*=") {
            "LastScrubDate=$($newDate.ToString('yyyy-MM-dd'))"
        } else {
            $_
        }
    }
    # Write back to the config file
    Set-Content -Path $configFilePath -Value $updatedLines
}

function Maybe-Run-Scrub {
    if ($config["SnapRAIDEnableScrub"] -eq "1") {
        $lastScrubDate = [datetime]::ParseExact($config["LastScrubDate"], 'yyyy-MM-dd', $null)
        $frequencyDays = [int]$config["ScrubFrequencyDays"]
        if (Should-Run-Scrub -frequencyDays $frequencyDays -lastScrubDate $lastScrubDate) {
            Write-Host "Scrub frequency reached. Running SnapRAID scrub operation..."
            Run-SnapRAID "scrub"
            # Update the LastScrubDate in the config file
            Update-LastScrubDate -configFilePath $ConfigFile -newDate (Get-Date)
            Write-Host "Scrub operation completed and LastScrubDate updated."
        } else {
            Write-Host "Scrub not required at this time. Last scrub was on $($lastScrubDate.ToShortDateString()). Next scrub scheduled on $($lastScrubDate.AddDays($frequencyDays).ToShortDateString())."
        }
    } else {
        Write-Host "Scrub operation is disabled in the configuration."
    }
}

# Main script execution
Ensure-LogFile
Manage-LogFile

# Send a start ping
Send-Ping -jobstatus "start"

Start-Transcript -path $TranscriptLogfile -append

Write-Host "Starting Pre-Process..."
Start-Pre-Process
Write-Host "Pre-Process completed."

Write-Host "Checking Event Logs..."
Check-EventLogs
Write-Host "Event Logs checked."

Write-Host "Checking Content Files..."
Check-Content-Files
Write-Host "Content Files checked."

Write-Host "Running SnapRAID diff..."
Run-SnapRAID "diff"
Write-Host "Completed SnapRAID diff operation."

# Check if the temporary file exists before reading
if (Test-Path $TmpOutput) {
    $diffOutput = Get-Content $TmpOutput
} else {
    Write-Output "Temp file not found: $TmpOutput" | Out-File -FilePath $SnapRAIDOperationsLog -Append
}
$removeCount = ($diffOutput | Select-String -Pattern "^remove" | Measure-Object).Count

Write-Host "Remove count: $removeCount"
Write-Host "Threshold: $($config["SnapRAIDDelThreshold"])"

if ($removeCount -lt [int]$config["SnapRAIDDelThreshold"] -and ($global:DiffChanges -eq 2 -or $global:DiffChanges -eq 0)) {
    Write-Host "Remove count is below the threshold and diff changes are within acceptable range. Proceeding with Sync."
    Manage-Services "stop"
    
    Write-Host "Running SnapRAID sync..."
    Run-SnapRAID "sync"
    Write-Host "Completed SnapRAID sync operation."
    
    # Decide whether to run scrub based on frequency
    Maybe-Run-Scrub
    
    if ($config["SnapRAIDStatusAfterScrub"] -eq "1") {
        Write-Host "Running SnapRAID status..."
        Run-SnapRAID "status"
        Write-Host "Completed SnapRAID status operation."
    }
    
    Manage-Services "start"
    Write-Host "SUCCESS: SnapRAID SYNC and Scrub (if applicable) completed."
    # Do not send success ping here
} else {
    if ($removeCount -ge [int]$config["SnapRAIDDelThreshold"]) {
        Write-Host "WARNING: Number of deleted files ($removeCount) exceeds threshold ($($config["SnapRAIDDelThreshold"])), manual intervention required."
    } else {
        Write-Host "WARNING: SnapRAID diff returned an unexpected error code ($global:DiffChanges), manual intervention required."
    }
    Send-Ping -jobstatus "fail" -payload $outcomeMessage
}

Write-Host "Starting Post-Process..."
Start-Post-Process
Write-Host "Post-Process completed."

# Send a single success ping at the end
Send-Ping -jobstatus "success"

# End Transcript
Stop-Transcript
Write-Host "Script execution completed."