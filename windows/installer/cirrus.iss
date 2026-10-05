; Inno Setup script for the Cirrus Windows installer.
; Built in CI: iscc /DAppVersion=0.1.0 /DSourceDir=<Release dir> /DOutputDir=dist windows\installer\cirrus.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{39AB8879-A24D-457E-B480-AC908C2EBCDB}
AppName=Cirrus
AppVersion={#AppVersion}
AppVerName=Cirrus {#AppVersion}
AppPublisher=Cirrus contributors
AppPublisherURL=https://github.com/felixbennettio/edgeops
DefaultDirName={autopf}\Cirrus
DefaultGroupName=Cirrus
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Cirrus-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\cirrus.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Cirrus"; Filename: "{app}\cirrus.exe"
Name: "{autodesktop}\Cirrus"; Filename: "{app}\cirrus.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\cirrus.exe"; Description: "{cm:LaunchProgram,Cirrus}"; Flags: nowait postinstall skipifsilent
