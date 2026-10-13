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
#ifndef TargetArchitecture
  #define TargetArchitecture "x64"
#endif
#if TargetArchitecture == "arm64"
  #define ArchitectureName "arm64"
#else
  #define ArchitectureName "x86-64"
#endif

[Setup]
AppId={{489FD5C5-19BE-4F73-9566-B47924A0A5BA}
AppName=LocalSend
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\LocalSend AutoSync
; Preserve the installation path and AppId so existing fork installations upgrade in place.
DefaultGroupName=LocalSend
PrivilegesRequired=lowest
#if TargetArchitecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
OutputDir={#ResultDir}
OutputBaseFilename=LocalSend-{#MyAppVersion}-windows-{#ArchitectureName}
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
Name: "{autoprograms}\LocalSend"; Filename: "{app}\localsend_app.exe"

[InstallDelete]
Type: files; Name: "{autoprograms}\LocalSend AutoSync.lnk"

[Run]
Filename: "{app}\localsend_app.exe"; Description: "Launch LocalSend"; Flags: nowait postinstall skipifsilent
