[Setup]
; NOTE: The value of AppId uniquely identifies this application. Do not use the same AppId value in installers for other applications.
; (To generate a new GUID, click Tools | Generate GUID inside the IDE.)
AppId={{C7A9E8D1-2B3A-4C5D-6E7F-8G9H0I1J2K3L}
AppName=Manfredonia Manager
AppVersion=1.1.1
AppPublisher=Robert Ciobanu
DefaultDirName={autopf}\Manfredonia Manager
DisableProgramGroupPage=yes
; Remove the following line to run in administrative install mode (install for all users.)
PrivilegesRequired=lowest
OutputDir=installer
OutputBaseFilename=Manfredonia Manager setup
SetupIconFile=C:\Users\rober\Documents\Coding\Manfredonia Manager\manfredonia_updater\assets\app_logo_final.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\manfredonia_updater.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\Manfredonia Manager"; Filename: "{app}\manfredonia_updater.exe"
Name: "{autodesktop}\Manfredonia Manager"; Filename: "{app}\manfredonia_updater.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\manfredonia_updater.exe"; Description: "{cm:LaunchProgram,Manfredonia Manager}"; Flags: nowait postinstall skipifsilent
