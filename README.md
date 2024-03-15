# Oracle Restore Workaround Script
## Purpose
- Automated backup of Oracle schema from locally installed database to Oracle database running in a Docker container

## Usage
- On host machine, create directory for export (also referred to as `baseDir`) (required resources, e.g. Dockerfile will be automatically created)
- in directory, create a new file (e.g. export_script.ps1) using TextEditor or other tool
- Copy/ paste the code from this repository into the file
- If required, run: `Unblock-File -Path .\export_script.ps1` assuming you are in the script's directory - this will let you run untrusted files. For more info refer to [docs](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file?view=powershell-7.4)
- Retrieve local Oracle database sysdba username and password and pass it to cmd as args
- Run script using command: `./export_script.ps1 -baseDir C:\Users\username\OracleDataPumpExport\ -port 1234 -exportSchema testschema -nlsParameter GERMAN_GERMANY.UTF8 -username username -password password`
- You can find a description of the parameters and their meaning in the docstring of the script at top of file
- Sysdba for Docker container DB is: username: system, password: oracle
