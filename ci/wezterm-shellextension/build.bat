@echo off
:: BatchGotAdmin
:-------------------------------------
REM  --> Check for permissions
IF "%PROCESSOR_ARCHITECTURE%" EQU "amd64" (
>nul 2>&1 "%SYSTEMROOT%\SysWOW64\cacls.exe" "%SYSTEMROOT%\SysWOW64\config\system"
) ELSE (
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
)

REM --> If error flag set, we do not have admin.
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"

    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%CD%"
    CD /D "%~dp0"
:--------------------------------------

:: Set up the Visual Studio environment
call "D:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat" x64

:: Set the project directory relative to the script location
set "PROJECT_DIR=%~dp0WezTermContextMenu"

:: Change to the project directory
cd /d "%PROJECT_DIR%"

:: Build the project with msbuild
msbuild WezTerm.vcxproj /p:Configuration=Release /p:Platform=x64

:: Check if the build succeeded
if %errorlevel% neq 0 (
    echo Build failed.
    exit /b %errorlevel%
)

:: Copy the .dll file to the target directory relative to the script location
set "SOURCE_DIR=%PROJECT_DIR%\x64\Release"
set "TARGET_DIR=%~dp0WezTerm\WezTerm"

:: Ensure the target directory exists
if not exist "%TARGET_DIR%" (
    mkdir "%TARGET_DIR%"
)

copy "%SOURCE_DIR%\*.dll" "%TARGET_DIR%"

:: Check if the copy succeeded
if %errorlevel% neq 0 (
    echo Copy failed.
    exit /b %errorlevel%
)

echo Build and copy succeeded.

:: Clear environment variables
set PROJECT_DIR=
set SOURCE_DIR=
set TARGET_DIR=

echo Creating self-signed certificate...
powershell -Command "New-SelfSignedCertificate -Type Custom -Subject 'CN=WezTerm' -KeyUsage DigitalSignature -FriendlyName 'SelfSignCert' -CertStoreLocation 'Cert:\CurrentUser\My' -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')"

set /p password="Enter a password for the PFX file: "

for /f "tokens=*" %%a in ('powershell -Command "Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.Subject -eq 'CN=WezTerm' } | Select-Object -ExpandProperty Thumbprint"') do (
    set thumbprint=%%a
)

if not defined thumbprint (
    echo Certificate not found.
    exit /b 1
)

set "batch_dir=%~dp0"
powershell -Command "Export-PfxCertificate -Cert Cert:\CurrentUser\My\%thumbprint% -FilePath '%batch_dir%WezTerm.pfx' -Password (ConvertTo-SecureString -String '%password%' -Force -AsPlainText)"

echo Removing certificate from CertMgr...
certutil -delstore My %thumbprint%
powershell -Command "Remove-Item -Path Cert:\CurrentUser\My\%thumbprint%"

:: Create the MSIX package using makeappx
"D:\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe" pack /d "%~dp0WezTerm" /p "%~dp0WezTerm.msix" /nv

:: Sign the MSIX package using SignTool
set /p PASSWORD="Enter the password for the .pfx file: "

set DIRECTORY=%~dp0

for /R %DIRECTORY% %%F in (*.pfx) do (
    set PFX_PATH="%%F"
)

for /R %DIRECTORY% %%F in (*.msix) do (
    set MSIX_PATH="%%F"
)

"D:\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe" sign /fd SHA256 /a /f %PFX_PATH% /p %PASSWORD% %MSIX_PATH%

:: Import the certificate to the TrustedPeople store
set "batch_dir=%~dp0"

:: Remove any existing certificates with the same subject name
for /f "tokens=*" %%a in ('powershell -Command "Get-ChildItem -Path Cert:\LocalMachine\TrustedPeople | Where-Object { $_.Subject -eq 'CN=WezTerm' } | Select-Object -ExpandProperty Thumbprint"') do (
    certutil -delstore TrustedPeople %%a
)

:: Extract the certificate from the MSIX file
powershell -Command "& { $msixFile = '%MSIX_PATH%'; if (!(Test-Path -Path $msixFile)) { Write-Host 'Error: MSIX file not found.'; exit }; $signature = Get-AuthenticodeSignature -FilePath $msixFile; $certificate = $signature.SignerCertificate; $certificate.Export('Cert') | Set-Content -Encoding Byte 'certificate.cer'; }"

:: Import the certificate to the TrustedPeople store
certutil -addstore -f TrustedPeople certificate.cer

:: Clean up
del certificate.cer

:: Delete the .pfx and .cer files
del "%batch_dir%WezTerm.pfx" /f /q

:: Ask the user if they want to install the package manually
set /p user_input="Do you want to install the package manually? (yes/no): "
if /I "%user_input%" EQU "yes" (
    echo Please install the package manually.
) else (
    echo Installing...
    powershell -Command "Add-AppPackage -Path %MSIX_PATH%"
)

:: Wait for 10 seconds
timeout /t 10

:: End of the script
exit