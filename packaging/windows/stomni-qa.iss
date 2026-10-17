#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildNumber
  #error BuildNumber is required
#endif
#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef OutputPath
  #error OutputPath is required
#endif

[Setup]
AppId={{F455C916-8664-42BB-B357-4C51DD97F282}
AppName=StOmni SaaS QA
AppVersion={#AppVersion}.{#BuildNumber}
AppPublisher=StOmni
DefaultDirName={localappdata}\Programs\StOmni SaaS QA
DefaultGroupName=StOmni SaaS QA
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputPath}
OutputBaseFilename=StOmni-SaaS-QA-{#AppVersion}-{#BuildNumber}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\StOmni.exe
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\StOmni SaaS QA"; Filename: "{app}\StOmni.exe"
Name: "{autodesktop}\StOmni SaaS QA"; Filename: "{app}\StOmni.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Crear acceso directo en el escritorio"; Flags: unchecked

[Run]
Filename: "{app}\StOmni.exe"; Description: "Abrir StOmni SaaS QA"; Flags: nowait postinstall skipifsilent
