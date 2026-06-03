#define MyAppName "Sleep Time"
#define MyAppVersion GetEnv("ST_VERSION")
#define MyAppPublisher "Sleep Time contributors"
#define MyAppURL "https://github.com/Vibraneum/sleep-time"
#define MyAppExeName "sleep_time.exe"

[Setup]
AppId={{A0ABAC90-6CD3-4F67-9B1A-6B514033CE13}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=LICENSE
OutputDir=dist
OutputBaseFilename=sleep-time-windows-setup-v{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; Bundles the whole Release dir, including the sibling watchdog
; (sleep_time_watchdog.exe) that relaunches the app if it is killed while locked.
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Best-effort: make sure neither process is running so files can be removed.
Filename: "{cmd}"; Parameters: "/c taskkill /im sleep_time_watchdog.exe /f"; Flags: runhidden; RunOnceId: "killWatchdog"
Filename: "{cmd}"; Parameters: "/c taskkill /im sleep_time.exe /f"; Flags: runhidden; RunOnceId: "killApp"

[UninstallDelete]
; The app keeps best-effort recovery state here; clean it up on uninstall.
Type: filesandordirs; Name: "{localappdata}\SleepTime"

[Registry]
; The app self-registers these run-at-login keys at runtime; remove them on uninstall
; so an uninstalled app can never relaunch itself or its watchdog.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "SleepTime"; ValueType: none; Flags: deletevalue uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "SleepTimeWatchdog"; ValueType: none; Flags: deletevalue uninsdeletevalue
