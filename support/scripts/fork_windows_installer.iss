; Separate installation identity for this fork; never replaces upstream LocalSend.
#ifndef MyAppVersion
  #error MyAppVersion must be supplied from app/pubspec.yaml
#endif
#ifndef PayloadDir
  #error PayloadDir is required
#endif
#ifndef ResultDir
  #error ResultDir is required
#endif

[Setup]
AppId={{489FD5C5-19BE-4F73-9566-B47924A0A5BA}
AppName=LocalSend AutoSync
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\LocalSend AutoSync
DefaultGroupName=LocalSend AutoSync
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#ResultDir}
OutputBaseFilename=LocalSend-{#MyAppVersion}-windows-x86-64
SetupIconFile={#PayloadDir}\logo.ico
UninstallDisplayIcon={app}\localsend_app.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "*.pdb,*.msix,*.manifest,install_msix_helper.ps1,logo.ico"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\LocalSend AutoSync"; Filename: "{app}\localsend_app.exe"

[Run]
Filename: "{app}\localsend_app.exe"; Description: "Launch LocalSend AutoSync"; Flags: nowait postinstall skipifsilent
