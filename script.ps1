<#
Script to export schema from locally running oracle db using export data pump utility and import dump file
into oracle db running in docker container.
The script will exit when an error occurs or the data import is completed successfully
The script requires an existing base directory, e.g. 'C:\Users\username\OracleDataPumpExport\' passed as argument.
It creates all required files and subdirectories on its own.
By design, little emphasis is placed on graceful error handling.

USAGE
Navigate to directory and execute
./script.ps1 -baseDir C:\Users\username\OracleDataPumpExport\ -port 1234 -exportSchema testschema -nlsParameter GERMAN_GERMANY.UTF8 -username username -password password
#>

param (
    [Parameter(Mandatory=$true, helpmessage="The base path to the Oracle data pump export directory.")]
    [string]$baseDir = "C:\Users\jonathan.schwarzhaup\OracleDataPumpExport\",

    [Parameter(Mandatory=$true, helpmessage="The port to the containerized XE Database.")]
    [int]$port = "1521",

    [Parameter(Mandatory=$true, helpmessage="Schemas to export; single value or comma separated values as single string.")]
    [string]$exportSchemas = "systolicstest",
    [Parameter(Mandatory=$true, helpmessage="NLS_PARAMETER value for the target database. E.g. 'GERMAN_GERMANY.UTF8'.")]
    [string]$nlsParameter = "GERMAN_GERMANY.UTF8",
    [Parameter(Mandatory=$true, helpmessage="The username of the sysdba.")]
    [string]$username = "system",
    [Parameter(Mandatory=$true, helpmessage="The password for the sysdba.")]
    [string]$password = "oracle"
)

# Writes a message to the log file
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$message
    )
    $logMessage = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $message"
    Add-Content -Path $logFilePath -Value $logMessage
}

# Cleans up docker
function Clear-Docker {
    # Stop all containers
    docker stop $(docker ps -a -q)
    Write-Log -message "stopped all docker containers"
    # Delete all containers
    docker rm $(docker ps -a -q)
    Write-Log -message "removed all docker containers"
    # Remove all images
    docker rmi -f $(docker images -a -q)
    Write-Log -message "removed all docker images"
}

function Get-Dumpfile-Container {
    param (
        [Parameter(Mandatory=$true)]
        [string]$dir,
        [Parameter(Mandatory=$true)]
        [string]$fileName,
        [Parameter(Mandatory=$true)]
        [string]$container
    )
    $checkFileCommand  = "if test -f $dir/$fileName; then echo 'dumpfile found in running docker volume'; else echo 'dumpfile not found in running docker volume'; fi"
    $output = docker exec $container /bin/bash -c "$checkFileCommand"
    $outputString = $output[-1]
    Write-Log -message $outputString
}


function Wait-ImportCompletion {
    $sleepSeconds = 10
    while ($true) {
        Write-Host "running logs command"
        # Obtain current logs of docker container (only stdout part, ommit stderr)
        $logs = docker logs $containerName 2>&1
        Write-Host "end logs command"

        # Check if completion string is in logs
        if ($logs -Match "successfully completed at") {
            Write-Log -message "Oracle container ready, exiting script."
            Write-Host "Oracle container ready, exiting script."
            break
        } else {
            Write-Log -message "Import not yet completed, waiting $sleepSeconds seconds"
            Write-Log -message "Import logs: $logs"
            Write-Host "Import not yet completed, waiting $sleepSeconds seconds"
            Write-Host "Import logs: $logs"
            Start-Sleep -Seconds $sleepSeconds

        }
    }

}

# Construct subdirectory paths
$logDirectory = Join-Path -Path $baseDir -ChildPath "logs"
$logFilePath = Join-Path -Path $logDirectory -ChildPath "export_script.log"
$expDirectorySource = Join-Path -Path $baseDir -ChildPath "dumps"
$dockerFilePath = Join-Path -Path $baseDir -ChildPath "Dockerfile"
$sqlScriptPath = Join-Path -Path $baseDir -ChildPath "01.sql"
$impdpScriptPath = Join-Path -Path $baseDir -ChildPath "02.sh"

$expDirTarget = "/tmp/oraexport"

$dumpfile = "SCHEMA_EXPORT.DMP"

<#
SETUP
- check input
- create variables, dockerfile, init.sql if not exist
#>

# If base directory exists. Exit if not
if (-not (Test-Path -Path $baseDir)) {
    Throw "The base directory must exist. Exiting script"
    Exit
}

# If constructed subdirectories exist. Create if not
if (-not(Test-Path -Path $logDirectory)) {
    New-Item -Path $logDirectory -ItemType Directory
}

# Check if the log file exists, create it if it doesn't
if (-not (Test-Path -Path $logFilePath)) {
    New-Item -Path $logFilePath -ItemType File
}

# Is port number 4 digits. Exit if not
if ($port -lt 1000 -or $port -gt 9999) {
    Write-Log -message "invalid port number $port"
    Throw "The port must be a number between 1000 and 9999. Exiting script."
    Exit
}

# If schemas not empty. Exit if not
if ([string]::IsNullOrWhiteSpace($exportSchemas)) {
    Write-Log -message "Schemas to export cannot be empty. Exiting script."
    Exit
}

if (-not(Test-Path -Path $expDirectorySource)) {
    New-Item -Path $expDirectorySource -ItemType Directory
    Write-Log -message "export directory created at $expDirectorySource"
}

# If init.sql, data_pump_import.sh and Dockerfile exist. Create if not
if (-not(Test-Path -Path $sqlScriptPath)) {
    $sqlFileContents = @"
        sqlplus system/oracle

        create user import_user identified by password;

        alter user import_user quota unlimited on users;

        alter user import_user default tablespace users;

        grant datapump_imp_full_database to import_user;

        create directory DATA_PUMP_IMP as '$expDirTarget';

        grant read, write on directory data_pump_imp to import_user;

        set sqlblanklines on;

        exit
"@
    $sqlFileContents | Out-File -FilePath $sqlScriptPath -Encoding UTF8
    Write-Log -message "created init.sql at $sqlScriptPath"
}

if (-not(Test-Path -Path $impdpScriptPath)) {
    $impdpFileContents = @"
        #!/bin/bash
        chmod -R 777 $expDirTarget
        `$ORACLE_HOME/bin/impdp import_user/password DIRECTORY=DATA_PUMP_IMP DUMPFILE=$dumpfile LOGFILE=log_import.log SCHEMAS=$exportSchemas
"@
    # use writer here, because the typical "Out-File" verb adds Byte Order Mark (BOM); Encoding utf8NoBOM
    # is only available in PowerShell version >= 6, thus might require an upgrade on host system, not feasible
    # Taken from https://stackoverflow.com/questions/5596982/using-powershell-to-write-a-file-in-utf-8-without-the-bom
    [IO.File]::WriteAllLines($impdpScriptPath, $impdpFileContents)
    # $impdpFileContents | Out-File -FilePath $impdpScriptPath -Encoding utf8
    Write-Log -message "created data pump import script at $impdpScriptPath"

}

if (-not(Test-Path -Path $dockerFilePath)) {
    $dockerFileContent = @"
        FROM wnameless/oracle-xe-11g-r2

        COPY dumps $expDirTarget

        # Add initialization scripts executed on startup
        ADD 01.sql /docker-entrypoint-initdb.d/
        ADD 02.sh /docker-entrypoint-initdb.d/
"@
    $dockerFileContent | Out-File -FilePath $dockerFilePath -Encoding UTF8
    Write-Log -message "created Dockerfile at $dockerFilePath"
}


<#
DELETE PREVIOUS DATA PUMP EXPORT FILES TO ENSURE WE START NEW
#>

Remove-Item -Path "$expDirectorySource\*" -Recurse -Force
Write-Log -message "deleted items in $expDirectorySource"


<#
DOCKER
- check if docker is installed
- stop running containers
- remomve all images
- build image with dockerfile, export dumpfile, and scripts
#>


# Get the file path of the docker executable. Exit if empty
$dockerPath = Get-Command -Name "docker" -ErrorAction SilentlyContinue
if ($null -eq $dockerPath) {
    Write-Log -message "Docker executable not found. Exiting script."
    exit
} else {
    Write-Log -message "Docker executable found"
}

# Clean docker
Clear-Docker
Write-Log -message "cleaned docker"

# Set variables
$imageName = "img_oracle_restore"
$containerName = "con_oracle_restore"


<#
SOURCE DATABASE
- login
- check for export user, create if not exist
#>


# All these settings to only obtain the integer from the output...
$sqlCmd = @"
set FEEDBACK OFF
set heading off
set termout OFF
set FEEDBACK OFF
set TAB OFF
set pause off
set verify off
set UNDERLINE OFF
set trimspool on
set timing off
set echo off
set linesize 1000
set pagesize 100
SELECT count(*) FROM dba_users WHERE username = 'EXPORT_USER';
exit;
"@
$output = Write-Output $sqlCmd | sqlplus -s / as sysdba
# ...and then the output is still garbage - Remove all non-digit characters
$count = $output -replace '[^\d]', ''
# Convert the cleaned output to an integer
[int]$exportUserExists = $count[-1]

# Adjust $expDirectorySource path for Oracle SQL
$oracleFriendlyPath = $expDirectorySource -replace '\\', '/'

Write-Host "export user exists (1 if true): $exportUserExists"
if($exportUserExists -eq 0) {
    Write-Log -message "export user does not exist, creating."
    # This assumes that DATA_PUMP_EXP does not yet exist as directory object
    $sqlCreateExportUser = @"
        CREATE USER EXPORT_USER IDENTIFIED BY password;
        ALTER USER EXPORT_USER QUOTA UNLIMITED ON users;
        ALTER USER EXPORT_USER DEFAULT TABLESPACE users;
        GRANT DATAPUMP_EXP_FULL_DATABASE TO EXPORT_USER;
        CREATE DIRECTORY DATA_PUMP_EXP AS '$oracleFriendlyPath';
        GRANT READ, WRITE ON DIRECTORY DATA_PUMP_EXP to EXPORT_USER;
        exit;
"@
    Write-Log -message "running sql: $sqlCreateExportUser"
    Write-Output $sqlCreateExportUser | sqlplus -s $username/$password
    Write-Log -message "created export user"
}

if($exportUserExists -eq 1) {
    Write-Log -message "export user exists"
}

# Launch export data pump
Write-Log -message "Starting export with command: expdp 'export_user/password' DIRECTORY=DATA_PUMP_EXP DUMPFILE=$dumpfile LOGFILE=log_export.log SCHEMAS=$exportSchemas"
expdp "export_user/password" DIRECTORY=DATA_PUMP_EXP DUMPFILE=$dumpfile LOGFILE=log_export.log SCHEMAS=$exportSchemas

$dumpFilePath = Join-Path -Path $expDirectorySource -ChildPath $dumpfile
# Check if dumpfile was created, exit if not
if (-not (Test-Path -Path $dumpFilePath)) {
    Write-Log -message "ERROR - dumpfile for schema '$exportSchemas' was not created - Exiting"
    Throw "Dumpfile not created. Exiting"
    Return
}
Write-Log -message "dumpfile found in $dumpFilePath"


<#
Target database
#>

# Build the image at $dockerFilePath, it includes a custom init.sql script that creates the directory object and import user with grants
docker build -t $imageName $baseDir
Write-Log -message "built docker image"

# Run docker container
docker run -d --name $containerName -p "${port}:1521" -e ORACLE_ALLOW_REMOTE=true -e NLS_LANG=$nlsLang $imageName
Write-Log -message "running docker image"

# Wait on completion of import
Wait-ImportCompletion